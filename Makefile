.PHONY: install uninstall test clean

# Install via pg_tle (requires pg_tle and pgcrypto extensions)
install:
	psql -f install.sql

# Install directly (without pg_tle, requires file access)
install-direct:
	psql -f sql/pg_fedi--0.2.0.sql

# Uninstall
uninstall:
	psql -c "DROP EXTENSION IF EXISTS pg_fedi CASCADE;"

# Run tests
test:
	psql -v ON_ERROR_STOP=1 -f tests/test_pg_fedi.sql

clean:
	@echo "Nothing to clean (pure SQL extension)"
