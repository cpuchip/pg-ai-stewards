# 2026-06-24 — Stewdio intent-named launcher (focusing release S5), workflow-tested

Second build increment of the autonomous focusing-release run. Same loop:
build → deterministic oracle → workflow QA → fix → commit.

## What shipped

The launcher's raw `<select>` of 53 internal pipeline slugs is replaced with the
**things the engine is FOR**, as a verb grid. Each verb maps to the user-facing
pipelines that exist on this install (filtered against the live `/api/pipelines/list`),
rendering their descriptions instead of slugs. `launch()` submits the family
unchanged — dispatch is identical.

## The QA pass changed the design (correctly)

The 3-lens QA workflow (`wf_af3ab766-81c`) + a confirming grep turned a naive
"5 verbs" into an honest "3 verbs that actually work from this form":

- **HIGH — Build fails from a topic string.** `code-pr`/`code-deploy` template
  `input.repo`/`base_branch`/`acceptance_criteria`/`sandbox` (20-coder.sql); a
  topic textarea supplies none → a guaranteed failed work item. **Dropped Build.**
- **Digest is shelf-driven, not topic-driven** (grep): `book-digest` claims the next
  QUEUED book via `book_next` (it's the scheduled hourly digester); playlist/yt need
  a source URL. A topic textarea wouldn't digest what you type. **Dropped Digest.**
- **HIGH — "more pipelines…" re-opened the exact jargon S1–S4 closed** (the raw
  53-slug list shown to everyday users, one commit after the Developer toggle hid
  it). **Gated "more pipelines…" behind `store.dev`.**
- MED desync (verb highlight vs the raw select) → clear the verb on a raw `@change`.
  LOW empty-state when no pipelines. NIT reset launcher state on open/launch.

**Everyday verbs are now Research / Generate / Reflect** — the three that genuinely
run from a binding-question. Build + Digest need their own adaptive input forms
(repo+criteria / source+shelf) before they belong on the everyday surface (**task
#257**); until then they're reachable via the Dev-gated "more pipelines…", and the
"digest a thing I give you" path is drag-drop doc-extract.

## Lesson

A single topic textarea only fits binding-question pipelines. The verb concept and
the pipeline's required input must match, or the everyday user gets a button that
silently fails. The QA caught one case (Build); a grep caught the second (Digest)
the QA missed — verify the tool's findings, don't just trust the list.

Oracle extended (`dev-toggle.oracle.sh`, **19/19**): verbs render, Build dropped,
"more" Dev-only, picking a verb sets its pipeline. Next: S6 (merge the two session
surfaces + drop ⬇/label 💬 in the chat header), S7 (brandTitle hook), S8 (collapse
the ~18-route nav — needs Michael's everyday-nav-set call), S9 (Tufte SparkMetrics).
