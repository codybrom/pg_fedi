use std::ffi::CString;

use pgrx::{GucContext, GucFlags, GucRegistry, GucSetting};

// -- GUC variables -----------------------------------------------------------

pub static DOMAIN: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);

pub static USE_HTTPS: GucSetting<bool> = GucSetting::<bool>::new(true);

pub static AUTO_ACCEPT_FOLLOWS: GucSetting<bool> = GucSetting::<bool>::new(true);

pub static MAX_DELIVERY_ATTEMPTS: GucSetting<i32> = GucSetting::<i32>::new(8);

pub static DELIVERY_TIMEOUT_SECONDS: GucSetting<i32> = GucSetting::<i32>::new(30);

pub static USER_AGENT: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"pg_fedi/0.1.0"));

// -- Registration ------------------------------------------------------------

pub fn register_gucs() {
    GucRegistry::define_string_guc(
        c"pg_fedi.domain",
        c"The domain name for this ActivityPub instance (e.g. 'example.com').",
        c"Used to construct actor URIs, WebFinger responses, and all federation identifiers. Required.",
        &DOMAIN,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_bool_guc(
        c"pg_fedi.https",
        c"Whether to use HTTPS in generated URIs.",
        c"Set to false only for local development.",
        &USE_HTTPS,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_bool_guc(
        c"pg_fedi.auto_accept_follows",
        c"Automatically accept incoming follow requests.",
        c"When true, incoming Follow activities are immediately accepted.",
        &AUTO_ACCEPT_FOLLOWS,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_fedi.max_delivery_attempts",
        c"Maximum number of delivery attempts before marking as expired.",
        c"Uses exponential backoff: 1m, 5m, 30m, 2h, 12h, 24h, 3d, 7d.",
        &MAX_DELIVERY_ATTEMPTS,
        1,
        20,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_fedi.delivery_timeout_seconds",
        c"HTTP timeout in seconds for outbound activity delivery.",
        c"How long to wait for a response when delivering to a remote inbox.",
        &DELIVERY_TIMEOUT_SECONDS,
        5,
        120,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_fedi.user_agent",
        c"User-Agent header for outbound HTTP requests.",
        c"Identifies this instance in federation traffic.",
        &USER_AGENT,
        GucContext::Suset,
        GucFlags::default(),
    );
}

// -- Helpers -----------------------------------------------------------------

/// Returns the configured domain or panics with a clear message.
pub fn get_domain() -> String {
    DOMAIN
        .get()
        .expect("pg_fedi.domain is not set. Run: ALTER SYSTEM SET pg_fedi.domain = 'yourdomain.com';")
        .to_str()
        .expect("pg_fedi.domain contains invalid UTF-8")
        .to_string()
}

/// Returns the base URL for this instance (e.g. "https://example.com").
pub fn base_url() -> String {
    let scheme = if USE_HTTPS.get() { "https" } else { "http" };
    format!("{}://{}", scheme, get_domain())
}
