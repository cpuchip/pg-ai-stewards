# 2026-07-08 overnight — the substrate got a voice, and a Hinge-gated forge

**Mandate (Michael, ratified before sleep):** "lets ratify everything now and you can
build while I sleep… this should probably be an add on / plugin… keeping
pg-ai-stewards lighter and more configurable by install… the most rewarding thing
would be to interact with you basically with my voice and we build together."
Sparked by Naz Louis's Ada-SI video/repo (MIT) — whose plan→approve→verify→register
loop we rebuilt on the substrate's own organs rather than importing.

## What shipped (all pushed)

**1. The companion seat** (`scripts/loom-companion-home/`, deployed to
`~/.stewards/companion-claude-home/`): a loom-shim role home whose CLAUDE.md is
written for text-to-speech — spoken prose only, no narration of checks or tools,
short turns, never speak secrets — plus the Ada-steal **bootstrap ritual** (first
meeting → get-to-know-you → `companion-profile` doc; greet-by-name after) and the
forge hand-off posture. Sonnet at effort low: **~5s warm turns** (measured), ~45s
cold with the bootstrap tool call.

**2. Spin companion mode** (`cpuchip/spin` `530e9da`): `SPIN_COMPANION=1` points the
Pipecat voice loop (local Whisper GPU STT + Kokoro TTS + Silero barge-in) at loom
serve's OpenAI shim, model `sonnet#companion`. SPIN_LLM_* env deliberately ignored in
this mode; loom's serve token read from `~/.stewards/loom-serve-token-current`
(found live: the shim is keyless without a bearer but 401s a WRONG one, and the
OpenAI client always sends one); client-side MCP skipped — the seat owns tools;
`LLMContext()` without kwarg (Pipecat 1.3 rejects `tools=None` — latent bug in the
old no-gospel path too).

**Live headless proof** (playwright + fake mic): WebRTC connect → the seat's first
greeting ran the quiet profile check, spoke real substrate state, and opened the
ritual; after a CLAUDE.md tightening (it initially SPOKE its deliberation — "No
profile yet, so this is our first meeting" — the top rule now says every word is
spoken aloud, no scratch space) the greeting came out clean: *"Hey — good to hear
from you. What are we working on?"* A text user turn then asked for today's
completions → the seat queried the real ledger → Kokoro spoke: *"Eight work items
finished today — all the hourly memory-tend runs, from just after midnight through
three-thirty this morning."* The real-mic half is Michael's morning test (ungrindable
— honest split).

**3. packs/companion — the forge** (`6ca9ac8`): the first true add-on pack (Michael's
"lighter and more configurable by install" steer; zero new core volumes; uninstall.sql
included). Pipeline `forge` = plan (LLM, `auto_advance=false` → **the existing bell**,
with the tool's purpose, risks, EXACT SQL, args schema, and its own test call) →
register (deterministic: `forge.forge_register` applies the SQL, runs the plan's test,
registers the tool_defs row, writes the `forge.forged_tools` receipt — ONE transaction,
any failure rolls back everything). Structure seatbelt (single statement, `forge`
schema only, jsonb→jsonb); **the approval is the wall** — stated plainly in the README.
Smoke green on scratch AND live: happy path + inverse (failing self-test leaves no
function/row/receipt) + wrong-schema and smuggled-statement refusals.

**Live e2e, first try:** wish ("moon phase by voice") → plan on the bell → I reviewed
the exact SQL as the fixture's approver (pure math, IMMUTABLE, no table access,
defensive) → resumed → **FORGED moon_phase** — and the registrar honestly flagged that
the verify's result diverged from the planner's expected phase name (waxing vs waning
gibbous) instead of hiding it. Tonight's answer: waning crescent, 36% lit. Refining its
phase windows can be the first VOICE-forge conversation.

## Design notes worth keeping

- **The pack pattern seeds D2A** (#319): everything by install (schema, pipeline,
  tools, groups, perms, intent), idempotent, uninstallable, receipts. The pgrx
  `.control` packaging is still D2A's job; this is the shape it will package.
- **The shim's fake streaming** (one SSE chunk after the full reply) is the latency
  ceiling: fine at 5s warm, would be the thing to fix for snappier voice (real
  stream-json forwarding in loom = filed follow-up).
- Forged sql_fn tools are live IMMEDIATELY for substrate pipelines/chat; the Arc-C
  harness surface (incl. the companion seat) sees them after its tool refresh — the
  #346 gap class, now load-bearing enough to fix properly.
- Ada-SI steals delivered: bell-gated plan approval, transaction-as-verify,
  bootstrap ritual. Deferred (filed in the proposal space): interactive skill UI
  templates for Stewdio, the missing-module self-repair for coder verify.

## Carry-forward

- **MORNING:** Michael opens http://localhost:7860/client → Connect → first real
  spoken meeting (the bootstrap ritual is his — the profile doesn't exist yet, on
  purpose). Stack: Spin 7860 + loom serve 7791 + Arc-C 8093 all up (ports.md).
- Real streaming through the loom shim (voice latency).
- #346 Arc-C dynamic tool surface (forged tools + case tools reach harness seats).
- D3C policy layer = the forge's growth path past everything-stops-at-the-bell.
- Voice UX iteration by feel: barge-in vs 5s turns, earcon while the seat thinks,
  Kokoro voice choice — Michael's ears decide.
