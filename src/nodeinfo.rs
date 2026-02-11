use pgrx::prelude::*;
use serde_json::json;

use crate::guc::base_url;

/// Returns the .well-known/nodeinfo discovery document (JRD).
/// Points fediverse crawlers to the actual NodeInfo endpoint.
#[pg_extern]
fn ap_nodeinfo_discovery() -> pgrx::Json {
    let base = base_url();

    pgrx::Json(json!({
        "links": [
            {
                "rel": "http://nodeinfo.diaspora.software/ns/schema/2.0",
                "href": format!("{}/nodeinfo/2.0", base)
            }
        ]
    }))
}

/// Returns a NodeInfo 2.0 document with instance metadata.
/// Reports software name/version, supported protocols, and usage statistics.
#[pg_extern]
fn ap_nodeinfo() -> pgrx::Json {
    // Count local users
    let total_users = Spi::get_one::<i64>("SELECT count(*) FROM ap_actors WHERE domain IS NULL")
        .unwrap()
        .unwrap_or(0);

    // Count users active in the last month
    let monthly_active = Spi::get_one::<i64>(
        "SELECT count(DISTINCT a.id) FROM ap_actors a
         JOIN ap_activities act ON act.actor_id = a.id
         WHERE a.domain IS NULL AND act.local = true
         AND act.created_at > now() - interval '30 days'",
    )
    .unwrap()
    .unwrap_or(0);

    // Count users active in the last 6 months
    let halfyear_active = Spi::get_one::<i64>(
        "SELECT count(DISTINCT a.id) FROM ap_actors a
         JOIN ap_activities act ON act.actor_id = a.id
         WHERE a.domain IS NULL AND act.local = true
         AND act.created_at > now() - interval '180 days'",
    )
    .unwrap()
    .unwrap_or(0);

    // Count local posts
    let local_posts = Spi::get_one::<i64>(
        "SELECT count(*) FROM ap_objects o
         JOIN ap_actors a ON a.id = o.actor_id
         WHERE a.domain IS NULL AND o.deleted_at IS NULL",
    )
    .unwrap()
    .unwrap_or(0);

    pgrx::Json(json!({
        "version": "2.0",
        "software": {
            "name": "pg_fedi",
            "version": "0.1.0"
        },
        "protocols": ["activitypub"],
        "usage": {
            "users": {
                "total": total_users,
                "activeMonth": monthly_active,
                "activeHalfyear": halfyear_active
            },
            "localPosts": local_posts
        },
        "openRegistrations": false
    }))
}
