#!/bin/sh
# bridge-entrypoint.sh — start the pg-ai-stewards MCP bridge daemon.
#
# The core substrate schema is installed atomically by
# `CREATE EXTENSION pg_ai_stewards`, which the pg container runs on first
# boot from extension/init/00-extensions.sql. The consolidated extension
# chain (00..20) IS the install — there are no core runtime migrations to
# replay, so the bridge does not run `stewards-cli migrate` on startup.
#
# Operator OVERLAY migrations (your own seeds / external MCP registrations)
# are a separate, opt-in step — see docs. (`stewards-cli migrate` currently
# expects the workspace path layout; the overlay-aware runner is tracked as
# part of the two-tier runner work, not wired here.)
#
# Failure mode: if the bridge cannot reach Postgres it exits non-zero and
# compose's restart policy retries. depends_on waits for pg to be healthy
# first, so the common case is a clean connect.
set -e

echo "bridge-entrypoint: starting pg-ai-stewards bridge daemon"
exec /usr/local/bin/stewards-mcp bridge run
