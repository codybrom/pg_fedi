-- pg_fedi test suite
-- Run with: psql -v ON_ERROR_STOP=1 -f tests/test_pg_fedi.sql
--
-- Prerequisites: pg_fedi extension installed, pgcrypto enabled

\echo '=== pg_fedi test suite ==='

-- Clean slate
DROP EXTENSION IF EXISTS pg_fedi CASCADE;
CREATE EXTENSION pg_fedi;

-- Configure test domain
SELECT ap_set_setting('domain', 'test.example');
SELECT ap_set_setting('https', 'true');
SELECT ap_set_setting('auto_accept_follows', 'true');

-- =========================================================================
-- Schema tests
-- =========================================================================

\echo 'TEST: tables exist'
DO $$
DECLARE
    v_tables TEXT[] := ARRAY[
        'ap_actors', 'ap_keys', 'ap_objects', 'ap_activities',
        'ap_follows', 'ap_likes', 'ap_announces', 'ap_blocks',
        'ap_deliveries', 'ap_actor_stats', 'ap_settings'
    ];
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY v_tables LOOP
        IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = v_table) THEN
            RAISE EXCEPTION 'Table % should exist', v_table;
        END IF;
    END LOOP;
    RAISE NOTICE 'PASS: all tables exist';
END;
$$;

\echo 'TEST: views exist'
DO $$
DECLARE
    v_views TEXT[] := ARRAY['ap_local_actors', 'ap_public_timeline', 'ap_local_timeline'];
    v_view TEXT;
BEGIN
    FOREACH v_view IN ARRAY v_views LOOP
        IF NOT EXISTS (SELECT 1 FROM information_schema.views WHERE table_name = v_view) THEN
            RAISE EXCEPTION 'View % should exist', v_view;
        END IF;
    END LOOP;
    RAISE NOTICE 'PASS: all views exist';
END;
$$;

\echo 'TEST: enum types exist'
DO $$
BEGIN
    PERFORM 'Person'::ap_actor_type;
    PERFORM 'Create'::ap_activity_type;
    PERFORM 'Note'::ap_object_type;
    PERFORM 'Public'::ap_visibility;
    PERFORM 'Queued'::ap_delivery_status;
    RAISE NOTICE 'PASS: all enum types exist';
END;
$$;

\echo 'TEST: stats trigger'
DO $$
BEGIN
    INSERT INTO ap_actors (uri, actor_type, username, inbox_uri, outbox_uri)
    VALUES ('https://example.com/users/trigger_test', 'Person', 'trigger_test',
            'https://example.com/users/trigger_test/inbox',
            'https://example.com/users/trigger_test/outbox');

    IF NOT EXISTS (
        SELECT 1 FROM ap_actor_stats
        WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'trigger_test')
          AND statuses_count = 0
    ) THEN
        RAISE EXCEPTION 'Stats row should be auto-created with count 0';
    END IF;
    RAISE NOTICE 'PASS: stats trigger';

    DELETE FROM ap_actors WHERE username = 'trigger_test';
END;
$$;

-- =========================================================================
-- Crypto tests
-- =========================================================================

\echo 'TEST: ap_digest'
DO $$
DECLARE
    v_digest TEXT;
BEGIN
    v_digest := ap_digest('hello world');
    IF v_digest != 'SHA-256=uU0nuZNNPgilLlLX2n2r+sSE7+N6U4DukIj3rOLvzek=' THEN
        RAISE EXCEPTION 'Unexpected digest: %', v_digest;
    END IF;
    RAISE NOTICE 'PASS: ap_digest';
END;
$$;

-- =========================================================================
-- Actor tests
-- =========================================================================

\echo 'TEST: create local actor'
DO $$
DECLARE
    v_uri TEXT;
    v_username TEXT;
    v_has_stats BOOLEAN;
BEGIN
    v_uri := ap_create_local_actor('alice', 'Alice', 'Hello!',
        '-----BEGIN PUBLIC KEY-----\nFAKEKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nFAKEKEY\n-----END PRIVATE KEY-----');

    IF v_uri != 'https://test.example/users/alice' THEN
        RAISE EXCEPTION 'Unexpected URI: %', v_uri;
    END IF;

    SELECT username INTO v_username FROM ap_actors WHERE uri = v_uri;
    IF v_username != 'alice' THEN
        RAISE EXCEPTION 'Actor username mismatch';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM ap_keys WHERE key_id = 'https://test.example/users/alice#main-key') THEN
        RAISE EXCEPTION 'Key should exist';
    END IF;

    SELECT EXISTS(SELECT 1 FROM ap_actor_stats
        WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'alice')
          AND followers_count = 0
    ) INTO v_has_stats;
    IF NOT v_has_stats THEN
        RAISE EXCEPTION 'Stats should exist';
    END IF;

    RAISE NOTICE 'PASS: create local actor';
END;
$$;

\echo 'TEST: serialize actor'
DO $$
DECLARE
    v_doc JSONB;
BEGIN
    PERFORM ap_create_local_actor('bob', 'Bob', '<p>Hi</p>',
        '-----BEGIN PUBLIC KEY-----\nBOBKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nBOBKEY\n-----END PRIVATE KEY-----');

    v_doc := ap_serialize_actor('bob');

    IF v_doc->>'id' != 'https://test.example/users/bob' THEN
        RAISE EXCEPTION 'Wrong id: %', v_doc->>'id';
    END IF;
    IF v_doc->>'type' != 'Person' THEN
        RAISE EXCEPTION 'Wrong type';
    END IF;
    IF v_doc->>'preferredUsername' != 'bob' THEN
        RAISE EXCEPTION 'Wrong username';
    END IF;
    IF v_doc->>'name' != 'Bob' THEN
        RAISE EXCEPTION 'Wrong display name';
    END IF;
    IF v_doc->'@context' IS NULL OR jsonb_typeof(v_doc->'@context') != 'array' THEN
        RAISE EXCEPTION '@context should be an array';
    END IF;
    IF v_doc->'publicKey'->>'id' != 'https://test.example/users/bob#main-key' THEN
        RAISE EXCEPTION 'Wrong public key id';
    END IF;
    IF v_doc->'endpoints'->>'sharedInbox' != 'https://test.example/inbox' THEN
        RAISE EXCEPTION 'Wrong shared inbox';
    END IF;

    RAISE NOTICE 'PASS: serialize actor';
END;
$$;

\echo 'TEST: upsert remote actor'
DO $$
DECLARE
    v_uri TEXT;
    v_domain TEXT;
    v_pk TEXT;
    v_display TEXT;
BEGIN
    v_uri := ap_upsert_remote_actor('{
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
            "publicKeyPem": "-----BEGIN PUBLIC KEY-----\nCAROLKEY\n-----END PUBLIC KEY-----"
        },
        "endpoints": {"sharedInbox": "https://remote.example/inbox"}
    }'::jsonb);

    IF v_uri != 'https://remote.example/users/carol' THEN
        RAISE EXCEPTION 'Wrong URI: %', v_uri;
    END IF;

    SELECT domain INTO v_domain FROM ap_actors WHERE username = 'carol';
    IF v_domain != 'remote.example' THEN
        RAISE EXCEPTION 'Wrong domain: %', v_domain;
    END IF;

    SELECT public_key_pem INTO v_pk
    FROM ap_keys WHERE key_id = 'https://remote.example/users/carol#main-key';
    IF v_pk NOT LIKE '%CAROLKEY%' THEN
        RAISE EXCEPTION 'Wrong public key';
    END IF;

    -- Test upsert update path
    PERFORM ap_upsert_remote_actor('{
        "id": "https://remote.example/users/carol",
        "type": "Person",
        "preferredUsername": "carol",
        "name": "Carol Updated",
        "inbox": "https://remote.example/users/carol/inbox",
        "outbox": "https://remote.example/users/carol/outbox",
        "publicKey": {
            "id": "https://remote.example/users/carol#main-key",
            "owner": "https://remote.example/users/carol",
            "publicKeyPem": "-----BEGIN PUBLIC KEY-----\nCAROLKEY\n-----END PUBLIC KEY-----"
        }
    }'::jsonb);

    SELECT display_name INTO v_display FROM ap_actors WHERE username = 'carol';
    IF v_display != 'Carol Updated' THEN
        RAISE EXCEPTION 'Upsert did not update display name';
    END IF;

    RAISE NOTICE 'PASS: upsert remote actor';
END;
$$;

-- =========================================================================
-- WebFinger tests
-- =========================================================================

\echo 'TEST: webfinger'
DO $$
DECLARE
    v_doc JSONB;
    v_self_link JSONB;
BEGIN
    PERFORM ap_create_local_actor('dave', 'Dave', NULL,
        '-----BEGIN PUBLIC KEY-----\nDAVEKEY\n-----END PUBLIC KEY-----', NULL);

    v_doc := ap_webfinger('acct:dave@test.example');

    IF v_doc->>'subject' != 'acct:dave@test.example' THEN
        RAISE EXCEPTION 'Wrong subject: %', v_doc->>'subject';
    END IF;

    SELECT elem INTO v_self_link
    FROM jsonb_array_elements(v_doc->'links') AS elem
    WHERE elem->>'rel' = 'self';

    IF v_self_link->>'href' != 'https://test.example/users/dave' THEN
        RAISE EXCEPTION 'Wrong self link: %', v_self_link->>'href';
    END IF;
    IF v_self_link->>'type' != 'application/activity+json' THEN
        RAISE EXCEPTION 'Wrong self link type';
    END IF;

    RAISE NOTICE 'PASS: webfinger';
END;
$$;

\echo 'TEST: host-meta'
DO $$
DECLARE
    v_xml TEXT;
BEGIN
    v_xml := ap_host_meta();
    IF v_xml NOT LIKE '%XRD%' OR v_xml NOT LIKE '%test.example%' THEN
        RAISE EXCEPTION 'Invalid host-meta: %', v_xml;
    END IF;
    RAISE NOTICE 'PASS: host-meta';
END;
$$;

-- =========================================================================
-- Note creation
-- =========================================================================

\echo 'TEST: create note'
DO $$
DECLARE
    v_note_uri TEXT;
    v_content TEXT;
    v_activity_exists BOOLEAN;
    v_status_count BIGINT;
BEGIN
    PERFORM ap_create_local_actor('poster', 'Poster', NULL,
        '-----BEGIN PUBLIC KEY-----\nPOSTERKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nPOSTERKEY\n-----END PRIVATE KEY-----');

    v_note_uri := ap_create_note('poster', '<p>Hello fediverse!</p>', NULL, NULL);

    IF v_note_uri NOT LIKE 'https://test.example/users/poster/objects/%' THEN
        RAISE EXCEPTION 'Unexpected note URI: %', v_note_uri;
    END IF;

    SELECT content INTO v_content FROM ap_objects WHERE uri = v_note_uri;
    IF v_content != '<p>Hello fediverse!</p>' THEN
        RAISE EXCEPTION 'Wrong content';
    END IF;

    SELECT EXISTS(SELECT 1 FROM ap_activities WHERE object_uri = v_note_uri AND activity_type = 'Create')
    INTO v_activity_exists;
    IF NOT v_activity_exists THEN
        RAISE EXCEPTION 'Create activity should exist';
    END IF;

    SELECT statuses_count INTO v_status_count
    FROM ap_actor_stats
    WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'poster');
    IF v_status_count != 1 THEN
        RAISE EXCEPTION 'Status count should be 1, got %', v_status_count;
    END IF;

    RAISE NOTICE 'PASS: create note';
END;
$$;

-- =========================================================================
-- Follow processing
-- =========================================================================

\echo 'TEST: inbox follow auto-accept'
DO $$
DECLARE
    v_accepted BOOLEAN;
    v_accept_exists BOOLEAN;
    v_delivery_exists BOOLEAN;
    v_followers BIGINT;
BEGIN
    PERFORM ap_create_local_actor('local_user', 'Local', NULL,
        '-----BEGIN PUBLIC KEY-----\nLOCALKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nLOCALKEY\n-----END PRIVATE KEY-----');

    PERFORM ap_upsert_remote_actor('{
        "id": "https://remote.example/users/remote_user",
        "type": "Person",
        "preferredUsername": "remote_user",
        "inbox": "https://remote.example/users/remote_user/inbox",
        "outbox": "https://remote.example/users/remote_user/outbox",
        "publicKey": {
            "id": "https://remote.example/users/remote_user#main-key",
            "owner": "https://remote.example/users/remote_user",
            "publicKeyPem": "-----BEGIN PUBLIC KEY-----\nREMOTEKEY\n-----END PUBLIC KEY-----"
        }
    }'::jsonb);

    PERFORM ap_process_inbox_activity('{
        "@context": "https://www.w3.org/ns/activitystreams",
        "id": "https://remote.example/activities/follow-1",
        "type": "Follow",
        "actor": "https://remote.example/users/remote_user",
        "object": "https://test.example/users/local_user"
    }'::jsonb);

    SELECT accepted INTO v_accepted FROM ap_follows
    WHERE follower_id = (SELECT id FROM ap_actors WHERE uri = 'https://remote.example/users/remote_user')
      AND following_id = (SELECT id FROM ap_actors WHERE username = 'local_user');
    IF NOT v_accepted THEN
        RAISE EXCEPTION 'Follow should be accepted';
    END IF;

    SELECT EXISTS(SELECT 1 FROM ap_activities WHERE activity_type = 'Accept' AND local = true)
    INTO v_accept_exists;
    IF NOT v_accept_exists THEN
        RAISE EXCEPTION 'Accept activity should exist';
    END IF;

    SELECT EXISTS(SELECT 1 FROM ap_deliveries
        WHERE inbox_uri = 'https://remote.example/users/remote_user/inbox')
    INTO v_delivery_exists;
    IF NOT v_delivery_exists THEN
        RAISE EXCEPTION 'Accept delivery should be queued';
    END IF;

    SELECT followers_count INTO v_followers
    FROM ap_actor_stats
    WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'local_user');
    IF v_followers != 1 THEN
        RAISE EXCEPTION 'Followers count should be 1, got %', v_followers;
    END IF;

    RAISE NOTICE 'PASS: inbox follow auto-accept';
END;
$$;

-- =========================================================================
-- Like processing
-- =========================================================================

\echo 'TEST: inbox like'
DO $$
DECLARE
    v_note_uri TEXT;
    v_like_exists BOOLEAN;
BEGIN
    PERFORM ap_create_local_actor('author', 'Author', NULL,
        '-----BEGIN PUBLIC KEY-----\nAUTHORKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nAUTHORKEY\n-----END PRIVATE KEY-----');

    v_note_uri := ap_create_note('author', '<p>Like me!</p>', NULL, NULL);

    PERFORM ap_process_inbox_activity(jsonb_build_object(
        '@context', 'https://www.w3.org/ns/activitystreams',
        'id', 'https://remote.example/activities/like-1',
        'type', 'Like',
        'actor', 'https://remote.example/users/liker',
        'object', v_note_uri
    ));

    SELECT EXISTS(SELECT 1 FROM ap_likes
        WHERE object_id = (SELECT id FROM ap_objects WHERE uri = v_note_uri))
    INTO v_like_exists;
    IF NOT v_like_exists THEN
        RAISE EXCEPTION 'Like should be recorded';
    END IF;

    RAISE NOTICE 'PASS: inbox like';
END;
$$;

-- =========================================================================
-- Undo processing
-- =========================================================================

\echo 'TEST: inbox undo follow'
DO $$
DECLARE
    v_follow_exists BOOLEAN;
    v_follow_gone BOOLEAN;
BEGIN
    PERFORM ap_create_local_actor('target', 'Target', NULL,
        '-----BEGIN PUBLIC KEY-----\nTARGETKEY\n-----END PUBLIC KEY-----', NULL);

    PERFORM ap_upsert_remote_actor('{
        "id": "https://remote.example/users/unfollower",
        "type": "Person",
        "preferredUsername": "unfollower",
        "inbox": "https://remote.example/users/unfollower/inbox",
        "outbox": "https://remote.example/users/unfollower/outbox"
    }'::jsonb);

    PERFORM ap_process_inbox_activity('{
        "id": "https://remote.example/activities/follow-2",
        "type": "Follow",
        "actor": "https://remote.example/users/unfollower",
        "object": "https://test.example/users/target"
    }'::jsonb);

    SELECT EXISTS(SELECT 1 FROM ap_follows
        WHERE follower_id = (SELECT id FROM ap_actors WHERE uri = 'https://remote.example/users/unfollower'))
    INTO v_follow_exists;
    IF NOT v_follow_exists THEN
        RAISE EXCEPTION 'Follow should exist before undo';
    END IF;

    PERFORM ap_process_inbox_activity('{
        "id": "https://remote.example/activities/undo-1",
        "type": "Undo",
        "actor": "https://remote.example/users/unfollower",
        "object": {
            "id": "https://remote.example/activities/follow-2",
            "type": "Follow",
            "actor": "https://remote.example/users/unfollower",
            "object": "https://test.example/users/target"
        }
    }'::jsonb);

    SELECT NOT EXISTS(SELECT 1 FROM ap_follows
        WHERE follower_id = (SELECT id FROM ap_actors WHERE uri = 'https://remote.example/users/unfollower')
          AND following_id = (SELECT id FROM ap_actors WHERE username = 'target'))
    INTO v_follow_gone;
    IF NOT v_follow_gone THEN
        RAISE EXCEPTION 'Follow should be removed after Undo';
    END IF;

    RAISE NOTICE 'PASS: inbox undo follow';
END;
$$;

-- =========================================================================
-- Create (remote content)
-- =========================================================================

\echo 'TEST: inbox create note'
DO $$
DECLARE
    v_content TEXT;
    v_content_text TEXT;
BEGIN
    PERFORM ap_process_inbox_activity('{
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
    }'::jsonb);

    SELECT content, content_text INTO v_content, v_content_text
    FROM ap_objects WHERE uri = 'https://remote.example/objects/note-1';

    IF v_content != '<p>Hello from remote!</p>' THEN
        RAISE EXCEPTION 'Wrong content: %', v_content;
    END IF;
    IF v_content_text != 'Hello from remote!' THEN
        RAISE EXCEPTION 'Wrong content_text: %', v_content_text;
    END IF;

    RAISE NOTICE 'PASS: inbox create note';
END;
$$;

-- =========================================================================
-- Delivery queue
-- =========================================================================

\echo 'TEST: delivery lifecycle'
DO $$
DECLARE
    v_delivery_id BIGINT;
    v_status TEXT;
    v_attempts INT;
    v_queued BIGINT;
BEGIN
    PERFORM ap_create_local_actor('sender', 'Sender', NULL,
        '-----BEGIN PUBLIC KEY-----\nSENDERKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nSENDERKEY\n-----END PRIVATE KEY-----');

    PERFORM ap_create_note('sender', '<p>Test</p>', NULL, NULL);

    -- Manually insert a delivery
    INSERT INTO ap_deliveries (activity_id, inbox_uri)
    SELECT id, 'https://remote.example/inbox'
    FROM ap_activities WHERE local = true
    ORDER BY id DESC LIMIT 1;

    SELECT count INTO v_queued FROM ap_delivery_stats() WHERE status = 'Queued';
    IF v_queued < 1 THEN
        RAISE EXCEPTION 'Should have at least 1 queued delivery';
    END IF;

    SELECT id INTO v_delivery_id FROM ap_deliveries ORDER BY id DESC LIMIT 1;

    PERFORM ap_delivery_failure(v_delivery_id, 'connection refused', 0);

    SELECT status::text, attempts INTO v_status, v_attempts
    FROM ap_deliveries WHERE id = v_delivery_id;

    IF v_status != 'Failed' THEN
        RAISE EXCEPTION 'Status should be Failed, got %', v_status;
    END IF;
    IF v_attempts != 1 THEN
        RAISE EXCEPTION 'Attempts should be 1, got %', v_attempts;
    END IF;

    RAISE NOTICE 'PASS: delivery lifecycle';
END;
$$;

-- =========================================================================
-- Collection serialization
-- =========================================================================

\echo 'TEST: serialize outbox'
DO $$
DECLARE
    v_summary JSONB;
    v_page JSONB;
BEGIN
    PERFORM ap_create_local_actor('collector', 'Collector', NULL,
        '-----BEGIN PUBLIC KEY-----\nCOLLECTORKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nCOLLECTORKEY\n-----END PRIVATE KEY-----');

    PERFORM ap_create_note('collector', '<p>Post 1</p>', NULL, NULL);
    PERFORM ap_create_note('collector', '<p>Post 2</p>', NULL, NULL);

    v_summary := ap_serialize_outbox('collector', NULL);
    IF v_summary->>'type' != 'OrderedCollection' THEN
        RAISE EXCEPTION 'Wrong type: %', v_summary->>'type';
    END IF;
    IF (v_summary->>'totalItems')::int != 2 THEN
        RAISE EXCEPTION 'Should have 2 items, got %', v_summary->>'totalItems';
    END IF;

    v_page := ap_serialize_outbox('collector', 1);
    IF v_page->>'type' != 'OrderedCollectionPage' THEN
        RAISE EXCEPTION 'Page wrong type';
    END IF;
    IF jsonb_typeof(v_page->'orderedItems') != 'array' THEN
        RAISE EXCEPTION 'orderedItems should be array';
    END IF;

    RAISE NOTICE 'PASS: serialize outbox';
END;
$$;

\echo 'TEST: serialize followers'
DO $$
DECLARE
    v_summary JSONB;
BEGIN
    PERFORM ap_create_local_actor('popular', 'Popular', NULL,
        '-----BEGIN PUBLIC KEY-----\nPOPULARKEY\n-----END PUBLIC KEY-----', NULL);

    v_summary := ap_serialize_followers('popular', NULL);
    IF v_summary->>'type' != 'OrderedCollection' THEN
        RAISE EXCEPTION 'Wrong type';
    END IF;
    IF (v_summary->>'totalItems')::int != 0 THEN
        RAISE EXCEPTION 'Should have 0 items';
    END IF;

    RAISE NOTICE 'PASS: serialize followers';
END;
$$;

-- =========================================================================
-- NodeInfo
-- =========================================================================

\echo 'TEST: nodeinfo discovery'
DO $$
DECLARE
    v_doc JSONB;
BEGIN
    v_doc := ap_nodeinfo_discovery();
    IF jsonb_typeof(v_doc->'links') != 'array' THEN
        RAISE EXCEPTION 'links should be array';
    END IF;
    IF v_doc->'links'->0->>'rel' != 'http://nodeinfo.diaspora.software/ns/schema/2.0' THEN
        RAISE EXCEPTION 'Wrong rel';
    END IF;

    RAISE NOTICE 'PASS: nodeinfo discovery';
END;
$$;

\echo 'TEST: nodeinfo'
DO $$
DECLARE
    v_doc JSONB;
BEGIN
    PERFORM ap_create_local_actor('nodeuser', 'Node User', NULL,
        '-----BEGIN PUBLIC KEY-----\nNODEKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nNODEKEY\n-----END PRIVATE KEY-----');
    PERFORM ap_create_note('nodeuser', '<p>NodeInfo test</p>', NULL, NULL);

    v_doc := ap_nodeinfo();
    IF v_doc->>'version' != '2.0' THEN RAISE EXCEPTION 'Wrong version'; END IF;
    IF v_doc->'software'->>'name' != 'pg_fedi' THEN RAISE EXCEPTION 'Wrong software name'; END IF;
    IF v_doc->'software'->>'version' != '0.2.0' THEN RAISE EXCEPTION 'Wrong software version'; END IF;

    RAISE NOTICE 'PASS: nodeinfo';
END;
$$;

-- =========================================================================
-- Featured collection
-- =========================================================================

\echo 'TEST: serialize featured'
DO $$
DECLARE
    v_doc JSONB;
BEGIN
    PERFORM ap_create_local_actor('featured_user', 'Featured', NULL,
        '-----BEGIN PUBLIC KEY-----\nFEATUREDKEY\n-----END PUBLIC KEY-----', NULL);

    v_doc := ap_serialize_featured('featured_user');
    IF v_doc->>'type' != 'OrderedCollection' THEN RAISE EXCEPTION 'Wrong type'; END IF;
    IF (v_doc->>'totalItems')::int != 0 THEN RAISE EXCEPTION 'Should be empty'; END IF;
    IF v_doc->>'id' NOT LIKE '%/collections/featured' THEN RAISE EXCEPTION 'Wrong id'; END IF;

    RAISE NOTICE 'PASS: serialize featured';
END;
$$;

-- =========================================================================
-- Domain blocking
-- =========================================================================

\echo 'TEST: domain blocking'
DO $$
DECLARE
    v_blocked BOOLEAN;
    v_count BIGINT;
BEGIN
    PERFORM ap_block_domain('evil.example');

    v_blocked := ap_is_domain_blocked('evil.example');
    IF NOT v_blocked THEN RAISE EXCEPTION 'evil.example should be blocked'; END IF;

    IF ap_is_domain_blocked('good.example') THEN
        RAISE EXCEPTION 'good.example should not be blocked';
    END IF;

    SELECT count(*) INTO v_count FROM ap_blocked_domains();
    IF v_count < 1 THEN RAISE EXCEPTION 'Should have at least 1 blocked domain'; END IF;

    PERFORM ap_unblock_domain('evil.example');
    IF ap_is_domain_blocked('evil.example') THEN
        RAISE EXCEPTION 'evil.example should be unblocked';
    END IF;

    RAISE NOTICE 'PASS: domain blocking';
END;
$$;

\echo 'TEST: inbox rejects blocked domain'
DO $$
DECLARE
    v_result TEXT;
    v_follow_exists BOOLEAN;
BEGIN
    PERFORM ap_create_local_actor('blocker', 'Blocker', NULL,
        '-----BEGIN PUBLIC KEY-----\nBLOCKERKEY\n-----END PUBLIC KEY-----', NULL);

    PERFORM ap_block_domain('blocked.example');

    v_result := ap_process_inbox_activity('{
        "id": "https://blocked.example/activities/follow-blocked",
        "type": "Follow",
        "actor": "https://blocked.example/users/badactor",
        "object": "https://test.example/users/blocker"
    }'::jsonb);

    IF v_result != '' THEN
        RAISE EXCEPTION 'Should return empty string for blocked domain, got: %', v_result;
    END IF;

    SELECT EXISTS(SELECT 1 FROM ap_follows
        WHERE following_id = (SELECT id FROM ap_actors WHERE username = 'blocker'))
    INTO v_follow_exists;
    IF v_follow_exists THEN
        RAISE EXCEPTION 'No follow should exist from blocked domain';
    END IF;

    PERFORM ap_unblock_domain('blocked.example');
    RAISE NOTICE 'PASS: inbox rejects blocked domain';
END;
$$;

-- =========================================================================
-- Search
-- =========================================================================

\echo 'TEST: search objects'
DO $$
DECLARE
    v_count BIGINT;
BEGIN
    PERFORM ap_create_local_actor('searcher', 'Searcher', NULL,
        '-----BEGIN PUBLIC KEY-----\nSEARCHKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nSEARCHKEY\n-----END PRIVATE KEY-----');
    PERFORM ap_create_note('searcher', '<p>The quick brown fox</p>', NULL, NULL);
    PERFORM ap_create_note('searcher', '<p>Lazy dog sleeping</p>', NULL, NULL);
    PERFORM ap_create_note('searcher', '<p>Another fox tale</p>', NULL, NULL);

    SELECT count(*) INTO v_count FROM ap_search_objects('fox');
    IF v_count != 2 THEN RAISE EXCEPTION 'Expected 2 fox results, got %', v_count; END IF;

    SELECT count(*) INTO v_count FROM ap_search_objects('dog');
    IF v_count != 1 THEN RAISE EXCEPTION 'Expected 1 dog result, got %', v_count; END IF;

    SELECT count(*) INTO v_count FROM ap_search_objects('nonexistent');
    IF v_count != 0 THEN RAISE EXCEPTION 'Expected 0 results, got %', v_count; END IF;

    RAISE NOTICE 'PASS: search objects';
END;
$$;

-- =========================================================================
-- Home timeline
-- =========================================================================

\echo 'TEST: home timeline'
DO $$
DECLARE
    v_count BIGINT;
BEGIN
    PERFORM ap_create_local_actor('reader', 'Reader', NULL,
        '-----BEGIN PUBLIC KEY-----\nREADERKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nREADERKEY\n-----END PRIVATE KEY-----');
    PERFORM ap_create_local_actor('writer1', 'Writer1', NULL,
        '-----BEGIN PUBLIC KEY-----\nWRITER1KEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nWRITER1KEY\n-----END PRIVATE KEY-----');
    PERFORM ap_create_local_actor('writer2', 'Writer2', NULL,
        '-----BEGIN PUBLIC KEY-----\nWRITER2KEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nWRITER2KEY\n-----END PRIVATE KEY-----');

    PERFORM ap_create_note('writer1', '<p>Post from writer1</p>', NULL, NULL);
    PERFORM ap_create_note('writer2', '<p>Post from writer2</p>', NULL, NULL);

    -- Reader follows writer1 only
    INSERT INTO ap_follows (follower_id, following_id, accepted)
    SELECT r.id, w.id, true
    FROM ap_actors r, ap_actors w
    WHERE r.username = 'reader' AND w.username = 'writer1'
      AND r.domain IS NULL AND w.domain IS NULL;

    SELECT count(*) INTO v_count FROM ap_home_timeline('reader');
    IF v_count != 1 THEN RAISE EXCEPTION 'Expected 1 post, got %', v_count; END IF;

    PERFORM ap_create_note('reader', '<p>My own post</p>', NULL, NULL);
    SELECT count(*) INTO v_count FROM ap_home_timeline('reader');
    IF v_count != 2 THEN RAISE EXCEPTION 'Expected 2 posts, got %', v_count; END IF;

    RAISE NOTICE 'PASS: home timeline';
END;
$$;

-- =========================================================================
-- Maintenance
-- =========================================================================

\echo 'TEST: cleanup expired deliveries'
DO $$
DECLARE
    v_deleted BIGINT;
BEGIN
    PERFORM ap_create_local_actor('cleaner', 'Cleaner', NULL,
        '-----BEGIN PUBLIC KEY-----\nCLEANERKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nCLEANERKEY\n-----END PRIVATE KEY-----');
    PERFORM ap_create_note('cleaner', '<p>Cleanup test</p>', NULL, NULL);

    INSERT INTO ap_deliveries (activity_id, inbox_uri, status, created_at)
    SELECT id, 'https://old.example/inbox', 'Expired', now() - interval '60 days'
    FROM ap_activities WHERE local = true ORDER BY id DESC LIMIT 1;

    v_deleted := ap_cleanup_expired_deliveries(30);
    IF v_deleted < 1 THEN RAISE EXCEPTION 'Should have deleted at least 1'; END IF;

    RAISE NOTICE 'PASS: cleanup expired deliveries';
END;
$$;

\echo 'TEST: refresh actor stats'
DO $$
DECLARE
    v_updated BIGINT;
    v_count BIGINT;
BEGIN
    PERFORM ap_create_local_actor('stats_user', 'Stats', NULL,
        '-----BEGIN PUBLIC KEY-----\nSTATSKEY\n-----END PUBLIC KEY-----',
        '-----BEGIN PRIVATE KEY-----\nSTATSKEY\n-----END PRIVATE KEY-----');
    PERFORM ap_create_note('stats_user', '<p>Post 1</p>', NULL, NULL);
    PERFORM ap_create_note('stats_user', '<p>Post 2</p>', NULL, NULL);

    -- Corrupt stats
    UPDATE ap_actor_stats SET statuses_count = 999
    WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'stats_user');

    v_updated := ap_refresh_actor_stats();
    IF v_updated < 1 THEN RAISE EXCEPTION 'Should have updated at least 1'; END IF;

    SELECT statuses_count INTO v_count
    FROM ap_actor_stats
    WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'stats_user');
    IF v_count != 2 THEN RAISE EXCEPTION 'Stats should be 2, got %', v_count; END IF;

    RAISE NOTICE 'PASS: refresh actor stats';
END;
$$;

-- =========================================================================
-- NOTIFY triggers
-- =========================================================================

\echo 'TEST: notify triggers exist'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.triggers WHERE trigger_name = 'trg_notify_delivery') THEN
        RAISE EXCEPTION 'delivery NOTIFY trigger should exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.triggers WHERE trigger_name = 'trg_notify_activity') THEN
        RAISE EXCEPTION 'activity NOTIFY trigger should exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.triggers WHERE trigger_name = 'trg_notify_object') THEN
        RAISE EXCEPTION 'object NOTIFY trigger should exist';
    END IF;
    RAISE NOTICE 'PASS: notify triggers exist';
END;
$$;

-- =========================================================================
-- Cleanup
-- =========================================================================

\echo ''
\echo '=== All tests passed! ==='
