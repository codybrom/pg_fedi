.PHONY: build test run check test-one test-supabase clean

# Local development (macOS, uses pgrx-managed PG15)
build:
	cargo pgrx install --pg-config=$$(cargo pgrx info pg-config pg15) --release

test:
	cargo pgrx test pg15

run:
	cargo pgrx run pg15

check:
	cargo check

# Run a single test: make test-one T=test_create_local_actor
test-one:
	cargo pgrx test pg15 -- $(T)

# Endpoint response validation (run against pgrx-managed PG15)
# Start PG first: cargo pgrx start pg15 (or cargo pgrx run pg15)
test-endpoints:
	$$(cargo pgrx info pg-config pg15 | xargs dirname)/psql -h localhost -p 28815 -d postgres -v ON_ERROR_STOP=1 -f tests/endpoint_test.sql

# Test on Supabase Postgres
test-supabase:
	bash tests/supabase_test.sh

clean:
	cargo clean
