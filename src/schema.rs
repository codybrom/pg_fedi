use pgrx::prelude::*;

// =============================================================================
// Table definitions
// =============================================================================
// These are created when CREATE EXTENSION pg_fedi is run.
// The enum types are created by pgrx from src/types.rs before these tables,
// ensured by the `requires` clauses.

extension_sql!(
    r#"
-- =========================================================================
-- ap_actors: Both local and remote actors.
-- =========================================================================
CREATE TABLE ap_actors (
    id              BIGSERIAL PRIMARY KEY,
    uri             TEXT UNIQUE NOT NULL,
    actor_type      ApActorType NOT NULL,
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

-- =========================================================================
-- ap_keys: Cryptographic keys for actors (separate table for security).
-- =========================================================================
CREATE TABLE ap_keys (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        BIGINT NOT NULL REFERENCES ap_actors(id) ON DELETE CASCADE,
    key_id          TEXT UNIQUE NOT NULL,       -- e.g. https://example.com/users/alice#main-key
    public_key_pem  TEXT NOT NULL,
    private_key_pem TEXT,                       -- NULL for remote actors
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_keys_actor_id ON ap_keys (actor_id);

-- =========================================================================
-- ap_objects: All content objects (notes, articles, etc.)
-- =========================================================================
CREATE TABLE ap_objects (
    id              BIGSERIAL PRIMARY KEY,
    uri             TEXT UNIQUE NOT NULL,
    object_type     ApObjectType NOT NULL,
    actor_id        BIGINT REFERENCES ap_actors(id) ON DELETE SET NULL,
    in_reply_to_uri TEXT,
    conversation_uri TEXT,
    content         TEXT,                       -- HTML content
    content_text    TEXT,                       -- plain text for search
    summary         TEXT,                       -- CW / content warning
    url             TEXT,                       -- human-browsable URL
    visibility      ApVisibility NOT NULL DEFAULT 'Public',
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

-- =========================================================================
-- ap_activities: The activity log — every federation event.
-- =========================================================================
CREATE TABLE ap_activities (
    id              BIGSERIAL PRIMARY KEY,
    uri             TEXT UNIQUE,
    activity_type   ApActivityType NOT NULL,
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

-- =========================================================================
-- ap_follows: The social graph.
-- =========================================================================
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

-- =========================================================================
-- ap_likes: Like/favourite tracking.
-- =========================================================================
CREATE TABLE ap_likes (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        BIGINT NOT NULL REFERENCES ap_actors(id) ON DELETE CASCADE,
    object_id       BIGINT NOT NULL REFERENCES ap_objects(id) ON DELETE CASCADE,
    uri             TEXT UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(actor_id, object_id)
);

CREATE INDEX idx_likes_object_id ON ap_likes (object_id);

-- =========================================================================
-- ap_announces: Boost/share tracking.
-- =========================================================================
CREATE TABLE ap_announces (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        BIGINT NOT NULL REFERENCES ap_actors(id) ON DELETE CASCADE,
    object_id       BIGINT NOT NULL REFERENCES ap_objects(id) ON DELETE CASCADE,
    uri             TEXT UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(actor_id, object_id)
);

CREATE INDEX idx_announces_object_id ON ap_announces (object_id);

-- =========================================================================
-- ap_blocks: Actor-level and domain-level blocks.
-- =========================================================================
CREATE TABLE ap_blocks (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        BIGINT REFERENCES ap_actors(id) ON DELETE CASCADE,
    blocked_actor_id BIGINT REFERENCES ap_actors(id) ON DELETE CASCADE,
    blocked_domain  TEXT,                       -- for domain blocks (actor_id NULL)
    uri             TEXT UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT block_target CHECK (
        (blocked_actor_id IS NOT NULL AND blocked_domain IS NULL) OR
        (blocked_actor_id IS NULL AND blocked_domain IS NOT NULL)
    )
);

CREATE INDEX idx_blocks_actor ON ap_blocks (actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX idx_blocks_domain ON ap_blocks (blocked_domain) WHERE blocked_domain IS NOT NULL;

-- =========================================================================
-- ap_deliveries: Outbound federation delivery queue.
-- =========================================================================
CREATE TABLE ap_deliveries (
    id              BIGSERIAL PRIMARY KEY,
    activity_id     BIGINT NOT NULL REFERENCES ap_activities(id) ON DELETE CASCADE,
    inbox_uri       TEXT NOT NULL,
    status          ApDeliveryStatus NOT NULL DEFAULT 'Queued',
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

-- =========================================================================
-- ap_actor_stats: Denormalized counters (Mastodon pattern — avoids write
-- contention on the main actors table).
-- =========================================================================
CREATE TABLE ap_actor_stats (
    actor_id        BIGINT PRIMARY KEY REFERENCES ap_actors(id) ON DELETE CASCADE,
    statuses_count  BIGINT NOT NULL DEFAULT 0,
    followers_count BIGINT NOT NULL DEFAULT 0,
    following_count BIGINT NOT NULL DEFAULT 0,
    last_status_at  TIMESTAMPTZ
);
"#,
    name = "schema_tables",
    requires = [
        ApActorType,
        ApActivityType,
        ApObjectType,
        ApVisibility,
        ApDeliveryStatus
    ]
);

// =============================================================================
// Triggers and functions for automatic bookkeeping
// =============================================================================

extension_sql!(
    r#"
-- Auto-create stats row when a new actor is inserted
CREATE OR REPLACE FUNCTION ap_actor_stats_init()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO ap_actor_stats (actor_id) VALUES (NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_actor_stats_init
    AFTER INSERT ON ap_actors
    FOR EACH ROW
    EXECUTE FUNCTION ap_actor_stats_init();

-- Auto-update updated_at on ap_actors
CREATE OR REPLACE FUNCTION ap_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_actors_updated_at
    BEFORE UPDATE ON ap_actors
    FOR EACH ROW
    EXECUTE FUNCTION ap_set_updated_at();

CREATE TRIGGER trg_objects_updated_at
    BEFORE UPDATE ON ap_objects
    FOR EACH ROW
    EXECUTE FUNCTION ap_set_updated_at();

-- Update follower/following counts on follow changes
CREATE OR REPLACE FUNCTION ap_follow_stats_update()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_follow_stats
    AFTER INSERT OR UPDATE OR DELETE ON ap_follows
    FOR EACH ROW
    EXECUTE FUNCTION ap_follow_stats_update();

-- Update status count on object insert/delete
CREATE OR REPLACE FUNCTION ap_status_count_update()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_status_count
    AFTER INSERT OR DELETE ON ap_objects
    FOR EACH ROW
    EXECUTE FUNCTION ap_status_count_update();
"#,
    name = "schema_triggers",
    requires = ["schema_tables"]
);

// =============================================================================
// Convenience views
// =============================================================================

extension_sql!(
    r#"
-- =========================================================================
-- NOTIFY triggers for real-time events
-- =========================================================================

-- Notify when a new delivery is queued (so the worker can react immediately)
CREATE OR REPLACE FUNCTION ap_notify_delivery()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('ap_delivery_queued', NEW.id::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_notify_delivery
    AFTER INSERT ON ap_deliveries
    FOR EACH ROW
    EXECUTE FUNCTION ap_notify_delivery();

-- Notify when a new activity is received from a remote server
CREATE OR REPLACE FUNCTION ap_notify_activity()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_notify_activity
    AFTER INSERT ON ap_activities
    FOR EACH ROW
    EXECUTE FUNCTION ap_notify_activity();

-- Notify when a new object is created
CREATE OR REPLACE FUNCTION ap_notify_object()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('ap_object_created', json_build_object(
        'id', NEW.id,
        'type', NEW.object_type::text,
        'actor_id', NEW.actor_id,
        'visibility', NEW.visibility::text
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_notify_object
    AFTER INSERT ON ap_objects
    FOR EACH ROW
    EXECUTE FUNCTION ap_notify_object();

-- Local actors only
CREATE VIEW ap_local_actors AS
    SELECT a.*, s.statuses_count, s.followers_count, s.following_count, s.last_status_at
    FROM ap_actors a
    JOIN ap_actor_stats s ON s.actor_id = a.id
    WHERE a.domain IS NULL;

-- Public timeline: public, non-deleted objects in reverse chronological order
CREATE VIEW ap_public_timeline AS
    SELECT o.*, a.username, a.domain, a.display_name, a.avatar_url
    FROM ap_objects o
    JOIN ap_actors a ON a.id = o.actor_id
    WHERE o.visibility = 'Public'
      AND o.deleted_at IS NULL
      AND o.in_reply_to_uri IS NULL
    ORDER BY o.published_at DESC NULLS LAST;

-- Local timeline: public objects from local actors
CREATE VIEW ap_local_timeline AS
    SELECT o.*, a.username, a.display_name, a.avatar_url
    FROM ap_objects o
    JOIN ap_actors a ON a.id = o.actor_id
    WHERE o.visibility = 'Public'
      AND o.deleted_at IS NULL
      AND o.in_reply_to_uri IS NULL
      AND a.domain IS NULL
    ORDER BY o.published_at DESC NULLS LAST;
"#,
    name = "schema_views",
    requires = ["schema_tables"]
);
