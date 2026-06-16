# 2026-06-16 — Skills (3-tier) + Corpus treatment: built, proven, deployed

Two ratified features (#174 skills, #178 corpus), built as a focused pass after the
cut, each isolated to its own rebuild → virgin-smoke → clobber-check → e2e cycle,
then deployed together to the running substrate in one atomic apply.

## Skills — the 3-tier on-demand catalog (#174)

**The council-moment save:** the proposal was written as if `stewards.skills` didn't
exist. It did — the table (with a `body` column already!), `skill_permission`, the
`<available_skills>` flat catalog in `compose_system_prompt`, two seeded skills
(reference-linking, source-verification), and a one-shot `skill` tool
(`load_skill_tool`) that returns a body as the tool *result*. So P0 was the delta,
not a from-scratch build. Reading the live core before writing saved building a
parallel system.

**What shipped (`24-skills.sql`):** `skill_groups` (tier-0 summaries) +
`skills.group_family` + `session_skills`/`session_skill_groups`;
`render_skills_block` (the 3-tier render); the four levers (group_open/close,
load/unload as sql_fn tools, `_session_id`-injected like the context levers); a
loaded-skill budget that **refuses** an over-budget load (no surprise eviction).
`09` calls `render_skills_block` (late-bound forward ref, safe). `compose_tools`
re-authored in 24 (not 16) because it's LANGUAGE sql → validates the `skill_groups`
ref at CREATE; it gates the skill_* levers on the agent having a skill surface.

The persistent lever (body in the system prompt until unload, budgeted) is the
ratified improvement over the pre-existing one-shot fetch; both coexist (different
names). Retire-or-keep the one-shot `skill` is a follow-up.

**First group (`overlays/skills-storytelling.sql`):** `storytelling` (applies_to
`fiction`), 6 skills generated from the harness `.claude/skills/*` + the new
`therefore-but-not-and-then` (authored from the D&D craft study). The fiction agent
prompt already named these by slug — the feature was pre-wired; this made the names
resolve. e2e: 6 skills (~12k chars) collapse to ONE summary line; open → frontmatter;
load believable-villains → body (2470 tok); budget cap → next load refused.

## Corpus — pool-publish decoupled from file-materialize (#178)

**The decouple was cleaner than feared — no new flag.** The pool-publish (`import_doc`)
was nested inside `IF file_destination IS NOT NULL` in `on_maturity_verified`, so the
digest loops (which write their own files via fs tools, no file_destination) never
pooled. Moved it to its own block gated `(auto_materialize+file) OR
project_association IS NOT NULL`. The single signal is `project_association` — the
existing reflect/planning pooling is preserved, and any project-tagged verified work
now pools. `25-corpus.sql` adds the generic `intent_project_map` + an **additive**
BEFORE-INSERT trigger that fills project_association when NULL (FK-guarded: only sets
a project that exists — work_items.project_association FKs projects(slug)). The
overlay seeds the map (book-study→books, video-study→ai, general-research→ai) +
books↔ai neighborhood (the work project stays walled). Backfilled 9 books + 26 yt into the pool.

`cut3-restore-core-finals.sql` carries a verbatim `on_maturity_verified` copy — had
to update it in lockstep, or the clobber-check flags it as a stale revert. (It
didn't; clobber-check stayed 3 overrides / 0 clobbers.)

## What the smoke caught (the value of building the oracle)

The virgin-smoke section 9/10 caught two wrong assumptions before they hit live:
1. "Virgin core seeds no skills" — false (2 core skills). The no-surface assertion was
   replaced with a **skill-deny gate** test (stronger, correct regardless of seeds).
2. `stewards.projects` has a NOT NULL `name` — my `(slug)`-only INSERT failed. Fixed
   the fixture AND the overlay. On live this would have been a silent no-op (books/ai
   already exist) and the fresh-build bug would have surfaced only at the next
   overlay-replay. The smoke surfaced it now.

## The live deploy (one atomic apply, no data loss)

The running `stewards-oss-pg` holds real data (27 docs, 5 personas, live chat.ibeco.me
personas via persona-host). Deployed by extracting the two new fn defs from the proven
image (pg_get_functiondef) + the two new files + both overlays into one BEGIN/COMMIT
bundle, `ON_ERROR_STOP=1`, against the running DB — no container recreate. Verified
after: all 4 persona families still compose prompts (fiction now 9456 ch with the
storytelling summary), corpus map live, books↔ai cross-pollinate, persona-host
undisturbed. Rebaked `stewards-oss-pg:pg18` for future-boot parity.

## Carry-forward

- **Skills P1:** `stewards-cli import --source skill:` (the SKILL.md → registry path);
  retire-or-keep the one-shot `skill`/`load_skill_tool`; broaden the storytelling
  group's applies_to to `gamemaster` (the DM persona) — it's `fiction`-only now.
- **Corpus P1 (fast-follow):** a persona per pool (books-librarian, ai-analyst, reuse
  Vera's analyst family) + `request_research` for the loops (D6).
- **Backfill dup risk:** future digests pool under the work_item slug, not `book-*`/
  `yt-*` — minor near-dups possible; dedup later if it matters.
- **Watch:** next book-digest / playlist-digest tick on live should pool to its
  project automatically now (the decouple + the map + the fill trigger).

## Same-session follow-on — the reflect planner kept re-proposing (Michael's catch)

Triaging the live proposal queue, Michael saw the planner re-proposing work already
pending/done and asked to "tighten that up." Diagnosis: the council survey
(`intent_work_survey`) *already surfaced* the pending queue, but (a) it's a soft
prompt-only nudge cold-start models ignore, and (b) the only HARD dedup at enqueue
was exact-slug — useless against reworded re-proposals. Three tightenings (OSS
`91e58d0`, deployed live):

1. **Deterministic near-dup gate** — `binding_question_overlap` (Jaccard of
   significant words, singular/plural-folded, no extension dep) + a guard in
   `enqueue_proposed_work_items` that drops a proposed item overlapping an existing
   non-terminal proposal for the same intent `>= reflect_dedup_overlap_threshold`
   (config, **0.5** — chosen after hand-/live-checking that a realistic reworded
   pair scores ~0.5 and a distinct pair ~0.1; 0.6 would have missed the real dups).
   The "build the oracle" pattern: structural, not model goodwill.
2. **Fewer/deeper** — propose_work template `Maximum 5 → Maximum 3`, quality-over-
   coverage, with an explicit "the gate rejects reworded dups" contract.
3. **Planner sees the studies** — `intent_work_survey` gains `existing_studies`:
   the pooled docs (project + neighbors) with a gist each, so the planner reasons
   over what we KNOW, not just slugs. (11 studies surfaced for work-corpus.)

**Honest limit:** word-Jaccard is lexical, not semantic — it catches verbatim and
moderate rewordings but a heavily-reworded semantic dup can still slip; the enriched
survey + the fewer/deeper prompt + the review_plan gate cover those. True semantic
dedup (embedding cosine on binding_questions) is the future tool, but synchronous
embedding inside the enqueue trigger is the wrong place — deferred. Also approved one
proposal (`work-corpus-self-service-feature-proposals`) which **ran, verified, and pooled
autonomously** — live proof the corpus decouple works on a real run — then declined 8
redundant proposals (35→27).
