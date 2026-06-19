# Agentic Doc Construction — digesters build the artifact, not emit it

**Status:** PROPOSAL (awaiting ratify — dominion_in_council; new standing pattern).
**Date:** 2026-06-19. **Origin:** the local-model soak (`.mind/sessions/pg-ai-stewards-soak-watch.md`)
surfaced 3 failure modes on the FlexLLama local rig; Michael's reframe addresses all three at once.

## The core insight

The digester stages today make the **final document the model's one-shot chat output** — gemma
reads a whole book and emits a 20k-char digest in a single generation; qwen emits a structured
digest in one call. That is the anomaly. **No good agentic worker produces a large structured
artifact in one shot** — Claude doesn't write a 20k doc in one generation, it *builds* it with
edits, reads back, and self-corrects. We were asking small local models to do something even the
big models don't do.

**Reframe:** a digester should work the way the **coder** already works (`code-write`/`code-pr`):
- The **artifact is built incrementally via tool-call diffs** against a work-in-progress doc.
- The model's **chat output is a free-flow JOURNAL** — "here's what I did and what I found" —
  exactly like Claude's reports to Michael. Captured as the work_item's narrative.
- A failed tool call **feeds its error back** to the model → it self-heals (redemptive work),
  same as the coder's verify loop.

This is not a small-model hack. It is making digesters work the way *all* good agentic work works.
Small models are **trained** for tool-calling loops; they are brittle at one-shot huge structured
prose. Play to the trained strength.

## How it addresses the 3 soak findings

1. **15-min reaper false-kills slow reads** → SOLVED *if the reaper is per-call* (evidence: it
   killed a single `work_queue` chat row, wq 8502 — so per-dispatch, not per-work-item; **VERIFY
   this before building**). Breaking one 25-min generation into many short tool rounds means no
   single dispatch exceeds 15 min. (If reaper is per-work-item, small calls don't help → raise the
   threshold instead.)
2. **gemma `--parallel 1` contention** → SOLVED/eased. A 25-min call monopolizes gemma's one slot;
   fifteen ~30s calls leave gaps other work_items slip into — helps even at `--parallel 1`, stacks
   with raising it (see `local-throughput-experiments.md`).
3. **qwen "peg-native format" 500 on grammar/structured stages** → SOLVED, but be precise about WHY:
   tool calls **are** structured output (function-call JSON). We are not escaping structure — we are
   switching to the structure these models are *trained* on. Two real wins: (a) function-calling is a
   first-class tuned capability vs. brittle GBNF/peg grammar on free prose; (b) tool-calling lets the
   model **think, THEN emit the call** — the reasoning tokens that broke qwen's grammar are *allowed*
   before a tool call. That is the actual mechanism.

## Architecture

**A. Doc-builder tool surface** (the main build) — markdown equivalent of the coder's `ApplyEdits`:
- `doc_create(title, outline)` — start a WIP doc (outline-first, for coherence).
- `doc_append_section(handle, section, body)` / `doc_patch(handle, anchor, new)` — small diffs.
- `doc_read(handle [, section])` — read back what's built (read-before-write discipline).
- `doc_finalize(handle)` — mark complete → pool it (existing `import_doc`).
- WIP doc storage: decision needed — a `draft` flag on `docs`, or a `doc_drafts` table. Lean: a
  status column on the existing docs/pool so finalize is a state flip, no copy.

**B. Stage shape** — recast a digest stage from "emit the doc" to a **tools-on loop**:
1. (read/gather) page the source in bounded chunks via the page-in tools (`33-page-in.sql`:
   `result_read`/`result_search`), building running notes via `doc_append_section`. No single huge call.
2. (build) outline → fill sections with small `doc_append`/`doc_patch` diffs.
3. chat final output = the **journal** (what it did / found / chose) → work_item narrative.
4. The DOC (via `doc_finalize`) is the artifact → pooled as today.

**C. Critic/verify adapts** — the critic stage reads the *built doc* (`doc_read`) instead of a passed
blob; verify gates on the finalized doc. Self-heal: a failed `doc_*` call returns an error the model
sees and retries.

**Reuse (not starting cold):** coder `ApplyEdits` + verify/self-heal pattern; page-in tools (built
this session); the gather loop (already tool-calls successfully on local — research-summary completed).

## Pilot

**playlist-digest** — it is the leg actually *broken* on qwen (peg-format). Best proof: if tool-call
construction makes the **broken** leg work on local, the thesis is proven before touching book-digest /
research-summary. Then generalize.

## Tradeoffs / risks (go in eyes-open)

- **More rounds = more prompt-processing overhead.** Each round re-sends context → one digest's
  wall-clock may *rise* even as reliability + interleaving improve. The page-in + `compact_context`
  tools keep re-sent context small — that's what makes it affordable on local. **Measure it.**
- **Coherence** — building by diffs risks a disjointed doc. Mitigation = outline-first, then fill;
  the journal carries the reasoning thread.
- **Tool-call reliability on the smallest models** — qwen/gemma proven for gather loops; nemotron
  unproven for multi-round tool loops. Cast the doer accordingly.

## Decisions for ratification (dominion_in_council)
1. Doc-builder tool surface shape + WIP storage (draft-flag vs draft-table).
2. Journal capture: work_item result field vs a sibling journal doc.
3. Which models are the "builders" (tool-loop doers) per stage (gemma/qwen; nemotron?).
4. Pilot scope = playlist-digest only, then a go/no-go before generalizing.

## ★ PILOT — THESIS PROVEN 2026-06-19 (Phase 1 + isolated build test)
Phase 1 (the tool surface, `34-doc-builder.sql`) shipped + chained (OSS `6145d51`). Then the core
thesis was proven in isolation on the *broken model*: a tools-on `build` stage on **qwen** (the model
that 500'd with "peg-native format" on the one-shot digest) was given a short transcript and told to
build via the doc tools. Result: **8 flexllama chats, 0 errors, 0 peg failures** — qwen ran
doc_create → 4× doc_append_section → doc_read → doc_finalize, pooled a coherent 2356-char digest
(proper Thesis / How-it-builds / Key-passages / Themes), and its final message was a short JOURNAL
(not the doc). The reframe works: tool-call construction + think-then-call sidesteps the grammar that
one-shot generation tripped. Test artifacts cleaned up.
**Remaining for the full playlist recast (the "wiring", thesis already proven):**
- `playlist_publish_draft(handle, video_id, title, playlist)` bridge — pulls the draft body
  SERVER-SIDE and runs the existing publish logic (seen-mark, brain, file, 11-char guard). Critical:
  the model must NEVER pass the full body as a tool arg (that's the one-shot generation again); it
  passes only the handle.
- Recast playlist-digest stages: read (unchanged) → build (tools-on doc construction, collapses
  digest+critique+recommend; re-add a critic doc_patch pass later). halt_on stays read→(NO PLAYLISTS/
  NOTHING NEW). Update stage_models + pipeline_stage_maturity for the new stage set.
- Live test on a fresh video (needs an unseen video / a fresh playlist).

## Verify-first checklist before build
- [ ] Confirm reaper scope is per-call (else raise threshold instead).
- [ ] Confirm `doc_*` tool calls round-trip on local qwen + gemma (think-then-call works).
- [ ] Confirm the journal-as-output reads well (it's the provenance trail).
