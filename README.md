# pg_fedi

A PostgreSQL extension that provides a **complete ActivityPub federation layer** directly inside Postgres.

Instead of building a full Rails/Django/Express app to participate in the fediverse,
you install this extension and point a thin HTTP proxy at it. The database *is* the server.

```
Internet  ←→  Caddy/nginx  ←→  PostgreSQL + pg_fedi
```

## Features

- **Full ActivityPub Protocol** — Actors, Activities, Objects, Collections
- **WebFinger Discovery** — `acct:alice@example.com` resolution
- **HTTP Signatures** — RSA-SHA256 signing & verification (draft-cavage)
- **Inbox Processing** — Follow, Like, Announce, Create, Update, Delete, Undo, Accept, Reject, Block
- **Outbox Posting** — Create notes, queue delivery to followers
- **Federation Delivery Queue** — Exponential backoff retry (1m → 7d)
- **Social Graph** — Followers/following with auto-accept option
- **Timelines** — Public, local, and home timeline views
- **Full-Text Search** — GIN-indexed content search across objects
- **Domain Blocking** — Instance-level federation controls
- **NodeInfo** — Instance metadata for fediverse crawlers
- **Mastodon-compatible** — JSON-LD context, extensions, addressing model

## Quick Start

```sql
-- Install the extension
CREATE EXTENSION pg_fedi;

-- Configure your domain (REQUIRED)
ALTER SYSTEM SET pg_fedi.domain = 'myinstance.social';
SELECT pg_reload_conf();

-- Create a user
SELECT ap_create_local_actor('alice', 'Alice', 'Hello from pg_fedi!');

-- Test WebFinger
SELECT ap_webfinger('acct:alice@myinstance.social');

-- Get the ActivityStreams JSON for Alice
SELECT ap_serialize_actor('alice');

-- Post a note
SELECT ap_create_note('alice', '<p>Hello, fediverse!</p>', NULL, NULL);

-- Check the delivery queue
SELECT * FROM ap_delivery_stats();
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Internet (other fediverse servers)             │
└────────────────────┬────────────────────────────┘
                     │ HTTPS
┌────────────────────▼────────────────────────────┐
│  Thin HTTP Proxy (Caddy / nginx / tiny app)     │
│  • Routes /.well-known/webfinger → pg function  │
│  • Routes /users/:name → pg function            │
│  • Routes /inbox → pg function                  │
│  • Routes /nodeinfo → pg function               │
│  • Delivers queued activities (polls pg table)   │
└────────────────────┬────────────────────────────┘
                     │ libpq / SQL
┌────────────────────▼────────────────────────────┐
│  PostgreSQL + pg_fedi extension                 │
│                                                 │
│  ┌─────────────┐  ┌──────────────────────────┐  │
│  │ Custom Types │  │ Core Tables              │  │
│  │ • enums     │  │ • ap_actors              │  │
│  └─────────────┘  │ • ap_objects             │  │
│                   │ • ap_activities          │  │
│  ┌─────────────┐  │ • ap_follows             │  │
│  │ Functions   │  │ • ap_likes               │  │
│  │ • inbox     │  │ • ap_announces           │  │
│  │ • outbox    │  │ • ap_deliveries          │  │
│  │ • webfinger │  │ • ap_keys                │  │
│  │ • serialize │  │ • ap_blocks              │  │
│  │ • verify    │  │ • ap_actor_stats         │  │
│  │ • sign      │  └──────────────────────────┘  │
│  └─────────────┘                                │
│                   ┌──────────────────────────┐  │
│                   │ Real-time (NOTIFY)       │  │
│                   │ • ap_delivery_queued     │  │
│                   │ • ap_activity_received   │  │
│                   │ • ap_object_created      │  │
│                   └──────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### The Thin HTTP Proxy

pg_fedi handles data storage, validation, serialization, and queue management.
You need a thin HTTP proxy to handle TLS and route requests to SQL functions:

| Route | Method | SQL Function |
|-------|--------|--------------|
| `/.well-known/webfinger?resource=acct:...` | GET | `ap_webfinger(resource)` |
| `/.well-known/host-meta` | GET | `ap_host_meta()` |
| `/.well-known/nodeinfo` | GET | `ap_nodeinfo_discovery()` |
| `/nodeinfo/2.0` | GET | `ap_nodeinfo()` |
| `/users/:name` | GET | `ap_serialize_actor(name)` |
| `/users/:name/inbox` | POST | `ap_process_inbox_activity(body)` |
| `/users/:name/outbox` | GET | `ap_serialize_outbox(name, page)` |
| `/users/:name/followers` | GET | `ap_serialize_followers(name, page)` |
| `/users/:name/following` | GET | `ap_serialize_following(name, page)` |
| `/users/:name/collections/featured` | GET | `ap_serialize_featured(name)` |
| `/inbox` (shared) | POST | `ap_process_inbox_activity(body)` |

### Delivery Worker

The extension queues outbound deliveries in `ap_deliveries` with NOTIFY triggers for real-time pickup.
An external worker polls `ap_get_pending_deliveries()`, performs the HTTP POSTs with signed requests, and reports results back:

```python
# Pseudocode
while True:
    batch = db.query("SELECT * FROM ap_get_pending_deliveries(10)")
    for d in batch:
        sig = ap_build_signature_header(d.key_id, d.private_key_pem, "POST", d.inbox_uri, date, body)
        response = http_post(d.inbox_uri, d.activity_json, headers={"Signature": sig})
        if response.ok:
            db.query("SELECT ap_delivery_success(%s, %s)", d.delivery_id, response.status)
        else:
            db.query("SELECT ap_delivery_failure(%s, %s, %s)",
                     d.delivery_id, str(response.error), response.status)
    sleep(5)
```

Retry schedule: 1m, 5m, 30m, 2h, 12h, 24h, 3d, 7d — then expire.

## Configuration

Set these in `postgresql.conf` or via `ALTER SYSTEM`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `pg_fedi.domain` | *(required)* | Instance domain name |
| `pg_fedi.https` | `true` | Use HTTPS in generated URIs |
| `pg_fedi.auto_accept_follows` | `true` | Auto-accept incoming follow requests |
| `pg_fedi.max_delivery_attempts` | `8` | Max retries before marking expired |
| `pg_fedi.delivery_timeout_seconds` | `30` | HTTP timeout for outbound delivery |
| `pg_fedi.user_agent` | `pg_fedi/0.1.0` | User-Agent for outbound requests |

## SQL Function Reference

### Actor Management

| Function | Description |
|----------|-------------|
| `ap_create_local_actor(username, display_name, summary)` | Create a local actor with generated RSA keypair |
| `ap_upsert_remote_actor(json)` | Insert or update a remote actor from ActivityStreams JSON |
| `ap_serialize_actor(username)` | Serialize a local actor to JSON-LD |

### Content

| Function | Description |
|----------|-------------|
| `ap_create_note(username, content, summary, in_reply_to)` | Create a Note and queue delivery to followers |
| `ap_serialize_object(uri)` | Serialize an object to JSON-LD |

### Inbox

| Function | Description |
|----------|-------------|
| `ap_process_inbox_activity(json)` | Process an inbound activity (Follow, Like, Create, Undo, etc.) |

### Collections

| Function | Description |
|----------|-------------|
| `ap_serialize_outbox(username, page)` | Outbox as OrderedCollection/Page |
| `ap_serialize_followers(username, page)` | Followers as OrderedCollection/Page |
| `ap_serialize_following(username, page)` | Following as OrderedCollection/Page |
| `ap_serialize_featured(username)` | Pinned/featured posts collection |
| `ap_serialize_activity(uri)` | Serialize a stored activity to JSON-LD |

### Discovery

| Function | Description |
|----------|-------------|
| `ap_webfinger(resource)` | WebFinger JRD response (RFC 7033) |
| `ap_host_meta()` | host-meta XRD document |
| `ap_nodeinfo_discovery()` | NodeInfo well-known discovery |
| `ap_nodeinfo()` | NodeInfo 2.0 instance metadata |

### Cryptography

| Function | Description |
|----------|-------------|
| `ap_generate_keypair()` | Generate RSA-2048 keypair (public_pem, private_pem) |
| `ap_digest(body)` | SHA-256 Digest header value |
| `ap_rsa_sign(private_key_pem, data)` | Sign data with RSA-SHA256 |
| `ap_rsa_verify(public_key_pem, data, signature)` | Verify RSA-SHA256 signature |
| `ap_build_signature_header(key_id, private_pem, method, url, date, body)` | Build HTTP Signature header |
| `ap_verify_http_signature(sig_header, method, path, host, date, digest, public_pem)` | Verify HTTP Signature |

### Delivery

| Function | Description |
|----------|-------------|
| `ap_get_pending_deliveries(batch_size)` | Get queued deliveries for the worker |
| `ap_delivery_success(delivery_id, status_code)` | Mark delivery as successful |
| `ap_delivery_failure(delivery_id, error, status_code)` | Mark delivery as failed (schedules retry) |
| `ap_delivery_stats()` | Delivery queue statistics by status |

### Admin & Maintenance

| Function | Description |
|----------|-------------|
| `ap_block_domain(domain)` | Block a domain from federating |
| `ap_unblock_domain(domain)` | Remove a domain block |
| `ap_is_domain_blocked(domain)` | Check if a domain is blocked |
| `ap_blocked_domains()` | List all blocked domains |
| `ap_search_objects(query, max_results)` | Full-text search across public objects |
| `ap_home_timeline(username, max_results, before_id)` | Home timeline (followed + own posts) |
| `ap_cleanup_expired_deliveries(older_than_days)` | Remove old expired deliveries |
| `ap_refresh_actor_stats()` | Recalculate all actor stats from source data |

### Views

| View | Description |
|------|-------------|
| `ap_local_actors` | Local actors with stats |
| `ap_public_timeline` | Public non-deleted objects, reverse chronological |
| `ap_local_timeline` | Public objects from local actors only |

## Building

### Prerequisites

- Rust toolchain (via [rustup](https://rustup.rs))
- PostgreSQL 13-18 development headers
- `cargo-pgrx` 0.16.1

### Build & Run

```bash
# Install cargo-pgrx
cargo install cargo-pgrx --version 0.16.1

# Initialize pgrx (downloads & compiles PostgreSQL)
cargo pgrx init

# Run in development mode (starts a temporary PG instance with psql)
cargo pgrx run pg15

# Build & install for production
cargo pgrx install --release
```

## Testing

Tests run against a real PostgreSQL instance managed by pgrx. Each `#[pg_test]` function gets its own transaction that is rolled back after the test.

```bash
# Run all tests
cargo pgrx test pg15

# Run a single test by name
cargo pgrx test pg15 -- test_create_local_actor

# Run tests matching a pattern
cargo pgrx test pg15 -- test_inbox

# Type-check only (no PG instance needed)
cargo check
```

Tests are located in `src/lib.rs` inside a `#[pg_schema] mod tests` block. They use a `setup_domain()` helper that configures `pg_fedi.domain = 'test.example'` and `pg_fedi.https = true` for tests that need URI generation.

Test coverage includes:

- **Schema** — Tables, views, enum types, and triggers exist
- **Crypto** — Keypair generation, RSA sign/verify, HTTP Signature build/verify, digest computation
- **Actors** — Local actor creation with keypair provisioning, remote actor upsert, actor serialization
- **WebFinger** — Resource resolution, host-meta generation
- **Activities** — Note creation, Follow auto-accept, Like, Undo Follow, inbound Create
- **Delivery** — Queue lifecycle, failure/retry tracking, stats
- **Collections** — Outbox, followers, featured serialization with pagination
- **Admin** — Domain blocking/unblocking, inbox rejection of blocked domains, full-text search, home timeline, expired delivery cleanup, actor stats refresh
- **NodeInfo** — Discovery document and instance metadata
- **NOTIFY triggers** — Delivery, activity, and object notification triggers exist

## License

Apache-2.0
