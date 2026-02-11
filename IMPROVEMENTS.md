# pg_fedi: Recommended Improvements

Comprehensive analysis of the codebase covering robustness, security, performance, testing, and schema design. Findings are prioritized by impact.

---

## 1. Error Handling: Replace Panics with Graceful Errors (High Priority)

The single most impactful improvement. Currently, ~50 `.expect()` calls and ~15 `.unwrap()` calls in production code paths mean malformed ActivityPub JSON from remote servers will crash the PostgreSQL connection rather than returning an error.

### The Problem

`src/activities.rs:126-128`:
```rust
let activity_type = json_str(obj, "type").expect("activity missing 'type'");
let actor_uri = json_str(obj, "actor").expect("activity missing 'actor'");
```

`src/activities.rs:192-193`:
```rust
.expect("failed to store activity")
.expect("no activity id returned");
```

A single malformed federation message (missing `type` or `actor` field) will panic and kill the calling connection. In a production Fediverse environment, remote servers regularly send non-conformant payloads.

### Recommendation

Convert `ap_process_inbox_activity` to use `pgrx::error!()` or return `Option<String>` / `Result`-style handling:

```rust
// Before:
let activity_type = json_str(obj, "type").expect("activity missing 'type'");

// After:
let activity_type = match json_str(obj, "type") {
    Some(t) => t,
    None => {
        pgrx::warning!("pg_fedi: rejecting activity with missing 'type' field");
        return String::new();
    }
};
```

Apply the same pattern to `ap_create_note` (`src/activities.rs:27-28`), `ap_upsert_remote_actor` (`src/actors.rs:77-78`), and `ap_get_pending_deliveries` (`src/delivery.rs:42-77`).

**Files affected:** `activities.rs`, `actors.rs`, `delivery.rs`

---

## 2. HTTP Signature Verification Hardening (High Priority)

### 2a. Algorithm Validation

`src/crypto.rs:237-242` — The `SignatureFields` struct stores `algorithm` but never validates it. Any algorithm value is silently accepted, but the code only performs RSA-SHA256 verification.

```rust
// In ap_verify_http_signature, after parsing:
if let Some(ref alg) = fields.algorithm {
    if alg != "rsa-sha256" {
        pgrx::warning!("pg_fedi: unsupported signature algorithm: {}", alg);
        return false;
    }
}
```

### 2b. Date Freshness Validation

The HTTP Signature verification (`src/crypto.rs:155-210`) includes the `date` header in the signing string but never checks whether the date is recent. This creates a replay attack surface.

Add a configurable clock skew tolerance (e.g., 5 minutes default via GUC):

```rust
// In guc.rs — add new GUC:
// pg_fedi.signature_clock_skew_seconds (default 300)
```

Then validate in `ap_verify_http_signature` before proceeding with cryptographic verification.

### 2c. Signature Header Parsing Edge Cases

`src/crypto.rs:246-290` — The custom parser for `keyId="...",algorithm="..."` does not handle escaped quotes within values. While rare in practice, this could cause verification to silently fail on legitimate signatures from implementations that include `\"` in key IDs.

Consider using a more robust parser or at minimum handling `\"` escape sequences.

**Files affected:** `crypto.rs`, `guc.rs`

---

## 3. HTML Sanitization (High Priority)

`src/activities.rs:713-726` — The `strip_html` function uses a naive character-level approach:

```rust
fn strip_html(html: &str) -> String {
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
```

Issues:
- Nested angle brackets like `<script<script>>` are handled incorrectly
- HTML entities (`&amp;`, `&lt;`) are not decoded
- `<![CDATA[...]]>` content is preserved verbatim

This function generates `content_text` which feeds into the full-text search GIN index. While the security boundary is primarily client-side, the search index will contain garbage for entity-heavy content.

**Recommendation:** Replace with the `ammonia` crate (well-audited HTML sanitizer for Rust) or `html-escape` for entity decoding. Alternatively, document clearly that `content_text` is best-effort and consumers must handle entities.

**Files affected:** `activities.rs`, `Cargo.toml`

---

## 4. Missing Database Indexes (Medium Priority)

Several query patterns in the codebase lack supporting indexes:

### 4a. Home Timeline Query

`src/admin.rs` runs:
```sql
SELECT ... FROM ap_objects o
JOIN ap_follows f ON f.following_id = o.actor_id
WHERE f.follower_id = $1 AND f.accepted = true AND o.deleted_at IS NULL
ORDER BY o.published_at DESC
```

Missing compound index:
```sql
CREATE INDEX idx_follows_follower_accepted
    ON ap_follows (follower_id, following_id) WHERE accepted = true;
```

### 4b. Actor URI Lookups

`resolve_actor_id()` in `activities.rs` queries `ap_actors WHERE uri = $1`. The `uri` column has a UNIQUE constraint (which creates an implicit index), so this is already covered. However, `ap_actors WHERE username = $1 AND domain IS NULL` (used in `ap_create_note`) would benefit from:

```sql
CREATE INDEX idx_actors_local_username
    ON ap_actors (username) WHERE domain IS NULL;
```

### 4c. Object Actor + Visibility

The public timeline view filters `WHERE deleted_at IS NULL AND visibility = 'Public'`:
```sql
CREATE INDEX idx_objects_public_timeline
    ON ap_objects (published_at DESC)
    WHERE deleted_at IS NULL AND visibility = 'Public';
```

**Files affected:** `schema.rs`

---

## 5. Domain Blocking: Subdomain Matching (Medium Priority)

`src/activities.rs:131-141` checks domain blocks with exact matching:
```sql
SELECT EXISTS(SELECT 1 FROM ap_blocks WHERE blocked_domain = $1)
```

Blocking `example.com` does **not** block `evil.example.com`. This is a common Fediverse moderation expectation.

**Recommendation:** Use `LIKE` with a prefix or check both exact and parent domains:
```sql
SELECT EXISTS(
    SELECT 1 FROM ap_blocks
    WHERE blocked_domain = $1
       OR $1 LIKE '%.' || blocked_domain
)
```

Or add a GUC to control this behavior (`pg_fedi.block_subdomains`, default `true`).

**Files affected:** `activities.rs`, optionally `guc.rs`

---

## 6. Delivery Queue: Race Condition on Concurrent Workers (Medium Priority)

`src/delivery.rs:22-93` — `ap_get_pending_deliveries` selects pending deliveries without any locking:

```sql
SELECT d.id, d.inbox_uri, act.raw, ...
FROM ap_deliveries d
WHERE (d.status = 'Queued' OR d.status = 'Failed')
  AND d.next_retry_at <= now()
ORDER BY d.next_retry_at
LIMIT $1
```

If multiple external workers poll concurrently, they will receive overlapping batches and deliver the same activity twice.

**Recommendation:** Use `SELECT ... FOR UPDATE SKIP LOCKED` and immediately mark rows as in-flight:

```sql
WITH batch AS (
    SELECT id FROM ap_deliveries
    WHERE (status = 'Queued' OR status = 'Failed')
      AND next_retry_at <= now()
    ORDER BY next_retry_at
    LIMIT $1
    FOR UPDATE SKIP LOCKED
)
UPDATE ap_deliveries SET status = 'InFlight', last_attempt_at = now()
FROM batch WHERE ap_deliveries.id = batch.id
RETURNING ap_deliveries.id, ...
```

This requires adding `InFlight` to the `ApDeliveryStatus` enum.

**Files affected:** `types.rs`, `delivery.rs`, `schema.rs`

---

## 7. N+1 Query Patterns (Medium Priority)

Several functions make multiple sequential SPI calls where a single query could suffice.

### Example: `process_follow()` in `activities.rs`

The Follow handler:
1. Queries `ap_actors` for the target actor
2. Inserts into `ap_follows`
3. If auto-accept: inserts an Accept activity into `ap_activities`
4. Inserts into `ap_deliveries`

This is 4 separate SPI calls per Follow. A CTE-based approach could combine steps 2-4:

```sql
WITH new_follow AS (
    INSERT INTO ap_follows (follower_id, following_id, uri, accepted)
    VALUES ($1, $2, $3, $4) RETURNING *
), new_activity AS (
    INSERT INTO ap_activities (...) SELECT ... FROM new_follow RETURNING id
)
INSERT INTO ap_deliveries (activity_id, inbox_uri) SELECT ... FROM new_activity;
```

This reduces round-trips from 4 to 2 (actor lookup + combined CTE).

**Files affected:** `activities.rs`

---

## 8. Test Coverage Gaps (Medium Priority)

The 34 existing tests cover happy paths well. Missing test categories:

### 8a. Malformed Input Tests
```rust
#[pg_test]
fn test_inbox_missing_type_field() {
    // Should return empty string, not panic
    let result = Spi::get_one::<String>(
        "SELECT ap_process_inbox_activity('{\"actor\": \"https://remote.example/u/bob\"}'::json)"
    );
    // Assert no panic, graceful handling
}
```

### 8b. Duplicate Activity Deduplication
```rust
#[pg_test]
fn test_duplicate_activity_ignored() {
    // Process same activity twice, verify idempotent
}
```

### 8c. Domain Block Enforcement Across Handlers
- Follow from blocked domain
- Create from blocked domain
- Like from blocked domain

### 8d. Delete Cascade Verification
- Delete an actor, verify all activities/objects/follows cascade
- Delete an object, verify likes/announces cascade

### 8e. Stats Trigger Correctness
- Verify follower counts after follow/unfollow cycle
- Verify status count after create/delete cycle

**Files affected:** `lib.rs`

---

## 9. Activity Log Growth (Low Priority)

`ap_activities` stores the full raw JSONB for every federation event and has no built-in retention policy. Over time this will grow unboundedly.

**Recommendation:** Add a maintenance function for activity log pruning:

```rust
#[pg_extern]
fn ap_cleanup_old_activities(days_to_keep: i32) -> i64 {
    // Delete processed, non-local activities older than N days
    // Preserve local activities indefinitely
}
```

Consider also adding a partitioning strategy on `created_at` for very active instances.

**Files affected:** `admin.rs`

---

## 10. GUC Validation (Low Priority)

`src/guc.rs` registers GUCs but doesn't validate values at registration time. For example:
- `pg_fedi.domain` should reject empty strings and values containing `/` or spaces
- `pg_fedi.max_delivery_attempts` should have a reasonable minimum (e.g., 1)
- `pg_fedi.delivery_timeout_seconds` should have a reasonable range

pgrx doesn't provide GUC value validation hooks directly, but runtime validation in functions that read GUCs (e.g., `base_url()`) would catch misconfiguration early with a clear error message rather than producing malformed URIs.

**Files affected:** `guc.rs`

---

## 11. Observability (Low Priority)

The extension has `NOTIFY` triggers for key events but no structured logging. Adding `pgrx::log!()` or `pgrx::warning!()` at key decision points would help operators diagnose federation issues:

- Log when an activity is rejected (blocked domain, duplicate, unknown type)
- Log when a delivery expires after max retries
- Log when HTTP signature verification fails (with actor URI)
- Log when an actor stub is created (indicating a fetch is needed)

Use PostgreSQL's standard logging levels so operators can filter via `log_min_messages`.

**Files affected:** `activities.rs`, `delivery.rs`, `crypto.rs`

---

## 12. Consider `updated_at` Index for Actor Refresh (Low Priority)

The `idx_actors_updated_at` index exists but there's no function to find stale remote actors for profile refresh. External workers need a way to discover actors whose profiles should be re-fetched:

```rust
#[pg_extern]
fn ap_get_stale_remote_actors(older_than_hours: i32, batch_size: i32)
    -> TableIterator<'static, (name!(actor_id, i64), name!(uri, String))>
```

This enables workers to periodically refresh remote actor profiles (display names, avatars, keys).

**Files affected:** `actors.rs` or `admin.rs`

---

## Summary

| # | Improvement | Priority | Effort | Impact |
|---|-------------|----------|--------|--------|
| 1 | Replace panics with graceful error handling | High | Medium | Prevents connection crashes from malformed federation messages |
| 2 | HTTP Signature hardening (algorithm, date, parsing) | High | Low | Closes replay attack surface and improves interoperability |
| 3 | HTML sanitization | High | Low | Fixes search index quality for entity-heavy content |
| 4 | Missing database indexes | Medium | Low | Improves query performance for timelines and lookups |
| 5 | Subdomain block matching | Medium | Low | Matches operator expectations for domain moderation |
| 6 | Delivery queue locking (SKIP LOCKED) | Medium | Medium | Prevents duplicate deliveries with concurrent workers |
| 7 | N+1 query consolidation | Medium | Medium | Reduces SPI round-trips in hot paths |
| 8 | Test coverage gaps | Medium | Medium | Catches regressions in error handling and edge cases |
| 9 | Activity log retention | Low | Low | Prevents unbounded table growth |
| 10 | GUC validation | Low | Low | Catches misconfiguration early |
| 11 | Observability / structured logging | Low | Low | Aids operational debugging |
| 12 | Stale actor refresh function | Low | Low | Enables profile re-fetch workflows |
