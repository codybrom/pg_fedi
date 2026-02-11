use pgrx::prelude::*;
use pkcs8::{EncodePrivateKey, EncodePublicKey, LineEnding};
use rand::rngs::OsRng;
use rsa::pkcs1v15::{SigningKey, VerifyingKey};
use rsa::pkcs8::{DecodePrivateKey, DecodePublicKey};
use rsa::{RsaPrivateKey, RsaPublicKey};
use sha2::{Digest, Sha256};
use signature::{SignatureEncoding, Signer, Verifier};

const RSA_KEY_BITS: usize = 2048;

// =============================================================================
// Keypair generation
// =============================================================================

/// Generate an RSA-2048 keypair, returning (public_key_pem, private_key_pem).
/// Internal function used by actor creation.
pub fn generate_keypair() -> (String, String) {
    let private_key =
        RsaPrivateKey::new(&mut OsRng, RSA_KEY_BITS).expect("failed to generate RSA private key");
    let public_key = RsaPublicKey::from(&private_key);

    let private_pem = private_key
        .to_pkcs8_pem(LineEnding::LF)
        .expect("failed to encode private key to PEM")
        .to_string();

    let public_pem = public_key
        .to_public_key_pem(LineEnding::LF)
        .expect("failed to encode public key to PEM");

    (public_pem, private_pem)
}

/// SQL-callable keypair generation. Returns a single-row table with
/// (public_key_pem TEXT, private_key_pem TEXT).
#[pg_extern]
fn ap_generate_keypair() -> TableIterator<
    'static,
    (
        name!(public_key_pem, String),
        name!(private_key_pem, String),
    ),
> {
    let (public_pem, private_pem) = generate_keypair();
    TableIterator::once((public_pem, private_pem))
}

// =============================================================================
// HTTP Signature support (draft-cavage-http-signatures)
// =============================================================================

/// Compute the SHA-256 digest of a request body.
/// Returns the value for the Digest header: "SHA-256=<base64>".
#[pg_extern]
fn ap_digest(body: &str) -> String {
    let hash = Sha256::digest(body.as_bytes());
    let encoded = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, hash);
    format!("SHA-256={}", encoded)
}

/// Sign data with RSA-SHA256 using a private key in PKCS#8 PEM format.
/// Returns the base64-encoded signature.
#[pg_extern]
fn ap_rsa_sign(private_key_pem: &str, data: &str) -> String {
    let private_key =
        RsaPrivateKey::from_pkcs8_pem(private_key_pem).expect("failed to parse private key PEM");
    let signing_key = SigningKey::<Sha256>::new(private_key);
    let sig = signing_key.sign(data.as_bytes());
    base64::Engine::encode(&base64::engine::general_purpose::STANDARD, sig.to_bytes())
}

/// Verify an RSA-SHA256 signature against a public key in SPKI PEM format.
/// Returns true if the signature is valid.
#[pg_extern]
fn ap_rsa_verify(public_key_pem: &str, data: &str, signature_b64: &str) -> bool {
    let public_key = match RsaPublicKey::from_public_key_pem(public_key_pem) {
        Ok(k) => k,
        Err(_) => return false,
    };

    let sig_bytes =
        match base64::Engine::decode(&base64::engine::general_purpose::STANDARD, signature_b64) {
            Ok(b) => b,
            Err(_) => return false,
        };

    let sig = match rsa::pkcs1v15::Signature::try_from(sig_bytes.as_slice()) {
        Ok(s) => s,
        Err(_) => return false,
    };

    let verifying_key = VerifyingKey::<Sha256>::new(public_key);
    verifying_key.verify(data.as_bytes(), &sig).is_ok()
}

/// Build a complete HTTP Signature header value for an outbound ActivityPub request.
///
/// Implements draft-cavage-http-signatures with headers:
///   (request-target) host date digest
///
/// Returns the full `Signature` header value ready to set on the request.
#[pg_extern]
fn ap_build_signature_header(
    key_id: &str,
    private_key_pem: &str,
    method: &str,
    url: &str,
    date: &str,
    body: &str,
) -> String {
    // Parse the URL to extract host and path
    let (host, path) = parse_url_parts(url);

    // Compute digest
    let digest = {
        let hash = Sha256::digest(body.as_bytes());
        let encoded = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, hash);
        format!("SHA-256={}", encoded)
    };

    // Build the signing string
    let signing_string = format!(
        "(request-target): {} {}\nhost: {}\ndate: {}\ndigest: {}",
        method.to_lowercase(),
        path,
        host,
        date,
        digest
    );

    // Sign it
    let private_key =
        RsaPrivateKey::from_pkcs8_pem(private_key_pem).expect("failed to parse private key PEM");
    let signing_key = SigningKey::<Sha256>::new(private_key);
    let sig = signing_key.sign(signing_string.as_bytes());
    let sig_b64 =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, sig.to_bytes());

    format!(
        "keyId=\"{}\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest\",signature=\"{}\"",
        key_id, sig_b64
    )
}

/// Verify an incoming HTTP Signature.
///
/// Parses the Signature header, reconstructs the signing string from the
/// provided request components, and verifies against the public key.
///
/// Parameters:
/// - signature_header: the raw `Signature` header value
/// - method: HTTP method (e.g., "POST")
/// - path: request path (e.g., "/users/alice/inbox")
/// - host: the Host header value
/// - date: the Date header value
/// - digest: the Digest header value (optional, only needed if "digest" is in signed headers)
/// - public_key_pem: the actor's public key in SPKI PEM format
#[pg_extern]
fn ap_verify_http_signature(
    signature_header: &str,
    method: &str,
    path: &str,
    host: &str,
    date: &str,
    digest: Option<&str>,
    public_key_pem: &str,
) -> bool {
    // Parse the Signature header fields
    let fields = match parse_signature_header(signature_header) {
        Some(f) => f,
        None => return false,
    };

    let headers_str = fields.headers.as_deref().unwrap_or("date");
    let sig_b64 = match fields.signature {
        Some(ref s) => s.as_str(),
        None => return false,
    };

    // Reconstruct the signing string from the listed headers
    let mut parts = Vec::new();
    for header in headers_str.split_whitespace() {
        let value = match header {
            "(request-target)" => {
                format!("(request-target): {} {}", method.to_lowercase(), path)
            }
            "host" => format!("host: {}", host),
            "date" => format!("date: {}", date),
            "digest" => {
                if let Some(d) = digest {
                    format!("digest: {}", d)
                } else {
                    return false;
                }
            }
            "content-type" => {
                // Some implementations include content-type; we accept but skip
                continue;
            }
            _ => continue,
        };
        parts.push(value);
    }

    let signing_string = parts.join("\n");

    // Verify
    ap_rsa_verify(public_key_pem, &signing_string, sig_b64)
}

// =============================================================================
// Helpers
// =============================================================================

/// Extract host and path from a URL string.
fn parse_url_parts(url: &str) -> (String, String) {
    // Strip scheme
    let without_scheme = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);

    // Split host and path
    match without_scheme.find('/') {
        Some(idx) => (
            without_scheme[..idx].to_string(),
            without_scheme[idx..].to_string(),
        ),
        None => (without_scheme.to_string(), "/".to_string()),
    }
}

/// Parsed fields from a Signature header.
struct SignatureFields {
    #[allow(dead_code)]
    key_id: Option<String>,
    #[allow(dead_code)]
    algorithm: Option<String>,
    headers: Option<String>,
    signature: Option<String>,
}

/// Parse a Signature header value into its components.
/// Format: `keyId="...",algorithm="...",headers="...",signature="..."`
fn parse_signature_header(header: &str) -> Option<SignatureFields> {
    let mut key_id = None;
    let mut algorithm = None;
    let mut headers = None;
    let mut signature = None;

    // Simple parser for key="value" pairs
    let mut remaining = header.trim();
    while !remaining.is_empty() {
        remaining = remaining.trim_start_matches(',').trim();
        if remaining.is_empty() {
            break;
        }

        let eq_pos = remaining.find('=')?;
        let key = remaining[..eq_pos].trim();
        remaining = &remaining[eq_pos + 1..];

        // Expect a quoted value
        if !remaining.starts_with('"') {
            return None;
        }
        remaining = &remaining[1..];

        // Find closing quote (handle no escaping for simplicity)
        let end_quote = remaining.find('"')?;
        let value = remaining[..end_quote].to_string();
        remaining = &remaining[end_quote + 1..];

        match key {
            "keyId" => key_id = Some(value),
            "algorithm" => algorithm = Some(value),
            "headers" => headers = Some(value),
            "signature" => signature = Some(value),
            _ => {}
        }
    }

    Some(SignatureFields {
        key_id,
        algorithm,
        headers,
        signature,
    })
}
