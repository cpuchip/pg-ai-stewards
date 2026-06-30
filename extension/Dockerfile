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
     15b-context-surface.sql 16-subagents.sql \
     17-personas.sql 18-scheduler.sql \
     19-models.sql 20-coder.sql 21-compact-context.sql \
     22-reflect-steward.sql 23-reflect-watchman.sql 24-skills.sql \
     25-corpus.sql 26-productivity.sql 27-context-search.sql \
     28-guard-autoresume.sql 29-intent-private-routing.sql \
     30-tool-primers.sql 31-model-aliases.sql \
     32-alias-failover.sql 33-page-in.sql \
     34-doc-builder.sql 35-research-doc-construction.sql \
     36-judge-local-routing.sql 37-tool-groups.sql \
     38-edge-vocabulary.sql 39-hinge.sql 40-rte.sql \
     41-memory-tend.sql 42-route-on.sql 43-request-research.sql \
     44-graph-organize.sql 45-work-item-chat.sql \
     46-chat-tasks.sql 47-multimodal.sql \
     48-chat-attachments.sql 49-doc-extract.sql \
     50-doc-build.sql 51-rich-chat-hardening.sql \
     52-session-scoped-tools.sql 53-explore-repos.sql \
     54-loreworks.sql 55-loreworks-build.sql \
     56-trajectory-critic.sql 57-loreworks-chat.sql \
     58-world-edge-audit.sql 59-self-improvement.sql \
     60-chat-model-pin.sql 61-world-build-worklist.sql \
     62-orientation.sql 63-orient-survey.sql \
     64-auto-critique.sql 65-rigor-mode.sql 66-rigor-verify.sql \
     67-rigor-force-final.sql 68-model-fallback-hardening.sql \
     69-a2a-engine.sql 70-hinge-decouple.sql \
     71-hybrid-rrf.sql 72-hybrid-rrf-everywhere.sql \
     73-brain-hybrid.sql 74-north-star.sql \
     75-wire-brain-hybrid.sql 76-wire-engram-search.sql \
     77-tool-shelf.sql 78-yt-slide-frames.sql \
     79-bineval.sql 80-rest.sql 81-spiral-oracle.sql \
     82-world-graph.sql ./

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
