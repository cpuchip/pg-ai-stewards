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
COPY 00-config.sql ./
COPY 01-graph.sql ./
COPY 02-workstreams.sql ./
COPY 03-watchman.sql ./
COPY 04-work-items.sql ./
COPY 05-mcp-bridge.sql ./
COPY 06-cost.sql ./
COPY 07-steward.sql ./
COPY 08-gates.sql ./
COPY 09-intents-covenants.sql ./
COPY 10-sabbath-atonement.sql ./
COPY 11-trust.sql ./
COPY 12-council.sql ./
COPY 13-research-pipelines.sql ./
COPY 14-fanout-brainstorm.sql ./
COPY 15a-context-engrams.sql ./
COPY 15b-context-surface.sql ./
COPY 16-subagents.sql ./
COPY 17-personas.sql ./
COPY 18-scheduler.sql ./
COPY 19-models.sql ./
COPY 20-coder.sql ./
COPY 21-compact-context.sql ./
COPY 22-reflect-steward.sql ./
COPY 23-reflect-watchman.sql ./
COPY 24-skills.sql ./
COPY 25-corpus.sql ./
COPY 26-productivity.sql ./
COPY 27-context-search.sql ./
COPY 28-guard-autoresume.sql ./
COPY 29-intent-private-routing.sql ./
COPY 30-tool-primers.sql ./
COPY 31-model-aliases.sql ./
COPY 32-alias-failover.sql ./
COPY 33-page-in.sql ./
COPY 34-doc-builder.sql ./
COPY 35-research-doc-construction.sql ./
COPY 36-judge-local-routing.sql ./
COPY 37-tool-groups.sql ./
COPY 38-edge-vocabulary.sql ./
COPY 39-hinge.sql ./
COPY 40-rte.sql ./
COPY 41-memory-tend.sql ./
COPY 42-route-on.sql ./
COPY 43-request-research.sql ./
COPY 44-graph-organize.sql ./
COPY 45-work-item-chat.sql ./
COPY 46-chat-tasks.sql ./
COPY 47-multimodal.sql ./
COPY 48-chat-attachments.sql ./
COPY 49-doc-extract.sql ./
COPY 50-doc-build.sql ./
COPY 51-rich-chat-hardening.sql ./
COPY 52-session-scoped-tools.sql ./
COPY 53-explore-repos.sql ./
COPY 54-loreworks.sql ./
COPY 55-loreworks-build.sql ./
COPY 56-trajectory-critic.sql ./
COPY 57-loreworks-chat.sql ./
COPY 58-world-edge-audit.sql ./
COPY 59-self-improvement.sql ./
COPY 60-chat-model-pin.sql ./
COPY 61-world-build-worklist.sql ./
COPY 62-orientation.sql ./
COPY 63-orient-survey.sql ./
COPY 64-auto-critique.sql ./
COPY 65-rigor-mode.sql ./
COPY 66-rigor-verify.sql ./
COPY 67-rigor-force-final.sql ./
COPY 68-model-fallback-hardening.sql ./
COPY 69-a2a-engine.sql ./
COPY 70-hinge-decouple.sql ./
COPY 71-hybrid-rrf.sql ./
COPY 72-hybrid-rrf-everywhere.sql ./
COPY 73-brain-hybrid.sql ./
COPY 74-north-star.sql ./
COPY 75-wire-brain-hybrid.sql ./
COPY 76-wire-engram-search.sql ./
COPY 77-tool-shelf.sql ./
COPY 78-yt-slide-frames.sql ./
COPY 79-bineval.sql ./
COPY 80-rest.sql ./
COPY 81-spiral-oracle.sql ./
COPY 82-world-graph.sql ./
COPY 83-code-graph.sql ./
COPY 84-tool-effect-gate.sql ./
COPY 85-world-chat.sql ./
COPY 86-sticky-agent-family.sql ./
COPY 87-lab.sql ./
COPY 88-credentials.sql ./
COPY 89-attention.sql ./
COPY 90-harness-executor.sql ./
COPY 91-core-compat.sql ./
COPY 92-wiki.sql ./
COPY 93-recall.sql ./
COPY 94-wiki-curator.sql ./
COPY 95-model-role-toggles.sql ./
COPY 96-wiki-assets.sql ./
COPY 97-world-wiki-bridge.sql ./
COPY 98-crawler.sql ./
COPY 99-route-intake.sql ./
COPY 100-schedule-chat.sql ./
COPY 101-lab-dispatch.sql ./
COPY 102-war-game.sql ./
COPY 103-abort-conditions.sql ./
COPY 104-observations.sql ./
COPY 105-seams.sql ./
COPY 106-schedule-visibility.sql ./
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
