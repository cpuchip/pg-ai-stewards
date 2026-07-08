# The Companion pack — a voice for the steward, and a Hinge-gated forge

An **add-on pack**, not core. The substrate ships lifeless; this pack, applied by
choice, gives an installed instance two things:

1. **A voice seat** — a role home for [loom](https://github.com/cpuchip/loom) serve's
   OpenAI shim (`scripts/loom-companion-home/` in this repo) so any
   OpenAI-compatible voice front (we use [Spin](https://github.com/cpuchip/spin) —
   Pipecat + local Whisper STT + local Kokoro TTS) talks to a real Claude session
   that carries the substrate's MCP tools. The seat's CLAUDE.md is written for
   text-to-speech output and includes the **bootstrap ritual**: on first meeting it
   learns who you are and writes a `companion-profile` doc; ever after it greets you
   by name.
2. **The forge** — Hinge-gated self-extension. You wish for a capability by voice
   (or Stewdio, or SQL); the `forge` pipeline plans it as **exact SQL + its own test
   call**, then **stops on your approval bell**. Approve, and the deterministic
   registrar applies the function, runs the plan's test, and registers the tool —
   all in one transaction. The test fails → nothing exists. You never approve →
   nothing exists.

## Install

```bash
docker compose exec -T pg psql -U stewards -d stewards < packs/companion/forge.sql
docker compose exec -T pg psql -U stewards -d stewards < packs/companion/smoke.sql   # the oracle
```

Voice seat (host side): copy `scripts/loom-companion-home/CLAUDE.md` into
`~/.stewards/companion-claude-home/` next to a `stewards-mcp.json` (your Arc-C HTTP
MCP endpoint + bearer), credentials, and `settings.json` with `"effortLevel": "low"`
(voice wants short, fast turns). Then point your voice front's OpenAI base URL at
loom serve with model `sonnet#companion`. Spin does this with `SPIN_COMPANION=1`.

## Using the forge

```sql
SELECT stewards.work_item_dispatch_stage_safe(stewards.work_item_create(
  'forge',
  jsonb_build_object('assignment', 'I want a tool that tells me the phase of the moon for a given date.'),
  NULL, 'human', NULL,
  (SELECT id FROM stewards.intents WHERE slug='companion')));
```

The plan lands on the bell (Stewdio → "Needs your answer") with the tool's purpose,
risks, **the complete SQL**, its args schema, and the test call. Read the SQL.
Approve → forged, verified, live. The receipt lives in `forge.forged_tools`.

## The trust model, honestly

- **The approval is the wall.** The human approves the exact SQL; the registrar
  executes that and nothing else. Structure checks (single statement, `forge`
  schema only, `jsonb→jsonb` signature) are a seatbelt against accidents, not a
  sandbox against a malicious approver.
- Forged functions run inside Postgres as the extension owner. The planner is
  instructed to keep them read-only against `stewards.*` and away from governance
  tables — but the reviewer's eyes are the enforcement until the policy layer
  (D3C) lands.
- Forged tools **cannot** reach the network, the filesystem, or send anything —
  they are plpgsql. Wishes that need those things get an honest "the forge can't
  do that part" in the plan, with the largest safe subset offered.
- New tools are live immediately for substrate pipelines and chat. Harness seats
  behind the Arc-C HTTP surface (including the voice companion) see them after
  that surface's tool list refreshes.

## Uninstall

```bash
docker compose exec -T pg psql -U stewards -d stewards < packs/companion/uninstall.sql
```

Removes the pipeline, the registrar tool, and — deliberately requiring an explicit
extra step printed by the script — any forged tools themselves.

## Provenance

The plan→approve→verify→register loop is the good idea in
[Ada-SI](https://github.com/nazirlouis/Ada-SI) (MIT, Naz Louis), rebuilt on the
substrate's own organs: Ada's chat approval became the durable bell; Ada's
throwaway-venv verify became a Postgres transaction; Ada's hot importlib reload
became `tool_defs` rows, which were always hot.
