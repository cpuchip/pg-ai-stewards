# 2026-06-24 — Stewdio Developer toggle (focusing release S1–S4), workflow-tested

First build increment of the focusing release: the "one surface, two depths"
Developer toggle. Built oracle-first, then stress-tested with a 4-lens QA workflow
that found a real blocker the oracle structurally couldn't.

## What shipped

A persisted `store.dev` flag (default OFF). OFF = clean everyday cockpit; ON brings
the power/ops surfaces back, zero capability loss. Guards:
- model-role select (raw reason/ingest/critic) → Developer-only, + added the missing
  `vision` option.
- the `🔧 retrieving` provenance/facet-chips row (ChatPanel) → Developer-only.
- per-stage `s.model` column + raw input-JSON dump (ArtifactPanel) → Developer-only.
- the Models pane → hidden from the launcher AND actively closed when Dev flips off.
Plus S1 labels: "Work items" → **Library**; `＋ New` → `＋ New task` (Library) vs
`＋ New chat` (Chat); empty-state copy.

## The test loop (the point of the exercise)

1. **Deterministic oracle first** (`cmd/stewards-ui/frontend/test/dev-toggle.oracle.sh`,
   playwright-cli) — asserts the invariants BOTH directions (OFF hides → ON shows →
   OFF hides; flag persists). It caught **four** of my own bad test assumptions
   before they could masquerade as bugs (the `＋New chat` conditional render; the
   launcher-open mechanic; and a CSS `text-transform:uppercase` + `innerText` trap
   where `'Running now'` renders as `RUNNING NOW`). Final: **13/13 green.**
2. **4-lens QA workflow** (`wf_4c77ff4a-461`: leak-audit · regression-audit ·
   ux-consistency · completeness-critic) — found the **BLOCKER the oracle missed**:
   the Models pane (the #1 dev surface) leaks on Dev OFF via two paths the oracle
   never drove — a **saved layout** restoring it on reload, and **toggling Dev off
   while it's open** (`visiblePanels` only filters the launcher menu, not open panes).
   Plus a dead-end (closed-then-can't-reopen).

## Fixes from the QA pass (before commit)

- **closeDevPanes()** — `watch(() => store.dev, …)` closes any `dev:true` pane when
  Dev flips off, and the same close-loop runs at the end of `onReady` (handles the
  saved-layout restore path). One fix, both paths; reuses the PANELS `dev:true` set.
- **LAYOUT_KEY v2→v3** — so the Library rename + dev-pane pruning reach existing
  installs without a manual ⟲ reset.
- **un-persisted chatModel** — the QA flagged (twice) that persisting a Dev-only
  role select silently strands an everyday user on a role they can't see or reset.
  Reverted to a session-only ref (the S3 "persist chatModel" guess was wrong).
- **gated `wi.pipeline` + `wi.maturity`** (ArtifactPanel) — ops jargon, half-applied
  guard; now Developer-only (status stays — it's plain English).
- **persisted() typeof guard** — ignore wrong-typed stale localStorage values.

## Lessons

- The deterministic oracle is the FLOOR (perfect recall on what it drives); the
  adversarial workflow catches what the oracle structurally can't (the oracle drove
  the launcher path; the leak lived in the restore/runtime-toggle paths). Both, not
  either.
- **When a bug escapes the oracle, extend the oracle.** Added the open-Models →
  toggle-off → assert-closed path so the leak can't silently return.

## Carry (next increments — all no-new-verbs)

- **S5 intent-named launcher** — READY, no backend dep: `pipelines.value.description`
  is already on the wire, just discarded; render it + map families to Research /
  Generate / Digest / Build / Reflect. Highest-leverage next (makes the engine's
  superpowers discoverable). Then S6 (merge the two session surfaces), S7 (brandTitle
  hook), S8 (collapse the ~18-route nav into the Developer menu — the biggest remaining
  clutter, needs a Michael call on the everyday-nav minimal set), S9 (Tufte
  `<SparkMetrics>` — define its data-binding oracle first).
- UX (S6-adjacent): drop `⬇` from the everyday chat header (export is in `/export`),
  label-or-gate `💬`; persist the grounding lens (only chatModel was; lens resets on
  reload).
