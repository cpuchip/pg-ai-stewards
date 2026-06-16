# 2026-06-16 — the cut, and every seam it opened

The night the substrate became one. Michael said "lets cut over… full send," and
it turned out to be a real migration with a tail of bugs that the cut's "36/36
clean" apply could not see. We found and closed each one, then built the test
layer that would have caught them.

## The cut (executed)

Live (`pg-ai-stewards-dev/bridge/ui/persona-host`) is retired — stopped, not
removed, recoverable. The OSS stack is the sole substrate. The real blocker was
never parity (the rebuilt core was already a superset of live); it was that the
generic OSS bridge ships 5 MCPs while the operator's tool-using personas need
their domain MCPs. Built a **Michael-bridge** image — `FROM` the live bridge
(inheriting the domain binaries + data + yt-dlp/ffmpeg) with the OSS clean-room
substrate binaries (`stewards-mcp`/`cli` + entrypoint) swapped in; same
Alpine/musl base, drop-in. Sequence: archive dump → operator overlays applied →
runtime-only rows COPY'd over (a `fiction` agent, `persona_host.personas` the
self-seed doesn't cover) → bridge up (refresh-tools all green) → persona-host
swapped (stop-live-first; one host; no double-fire) → `.mcp.json` repointed →
live stopped. The persona-host config (its `persona_host` schema, default
personas, room grants from the chat platform) self-seeds on connect — that
simplified the cut to "repoint `STEWARDS_DSN`."

## The seams (each fixed)

1. **Stale overlays clobber core finals.** Personas "started then went silent."
   Root cause: overlays authored against the old substrate's *chronological*
   history re-author functions the consolidated core finalizes *later* — applied
   core-then-overlay they REVERT the core. `r6` reverted `on_one_shot_pipeline_completed`
   (dropping its persona/subagent arms → turns never reached `verified` → the host
   timed out). `pe5` reverted `on_maturity_verified` (dropping the pool-publish).
   Fixed by `cut3-restore-core-finals.sql` (manifest tail, wins). **Then built the
   oracle:** `parity/overlay-clobber-check.sh` diffs every function body
   core-only vs core+overlays and FAILS on any non-allow-listed core function an
   overlay reverts. "overlay-replay clean" only ever meant "no SQL error" — never
   "no semantic revert." Now there's a check that means the latter, + the rule in
   `overlays/README.md`.

2. **A persona dumped the same answer to every question.** Prompt over-weighted
   "cite the top findings" + a 16k token budget invited a canned recap. Fixed:
   answer the specific question first, support with only the relevant finding,
   say so when the pool doesn't cover it; budget 16k→3k. Verified: distinct
   questions → distinct answers.

3. **A persona answered one turn behind.** A tool-using turn spans several
   work_queue items (chat → tool → chat …); `consult_subagent_dispatch` returns
   only the FIRST wq, which completes after the first model call — not the final
   answer. `ConsultTurn` read the latest assistant message at that moment = the
   PRIOR turn's reply. (Turn-zero was correct because it waits on the work_item to
   complete; only consults lagged.) Fixed: baseline the newest assistant id before
   dispatch, wait for a NEW one to land — unambiguously this turn's.

## The missing test layer

Every one of those bugs lived in the **running-turn loop** (dispatch → tool-rounds
→ verify → consult), which virgin-smoke (schema) and verify-* (single functions)
do not exercise. Built `tests/e2e-turn-loop.sh`: runs a real turn and asserts it
auto-verifies + is non-empty (catches #1), different questions → different answers
(catches #2), and a consult produces a new tracked reply (the #3 path). PASS on
the current stack. The full code audit Michael called for stays tasked for a
fresh pass — this is its first installment.

## New capability + a design

- **request_research** (persona-initiated research): when a pool-reading persona
  can't answer, it queues a research request as an *approve-gated proposal* on the
  intent; approve → the capacity-gated drain works it → the finding publishes to
  the pool → the persona answers next time. The front-desk feeds the back-office.
  Gated v1 adds no new unsupervised autonomy (rides the existing approval queue);
  auto-drain is a future council call.
- **Skills proposal** (`.spec/proposals/skills.md`): instruction modules as a
  context lever — frontmatter always visible, body loaded on demand, the agent
  turns them on/off. Plus **skill groups + a 3-tier catalog** (group summary →
  skill frontmatter → body), the engram move applied to skills so a big library
  costs almost nothing until reached for. First group = storytelling craft for the
  fiction/gamemaster personas (the `.claude/skills/*` set are import candidates).
  Awaiting ratification (D1–D6).

## Carry-forward

- Ratify skills D1–D6; decide `.stewards/` (archive vs. relocate to the workspace).
- The full code audit (#175's bigger sibling) — a rested pass.
- persona-host should stamp the persona's intent/project on dispatch (auto-scopes
  pool reads + research requests) — request_research's v1 has the persona pass it.
- Remove the stopped live containers + archive the volume once the OSS stack
  soaks clean.
- Born-clean debt: the Michael-bridge is pragmatically `FROM` the live image; a
  from-source domain-MCP rebuild is the purity follow-up.
