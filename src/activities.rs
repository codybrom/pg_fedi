use pgrx::prelude::*;
use serde_json::json;

use crate::guc::{base_url, AUTO_ACCEPT_FOLLOWS};
use crate::util::json_str;

// =============================================================================
// Note creation (outbox)
// =============================================================================

/// Create a Note and wrap it in a Create activity, queuing delivery to followers.
/// Returns the Note's URI.
#[pg_extern]
fn ap_create_note(
    username: &str,
    content: &str,
    summary: Option<&str>,
    in_reply_to: Option<&str>,
) -> String {
    let base = base_url();

    // Look up the local actor
    let actor_id = Spi::get_one_with_args::<i64>(
        "SELECT id FROM ap_actors WHERE username = $1 AND domain IS NULL",
        &[username.into()],
    )
    .expect("failed to query actor")
    .expect("local actor not found");

    let actor_uri = format!("{}/users/{}", base, username);

    // Generate a unique object URI using the DB sequence
    let object_id = Spi::get_one::<i64>("SELECT nextval('ap_objects_id_seq')")
        .unwrap()
        .unwrap();
    let object_uri = format!("{}/objects/{}", actor_uri, object_id);
    let object_url = format!("{}/@{}/{}", base, username, object_id);

    // Determine conversation URI
    let conversation_uri = match in_reply_to {
        Some(reply_uri) => {
            // Try to inherit conversation from parent
            Spi::get_one_with_args::<String>(
                "SELECT conversation_uri FROM ap_objects WHERE uri = $1",
                &[reply_uri.into()],
            )
            .ok()
            .flatten()
            .unwrap_or_else(|| format!("{}/conversations/{}", base, object_id))
        }
        None => format!("{}/conversations/{}", base, object_id),
    };

    // Strip HTML to plain text for full-text search
    let content_text = strip_html(content);

    // Insert the object (using the pre-allocated ID)
    Spi::run_with_args(
        "INSERT INTO ap_objects (id, uri, object_type, actor_id, content, content_text,
            summary, url, visibility, in_reply_to_uri, conversation_uri, published_at)
         VALUES ($1, $2, 'Note', $3, $4, $5, $6, $7, 'Public', $8, $9, now())",
        &[
            object_id.into(),
            object_uri.clone().into(),
            actor_id.into(),
            content.into(),
            content_text.into(),
            summary.into(),
            object_url.into(),
            in_reply_to.into(),
            conversation_uri.into(),
        ],
    )
    .expect("failed to insert object");

    // Build the Create activity
    let activity_id = Spi::get_one::<i64>("SELECT nextval('ap_activities_id_seq')")
        .unwrap()
        .unwrap();
    let activity_uri = format!("{}/activities/{}", actor_uri, activity_id);

    let public = "https://www.w3.org/ns/activitystreams#Public";
    let followers_uri = format!("{}/followers", actor_uri);

    Spi::run_with_args(
        "INSERT INTO ap_activities (id, uri, activity_type, actor_id, object_uri,
            to_uris, cc_uris, local, processed)
         VALUES ($1, $2, 'Create', $3, $4, $5, $6, true, true)",
        &[
            activity_id.into(),
            activity_uri.into(),
            actor_id.into(),
            object_uri.clone().into(),
            vec![public.to_string()].into(),
            vec![followers_uri.clone()].into(),
        ],
    )
    .expect("failed to insert activity");

    // Queue delivery to all followers
    Spi::run_with_args(
        "INSERT INTO ap_deliveries (activity_id, inbox_uri)
         SELECT $1, COALESCE(a.shared_inbox_uri, a.inbox_uri)
         FROM ap_follows f
         JOIN ap_actors a ON a.id = f.follower_id
         WHERE f.following_id = $2 AND f.accepted = true
         AND a.domain IS NOT NULL",
        &[activity_id.into(), actor_id.into()],
    )
    .expect("failed to queue deliveries");

    object_uri
}

// =============================================================================
// Inbox processing
// =============================================================================

/// Main inbox entry point. Receives raw ActivityStreams JSON, classifies it,
/// and dispatches to the appropriate handler.
/// Returns the activity URI on success.
#[pg_extern]
fn ap_process_inbox_activity(body: pgrx::Json) -> String {
    let obj = &body.0;

    let activity_type = json_str(obj, "type").expect("activity missing 'type'");
    let activity_uri = json_str(obj, "id");
    let actor_uri = json_str(obj, "actor").expect("activity missing 'actor'");

    // Check domain block
    if let Some(domain) = crate::util::parse_domain(&actor_uri) {
        let blocked = Spi::get_one_with_args::<bool>(
            "SELECT EXISTS(SELECT 1 FROM ap_blocks WHERE blocked_domain = $1)",
            &[domain.into()],
        )
        .unwrap_or(Some(false));

        if blocked == Some(true) {
            return String::new();
        }
    }

    // De-duplicate: skip if we've already processed this activity
    if let Some(ref uri) = activity_uri {
        let already = Spi::get_one_with_args::<bool>(
            "SELECT EXISTS(SELECT 1 FROM ap_activities WHERE uri = $1 AND processed = true)",
            &[uri.clone().into()],
        )
        .unwrap_or(Some(false));

        if already == Some(true) {
            return uri.clone();
        }
    }

    // Resolve the actor (must exist or be fetchable)
    let actor_id = resolve_actor_id(&actor_uri);

    // Extract addressing
    let to_uris = json_str_array(obj, "to");
    let cc_uris = json_str_array(obj, "cc");

    // Extract object URI (could be a string or an object with an "id")
    let object_uri = obj.get("object").and_then(|v| {
        if v.is_string() {
            v.as_str().map(|s| s.to_string())
        } else {
            json_str(v, "id")
        }
    });

    let target_uri = json_str(obj, "target");

    // Store the activity
    let stored_id = Spi::get_one_with_args::<i64>(
        "INSERT INTO ap_activities (uri, activity_type, actor_id, object_uri, target_uri,
            to_uris, cc_uris, raw, local, processed)
         VALUES ($1, $2::ApActivityType, $3, $4, $5, $6, $7, $8, false, false)
         ON CONFLICT (uri) DO UPDATE SET processed = false
         RETURNING id",
        &[
            activity_uri.clone().into(),
            activity_type.clone().into(),
            actor_id.into(),
            object_uri.clone().into(),
            target_uri.into(),
            to_uris.into(),
            cc_uris.into(),
            pgrx::JsonB(obj.clone()).into(),
        ],
    )
    .expect("failed to store activity")
    .expect("no activity id returned");

    // Dispatch to handler
    match activity_type.as_str() {
        "Follow" => process_follow(stored_id, actor_id, obj),
        "Like" => process_like(stored_id, actor_id, &object_uri),
        "Announce" => process_announce(stored_id, actor_id, &object_uri),
        "Undo" => process_undo(actor_id, obj),
        "Create" => process_create(actor_id, obj),
        "Update" => process_update(actor_id, obj),
        "Delete" => process_delete(actor_id, &object_uri),
        "Accept" => process_accept(actor_id, obj),
        "Reject" => process_reject(actor_id, obj),
        "Block" => process_block(stored_id, actor_id, &object_uri),
        _ => {
            pgrx::warning!("unhandled activity type: {}", activity_type);
        }
    }

    // Mark processed
    Spi::run_with_args(
        "UPDATE ap_activities SET processed = true WHERE id = $1",
        &[stored_id.into()],
    )
    .expect("failed to mark activity processed");

    activity_uri.unwrap_or_default()
}

// =============================================================================
// Activity handlers
// =============================================================================

fn process_follow(_activity_id: i64, follower_actor_id: i64, activity: &serde_json::Value) {
    let object_uri = activity
        .get("object")
        .and_then(|v| {
            if v.is_string() {
                v.as_str().map(|s| s.to_string())
            } else {
                json_str(v, "id")
            }
        })
        .expect("Follow activity missing 'object'");

    let activity_uri = json_str(activity, "id");

    // The object of a Follow is the actor being followed
    let following_id = Spi::get_one_with_args::<i64>(
        "SELECT id FROM ap_actors WHERE uri = $1",
        &[object_uri.clone().into()],
    )
    .expect("failed to query target actor")
    .expect("Follow target actor not found");

    // Insert or update the follow
    Spi::run_with_args(
        "INSERT INTO ap_follows (follower_id, following_id, uri, accepted)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (follower_id, following_id) DO UPDATE SET
            accepted = EXCLUDED.accepted,
            uri = COALESCE(EXCLUDED.uri, ap_follows.uri)",
        &[
            follower_actor_id.into(),
            following_id.into(),
            activity_uri.into(),
            AUTO_ACCEPT_FOLLOWS.get().into(),
        ],
    )
    .expect("failed to insert follow");

    // If auto-accept, send an Accept back
    if AUTO_ACCEPT_FOLLOWS.get() {
        let base = base_url();

        // Get the followed actor's info
        let followed_username = Spi::get_one_with_args::<String>(
            "SELECT username FROM ap_actors WHERE id = $1 AND domain IS NULL",
            &[following_id.into()],
        )
        .ok()
        .flatten();

        // Only send Accept if the followed actor is local
        if let Some(username) = followed_username {
            let followed_uri = format!("{}/users/{}", base, username);
            let follower_inbox = Spi::get_one_with_args::<String>(
                "SELECT inbox_uri FROM ap_actors WHERE id = $1",
                &[follower_actor_id.into()],
            )
            .unwrap()
            .unwrap();

            // Create the Accept activity
            let accept_id = Spi::get_one::<i64>("SELECT nextval('ap_activities_id_seq')")
                .unwrap()
                .unwrap();
            let accept_uri = format!("{}/activities/{}", followed_uri, accept_id);

            let accept_json = json!({
                "@context": "https://www.w3.org/ns/activitystreams",
                "id": accept_uri,
                "type": "Accept",
                "actor": followed_uri,
                "object": activity
            });

            Spi::run_with_args(
                "INSERT INTO ap_activities (id, uri, activity_type, actor_id, object_uri,
                    raw, local, processed)
                 VALUES ($1, $2, 'Accept', $3, $4, $5, true, true)",
                &[
                    accept_id.into(),
                    accept_uri.into(),
                    following_id.into(),
                    json_str(activity, "id").into(),
                    pgrx::JsonB(accept_json).into(),
                ],
            )
            .expect("failed to insert Accept activity");

            // Queue delivery of the Accept
            Spi::run_with_args(
                "INSERT INTO ap_deliveries (activity_id, inbox_uri) VALUES ($1, $2)",
                &[accept_id.into(), follower_inbox.into()],
            )
            .expect("failed to queue Accept delivery");
        }
    }
}

fn process_like(_activity_id: i64, actor_id: i64, object_uri: &Option<String>) {
    let object_uri = object_uri.as_ref().expect("Like activity missing 'object'");

    // Look up the object
    let object_id = Spi::get_one_with_args::<i64>(
        "SELECT id FROM ap_objects WHERE uri = $1",
        &[object_uri.clone().into()],
    )
    .ok()
    .flatten();

    if let Some(oid) = object_id {
        Spi::run_with_args(
            "INSERT INTO ap_likes (actor_id, object_id, uri)
             VALUES ($1, $2, $3)
             ON CONFLICT (actor_id, object_id) DO NOTHING",
            &[actor_id.into(), oid.into(), Option::<String>::None.into()],
        )
        .expect("failed to insert like");
    }
}

fn process_announce(_activity_id: i64, actor_id: i64, object_uri: &Option<String>) {
    let object_uri = object_uri
        .as_ref()
        .expect("Announce activity missing 'object'");

    let object_id = Spi::get_one_with_args::<i64>(
        "SELECT id FROM ap_objects WHERE uri = $1",
        &[object_uri.clone().into()],
    )
    .ok()
    .flatten();

    if let Some(oid) = object_id {
        Spi::run_with_args(
            "INSERT INTO ap_announces (actor_id, object_id, uri)
             VALUES ($1, $2, $3)
             ON CONFLICT (actor_id, object_id) DO NOTHING",
            &[actor_id.into(), oid.into(), Option::<String>::None.into()],
        )
        .expect("failed to insert announce");
    }
}

fn process_undo(actor_id: i64, activity: &serde_json::Value) {
    let inner = activity.get("object").expect("Undo missing 'object'");

    let inner_type = if inner.is_string() {
        // Object is a URI reference — look up the original activity type
        let uri = inner.as_str().unwrap();
        Spi::get_one_with_args::<String>(
            "SELECT activity_type::text FROM ap_activities WHERE uri = $1",
            &[uri.into()],
        )
        .ok()
        .flatten()
        .unwrap_or_default()
    } else {
        json_str(inner, "type").unwrap_or_default()
    };

    match inner_type.as_str() {
        "Follow" => {
            let target_uri = if inner.is_string() {
                Spi::get_one_with_args::<String>(
                    "SELECT object_uri FROM ap_activities WHERE uri = $1",
                    &[inner.as_str().unwrap().into()],
                )
                .ok()
                .flatten()
            } else {
                inner.get("object").and_then(|v| {
                    if v.is_string() {
                        v.as_str().map(|s| s.to_string())
                    } else {
                        json_str(v, "id")
                    }
                })
            };

            if let Some(target) = target_uri {
                Spi::run_with_args(
                    "DELETE FROM ap_follows
                     WHERE follower_id = $1
                     AND following_id = (SELECT id FROM ap_actors WHERE uri = $2)",
                    &[actor_id.into(), target.into()],
                )
                .expect("failed to undo follow");
            }
        }
        "Like" => {
            let object_uri = if inner.is_string() {
                Spi::get_one_with_args::<String>(
                    "SELECT object_uri FROM ap_activities WHERE uri = $1",
                    &[inner.as_str().unwrap().into()],
                )
                .ok()
                .flatten()
            } else {
                inner.get("object").and_then(|v| {
                    if v.is_string() {
                        v.as_str().map(|s| s.to_string())
                    } else {
                        json_str(v, "id")
                    }
                })
            };

            if let Some(obj_uri) = object_uri {
                Spi::run_with_args(
                    "DELETE FROM ap_likes
                     WHERE actor_id = $1
                     AND object_id = (SELECT id FROM ap_objects WHERE uri = $2)",
                    &[actor_id.into(), obj_uri.into()],
                )
                .expect("failed to undo like");
            }
        }
        "Announce" => {
            let object_uri = if inner.is_string() {
                Spi::get_one_with_args::<String>(
                    "SELECT object_uri FROM ap_activities WHERE uri = $1",
                    &[inner.as_str().unwrap().into()],
                )
                .ok()
                .flatten()
            } else {
                inner.get("object").and_then(|v| {
                    if v.is_string() {
                        v.as_str().map(|s| s.to_string())
                    } else {
                        json_str(v, "id")
                    }
                })
            };

            if let Some(obj_uri) = object_uri {
                Spi::run_with_args(
                    "DELETE FROM ap_announces
                     WHERE actor_id = $1
                     AND object_id = (SELECT id FROM ap_objects WHERE uri = $2)",
                    &[actor_id.into(), obj_uri.into()],
                )
                .expect("failed to undo announce");
            }
        }
        _ => {
            pgrx::warning!("Undo of unsupported type: {}", inner_type);
        }
    }
}

fn process_create(actor_id: i64, activity: &serde_json::Value) {
    let inner = activity.get("object").expect("Create missing 'object'");

    if !inner.is_object() {
        return;
    }

    let object_type = json_str(inner, "type").unwrap_or_default();
    let pg_type = match object_type.as_str() {
        "Note" | "Article" | "Page" | "Image" | "Video" | "Audio" | "Event" | "Question"
        | "Document" => object_type.as_str(),
        _ => return,
    };

    let object_uri = json_str(inner, "id").expect("object missing 'id'");
    let content = json_str(inner, "content");
    let content_text = content.as_ref().map(|c| strip_html(c));
    let summary_val = json_str(inner, "summary");
    let url = json_str(inner, "url");
    let in_reply_to = json_str(inner, "inReplyTo");
    let conversation = json_str(inner, "conversation").or_else(|| json_str(inner, "context"));
    let published = json_str(inner, "published");
    let sensitive = inner
        .get("sensitive")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let language = inner
        .get("contentMap")
        .and_then(|v| v.as_object())
        .and_then(|m| m.keys().next().cloned());

    Spi::run_with_args(
        "INSERT INTO ap_objects (uri, object_type, actor_id, content, content_text,
            summary, url, in_reply_to_uri, conversation_uri, visibility,
            sensitive, language, published_at, raw)
         VALUES ($1, $2::ApObjectType, $3, $4, $5, $6, $7, $8, $9, 'Public',
            $10, $11, CASE WHEN $12 IS NOT NULL THEN $12::timestamptz ELSE now() END,
            $13)
         ON CONFLICT (uri) DO NOTHING",
        &[
            object_uri.into(),
            pg_type.to_string().into(),
            actor_id.into(),
            content.into(),
            content_text.into(),
            summary_val.into(),
            url.into(),
            in_reply_to.into(),
            conversation.into(),
            sensitive.into(),
            language.into(),
            published.into(),
            pgrx::JsonB(inner.clone()).into(),
        ],
    )
    .expect("failed to insert remote object");
}

fn process_update(actor_id: i64, activity: &serde_json::Value) {
    let inner = activity.get("object").expect("Update missing 'object'");

    if !inner.is_object() {
        return;
    }

    let object_uri = json_str(inner, "id").expect("object missing 'id'");
    let content = json_str(inner, "content");
    let content_text = content.as_ref().map(|c| strip_html(c));
    let summary_val = json_str(inner, "summary");
    let sensitive = inner.get("sensitive").and_then(|v| v.as_bool());

    // Only update if the object belongs to this actor
    Spi::run_with_args(
        "UPDATE ap_objects SET
            content = COALESCE($2, content),
            content_text = COALESCE($3, content_text),
            summary = COALESCE($4, summary),
            sensitive = COALESCE($5, sensitive),
            edited_at = now(),
            raw = $6
         WHERE uri = $1 AND actor_id = $7",
        &[
            object_uri.into(),
            content.into(),
            content_text.into(),
            summary_val.into(),
            sensitive.into(),
            pgrx::JsonB(inner.clone()).into(),
            actor_id.into(),
        ],
    )
    .expect("failed to update object");
}

fn process_delete(actor_id: i64, object_uri: &Option<String>) {
    let object_uri = object_uri
        .as_ref()
        .expect("Delete activity missing 'object'");

    // Soft-delete: only if owned by this actor
    Spi::run_with_args(
        "UPDATE ap_objects SET deleted_at = now(), content = NULL, content_text = NULL
         WHERE uri = $1 AND actor_id = $2",
        &[object_uri.clone().into(), actor_id.into()],
    )
    .expect("failed to delete object");
}

fn process_accept(_actor_id: i64, activity: &serde_json::Value) {
    let inner = activity.get("object").expect("Accept missing 'object'");

    // The object of an Accept is typically the Follow activity that was accepted
    let follow_uri = if inner.is_string() {
        inner.as_str().map(|s| s.to_string())
    } else {
        json_str(inner, "id")
    };

    if let Some(uri) = follow_uri {
        // Accept the follow using the Follow activity's URI
        Spi::run_with_args(
            "UPDATE ap_follows SET accepted = true WHERE uri = $1",
            &[uri.into()],
        )
        .expect("failed to accept follow");
    }
}

fn process_reject(_actor_id: i64, activity: &serde_json::Value) {
    let inner = activity.get("object").expect("Reject missing 'object'");

    let follow_uri = if inner.is_string() {
        inner.as_str().map(|s| s.to_string())
    } else {
        json_str(inner, "id")
    };

    if let Some(uri) = follow_uri {
        // Remove the follow
        Spi::run_with_args("DELETE FROM ap_follows WHERE uri = $1", &[uri.into()])
            .expect("failed to reject follow");
    }
}

fn process_block(_activity_id: i64, actor_id: i64, object_uri: &Option<String>) {
    let blocked_uri = object_uri
        .as_ref()
        .expect("Block activity missing 'object'");

    let blocked_actor_id = Spi::get_one_with_args::<i64>(
        "SELECT id FROM ap_actors WHERE uri = $1",
        &[blocked_uri.clone().into()],
    )
    .ok()
    .flatten();

    if let Some(blocked_id) = blocked_actor_id {
        Spi::run_with_args(
            "INSERT INTO ap_blocks (actor_id, blocked_actor_id)
             VALUES ($1, $2)
             ON CONFLICT DO NOTHING",
            &[actor_id.into(), blocked_id.into()],
        )
        .ok();

        // Also remove any existing follow relationship
        Spi::run_with_args(
            "DELETE FROM ap_follows
             WHERE (follower_id = $1 AND following_id = $2)
                OR (follower_id = $2 AND following_id = $1)",
            &[actor_id.into(), blocked_id.into()],
        )
        .ok();
    }
}

// =============================================================================
// Helpers
// =============================================================================

/// Resolve an actor URI to a database ID, creating a stub if needed.
fn resolve_actor_id(actor_uri: &str) -> i64 {
    // Try to find existing
    let existing = Spi::get_one_with_args::<i64>(
        "SELECT id FROM ap_actors WHERE uri = $1",
        &[actor_uri.into()],
    )
    .ok()
    .flatten();

    if let Some(id) = existing {
        return id;
    }

    // Create a stub for the remote actor — will be fully fetched later
    let domain = crate::util::parse_domain(actor_uri).unwrap_or_default();
    let username = actor_uri.rsplit('/').next().unwrap_or("unknown");

    Spi::get_one_with_args::<i64>(
        "INSERT INTO ap_actors (uri, actor_type, username, domain, inbox_uri, outbox_uri)
         VALUES ($1, 'Person', $2, $3, $4, $5)
         ON CONFLICT (uri) DO UPDATE SET uri = EXCLUDED.uri
         RETURNING id",
        &[
            actor_uri.into(),
            username.into(),
            domain.into(),
            format!("{}/inbox", actor_uri).into(),
            format!("{}/outbox", actor_uri).into(),
        ],
    )
    .expect("failed to create actor stub")
    .expect("no actor id returned")
}

/// Extract an array of strings from a JSON field.
fn json_str_array(obj: &serde_json::Value, key: &str) -> Option<Vec<String>> {
    obj.get(key).and_then(|v| {
        if let Some(arr) = v.as_array() {
            let strings: Vec<String> = arr
                .iter()
                .filter_map(|item| item.as_str().map(|s| s.to_string()))
                .collect();
            if strings.is_empty() {
                None
            } else {
                Some(strings)
            }
        } else if let Some(s) = v.as_str() {
            Some(vec![s.to_string()])
        } else {
            None
        }
    })
}

/// Naive HTML tag stripping for generating plain text content.
fn strip_html(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut in_tag = false;
    for ch in html.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => result.push(ch),
            _ => {}
        }
    }
    result
}
