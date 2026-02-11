-- pg_fedi 0.2.0 — ActivityPub federation for PostgreSQL (pg_tle edition)
--
-- This file implements the full pg_fedi extension in PL/pgSQL, suitable for
-- installation via pg_tle on managed Postgres (e.g. Supabase) or standalone.
--
-- Cryptographic operations (RSA keypair generation, HTTP Signature signing/
-- verification) are NOT included — they must be handled by the application
-- layer (e.g. Cloudflare Workers, Edge Functions). The only crypto function
-- retained is ap_digest(), which uses pgcrypto for SHA-256 hashing.
--
-- Requires: pgcrypto extension (for ap_digest)

-- =========================================================================
-- 1. ENUM TYPES
-- =========================================================================

CREATE TYPE ap_actor_type AS ENUM (
    'Person', 'Group', 'Application', 'Service', 'Organization'
);

CREATE TYPE ap_activity_type AS ENUM (
    'Create', 'Update', 'Delete', 'Follow', 'Accept', 'Reject',
    'Like', 'Announce', 'Undo', 'Block', 'Flag', 'Move', 'Add', 'Remove'
);

CREATE TYPE ap_object_type AS ENUM (
    'Note', 'Article', 'Image', 'Video', 'Audio', 'Page',
    'Event', 'Question', 'Document'
);

CREATE TYPE ap_visibility AS ENUM (
    'Public', 'Unlisted', 'FollowersOnly', 'Direct'
);

CREATE TYPE ap_delivery_status AS ENUM (
    'Queued', 'Delivered', 'Failed', 'Expired'
);

-- =========================================================================
-- 2. SETTINGS TABLE (replaces GUC variables)
-- =========================================================================

CREATE TABLE ap_settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT INTO ap_settings (key, value) VALUES
    ('domain', ''),
    ('https', 'true'),
    ('auto_accept_follows', 'true'),
    ('max_delivery_attempts', '8'),
    ('delivery_timeout_seconds', '30'),
    ('user_agent', 'pg_fedi/0.2.0');

CREATE FUNCTION ap_get_setting(p_key TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT value FROM ap_settings WHERE key = p_key;
$$;

CREATE FUNCTION ap_set_setting(p_key TEXT, p_value TEXT) RETURNS VOID
LANGUAGE sql AS $$
    INSERT INTO ap_settings (key, value) VALUES (p_key, p_value)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
$$;

CREATE FUNCTION ap_base_url() RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN ap_get_setting('https') = 'true' THEN 'https' ELSE 'http' END
        || '://' || ap_get_setting('domain');
$$;

-- =========================================================================
-- 3. CORE TABLES
-- =========================================================================

-- Actors: both local and remote
CREATE TABLE ap_actors (
    id              BIGSERIAL PRIMARY KEY,
    uri             TEXT UNIQUE NOT NULL,
    actor_type      ap_actor_type NOT NULL,
    username        TEXT NOT NULL,
    domain          TEXT,                       -- NULL = local actor
    display_name    TEXT,
    summary         TEXT,
    inbox_uri       TEXT NOT NULL,
    outbox_uri      TEXT NOT NULL,
    shared_inbox_uri TEXT,
    followers_uri   TEXT,
    following_uri   TEXT,
    featured_uri    TEXT,
    avatar_url      TEXT,
    header_url      TEXT,
    manually_approves_followers BOOLEAN NOT NULL DEFAULT false,
    discoverable    BOOLEAN NOT NULL DEFAULT true,
    memorial        BOOLEAN NOT NULL DEFAULT false,
    raw             JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_fetched_at TIMESTAMPTZ,
    UNIQUE(username, domain)
);

CREATE INDEX idx_actors_domain ON ap_actors (domain);
CREATE INDEX idx_actors_username_lower ON ap_actors (lower(username));
CREATE INDEX idx_actors_local ON ap_actors ((domain IS NULL)) WHERE domain IS NULL;
CREATE INDEX idx_actors_updated_at ON ap_actors (updated_at);

-- Cryptographic keys for actors
CREATE TABLE ap_keys (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        BIGINT NOT NULL REFERENCES ap_actors(id) ON DELETE CASCADE,
    key_id          TEXT UNIQUE NOT NULL,
    public_key_pem  TEXT NOT NULL,
    private_key_pem TEXT,                       -- NULL for remote actors
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_keys_actor_id ON ap_keys (actor_id);

-- Content objects (notes, articles, etc.)
CREATE TABLE ap_objects (
    id              BIGSERIAL PRIMARY KEY,
    uri             TEXT UNIQUE NOT NULL,
    object_type     ap_object_type NOT NULL,
    actor_id        BIGINT REFERENCES ap_actors(id) ON DELETE SET NULL,
    in_reply_to_uri TEXT,
    conversation_uri TEXT,
    content         TEXT,                       -- HTML content
    content_text    TEXT,                       -- plain text for search
    summary         TEXT,                       -- CW / content warning
    url             TEXT,                       -- human-browsable URL
    visibility      ap_visibility NOT NULL DEFAULT 'Public',
    sensitive       BOOLEAN NOT NULL DEFAULT false,
    language        TEXT,                       -- ISO 639 code
    published_at    TIMESTAMPTZ,
    edited_at       TIMESTAMPTZ,
    deleted_at      TIMESTAMPTZ,               -- soft delete
    raw             JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_objects_actor_id ON ap_objects (actor_id);
CREATE INDEX idx_objects_in_reply_to ON ap_objects (in_reply_to_uri) WHERE in_reply_to_uri IS NOT NULL;
CREATE INDEX idx_objects_conversation ON ap_objects (conversation_uri) WHERE conversation_uri IS NOT NULL;
CREATE INDEX idx_objects_visibility ON ap_objects (visibility);
CREATE INDEX idx_objects_published_at ON ap_objects (published_at DESC);
CREATE INDEX idx_objects_not_deleted ON ap_objects (id) WHERE deleted_at IS NULL;
CREATE INDEX idx_objects_content_search ON ap_objects USING gin (to_tsvector('simple', coalesce(content_text, '')));

-- Activity log
CREATE TABLE ap_activities (
    id              BIGSERIAL PRIMARY KEY,
    uri             TEXT UNIQUE,
    activity_type   ap_activity_type NOT NULL,
    actor_id        BIGINT REFERENCES ap_actors(id) ON DELETE SET NULL,
    object_uri      TEXT,
    target_uri      TEXT,
    to_uris         TEXT[],
    cc_uris         TEXT[],
    raw             JSONB,
    local           BOOLEAN NOT NULL DEFAULT false,
    processed       BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_activities_actor_id ON ap_activities (actor_id);
CREATE INDEX idx_activities_object_uri ON ap_activities (object_uri) WHERE object_uri IS NOT NULL;
CREATE INDEX idx_activities_type ON ap_activities (activity_type);
CREATE INDEX idx_activities_local ON ap_activities (local) WHERE local = true;
CREATE INDEX idx_activities_unprocessed ON ap_activities (id) WHERE processed = false;
CREATE INDEX idx_activities_created_at ON ap_activities (created_at DESC);

-- Social graph
CREATE TABLE ap_follows (
    id              BIGSERIAL PRIMARY KEY,
    follower_id     BIGINT NOT NULL REFERENCES ap_actors(id) ON DELETE CASCADE,
    following_id    BIGINT NOT NULL REFERENCES ap_actors(id) ON DELETE CASCADE,
    uri             TEXT UNIQUE,
    accepted        BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(follower_id, following_id)
);

CREATE INDEX idx_follows_follower ON ap_follows (follower_id);
CREATE INDEX idx_follows_following ON ap_follows (following_id);
CREATE INDEX idx_follows_accepted ON ap_follows (accepted);

-- Likes
CREATE TABLE ap_likes (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        BIGINT NOT NULL REFERENCES ap_actors(id) ON DELETE CASCADE,
    object_id       BIGINT NOT NULL REFERENCES ap_objects(id) ON DELETE CASCADE,
    uri             TEXT UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(actor_id, object_id)
);

CREATE INDEX idx_likes_object_id ON ap_likes (object_id);

-- Boosts/shares
CREATE TABLE ap_announces (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        BIGINT NOT NULL REFERENCES ap_actors(id) ON DELETE CASCADE,
    object_id       BIGINT NOT NULL REFERENCES ap_objects(id) ON DELETE CASCADE,
    uri             TEXT UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(actor_id, object_id)
);

CREATE INDEX idx_announces_object_id ON ap_announces (object_id);

-- Domain and actor blocks
CREATE TABLE ap_blocks (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        BIGINT REFERENCES ap_actors(id) ON DELETE CASCADE,
    blocked_actor_id BIGINT REFERENCES ap_actors(id) ON DELETE CASCADE,
    blocked_domain  TEXT,
    uri             TEXT UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT block_target CHECK (
        (blocked_actor_id IS NOT NULL AND blocked_domain IS NULL) OR
        (blocked_actor_id IS NULL AND blocked_domain IS NOT NULL)
    )
);

CREATE INDEX idx_blocks_actor ON ap_blocks (actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX idx_blocks_domain ON ap_blocks (blocked_domain) WHERE blocked_domain IS NOT NULL;

-- Outbound delivery queue
CREATE TABLE ap_deliveries (
    id              BIGSERIAL PRIMARY KEY,
    activity_id     BIGINT NOT NULL REFERENCES ap_activities(id) ON DELETE CASCADE,
    inbox_uri       TEXT NOT NULL,
    status          ap_delivery_status NOT NULL DEFAULT 'Queued',
    attempts        INT NOT NULL DEFAULT 0,
    last_attempt_at TIMESTAMPTZ,
    next_retry_at   TIMESTAMPTZ DEFAULT now(),
    last_error      TEXT,
    last_status_code INT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_deliveries_pending ON ap_deliveries (next_retry_at)
    WHERE status = 'Queued' OR status = 'Failed';
CREATE INDEX idx_deliveries_activity ON ap_deliveries (activity_id);
CREATE INDEX idx_deliveries_status ON ap_deliveries (status);

-- Denormalized actor stats
CREATE TABLE ap_actor_stats (
    actor_id        BIGINT PRIMARY KEY REFERENCES ap_actors(id) ON DELETE CASCADE,
    statuses_count  BIGINT NOT NULL DEFAULT 0,
    followers_count BIGINT NOT NULL DEFAULT 0,
    following_count BIGINT NOT NULL DEFAULT 0,
    last_status_at  TIMESTAMPTZ
);

-- =========================================================================
-- 4. BOOKKEEPING TRIGGERS
-- =========================================================================

-- Auto-create stats row when a new actor is inserted
CREATE FUNCTION ap_actor_stats_init() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ap_actor_stats (actor_id) VALUES (NEW.id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_actor_stats_init
    AFTER INSERT ON ap_actors
    FOR EACH ROW EXECUTE FUNCTION ap_actor_stats_init();

-- Auto-update updated_at
CREATE FUNCTION ap_set_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_actors_updated_at
    BEFORE UPDATE ON ap_actors
    FOR EACH ROW EXECUTE FUNCTION ap_set_updated_at();

CREATE TRIGGER trg_objects_updated_at
    BEFORE UPDATE ON ap_objects
    FOR EACH ROW EXECUTE FUNCTION ap_set_updated_at();

-- Update follower/following counts on follow changes
CREATE FUNCTION ap_follow_stats_update() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.accepted THEN
        UPDATE ap_actor_stats SET followers_count = followers_count + 1 WHERE actor_id = NEW.following_id;
        UPDATE ap_actor_stats SET following_count = following_count + 1 WHERE actor_id = NEW.follower_id;
    ELSIF TG_OP = 'UPDATE' AND NEW.accepted AND NOT OLD.accepted THEN
        UPDATE ap_actor_stats SET followers_count = followers_count + 1 WHERE actor_id = NEW.following_id;
        UPDATE ap_actor_stats SET following_count = following_count + 1 WHERE actor_id = NEW.follower_id;
    ELSIF TG_OP = 'UPDATE' AND NOT NEW.accepted AND OLD.accepted THEN
        UPDATE ap_actor_stats SET followers_count = GREATEST(followers_count - 1, 0) WHERE actor_id = NEW.following_id;
        UPDATE ap_actor_stats SET following_count = GREATEST(following_count - 1, 0) WHERE actor_id = NEW.follower_id;
    ELSIF TG_OP = 'DELETE' AND OLD.accepted THEN
        UPDATE ap_actor_stats SET followers_count = GREATEST(followers_count - 1, 0) WHERE actor_id = OLD.following_id;
        UPDATE ap_actor_stats SET following_count = GREATEST(following_count - 1, 0) WHERE actor_id = OLD.follower_id;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_follow_stats
    AFTER INSERT OR UPDATE OR DELETE ON ap_follows
    FOR EACH ROW EXECUTE FUNCTION ap_follow_stats_update();

-- Update status count on object insert/delete
CREATE FUNCTION ap_status_count_update() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.actor_id IS NOT NULL THEN
        UPDATE ap_actor_stats
        SET statuses_count = statuses_count + 1,
            last_status_at = COALESCE(NEW.published_at, now())
        WHERE actor_id = NEW.actor_id;
    ELSIF TG_OP = 'DELETE' AND OLD.actor_id IS NOT NULL THEN
        UPDATE ap_actor_stats
        SET statuses_count = GREATEST(statuses_count - 1, 0)
        WHERE actor_id = OLD.actor_id;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_status_count
    AFTER INSERT OR DELETE ON ap_objects
    FOR EACH ROW EXECUTE FUNCTION ap_status_count_update();

-- =========================================================================
-- 5. NOTIFY TRIGGERS
-- =========================================================================

CREATE FUNCTION ap_notify_delivery() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ap_delivery_queued', NEW.id::text);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_notify_delivery
    AFTER INSERT ON ap_deliveries
    FOR EACH ROW EXECUTE FUNCTION ap_notify_delivery();

CREATE FUNCTION ap_notify_activity() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.local THEN
        PERFORM pg_notify('ap_activity_received', json_build_object(
            'id', NEW.id,
            'type', NEW.activity_type::text,
            'actor_id', NEW.actor_id
        )::text);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_notify_activity
    AFTER INSERT ON ap_activities
    FOR EACH ROW EXECUTE FUNCTION ap_notify_activity();

CREATE FUNCTION ap_notify_object() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ap_object_created', json_build_object(
        'id', NEW.id,
        'type', NEW.object_type::text,
        'actor_id', NEW.actor_id,
        'visibility', NEW.visibility::text
    )::text);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_notify_object
    AFTER INSERT ON ap_objects
    FOR EACH ROW EXECUTE FUNCTION ap_notify_object();

-- =========================================================================
-- 6. VIEWS
-- =========================================================================

CREATE VIEW ap_local_actors AS
    SELECT a.*, s.statuses_count, s.followers_count, s.following_count, s.last_status_at
    FROM ap_actors a
    JOIN ap_actor_stats s ON s.actor_id = a.id
    WHERE a.domain IS NULL;

CREATE VIEW ap_public_timeline AS
    SELECT o.*, a.username, a.domain, a.display_name, a.avatar_url
    FROM ap_objects o
    JOIN ap_actors a ON a.id = o.actor_id
    WHERE o.visibility = 'Public'
      AND o.deleted_at IS NULL
      AND o.in_reply_to_uri IS NULL
    ORDER BY o.published_at DESC NULLS LAST;

CREATE VIEW ap_local_timeline AS
    SELECT o.*, a.username, a.display_name, a.avatar_url
    FROM ap_objects o
    JOIN ap_actors a ON a.id = o.actor_id
    WHERE o.visibility = 'Public'
      AND o.deleted_at IS NULL
      AND o.in_reply_to_uri IS NULL
      AND a.domain IS NULL
    ORDER BY o.published_at DESC NULLS LAST;

-- =========================================================================
-- 7. INTERNAL HELPER FUNCTIONS
-- =========================================================================

-- Strip HTML tags (naive but sufficient for FTS)
CREATE FUNCTION _ap_strip_html(p_html TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(p_html, '<[^>]*>', '', 'g');
$$;

-- Extract domain from a URI
CREATE FUNCTION _ap_parse_domain(p_uri TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT split_part(split_part(regexp_replace(p_uri, '^https?://', ''), '/', 1), ':', 1);
$$;

-- Extract a text array from a JSONB field (handles string or array values)
CREATE FUNCTION _ap_jsonb_text_array(p_obj JSONB, p_key TEXT) RETURNS TEXT[]
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_obj->p_key IS NULL THEN
        RETURN NULL;
    ELSIF jsonb_typeof(p_obj->p_key) = 'array' THEN
        RETURN ARRAY(SELECT jsonb_array_elements_text(p_obj->p_key));
    ELSIF jsonb_typeof(p_obj->p_key) = 'string' THEN
        RETURN ARRAY[p_obj->>p_key];
    ELSE
        RETURN NULL;
    END IF;
END;
$$;

-- Extract object URI from activity JSON (handles string or object with "id")
CREATE FUNCTION _ap_extract_object_uri(p_obj JSONB) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN jsonb_typeof(p_obj->'object') = 'string' THEN p_obj->>'object'
        WHEN jsonb_typeof(p_obj->'object') = 'object' THEN p_obj->'object'->>'id'
        ELSE NULL
    END;
$$;

-- Resolve an actor URI to a database ID, creating a stub if needed
CREATE FUNCTION _ap_resolve_actor_id(p_actor_uri TEXT) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT;
    v_domain TEXT;
    v_username TEXT;
BEGIN
    SELECT id INTO v_id FROM ap_actors WHERE uri = p_actor_uri;
    IF v_id IS NOT NULL THEN
        RETURN v_id;
    END IF;

    -- Create a stub for the remote actor
    v_domain := _ap_parse_domain(p_actor_uri);
    v_username := reverse(split_part(reverse(p_actor_uri), '/', 1));

    INSERT INTO ap_actors (uri, actor_type, username, domain, inbox_uri, outbox_uri)
    VALUES (p_actor_uri, 'Person', v_username, v_domain,
            p_actor_uri || '/inbox', p_actor_uri || '/outbox')
    ON CONFLICT (uri) DO UPDATE SET uri = EXCLUDED.uri
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- =========================================================================
-- 8. CRYPTO (pgcrypto-based, app layer handles RSA)
-- =========================================================================

-- SHA-256 digest for HTTP Digest header (requires pgcrypto)
CREATE FUNCTION ap_digest(p_body TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT 'SHA-256=' || encode(digest(p_body::bytea, 'sha256'), 'base64');
$$;

-- =========================================================================
-- 9. ACTOR FUNCTIONS
-- =========================================================================

-- Create a local actor. Keys are optional — the application layer generates
-- RSA keypairs and passes them in. If omitted, the actor is created without
-- keys (they can be added later via direct INSERT into ap_keys).
CREATE FUNCTION ap_create_local_actor(
    p_username TEXT,
    p_display_name TEXT DEFAULT NULL,
    p_summary TEXT DEFAULT NULL,
    p_public_key_pem TEXT DEFAULT NULL,
    p_private_key_pem TEXT DEFAULT NULL
) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_base TEXT := ap_base_url();
    v_uri TEXT;
    v_actor_id BIGINT;
BEGIN
    v_uri := v_base || '/users/' || p_username;

    INSERT INTO ap_actors (
        uri, actor_type, username, display_name, summary,
        inbox_uri, outbox_uri, followers_uri, following_uri,
        featured_uri, shared_inbox_uri
    ) VALUES (
        v_uri, 'Person', p_username, p_display_name, p_summary,
        v_uri || '/inbox',
        v_uri || '/outbox',
        v_uri || '/followers',
        v_uri || '/following',
        v_uri || '/collections/featured',
        v_base || '/inbox'
    )
    RETURNING id INTO v_actor_id;

    IF p_public_key_pem IS NOT NULL THEN
        INSERT INTO ap_keys (actor_id, key_id, public_key_pem, private_key_pem)
        VALUES (v_actor_id, v_uri || '#main-key', p_public_key_pem, p_private_key_pem);
    END IF;

    RETURN v_uri;
END;
$$;

-- Upsert a remote actor from raw ActivityStreams JSON
CREATE FUNCTION ap_upsert_remote_actor(p_actor_json JSONB) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_uri TEXT;
    v_actor_type TEXT;
    v_pg_actor_type TEXT;
    v_domain TEXT;
    v_key_id TEXT;
    v_public_key_pem TEXT;
BEGIN
    v_uri := p_actor_json->>'id';
    v_actor_type := COALESCE(p_actor_json->>'type', 'Person');
    v_domain := _ap_parse_domain(v_uri);

    -- Map to valid enum value
    v_pg_actor_type := CASE v_actor_type
        WHEN 'Person' THEN 'Person'
        WHEN 'Group' THEN 'Group'
        WHEN 'Application' THEN 'Application'
        WHEN 'Service' THEN 'Service'
        WHEN 'Organization' THEN 'Organization'
        ELSE 'Person'
    END;

    INSERT INTO ap_actors (
        uri, actor_type, username, domain, display_name, summary,
        inbox_uri, outbox_uri, followers_uri, following_uri, featured_uri,
        shared_inbox_uri, avatar_url, header_url,
        manually_approves_followers, discoverable, raw, last_fetched_at
    ) VALUES (
        v_uri,
        v_pg_actor_type::ap_actor_type,
        p_actor_json->>'preferredUsername',
        v_domain,
        p_actor_json->>'name',
        p_actor_json->>'summary',
        p_actor_json->>'inbox',
        p_actor_json->>'outbox',
        p_actor_json->>'followers',
        p_actor_json->>'following',
        COALESCE(p_actor_json->'featured'->>'id', p_actor_json->>'featured'),
        p_actor_json->'endpoints'->>'sharedInbox',
        p_actor_json->'icon'->>'url',
        p_actor_json->'image'->>'url',
        COALESCE((p_actor_json->>'manuallyApprovesFollowers')::boolean, false),
        COALESCE((p_actor_json->>'discoverable')::boolean, true),
        p_actor_json,
        now()
    )
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
        last_fetched_at = now();

    -- Upsert public key if present
    v_key_id := p_actor_json->'publicKey'->>'id';
    v_public_key_pem := p_actor_json->'publicKey'->>'publicKeyPem';

    IF v_key_id IS NOT NULL AND v_public_key_pem IS NOT NULL THEN
        INSERT INTO ap_keys (actor_id, key_id, public_key_pem)
        VALUES ((SELECT id FROM ap_actors WHERE uri = v_uri), v_key_id, v_public_key_pem)
        ON CONFLICT (key_id) DO UPDATE SET public_key_pem = EXCLUDED.public_key_pem;
    END IF;

    RETURN v_uri;
END;
$$;

-- Serialize a local actor to full ActivityStreams JSON-LD
CREATE FUNCTION ap_serialize_actor(p_username TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base TEXT := ap_base_url();
    v_actor RECORD;
    v_result JSONB;
BEGIN
    SELECT a.*, k.public_key_pem, k.key_id
    INTO v_actor
    FROM ap_actors a
    LEFT JOIN ap_keys k ON k.actor_id = a.id
    WHERE a.username = p_username AND a.domain IS NULL;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'actor not found: %', p_username;
    END IF;

    v_result := jsonb_build_object(
        '@context', jsonb_build_array(
            'https://www.w3.org/ns/activitystreams',
            'https://w3id.org/security/v1',
            jsonb_build_object(
                'manuallyApprovesFollowers', 'as:manuallyApprovesFollowers',
                'toot', 'http://joinmastodon.org/ns#',
                'featured', jsonb_build_object('@id', 'toot:featured', '@type', '@id'),
                'discoverable', 'toot:discoverable',
                'schema', 'http://schema.org#',
                'PropertyValue', 'schema:PropertyValue',
                'value', 'schema:value'
            )
        ),
        'id', v_actor.uri,
        'type', v_actor.actor_type::text,
        'preferredUsername', v_actor.username,
        'inbox', v_actor.inbox_uri,
        'outbox', v_actor.outbox_uri,
        'url', v_base || '/@' || v_actor.username,
        'manuallyApprovesFollowers', v_actor.manually_approves_followers,
        'discoverable', v_actor.discoverable
    );

    IF v_actor.display_name IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('name', v_actor.display_name);
    END IF;
    IF v_actor.summary IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('summary', v_actor.summary);
    END IF;
    IF v_actor.followers_uri IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('followers', v_actor.followers_uri);
    END IF;
    IF v_actor.following_uri IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('following', v_actor.following_uri);
    END IF;
    IF v_actor.featured_uri IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('featured', v_actor.featured_uri);
    END IF;
    IF v_actor.key_id IS NOT NULL AND v_actor.public_key_pem IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('publicKey', jsonb_build_object(
            'id', v_actor.key_id,
            'owner', v_actor.uri,
            'publicKeyPem', v_actor.public_key_pem
        ));
    END IF;
    IF v_actor.shared_inbox_uri IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('endpoints', jsonb_build_object(
            'sharedInbox', v_actor.shared_inbox_uri
        ));
    END IF;
    IF v_actor.avatar_url IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('icon', jsonb_build_object(
            'type', 'Image', 'url', v_actor.avatar_url
        ));
    END IF;
    IF v_actor.header_url IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('image', jsonb_build_object(
            'type', 'Image', 'url', v_actor.header_url
        ));
    END IF;

    RETURN v_result;
END;
$$;

-- =========================================================================
-- 10. NOTE CREATION (OUTBOX)
-- =========================================================================

CREATE FUNCTION ap_create_note(
    p_username TEXT,
    p_content TEXT,
    p_summary TEXT DEFAULT NULL,
    p_in_reply_to TEXT DEFAULT NULL
) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_base TEXT := ap_base_url();
    v_actor_id BIGINT;
    v_actor_uri TEXT;
    v_object_id BIGINT;
    v_object_uri TEXT;
    v_object_url TEXT;
    v_conversation_uri TEXT;
    v_content_text TEXT;
    v_activity_id BIGINT;
    v_activity_uri TEXT;
    v_followers_uri TEXT;
    v_public TEXT := 'https://www.w3.org/ns/activitystreams#Public';
BEGIN
    SELECT id INTO v_actor_id FROM ap_actors WHERE username = p_username AND domain IS NULL;
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'local actor not found: %', p_username;
    END IF;

    v_actor_uri := v_base || '/users/' || p_username;
    v_object_id := nextval('ap_objects_id_seq');
    v_object_uri := v_actor_uri || '/objects/' || v_object_id;
    v_object_url := v_base || '/@' || p_username || '/' || v_object_id;

    -- Determine conversation URI
    IF p_in_reply_to IS NOT NULL THEN
        SELECT conversation_uri INTO v_conversation_uri
        FROM ap_objects WHERE uri = p_in_reply_to;
    END IF;
    v_conversation_uri := COALESCE(v_conversation_uri, v_base || '/conversations/' || v_object_id);

    v_content_text := _ap_strip_html(p_content);

    INSERT INTO ap_objects (
        id, uri, object_type, actor_id, content, content_text,
        summary, url, visibility, in_reply_to_uri, conversation_uri, published_at
    ) VALUES (
        v_object_id, v_object_uri, 'Note', v_actor_id, p_content, v_content_text,
        p_summary, v_object_url, 'Public', p_in_reply_to, v_conversation_uri, now()
    );

    -- Build Create activity
    v_activity_id := nextval('ap_activities_id_seq');
    v_activity_uri := v_actor_uri || '/activities/' || v_activity_id;
    v_followers_uri := v_actor_uri || '/followers';

    INSERT INTO ap_activities (
        id, uri, activity_type, actor_id, object_uri,
        to_uris, cc_uris, local, processed
    ) VALUES (
        v_activity_id, v_activity_uri, 'Create', v_actor_id, v_object_uri,
        ARRAY[v_public], ARRAY[v_followers_uri], true, true
    );

    -- Queue delivery to all followers
    INSERT INTO ap_deliveries (activity_id, inbox_uri)
    SELECT v_activity_id, COALESCE(a.shared_inbox_uri, a.inbox_uri)
    FROM ap_follows f
    JOIN ap_actors a ON a.id = f.follower_id
    WHERE f.following_id = v_actor_id AND f.accepted = true
      AND a.domain IS NOT NULL;

    RETURN v_object_uri;
END;
$$;

-- =========================================================================
-- 11. INBOX PROCESSING
-- =========================================================================

-- Internal: process a Follow activity
CREATE FUNCTION _ap_process_follow(
    p_activity_id BIGINT,
    p_follower_actor_id BIGINT,
    p_activity JSONB
) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_object_uri TEXT;
    v_activity_uri TEXT;
    v_following_id BIGINT;
    v_auto_accept BOOLEAN;
    v_followed_username TEXT;
    v_base TEXT;
    v_followed_uri TEXT;
    v_follower_inbox TEXT;
    v_accept_id BIGINT;
    v_accept_uri TEXT;
    v_accept_json JSONB;
BEGIN
    v_object_uri := _ap_extract_object_uri(p_activity);
    v_activity_uri := p_activity->>'id';

    SELECT id INTO v_following_id FROM ap_actors WHERE uri = v_object_uri;
    IF v_following_id IS NULL THEN
        RAISE EXCEPTION 'Follow target actor not found: %', v_object_uri;
    END IF;

    v_auto_accept := ap_get_setting('auto_accept_follows') = 'true';

    INSERT INTO ap_follows (follower_id, following_id, uri, accepted)
    VALUES (p_follower_actor_id, v_following_id, v_activity_uri, v_auto_accept)
    ON CONFLICT (follower_id, following_id) DO UPDATE SET
        accepted = EXCLUDED.accepted,
        uri = COALESCE(EXCLUDED.uri, ap_follows.uri);

    -- If auto-accept, send an Accept back (only for local actors)
    IF v_auto_accept THEN
        SELECT username INTO v_followed_username
        FROM ap_actors WHERE id = v_following_id AND domain IS NULL;

        IF v_followed_username IS NOT NULL THEN
            v_base := ap_base_url();
            v_followed_uri := v_base || '/users/' || v_followed_username;

            SELECT inbox_uri INTO v_follower_inbox
            FROM ap_actors WHERE id = p_follower_actor_id;

            v_accept_id := nextval('ap_activities_id_seq');
            v_accept_uri := v_followed_uri || '/activities/' || v_accept_id;

            v_accept_json := jsonb_build_object(
                '@context', 'https://www.w3.org/ns/activitystreams',
                'id', v_accept_uri,
                'type', 'Accept',
                'actor', v_followed_uri,
                'object', p_activity
            );

            INSERT INTO ap_activities (id, uri, activity_type, actor_id, object_uri, raw, local, processed)
            VALUES (v_accept_id, v_accept_uri, 'Accept', v_following_id, v_activity_uri, v_accept_json, true, true);

            INSERT INTO ap_deliveries (activity_id, inbox_uri)
            VALUES (v_accept_id, v_follower_inbox);
        END IF;
    END IF;
END;
$$;

-- Internal: process a Like activity
CREATE FUNCTION _ap_process_like(p_actor_id BIGINT, p_object_uri TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_object_id BIGINT;
BEGIN
    SELECT id INTO v_object_id FROM ap_objects WHERE uri = p_object_uri;
    IF v_object_id IS NOT NULL THEN
        INSERT INTO ap_likes (actor_id, object_id)
        VALUES (p_actor_id, v_object_id)
        ON CONFLICT (actor_id, object_id) DO NOTHING;
    END IF;
END;
$$;

-- Internal: process an Announce activity
CREATE FUNCTION _ap_process_announce(p_actor_id BIGINT, p_object_uri TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_object_id BIGINT;
BEGIN
    SELECT id INTO v_object_id FROM ap_objects WHERE uri = p_object_uri;
    IF v_object_id IS NOT NULL THEN
        INSERT INTO ap_announces (actor_id, object_id)
        VALUES (p_actor_id, v_object_id)
        ON CONFLICT (actor_id, object_id) DO NOTHING;
    END IF;
END;
$$;

-- Internal: process an Undo activity
CREATE FUNCTION _ap_process_undo(p_actor_id BIGINT, p_activity JSONB) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_inner JSONB;
    v_inner_type TEXT;
    v_target_uri TEXT;
BEGIN
    v_inner := p_activity->'object';

    IF jsonb_typeof(v_inner) = 'string' THEN
        -- Object is a URI reference — look up the original activity
        SELECT activity_type::text, object_uri
        INTO v_inner_type, v_target_uri
        FROM ap_activities WHERE uri = v_inner #>> '{}';
        v_inner_type := COALESCE(v_inner_type, '');
    ELSE
        v_inner_type := COALESCE(v_inner->>'type', '');
        v_target_uri := _ap_extract_object_uri(v_inner);
    END IF;

    CASE v_inner_type
        WHEN 'Follow' THEN
            IF v_target_uri IS NULL AND jsonb_typeof(v_inner) = 'string' THEN
                SELECT object_uri INTO v_target_uri
                FROM ap_activities WHERE uri = v_inner #>> '{}';
            END IF;
            IF v_target_uri IS NOT NULL THEN
                DELETE FROM ap_follows
                WHERE follower_id = p_actor_id
                  AND following_id = (SELECT id FROM ap_actors WHERE uri = v_target_uri);
            END IF;

        WHEN 'Like' THEN
            IF v_target_uri IS NULL AND jsonb_typeof(v_inner) = 'string' THEN
                SELECT object_uri INTO v_target_uri
                FROM ap_activities WHERE uri = v_inner #>> '{}';
            END IF;
            IF v_target_uri IS NOT NULL THEN
                DELETE FROM ap_likes
                WHERE actor_id = p_actor_id
                  AND object_id = (SELECT id FROM ap_objects WHERE uri = v_target_uri);
            END IF;

        WHEN 'Announce' THEN
            IF v_target_uri IS NULL AND jsonb_typeof(v_inner) = 'string' THEN
                SELECT object_uri INTO v_target_uri
                FROM ap_activities WHERE uri = v_inner #>> '{}';
            END IF;
            IF v_target_uri IS NOT NULL THEN
                DELETE FROM ap_announces
                WHERE actor_id = p_actor_id
                  AND object_id = (SELECT id FROM ap_objects WHERE uri = v_target_uri);
            END IF;

        ELSE
            RAISE WARNING 'Undo of unsupported type: %', v_inner_type;
    END CASE;
END;
$$;

-- Internal: process a Create activity (store remote content)
CREATE FUNCTION _ap_process_create(p_actor_id BIGINT, p_activity JSONB) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_inner JSONB;
    v_object_type TEXT;
    v_pg_type TEXT;
    v_content TEXT;
    v_published TEXT;
    v_language TEXT;
BEGIN
    v_inner := p_activity->'object';
    IF jsonb_typeof(v_inner) != 'object' THEN RETURN; END IF;

    v_object_type := COALESCE(v_inner->>'type', '');
    v_pg_type := CASE v_object_type
        WHEN 'Note' THEN 'Note' WHEN 'Article' THEN 'Article'
        WHEN 'Page' THEN 'Page' WHEN 'Image' THEN 'Image'
        WHEN 'Video' THEN 'Video' WHEN 'Audio' THEN 'Audio'
        WHEN 'Event' THEN 'Event' WHEN 'Question' THEN 'Question'
        WHEN 'Document' THEN 'Document'
        ELSE NULL
    END;
    IF v_pg_type IS NULL THEN RETURN; END IF;

    v_content := v_inner->>'content';
    v_published := v_inner->>'published';

    -- Extract first language key from contentMap
    SELECT k INTO v_language
    FROM jsonb_object_keys(v_inner->'contentMap') AS k LIMIT 1;

    INSERT INTO ap_objects (
        uri, object_type, actor_id, content, content_text,
        summary, url, in_reply_to_uri, conversation_uri, visibility,
        sensitive, language, published_at, raw
    ) VALUES (
        v_inner->>'id',
        v_pg_type::ap_object_type,
        p_actor_id,
        v_content,
        CASE WHEN v_content IS NOT NULL THEN _ap_strip_html(v_content) ELSE NULL END,
        v_inner->>'summary',
        v_inner->>'url',
        v_inner->>'inReplyTo',
        COALESCE(v_inner->>'conversation', v_inner->>'context'),
        'Public',
        COALESCE((v_inner->>'sensitive')::boolean, false),
        v_language,
        CASE WHEN v_published IS NOT NULL THEN v_published::timestamptz ELSE now() END,
        v_inner
    )
    ON CONFLICT (uri) DO NOTHING;
END;
$$;

-- Internal: process an Update activity
CREATE FUNCTION _ap_process_update(p_actor_id BIGINT, p_activity JSONB) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_inner JSONB;
    v_content TEXT;
BEGIN
    v_inner := p_activity->'object';
    IF jsonb_typeof(v_inner) != 'object' THEN RETURN; END IF;

    v_content := v_inner->>'content';

    UPDATE ap_objects SET
        content = COALESCE(v_content, content),
        content_text = COALESCE(
            CASE WHEN v_content IS NOT NULL THEN _ap_strip_html(v_content) ELSE NULL END,
            content_text
        ),
        summary = COALESCE(v_inner->>'summary', summary),
        sensitive = COALESCE((v_inner->>'sensitive')::boolean, sensitive),
        edited_at = now(),
        raw = v_inner
    WHERE uri = v_inner->>'id' AND actor_id = p_actor_id;
END;
$$;

-- Internal: process a Delete activity (soft-delete)
CREATE FUNCTION _ap_process_delete(p_actor_id BIGINT, p_object_uri TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE ap_objects SET deleted_at = now(), content = NULL, content_text = NULL
    WHERE uri = p_object_uri AND actor_id = p_actor_id;
END;
$$;

-- Internal: process an Accept activity
CREATE FUNCTION _ap_process_accept(p_activity JSONB) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_follow_uri TEXT;
BEGIN
    IF jsonb_typeof(p_activity->'object') = 'string' THEN
        v_follow_uri := p_activity->>'object';
    ELSE
        v_follow_uri := p_activity->'object'->>'id';
    END IF;

    IF v_follow_uri IS NOT NULL THEN
        UPDATE ap_follows SET accepted = true WHERE uri = v_follow_uri;
    END IF;
END;
$$;

-- Internal: process a Reject activity
CREATE FUNCTION _ap_process_reject(p_activity JSONB) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_follow_uri TEXT;
BEGIN
    IF jsonb_typeof(p_activity->'object') = 'string' THEN
        v_follow_uri := p_activity->>'object';
    ELSE
        v_follow_uri := p_activity->'object'->>'id';
    END IF;

    IF v_follow_uri IS NOT NULL THEN
        DELETE FROM ap_follows WHERE uri = v_follow_uri;
    END IF;
END;
$$;

-- Internal: process a Block activity
CREATE FUNCTION _ap_process_block(p_actor_id BIGINT, p_object_uri TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_blocked_id BIGINT;
BEGIN
    SELECT id INTO v_blocked_id FROM ap_actors WHERE uri = p_object_uri;

    IF v_blocked_id IS NOT NULL THEN
        INSERT INTO ap_blocks (actor_id, blocked_actor_id)
        VALUES (p_actor_id, v_blocked_id)
        ON CONFLICT DO NOTHING;

        DELETE FROM ap_follows
        WHERE (follower_id = p_actor_id AND following_id = v_blocked_id)
           OR (follower_id = v_blocked_id AND following_id = p_actor_id);
    END IF;
END;
$$;

-- Main inbox entry point
CREATE FUNCTION ap_process_inbox_activity(p_body JSONB) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_activity_type TEXT;
    v_activity_uri TEXT;
    v_actor_uri TEXT;
    v_actor_id BIGINT;
    v_object_uri TEXT;
    v_target_uri TEXT;
    v_to_uris TEXT[];
    v_cc_uris TEXT[];
    v_stored_id BIGINT;
    v_already BOOLEAN;
    v_blocked BOOLEAN;
BEGIN
    v_activity_type := p_body->>'type';
    v_activity_uri := p_body->>'id';
    v_actor_uri := p_body->>'actor';

    -- Check domain block
    SELECT EXISTS(SELECT 1 FROM ap_blocks WHERE blocked_domain = _ap_parse_domain(v_actor_uri))
    INTO v_blocked;
    IF v_blocked THEN RETURN ''; END IF;

    -- De-duplicate
    IF v_activity_uri IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM ap_activities WHERE uri = v_activity_uri AND processed = true)
        INTO v_already;
        IF v_already THEN RETURN v_activity_uri; END IF;
    END IF;

    v_actor_id := _ap_resolve_actor_id(v_actor_uri);
    v_object_uri := _ap_extract_object_uri(p_body);
    v_target_uri := p_body->>'target';
    v_to_uris := _ap_jsonb_text_array(p_body, 'to');
    v_cc_uris := _ap_jsonb_text_array(p_body, 'cc');

    -- Store the activity
    INSERT INTO ap_activities (uri, activity_type, actor_id, object_uri, target_uri,
        to_uris, cc_uris, raw, local, processed)
    VALUES (v_activity_uri, v_activity_type::ap_activity_type, v_actor_id, v_object_uri,
        v_target_uri, v_to_uris, v_cc_uris, p_body, false, false)
    ON CONFLICT (uri) DO UPDATE SET processed = false
    RETURNING id INTO v_stored_id;

    -- Dispatch to handler
    CASE v_activity_type
        WHEN 'Follow' THEN
            PERFORM _ap_process_follow(v_stored_id, v_actor_id, p_body);
        WHEN 'Like' THEN
            PERFORM _ap_process_like(v_actor_id, v_object_uri);
        WHEN 'Announce' THEN
            PERFORM _ap_process_announce(v_actor_id, v_object_uri);
        WHEN 'Undo' THEN
            PERFORM _ap_process_undo(v_actor_id, p_body);
        WHEN 'Create' THEN
            PERFORM _ap_process_create(v_actor_id, p_body);
        WHEN 'Update' THEN
            PERFORM _ap_process_update(v_actor_id, p_body);
        WHEN 'Delete' THEN
            PERFORM _ap_process_delete(v_actor_id, v_object_uri);
        WHEN 'Accept' THEN
            PERFORM _ap_process_accept(p_body);
        WHEN 'Reject' THEN
            PERFORM _ap_process_reject(p_body);
        WHEN 'Block' THEN
            PERFORM _ap_process_block(v_actor_id, v_object_uri);
        ELSE
            RAISE WARNING 'unhandled activity type: %', v_activity_type;
    END CASE;

    -- Mark processed
    UPDATE ap_activities SET processed = true WHERE id = v_stored_id;

    RETURN COALESCE(v_activity_uri, '');
END;
$$;

-- =========================================================================
-- 12. SERIALIZATION
-- =========================================================================

-- Serialize a content object to ActivityStreams JSON-LD
CREATE FUNCTION ap_serialize_object(p_object_uri TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_obj RECORD;
    v_result JSONB;
    v_public TEXT := 'https://www.w3.org/ns/activitystreams#Public';
BEGIN
    SELECT o.uri, o.object_type::text AS object_type, o.content, o.summary,
           o.url, o.in_reply_to_uri, o.conversation_uri, o.sensitive,
           o.published_at, o.edited_at, o.language,
           a.uri AS actor_uri, a.username AS actor_username, a.followers_uri
    INTO v_obj
    FROM ap_objects o
    JOIN ap_actors a ON a.id = o.actor_id
    WHERE o.uri = p_object_uri AND o.deleted_at IS NULL;

    IF v_obj IS NULL THEN
        RAISE EXCEPTION 'object not found: %', p_object_uri;
    END IF;

    v_result := jsonb_build_object(
        '@context', 'https://www.w3.org/ns/activitystreams',
        'id', v_obj.uri,
        'type', v_obj.object_type,
        'attributedTo', v_obj.actor_uri,
        'to', jsonb_build_array(v_public),
        'cc', CASE WHEN v_obj.followers_uri IS NOT NULL
              THEN jsonb_build_array(v_obj.followers_uri)
              ELSE '[]'::jsonb END,
        'published', v_obj.published_at
    );

    IF v_obj.content IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('content', v_obj.content);
        IF v_obj.language IS NOT NULL THEN
            v_result := v_result || jsonb_build_object('contentMap',
                jsonb_build_object(v_obj.language, v_obj.content));
        END IF;
    END IF;
    IF v_obj.summary IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('summary', v_obj.summary, 'sensitive', true);
    END IF;
    IF v_obj.url IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('url', v_obj.url);
    END IF;
    IF v_obj.in_reply_to_uri IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('inReplyTo', v_obj.in_reply_to_uri);
    END IF;
    IF v_obj.conversation_uri IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('conversation', v_obj.conversation_uri);
    END IF;
    IF v_obj.edited_at IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('updated', v_obj.edited_at);
    END IF;

    RETURN v_result;
END;
$$;

-- Serialize a stored activity to ActivityStreams JSON-LD
CREATE FUNCTION ap_serialize_activity(p_activity_uri TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_act RECORD;
    v_result JSONB;
BEGIN
    SELECT act.uri, act.activity_type::text AS activity_type,
           a.uri AS actor_uri, act.object_uri, act.target_uri,
           act.to_uris, act.cc_uris, act.raw, act.created_at
    INTO v_act
    FROM ap_activities act
    JOIN ap_actors a ON a.id = act.actor_id
    WHERE act.uri = p_activity_uri;

    IF v_act IS NULL THEN
        RAISE EXCEPTION 'activity not found: %', p_activity_uri;
    END IF;

    -- If raw JSON is stored, use it (adding @context if missing)
    IF v_act.raw IS NOT NULL AND jsonb_typeof(v_act.raw) = 'object' THEN
        v_result := v_act.raw;
        IF v_result->>'@context' IS NULL THEN
            v_result := v_result || jsonb_build_object('@context', 'https://www.w3.org/ns/activitystreams');
        END IF;
        RETURN v_result;
    END IF;

    -- Reconstruct from fields
    v_result := jsonb_build_object(
        '@context', 'https://www.w3.org/ns/activitystreams',
        'id', v_act.uri,
        'type', v_act.activity_type,
        'actor', v_act.actor_uri,
        'published', v_act.created_at
    );

    IF v_act.object_uri IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('object', v_act.object_uri);
    END IF;
    IF v_act.target_uri IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('target', v_act.target_uri);
    END IF;
    IF v_act.to_uris IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('to', to_jsonb(v_act.to_uris));
    END IF;
    IF v_act.cc_uris IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('cc', to_jsonb(v_act.cc_uris));
    END IF;

    RETURN v_result;
END;
$$;

-- Serialize outbox as OrderedCollection / OrderedCollectionPage
CREATE FUNCTION ap_serialize_outbox(p_username TEXT, p_page INT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base TEXT := ap_base_url();
    v_outbox_uri TEXT;
    v_total BIGINT;
    v_offset BIGINT;
    v_items JSONB;
    v_result JSONB;
    v_page_size INT := 20;
BEGIN
    v_outbox_uri := v_base || '/users/' || p_username || '/outbox';

    IF p_page IS NULL THEN
        SELECT count(*) INTO v_total
        FROM ap_activities act
        JOIN ap_actors a ON a.id = act.actor_id
        WHERE a.username = p_username AND a.domain IS NULL
          AND act.local = true AND act.activity_type = 'Create';

        RETURN jsonb_build_object(
            '@context', 'https://www.w3.org/ns/activitystreams',
            'id', v_outbox_uri,
            'type', 'OrderedCollection',
            'totalItems', v_total,
            'first', v_outbox_uri || '?page=1',
            'last', v_outbox_uri || '?page=' || ((v_total / v_page_size) + 1)
        );
    END IF;

    v_offset := (GREATEST(p_page, 1) - 1) * v_page_size;

    SELECT jsonb_agg(ap_serialize_activity(act.uri) ORDER BY act.created_at DESC)
    INTO v_items
    FROM (
        SELECT act.uri, act.created_at
        FROM ap_activities act
        JOIN ap_actors a ON a.id = act.actor_id
        WHERE a.username = p_username AND a.domain IS NULL
          AND act.local = true AND act.activity_type = 'Create'
        ORDER BY act.created_at DESC
        LIMIT v_page_size OFFSET v_offset
    ) act;

    v_items := COALESCE(v_items, '[]'::jsonb);

    v_result := jsonb_build_object(
        '@context', 'https://www.w3.org/ns/activitystreams',
        'id', v_outbox_uri || '?page=' || p_page,
        'type', 'OrderedCollectionPage',
        'partOf', v_outbox_uri,
        'orderedItems', v_items
    );

    IF p_page > 1 THEN
        v_result := v_result || jsonb_build_object('prev', v_outbox_uri || '?page=' || (p_page - 1));
    END IF;
    IF jsonb_array_length(v_items) >= v_page_size THEN
        v_result := v_result || jsonb_build_object('next', v_outbox_uri || '?page=' || (p_page + 1));
    END IF;

    RETURN v_result;
END;
$$;

-- Serialize followers as OrderedCollection / OrderedCollectionPage
CREATE FUNCTION ap_serialize_followers(p_username TEXT, p_page INT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base TEXT := ap_base_url();
    v_collection_uri TEXT;
    v_total BIGINT;
    v_offset BIGINT;
    v_items JSONB;
    v_result JSONB;
    v_page_size INT := 20;
BEGIN
    v_collection_uri := v_base || '/users/' || p_username || '/followers';

    IF p_page IS NULL THEN
        SELECT count(*) INTO v_total
        FROM ap_follows f
        JOIN ap_actors a ON a.id = f.following_id
        WHERE a.username = p_username AND a.domain IS NULL AND f.accepted = true;

        RETURN jsonb_build_object(
            '@context', 'https://www.w3.org/ns/activitystreams',
            'id', v_collection_uri,
            'type', 'OrderedCollection',
            'totalItems', v_total,
            'first', v_collection_uri || '?page=1'
        );
    END IF;

    v_offset := (GREATEST(p_page, 1) - 1) * v_page_size;

    SELECT jsonb_agg(fa.uri ORDER BY f.created_at DESC)
    INTO v_items
    FROM (
        SELECT f.created_at, fa.uri
        FROM ap_follows f
        JOIN ap_actors a ON a.id = f.following_id
        JOIN ap_actors fa ON fa.id = f.follower_id
        WHERE a.username = p_username AND a.domain IS NULL AND f.accepted = true
        ORDER BY f.created_at DESC
        LIMIT v_page_size OFFSET v_offset
    ) sub
    JOIN ap_follows f ON true
    JOIN ap_actors fa ON true
    WHERE false;

    -- Simpler approach for followers
    SELECT jsonb_agg(t.uri)
    INTO v_items
    FROM (
        SELECT fa.uri
        FROM ap_follows f
        JOIN ap_actors a ON a.id = f.following_id
        JOIN ap_actors fa ON fa.id = f.follower_id
        WHERE a.username = p_username AND a.domain IS NULL AND f.accepted = true
        ORDER BY f.created_at DESC
        LIMIT v_page_size OFFSET v_offset
    ) t;

    v_items := COALESCE(v_items, '[]'::jsonb);

    v_result := jsonb_build_object(
        '@context', 'https://www.w3.org/ns/activitystreams',
        'id', v_collection_uri || '?page=' || p_page,
        'type', 'OrderedCollectionPage',
        'partOf', v_collection_uri,
        'orderedItems', v_items
    );

    IF p_page > 1 THEN
        v_result := v_result || jsonb_build_object('prev', v_collection_uri || '?page=' || (p_page - 1));
    END IF;
    IF jsonb_array_length(v_items) >= v_page_size THEN
        v_result := v_result || jsonb_build_object('next', v_collection_uri || '?page=' || (p_page + 1));
    END IF;

    RETURN v_result;
END;
$$;

-- Serialize following list as OrderedCollection / OrderedCollectionPage
CREATE FUNCTION ap_serialize_following(p_username TEXT, p_page INT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base TEXT := ap_base_url();
    v_collection_uri TEXT;
    v_total BIGINT;
    v_offset BIGINT;
    v_items JSONB;
    v_result JSONB;
    v_page_size INT := 20;
BEGIN
    v_collection_uri := v_base || '/users/' || p_username || '/following';

    IF p_page IS NULL THEN
        SELECT count(*) INTO v_total
        FROM ap_follows f
        JOIN ap_actors a ON a.id = f.follower_id
        WHERE a.username = p_username AND a.domain IS NULL AND f.accepted = true;

        RETURN jsonb_build_object(
            '@context', 'https://www.w3.org/ns/activitystreams',
            'id', v_collection_uri,
            'type', 'OrderedCollection',
            'totalItems', v_total,
            'first', v_collection_uri || '?page=1'
        );
    END IF;

    v_offset := (GREATEST(p_page, 1) - 1) * v_page_size;

    SELECT jsonb_agg(t.uri)
    INTO v_items
    FROM (
        SELECT fa.uri
        FROM ap_follows f
        JOIN ap_actors a ON a.id = f.follower_id
        JOIN ap_actors fa ON fa.id = f.following_id
        WHERE a.username = p_username AND a.domain IS NULL AND f.accepted = true
        ORDER BY f.created_at DESC
        LIMIT v_page_size OFFSET v_offset
    ) t;

    v_items := COALESCE(v_items, '[]'::jsonb);

    v_result := jsonb_build_object(
        '@context', 'https://www.w3.org/ns/activitystreams',
        'id', v_collection_uri || '?page=' || p_page,
        'type', 'OrderedCollectionPage',
        'partOf', v_collection_uri,
        'orderedItems', v_items
    );

    IF p_page > 1 THEN
        v_result := v_result || jsonb_build_object('prev', v_collection_uri || '?page=' || (p_page - 1));
    END IF;
    IF jsonb_array_length(v_items) >= v_page_size THEN
        v_result := v_result || jsonb_build_object('next', v_collection_uri || '?page=' || (p_page + 1));
    END IF;

    RETURN v_result;
END;
$$;

-- Featured/pinned posts (empty collection, required for Mastodon compatibility)
CREATE FUNCTION ap_serialize_featured(p_username TEXT) RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        '@context', 'https://www.w3.org/ns/activitystreams',
        'id', ap_base_url() || '/users/' || p_username || '/collections/featured',
        'type', 'OrderedCollection',
        'totalItems', 0,
        'orderedItems', '[]'::jsonb
    );
$$;

-- =========================================================================
-- 13. DELIVERY QUEUE
-- =========================================================================

-- Get pending deliveries for the external worker
CREATE FUNCTION ap_get_pending_deliveries(p_batch_size INT DEFAULT 10)
RETURNS TABLE (
    delivery_id BIGINT,
    inbox_uri TEXT,
    activity_json JSONB,
    actor_uri TEXT,
    key_id TEXT,
    private_key_pem TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT d.id, d.inbox_uri, act.raw, a.uri, k.key_id, k.private_key_pem
    FROM ap_deliveries d
    JOIN ap_activities act ON act.id = d.activity_id
    JOIN ap_actors a ON a.id = act.actor_id
    JOIN ap_keys k ON k.actor_id = a.id
    WHERE (d.status = 'Queued' OR d.status = 'Failed')
      AND d.next_retry_at <= now()
      AND k.private_key_pem IS NOT NULL
    ORDER BY d.next_retry_at
    LIMIT p_batch_size;
$$;

-- Mark delivery as successful
CREATE FUNCTION ap_delivery_success(p_delivery_id BIGINT, p_status_code INT) RETURNS VOID
LANGUAGE sql AS $$
    UPDATE ap_deliveries SET
        status = 'Delivered',
        attempts = attempts + 1,
        last_attempt_at = now(),
        last_status_code = p_status_code
    WHERE id = p_delivery_id;
$$;

-- Mark delivery as failed with exponential backoff retry
CREATE FUNCTION ap_delivery_failure(p_delivery_id BIGINT, p_error TEXT, p_status_code INT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_max_attempts INT;
    v_current_attempts INT;
    v_new_attempts INT;
    v_intervals INT[] := ARRAY[60, 300, 1800, 7200, 43200, 86400, 259200, 604800];
    v_interval_idx INT;
    v_interval_secs INT;
BEGIN
    v_max_attempts := COALESCE(ap_get_setting('max_delivery_attempts')::int, 8);

    SELECT attempts INTO v_current_attempts FROM ap_deliveries WHERE id = p_delivery_id;
    v_new_attempts := COALESCE(v_current_attempts, 0) + 1;

    IF v_new_attempts >= v_max_attempts THEN
        UPDATE ap_deliveries SET
            status = 'Expired',
            attempts = v_new_attempts,
            last_attempt_at = now(),
            last_error = p_error,
            last_status_code = p_status_code
        WHERE id = p_delivery_id;
    ELSE
        v_interval_idx := LEAST(v_new_attempts, array_length(v_intervals, 1));
        v_interval_secs := v_intervals[v_interval_idx];

        UPDATE ap_deliveries SET
            status = 'Failed',
            attempts = v_new_attempts,
            last_attempt_at = now(),
            next_retry_at = now() + (v_interval_secs || ' seconds')::interval,
            last_error = p_error,
            last_status_code = p_status_code
        WHERE id = p_delivery_id;
    END IF;
END;
$$;

-- Delivery queue statistics
CREATE FUNCTION ap_delivery_stats()
RETURNS TABLE (status TEXT, count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT status::text, count(*)
    FROM ap_deliveries
    GROUP BY status
    ORDER BY status;
$$;

-- =========================================================================
-- 14. WEBFINGER & NODEINFO
-- =========================================================================

-- WebFinger response (RFC 7033)
CREATE FUNCTION ap_webfinger(p_resource TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base TEXT := ap_base_url();
    v_domain TEXT := ap_get_setting('domain');
    v_acct TEXT;
    v_username TEXT;
    v_exists BOOLEAN;
    v_actor_uri TEXT;
    v_profile_url TEXT;
BEGIN
    v_acct := ltrim(p_resource, 'acct:');
    v_username := split_part(v_acct, '@', 1);

    SELECT EXISTS(SELECT 1 FROM ap_actors WHERE username = v_username AND domain IS NULL)
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'actor not found: %', v_username;
    END IF;

    v_actor_uri := v_base || '/users/' || v_username;
    v_profile_url := v_base || '/@' || v_username;

    RETURN jsonb_build_object(
        'subject', 'acct:' || v_username || '@' || v_domain,
        'aliases', jsonb_build_array(v_profile_url, v_actor_uri),
        'links', jsonb_build_array(
            jsonb_build_object(
                'rel', 'self',
                'type', 'application/activity+json',
                'href', v_actor_uri
            ),
            jsonb_build_object(
                'rel', 'http://webfinger.net/rel/profile-page',
                'type', 'text/html',
                'href', v_profile_url
            )
        )
    );
END;
$$;

-- host-meta XRD document
CREATE FUNCTION ap_host_meta() RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT format(
        '<?xml version="1.0" encoding="UTF-8"?>
<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
  <Link rel="lhost-meta" type="application/xrd+xml" template="%s/.well-known/webfinger?resource={uri}"/>
</XRD>',
        ap_base_url()
    );
$$;

-- NodeInfo discovery document
CREATE FUNCTION ap_nodeinfo_discovery() RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'links', jsonb_build_array(
            jsonb_build_object(
                'rel', 'http://nodeinfo.diaspora.software/ns/schema/2.0',
                'href', ap_base_url() || '/nodeinfo/2.0'
            )
        )
    );
$$;

-- NodeInfo 2.0 metadata
CREATE FUNCTION ap_nodeinfo() RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_total_users BIGINT;
    v_monthly_active BIGINT;
    v_halfyear_active BIGINT;
    v_local_posts BIGINT;
BEGIN
    SELECT count(*) INTO v_total_users FROM ap_actors WHERE domain IS NULL;

    SELECT count(DISTINCT a.id) INTO v_monthly_active
    FROM ap_actors a
    JOIN ap_activities act ON act.actor_id = a.id
    WHERE a.domain IS NULL AND act.local = true
      AND act.created_at > now() - interval '30 days';

    SELECT count(DISTINCT a.id) INTO v_halfyear_active
    FROM ap_actors a
    JOIN ap_activities act ON act.actor_id = a.id
    WHERE a.domain IS NULL AND act.local = true
      AND act.created_at > now() - interval '180 days';

    SELECT count(*) INTO v_local_posts
    FROM ap_objects o
    JOIN ap_actors a ON a.id = o.actor_id
    WHERE a.domain IS NULL AND o.deleted_at IS NULL;

    RETURN jsonb_build_object(
        'version', '2.0',
        'software', jsonb_build_object('name', 'pg_fedi', 'version', '0.2.0'),
        'protocols', jsonb_build_array('activitypub'),
        'usage', jsonb_build_object(
            'users', jsonb_build_object(
                'total', v_total_users,
                'activeMonth', v_monthly_active,
                'activeHalfyear', v_halfyear_active
            ),
            'localPosts', v_local_posts
        ),
        'openRegistrations', false
    );
END;
$$;

-- =========================================================================
-- 15. ADMINISTRATION
-- =========================================================================

-- Domain blocking
CREATE FUNCTION ap_block_domain(p_domain TEXT) RETURNS VOID
LANGUAGE sql AS $$
    INSERT INTO ap_blocks (blocked_domain) VALUES (p_domain) ON CONFLICT DO NOTHING;
$$;

CREATE FUNCTION ap_unblock_domain(p_domain TEXT) RETURNS VOID
LANGUAGE sql AS $$
    DELETE FROM ap_blocks WHERE blocked_domain = p_domain;
$$;

CREATE FUNCTION ap_is_domain_blocked(p_domain TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM ap_blocks WHERE blocked_domain = p_domain);
$$;

CREATE FUNCTION ap_blocked_domains()
RETURNS TABLE (domain TEXT, blocked_at TIMESTAMPTZ)
LANGUAGE sql STABLE AS $$
    SELECT blocked_domain, created_at
    FROM ap_blocks
    WHERE blocked_domain IS NOT NULL
    ORDER BY created_at DESC;
$$;

-- Full-text search
CREATE FUNCTION ap_search_objects(p_query TEXT, p_max_results INT DEFAULT 20)
RETURNS TABLE (
    uri TEXT,
    object_type TEXT,
    content TEXT,
    actor_uri TEXT,
    published_at TIMESTAMPTZ
)
LANGUAGE sql STABLE AS $$
    SELECT o.uri, o.object_type::text, o.content, a.uri, o.published_at
    FROM ap_objects o
    JOIN ap_actors a ON a.id = o.actor_id
    WHERE o.deleted_at IS NULL
      AND o.visibility = 'Public'
      AND to_tsvector('simple', coalesce(o.content_text, ''))
          @@ plainto_tsquery('simple', p_query)
    ORDER BY o.published_at DESC NULLS LAST
    LIMIT p_max_results;
$$;

-- Home timeline
CREATE FUNCTION ap_home_timeline(
    p_username TEXT,
    p_max_results INT DEFAULT 20,
    p_before_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT,
    uri TEXT,
    object_type TEXT,
    content TEXT,
    actor_uri TEXT,
    actor_username TEXT,
    published_at TIMESTAMPTZ
)
LANGUAGE sql STABLE AS $$
    SELECT o.id, o.uri, o.object_type::text, o.content, a.uri, a.username, o.published_at
    FROM ap_objects o
    JOIN ap_actors a ON a.id = o.actor_id
    WHERE o.deleted_at IS NULL
      AND (p_before_id IS NULL OR o.id < p_before_id)
      AND (
          a.id IN (
              SELECT f.following_id FROM ap_follows f
              JOIN ap_actors me ON me.id = f.follower_id
              WHERE me.username = p_username AND me.domain IS NULL AND f.accepted = true
          )
          OR (a.username = p_username AND a.domain IS NULL)
      )
    ORDER BY o.published_at DESC NULLS LAST
    LIMIT p_max_results;
$$;

-- Maintenance: clean up expired deliveries
CREATE FUNCTION ap_cleanup_expired_deliveries(p_older_than_days INT DEFAULT 30) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_count BIGINT;
BEGIN
    WITH deleted AS (
        DELETE FROM ap_deliveries
        WHERE status = 'Expired'
          AND created_at < now() - (p_older_than_days || ' days')::interval
        RETURNING id
    )
    SELECT count(*) INTO v_count FROM deleted;
    RETURN v_count;
END;
$$;

-- Maintenance: recalculate all actor stats
CREATE FUNCTION ap_refresh_actor_stats() RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_count BIGINT;
BEGIN
    WITH updated AS (
        UPDATE ap_actor_stats s SET
            statuses_count = (
                SELECT count(*) FROM ap_objects o
                WHERE o.actor_id = s.actor_id AND o.deleted_at IS NULL
            ),
            followers_count = (
                SELECT count(*) FROM ap_follows f
                WHERE f.following_id = s.actor_id AND f.accepted = true
            ),
            following_count = (
                SELECT count(*) FROM ap_follows f
                WHERE f.follower_id = s.actor_id AND f.accepted = true
            ),
            last_status_at = (
                SELECT max(published_at) FROM ap_objects o
                WHERE o.actor_id = s.actor_id AND o.deleted_at IS NULL
            )
        RETURNING actor_id
    )
    SELECT count(*) INTO v_count FROM updated;
    RETURN v_count;
END;
$$;
