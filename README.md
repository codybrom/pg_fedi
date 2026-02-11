# pg_fedi

ActivityPub federation as a PostgreSQL extension.

## Installation

Requires [Rust](https://rustup.rs) and [cargo-pgrx](https://github.com/pgcentralfoundation/pgrx) 0.16.1.

```bash
cargo install cargo-pgrx --version 0.16.1
cargo pgrx init
cargo pgrx install --release
```

Then in PostgreSQL:

```sql
CREATE EXTENSION pg_fedi;

ALTER SYSTEM SET pg_fedi.domain = 'myinstance.social';
SELECT pg_reload_conf();
```

## Usage

```sql
-- Create a local actor (generates RSA keypair automatically)
SELECT ap_create_local_actor('alice', 'Alice', 'Hello from pg_fedi!');

-- Post a note (queues delivery to followers)
SELECT ap_create_note('alice', '<p>Hello, fediverse!</p>', NULL, NULL);

-- Process an inbound activity
SELECT ap_process_inbox_activity('{"type":"Follow", ...}'::json);

-- WebFinger lookup
SELECT ap_webfinger('acct:alice@myinstance.social');

-- Actor profile as ActivityStreams JSON-LD
SELECT ap_serialize_actor('alice');

-- Timelines
SELECT * FROM ap_public_timeline;
SELECT * FROM ap_home_timeline('alice', 20, NULL);
```

## HTTP Routing

pg_fedi does not listen on HTTP. You need a thin proxy (Caddy, nginx, a small app) to route requests to SQL functions:

| Route | Method | SQL |
| --- | --- | --- |
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

## Delivery Worker

Outbound activities are queued in `ap_deliveries` with `NOTIFY` triggers. An external worker polls the queue, sends signed HTTP requests, and reports results:

```sql
SELECT * FROM ap_get_pending_deliveries(10);
SELECT ap_delivery_success(delivery_id, 202);
SELECT ap_delivery_failure(delivery_id, 'connection refused', 0);
```

Retry schedule: 1m, 5m, 30m, 2h, 12h, 24h, 3d, 7d, then expire.

## Configuration

Set via `postgresql.conf` or `ALTER SYSTEM`:

| Parameter | Default | Description |
| --- | --- | --- |
| `pg_fedi.domain` | *(required)* | Instance domain name |
| `pg_fedi.https` | `true` | Use HTTPS in generated URIs |
| `pg_fedi.auto_accept_follows` | `true` | Auto-accept incoming follows |
| `pg_fedi.max_delivery_attempts` | `8` | Max retries before expiring |
| `pg_fedi.delivery_timeout_seconds` | `30` | HTTP timeout for outbound delivery |
| `pg_fedi.user_agent` | `pg_fedi/0.1.0` | User-Agent for outbound requests |

## Functions

### Actors

| Function | Returns | Description |
| --- | --- | --- |
| `ap_create_local_actor(username, display_name, summary)` | `text` | Create local actor with RSA keypair |
| `ap_upsert_remote_actor(json)` | `text` | Insert/update remote actor from ActivityStreams |
| `ap_serialize_actor(username)` | `json` | Actor profile as JSON-LD |

### Content

| Function | Returns | Description |
| --- | --- | --- |
| `ap_create_note(username, content, summary, in_reply_to)` | `text` | Create Note, queue delivery to followers |
| `ap_serialize_object(uri)` | `json` | Object as JSON-LD |
| `ap_search_objects(query, max_results)` | `setof record` | Full-text search across public objects |

### Inbox

| Function | Returns | Description |
| --- | --- | --- |
| `ap_process_inbox_activity(json)` | `void` | Process inbound Follow, Like, Create, Undo, etc. |

### Collections

| Function | Returns | Description |
| --- | --- | --- |
| `ap_serialize_outbox(username, page)` | `json` | OrderedCollection / OrderedCollectionPage |
| `ap_serialize_followers(username, page)` | `json` | OrderedCollection / OrderedCollectionPage |
| `ap_serialize_following(username, page)` | `json` | OrderedCollection / OrderedCollectionPage |
| `ap_serialize_featured(username)` | `json` | Pinned posts collection |
| `ap_serialize_activity(uri)` | `json` | Single activity as JSON-LD |

### Discovery

| Function | Returns | Description |
| --- | --- | --- |
| `ap_webfinger(resource)` | `json` | WebFinger JRD (RFC 7033) |
| `ap_host_meta()` | `text` | host-meta XRD document |
| `ap_nodeinfo_discovery()` | `json` | NodeInfo well-known pointer |
| `ap_nodeinfo()` | `json` | NodeInfo 2.0 metadata |

### Cryptography

| Function | Returns | Description |
| --- | --- | --- |
| `ap_generate_keypair()` | `record` | RSA-2048 keypair |
| `ap_digest(body)` | `text` | SHA-256 Digest header |
| `ap_rsa_sign(private_key_pem, data)` | `text` | RSA-SHA256 signature |
| `ap_rsa_verify(public_key_pem, data, signature)` | `bool` | Verify RSA-SHA256 |
| `ap_build_signature_header(key_id, private_pem, method, url, date, body)` | `text` | HTTP Signature header |
| `ap_verify_http_signature(sig_header, method, path, host, date, digest, pub_pem)` | `bool` | Verify HTTP Signature |

### Delivery

| Function | Returns | Description |
| --- | --- | --- |
| `ap_get_pending_deliveries(batch_size)` | `setof record` | Queued deliveries for worker |
| `ap_delivery_success(delivery_id, status_code)` | `void` | Mark delivery successful |
| `ap_delivery_failure(delivery_id, error, status_code)` | `void` | Mark failed, schedule retry |
| `ap_delivery_stats()` | `setof record` | Queue statistics by status |

### Administration

| Function | Returns | Description |
| --- | --- | --- |
| `ap_block_domain(domain)` | `void` | Block a domain |
| `ap_unblock_domain(domain)` | `void` | Unblock a domain |
| `ap_is_domain_blocked(domain)` | `bool` | Check if domain is blocked |
| `ap_blocked_domains()` | `setof text` | List blocked domains |
| `ap_home_timeline(username, max_results, before_id)` | `setof record` | Home timeline |
| `ap_cleanup_expired_deliveries(older_than_days)` | `bigint` | Remove expired deliveries |
| `ap_refresh_actor_stats()` | `void` | Recalculate actor statistics |

### Views

| View | Description |
| --- | --- |
| `ap_local_actors` | Local actors with follower/following/post counts |
| `ap_public_timeline` | Public objects, reverse chronological |
| `ap_local_timeline` | Public objects from local actors only |

### NOTIFY Channels

| Channel | Fired on |
| --- | --- |
| `ap_delivery_queued` | New outbound delivery queued |
| `ap_activity_received` | Inbound activity processed |
| `ap_object_created` | New object created |

## Tables

`ap_actors`, `ap_keys`, `ap_objects`, `ap_activities`, `ap_follows`, `ap_likes`, `ap_announces`, `ap_deliveries`, `ap_blocks`, `ap_actor_stats`

## Testing

```bash
make test             # 34 pgrx unit tests
make test-one T=name  # single test
make test-endpoints   # endpoint JSON validation (needs: cargo pgrx start pg15)
make test-supabase    # build & test on supabase/postgres via Docker
make check            # type-check only
```

## Development

```bash
make build   # build & install into pgrx-managed PG15
make run     # start PG15 with psql
make clean   # cargo clean
```

## License

Apache-2.0
