#!/usr/bin/env bash
# Build and test pg_fedi inside a Supabase Postgres container.
# Usage: ./tests/supabase_test.sh
set -euo pipefail

SUPABASE_IMAGE="${SUPABASE_IMAGE:-supabase/postgres:15.14.1.081}"
NIX_PG="/nix/store/wrzs20jzmmkkg9p5yb731chmfljgjb6p-postgresql-15.14"
NIX_PGLIB="/nix/store/6sym2x3xyz8lirdrs6yg5yv7paw2bz8l-postgresql-15.14-lib/lib"
# The postgres binary is a Nix wrapper that sets NIX_PGLIBDIR to a different path
# than pg_config reports. We need to copy the .so there too.
NIX_PLUGINS="/nix/store/0mj4239bl5gafr2brvw0qjjdm3h77ij2-postgresql-and-plugins-15.14/lib"

echo "==> Building and testing pg_fedi on ${SUPABASE_IMAGE}"

docker run --rm \
  -v "$(pwd)":/src \
  "${SUPABASE_IMAGE}" \
  bash -c "
    set -e

    # 1. Install build deps
    echo '==> Installing build dependencies...'
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y -qq build-essential pkg-config libclang-dev clang \
      curl libreadline-dev zlib1g-dev libssl-dev > /dev/null 2>&1

    # 2. PG headers (Nix store has them, /usr/include/server is empty)
    mkdir -p /usr/include/server
    cp -r ${NIX_PG}/include/server/* /usr/include/server/
    cp -r ${NIX_PG}/include/*.h /usr/include/ 2>/dev/null || true

    # 3. Install Rust
    echo '==> Installing Rust...'
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable > /dev/null 2>&1
    export PATH=\"/root/.cargo/bin:\${PATH}\"

    # 4. Install cargo-pgrx
    echo '==> Installing cargo-pgrx 0.16.1...'
    cargo install cargo-pgrx --version 0.16.1 --locked 2>&1 | tail -1

    # 5. Init pgrx
    cargo pgrx init --pg15=\$(which pg_config) 2>&1 | tail -1

    # 6. Make PG dirs writable
    chmod -R a+w ${NIX_PGLIB}
    chmod -R a+w ${NIX_PLUGINS}
    chmod -R a+w /usr/share/postgresql

    # 7. Build and install the extension
    echo '==> Building pg_fedi...'
    cd /src
    cargo pgrx install --pg-config=\$(which pg_config) --release

    # Copy .so to the actual runtime pkglibdir (Nix wrapper uses a different path)
    cp ${NIX_PGLIB}/pg_fedi.so ${NIX_PLUGINS}/pg_fedi.so

    # 8. Start a clean PG instance
    echo '==> Starting PostgreSQL...'
    su postgres -c \"/usr/bin/pg_ctl -D /tmp/pgdata init -o '--locale=C.UTF-8'\" > /dev/null 2>&1
    su postgres -c \"/usr/bin/pg_ctl -D /tmp/pgdata -l /tmp/pg.log start -o '-c shared_preload_libraries='\"
    sleep 2

    # 9. Run smoke tests
    echo '==> Running smoke tests...'
    su postgres -c 'psql -v ON_ERROR_STOP=1 -f /src/tests/supabase_smoke.sql'
  "
