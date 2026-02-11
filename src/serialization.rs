use pgrx::prelude::*;
use serde_json::json;

use crate::guc::base_url;
use crate::util::json_str;

const PAGE_SIZE: i64 = 20;

/// Serialize a Note/Article object to ActivityStreams JSON-LD.
#[pg_extern]
fn ap_serialize_object(object_uri: &str) -> pgrx::Json {
    let row = Spi::get_one_with_args::<pgrx::Json>(
        "SELECT json_build_object(
            'uri', o.uri,
            'object_type', o.object_type::text,
            'content', o.content,
            'summary', o.summary,
            'url', o.url,
            'in_reply_to_uri', o.in_reply_to_uri,
            'conversation_uri', o.conversation_uri,
            'sensitive', o.sensitive,
            'published_at', o.published_at,
            'edited_at', o.edited_at,
            'language', o.language,
            'actor_uri', a.uri,
            'actor_username', a.username,
            'followers_uri', a.followers_uri
        )::json FROM ap_objects o
        JOIN ap_actors a ON a.id = o.actor_id
        WHERE o.uri = $1 AND o.deleted_at IS NULL",
        &[object_uri.into()],
    )
    .expect("failed to query object")
    .expect("object not found");

    let r = &row.0;

    let uri = r["uri"].as_str().unwrap();
    let obj_type = r["object_type"].as_str().unwrap_or("Note");
    let actor_uri = r["actor_uri"].as_str().unwrap();
    let followers_uri = r["followers_uri"].as_str();

    let public = "https://www.w3.org/ns/activitystreams#Public";

    let mut doc = json!({
        "@context": "https://www.w3.org/ns/activitystreams",
        "id": uri,
        "type": obj_type,
        "attributedTo": actor_uri,
        "to": [public],
        "cc": followers_uri.map(|f| json!([f])).unwrap_or(json!([])),
        "published": r["published_at"],
    });

    let obj = doc.as_object_mut().unwrap();

    if let Some(content) = r["content"].as_str() {
        obj.insert("content".into(), json!(content));

        if let Some(lang) = r["language"].as_str() {
            obj.insert("contentMap".into(), json!({ lang: content }));
        }
    }
    if let Some(s) = r["summary"].as_str() {
        obj.insert("summary".into(), json!(s));
        obj.insert("sensitive".into(), json!(true));
    }
    if let Some(url) = r["url"].as_str() {
        obj.insert("url".into(), json!(url));
    }
    if let Some(reply) = r["in_reply_to_uri"].as_str() {
        obj.insert("inReplyTo".into(), json!(reply));
    }
    if let Some(conv) = r["conversation_uri"].as_str() {
        obj.insert("conversation".into(), json!(conv));
    }
    if !r["edited_at"].is_null() {
        obj.insert("updated".into(), r["edited_at"].clone());
    }

    pgrx::Json(doc)
}

/// Serialize an actor's outbox as an OrderedCollection or OrderedCollectionPage.
/// If page is NULL, returns the collection summary. Otherwise returns the page.
#[pg_extern]
fn ap_serialize_outbox(username: &str, page: Option<i32>) -> pgrx::Json {
    let base = base_url();
    let outbox_uri = format!("{}/users/{}/outbox", base, username);

    match page {
        None => {
            // Collection summary
            let total = Spi::get_one_with_args::<i64>(
                "SELECT count(*) FROM ap_activities act
                 JOIN ap_actors a ON a.id = act.actor_id
                 WHERE a.username = $1 AND a.domain IS NULL
                 AND act.local = true AND act.activity_type = 'Create'",
                &[username.into()],
            )
            .unwrap()
            .unwrap_or(0);

            pgrx::Json(json!({
                "@context": "https://www.w3.org/ns/activitystreams",
                "id": outbox_uri,
                "type": "OrderedCollection",
                "totalItems": total,
                "first": format!("{}?page=1", outbox_uri),
                "last": format!("{}?page={}", outbox_uri, (total / PAGE_SIZE) + 1),
            }))
        }
        Some(p) => {
            let offset = ((p.max(1) - 1) as i64) * PAGE_SIZE;

            let items: Vec<pgrx::Json> = Spi::connect(|client| {
                let mut results = Vec::new();
                let tup_table = client
                    .select(
                        "SELECT ap_serialize_activity(act.uri)::json
                         FROM ap_activities act
                         JOIN ap_actors a ON a.id = act.actor_id
                         WHERE a.username = $1 AND a.domain IS NULL
                         AND act.local = true AND act.activity_type = 'Create'
                         ORDER BY act.created_at DESC
                         LIMIT $2 OFFSET $3",
                        None,
                        &[username.into(), PAGE_SIZE.into(), offset.into()],
                    )
                    .expect("failed to query outbox");

                for row in tup_table {
                    if let Some(j) = row
                        .get_datum_by_ordinal(1)
                        .unwrap()
                        .value::<pgrx::Json>()
                        .ok()
                        .flatten()
                    {
                        results.push(j);
                    }
                }

                results
            });

            let item_values: Vec<serde_json::Value> = items.into_iter().map(|j| j.0).collect();

            let mut page_doc = json!({
                "@context": "https://www.w3.org/ns/activitystreams",
                "id": format!("{}?page={}", outbox_uri, p),
                "type": "OrderedCollectionPage",
                "partOf": outbox_uri,
                "orderedItems": item_values,
            });

            if p > 1 {
                page_doc.as_object_mut().unwrap().insert(
                    "prev".into(),
                    json!(format!("{}?page={}", outbox_uri, p - 1)),
                );
            }

            let has_more = item_values.len() as i64 >= PAGE_SIZE;
            if has_more {
                page_doc.as_object_mut().unwrap().insert(
                    "next".into(),
                    json!(format!("{}?page={}", outbox_uri, p + 1)),
                );
            }

            pgrx::Json(page_doc)
        }
    }
}

/// Serialize an actor's followers as an OrderedCollection or OrderedCollectionPage.
#[pg_extern]
fn ap_serialize_followers(username: &str, page: Option<i32>) -> pgrx::Json {
    let base = base_url();
    let collection_uri = format!("{}/users/{}/followers", base, username);

    match page {
        None => {
            let total = Spi::get_one_with_args::<i64>(
                "SELECT count(*) FROM ap_follows f
                 JOIN ap_actors a ON a.id = f.following_id
                 WHERE a.username = $1 AND a.domain IS NULL AND f.accepted = true",
                &[username.into()],
            )
            .unwrap()
            .unwrap_or(0);

            pgrx::Json(json!({
                "@context": "https://www.w3.org/ns/activitystreams",
                "id": collection_uri,
                "type": "OrderedCollection",
                "totalItems": total,
                "first": format!("{}?page=1", collection_uri),
            }))
        }
        Some(p) => {
            let offset = ((p.max(1) - 1) as i64) * PAGE_SIZE;

            let items: Vec<String> = Spi::connect(|client| {
                let mut results = Vec::new();
                let tup_table = client
                    .select(
                        "SELECT fa.uri FROM ap_follows f
                         JOIN ap_actors a ON a.id = f.following_id
                         JOIN ap_actors fa ON fa.id = f.follower_id
                         WHERE a.username = $1 AND a.domain IS NULL AND f.accepted = true
                         ORDER BY f.created_at DESC
                         LIMIT $2 OFFSET $3",
                        None,
                        &[username.into(), PAGE_SIZE.into(), offset.into()],
                    )
                    .expect("failed to query followers");

                for row in tup_table {
                    if let Some(uri) = row
                        .get_datum_by_ordinal(1)
                        .unwrap()
                        .value::<String>()
                        .ok()
                        .flatten()
                    {
                        results.push(uri);
                    }
                }

                results
            });

            let mut page_doc = json!({
                "@context": "https://www.w3.org/ns/activitystreams",
                "id": format!("{}?page={}", collection_uri, p),
                "type": "OrderedCollectionPage",
                "partOf": collection_uri,
                "orderedItems": items,
            });

            if p > 1 {
                page_doc.as_object_mut().unwrap().insert(
                    "prev".into(),
                    json!(format!("{}?page={}", collection_uri, p - 1)),
                );
            }

            if items.len() as i64 >= PAGE_SIZE {
                page_doc.as_object_mut().unwrap().insert(
                    "next".into(),
                    json!(format!("{}?page={}", collection_uri, p + 1)),
                );
            }

            pgrx::Json(page_doc)
        }
    }
}

/// Serialize an actor's following list as an OrderedCollection.
#[pg_extern]
fn ap_serialize_following(username: &str, page: Option<i32>) -> pgrx::Json {
    let base = base_url();
    let collection_uri = format!("{}/users/{}/following", base, username);

    match page {
        None => {
            let total = Spi::get_one_with_args::<i64>(
                "SELECT count(*) FROM ap_follows f
                 JOIN ap_actors a ON a.id = f.follower_id
                 WHERE a.username = $1 AND a.domain IS NULL AND f.accepted = true",
                &[username.into()],
            )
            .unwrap()
            .unwrap_or(0);

            pgrx::Json(json!({
                "@context": "https://www.w3.org/ns/activitystreams",
                "id": collection_uri,
                "type": "OrderedCollection",
                "totalItems": total,
                "first": format!("{}?page=1", collection_uri),
            }))
        }
        Some(p) => {
            let offset = ((p.max(1) - 1) as i64) * PAGE_SIZE;

            let items: Vec<String> = Spi::connect(|client| {
                let mut results = Vec::new();
                let tup_table = client
                    .select(
                        "SELECT fa.uri FROM ap_follows f
                         JOIN ap_actors a ON a.id = f.follower_id
                         JOIN ap_actors fa ON fa.id = f.following_id
                         WHERE a.username = $1 AND a.domain IS NULL AND f.accepted = true
                         ORDER BY f.created_at DESC
                         LIMIT $2 OFFSET $3",
                        None,
                        &[username.into(), PAGE_SIZE.into(), offset.into()],
                    )
                    .expect("failed to query following");

                for row in tup_table {
                    if let Some(uri) = row
                        .get_datum_by_ordinal(1)
                        .unwrap()
                        .value::<String>()
                        .ok()
                        .flatten()
                    {
                        results.push(uri);
                    }
                }

                results
            });

            let mut page_doc = json!({
                "@context": "https://www.w3.org/ns/activitystreams",
                "id": format!("{}?page={}", collection_uri, p),
                "type": "OrderedCollectionPage",
                "partOf": collection_uri,
                "orderedItems": items,
            });

            if p > 1 {
                page_doc.as_object_mut().unwrap().insert(
                    "prev".into(),
                    json!(format!("{}?page={}", collection_uri, p - 1)),
                );
            }

            if items.len() as i64 >= PAGE_SIZE {
                page_doc.as_object_mut().unwrap().insert(
                    "next".into(),
                    json!(format!("{}?page={}", collection_uri, p + 1)),
                );
            }

            pgrx::Json(page_doc)
        }
    }
}

/// Serialize a stored activity to full ActivityStreams JSON-LD.
/// If the activity has stored raw JSON, returns that with @context added.
/// Otherwise reconstructs the activity from the database fields.
#[pg_extern]
fn ap_serialize_activity(activity_uri: &str) -> pgrx::Json {
    let row = Spi::get_one_with_args::<pgrx::Json>(
        "SELECT json_build_object(
            'uri', act.uri,
            'activity_type', act.activity_type::text,
            'actor_uri', a.uri,
            'object_uri', act.object_uri,
            'target_uri', act.target_uri,
            'to_uris', act.to_uris,
            'cc_uris', act.cc_uris,
            'raw', act.raw,
            'created_at', act.created_at
        )::json FROM ap_activities act
        JOIN ap_actors a ON a.id = act.actor_id
        WHERE act.uri = $1",
        &[activity_uri.into()],
    )
    .expect("failed to query activity")
    .expect("activity not found");

    let r = &row.0;

    // If we have stored raw JSON, use it (adding @context if missing)
    if let Some(raw) = r.get("raw") {
        if raw.is_object() {
            let mut doc = raw.clone();
            if doc.get("@context").is_none() {
                doc.as_object_mut().unwrap().insert(
                    "@context".into(),
                    json!("https://www.w3.org/ns/activitystreams"),
                );
            }
            return pgrx::Json(doc);
        }
    }

    // Reconstruct from fields
    let uri = json_str(r, "uri").unwrap();
    let activity_type = json_str(r, "activity_type").unwrap();
    let actor_uri = json_str(r, "actor_uri").unwrap();
    let object_uri = json_str(r, "object_uri");

    let mut doc = json!({
        "@context": "https://www.w3.org/ns/activitystreams",
        "id": uri,
        "type": activity_type,
        "actor": actor_uri,
        "published": r["created_at"],
    });

    let obj = doc.as_object_mut().unwrap();

    if let Some(object) = object_uri {
        obj.insert("object".into(), json!(object));
    }
    if let Some(target) = json_str(r, "target_uri") {
        obj.insert("target".into(), json!(target));
    }

    // Add addressing
    if let Some(to) = r.get("to_uris") {
        if to.is_array() {
            obj.insert("to".into(), to.clone());
        }
    }
    if let Some(cc) = r.get("cc_uris") {
        if cc.is_array() {
            obj.insert("cc".into(), cc.clone());
        }
    }

    pgrx::Json(doc)
}

/// Serialize an actor's featured/pinned posts as an OrderedCollection.
/// Returns an empty collection (pinning can be added via a `pinned` column later).
/// This endpoint must exist for Mastodon compatibility.
#[pg_extern]
fn ap_serialize_featured(username: &str) -> pgrx::Json {
    let base = base_url();
    let collection_uri = format!("{}/users/{}/collections/featured", base, username);

    pgrx::Json(json!({
        "@context": "https://www.w3.org/ns/activitystreams",
        "id": collection_uri,
        "type": "OrderedCollection",
        "totalItems": 0,
        "orderedItems": [],
    }))
}
