# pg_fedi

ActivityPub federation as a PostgreSQL extension. Pure PL/pgSQL — installable via [pg_tle](https://github.com/aws/pg_tle) on managed Postgres (Supabase, RDS, etc.) or as a standalone extension.

## Installation

### Via pg_tle (managed Postgres)

```sql
CREATE EXTENSION IF NOT EXISTS pg_tle;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Install pg_fedi into pg_tle (run install.sql or inline the SQL)
SELECT pgtle.install_extension(
    'pg_fedi', '0.2.0',
    'ActivityPub federation for PostgreSQL',
    -- paste contents of sql/pg_fedi--0.2.0.sql here
);

CREATE EXTENSION pg_fedi;
```

### Standalone

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
\i sql/pg_fedi--0.2.0.sql
```

### Configuration

```sql
SELECT ap_set_setting('domain', 'myinstance.social');

-- Optional
SELECT ap_set_setting('https', 'true');                  -- default: true
SELECT ap_set_setting('auto_accept_follows', 'true');    -- default: true
SELECT ap_set_setting('max_delivery_attempts', '8');     -- default: 8
SELECT ap_set_setting('delivery_timeout_seconds', '30'); -- default: 30
SELECT ap_set_setting('user_agent', 'pg_fedi/0.2.0');   -- default: pg_fedi/0.2.0
```

## Usage

```sql
-- Create a local actor (app layer generates RSA keypair, passes it in)
SELECT ap_create_local_actor('alice', 'Alice', 'Hello!', public_pem, private_pem);

-- Post a note (queues delivery to followers)
SELECT ap_create_note('alice', '<p>Hello, fediverse!</p>');

-- Process an inbound activity
SELECT ap_process_inbox_activity('{"type":"Follow", ...}'::jsonb);

-- WebFinger lookup
SELECT ap_webfinger('acct:alice@myinstance.social');

-- Actor profile as ActivityStreams JSON-LD
SELECT ap_serialize_actor('alice');

-- Timelines
SELECT * FROM ap_public_timeline;
SELECT * FROM ap_home_timeline('alice');
```

## Architecture

pg_fedi handles all federation **logic and state** inside PostgreSQL. It does NOT handle HTTP or cryptographic signing — those are the responsibility of your application layer (e.g. Cloudflare Workers, Edge Functions, a small proxy).

```
┌─────────────────────────────────────────────────┐
│  Application Layer (Workers / Proxy)            │
│  - HTTP routing                                 │
│  - RSA keypair generation                       │
│  - HTTP Signature signing (outbound)            │
│  - HTTP Signature verification (inbound)        │
│  - Delivery worker (polls queue, POSTs to       │
│    remote inboxes)                              │
└──────────────────────┬──────────────────────────┘
                       │ SQL calls
┌──────────────────────▼──────────────────────────┐
│  pg_fedi (PostgreSQL)                           │
│  - Actor management & serialization             │
│  - Inbox processing (Follow, Like, Undo, etc.)  │
│  - Content creation & delivery queuing          │
│  - WebFinger, NodeInfo                          │
│  - Full-text search, timelines                  │
│  - SHA-256 digest (via pgcrypto)                │
└─────────────────────────────────────────────────┘
```

## HTTP Routing

Your proxy maps HTTP requests to SQL functions:

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

Outbound activities are queued in `ap_deliveries`. An external worker polls the queue, signs and sends HTTP requests, and reports results:

```sql
-- Get pending deliveries (includes private key for signing)
SELECT * FROM ap_get_pending_deliveries(10);

-- Report results
SELECT ap_delivery_success(delivery_id, 202);
SELECT ap_delivery_failure(delivery_id, 'connection refused', 0);
```

Retry schedule: 1m, 5m, 30m, 2h, 12h, 24h, 3d, 7d, then expire.

Listen for real-time delivery events: `LISTEN ap_delivery_queued;`

## Functions

### Actors

| Function | Returns | Description |
| --- | --- | --- |
| `ap_create_local_actor(username, display_name, summary, public_pem, private_pem)` | `text` | Create local actor (keys from app layer) |
| `ap_upsert_remote_actor(jsonb)` | `text` | Insert/update remote actor from ActivityStreams |
| `ap_serialize_actor(username)` | `jsonb` | Actor profile as JSON-LD |

### Content

| Function | Returns | Description |
| --- | --- | --- |
| `ap_create_note(username, content, summary, in_reply_to)` | `text` | Create Note, queue delivery to followers |
| `ap_serialize_object(uri)` | `jsonb` | Object as JSON-LD |
| `ap_search_objects(query, max_results)` | `setof record` | Full-text search across public objects |

### Inbox

| Function | Returns | Description |
| --- | --- | --- |
| `ap_process_inbox_activity(jsonb)` | `text` | Process inbound Follow, Like, Create, Undo, etc. |

### Collections

| Function | Returns | Description |
| --- | --- | --- |
| `ap_serialize_outbox(username, page)` | `jsonb` | OrderedCollection / OrderedCollectionPage |
| `ap_serialize_followers(username, page)` | `jsonb` | OrderedCollection / OrderedCollectionPage |
| `ap_serialize_following(username, page)` | `jsonb` | OrderedCollection / OrderedCollectionPage |
| `ap_serialize_featured(username)` | `jsonb` | Pinned posts collection |
| `ap_serialize_activity(uri)` | `jsonb` | Single activity as JSON-LD |

### Discovery

| Function | Returns | Description |
| --- | --- | --- |
| `ap_webfinger(resource)` | `jsonb` | WebFinger JRD (RFC 7033) |
| `ap_host_meta()` | `text` | host-meta XRD document |
| `ap_nodeinfo_discovery()` | `jsonb` | NodeInfo well-known pointer |
| `ap_nodeinfo()` | `jsonb` | NodeInfo 2.0 metadata |

### Crypto

| Function | Returns | Description |
| --- | --- | --- |
| `ap_digest(body)` | `text` | SHA-256 Digest header (uses pgcrypto) |

> RSA keypair generation, HTTP Signature signing, and verification are handled by the application layer. Keys are stored in `ap_keys` and passed to/from the app.

### Delivery

| Function | Returns | Description |
| --- | --- | --- |
| `ap_get_pending_deliveries(batch_size)` | `setof record` | Queued deliveries for worker |
| `ap_delivery_success(delivery_id, status_code)` | `void` | Mark delivery successful |
| `ap_delivery_failure(delivery_id, error, status_code)` | `void` | Mark failed, schedule retry |
| `ap_delivery_stats()` | `setof record` | Queue statistics by status |

### Settings

| Function | Returns | Description |
| --- | --- | --- |
| `ap_get_setting(key)` | `text` | Read a setting |
| `ap_set_setting(key, value)` | `void` | Write a setting |
| `ap_base_url()` | `text` | Returns `https://domain` from settings |

### Administration

| Function | Returns | Description |
| --- | --- | --- |
| `ap_block_domain(domain)` | `void` | Block a domain |
| `ap_unblock_domain(domain)` | `void` | Unblock a domain |
| `ap_is_domain_blocked(domain)` | `bool` | Check if domain is blocked |
| `ap_blocked_domains()` | `setof record` | List blocked domains |
| `ap_home_timeline(username, max_results, before_id)` | `setof record` | Home timeline |
| `ap_cleanup_expired_deliveries(older_than_days)` | `bigint` | Remove expired deliveries |
| `ap_refresh_actor_stats()` | `bigint` | Recalculate actor statistics |

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

`ap_actors`, `ap_keys`, `ap_objects`, `ap_activities`, `ap_follows`, `ap_likes`, `ap_announces`, `ap_deliveries`, `ap_blocks`, `ap_actor_stats`, `ap_settings`

## Testing

```bash
# Run the full test suite (requires pg_fedi + pgcrypto installed)
psql -v ON_ERROR_STOP=1 -f tests/test_pg_fedi.sql

# Or via make
make test
```

## License

Apache-2.0
