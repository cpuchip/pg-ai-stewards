# stewards_companion — the companion pack as a real extension

Proof subject for D2A (#319): `forge.sql`+`companion.sql`+`steward-tools.sql`
packaged as a pure-SQL extension (no pgrx). Plan: `.spec/proposals/d2a-pack-extension-battle-plan.md`.

## Two install paths

- **Extension (here):** `CREATE EXTENSION stewards_companion` after the core.
  `--0.1.0.sql` = forge+companion; `--0.1.0--0.2.0.sql` = +steward-tools;
  `--0.2.0.sql` lands a fresh install at 0.2.0 directly. Copy files into the
  server's extension sharedir first (`/usr/share/postgresql/18/extension/` in
  the shipped image — see `extension/Dockerfile`'s stage-2 comment).
- **Loose SQL (dev path, unchanged):** apply `packs/companion/*.sql` directly
  with `psql -f`, per `packs/companion/README.md`.

## Status

Scaffold only. `stewards_companion.control` records an open DROP-survivors
question (TODO(window)) that gates `test-extension.sh` stage 6. Run
`verify-verbatim.sh` to blind-check the shipped `--X.sql` files.
