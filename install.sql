-- pg_fedi pg_tle installer
-- Run this on a Postgres instance with pg_tle enabled to install pg_fedi.
--
-- Usage:
--   psql -f install.sql
--
-- Prerequisites:
--   CREATE EXTENSION IF NOT EXISTS pg_tle;
--   CREATE EXTENSION IF NOT EXISTS pgcrypto;

SELECT pgtle.install_extension(
    'pg_fedi',
    '0.2.0',
    'ActivityPub federation for PostgreSQL',
    pg_read_file('sql/pg_fedi--0.2.0.sql')
);

-- After running this, create the extension in your database:
--   CREATE EXTENSION pg_fedi;
--
-- Then configure your domain:
--   SELECT ap_set_setting('domain', 'yourdomain.com');
