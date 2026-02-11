use pgrx::prelude::*;

// =============================================================================
// Instance (domain) blocking
// =============================================================================

/// Block an entire domain from federating with this instance.
/// All activities from actors on this domain will be rejected.
#[pg_extern]
fn ap_block_domain(domain: &str) {
    Spi::run_with_args(
        "INSERT INTO ap_blocks (blocked_domain)
         VALUES ($1)
         ON CONFLICT DO NOTHING",
        &[domain.into()],
    )
    .expect("failed to block domain");
}

/// Remove a domain block, allowing federation to resume.
#[pg_extern]
fn ap_unblock_domain(domain: &str) {
    Spi::run_with_args(
        "DELETE FROM ap_blocks WHERE blocked_domain = $1",
        &[domain.into()],
    )
    .expect("failed to unblock domain");
}

/// Check if a domain is blocked.
#[pg_extern]
fn ap_is_domain_blocked(domain: &str) -> bool {
    Spi::get_one_with_args::<bool>(
        "SELECT EXISTS(SELECT 1 FROM ap_blocks WHERE blocked_domain = $1)",
        &[domain.into()],
    )
    .unwrap()
    .unwrap_or(false)
}

/// List all blocked domains.
#[pg_extern]
fn ap_blocked_domains() -> TableIterator<
    'static,
    (
        name!(domain, String),
        name!(blocked_at, TimestampWithTimeZone),
    ),
> {
    let rows: Vec<_> = Spi::connect(|client| {
        let mut results = Vec::new();
        let tup_table = client
            .select(
                "SELECT blocked_domain, created_at FROM ap_blocks
                 WHERE blocked_domain IS NOT NULL
                 ORDER BY created_at DESC",
                None,
                &[],
            )
            .expect("failed to query blocked domains");

        for row in tup_table {
            let domain: String = row
                .get_datum_by_ordinal(1)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let blocked_at: TimestampWithTimeZone = row
                .get_datum_by_ordinal(2)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            results.push((domain, blocked_at));
        }

        results
    });

    TableIterator::new(rows)
}

// =============================================================================
// Full-text search
// =============================================================================

/// Search objects by content using the existing GIN full-text search index.
/// Returns matching objects in relevance order.
#[pg_extern]
fn ap_search_objects(
    query: &str,
    max_results: default!(i32, 20),
) -> TableIterator<
    'static,
    (
        name!(uri, String),
        name!(object_type, String),
        name!(content, Option<String>),
        name!(actor_uri, String),
        name!(published_at, Option<TimestampWithTimeZone>),
    ),
> {
    let rows: Vec<_> = Spi::connect(|client| {
        let mut results = Vec::new();
        let tup_table = client
            .select(
                "SELECT o.uri, o.object_type::text, o.content, a.uri, o.published_at
                 FROM ap_objects o
                 JOIN ap_actors a ON a.id = o.actor_id
                 WHERE o.deleted_at IS NULL
                 AND o.visibility = 'Public'
                 AND to_tsvector('simple', coalesce(o.content_text, ''))
                     @@ plainto_tsquery('simple', $1)
                 ORDER BY o.published_at DESC NULLS LAST
                 LIMIT $2",
                None,
                &[query.into(), max_results.into()],
            )
            .expect("failed to search objects");

        for row in tup_table {
            let uri: String = row
                .get_datum_by_ordinal(1)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let object_type: String = row
                .get_datum_by_ordinal(2)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let content: Option<String> = row.get_datum_by_ordinal(3).unwrap().value().unwrap();
            let actor_uri: String = row
                .get_datum_by_ordinal(4)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let published_at: Option<TimestampWithTimeZone> =
                row.get_datum_by_ordinal(5).unwrap().value().unwrap();

            results.push((uri, object_type, content, actor_uri, published_at));
        }

        results
    });

    TableIterator::new(rows)
}

// =============================================================================
// Home timeline
// =============================================================================

/// Get the home timeline for a local user: public objects from actors they follow,
/// plus their own posts, in reverse chronological order.
#[pg_extern]
fn ap_home_timeline(
    username: &str,
    max_results: default!(i32, 20),
    before_id: default!(Option<i64>, "NULL"),
) -> TableIterator<
    'static,
    (
        name!(id, i64),
        name!(uri, String),
        name!(object_type, String),
        name!(content, Option<String>),
        name!(actor_uri, String),
        name!(actor_username, String),
        name!(published_at, Option<TimestampWithTimeZone>),
    ),
> {
    let rows: Vec<_> = Spi::connect(|client| {
        let mut results = Vec::new();

        let query = if before_id.is_some() {
            "SELECT o.id, o.uri, o.object_type::text, o.content, a.uri, a.username, o.published_at
             FROM ap_objects o
             JOIN ap_actors a ON a.id = o.actor_id
             WHERE o.deleted_at IS NULL
             AND o.id < $3
             AND (
                 a.id IN (
                     SELECT f.following_id FROM ap_follows f
                     JOIN ap_actors me ON me.id = f.follower_id
                     WHERE me.username = $1 AND me.domain IS NULL AND f.accepted = true
                 )
                 OR (a.username = $1 AND a.domain IS NULL)
             )
             ORDER BY o.published_at DESC NULLS LAST
             LIMIT $2"
        } else {
            "SELECT o.id, o.uri, o.object_type::text, o.content, a.uri, a.username, o.published_at
             FROM ap_objects o
             JOIN ap_actors a ON a.id = o.actor_id
             WHERE o.deleted_at IS NULL
             AND ($3::bigint IS NULL OR true)
             AND (
                 a.id IN (
                     SELECT f.following_id FROM ap_follows f
                     JOIN ap_actors me ON me.id = f.follower_id
                     WHERE me.username = $1 AND me.domain IS NULL AND f.accepted = true
                 )
                 OR (a.username = $1 AND a.domain IS NULL)
             )
             ORDER BY o.published_at DESC NULLS LAST
             LIMIT $2"
        };

        let tup_table = client
            .select(
                query,
                None,
                &[username.into(), max_results.into(), before_id.into()],
            )
            .expect("failed to query home timeline");

        for row in tup_table {
            let id: i64 = row
                .get_datum_by_ordinal(1)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let uri: String = row
                .get_datum_by_ordinal(2)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let object_type: String = row
                .get_datum_by_ordinal(3)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let content: Option<String> = row.get_datum_by_ordinal(4).unwrap().value().unwrap();
            let actor_uri: String = row
                .get_datum_by_ordinal(5)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let actor_username: String = row
                .get_datum_by_ordinal(6)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let published_at: Option<TimestampWithTimeZone> =
                row.get_datum_by_ordinal(7).unwrap().value().unwrap();

            results.push((
                id,
                uri,
                object_type,
                content,
                actor_uri,
                actor_username,
                published_at,
            ));
        }

        results
    });

    TableIterator::new(rows)
}

// =============================================================================
// Maintenance
// =============================================================================

/// Clean up expired deliveries older than the specified number of days.
/// Returns the number of deleted rows.
#[pg_extern]
fn ap_cleanup_expired_deliveries(older_than_days: default!(i32, 30)) -> i64 {
    Spi::get_one_with_args::<i64>(
        "WITH deleted AS (
            DELETE FROM ap_deliveries
            WHERE status = 'Expired'
            AND created_at < now() - ($1 || ' days')::interval
            RETURNING id
         )
         SELECT count(*) FROM deleted",
        &[older_than_days.into()],
    )
    .unwrap()
    .unwrap_or(0)
}

/// Recalculate all actor stats from source data.
/// Useful if stats get out of sync due to manual data changes.
#[pg_extern]
fn ap_refresh_actor_stats() -> i64 {
    Spi::get_one::<i64>(
        "WITH updated AS (
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
         SELECT count(*) FROM updated",
    )
    .unwrap()
    .unwrap_or(0)
}
