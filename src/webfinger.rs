use pgrx::prelude::*;
use serde_json::json;

use crate::guc::base_url;

/// Generate a WebFinger JRD response for a given resource.
/// Accepts `acct:user@domain` or just `user@domain`.
/// Returns JSON per RFC 7033.
#[pg_extern]
fn ap_webfinger(resource: &str) -> pgrx::Json {
    let base = base_url();

    // Parse the acct: URI
    let acct = resource.strip_prefix("acct:").unwrap_or(resource).trim();

    let username = acct
        .split('@')
        .next()
        .expect("invalid resource: no username");

    // Verify the actor exists locally
    let exists = Spi::get_one_with_args::<bool>(
        "SELECT EXISTS(SELECT 1 FROM ap_actors WHERE username = $1 AND domain IS NULL)",
        &[username.into()],
    )
    .expect("failed to query actor");

    if exists != Some(true) {
        pgrx::error!("actor '{}' not found", username);
    }

    let actor_uri = format!("{}/users/{}", base, username);
    let profile_url = format!("{}/@{}", base, username);

    pgrx::Json(json!({
        "subject": format!("acct:{}", acct),
        "aliases": [
            profile_url,
            actor_uri,
        ],
        "links": [
            {
                "rel": "self",
                "type": "application/activity+json",
                "href": actor_uri
            },
            {
                "rel": "http://webfinger.net/rel/profile-page",
                "type": "text/html",
                "href": profile_url
            }
        ]
    }))
}

/// Generate the host-meta XRD document.
/// Used by some older clients for WebFinger discovery.
#[pg_extern]
fn ap_host_meta() -> String {
    let base = base_url();

    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
  <Link rel="lhost-meta" type="application/xrd+xml" template="{base}/.well-known/webfinger?resource={{uri}}"/>
</XRD>"#
    )
}
