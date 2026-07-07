# extension/Dockerfile
#
# Multi-stage build for the pg_ai_stewards extension.
# Stage 1: build the extension with cargo-pgrx against PG18 dev headers.
# Stage 2: layer the extension onto pgvector on PG18.
#
# (Apache AGE was dropped at the 2026-06-12 consolidation — the graph
# is relational, installed by the extension itself. Stage 2 is now a
# plain pgvector image plus our packaged extension.)

# ============================================================
# Stage 1: builder — Rust + cargo-pgrx + PG18 server-dev
# ============================================================
FROM rust:1-bookworm AS builder

ARG PGRX_VERSION=0.18.0
ENV DEBIAN_FRONTEND=noninteractive

# PG18 dev headers from the official PGDG repository (bookworm).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        build-essential pkg-config \
        libclang-dev clang \
        libreadline-dev zlib1g-dev libssl-dev \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
       | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg \
    && echo "deb http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-18 postgresql-server-dev-18 \
    && rm -rf /var/lib/apt/lists/*

RUN cargo install --locked cargo-pgrx --version ${PGRX_VERSION}

# Register the system PG18 with pgrx. --no-run means "don't initdb a
# managed cluster" — we only need cargo-pgrx to know where pg_config is
# so it can package against PG18's headers and lib paths.
RUN cargo pgrx init --pg18 /usr/lib/postgresql/18/bin/pg_config

WORKDIR /build/pg_ai_stewards
COPY Cargo.toml pg_ai_stewards.control ./
COPY src ./src
# The chain files below are read at compile time by extension_sql_file!
# macros in src/lib.rs (folded back from live-DB migrations as of v0.2.0).
# They must be present in the build context.
#
# This block is GENERATED — do not hand-edit it. Run
# `extension/gen-copy-manifest.sh` after adding/removing an
# extension_sql_file! entry in src/lib.rs (it parses lib.rs, verifies every
# referenced file exists, and rewrites everything between the two markers
# below). Run `extension/gen-copy-manifest.sh --check` (UNPIPED exit code)
# before `docker compose build` to catch drift instead of hitting the
# forgotten-COPY-line failure class this replaced: forgetting a line here
# used to be a builder COMPILE error whose non-zero exit a piped
# `| tail` silently swallowed, leaving a stale image running for a week
# (102-war-game.sql, 2026-07-06 — see git history on this region).
# ===== GENERATED SQL COPY BLOCK (gen-copy-manifest.sh) =====
COPY v00-foundations.sql ./
COPY v01-work-substrate.sql ./
COPY v02-governance.sql ./
COPY v03-fanout-brainstorm.sql ./
COPY v04-context-engine.sql ./
COPY v05-subagents.sql ./
COPY v06-agents-runtime.sql ./
COPY v07-agent-surface.sql ./
COPY v08-aliases-docbuilder.sql ./
COPY v09-routing-and-hinge.sql ./
COPY v10-chat.sql ./
COPY v11-loreworks.sql ./
COPY v12-rigor.sql ./
COPY v13-a2a.sql ./
COPY v14-search-and-disclosure.sql ./
COPY v15-world-graph.sql ./
COPY v16-code-graph.sql ./
COPY v17-gates-worldchat.sql ./
COPY v18-lab.sql ./
COPY v19-platform.sql ./
COPY v20-wiki.sql ./
COPY v21-crawler.sql ./
COPY v22-route-intake.sql ./
COPY v23-schedule-chat.sql ./
COPY v24-lab-dispatch.sql ./
COPY v25-war-game.sql ./
COPY v26-knowledge.sql ./
COPY v27-lifeless-core.sql ./
COPY v28-files-interface.sql ./
COPY v29-normalize.sql ./
COPY v30-workspaces.sql ./
# ===== END GENERATED =====

# `cargo pgrx package` produces ./target/release/pg_ai_stewards-pg18/
# with the directory tree rooted at /, containing the .so, .control,
# and generated .sql under the standard pg_config paths.
RUN cargo pgrx package \
        --pg-config /usr/lib/postgresql/18/bin/pg_config \
        --out-dir /out

# ============================================================
# Stage 2: runtime — pgvector + pg_ai_stewards on PG18
# ============================================================
FROM pgvector/pgvector:pg18

# Drop in the pgrx-built extension. Stage 1's --out-dir output is rooted
# directly at / (the .so under /usr/lib/postgresql/18/lib/, control +
# generated SQL under /usr/share/postgresql/18/extension/).
COPY --from=builder /out/ /
