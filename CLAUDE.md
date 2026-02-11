# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

pg_fedi is a PostgreSQL extension that implements ActivityPub federation directly inside Postgres. Written in pure PL/pgSQL, it's installable via pg_tle on managed Postgres (e.g. Supabase) or as a standalone extension. It exposes ~40 SQL functions for actor management, content creation, inbox processing, delivery queuing, and protocol serialization (WebFinger, NodeInfo).

**Cryptographic operations** (RSA keypair generation, HTTP Signature signing/verification) are handled by the application layer — not the database. The only crypto function in the extension is `ap_digest()` which uses pgcrypto for SHA-256 hashing.

## Installation

```sql
-- Via pg_tle (managed Postgres like Supabase)
CREATE EXTENSION IF NOT EXISTS pg_tle;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- Then run install.sql or manually call pgtle.install_extension(...)
CREATE EXTENSION pg_fedi;

-- Configure
SELECT ap_set_setting('domain', 'yourdomain.com');
```

## File Structure

```
pg_fedi/
├── sql/
│   └── pg_fedi--0.2.0.sql   # Complete extension SQL (enums, tables, functions)
├── tests/
│   └── test_pg_fedi.sql      # PL/pgSQL test suite
├── install.sql               # pg_tle installer wrapper
├── pg_fedi.control           # PostgreSQL extension control file
├── Makefile                  # install/test/uninstall shortcuts
└── README.md
```

## Architecture

### Settings (replaces GUC variables)

Settings are stored in `ap_settings` table instead of PostgreSQL GUC variables:

- `ap_get_setting('domain')` / `ap_set_setting('domain', 'example.com')`
- `ap_base_url()` returns `https://example.com` based on settings

### Key patterns

- All functions are PL/pgSQL or SQL (no compiled extensions needed)
- Local actors have `domain IS NULL`; remote actors have a non-null `domain`
- Actor stats maintained by triggers in `ap_actor_stats`
- Inbox dispatcher (`ap_process_inbox_activity`) stores every activity with raw JSON, dispatches to type-specific `_ap_process_*` handlers
- Internal helpers prefixed with `_ap_` (not part of public API)
- Collection serialization uses `jsonb_build_object` / `jsonb_agg`

### Crypto boundary

The extension does NOT handle:

- RSA keypair generation → application layer generates and passes to `ap_create_local_actor`
- HTTP Signature signing → application layer signs outbound requests using keys from `ap_keys`
- HTTP Signature verification → application layer verifies before calling `ap_process_inbox_activity`

The extension DOES handle:

- `ap_digest(body)` → SHA-256 digest header using pgcrypto

### Database schema (core tables)

`ap_actors`, `ap_keys`, `ap_objects`, `ap_activities`, `ap_follows`, `ap_likes`, `ap_announces`, `ap_blocks`, `ap_deliveries`, `ap_actor_stats`, `ap_settings`

Views: `ap_local_actors`, `ap_public_timeline`, `ap_local_timeline`

### NOTIFY channels

- `ap_delivery_queued` — new delivery inserted
- `ap_activity_received` — remote activity received
- `ap_object_created` — new object created
