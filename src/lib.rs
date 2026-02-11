use pgrx::prelude::*;

mod activities;
mod actors;
mod admin;
mod crypto;
mod delivery;
mod guc;
mod nodeinfo;
mod schema;
mod serialization;
mod types;
mod util;
mod webfinger;

::pgrx::pg_module_magic!(name, version);

#[allow(non_snake_case)]
#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    guc::register_gucs();
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    // Helper to set up the test domain
    fn setup_domain() {
        Spi::run("SET pg_fedi.domain = 'test.example'").unwrap();
        Spi::run("SET pg_fedi.https = true").unwrap();
        Spi::run("SET pg_fedi.auto_accept_follows = true").unwrap();
    }

    // -- Phase 1: Schema tests ------------------------------------------------

    #[pg_test]
    fn test_extension_loads() {
        let result = Spi::get_one::<i64>("SELECT count(*) FROM ap_actors");
        assert_eq!(result, Ok(Some(0)));
    }

    #[pg_test]
    fn test_tables_exist() {
        let tables = vec![
            "ap_actors",
            "ap_keys",
            "ap_objects",
            "ap_activities",
            "ap_follows",
            "ap_likes",
            "ap_announces",
            "ap_blocks",
            "ap_deliveries",
            "ap_actor_stats",
        ];
        for table in tables {
            let exists = Spi::get_one::<bool>(&format!(
                "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = '{}')",
                table
            ));
            assert_eq!(exists, Ok(Some(true)), "Table {} should exist", table);
        }
    }

    #[pg_test]
    fn test_views_exist() {
        let views = vec!["ap_local_actors", "ap_public_timeline", "ap_local_timeline"];
        for view in views {
            let exists = Spi::get_one::<bool>(&format!(
                "SELECT EXISTS (SELECT 1 FROM information_schema.views WHERE table_name = '{}')",
                view
            ));
            assert_eq!(exists, Ok(Some(true)), "View {} should exist", view);
        }
    }

    #[pg_test]
    fn test_enum_types_exist() {
        let result = Spi::get_one::<bool>("SELECT 'Person'::ApActorType IS NOT NULL");
        assert_eq!(result, Ok(Some(true)));
        let result = Spi::get_one::<bool>("SELECT 'Create'::ApActivityType IS NOT NULL");
        assert_eq!(result, Ok(Some(true)));
        let result = Spi::get_one::<bool>("SELECT 'Note'::ApObjectType IS NOT NULL");
        assert_eq!(result, Ok(Some(true)));
        let result = Spi::get_one::<bool>("SELECT 'Public'::ApVisibility IS NOT NULL");
        assert_eq!(result, Ok(Some(true)));
        let result = Spi::get_one::<bool>("SELECT 'Queued'::ApDeliveryStatus IS NOT NULL");
        assert_eq!(result, Ok(Some(true)));
    }

    #[pg_test]
    fn test_stats_trigger() {
        Spi::run(
            "INSERT INTO ap_actors (uri, actor_type, username, inbox_uri, outbox_uri)
             VALUES ('https://example.com/users/test', 'Person', 'test',
                     'https://example.com/users/test/inbox',
                     'https://example.com/users/test/outbox')",
        )
        .expect("insert actor");

        let count = Spi::get_one::<i64>(
            "SELECT statuses_count FROM ap_actor_stats
             WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'test')",
        );
        assert_eq!(count, Ok(Some(0)));
    }

    // -- Phase 2: Crypto tests ------------------------------------------------

    #[pg_test]
    fn test_generate_keypair() {
        let result = Spi::get_two::<String, String>("SELECT * FROM ap_generate_keypair()");
        let (public_pem, private_pem) = result.unwrap();
        let public_pem = public_pem.unwrap();
        let private_pem = private_pem.unwrap();

        assert!(
            public_pem.starts_with("-----BEGIN PUBLIC KEY-----"),
            "public key should be SPKI PEM"
        );
        assert!(
            private_pem.starts_with("-----BEGIN PRIVATE KEY-----"),
            "private key should be PKCS#8 PEM"
        );
    }

    // -- Phase 2: Actor tests -------------------------------------------------

    #[pg_test]
    fn test_create_local_actor() {
        setup_domain();

        let uri =
            Spi::get_one::<String>("SELECT ap_create_local_actor('alice', 'Alice', 'Hello!')")
                .unwrap()
                .unwrap();

        assert_eq!(uri, "https://test.example/users/alice");

        let username = Spi::get_one::<String>(
            "SELECT username FROM ap_actors WHERE uri = 'https://test.example/users/alice'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(username, "alice");

        let has_key = Spi::get_one::<bool>(
            "SELECT EXISTS(SELECT 1 FROM ap_keys WHERE key_id = 'https://test.example/users/alice#main-key')",
        )
        .unwrap()
        .unwrap();
        assert!(has_key);

        let has_private = Spi::get_one::<bool>(
            "SELECT private_key_pem IS NOT NULL FROM ap_keys
             WHERE key_id = 'https://test.example/users/alice#main-key'",
        )
        .unwrap()
        .unwrap();
        assert!(has_private);

        let stats = Spi::get_one::<i64>(
            "SELECT followers_count FROM ap_actor_stats
             WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'alice')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(stats, 0);
    }

    #[pg_test]
    fn test_serialize_actor() {
        setup_domain();

        Spi::run("SELECT ap_create_local_actor('bob', 'Bob', '<p>Hi</p>')").unwrap();

        let json = Spi::get_one::<pgrx::Json>("SELECT ap_serialize_actor('bob')")
            .unwrap()
            .unwrap();
        let doc = &json.0;

        assert_eq!(doc["id"], "https://test.example/users/bob");
        assert_eq!(doc["type"], "Person");
        assert_eq!(doc["preferredUsername"], "bob");
        assert_eq!(doc["name"], "Bob");
        assert_eq!(doc["inbox"], "https://test.example/users/bob/inbox");
        assert_eq!(doc["outbox"], "https://test.example/users/bob/outbox");
        assert!(doc["@context"].is_array());
        assert_eq!(
            doc["publicKey"]["id"],
            "https://test.example/users/bob#main-key"
        );
        assert!(doc["publicKey"]["publicKeyPem"]
            .as_str()
            .unwrap()
            .starts_with("-----BEGIN PUBLIC KEY-----"));
        assert_eq!(
            doc["endpoints"]["sharedInbox"],
            "https://test.example/inbox"
        );
    }

    #[pg_test]
    fn test_upsert_remote_actor() {
        setup_domain();

        let remote_json = serde_json::json!({
            "@context": "https://www.w3.org/ns/activitystreams",
            "id": "https://remote.example/users/carol",
            "type": "Person",
            "preferredUsername": "carol",
            "name": "Carol",
            "summary": "Remote user",
            "inbox": "https://remote.example/users/carol/inbox",
            "outbox": "https://remote.example/users/carol/outbox",
            "followers": "https://remote.example/users/carol/followers",
            "following": "https://remote.example/users/carol/following",
            "manuallyApprovesFollowers": false,
            "discoverable": true,
            "publicKey": {
                "id": "https://remote.example/users/carol#main-key",
                "owner": "https://remote.example/users/carol",
                "publicKeyPem": "-----BEGIN PUBLIC KEY-----\nFAKEKEY\n-----END PUBLIC KEY-----"
            },
            "endpoints": {
                "sharedInbox": "https://remote.example/inbox"
            }
        });

        let uri = Spi::get_one_with_args::<String>(
            "SELECT ap_upsert_remote_actor($1::json)",
            &[pgrx::Json(remote_json.clone()).into()],
        )
        .unwrap()
        .unwrap();
        assert_eq!(uri, "https://remote.example/users/carol");

        let domain =
            Spi::get_one::<String>("SELECT domain FROM ap_actors WHERE username = 'carol'")
                .unwrap()
                .unwrap();
        assert_eq!(domain, "remote.example");

        let pk = Spi::get_one::<String>(
            "SELECT public_key_pem FROM ap_keys
             WHERE key_id = 'https://remote.example/users/carol#main-key'",
        )
        .unwrap()
        .unwrap();
        assert!(pk.contains("FAKEKEY"));

        // Upsert update path
        let mut updated_json = remote_json;
        updated_json["name"] = serde_json::json!("Carol Updated");
        Spi::run_with_args(
            "SELECT ap_upsert_remote_actor($1::json)",
            &[pgrx::Json(updated_json).into()],
        )
        .unwrap();

        let display =
            Spi::get_one::<String>("SELECT display_name FROM ap_actors WHERE username = 'carol'")
                .unwrap()
                .unwrap();
        assert_eq!(display, "Carol Updated");
    }

    // -- Phase 2: WebFinger tests ---------------------------------------------

    #[pg_test]
    fn test_webfinger() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('dave', 'Dave', NULL)").unwrap();

        let json = Spi::get_one::<pgrx::Json>("SELECT ap_webfinger('acct:dave@test.example')")
            .unwrap()
            .unwrap();
        let doc = &json.0;

        assert_eq!(doc["subject"], "acct:dave@test.example");
        assert!(doc["links"].is_array());
        let self_link = doc["links"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["rel"] == "self")
            .expect("should have self link");
        assert_eq!(self_link["href"], "https://test.example/users/dave");
        assert_eq!(self_link["type"], "application/activity+json");
    }

    #[pg_test]
    fn test_host_meta() {
        setup_domain();
        let xml = Spi::get_one::<String>("SELECT ap_host_meta()")
            .unwrap()
            .unwrap();
        assert!(xml.contains("XRD"));
        assert!(xml.contains("test.example"));
    }

    // -- Phase 3: Note creation -----------------------------------------------

    #[pg_test]
    fn test_create_note() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('poster', 'Poster', NULL)").unwrap();

        let note_uri = Spi::get_one::<String>(
            "SELECT ap_create_note('poster', '<p>Hello fediverse!</p>', NULL, NULL)",
        )
        .unwrap()
        .unwrap();

        assert!(note_uri.starts_with("https://test.example/users/poster/objects/"));

        // Verify the object was stored
        let content = Spi::get_one_with_args::<String>(
            "SELECT content FROM ap_objects WHERE uri = $1",
            &[note_uri.clone().into()],
        )
        .unwrap()
        .unwrap();
        assert_eq!(content, "<p>Hello fediverse!</p>");

        // Verify the Create activity was created
        let activity_exists = Spi::get_one_with_args::<bool>(
            "SELECT EXISTS(SELECT 1 FROM ap_activities WHERE object_uri = $1 AND activity_type = 'Create')",
            &[note_uri.clone().into()],
        )
        .unwrap()
        .unwrap();
        assert!(activity_exists);

        // Verify status count was incremented
        let status_count = Spi::get_one::<i64>(
            "SELECT statuses_count FROM ap_actor_stats
             WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'poster')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(status_count, 1);
    }

    // -- Phase 3: Follow processing -------------------------------------------

    #[pg_test]
    fn test_inbox_follow_auto_accept() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('local_user', 'Local', NULL)").unwrap();

        // Insert a remote actor
        let remote_json = serde_json::json!({
            "id": "https://remote.example/users/remote_user",
            "type": "Person",
            "preferredUsername": "remote_user",
            "inbox": "https://remote.example/users/remote_user/inbox",
            "outbox": "https://remote.example/users/remote_user/outbox",
            "publicKey": {
                "id": "https://remote.example/users/remote_user#main-key",
                "owner": "https://remote.example/users/remote_user",
                "publicKeyPem": "-----BEGIN PUBLIC KEY-----\nFAKE\n-----END PUBLIC KEY-----"
            }
        });
        Spi::run_with_args(
            "SELECT ap_upsert_remote_actor($1::json)",
            &[pgrx::Json(remote_json).into()],
        )
        .unwrap();

        // Send a Follow activity
        let follow_json = serde_json::json!({
            "@context": "https://www.w3.org/ns/activitystreams",
            "id": "https://remote.example/activities/follow-1",
            "type": "Follow",
            "actor": "https://remote.example/users/remote_user",
            "object": "https://test.example/users/local_user"
        });

        Spi::run_with_args(
            "SELECT ap_process_inbox_activity($1::json)",
            &[pgrx::Json(follow_json).into()],
        )
        .unwrap();

        // Verify follow was created and accepted
        let accepted = Spi::get_one::<bool>(
            "SELECT accepted FROM ap_follows
             WHERE follower_id = (SELECT id FROM ap_actors WHERE uri = 'https://remote.example/users/remote_user')
             AND following_id = (SELECT id FROM ap_actors WHERE username = 'local_user')",
        )
        .unwrap()
        .unwrap();
        assert!(accepted);

        // Verify Accept activity was created
        let accept_exists = Spi::get_one::<bool>(
            "SELECT EXISTS(SELECT 1 FROM ap_activities
             WHERE activity_type = 'Accept' AND local = true)",
        )
        .unwrap()
        .unwrap();
        assert!(accept_exists);

        // Verify Accept was queued for delivery
        let delivery_exists = Spi::get_one::<bool>(
            "SELECT EXISTS(SELECT 1 FROM ap_deliveries
             WHERE inbox_uri = 'https://remote.example/users/remote_user/inbox')",
        )
        .unwrap()
        .unwrap();
        assert!(delivery_exists);

        // Verify follower count was updated
        let followers = Spi::get_one::<i64>(
            "SELECT followers_count FROM ap_actor_stats
             WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'local_user')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(followers, 1);
    }

    // -- Phase 3: Like processing ---------------------------------------------

    #[pg_test]
    fn test_inbox_like() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('author', 'Author', NULL)").unwrap();
        let note_uri = Spi::get_one::<String>(
            "SELECT ap_create_note('author', '<p>Like me!</p>', NULL, NULL)",
        )
        .unwrap()
        .unwrap();

        // Remote actor likes the note
        let like_json = serde_json::json!({
            "@context": "https://www.w3.org/ns/activitystreams",
            "id": "https://remote.example/activities/like-1",
            "type": "Like",
            "actor": "https://remote.example/users/liker",
            "object": note_uri
        });

        Spi::run_with_args(
            "SELECT ap_process_inbox_activity($1::json)",
            &[pgrx::Json(like_json).into()],
        )
        .unwrap();

        // Verify like was recorded
        let like_exists = Spi::get_one_with_args::<bool>(
            "SELECT EXISTS(SELECT 1 FROM ap_likes
             WHERE object_id = (SELECT id FROM ap_objects WHERE uri = $1))",
            &[note_uri.into()],
        )
        .unwrap()
        .unwrap();
        assert!(like_exists);
    }

    // -- Phase 3: Undo processing ---------------------------------------------

    #[pg_test]
    fn test_inbox_undo_follow() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('target', 'Target', NULL)").unwrap();

        // Set up remote actor
        let remote_json = serde_json::json!({
            "id": "https://remote.example/users/unfollower",
            "type": "Person",
            "preferredUsername": "unfollower",
            "inbox": "https://remote.example/users/unfollower/inbox",
            "outbox": "https://remote.example/users/unfollower/outbox"
        });
        Spi::run_with_args(
            "SELECT ap_upsert_remote_actor($1::json)",
            &[pgrx::Json(remote_json).into()],
        )
        .unwrap();

        // Follow first
        let follow_json = serde_json::json!({
            "id": "https://remote.example/activities/follow-2",
            "type": "Follow",
            "actor": "https://remote.example/users/unfollower",
            "object": "https://test.example/users/target"
        });
        Spi::run_with_args(
            "SELECT ap_process_inbox_activity($1::json)",
            &[pgrx::Json(follow_json).into()],
        )
        .unwrap();

        // Verify follow exists
        let follow_exists = Spi::get_one::<bool>(
            "SELECT EXISTS(SELECT 1 FROM ap_follows
             WHERE follower_id = (SELECT id FROM ap_actors WHERE uri = 'https://remote.example/users/unfollower'))",
        )
        .unwrap()
        .unwrap();
        assert!(follow_exists);

        // Now undo it
        let undo_json = serde_json::json!({
            "id": "https://remote.example/activities/undo-1",
            "type": "Undo",
            "actor": "https://remote.example/users/unfollower",
            "object": {
                "id": "https://remote.example/activities/follow-2",
                "type": "Follow",
                "actor": "https://remote.example/users/unfollower",
                "object": "https://test.example/users/target"
            }
        });
        Spi::run_with_args(
            "SELECT ap_process_inbox_activity($1::json)",
            &[pgrx::Json(undo_json).into()],
        )
        .unwrap();

        // Verify follow was removed
        let follow_gone = Spi::get_one::<bool>(
            "SELECT NOT EXISTS(SELECT 1 FROM ap_follows
             WHERE follower_id = (SELECT id FROM ap_actors WHERE uri = 'https://remote.example/users/unfollower')
             AND following_id = (SELECT id FROM ap_actors WHERE username = 'target'))",
        )
        .unwrap()
        .unwrap();
        assert!(follow_gone, "follow should be removed after Undo");
    }

    // -- Phase 3: Create (remote content) processing --------------------------

    #[pg_test]
    fn test_inbox_create_note() {
        setup_domain();

        let create_json = serde_json::json!({
            "id": "https://remote.example/activities/create-1",
            "type": "Create",
            "actor": "https://remote.example/users/writer",
            "object": {
                "id": "https://remote.example/objects/note-1",
                "type": "Note",
                "attributedTo": "https://remote.example/users/writer",
                "content": "<p>Hello from remote!</p>",
                "published": "2025-01-01T00:00:00Z",
                "to": ["https://www.w3.org/ns/activitystreams#Public"]
            }
        });

        Spi::run_with_args(
            "SELECT ap_process_inbox_activity($1::json)",
            &[pgrx::Json(create_json).into()],
        )
        .unwrap();

        // Verify the object was stored
        let content = Spi::get_one::<String>(
            "SELECT content FROM ap_objects WHERE uri = 'https://remote.example/objects/note-1'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(content, "<p>Hello from remote!</p>");

        // Verify plain text was generated
        let content_text = Spi::get_one::<String>(
            "SELECT content_text FROM ap_objects WHERE uri = 'https://remote.example/objects/note-1'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(content_text, "Hello from remote!");
    }

    // -- Phase 3: Delivery queue ----------------------------------------------

    #[pg_test]
    fn test_delivery_lifecycle() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('sender', 'Sender', NULL)").unwrap();

        // Create a note (which queues no deliveries since there are no followers)
        Spi::run("SELECT ap_create_note('sender', '<p>Test</p>', NULL, NULL)").unwrap();

        // Manually insert a delivery for testing
        Spi::run(
            "INSERT INTO ap_deliveries (activity_id, inbox_uri)
             SELECT id, 'https://remote.example/inbox'
             FROM ap_activities WHERE local = true LIMIT 1",
        )
        .unwrap();

        // Check delivery stats
        let queued =
            Spi::get_one::<i64>("SELECT count FROM ap_delivery_stats() WHERE status = 'Queued'")
                .unwrap()
                .unwrap();
        assert_eq!(queued, 1);

        // Mark failed
        let delivery_id = Spi::get_one::<i64>("SELECT id FROM ap_deliveries ORDER BY id LIMIT 1")
            .unwrap()
            .unwrap();

        Spi::run(&format!(
            "SELECT ap_delivery_failure({}, 'connection refused', 0)",
            delivery_id
        ))
        .unwrap();

        // Verify retry was scheduled
        let status = Spi::get_one_with_args::<String>(
            "SELECT status::text FROM ap_deliveries WHERE id = $1",
            &[delivery_id.into()],
        )
        .unwrap()
        .unwrap();
        assert_eq!(status, "Failed");

        let attempts = Spi::get_one_with_args::<i32>(
            "SELECT attempts FROM ap_deliveries WHERE id = $1",
            &[delivery_id.into()],
        )
        .unwrap()
        .unwrap();
        assert_eq!(attempts, 1);
    }

    // -- Phase 3: Collection serialization ------------------------------------

    #[pg_test]
    fn test_serialize_outbox() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('collector', 'Collector', NULL)").unwrap();
        Spi::run("SELECT ap_create_note('collector', '<p>Post 1</p>', NULL, NULL)").unwrap();
        Spi::run("SELECT ap_create_note('collector', '<p>Post 2</p>', NULL, NULL)").unwrap();

        // Collection summary (no page)
        let summary = Spi::get_one::<pgrx::Json>("SELECT ap_serialize_outbox('collector', NULL)")
            .unwrap()
            .unwrap();
        assert_eq!(summary.0["type"], "OrderedCollection");
        assert_eq!(summary.0["totalItems"], 2);

        // Page 1
        let page = Spi::get_one::<pgrx::Json>("SELECT ap_serialize_outbox('collector', 1)")
            .unwrap()
            .unwrap();
        assert_eq!(page.0["type"], "OrderedCollectionPage");
        assert!(page.0["orderedItems"].is_array());
    }

    #[pg_test]
    fn test_serialize_followers() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('popular', 'Popular', NULL)").unwrap();

        let summary = Spi::get_one::<pgrx::Json>("SELECT ap_serialize_followers('popular', NULL)")
            .unwrap()
            .unwrap();
        assert_eq!(summary.0["type"], "OrderedCollection");
        assert_eq!(summary.0["totalItems"], 0);
    }

    // -- Phase 4: Activity serialization --------------------------------------

    #[pg_test]
    fn test_serialize_activity() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('serializer', 'Serializer', NULL)").unwrap();
        Spi::run("SELECT ap_create_note('serializer', '<p>Serialize me!</p>', NULL, NULL)")
            .unwrap();

        // Get the activity URI
        let activity_uri = Spi::get_one::<String>(
            "SELECT uri FROM ap_activities WHERE local = true AND activity_type = 'Create' LIMIT 1",
        )
        .unwrap()
        .unwrap();

        let json = Spi::get_one_with_args::<pgrx::Json>(
            "SELECT ap_serialize_activity($1)",
            &[activity_uri.into()],
        )
        .unwrap()
        .unwrap();
        let doc = &json.0;

        assert_eq!(doc["type"], "Create");
        assert!(doc["actor"].as_str().unwrap().contains("serializer"));
        assert!(doc["@context"].is_string() || doc["@context"].is_array());
    }

    #[pg_test]
    fn test_serialize_activity_from_inbox() {
        setup_domain();

        // Process an inbound Follow so it gets stored with raw JSON
        let remote_json = serde_json::json!({
            "id": "https://remote.example/users/actor4",
            "type": "Person",
            "preferredUsername": "actor4",
            "inbox": "https://remote.example/users/actor4/inbox",
            "outbox": "https://remote.example/users/actor4/outbox"
        });
        Spi::run_with_args(
            "SELECT ap_upsert_remote_actor($1::json)",
            &[pgrx::Json(remote_json).into()],
        )
        .unwrap();

        Spi::run("SELECT ap_create_local_actor('target4', 'Target4', NULL)").unwrap();

        let follow_json = serde_json::json!({
            "@context": "https://www.w3.org/ns/activitystreams",
            "id": "https://remote.example/activities/follow-serialize",
            "type": "Follow",
            "actor": "https://remote.example/users/actor4",
            "object": "https://test.example/users/target4"
        });
        Spi::run_with_args(
            "SELECT ap_process_inbox_activity($1::json)",
            &[pgrx::Json(follow_json).into()],
        )
        .unwrap();

        // Now serialize the stored activity — it should use the raw JSON
        let json = Spi::get_one::<pgrx::Json>(
            "SELECT ap_serialize_activity('https://remote.example/activities/follow-serialize')",
        )
        .unwrap()
        .unwrap();
        let doc = &json.0;

        assert_eq!(doc["type"], "Follow");
        assert_eq!(doc["actor"], "https://remote.example/users/actor4");
        assert_eq!(doc["@context"], "https://www.w3.org/ns/activitystreams");
    }

    // -- Phase 4: NodeInfo ----------------------------------------------------

    #[pg_test]
    fn test_nodeinfo_discovery() {
        setup_domain();

        let json = Spi::get_one::<pgrx::Json>("SELECT ap_nodeinfo_discovery()")
            .unwrap()
            .unwrap();
        let doc = &json.0;

        assert!(doc["links"].is_array());
        let links = doc["links"].as_array().unwrap();
        assert_eq!(links.len(), 1);
        assert_eq!(
            links[0]["rel"],
            "http://nodeinfo.diaspora.software/ns/schema/2.0"
        );
        assert!(links[0]["href"]
            .as_str()
            .unwrap()
            .ends_with("/nodeinfo/2.0"));
    }

    #[pg_test]
    fn test_nodeinfo() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('nodeuser', 'Node User', NULL)").unwrap();
        Spi::run("SELECT ap_create_note('nodeuser', '<p>NodeInfo test</p>', NULL, NULL)").unwrap();

        let json = Spi::get_one::<pgrx::Json>("SELECT ap_nodeinfo()")
            .unwrap()
            .unwrap();
        let doc = &json.0;

        assert_eq!(doc["version"], "2.0");
        assert_eq!(doc["software"]["name"], "pg_fedi");
        assert_eq!(doc["software"]["version"], "0.1.0");
        assert!(doc["protocols"]
            .as_array()
            .unwrap()
            .contains(&serde_json::json!("activitypub")));
        assert_eq!(doc["usage"]["users"]["total"], 1);
        assert_eq!(doc["usage"]["localPosts"], 1);
    }

    // -- Phase 4: Featured collection -----------------------------------------

    #[pg_test]
    fn test_serialize_featured() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('featured_user', 'Featured', NULL)").unwrap();

        let json = Spi::get_one::<pgrx::Json>("SELECT ap_serialize_featured('featured_user')")
            .unwrap()
            .unwrap();
        let doc = &json.0;

        assert_eq!(doc["type"], "OrderedCollection");
        assert_eq!(doc["totalItems"], 0);
        assert!(doc["orderedItems"].as_array().unwrap().is_empty());
        assert!(doc["id"]
            .as_str()
            .unwrap()
            .contains("/collections/featured"));
    }

    // -- Phase 5: HTTP Signature crypto ---------------------------------------

    #[pg_test]
    fn test_digest() {
        let digest = Spi::get_one::<String>("SELECT ap_digest('hello world')")
            .unwrap()
            .unwrap();
        assert!(digest.starts_with("SHA-256="));
        // SHA-256 of "hello world" is well-known
        assert_eq!(
            digest,
            "SHA-256=uU0nuZNNPgilLlLX2n2r+sSE7+N6U4DukIj3rOLvzek="
        );
    }

    #[pg_test]
    fn test_rsa_sign_verify() {
        setup_domain();

        // Generate a keypair
        let (public_pem, private_pem) = Spi::get_two::<String, String>(
            "SELECT public_key_pem, private_key_pem FROM ap_generate_keypair()",
        )
        .unwrap();
        let public_pem = public_pem.unwrap();
        let private_pem = private_pem.unwrap();

        // Sign some data
        let sig = Spi::get_one_with_args::<String>(
            "SELECT ap_rsa_sign($1, 'test data to sign')",
            &[private_pem.clone().into()],
        )
        .unwrap()
        .unwrap();

        // Verify the signature
        let valid = Spi::get_one_with_args::<bool>(
            "SELECT ap_rsa_verify($1, 'test data to sign', $2)",
            &[public_pem.clone().into(), sig.clone().into()],
        )
        .unwrap()
        .unwrap();
        assert!(valid, "signature should be valid");

        // Verify with wrong data should fail
        let invalid = Spi::get_one_with_args::<bool>(
            "SELECT ap_rsa_verify($1, 'wrong data', $2)",
            &[public_pem.into(), sig.into()],
        )
        .unwrap()
        .unwrap();
        assert!(!invalid, "signature should not be valid for wrong data");
    }

    #[pg_test]
    fn test_build_and_verify_signature_header() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('signer', 'Signer', NULL)").unwrap();

        // Get the actor's key
        let (key_id, private_pem, public_pem) = Spi::get_three::<String, String, String>(
            "SELECT k.key_id, k.private_key_pem, k.public_key_pem
             FROM ap_keys k JOIN ap_actors a ON a.id = k.actor_id
             WHERE a.username = 'signer'",
        )
        .unwrap();
        let key_id = key_id.unwrap();
        let private_pem = private_pem.unwrap();
        let public_pem = public_pem.unwrap();

        let body = r#"{"type":"Create","actor":"https://test.example/users/signer"}"#;
        let date = "Sun, 09 Feb 2025 12:00:00 GMT";
        let url = "https://remote.example/users/bob/inbox";

        // Build the signature header
        let sig_header = Spi::get_one_with_args::<String>(
            "SELECT ap_build_signature_header($1, $2, $3, $4, $5, $6)",
            &[
                key_id.into(),
                private_pem.into(),
                "POST".to_string().into(),
                url.into(),
                date.into(),
                body.into(),
            ],
        )
        .unwrap()
        .unwrap();

        assert!(sig_header.contains("keyId="));
        assert!(sig_header.contains("algorithm=\"rsa-sha256\""));
        assert!(sig_header.contains("signature="));

        // Now verify it
        let digest = Spi::get_one_with_args::<String>("SELECT ap_digest($1)", &[body.into()])
            .unwrap()
            .unwrap();

        let valid = Spi::get_one_with_args::<bool>(
            "SELECT ap_verify_http_signature($1, $2, $3, $4, $5, $6, $7)",
            &[
                sig_header.into(),
                "POST".to_string().into(),
                "/users/bob/inbox".to_string().into(),
                "remote.example".to_string().into(),
                date.into(),
                digest.into(),
                public_pem.into(),
            ],
        )
        .unwrap()
        .unwrap();
        assert!(valid, "signature header should verify successfully");
    }

    // -- Phase 6: Domain blocking ---------------------------------------------

    #[pg_test]
    fn test_domain_blocking() {
        setup_domain();

        // Block a domain
        Spi::run("SELECT ap_block_domain('evil.example')").unwrap();

        let blocked = Spi::get_one::<bool>("SELECT ap_is_domain_blocked('evil.example')")
            .unwrap()
            .unwrap();
        assert!(blocked);

        let not_blocked = Spi::get_one::<bool>("SELECT ap_is_domain_blocked('good.example')")
            .unwrap()
            .unwrap();
        assert!(!not_blocked);

        // Verify blocked domain list
        let count = Spi::get_one::<i64>("SELECT count(*) FROM ap_blocked_domains()")
            .unwrap()
            .unwrap();
        assert_eq!(count, 1);

        // Unblock
        Spi::run("SELECT ap_unblock_domain('evil.example')").unwrap();
        let blocked_after = Spi::get_one::<bool>("SELECT ap_is_domain_blocked('evil.example')")
            .unwrap()
            .unwrap();
        assert!(!blocked_after);
    }

    #[pg_test]
    fn test_inbox_rejects_blocked_domain() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('blocker', 'Blocker', NULL)").unwrap();

        // Block the remote domain
        Spi::run("SELECT ap_block_domain('blocked.example')").unwrap();

        // Try to process an activity from a blocked domain
        let follow_json = serde_json::json!({
            "id": "https://blocked.example/activities/follow-blocked",
            "type": "Follow",
            "actor": "https://blocked.example/users/badactor",
            "object": "https://test.example/users/blocker"
        });

        let result = Spi::get_one_with_args::<String>(
            "SELECT ap_process_inbox_activity($1::json)",
            &[pgrx::Json(follow_json).into()],
        )
        .unwrap()
        .unwrap();

        // Should return empty string (rejected)
        assert_eq!(result, "");

        // No follow should have been created
        let follow_exists = Spi::get_one::<bool>(
            "SELECT EXISTS(SELECT 1 FROM ap_follows
             WHERE following_id = (SELECT id FROM ap_actors WHERE username = 'blocker'))",
        )
        .unwrap()
        .unwrap();
        assert!(!follow_exists);
    }

    // -- Phase 6: Full-text search --------------------------------------------

    #[pg_test]
    fn test_search_objects() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('searcher', 'Searcher', NULL)").unwrap();
        Spi::run("SELECT ap_create_note('searcher', '<p>The quick brown fox</p>', NULL, NULL)")
            .unwrap();
        Spi::run("SELECT ap_create_note('searcher', '<p>Lazy dog sleeping</p>', NULL, NULL)")
            .unwrap();
        Spi::run("SELECT ap_create_note('searcher', '<p>Another fox tale</p>', NULL, NULL)")
            .unwrap();

        let count = Spi::get_one::<i64>("SELECT count(*) FROM ap_search_objects('fox')")
            .unwrap()
            .unwrap();
        assert_eq!(count, 2, "should find 2 posts containing 'fox'");

        let count = Spi::get_one::<i64>("SELECT count(*) FROM ap_search_objects('dog')")
            .unwrap()
            .unwrap();
        assert_eq!(count, 1, "should find 1 post containing 'dog'");

        let count = Spi::get_one::<i64>("SELECT count(*) FROM ap_search_objects('nonexistent')")
            .unwrap()
            .unwrap();
        assert_eq!(count, 0, "should find 0 posts for nonexistent term");
    }

    // -- Phase 6: Home timeline -----------------------------------------------

    #[pg_test]
    fn test_home_timeline() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('reader', 'Reader', NULL)").unwrap();
        Spi::run("SELECT ap_create_local_actor('writer1', 'Writer1', NULL)").unwrap();
        Spi::run("SELECT ap_create_local_actor('writer2', 'Writer2', NULL)").unwrap();

        // Writer1 and Writer2 post
        Spi::run("SELECT ap_create_note('writer1', '<p>Post from writer1</p>', NULL, NULL)")
            .unwrap();
        Spi::run("SELECT ap_create_note('writer2', '<p>Post from writer2</p>', NULL, NULL)")
            .unwrap();

        // Reader follows writer1 only
        Spi::run(
            "INSERT INTO ap_follows (follower_id, following_id, accepted)
             SELECT r.id, w.id, true
             FROM ap_actors r, ap_actors w
             WHERE r.username = 'reader' AND w.username = 'writer1'
             AND r.domain IS NULL AND w.domain IS NULL",
        )
        .unwrap();

        // Home timeline should include writer1's post + reader's own posts (none)
        let count = Spi::get_one::<i64>("SELECT count(*) FROM ap_home_timeline('reader')")
            .unwrap()
            .unwrap();
        assert_eq!(count, 1, "should see 1 post from followed writer1");

        // Reader posts something — should also appear in their timeline
        Spi::run("SELECT ap_create_note('reader', '<p>My own post</p>', NULL, NULL)").unwrap();
        let count = Spi::get_one::<i64>("SELECT count(*) FROM ap_home_timeline('reader')")
            .unwrap()
            .unwrap();
        assert_eq!(count, 2, "should see writer1's post + own post");
    }

    // -- Phase 6: Maintenance -------------------------------------------------

    #[pg_test]
    fn test_cleanup_expired_deliveries() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('cleaner', 'Cleaner', NULL)").unwrap();
        Spi::run("SELECT ap_create_note('cleaner', '<p>Cleanup test</p>', NULL, NULL)").unwrap();

        // Insert an expired delivery with old timestamp
        Spi::run(
            "INSERT INTO ap_deliveries (activity_id, inbox_uri, status, created_at)
             SELECT id, 'https://old.example/inbox', 'Expired', now() - interval '60 days'
             FROM ap_activities WHERE local = true LIMIT 1",
        )
        .unwrap();

        let deleted = Spi::get_one::<i64>("SELECT ap_cleanup_expired_deliveries(30)")
            .unwrap()
            .unwrap();
        assert_eq!(deleted, 1);
    }

    #[pg_test]
    fn test_refresh_actor_stats() {
        setup_domain();
        Spi::run("SELECT ap_create_local_actor('stats_user', 'Stats', NULL)").unwrap();
        Spi::run("SELECT ap_create_note('stats_user', '<p>Post 1</p>', NULL, NULL)").unwrap();
        Spi::run("SELECT ap_create_note('stats_user', '<p>Post 2</p>', NULL, NULL)").unwrap();

        // Manually corrupt stats
        Spi::run(
            "UPDATE ap_actor_stats SET statuses_count = 999
             WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'stats_user')",
        )
        .unwrap();

        // Refresh should fix them
        let updated = Spi::get_one::<i64>("SELECT ap_refresh_actor_stats()")
            .unwrap()
            .unwrap();
        assert!(updated >= 1);

        let count = Spi::get_one::<i64>(
            "SELECT statuses_count FROM ap_actor_stats
             WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'stats_user')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(count, 2, "stats should be recalculated to actual count");
    }

    // -- Phase 6: NOTIFY triggers ---------------------------------------------

    #[pg_test]
    fn test_notify_triggers_exist() {
        // Verify the NOTIFY triggers were created
        let delivery_trigger = Spi::get_one::<bool>(
            "SELECT EXISTS(SELECT 1 FROM information_schema.triggers
             WHERE trigger_name = 'trg_notify_delivery')",
        )
        .unwrap()
        .unwrap();
        assert!(delivery_trigger, "delivery NOTIFY trigger should exist");

        let activity_trigger = Spi::get_one::<bool>(
            "SELECT EXISTS(SELECT 1 FROM information_schema.triggers
             WHERE trigger_name = 'trg_notify_activity')",
        )
        .unwrap()
        .unwrap();
        assert!(activity_trigger, "activity NOTIFY trigger should exist");

        let object_trigger = Spi::get_one::<bool>(
            "SELECT EXISTS(SELECT 1 FROM information_schema.triggers
             WHERE trigger_name = 'trg_notify_object')",
        )
        .unwrap()
        .unwrap();
        assert!(object_trigger, "object NOTIFY trigger should exist");
    }
}

/// Required by `cargo pgrx test`.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
