# pg_ai_stewards — the extension

The substrate's core: a Rust (pgrx) PostgreSQL extension plus its SQL
migration chain. Everything an agent turn touches — work items,
pipelines, agents, dispatch, councils, gates, trust, sabbath/atonement,
cost, the context engine — lives here as tables, functions, and
triggers. See [docs/anatomy-of-a-turn.md](../docs/anatomy-of-a-turn.md)
for the narrative.

## Two tiers of SQL

1. **Bundle tier** — the `extension_sql_file!` chain in `src/lib.rs`
   embeds ~52 SQL files into the extension at compile time.
   `CREATE EXTENSION pg_ai_stewards` applies all of them. The versioned
   bundle (`pg_ai_stewards--*.sql`) is a **build artifact** — generated
   by `cargo pgrx package` inside the Docker build, never checked in,
   never listed in the migration manifest. (Upstream lesson: a stale
   checked-in bundle kept re-seeding retired data on every fresh boot.)
2. **Runtime tier** — everything in `migration-order.txt`, applied by
   the migration runner **in manifest order, never lexical order**.
   (Upstream lesson: a lexical directory scan replayed a scratch file
   into a live database.) Entries are idempotent; the ledger records
   each by name + sha.

Downstream overlays add a third tier: their own manifest, applied after
core. The ledger keeps core and overlay entries distinct.

## Layout

| Path | What |
|---|---|
| `src/*.rs` | Extension code: bgworkers (dispatch loop), providers, tools, YAML seed parsers, schema |
| `*.sql` | The migration chain (bundle-tier files are also runtime entries — idempotent) |
| `migration-order.txt` | The replay manifest — the only authoritative order |
| `init/00-extensions.sql` | First-boot initdb hook: `CREATE EXTENSION` vector, age, pg_ai_stewards |
| `Dockerfile` | Two-stage build: cargo-pgrx against PG18 → pgvector/AGE runtime image |

## Provenance

Extracted 2026-06-12 from the private workspace where the substrate
grew (clean-room: fresh history, every file audited). Five migrations
were split at extraction — machinery stayed here, workspace seed rows
moved to the downstream overlay; each carries a note at the split
point. Domain-flavored text retained in core (corpus tool names,
`scripture_anchor`) is heritage, documented in the extraction plan's
genericization worklist.
