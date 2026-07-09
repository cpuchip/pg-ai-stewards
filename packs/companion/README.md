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
docker compose exec -T pg psql -U stewards -d stewards < packs/companion/companion.sql        # reminders + bell + verbal approval
docker compose exec -T pg psql -U stewards -d stewards < packs/companion/steward-tools.sql    # forge_start, work_item_unstick, model_health(_check)
docker compose exec -T pg psql -U stewards -d stewards < packs/companion/steward-tools-v2.sql # task_start, doc_brief
docker compose exec -T pg psql -U stewards -d stewards < packs/companion/smoke.sql      # the oracle (forge)
docker compose exec -T pg psql -U stewards -d stewards < packs/companion/smoke-v2.sql   # the oracle (task_start + doc_brief)
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

## Durable reminders + the dynamic tool surface

`companion.sql` adds `companion.reminders` (rows — they survive every session) with
`reminder_set/list/cancel`, the spoken-friendly `companion_bell`, and
`companion_approve` (verbal approval of awaiting_review items — the seat must read
the plan aloud and hear an explicit yes first). Delivery is the voice front's job:
Spin's companion mode polls `companion.reminders_claim_due()` every 10s while a
client is connected and speaks due reminders unprompted; reminders that come due
with nobody connected are spoken on the next connect.

Harness seats reach ALL of these — and every FORGED tool, the moment it exists —
through `substrate_tool`/`substrate_tools` on the MCP surface (the dynamic sql_fn
dispatcher): read-class tools dispatch freely; write-class only if named in the
`arc_c_dynamic_write_allowlist` config row, which this pack seeds with exactly
the three reminder/approval tools. `forge_register` is deliberately not on it.

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

## Steward tools — converse with work, by voice (2026-07-08)

`steward-tools.sql` (apply after `companion.sql`) adds the verbs the first real
voice session was missing:

- **`forge_start`** — speak a wish, get a plan on the bell. Allowlisted because it
  is safe by construction: the forge registrar is bell-gated, so voice can only ever
  produce a PLAN awaiting approval. Rate-limited 5/hour.
- **`work_item_unstick`** — re-dispatch ONE failed/parked item's current stage,
  optionally pinning a validated model (alias or provider/model). Refuses anything
  not failed/awaiting_review. Verbal gate: error read aloud + explicit yes.
- **`model_health`** (read) — per-model report: usable flag, last probe, alias
  membership, recent failures naming it.
- **`models_health_check`** — bounded (≤25) probes through the substrate's own
  dispatch path; `include_disabled=true` re-tests operator-toggled-off models.
  Reports only — it never re-enables anything.

Field note that motivated the health pair: a model can pass its (non-streaming)
probe while the provider rejects it on the STREAMING path that pipeline dispatches
actually use — Console Go did exactly this. `model_capability.supports_streaming`
records the evidence; a streaming-aware probe is the filed follow-up.

## Jarvis wave — start real work and read docs aloud, by voice (2026-07-09)

`steward-tools-v2.sql` (apply after `steward-tools.sql`) adds two more verbs, ratified
from Michael's "Jarvis list":

- **`task_start`** — the generalization of `forge_start` to ANY registered pipeline
  family, not just `forge`. Refuses a `pipeline_family` that doesn't exist in
  `stewards.pipelines` — and lists the real ones — and refuses a wish under 10 or over
  4000 chars, or a `slug` already in use. Rate-limited 5/hour across every family (the
  count keys off a marker this function stamps into `input`, since `work_items` carries
  no created-via column). Allowlisted, but **not safe by construction the way `forge`
  is** — most pipelines run straight through to completion with no further approval
  bell (a `code-pr` item, say, ends at an opened draft PR). The safety net is
  procedural: the tool description requires the calling seat to confirm the pipeline
  family AND the wish wording aloud and hear an explicit yes before ever calling it.
- **`doc_brief`** (read) — a doc's shape (title, kind, updated_at, word_count) plus its
  body trimmed to ~1200 chars at a paragraph boundary, by slug or id. Sized for a
  spoken summary, never a verbatim read of the whole doc. A miss returns the 3 nearest
  slugs by `ILIKE` substring match (this codebase deliberately carries no pg_trgm — see
  `extension/v02-governance.sql` and `v22-route-intake.sql` — so this is substring
  containment, not a similarity score: a truncated or mis-heard slug guess will find
  its target; a same-length typo may not).
