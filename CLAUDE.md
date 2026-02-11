# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

pg_fedi is a PostgreSQL extension that implements ActivityPub federation directly inside Postgres. Written in Rust using pgrx 0.16.1, it exposes SQL functions for actor management, content creation, inbox processing, delivery queuing, and protocol serialization (WebFinger, NodeInfo, HTTP Signatures).

## Build & Test Commands

```bash
# Build the extension
cargo pgrx run pg15          # Build and launch a psql session with the extension loaded

# Run all pgrx tests (spins up a real PG instance per test)
cargo pgrx test pg15

# Run a single test
cargo pgrx test pg15 -- test_create_local_actor

# Type-check without building
cargo check

# Run pg_regress tests
cargo pgrx test pg15 --runas postgres -- --regress setup
```

The default PG version is `pg15` (set in `Cargo.toml` features).

## Architecture

### How it works

Everything runs inside PostgreSQL — there is no external application server. SQL functions (`ap_*`) handle all ActivityPub operations. An external worker is expected to poll `ap_get_pending_deliveries()` and perform HTTP POSTs, then call `ap_delivery_success/failure` to update status. NOTIFY triggers (`ap_delivery_queued`, `ap_activity_received`, `ap_object_created`) allow real-time event-driven workers.

### Module responsibilities

- **`schema.rs`** — All table, index, trigger, and view DDL via `extension_sql!` blocks. Tables are prefixed `ap_`. The SQL generation order is controlled by `requires` clauses that reference enum types from `types.rs` and named SQL blocks.
- **`types.rs`** — PostgreSQL enum types (`ApActorType`, `ApActivityType`, `ApObjectType`, `ApVisibility`, `ApDeliveryStatus`) via `#[derive(PostgresEnum)]`. These must be created before tables reference them.
- **`actors.rs`** — Local actor creation (`ap_create_local_actor`), remote actor upsert from raw JSON (`ap_upsert_remote_actor`), and actor JSON-LD serialization (`ap_serialize_actor`).
- **`activities.rs`** — Note creation (`ap_create_note`) and the main inbox dispatcher (`ap_process_inbox_activity`) which handles Follow, Like, Announce, Undo, Create, Update, Delete, Accept, Reject, and Block activities. Contains all activity handler functions.
- **`delivery.rs`** — Outbound delivery queue: `ap_get_pending_deliveries` (for external workers), `ap_delivery_success/failure` (with exponential backoff), and `ap_delivery_stats`.
- **`crypto.rs`** — RSA-2048 keypair generation, SHA-256 digest, RSA signing/verification, and HTTP Signature construction/verification per draft-cavage-http-signatures.
- **`serialization.rs`** — ActivityStreams JSON-LD serialization for objects, activities, and collections (outbox, followers, following, featured). All paginated collections use `OrderedCollection`/`OrderedCollectionPage`.
- **`guc.rs`** — GUC variables: `pg_fedi.domain` (required), `pg_fedi.https`, `pg_fedi.auto_accept_follows`, `pg_fedi.max_delivery_attempts`, `pg_fedi.delivery_timeout_seconds`, `pg_fedi.user_agent`. Registered in `_PG_init`.
- **`admin.rs`** — Domain blocking, full-text search (`ap_search_objects`), home timeline, and maintenance functions (`ap_cleanup_expired_deliveries`, `ap_refresh_actor_stats`).
- **`webfinger.rs`** — WebFinger (RFC 7033) and host-meta XRD responses.
- **`nodeinfo.rs`** — NodeInfo 2.0 discovery and metadata endpoint.
- **`util.rs`** — JSON helpers (`json_str`, `json_str_nested`) and URI domain parsing.

### Key patterns

- All SQL interaction uses pgrx's SPI API: `Spi::run_with_args`, `Spi::get_one_with_args`, `Spi::connect` for multi-row iteration.
- Local actors have `domain IS NULL`; remote actors have a non-null `domain`.
- Actor stats (follower/following/status counts) are maintained by SQL triggers in a separate `ap_actor_stats` table.
- The inbox dispatcher (`ap_process_inbox_activity`) stores every activity in `ap_activities` with the raw JSON, then dispatches to type-specific handlers, and marks as processed.
- RSA key generation is slow in debug mode — `num-bigint-dig` has `opt-level = 3` in the dev profile to mitigate this.

### Database schema (core tables)

`ap_actors`, `ap_keys`, `ap_objects`, `ap_activities`, `ap_follows`, `ap_likes`, `ap_announces`, `ap_blocks`, `ap_deliveries`, `ap_actor_stats`

Views: `ap_local_actors`, `ap_public_timeline`, `ap_local_timeline`

### Tests

All tests are `#[pg_test]` functions in `src/lib.rs` inside a `#[pg_schema] mod tests` block. Each test runs against a real PostgreSQL instance. Tests use a helper `setup_domain()` that sets `pg_fedi.domain = 'test.example'`.
