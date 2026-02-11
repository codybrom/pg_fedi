-- pg_fedi smoke tests
-- Run against any PG15 with the extension installed:
--   psql -v ON_ERROR_STOP=1 -f tests/supabase_smoke.sql

CREATE EXTENSION IF NOT EXISTS pg_fedi;

SET pg_fedi.domain = 'test.example';
SET pg_fedi.https = true;
SET pg_fedi.auto_accept_follows = true;

-- Tables
DO $$
DECLARE
    t TEXT;
    tables TEXT[] := ARRAY[
        'ap_actors','ap_keys','ap_objects','ap_activities',
        'ap_follows','ap_likes','ap_announces','ap_blocks',
        'ap_deliveries','ap_actor_stats'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        PERFORM 1 FROM information_schema.tables WHERE table_name = t;
        IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: table % missing', t; END IF;
    END LOOP;
    RAISE NOTICE 'PASS: all tables exist';
END $$;

-- Enum types
DO $$
BEGIN
    PERFORM 'Person'::ApActorType;
    PERFORM 'Create'::ApActivityType;
    PERFORM 'Note'::ApObjectType;
    PERFORM 'Public'::ApVisibility;
    PERFORM 'Queued'::ApDeliveryStatus;
    RAISE NOTICE 'PASS: enum types';
END $$;

-- Create local actor
DO $$
DECLARE uri TEXT;
BEGIN
    uri := ap_create_local_actor('alice', 'Alice', 'Hello!');
    ASSERT uri = 'https://test.example/users/alice', 'actor URI mismatch';
    PERFORM 1 FROM ap_keys WHERE key_id = 'https://test.example/users/alice#main-key'
        AND private_key_pem IS NOT NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: keypair missing'; END IF;
    RAISE NOTICE 'PASS: create local actor';
END $$;

-- Serialize actor
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_serialize_actor('alice');
    ASSERT doc->>'id' = 'https://test.example/users/alice';
    ASSERT doc->>'type' = 'Person';
    ASSERT doc->'publicKey'->>'publicKeyPem' IS NOT NULL;
    RAISE NOTICE 'PASS: serialize actor';
END $$;

-- WebFinger
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_webfinger('acct:alice@test.example');
    ASSERT doc->>'subject' = 'acct:alice@test.example';
    RAISE NOTICE 'PASS: webfinger';
END $$;

-- Create note
DO $$
DECLARE note_uri TEXT;
BEGIN
    note_uri := ap_create_note('alice', '<p>Hello fediverse!</p>', NULL, NULL);
    ASSERT note_uri LIKE 'https://test.example/users/alice/objects/%';
    PERFORM 1 FROM ap_objects WHERE uri = note_uri;
    IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: note not stored'; END IF;
    PERFORM 1 FROM ap_activities WHERE object_uri = note_uri AND activity_type = 'Create';
    IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Create activity missing'; END IF;
    RAISE NOTICE 'PASS: create note';
END $$;

-- Upsert remote actor
DO $$
DECLARE uri TEXT;
BEGIN
    uri := ap_upsert_remote_actor(
        '{"id":"https://remote.example/users/bob","type":"Person","preferredUsername":"bob",
          "inbox":"https://remote.example/users/bob/inbox",
          "outbox":"https://remote.example/users/bob/outbox",
          "publicKey":{"id":"https://remote.example/users/bob#main-key",
                       "owner":"https://remote.example/users/bob",
                       "publicKeyPem":"-----BEGIN PUBLIC KEY-----\nFAKE\n-----END PUBLIC KEY-----"}}'::json);
    ASSERT uri = 'https://remote.example/users/bob';
    PERFORM 1 FROM ap_actors WHERE username = 'bob' AND domain = 'remote.example';
    IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: remote actor missing'; END IF;
    RAISE NOTICE 'PASS: upsert remote actor';
END $$;

-- Inbox Follow (auto-accept)
DO $$
BEGIN
    PERFORM ap_process_inbox_activity(
        '{"id":"https://remote.example/activities/follow-1","type":"Follow",
          "actor":"https://remote.example/users/bob",
          "object":"https://test.example/users/alice"}'::json);
    PERFORM 1 FROM ap_follows
        WHERE follower_id = (SELECT id FROM ap_actors WHERE uri = 'https://remote.example/users/bob')
        AND following_id = (SELECT id FROM ap_actors WHERE username = 'alice' AND domain IS NULL)
        AND accepted = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: follow not auto-accepted'; END IF;
    PERFORM 1 FROM ap_activities WHERE activity_type = 'Accept' AND local = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Accept not created'; END IF;
    RAISE NOTICE 'PASS: inbox Follow auto-accept';
END $$;

-- Crypto
DO $$
DECLARE d TEXT; pub_pem TEXT; priv_pem TEXT; sig TEXT; valid BOOLEAN;
BEGIN
    d := ap_digest('hello world');
    ASSERT d = 'SHA-256=uU0nuZNNPgilLlLX2n2r+sSE7+N6U4DukIj3rOLvzek=', 'digest mismatch';
    SELECT public_key_pem, private_key_pem INTO pub_pem, priv_pem FROM ap_generate_keypair();
    sig := ap_rsa_sign(priv_pem, 'test data');
    valid := ap_rsa_verify(pub_pem, 'test data', sig);
    ASSERT valid, 'RSA verify failed';
    valid := ap_rsa_verify(pub_pem, 'wrong data', sig);
    ASSERT NOT valid, 'RSA verify should reject wrong data';
    RAISE NOTICE 'PASS: crypto';
END $$;

-- NodeInfo
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_nodeinfo();
    ASSERT doc->>'version' = '2.0';
    ASSERT doc->'software'->>'name' = 'pg_fedi';
    RAISE NOTICE 'PASS: nodeinfo';
END $$;

-- Domain blocking
DO $$
BEGIN
    PERFORM ap_block_domain('evil.example');
    ASSERT ap_is_domain_blocked('evil.example'), 'should be blocked';
    ASSERT NOT ap_is_domain_blocked('good.example'), 'should not be blocked';
    PERFORM ap_unblock_domain('evil.example');
    ASSERT NOT ap_is_domain_blocked('evil.example'), 'should be unblocked';
    RAISE NOTICE 'PASS: domain blocking';
END $$;

-- Full-text search
DO $$
DECLARE cnt BIGINT;
BEGIN
    PERFORM ap_create_note('alice', '<p>The quick brown fox</p>', NULL, NULL);
    PERFORM ap_create_note('alice', '<p>Lazy dog sleeping</p>', NULL, NULL);
    SELECT count(*) INTO cnt FROM ap_search_objects('fox');
    ASSERT cnt = 1, 'search fox expected 1 got ' || cnt;
    RAISE NOTICE 'PASS: full-text search';
END $$;

-- Outbox serialization
DO $$
DECLARE doc JSON;
BEGIN
    doc := ap_serialize_outbox('alice', NULL);
    ASSERT doc->>'type' = 'OrderedCollection';
    RAISE NOTICE 'PASS: outbox serialization';
END $$;

-- Views
DO $$
BEGIN
    PERFORM 1 FROM ap_public_timeline LIMIT 1;
    PERFORM 1 FROM ap_local_timeline LIMIT 1;
    PERFORM 1 FROM ap_local_actors LIMIT 1;
    RAISE NOTICE 'PASS: views';
END $$;

-- Delivery stats
DO $$
BEGIN
    PERFORM 1 FROM ap_delivery_stats();
    RAISE NOTICE 'PASS: delivery stats';
END $$;

DO $$ BEGIN RAISE NOTICE '=========================================='; END $$;
DO $$ BEGIN RAISE NOTICE 'All pg_fedi smoke tests passed!'; END $$;
DO $$ BEGIN RAISE NOTICE '=========================================='; END $$;
