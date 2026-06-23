# examples/

Copy-paste starters that make the substrate yours. These are **not** applied by
`CREATE EXTENSION` — they're optional imports you run against a live database.

| File | What | How |
|------|------|-----|
| [`models.sql`](models.sql) | A starter model catalog (opencode zen/go, Gemini, LM Studio) with snapshot prices. Pairs with [`docs/wiring-up-models.md`](../docs/wiring-up-models.md). | `psql "$STEWARDS_DSN" -f examples/models.sql` |
| [`book-digester.sql`](book-digester.sql) | Picks the next book off a reading shelf, fetches its public-domain text, and digests it in one pass (read → digest → critique → recommend), publishing a study doc + brain entry. | `psql "$STEWARDS_DSN" -f examples/book-digester.sql` |
| [`book-corpus.sql`](book-corpus.sql) | Persists a digested book's **source text** (`book_text` + `book_chunks`, keyed by `book_slug`) so a book-study chat can quote the book's actual passages — `book_search` (FTS + verbatim). The book digester calls `book_persist_corpus` after `fetch_url`; the doc frontmatter gets a `source_url`/`has_corpus` backlink. The video equivalent is `yt-transcripts.sql`. Apply after `book-digester.sql`. | `psql "$STEWARDS_DSN" -f examples/book-corpus.sql` |
| [`playlist-digester.sql`](playlist-digester.sql) | Watches a YouTube playlist and digests each new video (read → digest → critique → recommend). Needs the **yt MCP overlay** — see below. | bring up the yt overlay, then `psql … -f examples/playlist-digester.sql` |

Import a file, then trim it to what you actually use. Prices are snapshots —
treat them as cost-cap estimates and let the auto-probe verify what's usable.

## On MCP servers

Several examples register external **MCP servers** to give agents tools (the
playlist digester needs the `yt` server; the research pipelines lean on
`fetch-md` and web search). The mechanics — stdio vs. remote HTTP, the
deny-by-default grant flow, secrets via `$env:` indirection — live in
[`docs/wiring-up-mcp-servers.md`](../docs/wiring-up-mcp-servers.md), with worked
examples for our public servers ([gospel-engine](https://github.com/cpuchip/gospel-engine),
[dnd-tools](https://github.com/cpuchip/dnd-tools)). For the YouTube overlay
specifically:

```bash
docker compose -f docker-compose.yaml -f docker-compose.yt.yaml up -d --build
docker compose exec -T pg psql -U stewards -d stewards < examples/playlist-digester.sql
docker compose exec bridge stewards-mcp bridge refresh-tools
```

For putting a persona in a live chat room, see
[`docs/personas-and-chattermax.md`](../docs/personas-and-chattermax.md).
