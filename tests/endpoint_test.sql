-- pg_fedi endpoint response validation
-- Validates that SQL function outputs match what remote fediverse servers expect.
-- Run: psql -v ON_ERROR_STOP=1 -p 28815 -f tests/endpoint_test.sql
--   or: \i tests/endpoint_test.sql  (from cargo pgrx run pg15)

CREATE EXTENSION IF NOT EXISTS pg_fedi;

SET pg_fedi.domain = 'test.example';
SET pg_fedi.https = true;
SET pg_fedi.auto_accept_follows = true;

-- Setup: create a local actor with a note
DO $$
BEGIN
    PERFORM ap_create_local_actor('endpoint_alice', 'Alice Endpoint', 'Testing endpoints');
    PERFORM ap_create_note('endpoint_alice', '<p>Hello from endpoint test!</p>', NULL, NULL);
    RAISE NOTICE 'SETUP: actor and note created';
END $$;

----------------------------------------------------------------------
-- GET /.well-known/webfinger?resource=acct:endpoint_alice@test.example
----------------------------------------------------------------------
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_webfinger('acct:endpoint_alice@test.example');

    -- JRD required fields (RFC 7033)
    ASSERT doc->>'subject' = 'acct:endpoint_alice@test.example',
        'webfinger: subject mismatch';

    -- Must have links array
    ASSERT json_array_length(doc->'links') > 0,
        'webfinger: links array empty';

    -- Must have self link with ActivityPub type
    PERFORM 1 FROM json_array_elements(doc->'links') AS link
        WHERE link->>'rel' = 'self'
        AND link->>'type' = 'application/activity+json'
        AND link->>'href' = 'https://test.example/users/endpoint_alice';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'webfinger: missing self link with application/activity+json';
    END IF;

    RAISE NOTICE 'PASS: GET /.well-known/webfinger';
END $$;

----------------------------------------------------------------------
-- GET /.well-known/host-meta
----------------------------------------------------------------------
DO $$
DECLARE doc TEXT;
BEGIN
    doc := ap_host_meta();

    -- Must be XRD XML
    ASSERT doc LIKE '%<?xml%', 'host-meta: not XML';
    ASSERT doc LIKE '%XRD%', 'host-meta: missing XRD element';
    -- Must contain WebFinger template
    ASSERT doc LIKE '%/.well-known/webfinger%', 'host-meta: missing webfinger template';

    RAISE NOTICE 'PASS: GET /.well-known/host-meta';
END $$;

----------------------------------------------------------------------
-- GET /.well-known/nodeinfo
----------------------------------------------------------------------
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_nodeinfo_discovery();

    -- Must have links array
    ASSERT json_array_length(doc->'links') > 0,
        'nodeinfo discovery: links empty';

    -- Link must point to nodeinfo 2.0
    PERFORM 1 FROM json_array_elements(doc->'links') AS link
        WHERE link->>'rel' = 'http://nodeinfo.diaspora.software/ns/schema/2.0'
        AND link->>'href' LIKE '%/nodeinfo/2.0';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'nodeinfo discovery: missing nodeinfo 2.0 link';
    END IF;

    RAISE NOTICE 'PASS: GET /.well-known/nodeinfo';
END $$;

----------------------------------------------------------------------
-- GET /nodeinfo/2.0
----------------------------------------------------------------------
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_nodeinfo();

    ASSERT doc->>'version' = '2.0', 'nodeinfo: version != 2.0';
    ASSERT doc->'software'->>'name' = 'pg_fedi', 'nodeinfo: software name';
    ASSERT doc->'software'->>'version' IS NOT NULL, 'nodeinfo: software version missing';

    -- Must list activitypub protocol
    PERFORM 1 FROM json_array_elements_text(doc->'protocols') AS p WHERE p = 'activitypub';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'nodeinfo: protocols missing activitypub';
    END IF;

    -- Usage stats
    ASSERT (doc->'usage'->'users'->>'total')::int >= 0, 'nodeinfo: usage.users.total missing';
    ASSERT (doc->'usage'->>'localPosts')::int >= 0, 'nodeinfo: usage.localPosts missing';

    RAISE NOTICE 'PASS: GET /nodeinfo/2.0';
END $$;

----------------------------------------------------------------------
-- GET /users/endpoint_alice  (Actor profile)
----------------------------------------------------------------------
DO $$
DECLARE doc JSON; ctx JSON;
BEGIN
    doc := ap_serialize_actor('endpoint_alice');

    -- JSON-LD @context
    ctx := doc->'@context';
    ASSERT ctx IS NOT NULL, 'actor: @context missing';

    -- Core ActivityPub fields
    ASSERT doc->>'id' = 'https://test.example/users/endpoint_alice', 'actor: id mismatch';
    ASSERT doc->>'type' = 'Person', 'actor: type != Person';
    ASSERT doc->>'preferredUsername' = 'endpoint_alice', 'actor: preferredUsername';
    ASSERT doc->>'name' = 'Alice Endpoint', 'actor: name/displayName';

    -- Required endpoints
    ASSERT doc->>'inbox' = 'https://test.example/users/endpoint_alice/inbox', 'actor: inbox URL';
    ASSERT doc->>'outbox' = 'https://test.example/users/endpoint_alice/outbox', 'actor: outbox URL';
    ASSERT doc->>'followers' = 'https://test.example/users/endpoint_alice/followers', 'actor: followers URL';
    ASSERT doc->>'following' = 'https://test.example/users/endpoint_alice/following', 'actor: following URL';

    -- Public key (required for federation)
    ASSERT doc->'publicKey'->>'id' = 'https://test.example/users/endpoint_alice#main-key',
        'actor: publicKey.id';
    ASSERT doc->'publicKey'->>'owner' = 'https://test.example/users/endpoint_alice',
        'actor: publicKey.owner';
    ASSERT doc->'publicKey'->>'publicKeyPem' LIKE '-----BEGIN PUBLIC KEY-----%',
        'actor: publicKey.publicKeyPem format';

    -- Featured collection (Mastodon expects this)
    ASSERT doc->>'featured' = 'https://test.example/users/endpoint_alice/collections/featured',
        'actor: featured URL';

    RAISE NOTICE 'PASS: GET /users/:name';
END $$;

----------------------------------------------------------------------
-- GET /users/endpoint_alice/outbox
----------------------------------------------------------------------
DO $$
DECLARE doc JSON;
BEGIN
    -- Unpaginated (collection summary)
    doc := ap_serialize_outbox('endpoint_alice', NULL);
    ASSERT doc->>'type' = 'OrderedCollection', 'outbox: type != OrderedCollection';
    ASSERT doc->>'id' = 'https://test.example/users/endpoint_alice/outbox', 'outbox: id';
    ASSERT (doc->>'totalItems')::int >= 1, 'outbox: totalItems < 1';
    ASSERT doc->>'first' IS NOT NULL, 'outbox: first page link missing';

    -- Paginated (first page)
    doc := ap_serialize_outbox('endpoint_alice', 1);
    ASSERT doc->>'type' = 'OrderedCollectionPage', 'outbox page: type != OrderedCollectionPage';
    ASSERT doc->>'partOf' = 'https://test.example/users/endpoint_alice/outbox', 'outbox page: partOf';
    ASSERT json_array_length(doc->'orderedItems') >= 1, 'outbox page: no items';

    RAISE NOTICE 'PASS: GET /users/:name/outbox';
END $$;

----------------------------------------------------------------------
-- GET /users/endpoint_alice/followers
----------------------------------------------------------------------
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_serialize_followers('endpoint_alice', NULL);
    ASSERT doc->>'type' = 'OrderedCollection', 'followers: type';
    ASSERT doc->>'id' = 'https://test.example/users/endpoint_alice/followers', 'followers: id';
    ASSERT (doc->>'totalItems')::int >= 0, 'followers: totalItems';

    RAISE NOTICE 'PASS: GET /users/:name/followers';
END $$;

----------------------------------------------------------------------
-- GET /users/endpoint_alice/following
----------------------------------------------------------------------
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_serialize_following('endpoint_alice', NULL);
    ASSERT doc->>'type' = 'OrderedCollection', 'following: type';
    ASSERT doc->>'id' = 'https://test.example/users/endpoint_alice/following', 'following: id';
    ASSERT (doc->>'totalItems')::int >= 0, 'following: totalItems';

    RAISE NOTICE 'PASS: GET /users/:name/following';
END $$;

----------------------------------------------------------------------
-- GET /users/endpoint_alice/collections/featured
----------------------------------------------------------------------
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_serialize_featured('endpoint_alice');
    ASSERT doc->>'type' = 'OrderedCollection', 'featured: type';
    ASSERT doc->>'id' = 'https://test.example/users/endpoint_alice/collections/featured', 'featured: id';

    RAISE NOTICE 'PASS: GET /users/:name/collections/featured';
END $$;

----------------------------------------------------------------------
-- POST /users/endpoint_alice/inbox  (Follow request → Accept)
----------------------------------------------------------------------
DO $$
DECLARE accept_row RECORD;
BEGIN
    -- Upsert a remote actor first
    PERFORM ap_upsert_remote_actor(
        '{"id":"https://remote.example/users/carol","type":"Person","preferredUsername":"carol",
          "inbox":"https://remote.example/users/carol/inbox",
          "outbox":"https://remote.example/users/carol/outbox",
          "publicKey":{"id":"https://remote.example/users/carol#main-key",
                       "owner":"https://remote.example/users/carol",
                       "publicKeyPem":"-----BEGIN PUBLIC KEY-----\nFAKE\n-----END PUBLIC KEY-----"}}'::json);

    -- Send Follow
    PERFORM ap_process_inbox_activity(
        '{"id":"https://remote.example/activities/follow-ep-1","type":"Follow",
          "actor":"https://remote.example/users/carol",
          "object":"https://test.example/users/endpoint_alice"}'::json);

    -- Follow should be accepted
    PERFORM 1 FROM ap_follows
        WHERE follower_id = (SELECT id FROM ap_actors WHERE uri = 'https://remote.example/users/carol')
        AND following_id = (SELECT id FROM ap_actors WHERE username = 'endpoint_alice' AND domain IS NULL)
        AND accepted = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'inbox Follow: not auto-accepted';
    END IF;

    -- Accept activity should be created and serializable
    SELECT * INTO accept_row FROM ap_activities
        WHERE activity_type = 'Accept' AND local = true
        ORDER BY created_at DESC LIMIT 1;
    IF accept_row IS NULL THEN
        RAISE EXCEPTION 'inbox Follow: Accept activity not created';
    END IF;

    RAISE NOTICE 'PASS: POST /users/:name/inbox (Follow)';
END $$;

----------------------------------------------------------------------
-- POST /inbox  (Like)
----------------------------------------------------------------------
DO $$
DECLARE note_uri TEXT;
BEGIN
    -- Get a note URI
    SELECT uri INTO note_uri FROM ap_objects
        WHERE actor_id = (SELECT id FROM ap_actors WHERE username = 'endpoint_alice' AND domain IS NULL)
        LIMIT 1;

    PERFORM ap_process_inbox_activity(
        ('{"id":"https://remote.example/activities/like-ep-1","type":"Like",
          "actor":"https://remote.example/users/carol",
          "object":"' || note_uri || '"}')::json);

    PERFORM 1 FROM ap_likes
        WHERE object_id = (SELECT id FROM ap_objects WHERE uri = note_uri)
        AND actor_id = (SELECT id FROM ap_actors WHERE uri = 'https://remote.example/users/carol');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'inbox Like: like not recorded';
    END IF;

    RAISE NOTICE 'PASS: POST /inbox (Like)';
END $$;

----------------------------------------------------------------------
-- Activity serialization (what delivery worker sends)
----------------------------------------------------------------------
DO $$
DECLARE doc JSON; act_uri TEXT;
BEGIN
    SELECT uri INTO act_uri FROM ap_activities
        WHERE activity_type = 'Create' AND local = true LIMIT 1;

    doc := ap_serialize_activity(act_uri);

    ASSERT doc->'@context' IS NOT NULL, 'activity: @context missing';
    ASSERT doc->>'type' = 'Create', 'activity: type';
    ASSERT doc->>'actor' IS NOT NULL, 'activity: actor missing';
    -- Object may be a URI reference or embedded object
    ASSERT doc->>'object' IS NOT NULL, 'activity: object missing';
    ASSERT doc->>'published' IS NOT NULL, 'activity: published missing';
    -- Addressing
    ASSERT doc->'to' IS NOT NULL, 'activity: to missing';
    ASSERT doc->'cc' IS NOT NULL, 'activity: cc missing';

    RAISE NOTICE 'PASS: activity serialization (delivery payload)';
END $$;

----------------------------------------------------------------------
-- Delivery queue (what the worker polls)
----------------------------------------------------------------------
DO $$
DECLARE d RECORD; cnt INT;
BEGIN
    SELECT count(*)::int INTO cnt FROM ap_get_pending_deliveries(100);
    -- We may or may not have pending deliveries depending on follower state,
    -- but the function should not error
    ASSERT cnt >= 0, 'pending deliveries: returned negative count';

    -- Delivery stats should work
    PERFORM 1 FROM ap_delivery_stats();

    RAISE NOTICE 'PASS: delivery queue (% pending)', cnt;
END $$;

----------------------------------------------------------------------
-- HTTP Signature round-trip (proxy would use this for outbound requests)
----------------------------------------------------------------------
DO $$
DECLARE
    sig_header TEXT;
    valid BOOLEAN;
    priv_pem TEXT;
    pub_pem TEXT;
    key_id TEXT;
    test_date TEXT := 'Thu, 01 Jan 2025 00:00:00 GMT';
    test_body TEXT := '{"type":"Create"}';
    test_digest TEXT;
BEGIN
    -- Get alice's key
    SELECT k.private_key_pem, k.public_key_pem, k.key_id
    INTO priv_pem, pub_pem, key_id
    FROM ap_keys k
    JOIN ap_actors a ON k.actor_id = a.id
    WHERE a.username = 'endpoint_alice' AND a.domain IS NULL;

    test_digest := ap_digest(test_body);

    -- Build signature header (what proxy sends)
    sig_header := ap_build_signature_header(
        key_id, priv_pem,
        'POST', 'https://remote.example/inbox',
        test_date, test_body
    );

    ASSERT sig_header LIKE 'keyId="%', 'sig header: missing keyId';
    ASSERT sig_header LIKE '%algorithm="rsa-sha256"%', 'sig header: missing algorithm';
    ASSERT sig_header LIKE '%signature="%', 'sig header: missing signature';

    -- Verify signature (what remote server does)
    valid := ap_verify_http_signature(
        sig_header,
        'POST', '/inbox', 'remote.example',
        test_date, test_digest, pub_pem
    );
    ASSERT valid, 'HTTP signature round-trip verification failed';

    RAISE NOTICE 'PASS: HTTP Signature round-trip';
END $$;

----------------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------------
DO $$ BEGIN RAISE NOTICE '=========================================='; END $$;
DO $$ BEGIN RAISE NOTICE 'All endpoint tests passed!'; END $$;
DO $$ BEGIN RAISE NOTICE '=========================================='; END $$;
