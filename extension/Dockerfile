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
# The 2-6*/2-7*/3a*.sql files are read at compile time by
# extension_sql_file! macros in src/lib.rs (folded back from live-DB
# migrations as of v0.2.0). They must be present in the build context.
# When adding a new file, also add the corresponding extension_sql_file!
# call in src/lib.rs and update this list.
COPY 00-config.sql 01-graph.sql 02-workstreams.sql \
     03-watchman.sql 04-work-items.sql 05-mcp-bridge.sql \
     06-cost.sql 07-steward.sql \
     08-gates.sql 09-intents-covenants.sql 10-sabbath-atonement.sql \
     11-trust.sql 12-council.sql 13-research-pipelines.sql \
     14-fanout-brainstorm.sql 15a-context-engrams.sql \
     15b-context-surface.sql ./

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
