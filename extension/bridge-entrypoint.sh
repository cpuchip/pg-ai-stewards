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
# External MCP tool discovery: `bridge run` (the daemon) only PROXIES tool
# calls — it never lists/registers the configured mcp_servers' tools into
# stewards.tool_defs. That registration is the separate `bridge refresh-tools`
# pass. Without it a fresh install boots with ZERO external MCP tools (coder,
# doc-extract, …), so agents that expect them (e.g. doc-build calling
# coder_export_artifact) fail with "tool not active". So run it once on boot,
# BEST-EFFORT: a discovery failure (an MCP server binary missing/unreachable)
# must not stop the daemon from starting — the cache persists in the DB, so a
# later manual `refresh-tools` can recover. mcp_servers is seeded by
# CREATE EXTENSION and depends_on waits for pg healthy, so the rows exist here.
#
# Failure mode: if the bridge cannot reach Postgres it exits non-zero and
# compose's restart policy retries. depends_on waits for pg to be healthy
# first, so the common case is a clean connect.
set -e

echo "bridge-entrypoint: discovering external MCP tools (refresh-tools, best-effort)"
/usr/local/bin/stewards-mcp bridge refresh-tools \
  || echo "bridge-entrypoint: refresh-tools failed (non-fatal) — run it manually once servers are reachable"

echo "bridge-entrypoint: starting pg-ai-stewards bridge daemon"
exec /usr/local/bin/stewards-mcp bridge run
