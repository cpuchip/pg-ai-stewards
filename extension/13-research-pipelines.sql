-- =====================================================================
-- 13-research-pipelines.sql — research / planning / agent-write-back
--   pipeline-family seeds and their apply functions.
--
-- Consolidates (authoring blueprint, batch B4):
--   h1-2  research-write pipeline (gather/synthesize/review)
--   h1-5b gather-template tighten        ┐ both superseded by h2's final
--   h1-7b research tool grants + template┘ context_gather / gather split
--   h2    context_gather stage  → research-write FINAL is 4 stages:
--                                 context_gather → gather → synthesize → review
--   h3-4  planning pipeline (5 stages)
--   h3-5  enqueue_proposed_work_items
--   h3-followup-3 revise-proposal pipeline + apply_revision
--   i4    agent-proposal pipeline + apply_agent_proposal base
--         + the agent_proposal_applied_at column
--   i6    schema-migration claude_attested gate   ┐ folded into the single
--   i7    apply_agent_proposal FINAL (direct       ┘ i7 form authored below
--         pending_file_writes queue; bypasses the i4 JSON-wrapper bug)
--   pe2   research-summary (daily-digest) pipeline
--
-- Dependency-correctness deviations from the blueprint's literal source
-- map (the forward-ref rule, same class as the B2/B3 deviations):
--
--   * h1-0 and h3-1 were already FULLY consumed before B4 — h1-0 at B3
--     (maturity_ladder → 08, sabbath/atonement overrides → 10); h3-1's
--     work_items columns (origin/project_association/parent_work_item_id
--     + the origin CHECK carrying agent_planning AND agent_proposal) are
--     born in 04, its docs columns in create_docs. Both are dropped from
--     this file's source list.
--
--   * h-ledger-1's stewards.schema_migrations table is migration
--     INFRASTRUCTURE, not a research pipeline. In the consolidated bundle
--     the runtime manifest starts empty, so the table must be born by
--     CREATE EXTENSION for the overlay tier (and going-forward core
--     hotfixes) to record into it. It moves to 00-config, not here.
--
--   * on_maturity_verified is NOT redefined here. It is authored once in
--     08-gates as a single final form that calls enqueue_proposed_work_items
--     (this file), apply_agent_proposal (this file), and the fan-out
--     aggregator (14-fanout) as WRAPPED forward refs — the 04/B3 precedent
--     (a wrapped function call to an object born later in the chain is a
--     safe CREATE-time forward ref; a SELECT-from-a-later-table is not).
--     08's single final form is updated at the close of B4 once 13's and
--     14's functions both exist.
--
--   * apply_agent_proposal is authored ONCE in its i7 final form (the
--     direct pending_file_writes queue, which also carries i6's
--     claude_attested gate). i4's base and i6's redefinition collapse into
--     it; i4's validate-stage prompt is seeded in the i6 form (the one that
--     documents the KIMI-TRUST GATE).
--
--   * work_item_dispatch_stage's per-stage tools_disabled forward
--     (h1-2 §H.1.3) is NOT authored here. That function accretes across
--     the chain (04 base → tools_disabled → fallback chain → spend caps →
--     capability gate → max-tokens) and is authored once in its final form
--     in 19-models (B5), where its last dependency (r3 max-tokens) lands.
--     04's base form holds until then; the pipeline seeds below still carry
--     each stage's tools_disabled flag in the stages jsonb.
--
-- Genericization (classification notes "genericize corpus-kind text"):
-- the scripture-study "gospel" corpus reference in the prior-work tool
-- descriptions is generalized, and the project-specific example names in
-- the planning propose_work example are neutralized. Model / provider
-- names (kimi-k2.6 / qwen3.6-plus / opencode_go) are kept as operator-data
-- references, consistent with 04's echo-test example seed: the seed pack
-- ships matching example agents/models/providers.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Feature columns this subsystem owns (work_items spine lives in 04).
-- ---------------------------------------------------------------------
ALTER TABLE stewards.work_items
    ADD COLUMN IF NOT EXISTS agent_proposal_applied_at timestamp with time zone,
    ADD COLUMN IF NOT EXISTS revision_applied_at       timestamp with time zone;

COMMENT ON COLUMN stewards.work_items.agent_proposal_applied_at IS
'i4/i7 (13-research-pipelines): set by apply_agent_proposal when an agent-proposal work_item has been persisted (docs row + pending_file_write queued). NULL = not yet persisted (or never an agent proposal). Idempotency guard.';
COMMENT ON COLUMN stewards.work_items.revision_applied_at IS
'h3-followup-3 (13-research-pipelines): set by apply_revision when a revise-proposal work_item has been merged into its parent proposal. NULL = not yet applied (or rejected). Idempotency guard.';

-- ---------------------------------------------------------------------
-- Research agent-family tool grants (h1-7b). The 'research' family is the
-- generic creative/research example agent the seed pack ships. These are
-- substrate-generic tools (filesystem-read, prior-work inspection); the
-- escalation WRITE tools are deliberately NOT granted (operator surface).
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('research', 'fs_read',              'allow', 'manual'),
  ('research', 'fs_list',              'allow', 'manual'),
  ('research', 'fs_search',            'allow', 'manual'),
  ('research', 'work_item_list',       'allow', 'manual'),
  ('research', 'work_item_show',       'allow', 'manual'),
  ('research', 'watchman_pass_show',   'allow', 'manual'),
  ('research', 'watchman_passes_list', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO NOTHING;

-- =====================================================================
-- research-write — deep-research pipeline (4 stages, h2 final form)
--   context_gather → gather → synthesize → review
-- =====================================================================
DO $seed$
DECLARE
    v_context_gather_template text;
    v_gather_template         text;
    v_synthesize_template     text;
    v_review_template         text;
    v_stages                  jsonb;
BEGIN

v_context_gather_template :=
$T$Binding question: {{input.binding_question}}

## YOUR TASK — situational awareness briefing

You are gathering context from the substrate's own knowledge — prior journals, proposals, mind files, docs, and work_items — to brief the next stage (the external-research gather stage) on what we already know about this binding question. Your output is NOT the final research piece. It is a *briefing* the next stage reads before doing external search.

## TOOLS

You have:
- `fs_search` (regex search across `.spec/journal/*`, `.spec/proposals/*`, `.mind/*`, `docs/**`)
- `fs_read` (read a file in full)
- `fs_list` (list files matching a glob)
- `doc_search` (the substrate's docs corpus — research, planning, and other studies)
- `doc_get` (read a doc by slug)
- `doc_similar` (related docs via embedding edges)
- `work_item_list` / `work_item_show` (prior work_items on this binding)

## HARD CONSTRAINTS

- **Maximum 4 rounds of tool calls.** Spend them on the most likely prior-work sources first (journals named for the topic; proposals; mind files like `.mind/active.md`, `.mind/principles.md`).
- **Output budget: ~2KB.** Summarize, don't transcribe. The gather stage reads your briefing in addition to its own template; keep it tight.
- **End-of-turn:** your final message is the briefing in markdown, then STOP.

## OUTPUT FORMAT — the briefing

```
## Prior context for: <one-line restatement of the binding question>

### What we already know
<2-4 bullets: the most relevant prior journals/proposals/docs and what they say>

### Gaps in our prior work
<2-3 bullets: what the prior work does NOT cover that the binding question needs>

### Suggested external-search angle for the next stage
<1-2 sentences: where the gather stage should focus its external search to fill the gaps>
```

If prior work is sparse or absent (e.g., this is a brand-new topic for us), say so explicitly — "We have no prior journals or proposals on X" — and the gather stage will know to start fresh externally.$T$;

v_gather_template :=
$T$Binding question: {{input.binding_question}}

## PRIOR CONTEXT (from context_gather stage)

{{stage_results.context_gather.output}}

## YOUR TASK

Given the prior context above, find external sources to fill the gaps and answer what prior work doesn't cover. Then **STOP**, produce the sources brief, and end your turn.

## HARD CONSTRAINTS

- **Maximum 8 strong sources** in the final brief. The prior context above counts as 0 of those — your job is the EXTERNAL sources.
- **Maximum 5 rounds of tool calls.** Cast wide early, narrow with `fetch_url` on high-value hits.
- **End-of-turn:** your final message is the sources brief in markdown. No further tool calls.

## TOOL GUIDANCE

You have `web_search_exa` (Exa neural search), `web_search` (DuckDuckGo), `news_search`, `fetch_url`, `fetch_urls`, `yt_search`, `yt_get`, and others. Use 1-2 search calls per round to cast wide; use `fetch_url` to read a specific high-value source. Parallel tool calls in one round = ONE round.

You can also still use `fs_*` and `doc_*` if the prior context surfaces a substrate document you want to read directly — but skip another full sweep; context_gather already did that.

## FOR EACH SOURCE YOU KEEP

- **Title** + **URL** + **publication date**
- **One-sentence summary** of what it adds (especially what prior context didn't already cover)
- **Short verbatim quote** (1-3 sentences) you might draw on in synthesis
- **Source type:** primary documentation / news reporting / opinion / vendor blog / academic / etc.
- **Credibility note:** primary source for this claim? secondary? recency vs domain half-life?

## OUTPUT FORMAT

Produce a markdown sources brief: a numbered list of up to 8 sources, each with the five fields above. **No prose intro. No prose outro.** Just the structured list. The synthesize stage drafts the actual research piece from your brief + the prior context.$T$;

v_synthesize_template :=
$T$Binding question: {{input.binding_question}}

Sources brief from the gather stage:

{{stage_results.gather.output}}

Now write the research piece. Draw on the sources collected in the gather stage. You MAY re-fetch any source via fetch_url if you need to re-read it; you SHOULD NOT introduce new sources here — that's a sign the gather stage was incomplete and would be better fixed by re-running gather.

Quote text VERBATIM only when you have the source text in front of you in this session. Paraphrase otherwise — "Vendor X says that..." is honest; an unverified direct quote is not.

Attribution: every non-trivial claim cites the source it came from. Use inline markdown links: [Source Title](https://url). Where a claim is your synthesis across multiple sources, say so explicitly.

Structure suggestion (adapt to what the binding question actually needs):
  - **Headlines** — the 3-5 most important findings that answer the binding question
  - **Notable** — second-tier findings worth knowing
  - **Skeptical takes** — credible dissenting voices, if any
  - **Open questions** — what the sources don't answer

Length: aim for 800-2500 words depending on topic depth. Resist the urge to pad. Honest uncertainty ("I couldn't find a credible source on X") is preferred over fabrication.

Produce the complete research piece in markdown. The next stage reviews it.$T$;

v_review_template :=
$T$Binding question: {{input.binding_question}}

The draft from the previous stage:

{{stage_results.synthesize.output}}

Review the draft against four criteria:

1. **Source credibility.** Every claim of fact has a citation. Citations point to credible sources (primary docs or established reporting, not random blog posts presented as fact). Where a claim is uncited or cited weakly, flag it.

2. **Recency.** Where the domain moves fast, sources are 2025-2026. Older sources are explicitly flagged or appropriate to a slow-moving domain.

3. **Binding question coverage.** Does the draft answer what was asked? If not, name what's missing.

4. **Honest uncertainty.** Where the sources don't support a strong claim, the draft says so. No fabricated certainty.

Tools are DISABLED for this stage. You CANNOT fetch URLs or re-search — your review must rest on the draft itself plus the sources it cites in-line. If a claim looks unverifiable from the draft alone, flag it as unverifiable rather than try to verify externally.

Return ONE of:
(a) The same draft, verbatim and unchanged, if it passes all four criteria. Prefix with a single line: "REVIEW: passes" then a blank line then the draft.
(b) A revised draft. Prefix with "REVIEW: revised" then a blank line, the revised draft, and at the end a brief notes section listing what changed and why.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object(
        'name', 'context_gather', 'next', 'gather',
        'model', 'qwen3.6-plus', 'provider', 'opencode_go',
        'agent_family', 'research', 'auto_advance', true,
        'tools_disabled', false, 'input_template', v_context_gather_template
    ),
    jsonb_build_object(
        'name', 'gather', 'next', 'synthesize',
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'research', 'auto_advance', true,
        'tools_disabled', false, 'input_template', v_gather_template
    ),
    jsonb_build_object(
        'name', 'synthesize', 'next', 'review',
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'research', 'auto_advance', true,
        'tools_disabled', false, 'input_template', v_synthesize_template
    ),
    jsonb_build_object(
        'name', 'review', 'next', NULL,
        'model', 'qwen3.6-plus', 'provider', 'opencode_go',
        'agent_family', 'research', 'auto_advance', true,
        'tools_disabled', true, 'input_template', v_review_template
    )
);

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'research-write',
    'Deep-research pipeline. context_gather reads prior substrate work, gather does external search, synthesize drafts the piece, review verifies it tools-off. Uses the research agent family. Materializes to research/<slug>.md on verified.',
    v_stages,
    true,   -- sabbath_enabled (research is creative; sabbath reflection is valuable)
    true,   -- atonement_enabled
    'research/<slug>.md',
    NULL,   -- file_content_jsonpath: whole final-stage output
    '["raw","researched","planned","specced","executing","verified"]'::jsonb,
    true    -- auto_materialize_on_verified (set since H.1.6.5)
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('research-write', 'context_gather', 'qwen3.6-plus', 'Prior-work briefing; structured, not creative.'),
    ('research-write', 'gather',         'kimi-k2.6',    'External-source gather; tools enabled (exa, web_search, fetch_url, yt_*).'),
    ('research-write', 'synthesize',     'kimi-k2.6',    'Draft synthesis from gather brief; tools enabled lightly (re-fetch only).'),
    ('research-write', 'review',         'qwen3.6-plus', 'Tools-disabled verification pass.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

-- context_gather does NOT advance maturity (no row → COALESCE leaves it).
-- research skips "executing": synthesize IS the draft.
INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('research-write', 'gather',     'researched', 'Sources collected + summarized; ready for synthesis.'),
    ('research-write', 'synthesize', 'planned',    'Draft is the plan. No separate executing rung.'),
    ('research-write', 'review',     'verified',   'Review pass complete; piece is verified.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

END $seed$;

-- =====================================================================
-- planning — exploratory binding question → plan doc + proposed work_items
--   context_gather → explore → synthesize → propose_work → review_plan
-- =====================================================================
DO $seed$
DECLARE
    v_context_gather_template text;
    v_explore_template        text;
    v_synthesize_template     text;
    v_propose_work_template   text;
    v_review_plan_template    text;
    v_stages                  jsonb;
BEGIN

v_context_gather_template :=
$T$Binding question: {{input.binding_question}}

## YOUR TASK — situational awareness briefing for planning

You are gathering context from the substrate's own knowledge — prior journals, proposals, mind files, docs, and work_items — to brief the next stage (the explore stage) on what we already know about this binding question. The next stage will think about what to PLAN; your job is to give it the lay of the land.

## TOOLS

- `fs_search` / `fs_read` / `fs_list` — substrate-scoped files (journals, proposals, mind, docs, and per-pipeline-scoped project dirs if available)
- `doc_search` / `doc_get` / `doc_similar` — the substrate's docs corpus
- `work_item_list` / `work_item_show` — prior work_items on this topic or in the same project
- `watchman_pass_show` / `watchman_passes_list` — substrate state

## HARD CONSTRAINTS

- **Maximum 4 rounds of tool calls.** Spend them on the highest-signal sources first: prior plans in `/plans/` or `/projects/<project>/plans/`, recent journal entries, proposals, work_items with same `project_association`.
- **Output budget: ~2KB.** Summarize, don't transcribe.
- **End-of-turn:** your final message is the briefing in markdown, then STOP.

## OUTPUT FORMAT

```
## Prior context for: <one-line restatement of the binding question>

### What we already know
<2-4 bullets — what we've planned/built/discussed before that bears on this>

### Constraints already established
<2-3 bullets — covenants, prior decisions, ratifications relevant here>

### Gaps / open questions in our prior thinking
<2-3 bullets — what's NOT been decided that this plan must decide>

### Suggested angle for the explore stage
<1-2 sentences — where should the next stage focus its thinking>
```

If prior work is sparse, say so. The explore stage will know to start fresh.$T$;

v_explore_template :=
$T$Binding question: {{input.binding_question}}

## PRIOR CONTEXT (from context_gather stage)

{{stage_results.context_gather.output}}

## YOUR TASK — think alongside the operator

You are the *planning-partner*. Your job is NOT to produce a research artifact. Your job is to explore the question, surface assumptions, identify risks, and converge toward one strong plan. Think the way the operator would think with unlimited focus right now.

Follow the **planning-partner** intent's values:
- **Surface assumptions first.** Before any recommendation, name what you're assuming. If you can't name them, you don't understand the problem yet.
- **Ask back when underspecified.** If the binding question doesn't give enough constraint to plan well, name what's missing and propose options. "What are you optimizing for?" is a valid first move — write that down, don't invent the answer.
- **Converge.** Don't list five branches. Pick one and commit (the operator can redirect after).
- **Name risks.** Every plan has things that could go wrong. Surface them now, not later.
- **Small finishable work.** Anything you'll later propose as a follow-up work_item must be ≤2hr of work.

## TOOLS

You have the full research suite: `fs_*`, `doc_*`, `work_item_*` on the substrate side; `web_search_exa`, `web_search`, `news_search`, `fetch_url`, `fetch_urls`, `yt_search`, `yt_get` on the external side. Use external search only when prior context doesn't cover something the plan needs.

## HARD CONSTRAINTS

- **Maximum 6 rounds of tool calls total.** Most of your value is in thinking, not searching.
- **End-of-turn:** your final message is a structured exploration in markdown (see format below), then STOP. The synthesize stage takes this and turns it into the plan.

## OUTPUT FORMAT — exploration brief

```
## Exploration: <one-line binding question>

### Assumptions
<3-5 bullets — what you're assuming. Each assumption a one-liner.>

### What you'd ask back (if anything)
<0-3 bullets — questions whose answers would shape the plan. Empty if the binding is well-specified.>

### The plan you're converging toward (one option)
<3-7 sentences — the core direction. Not five branches; one plan with sub-decisions.>

### Risks
<2-4 bullets — concrete things that could go wrong. Not generic; specific to this plan.>

### Tangents you considered but rejected
<1-3 bullets — why you didn't go with X, Y, Z. Names the road-not-taken so synthesize doesn't reopen them.>
```$T$;

v_synthesize_template :=
$T$Binding question: {{input.binding_question}}

## EXPLORATION (from previous stage)

{{stage_results.explore.output}}

## YOUR TASK — write the plan document

Convert the exploration brief above into a publishable plan document. The plan will land at `projects/<project>/plans/<slug>.md` (or `plans/<slug>.md` if no project). The operator reads it; future runs read it as prior context; the substrate keeps it as a doc artifact.

## HARD CONSTRAINTS

- **No external tools.** This stage is pure writing. The explore stage already gathered.
- **End-of-turn:** your final message IS the plan document. No prose-around-the-prose.

## VOICE

Concrete, direct, unadorned. One em-dash per paragraph max. *Therefore* / *but*, not "and then." No closing refrain. No meta-narration.

## OUTPUT FORMAT — the plan document

```markdown
# <Plan title — short, derived from binding question>

**Binding question:** <restate verbatim>

**Project:** <inherited from work_item.project_association, or "—" if standalone>

**Date:** {{input.today}}

---

## The plan

<3-6 paragraphs. The one-option plan you converged on in explore.
Concrete actions, not aspirations.>

## Assumptions

<bullets — copied from exploration; reframed if synthesis surfaced
something deeper. Each assumption phrased so a future reader knows
when it'd break.>

## Risks

<bullets — concrete failure modes; mitigation if obvious, else
"watch for X" framing.>

## Next steps

<short paragraph — what gets done first, second, third. Maps to
the proposed work_items the next stage will emit.>
```$T$;

v_propose_work_template :=
$T$Binding question: {{input.binding_question}}

## THE PLAN (from synthesize stage)

{{stage_results.synthesize.output}}

## YOUR TASK — emit proposed follow-up work_items

You are the *propose_work* stage. Your output is a **JSON array** of proposed follow-up work_items. NO prose. NO markdown fences around the JSON. Just the array.

The substrate's review_plan stage (next) will validate your JSON. If invalid, the substrate revises this stage. If valid, the substrate creates each item as a `work_items` row at `maturity='raw'` with `origin='agent_planning'` and `parent_work_item_id` pointing back at this planning run. The operator ratifies (advances maturity) before they actually fire.

## SCHEMA — every array element MUST have these keys

```json
{
  "slug":                 "kebab-case-identifier",
  "binding_question":     "The actual question this work answers (verbatim, complete sentence)",
  "pipeline_family_hint": "research-write" | "planning" | null,
  "rationale":            "One sentence — why this work is worth doing"
}
```

Optional keys (omit if not applicable):
- `"project_association"`: string — inherits from parent if omitted
- `"destination_maturity"`: "researched" | "planned" | "specced" | "executing" | "verified"

## HARD CONSTRAINTS

- **Output ONLY the JSON array.** No prose intro/outro. No markdown fences. Just `[ ... ]`.
- **Maximum 5 proposed work_items.** Quality over quantity. Pick the ones that matter.
- **Each work_item must be ≤2hr scope.** "Build the substrate" is not a work_item; "Add origin column to work_items" is.
- **slugs must be kebab-case** matching `^[a-z0-9-]+$`, prefixed with the parent slug or project where possible (e.g., `museum-exhibit-budget-q2`).
- **No external tools.** This stage is pure structured output.

## EXAMPLE

```json
[
  {
    "slug": "exhibit-wall-vendor-eval",
    "binding_question": "Which modular exhibit wall system (Flexhibit, CoMotion, or DIY) best fits a regional science center's 6-rotation-per-year cadence and a $50K capital budget?",
    "pipeline_family_hint": "research-write",
    "rationale": "The plan commits to a modular wall as foundation; vendor choice is the first concrete decision that gates everything else."
  },
  {
    "slug": "ai-exhibit-mvp-scope",
    "binding_question": "What's the minimum-viable AI-literacy exhibit we could build in 8 weeks with one staffer and ~$3K in materials?",
    "pipeline_family_hint": "planning",
    "rationale": "Plan identifies AI as the signature topic; need to scope a buildable MVP before fundraising or partnership talks."
  }
]
```

Your turn. Output ONLY the JSON array.$T$;

v_review_plan_template :=
$T$Binding question: {{input.binding_question}}

## THE PLAN (synthesize)

{{stage_results.synthesize.output}}

## PROPOSED WORK_ITEMS (propose_work — raw JSON)

{{stage_results.propose_work.output}}

## YOUR TASK — review the plan + the proposed work

You are the review_plan gate. Verify BOTH the plan document AND the JSON array of proposed work_items. Output a JSON verdict (schema below). The substrate uses this to decide: pass → verified maturity → trigger fires materialization + work_item proposals; revise → propose_work stage re-runs with your feedback.

## CHECKS — both must pass

### A. JSON validation (propose_work output)
- Output is a valid JSON array (no prose, no markdown fences)
- Length ≤ 5
- Every element has required keys: `slug`, `binding_question`, `pipeline_family_hint`, `rationale`
- `slug` matches `^[a-z0-9-]+$` and is unique within the array
- `binding_question` is a complete sentence ending in `?`
- `pipeline_family_hint` is one of: `"research-write"`, `"planning"`, or `null`
- `rationale` is a single sentence

### B. Plan quality (synthesize output)
- Assumptions are explicitly named (not implicit)
- At least one risk is concrete (not generic "things could go wrong")
- The plan converges on ONE direction (not five branches)
- "Next steps" section maps to the proposed work_items
- Proposed work_items are each ≤2hr scope (judge from the binding_question — "Build the substrate" = revise; "Add origin column" = ok)

## HARD CONSTRAINTS

- **No external tools.** Pure verification.
- **Output ONLY the JSON verdict.** No prose.

## OUTPUT FORMAT

```json
{
  "verdict": "pass" | "revise",
  "json_validation": {
    "valid": true | false,
    "issues": ["array of issue strings — empty if valid"]
  },
  "plan_quality": {
    "assumptions_surfaced": true | false,
    "risks_concrete": true | false,
    "converged_on_one_direction": true | false,
    "next_steps_map_to_proposed_work": true | false,
    "work_items_appropriately_sized": true | false,
    "issues": ["any concrete improvements needed"]
  },
  "feedback_for_revise": "If verdict=revise: one paragraph telling propose_work specifically what to fix. Empty if pass."
}
```$T$;

v_stages := jsonb_build_array(
    jsonb_build_object('name','context_gather','next','explore',
        'model','qwen3.6-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',false,'input_template',v_context_gather_template),
    jsonb_build_object('name','explore','next','synthesize',
        'model','kimi-k2.6','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',false,'input_template',v_explore_template),
    jsonb_build_object('name','synthesize','next','propose_work',
        'model','kimi-k2.6','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_synthesize_template),
    jsonb_build_object('name','propose_work','next','review_plan',
        'model','qwen3.6-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_propose_work_template),
    jsonb_build_object('name','review_plan','next',NULL,
        'model','qwen3.6-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_review_plan_template)
);

INSERT INTO stewards.pipelines (
    family, description, stages, metadata,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'planning',
    'Planning pipeline — converts an exploratory binding question into a plan document + a JSON array of proposed follow-up work_items. Uses the planning-partner intent. Plan materializes via auto_materialize_on_verified; proposed work_items materialize via the on_maturity_verified trigger (enqueue_proposed_work_items).',
    v_stages,
    jsonb_build_object(
        'cost_cap_default_micro', 750000,
        'cost_cap_default_dollars', 0.75,
        'note_cost_cap', 'UI/CLI should set work_items.cost_cap_micro=750000 as default when origin=human creates a planning work_item.'
    ),
    true,   -- sabbath_enabled
    true,   -- atonement_enabled
    'plans/<slug>.md',  -- fallback; compose_file_destination prefers projects/<project>/plans/<slug>.md
    NULL,   -- overridden below to stage_results.synthesize.output
    '["raw","researched","planned","specced","executing","verified"]'::jsonb,
    true    -- auto_materialize_on_verified
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    metadata                     = EXCLUDED.metadata,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

-- The plan document lives in stage_results.synthesize.output, not
-- review_plan.output (which is the verdict JSON).
UPDATE stewards.pipelines
   SET file_content_jsonpath = 'stage_results.synthesize.output'
 WHERE family = 'planning';

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity) VALUES
    ('planning', 'explore',     'researched'),
    ('planning', 'synthesize',  'planned'),
    ('planning', 'review_plan', 'verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model) VALUES
    ('planning', 'context_gather', 'qwen3.6-plus'),
    ('planning', 'explore',        'kimi-k2.6'),
    ('planning', 'synthesize',     'kimi-k2.6'),
    ('planning', 'propose_work',   'qwen3.6-plus'),
    ('planning', 'review_plan',    'qwen3.6-plus')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET default_model = EXCLUDED.default_model;

END $seed$;

-- =====================================================================
-- agent-proposal — agent submits a doc/schema-migration proposal for
--   human ratification. Single validate stage; apply_agent_proposal
--   persists on verified (i6 KIMI-TRUST GATE prompt + i7 apply form).
-- =====================================================================
DO $seed$
DECLARE
    v_validate_template text;
    v_stages            jsonb;
BEGIN

v_validate_template :=
$T$You are validating an agent-submitted proposal for a substrate artifact.

## AGENT DRAFT

```json
{{input.draft}}
```

## YOUR TASK

Read the draft. Validate and normalize it. Output ONLY a JSON object — no prose, no markdown fences.

## SCHEMA (output)

```json
{
  "source_type": "study | lesson | note | exhibit | schema-migration",
  "slug": "kebab-case-slug",
  "title": "Human-readable title (10-120 chars)",
  "body": "Full markdown body OR full SQL for schema-migration",
  "frontmatter": { /* per-source-type metadata; jsonb object */ },
  "project_association": "string slug or null",
  "rationale": "Why this proposal exists (1-3 sentences; shown in ratification UI)"
}
```

## VALIDATION RULES

- `source_type` MUST be one of: study, lesson, note, exhibit, schema-migration.
- `slug` MUST match `^[a-z0-9-]+$`. If the draft slug is malformed, fix it.
- `title` MUST be 10-120 chars. If too short, expand from body's first heading. If too long, trim.
- `body` MUST be non-empty.
- For `schema-migration`: `body` MUST start with `-- ` (SQL comment header) and contain at least one `CREATE`, `ALTER`, `INSERT`, or `CREATE OR REPLACE` statement.
- `frontmatter` MUST be a JSON object (use `{}` if no metadata).
- `project_association` is optional; pass through from draft or set null.
- `rationale` MUST be 20-500 chars. If missing, derive from body's intro.

## SCHEMA-MIGRATION CLAUDE-ATTEST GATE (i6)

For `source_type=schema-migration`, the substrate enforces a `claude_attested=true` gate at apply time: substrate-internal SQL stays Claude-only. The attestation lives on `input.draft.claude_attested` and is NOT promoted by this validate stage. Your output should preserve any draft.claude_attested value verbatim alongside the normalized fields, but the gate check reads from input.draft directly.

## ON ERROR

If the draft cannot be normalized into a valid proposal, output:
```json
{"error": "Brief reason"}
```

Output ONLY the JSON object. Your turn.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object('name','validate','next',NULL,
        'model','qwen3.6-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_validate_template)
);

INSERT INTO stewards.pipelines (
    family, description, stages, metadata,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'agent-proposal',
    'Agent submits a study/lesson/note/exhibit/schema-migration proposal. Single-stage validate pass normalizes the draft JSON. On verified, apply_agent_proposal persists to docs + queues the file write directly. The operator ratifies via the Proposed-work panel (origin filter agent_proposal). schema-migration source_type is Claude-only and lands at the extension dir as <slug>.sql.',
    v_stages,
    jsonb_build_object(
        'cost_cap_default_micro', 100000,
        'cost_cap_default_dollars', 0.10,
        'note', 'Single qwen validate pass; typical cost $0.005-0.01. apply_agent_proposal sets file_destination dynamically per source_type.'
    ),
    false,  -- sabbath_enabled
    false,  -- atonement_enabled
    NULL,   -- file_destination_template: dynamic via apply_agent_proposal
    'stage_results.validate.output',
    '["raw","verified"]'::jsonb,
    true    -- auto_materialize_on_verified
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    metadata                     = EXCLUDED.metadata,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity)
VALUES ('agent-proposal', 'validate', 'verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model)
VALUES ('agent-proposal', 'validate', 'qwen3.6-plus')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET default_model = EXCLUDED.default_model;

END $seed$;

-- =====================================================================
-- revise-proposal — AI revision of an existing proposed work_item.
--   Single revise stage; apply_revision merges into the parent on Accept.
-- =====================================================================
DO $seed$
DECLARE
    v_revise_template text;
    v_stages          jsonb;
BEGIN

v_revise_template :=
$T$You are revising a proposed work_item based on user feedback.

## ORIGINAL PROPOSAL (the work_item being revised)

- slug: {{input.original_slug}}
- binding_question: {{input.original_binding_question}}
- rationale: {{input.original_rationale}}
- pipeline_family_hint: {{input.original_pipeline_family_hint}}
- project_association: {{input.original_project_association}}

## PARENT PLANNING CONTEXT (excerpt)

{{input.parent_plan_excerpt}}

## USER FEEDBACK

{{input.feedback}}

## YOUR TASK — emit a JSON revision

Read the original + parent context + user feedback. Emit a JSON object with the REVISED fields. Only include fields you're changing — omit fields that stay the same. The substrate will merge your output into the original.

## SCHEMA

```json
{
  "binding_question":     "Revised question text (optional)",
  "rationale":            "Revised rationale, one sentence (optional)",
  "slug":                 "revised-kebab-case-slug (optional)",
  "pipeline_family_hint": "research-write | planning | null (optional)",
  "project_association":  "string or null (optional)"
}
```

## HARD CONSTRAINTS

- **Output ONLY the JSON object.** No prose intro/outro. No markdown fences.
- **Honor the user's feedback as the primary signal.** If they say "scope tighter," tighten. If they say "rephrase," rephrase. Don't second-guess.
- **Preserve fields the user didn't ask to change.** Omit them from your output.
- **slug regex: ^[a-z0-9-]+$** if you're changing it.
- **binding_question must be a complete question** ending in `?` and ≥20 chars.

## EXAMPLE

User feedback: "scope this tighter — just validate the laptop webcams, not the full ML stack"

Original binding_question: "Do all five repurposed laptops support Chrome kiosk mode and offline TensorFlow.js webcam inference without driver conflicts or privacy blocks?"

Revision:
```json
{
  "binding_question": "Do all five repurposed laptops have functional built-in webcams accessible to Chrome under a kiosk-mode user profile, ignoring ML stack validation for a later work_item?",
  "rationale": "Splits hardware compatibility from software validation so the cheaper hardware test runs first."
}
```

Your turn. Output ONLY the JSON.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object('name','revise','next',NULL,
        'model','qwen3.6-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_revise_template)
);

INSERT INTO stewards.pipelines (
    family, description, stages, metadata,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'revise-proposal',
    'AI revision of an existing proposed work_item. Reads the original + parent plan + user feedback; emits a JSON partial revision; the UI shows a diff card with Accept/Reject. parent_work_item_id MUST be set to the proposal being revised.',
    v_stages,
    jsonb_build_object(
        'cost_cap_default_micro', 100000,
        'cost_cap_default_dollars', 0.10,
        'note', 'Single stage, qwen3.6-plus, tools off; typical cost $0.02-0.05'
    ),
    false,  -- sabbath_enabled
    false,  -- atonement_enabled
    NULL,   -- file_destination_template: no file artifact
    'stage_results.revise.output',
    '["raw","verified"]'::jsonb,
    false   -- auto_materialize_on_verified: no file write
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    metadata                     = EXCLUDED.metadata,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity)
VALUES ('revise-proposal', 'revise', 'verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model)
VALUES ('revise-proposal', 'revise', 'qwen3.6-plus')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET default_model = EXCLUDED.default_model;

END $seed$;

-- =====================================================================
-- research-summary — daily-digest (lighter research-write; no sabbath)
--   gather → synthesize → review
-- =====================================================================
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder,
    auto_materialize_on_verified
)
VALUES (
    'research-summary',
    'Daily-digest pipeline — a 24-hour news scan, not a deep dive. Same agent + model shape as research-write with lighter templates and sabbath/atonement off. Materializes to study/daily-digest/<slug>.md on verified.',
    jsonb_build_array(
        jsonb_build_object(
            'name',            'gather',
            'next',            'synthesize',
            'model',           'kimi-k2.6',
            'provider',        'opencode_go',
            'agent_family',    'research',
            'auto_advance',    true,
            'tools_disabled',  false,
            'input_template',
                'Binding question: {{input.binding_question}}' || E'\n\n' ||
                'You are gathering items for a DAILY DIGEST that answers the binding question above. This is not a deep research piece — it is a 24-hour news scan.' || E'\n\n' ||
                'Use the tools available (web_search_exa, web_search, fetch_url, yt_*, etc.) to find 4-8 noteworthy items from the last 24 hours that bear on the binding question. Prefer primary sources (official announcements, vendor docs, the paper itself). Secondary reporting only when it adds context the primary source omits.' || E'\n\n' ||
                'For each item kept, capture:' || E'\n' ||
                '  - Title + URL + publication date/time' || E'\n' ||
                '  - One-sentence summary of what shipped or was reported' || E'\n' ||
                '  - A short verbatim quote (1-2 sentences) you might draw on in the synthesis' || E'\n' ||
                '  - Item type: official-release, news-reporting, vendor-blog, opinion-piece, social-media-thread' || E'\n\n' ||
                'The general-research intent applies — apply credibility-over-volume, skepticism-as-default, and surface-the-rhetoric. A loud headline is not evidence of a substantive change; flag rhetorical heat that isn''t backed by a concrete release or document.' || E'\n\n' ||
                'Recency is the whole point of a daily digest: items older than 48 hours need a strong justification to keep. If a story keeps trending on day 3, that itself is the news — note the trending arc, not the original event.' || E'\n\n' ||
                'Produce an items brief — a structured list of every item kept, with the four fields above. The next stage drafts the digest from this brief. Do NOT write the digest yet.'
        ),
        jsonb_build_object(
            'name',            'synthesize',
            'next',            'review',
            'model',           'kimi-k2.6',
            'provider',        'opencode_go',
            'agent_family',    'research',
            'auto_advance',    true,
            'tools_disabled',  false,
            'input_template',
                'Binding question: {{input.binding_question}}' || E'\n\n' ||
                'Items brief from the gather stage:' || E'\n\n' ||
                '{{stage_results.gather.output}}' || E'\n\n' ||
                'Now write the daily digest. Aim for 300-700 words total. This is a scan, not a deep dive — the reader will read it once and move on. If a single item warrants depth, name it and recommend a follow-up deep-research run rather than expanding inline.' || E'\n\n' ||
                'Attribution: every claim has an inline markdown link to the source it came from: [Title](URL). Paraphrase by default; quote verbatim only when you have the source text in front of you in this session.' || E'\n\n' ||
                'Structure (adapt to what the day actually produced):' || E'\n' ||
                '  - **Headlines** — the 1-3 most important items of the day, one short paragraph each' || E'\n' ||
                '  - **Notable** — second-tier items worth knowing, one-line each with link' || E'\n' ||
                '  - **Skeptical takes** — credible dissenting voices on any headline item, if any' || E'\n' ||
                '  - **Carry-forward** — what to watch for tomorrow; any deep-research candidates' || E'\n\n' ||
                'No filler. If a day produced nothing noteworthy, the digest can be three lines: "Slow news day. [link to the one minor thing]. Carry-forward: nothing." Honest emptiness beats manufactured importance.' || E'\n\n' ||
                'Produce the complete digest in markdown. The next stage reviews it.'
        ),
        jsonb_build_object(
            'name',            'review',
            'next',            NULL,
            'model',           'qwen3.6-plus',
            'provider',        'opencode_go',
            'agent_family',    'research',
            'auto_advance',    true,
            'tools_disabled',  true,
            'input_template',
                'Binding question: {{input.binding_question}}' || E'\n\n' ||
                'The digest draft from the previous stage:' || E'\n\n' ||
                '{{stage_results.synthesize.output}}' || E'\n\n' ||
                'Review the digest against four criteria:' || E'\n\n' ||
                '1. **Attribution.** Every claim has an inline link. No claims without a source. If a claim is the synthesizer''s own observation, it is named as such ("These three releases together suggest...") rather than presented as reporting.' || E'\n\n' ||
                '2. **Recency.** Every item is from within the last 24-48 hours, OR the item is explicitly framed as a "still trending" follow-up to an older event.' || E'\n\n' ||
                '3. **Rhetorical inflation.** No headline manufactured from minor news. No urgency that isn''t in the underlying source. Flag any item where the digest''s framing is hotter than the source''s.' || E'\n\n' ||
                '4. **Honest emptiness.** If the day was slow, the digest says so. No padding.' || E'\n\n' ||
                'Tools are DISABLED for this stage. You CANNOT fetch URLs — review on the digest text + its in-line links only.' || E'\n\n' ||
                'Return ONE of:' || E'\n' ||
                '(a) The same digest, verbatim and unchanged, if it passes all four criteria. Prefix with a single line: "REVIEW: passes" then a blank line then the digest.' || E'\n' ||
                '(b) A revised digest. Prefix with "REVIEW: revised" then a blank line, the revised digest, and at the end a brief notes section listing what changed and why.'
        )
    ),
    false,  -- sabbath_enabled: daily-digest is transient
    false,  -- atonement_enabled
    'study/daily-digest/<slug>.md',
    NULL,
    '["raw","researched","planned","specced","executing","verified"]'::jsonb,
    true    -- auto_materialize_on_verified
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('research-summary', 'gather',     'kimi-k2.6',    'Daily-digest source gather; tools enabled. 24-hour scan.'),
    ('research-summary', 'synthesize', 'kimi-k2.6',    'Daily-digest synthesis from gather brief; 300-700 word target.'),
    ('research-summary', 'review',     'qwen3.6-plus', 'Tools-disabled verification pass.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('research-summary', 'gather',     'researched', 'Items collected + summarized; ready for synthesis.'),
    ('research-summary', 'synthesize', 'planned',    'Draft is the plan. No separate executing rung.'),
    ('research-summary', 'review',     'verified',   'Review pass complete; digest is verified and auto-materializes.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

-- =====================================================================
-- enqueue_proposed_work_items (h3-5) — called by 08's on_maturity_verified
-- planning branch (wrapped forward ref). Reads a planning work_item's
-- propose_work.output JSON array; inserts each proposed work_item.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.enqueue_proposed_work_items(p_work_item_id uuid)
RETURNS int
LANGUAGE plpgsql
AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_raw_output      text;
    v_clean_output    text;
    v_json            jsonb;
    v_item            jsonb;
    v_slug            text;
    v_binding         text;
    v_rationale       text;
    v_hint            text;
    v_project         text;
    v_dest_maturity   text;
    v_target_pipeline text;
    v_first_stage     text;
    v_inserted        int := 0;
    v_skipped         int := 0;
    v_reason          text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE NOTICE 'enqueue_proposed_work_items: work_item % not found', p_work_item_id;
        RETURN 0;
    END IF;

    -- Only planning-family work_items emit proposed work.
    IF v_wi.pipeline_family <> 'planning' THEN
        RETURN 0;
    END IF;

    v_raw_output := (v_wi.stage_results -> 'propose_work' -> 'output') #>> '{}';
    IF v_raw_output IS NULL OR length(trim(v_raw_output)) = 0 THEN
        RAISE NOTICE 'enqueue_proposed_work_items: empty propose_work.output for work_item %', p_work_item_id;
        RETURN 0;
    END IF;

    -- Strip optional markdown code fences.
    v_clean_output := regexp_replace(
        v_raw_output,
        E'^\\s*```(?:json)?\\s*\\n?|\\n?```\\s*$',
        '',
        'g'
    );
    v_clean_output := trim(v_clean_output);

    BEGIN
        v_json := v_clean_output::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'enqueue_proposed_work_items: JSON parse failed for work_item %: %', p_work_item_id, SQLERRM;
        RETURN 0;
    END;

    IF jsonb_typeof(v_json) <> 'array' THEN
        RAISE NOTICE 'enqueue_proposed_work_items: top-level JSON is %, expected array (work_item %)',
            jsonb_typeof(v_json), p_work_item_id;
        RETURN 0;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_json)
    LOOP
        v_reason := NULL;

        v_slug      := v_item ->> 'slug';
        v_binding   := v_item ->> 'binding_question';
        v_rationale := v_item ->> 'rationale';
        v_hint      := v_item ->> 'pipeline_family_hint';

        IF v_slug IS NULL OR v_slug !~ '^[a-z0-9-]+$' THEN
            v_reason := format('invalid slug: %s', COALESCE(v_slug, '(null)'));
        ELSIF v_binding IS NULL OR length(trim(v_binding)) < 20 THEN
            v_reason := format('binding_question too short or missing for slug=%s (need ≥20 chars)', v_slug);
        ELSIF v_rationale IS NULL OR length(trim(v_rationale)) < 10 THEN
            v_reason := format('rationale missing or too short for slug=%s (need ≥10 chars)', v_slug);
        END IF;

        v_project       := COALESCE(v_item ->> 'project_association', v_wi.project_association);
        v_dest_maturity := v_item ->> 'destination_maturity';

        v_target_pipeline := NULL;
        v_first_stage := NULL;
        IF v_hint IS NOT NULL AND v_hint <> '' AND v_hint <> 'null' THEN
            IF EXISTS (SELECT 1 FROM stewards.pipelines WHERE family = v_hint) THEN
                v_target_pipeline := v_hint;
                v_first_stage := stewards.pipeline_first_stage_name(v_hint);
            ELSE
                RAISE NOTICE 'enqueue_proposed_work_items: unknown pipeline_family_hint=% for slug=%; inserting as proposal-only',
                    v_hint, v_slug;
            END IF;
        END IF;

        IF v_reason IS NOT NULL THEN
            RAISE NOTICE 'enqueue_proposed_work_items: skipping element: %', v_reason;
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        IF EXISTS (SELECT 1 FROM stewards.work_items WHERE slug = v_slug) THEN
            RAISE NOTICE 'enqueue_proposed_work_items: slug=% already exists, skipping', v_slug;
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        -- If no target pipeline resolved, park under planning with a
        -- non-dispatchable stage so it shows in the UI but can't run.
        IF v_target_pipeline IS NULL THEN
            v_target_pipeline := 'planning';
            v_first_stage     := '__proposal_only';
        END IF;

        INSERT INTO stewards.work_items (
            slug, pipeline_family, current_stage, input, actor,
            intent_id, origin, parent_work_item_id, project_association,
            destination_maturity
        )
        VALUES (
            v_slug, v_target_pipeline, v_first_stage,
            jsonb_build_object(
                'binding_question', v_binding,
                'rationale_from_planning', v_rationale,
                'proposed_by_work_item_id', v_wi.id::text,
                'proposed_by_slug', v_wi.slug,
                'today', to_char(current_date, 'YYYY-MM-DD')
            ),
            'agent',
            v_wi.intent_id,   -- inherit; operator can swap at ratification
            'agent_planning',
            v_wi.id,
            v_project,
            v_dest_maturity
        );

        v_inserted := v_inserted + 1;
    END LOOP;

    RAISE NOTICE 'enqueue_proposed_work_items: work_item=% inserted=% skipped=%',
        p_work_item_id, v_inserted, v_skipped;
    RETURN v_inserted;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_proposed_work_items(uuid) IS
'h3-5 (13-research-pipelines): reads a planning work_item''s stage_results.propose_work.output JSON array and inserts each proposed work_item with origin=agent_planning, parent_work_item_id pointing back, and intent inherited. Malformed elements are skipped with NOTICE (not raised) so the calling trigger remains non-throwing. Called by on_maturity_verified''s planning branch (08, wrapped).';

-- =====================================================================
-- apply_agent_proposal (i7 final — incl. i6 claude_attested gate).
-- Queues pending_file_writes DIRECTLY with the validated body as content
-- (bypassing extract_work_item_file_content, which would return the JSON
-- wrapper), sets file_enqueued_at so on_maturity_verified's enqueue path
-- is a no-op. Scoped to the agent-proposal pipeline. Called by 08's
-- on_maturity_verified agent-proposal branch (wrapped forward ref).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.apply_agent_proposal(p_work_item_id uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_raw         text;
    v_clean       text;
    v_json        jsonb;
    v_source_type text;
    v_slug        text;
    v_title       text;
    v_body        text;
    v_frontmatter jsonb;
    v_project     text;
    v_rationale   text;
    v_file_dest   text;
    v_existing_id text;
    v_claude_attested boolean;
    v_pwid        bigint;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE NOTICE 'apply_agent_proposal: work_item % not found', p_work_item_id;
        RETURN false;
    END IF;
    IF v_wi.pipeline_family <> 'agent-proposal' THEN
        RAISE NOTICE 'apply_agent_proposal: work_item % is not agent-proposal (family=%)',
            p_work_item_id, v_wi.pipeline_family;
        RETURN false;
    END IF;
    IF v_wi.agent_proposal_applied_at IS NOT NULL THEN
        RAISE NOTICE 'apply_agent_proposal: already applied at %', v_wi.agent_proposal_applied_at;
        RETURN false;
    END IF;

    v_raw := (v_wi.stage_results -> 'validate' -> 'output') #>> '{}';
    IF v_raw IS NULL OR length(trim(v_raw)) = 0 THEN
        RAISE NOTICE 'apply_agent_proposal: validate.output is empty';
        RETURN false;
    END IF;

    v_clean := regexp_replace(v_raw, E'^\\s*```(?:json)?\\s*\\n?|\\n?```\\s*$', '', 'g');
    v_clean := trim(v_clean);

    BEGIN
        v_json := v_clean::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'apply_agent_proposal: JSON parse failed: %', SQLERRM;
        RETURN false;
    END;

    IF v_json ? 'error' THEN
        RAISE NOTICE 'apply_agent_proposal: validator returned error: %', v_json->>'error';
        RETURN false;
    END IF;

    v_source_type := v_json ->> 'source_type';
    v_slug        := v_json ->> 'slug';
    v_title       := v_json ->> 'title';
    v_body        := v_json ->> 'body';
    v_frontmatter := COALESCE(v_json -> 'frontmatter', '{}'::jsonb);
    v_project     := v_json ->> 'project_association';
    v_rationale   := v_json ->> 'rationale';

    IF v_source_type IS NULL OR v_source_type NOT IN ('study','lesson','note','exhibit','schema-migration') THEN
        RAISE NOTICE 'apply_agent_proposal: invalid source_type %', v_source_type;
        RETURN false;
    END IF;
    IF v_slug IS NULL OR v_slug !~ '^[a-z0-9-]+$' THEN
        RAISE NOTICE 'apply_agent_proposal: invalid slug %', v_slug;
        RETURN false;
    END IF;
    IF v_title IS NULL OR length(v_title) < 10 OR length(v_title) > 120 THEN
        RAISE NOTICE 'apply_agent_proposal: invalid title length: %', coalesce(length(v_title), 0);
        RETURN false;
    END IF;
    IF v_body IS NULL OR length(trim(v_body)) = 0 THEN
        RAISE NOTICE 'apply_agent_proposal: empty body';
        RETURN false;
    END IF;

    -- i6: schema-migration claude_attested gate (reads input.draft directly;
    -- the validate stage cannot promote attestation).
    IF v_source_type = 'schema-migration' THEN
        v_claude_attested := COALESCE(
            (v_wi.input -> 'draft' ->> 'claude_attested')::boolean,
            false
        );
        IF v_claude_attested <> true THEN
            RAISE NOTICE 'apply_agent_proposal: schema-migration requires input.draft.claude_attested=true (substrate-internal SQL stays Claude-only); got %',
                v_wi.input -> 'draft' ->> 'claude_attested';
            RETURN false;
        END IF;
    END IF;

    v_file_dest := CASE v_source_type
        WHEN 'study'            THEN 'study/' || v_slug || '.md'
        WHEN 'lesson'           THEN 'lessons/' || v_slug || '.md'
        WHEN 'note'             THEN 'becoming/notes/' || v_slug || '.md'
        WHEN 'exhibit'          THEN 'exhibits/' || v_slug || '.md'
        WHEN 'schema-migration' THEN 'projects/pg-ai-stewards/extension/' || v_slug || '.sql'
    END;

    IF v_source_type IN ('study','lesson','note','exhibit') THEN
        SELECT id INTO v_existing_id
          FROM stewards.docs
         WHERE kind = v_source_type AND slug = v_slug
         LIMIT 1;
        IF v_existing_id IS NOT NULL THEN
            RAISE NOTICE 'apply_agent_proposal: (kind=%, slug=%) already exists as doc id=%',
                v_source_type, v_slug, v_existing_id;
            RETURN false;
        END IF;

        v_frontmatter := v_frontmatter
                      || jsonb_build_object(
                            'source_type', v_source_type,
                            'origin', 'agent_proposal',
                            'proposed_by_work_item_id', p_work_item_id::text,
                            'rationale', v_rationale
                         );

        INSERT INTO stewards.docs (slug, title, body, kind, frontmatter, project_association, file_path)
        VALUES (v_slug, v_title, v_body, v_source_type, v_frontmatter, v_project, v_file_dest);

    ELSIF v_source_type = 'schema-migration' THEN
        RAISE NOTICE 'apply_agent_proposal: schema-migration; queueing file at %', v_file_dest;
    END IF;

    -- i7: queue pending_file_writes DIRECTLY with the body as content,
    -- bypassing enqueue_work_item_file's extract (which would return the
    -- full JSON wrapper).
    INSERT INTO stewards.pending_file_writes
        (requested_by, target_path, write_mode, content, source_id, source_kind)
    VALUES
        ('apply_agent_proposal', v_file_dest, 'create', v_body,
         p_work_item_id::text, 'work_item')
    RETURNING id INTO v_pwid;

    -- Set file_destination AND file_enqueued_at so on_maturity_verified's
    -- subsequent enqueue path becomes a no-op (its guard is file_enqueued_at IS NULL).
    UPDATE stewards.work_items
       SET file_destination          = v_file_dest,
           file_enqueued_at          = now(),
           agent_proposal_applied_at = now(),
           updated_at                = now()
     WHERE id = p_work_item_id;

    RAISE NOTICE 'apply_agent_proposal: persisted source_type=% slug=% body_len=% pwid=% file_dest=%',
        v_source_type, v_slug, length(v_body), v_pwid, v_file_dest;
    RETURN true;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_agent_proposal(uuid) IS
'i4/i6/i7 (13-research-pipelines): persists a verified agent-proposal work_item. Parses stage_results.validate.output, validates schema + the i6 claude_attested gate (schema-migration), INSERTs into docs for study/lesson/note/exhibit, then queues pending_file_writes DIRECTLY with the validated body as content (i7 — bypasses the JSON-wrapper bug) and sets file_enqueued_at so the subsequent on_maturity_verified enqueue path is a no-op. Idempotent via agent_proposal_applied_at. Called by on_maturity_verified''s agent-proposal branch (08, wrapped).';

-- =====================================================================
-- apply_revision (h3-followup-3) — merge a completed revise-proposal
-- work_item into its parent (the original proposal). UI-invoked.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.apply_revision(p_revise_work_item_id uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $func$
DECLARE
    v_revise   stewards.work_items%ROWTYPE;
    v_original stewards.work_items%ROWTYPE;
    v_raw      text;
    v_clean    text;
    v_json     jsonb;
    v_new_slug text;
    v_new_binding text;
    v_new_rationale text;
    v_new_hint text;
    v_new_project text;
BEGIN
    SELECT * INTO v_revise FROM stewards.work_items WHERE id = p_revise_work_item_id;
    IF v_revise.id IS NULL THEN
        RAISE NOTICE 'apply_revision: revise work_item % not found', p_revise_work_item_id;
        RETURN false;
    END IF;
    IF v_revise.pipeline_family <> 'revise-proposal' THEN
        RAISE NOTICE 'apply_revision: work_item % is not a revise-proposal (family=%)',
            p_revise_work_item_id, v_revise.pipeline_family;
        RETURN false;
    END IF;
    IF v_revise.revision_applied_at IS NOT NULL THEN
        RAISE NOTICE 'apply_revision: revision already applied at %', v_revise.revision_applied_at;
        RETURN false;
    END IF;
    IF v_revise.status = 'cancelled' THEN
        RAISE NOTICE 'apply_revision: revision was rejected (status=cancelled)';
        RETURN false;
    END IF;
    IF v_revise.parent_work_item_id IS NULL THEN
        RAISE NOTICE 'apply_revision: revision % has no parent_work_item_id', p_revise_work_item_id;
        RETURN false;
    END IF;

    SELECT * INTO v_original FROM stewards.work_items WHERE id = v_revise.parent_work_item_id;
    IF v_original.id IS NULL THEN
        RAISE NOTICE 'apply_revision: parent (original) work_item % not found', v_revise.parent_work_item_id;
        RETURN false;
    END IF;

    v_raw := (v_revise.stage_results -> 'revise' -> 'output') #>> '{}';
    IF v_raw IS NULL OR length(trim(v_raw)) = 0 THEN
        RAISE NOTICE 'apply_revision: revise.output is empty';
        RETURN false;
    END IF;

    v_clean := regexp_replace(v_raw, E'^\\s*```(?:json)?\\s*\\n?|\\n?```\\s*$', '', 'g');
    v_clean := trim(v_clean);

    BEGIN
        v_json := v_clean::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'apply_revision: JSON parse failed: %', SQLERRM;
        RETURN false;
    END;

    v_new_slug      := v_json ->> 'slug';
    v_new_binding   := v_json ->> 'binding_question';
    v_new_rationale := v_json ->> 'rationale';
    v_new_hint      := v_json ->> 'pipeline_family_hint';
    v_new_project   := v_json ->> 'project_association';

    IF v_new_slug IS NOT NULL THEN
        IF v_new_slug !~ '^[a-z0-9-]+$' THEN
            RAISE NOTICE 'apply_revision: invalid slug %', v_new_slug;
            RETURN false;
        END IF;
        IF EXISTS (
            SELECT 1 FROM stewards.work_items
             WHERE slug = v_new_slug AND id <> v_original.id
        ) THEN
            RAISE NOTICE 'apply_revision: slug % already in use', v_new_slug;
            RETURN false;
        END IF;
    END IF;
    IF v_new_binding IS NOT NULL AND length(trim(v_new_binding)) < 20 THEN
        RAISE NOTICE 'apply_revision: binding_question too short';
        RETURN false;
    END IF;

    -- "null" string = explicit clear-hint.
    IF v_new_hint IS NOT NULL AND v_new_hint = 'null' THEN
        v_new_hint := NULL;
    END IF;

    UPDATE stewards.work_items
       SET slug            = COALESCE(v_new_slug, slug),
           input           = input
                          || COALESCE(
                               CASE WHEN v_new_binding IS NOT NULL
                                    THEN jsonb_build_object('binding_question', v_new_binding)
                                    ELSE NULL END,
                               '{}'::jsonb)
                          || COALESCE(
                               CASE WHEN v_new_rationale IS NOT NULL
                                    THEN jsonb_build_object('rationale_from_planning', v_new_rationale)
                                    ELSE NULL END,
                               '{}'::jsonb),
           pipeline_family = CASE
                                WHEN v_new_hint IS NOT NULL AND EXISTS (
                                    SELECT 1 FROM stewards.pipelines WHERE family = v_new_hint
                                ) THEN v_new_hint
                                ELSE pipeline_family
                             END,
           current_stage   = CASE
                                WHEN v_new_hint IS NOT NULL AND EXISTS (
                                    SELECT 1 FROM stewards.pipelines WHERE family = v_new_hint
                                ) THEN stewards.pipeline_first_stage_name(v_new_hint)
                                ELSE current_stage
                             END,
           project_association = CASE
                                    WHEN v_json ? 'project_association'
                                        THEN v_new_project
                                    ELSE project_association
                                END,
           updated_at      = now()
     WHERE id = v_original.id;

    UPDATE stewards.work_items
       SET revision_applied_at = now(),
           updated_at = now()
     WHERE id = p_revise_work_item_id;

    RAISE NOTICE 'apply_revision: applied revision % to original %',
        p_revise_work_item_id, v_original.id;
    RETURN true;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_revision(uuid) IS
'h3-followup-3 (13-research-pipelines): applies a completed revise-proposal work_item to its parent (the original proposal). Validates schema, UPDATEs the original with non-null revision fields (COALESCE preserves unchanged values), marks the revise work_item with revision_applied_at. Idempotent — re-call after applied returns false.';
