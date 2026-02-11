use pgrx::prelude::*;
use serde_json::json;

use crate::crypto::generate_keypair;
use crate::guc::base_url;
use crate::util::{json_str, json_str_nested, parse_domain};

// =============================================================================
// Local actor creation
// =============================================================================

/// Create a local actor with a generated RSA keypair.
/// Returns the actor's URI.
#[pg_extern]
fn ap_create_local_actor(
    username: &str,
    display_name: Option<&str>,
    summary: Option<&str>,
) -> String {
    let base = base_url();
    let uri = format!("{}/users/{}", base, username);
    let inbox = format!("{}/inbox", uri);
    let outbox = format!("{}/outbox", uri);
    let followers = format!("{}/followers", uri);
    let following = format!("{}/following", uri);
    let featured = format!("{}/collections/featured", uri);
    let shared_inbox = format!("{}/inbox", base);
    let key_id = format!("{}#main-key", uri);

    let (public_pem, private_pem) = generate_keypair();

    Spi::run_with_args(
        "INSERT INTO ap_actors (uri, actor_type, username, display_name, summary,
            inbox_uri, outbox_uri, followers_uri, following_uri, featured_uri, shared_inbox_uri)
         VALUES ($1, 'Person', $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        &[
            uri.clone().into(),
            username.into(),
            display_name.into(),
            summary.into(),
            inbox.into(),
            outbox.into(),
            followers.into(),
            following.into(),
            featured.into(),
            shared_inbox.into(),
        ],
    )
    .expect("failed to insert actor");

    Spi::run_with_args(
        "INSERT INTO ap_keys (actor_id, key_id, public_key_pem, private_key_pem)
         VALUES ((SELECT id FROM ap_actors WHERE uri = $1), $2, $3, $4)",
        &[
            uri.clone().into(),
            key_id.into(),
            public_pem.into(),
            private_pem.into(),
        ],
    )
    .expect("failed to insert keypair");

    uri
}

// =============================================================================
// Remote actor upsert
// =============================================================================

/// Upsert a remote actor from raw ActivityStreams JSON.
/// Parses the JSON to extract fields, inserts or updates the actor row,
/// and stores/updates the public key if present.
#[pg_extern]
fn ap_upsert_remote_actor(actor_json: pgrx::Json) -> String {
    let obj = &actor_json.0;

    let uri = json_str(obj, "id").expect("actor JSON missing 'id'");
    let actor_type = json_str(obj, "type").unwrap_or("Person".to_string());
    let username =
        json_str(obj, "preferredUsername").expect("actor JSON missing 'preferredUsername'");
    let display_name = json_str(obj, "name");
    let summary = json_str(obj, "summary");
    let inbox = json_str(obj, "inbox").expect("actor JSON missing 'inbox'");
    let outbox = json_str(obj, "outbox").expect("actor JSON missing 'outbox'");
    let followers = json_str(obj, "followers");
    let following = json_str(obj, "following");
    let featured = json_str_nested(obj, &["featured", "id"]).or_else(|| json_str(obj, "featured"));
    let shared_inbox = json_str_nested(obj, &["endpoints", "sharedInbox"]);

    let icon_url = json_str_nested(obj, &["icon", "url"]);
    let image_url = json_str_nested(obj, &["image", "url"]);
    let manually_approves = obj
        .get("manuallyApprovesFollowers")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let discoverable = obj
        .get("discoverable")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);

    // Parse domain from URI
    let domain = parse_domain(&uri).expect("could not parse domain from actor URI");

    let raw_json = pgrx::JsonB(obj.clone());

    // Map ActivityStreams type name to our enum value
    let pg_actor_type = match actor_type.as_str() {
        "Person" | "Group" | "Application" | "Service" | "Organization" => actor_type.as_str(),
        _ => "Person",
    };

    Spi::run_with_args(
        "INSERT INTO ap_actors (uri, actor_type, username, domain, display_name, summary,
            inbox_uri, outbox_uri, followers_uri, following_uri, featured_uri, shared_inbox_uri,
            avatar_url, header_url, manually_approves_followers, discoverable, raw, last_fetched_at)
         VALUES ($1, $2::ApActorType, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, now())
         ON CONFLICT (uri) DO UPDATE SET
            display_name = EXCLUDED.display_name,
            summary = EXCLUDED.summary,
            inbox_uri = EXCLUDED.inbox_uri,
            outbox_uri = EXCLUDED.outbox_uri,
            followers_uri = EXCLUDED.followers_uri,
            following_uri = EXCLUDED.following_uri,
            featured_uri = EXCLUDED.featured_uri,
            shared_inbox_uri = EXCLUDED.shared_inbox_uri,
            avatar_url = EXCLUDED.avatar_url,
            header_url = EXCLUDED.header_url,
            manually_approves_followers = EXCLUDED.manually_approves_followers,
            discoverable = EXCLUDED.discoverable,
            raw = EXCLUDED.raw,
            last_fetched_at = now()",
        &[
            uri.clone().into(),
            pg_actor_type.to_string().into(),
            username.into(),
            domain.into(),
            display_name.into(),
            summary.into(),
            inbox.into(),
            outbox.into(),
            followers.into(),
            following.into(),
            featured.into(),
            shared_inbox.into(),
            icon_url.into(),
            image_url.into(),
            manually_approves.into(),
            discoverable.into(),
            raw_json.into(),
        ],
    )
    .expect("failed to upsert remote actor");

    // Upsert public key if present
    if let Some(pk) = obj.get("publicKey") {
        let key_id = json_str(pk, "id");
        let public_key_pem = json_str(pk, "publicKeyPem");

        if let (Some(key_id), Some(public_key_pem)) = (key_id, public_key_pem) {
            Spi::run_with_args(
                "INSERT INTO ap_keys (actor_id, key_id, public_key_pem)
                 VALUES ((SELECT id FROM ap_actors WHERE uri = $1), $2, $3)
                 ON CONFLICT (key_id) DO UPDATE SET
                    public_key_pem = EXCLUDED.public_key_pem",
                &[uri.clone().into(), key_id.into(), public_key_pem.into()],
            )
            .expect("failed to upsert public key");
        }
    }

    uri
}

// =============================================================================
// Actor serialization
// =============================================================================

/// Serialize a local actor to full ActivityStreams JSON-LD.
/// Accepts a username (local actors only).
#[pg_extern]
fn ap_serialize_actor(username: &str) -> pgrx::Json {
    let base = base_url();

    let row = Spi::get_one_with_args::<pgrx::Json>(
        "SELECT json_build_object(
            'uri', a.uri,
            'actor_type', a.actor_type::text,
            'username', a.username,
            'display_name', a.display_name,
            'summary', a.summary,
            'inbox_uri', a.inbox_uri,
            'outbox_uri', a.outbox_uri,
            'followers_uri', a.followers_uri,
            'following_uri', a.following_uri,
            'featured_uri', a.featured_uri,
            'shared_inbox_uri', a.shared_inbox_uri,
            'avatar_url', a.avatar_url,
            'header_url', a.header_url,
            'manually_approves_followers', a.manually_approves_followers,
            'discoverable', a.discoverable,
            'memorial', a.memorial,
            'created_at', a.created_at,
            'public_key_pem', k.public_key_pem,
            'key_id', k.key_id
        )::json FROM ap_actors a
        LEFT JOIN ap_keys k ON k.actor_id = a.id
        WHERE a.username = $1 AND a.domain IS NULL",
        &[username.into()],
    )
    .expect("failed to query actor")
    .expect("actor not found");

    let r = &row.0;

    let uri = json_str(r, "uri").unwrap();
    let actor_type = json_str(r, "actor_type").unwrap_or("Person".into());
    let display_name = json_str(r, "display_name");
    let summary = json_str(r, "summary");
    let inbox = json_str(r, "inbox_uri").unwrap();
    let outbox = json_str(r, "outbox_uri").unwrap();
    let followers = json_str(r, "followers_uri");
    let following = json_str(r, "following_uri");
    let featured = json_str(r, "featured_uri");
    let shared_inbox = json_str(r, "shared_inbox_uri");
    let avatar_url = json_str(r, "avatar_url");
    let header_url = json_str(r, "header_url");
    let manually_approves = r
        .get("manually_approves_followers")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let discoverable = r
        .get("discoverable")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);
    let public_key_pem = json_str(r, "public_key_pem");
    let key_id = json_str(r, "key_id");
    let uname = json_str(r, "username").unwrap();

    let url = format!("{}/@{}", base, uname);

    let mut doc = json!({
        "@context": [
            "https://www.w3.org/ns/activitystreams",
            "https://w3id.org/security/v1",
            {
                "manuallyApprovesFollowers": "as:manuallyApprovesFollowers",
                "toot": "http://joinmastodon.org/ns#",
                "featured": { "@id": "toot:featured", "@type": "@id" },
                "discoverable": "toot:discoverable",
                "schema": "http://schema.org#",
                "PropertyValue": "schema:PropertyValue",
                "value": "schema:value"
            }
        ],
        "id": uri,
        "type": actor_type,
        "preferredUsername": uname,
        "inbox": inbox,
        "outbox": outbox,
        "url": url,
        "manuallyApprovesFollowers": manually_approves,
        "discoverable": discoverable,
    });

    let obj = doc.as_object_mut().unwrap();

    if let Some(name) = display_name {
        obj.insert("name".into(), json!(name));
    }
    if let Some(s) = summary {
        obj.insert("summary".into(), json!(s));
    }
    if let Some(f) = followers {
        obj.insert("followers".into(), json!(f));
    }
    if let Some(f) = following {
        obj.insert("following".into(), json!(f));
    }
    if let Some(f) = featured {
        obj.insert("featured".into(), json!(f));
    }

    if let (Some(kid), Some(pem)) = (key_id, public_key_pem) {
        obj.insert(
            "publicKey".into(),
            json!({
                "id": kid,
                "owner": obj.get("id").unwrap(),
                "publicKeyPem": pem
            }),
        );
    }

    if let Some(si) = shared_inbox {
        obj.insert("endpoints".into(), json!({ "sharedInbox": si }));
    }

    if let Some(av) = avatar_url {
        obj.insert("icon".into(), json!({ "type": "Image", "url": av }));
    }
    if let Some(hd) = header_url {
        obj.insert("image".into(), json!({ "type": "Image", "url": hd }));
    }

    pgrx::Json(doc)
}
