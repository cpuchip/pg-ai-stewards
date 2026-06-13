# examples/

Copy-paste starters that make the substrate yours. These are **not** applied by
`CREATE EXTENSION` — they're optional imports you run against a live database.

| File | What | How |
|------|------|-----|
| [`models.sql`](models.sql) | A starter model catalog (opencode zen/go, Gemini, LM Studio) with snapshot prices. Pairs with [`docs/wiring-up-models.md`](../docs/wiring-up-models.md). | `psql "$STEWARDS_DSN" -f examples/models.sql` |

Import a file, then trim it to what you actually use. Prices are snapshots —
treat them as cost-cap estimates and let the auto-probe verify what's usable.

More examples land here as the packaging fills in (registering a web-search key,
bring-your-own domain MCP servers, an example agent + grants).
