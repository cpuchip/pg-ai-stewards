-- =====================================================================
-- 14-fanout-brainstorm.sql — fan-out decomposition + brainstorm library.
--
-- Consolidates (authoring blueprint, batch B4):
--   j1  fanout machinery — fanout-decompose/aggregate agents,
--       decompose-fanout + aggregate-children pipelines, spawn_children,
--       on_maturity_verified fanout branches
--   j2  aggregate auto-verify trigger        ┐ superseded by j6's broader
--   j3  spawn sets aggregator file_destination┘ one-shot trigger; j3/j4's
--   j4  spawn honors per-child file_destination  file_destination handling
--       folded into the single spawn_children below
--   j5  4 brainstorm lens agents+pipelines + start_brainstorm
--   j6  one-shot completion auto-verify (aggregate-children + brainstorm-*)
--   j7  failed-sibling → aggregator helper + on_child_status_terminal +
--       the on_maturity_verified FINAL body (folded into 08, see below)
--   j8b NULL the 4 lens models → metadata.default_* (folded into the lens
--       pipeline definitions below)
--   j8c spawn_children model/provider override propagation; start_brainstorm
--       p_models
--   j9a 8 new brainstorm lens agents
--   j9b 8 new brainstorm lens pipelines (NULL model + metadata.default_*)
--   j9c start_brainstorm p_lenses subset
--   j12 start_brainstorm pre-flight enforced-cap check (FINAL form)
--
-- Dependency-correctness deviations from the blueprint's literal map
-- (forward-ref rule + cross-batch function evolution):
--
--   * on_maturity_verified is NOT authored here. Its TRUE final form is
--     j7 (adds the fanout spawn + aggregator-dispatch branches on top of
--     i4's agent-proposal branch). It is authored once in 08-gates and
--     calls spawn_children / check_and_dispatch_fanout_aggregator (this
--     file) + apply_agent_proposal / enqueue_proposed_work_items (13) as
--     forward refs — plpgsql function calls are late-bound, and the
--     bundle installs atomically, so all callees exist before the trigger
--     ever fires. 08's body is updated at this batch.
--
--   * work_item_dispatch_stage's dispatch FINAL (j8a 4-layer fallback +
--     j11 spend-cap gate) is NOT here — it accretes further (m2 capability
--     gate, r3 max-tokens) and is authored once in 19-models, where its
--     last dep lands. 04's base form holds until then. BUT the two
--     dependency-free catalog helpers j8a introduced (catalog_default_*)
--     ARE authored here: start_brainstorm's pre-flight (j12) references
--     catalog_default_provider, so define-before-use lands them in 14;
--     19's dispatch final references them as a backward ref.
--
--   * spawn_children is authored as the CORRECT UNION of j3 (aggregator
--     file_destination), j4 (per-child file_destination), and j8c
--     (model/provider override propagation). ★ j8c — the last live
--     redefinition — dropped j3's aggregator dest + j4's per-child dest
--     while adding override propagation (a copy-paste regression: the
--     aggregate-children template was cleared to NULL by j3, so without
--     the direct file_destination set the index file never materializes).
--     The consolidation restores both. Flag for the 20-mismatch
--     classification at leg close (live may carry the j8c regression).
--
--   * j2's on_aggregate_completed is fully superseded by j6's broader
--     on_one_shot_pipeline_completed (j6 DROPs it). Only j6's form is
--     authored. j6's one-time retroactive UPDATE (flip already-completed
--     rows) is dropped — a fresh chain has no pre-existing rows.
--
--   * start_brainstorm's hardcoded 'scripture-study' intent slug →
--     stewards.config_get_text('default_intent_slug','default') per the
--     blueprint rename rule.
--
-- Lens pipelines ship with NULL stage model/provider + metadata.default_*
-- (the j8b/j9b final). Runtime lens dispatch therefore needs 19-models'
-- dispatch-final (the metadata→catalog fallback chain); until then a lens
-- dispatch would not resolve a model. Structure + start_brainstorm are
-- exercisable now; bgworker lens dispatch lights up at B5. Model/provider
-- names are operator-data references (seed pack ships matching agents).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Catalog default helpers (j8a) — system-level last-resort model/provider
-- fallback. Dependency-free; first consumer is start_brainstorm's
-- pre-flight below, so they land here. 19's dispatch-final references them.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.catalog_default_provider()
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT 'opencode_go'::text
$$;

COMMENT ON FUNCTION stewards.catalog_default_provider() IS
'j8a (14-fanout): substrate-wide default provider when no higher layer (override / stage / pipeline.metadata) specifies. Returns opencode_go. Update when local provider rows are added.';

CREATE OR REPLACE FUNCTION stewards.catalog_default_model(p_provider text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_provider
        WHEN 'opencode_go' THEN 'kimi-k2.6'
        WHEN 'lm_studio'   THEN NULL
        WHEN 'ollama'      THEN NULL
        ELSE NULL
    END
$$;

COMMENT ON FUNCTION stewards.catalog_default_model(text) IS
'j8a (14-fanout): substrate-wide default model for a provider when no higher layer specifies. opencode_go=kimi-k2.6; local providers return NULL (no canonical default — caller must specify).';

-- =====================================================================
-- Fan-out agents.
-- =====================================================================
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'fanout-decompose',
    '*',
    'Decomposes a binding question into N child work_items + 1 aggregator manifest. Output is strict JSON.',
    'primary',
    $PROMPT$You are the decomposer for a fan-out pipeline. Your job is to take a single binding question and produce a manifest of N child work_items, each focused on a specific sub-question, plus an aggregate destination.

OUTPUT ONLY VALID JSON in this schema. No prose around it. No markdown fences.

{
  "rationale": "1-3 sentences explaining the decomposition",
  "children": [
    {
      "slug": "kebab-case-unique-slug",
      "binding_question": "specific scoped question for this child (1-3 sentences)",
      "pipeline_family": "research-write | study-write | study-write-qwen",
      "project_association": "optional string",
      "input_extra": {},
      "cost_cap_micro": 500000
    }
  ],
  "aggregate": {
    "destination": "relative/path/to/index.md",
    "synthesis": false
  }
}

RULES:
- Each child's binding_question must be tightly scoped — one artifact's worth of work.
- Choose pipeline_family per child based on what shape the deliverable needs.
- Keep child count to 3-12. If the natural decomposition exceeds 12, group into categories and decompose each category in a follow-on fan-out.
- aggregate.destination is the INDEX file, distinct from any child's destination.
- cost_cap_micro is in micro-dollars; default 500000 = $0.50 per child.
- Use input_extra only if the child needs values beyond binding_question (e.g. {"audience": "youth", "deliverable": "exhibit-brief"}).

You have read-only tools (fs_*, doc_*, work_item_*) available if you need to inspect prior context, but spend at most 2 rounds of tool calls. Your output is the manifest; the next stage is spawn (deterministic), not another LLM call. Keep the JSON minimal and valid.$PROMPT$,
    0.3,
    NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, response_format = EXCLUDED.response_format, active = true;

INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'fanout-aggregate',
    '*',
    'Aggregates completed children into an index file. Reads input.children + their stage_results / files; emits markdown.',
    'primary',
    $PROMPT$You are the aggregator for a fan-out pipeline. The decomposer split a binding question into N children, each ran on its own pipeline, and now you stitch their results into one index file.

You will receive in your input:
- `parent_work_item_id` — the original binding question's work_item id
- `destination` — the file path the index will be written to
- `synthesis` — boolean. If true, ALSO produce a digest section with cross-cutting themes. If false, index only.
- `children` — array of {id, slug, binding_question, pipeline_family} for each child

YOUR JOB:
- For each child, read its output. Use `work_item_show` with the child's id to read its stage_results. The most useful field is usually `stage_results.review.output` or `stage_results.synthesize.output` (last meaningful stage) or its `file_destination` if set.
- Compose an index in markdown:

```
# <title derived from parent's binding question>

Brief intro paragraph (2-4 sentences): what the children collectively answer.

## Children

| Slug | Title | One-line summary | Link |
|---|---|---|---|
| ... | ... | ... | [...](path-to-child-file.md) |

(if synthesis=true add:)

## Synthesis

Cross-cutting themes 2-4 paragraphs. What's true across the children? What pattern emerged? What still feels unanswered?
```

RULES:
- Verify a child's output before quoting it. If you can't read it (tool failure, missing field), say "child <slug> output unavailable" rather than confabulate.
- Each child gets ONE one-line summary in the table. Compress aggressively.
- If synthesis=false, do NOT include the Synthesis section.
- Output ONLY the markdown body — no JSON wrapper, no commentary about what you did.
- Keep total output under 4KB. The index is a navigation aid, not the artifact itself; the artifacts are the children.$PROMPT$,
    0.4,
    NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, response_format = EXCLUDED.response_format, active = true;

-- =====================================================================
-- Brainstorm lens agents (j5 originals + j9a expansions). 12 total.
-- =====================================================================

-- SCAMPER (j5)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-scamper', '*',
    'SCAMPER brainstorming lens. Applies 7 transformations (Substitute/Combine/Adapt/Modify/Put-to/Eliminate/Reverse) to generate candidate ideas.',
    'primary',
    $PROMPT$You are the SCAMPER lens for a brainstorming pipeline. Given a binding question, apply the SCAMPER framework to generate distinct, concrete candidate ideas. SCAMPER prompts:

S — SUBSTITUTE: what could be swapped out for something else?
C — COMBINE: what could be merged with another idea, object, or process?
A — ADAPT: what existing solution from another domain could be adapted?
M — MAGNIFY / MINIFY: what could be made bigger, smaller, stronger, or weaker?
P — PUT TO OTHER USE: what other purposes could this serve?
E — ELIMINATE: what could be removed to simplify or focus?
R — REVERSE / REARRANGE: what if the order or relationship were flipped?

Generate 2-3 ideas per prompt letter (14-21 ideas total). Each idea has:
- A one-line title (max 12 words)
- A 2-3 sentence description explaining what it is and why it might work
- A SCAMPER tag in brackets, e.g. [S-Substitute]

Output ONE markdown list grouped by letter. No prose intro. No prose outro. End your turn after the list.$PROMPT$,
    0.7, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Six Hats (j5)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-six-hats', '*',
    'Six Thinking Hats lens (de Bono). Generates ideas through Green (creative), White (factual), and Black (critical) modes.',
    'primary',
    $PROMPT$You are the Six Hats lens for a brainstorming pipeline, applying Edward de Bono's Six Thinking Hats framework. For brainstorm purposes, focus on three complementary modes:

GREEN HAT — Creative, wild, "what if"
   Generate 5-7 unconventional, ambitious ideas. Don't worry about feasibility. Aim for variety in mechanism and scale.

WHITE HAT — Facts, data, what's been done before
   Generate 3-4 ideas grounded in existing examples from the literature, similar institutions, or proven patterns. Cite the precedent where you can.

BLACK HAT — Critical, what could go wrong
   Surface 3-4 risks, constraints, failure modes, or things to avoid. Each phrased as a thing to watch out for. These are constraints the other lenses (and downstream synthesis) should respect.

Total target: 11-15 items across the three hats.

Format each item as a bullet:
- One-line title
- 2-sentence description
- Hat tag in brackets at end, e.g. [GREEN], [WHITE], [BLACK]

Output ONE markdown list grouped by hat. No prose intro. No prose outro. End your turn after the list.$PROMPT$,
    0.8, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Crazy 8s (j5)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-crazy8s', '*',
    'Crazy 8s lens. Sprint exercise: 8 distinct ideas in 8 minutes. Volume over polish; deliberate variety.',
    'primary',
    $PROMPT$You are the Crazy 8s lens for a brainstorming pipeline. Crazy 8s is a sprint technique: generate 8 distinct ideas fast, prioritizing VOLUME and VARIETY over polish.

Rules:
- Exactly 8 ideas. Number them 1-8.
- Each idea is ONE sentence (max 25 words).
- Ideas must be DISTINCT — no variations of the same theme.
- Deliberate variety across the 8:
  * At least one OBVIOUS idea (the first thing anyone would think of)
  * At least one WEIRD idea (unconventional mechanism or framing)
  * At least one ADJACENT-DOMAIN idea (stolen from a different field)
  * At least one MOONSHOT (impossible or expensive but interesting)
  * Fill the rest with whatever mix feels right
- Tag each with ONE keyword in brackets at the end, e.g. [obvious], [weird], [adjacent-domain], [moonshot], [cheap], [community], [tech], [analog].

Output a numbered markdown list (1-8). No prose intro. No prose outro. End your turn after item 8.$PROMPT$,
    0.9, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Reverse (j5)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-reverse', '*',
    'Reverse brainstorm lens. Generate failure modes first, then invert each into a positive solution.',
    'primary',
    $PROMPT$You are the Reverse Brainstorm lens. Instead of "how could we solve this?", you ask "how could we GUARANTEE FAILURE here?" — then INVERT each failure mode into a solution.

The technique works because identifying failure modes is often easier than identifying solutions, and the inversion produces solutions that specifically guard against the worst outcomes.

Step 1 — FAILURE MODES: Generate 5-7 specific ways this question could be answered badly. Concrete and specific. Format each as:
  - Failure mode: <description>

Step 2 — INVERSIONS: For each failure mode, write the opposite/protective approach. Format each as:
  - → Inverted: <description of the protective or opposite approach>

Output as a markdown list of paired items. No prose intro. No prose outro. End your turn after the last inversion.$PROMPT$,
    0.7, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Mind Mapping (j9a)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-mind-mapping', '*',
    'Mind Mapping lens. Outputs a hierarchical idea tree (3-4 central branches, 3-5 sub-ideas per branch). Different from flat-list lenses by surfacing relationships.',
    'primary',
    $PROMPT$You are the Mind Mapping lens for a brainstorming pipeline. A mind map is a hierarchical idea tree where the binding question sits at the center, surrounded by 3-4 angular sub-themes, each with its own 3-5 child ideas. The structure surfaces RELATIONSHIPS between ideas in a way that a flat list cannot.

Step 1 — Pick 3-4 ANGULAR sub-themes from the binding question. Angular means they attack the question from genuinely different directions. Avoid sub-themes that just rephrase the question (those produce shallow children).

Step 2 — For each sub-theme, generate 3-5 child ideas. Children should be CONCRETE and SPECIFIC enough that a reader could act on them.

Step 3 — Optionally mark cross-branch links where an idea on branch A naturally connects to one on branch B. Use the format `(→ B.2)` at the end of A.X.

Format as a nested markdown list with bold sub-theme headers:

- **<Sub-theme 1>**
  - <Child idea 1.1>
  - <Child idea 1.2 (→ 2.3)>
  - ...
- **<Sub-theme 2>**
  - ...

Aim for 12-18 total leaves across all branches. No prose intro. No prose outro. End your turn after the last leaf.$PROMPT$,
    0.7, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Brainwriting (j9a)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-brainwriting', '*',
    'Brainwriting lens. Self-iterating: 6 seed ideas, then 3 builds per seed (extension / variation / counter). Distinct from Crazy 8s by adding structured iteration on each seed.',
    'primary',
    $PROMPT$You are the Brainwriting lens for a brainstorming pipeline. Brainwriting (the 6-3-5 method) is a sprint technique where each participant writes 6 initial ideas, then 3 builds on each. You are simulating that whole loop in one pass.

Step 1 — Generate 6 distinct SEED ideas (numbered 1-6). Each seed is one sentence (max 20 words). Aim for variety in mechanism — not 6 variations of the same theme.

Step 2 — For EACH seed, produce 3 builds in this exact triad shape:
- **Extend** — push the seed further. What's the more ambitious or wider-scope version?
- **Vary** — same core but different mechanism, audience, or context.
- **Counter** — what if you flipped one assumption inside the seed? (not a rejection — a productive twist)

Format as nested markdown:

1. <Seed 1>
   - **Extend:** <build>
   - **Vary:** <build>
   - **Counter:** <build>
2. <Seed 2>
   - **Extend:** ...
   ...

Total output: 6 seeds + 18 builds = 24 items. Each build is one sentence. No prose intro. No prose outro. End your turn after seed 6's Counter build.$PROMPT$,
    0.8, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Starbursting (j9a)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-starbursting', '*',
    'Starbursting lens. Generates the QUESTIONS worth asking (Who/What/When/Where/Why/How) instead of answers. Reframes the brief by surfacing what the asker hadn''t yet articulated.',
    'primary',
    $PROMPT$You are the Starbursting lens for a brainstorming pipeline. Starbursting is the 5W1H technique: instead of generating answers, you generate the QUESTIONS that should be asked before any answer is meaningful. The deliverable shifts the brief itself.

For the binding question, produce 4-6 sharp questions in EACH of the six categories. Questions must be:
- SPECIFIC to this binding question (not generic)
- DIFFERENT angles within the category (not rephrasings of each other)
- ACTIONABLE — answering each would produce information that changes the design

Format as six markdown sections:

## WHO
- <Question 1>
- <Question 2>
- ...

## WHAT
- ...

## WHEN
- ...

## WHERE
- ...

## WHY
- ...

## HOW
- ...

Total 24-36 questions. Do NOT answer them. The OUTPUT of this lens is the question set; the value is in the questions the original brief left unasked. No prose intro. No prose outro. End your turn after the last HOW question.$PROMPT$,
    0.6, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Disney Method (j9a)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-disney', '*',
    'Disney Method lens. Three voices in sequence: Dreamer (ambition without constraint), Realist (concrete execution), Critic (risks and failures). Each voice constrains and informs the next.',
    'primary',
    $PROMPT$You are the Disney Method lens for a brainstorming pipeline. Walt Disney famously used three "rooms" to develop ideas: the DREAMER (no constraints, only vision), the REALIST (how would we actually do it?), and the CRITIC (what fails / what's missing?). The three voices run in sequence and the later voices SHOULD reference the earlier ones.

## DREAMER
Generate 5-7 ambitious, unconstrained visions for the binding question. Don't worry about feasibility. What's the version that would make people say "wow"? What's the version that solves the underlying need entirely, not just adequately?

## REALIST
For each dream above (reference by number), name what an actual execution would look like. 1-2 sentences each. What's the concrete first step? What roles, materials, dependencies? Skip any dream that has no realistic path — don't force it.

## CRITIC
For the realist plans you just sketched, name the failure modes. Be specific. 3-5 critiques total. Format each as: "Critique: <what fails> → Watch out: <the protective principle>".

Format the output as three markdown sections with the headers above. Each section's items are bulleted. No prose intro. No prose outro. End your turn after the last Critic bullet.$PROMPT$,
    0.7, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Storyboarding (j9a)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-storyboarding', '*',
    'Storyboarding lens. Frames the problem as a 5-7 scene narrative — stakeholder, setting, action, complication, resolution arc. Distinct because it surfaces TEMPORAL and CONTEXTUAL ideas a flat list misses.',
    'primary',
    $PROMPT$You are the Storyboarding lens for a brainstorming pipeline. A storyboard tells the binding question as a 5-7 scene narrative. Story-based thinking surfaces ideas the flat-list techniques miss: how the situation begins, what triggers change, who is affected when, and what comes after.

Pick one PROTAGONIST relevant to the binding question (a specific person, role, or institution). Then write 5-7 scenes describing their journey from "before" through "during" to "after." Each scene is:
- A scene label (one phrase, e.g. "Tuesday morning: the problem becomes visible")
- A 2-3 sentence description of what happens, who is involved, what they notice
- An IDEA seed — what design/solution element appears in this scene? (One sentence)

Format as numbered scenes:

### Scene 1 — <label>
<2-3 sentence description>
**Idea:** <one-sentence design element>

### Scene 2 — <label>
...

The arc should pass through at least: a baseline / status quo, a triggering complication, a midpoint shift, and a resolution that's different from the start. Don't be afraid of mess — a story that's all triumphant is fiction. No prose intro. No prose outro. End your turn after Scene N's Idea line.$PROMPT$,
    0.7, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- TRIZ (j9a)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-triz', '*',
    'TRIZ lens. Identifies the core contradiction in the binding question, then maps 3-5 of TRIZ''s 40 inventive principles that resolve it. Heavyweight / structured; produces very different output from divergent lenses.',
    'primary',
    $PROMPT$You are the TRIZ lens for a brainstorming pipeline. TRIZ (Altshuller, 1946) is a structured invention methodology built from analyzing 200K+ patents. Its key insight: most inventive problems contain a CONTRADICTION (improving X worsens Y), and the same 40 INVENTIVE PRINCIPLES recur across domains to resolve those contradictions.

## STEP 1 — NAME THE CONTRADICTION
What is the binding question actually asking us to improve, AND what does that improvement appear to make worse? Phrase it as: "If we improve X, then Y suffers." Generate 2-3 distinct contradictions (problems often contain more than one).

## STEP 2 — MAP TO PRINCIPLES
For each contradiction, cite 2-3 TRIZ principles from the canonical 40 that would help resolve it. Use the principle name and number (e.g. "Principle 1: Segmentation"). The 40 principles include: Segmentation, Taking Out, Local Quality, Asymmetry, Merging, Universality, Nested Doll, Counterweight, Preliminary Anti-Action, Preliminary Action, Beforehand Cushioning, Equipotentiality, The Other Way Round, Spheroidality / Curvature, Dynamics, Partial or Excessive Action, Another Dimension, Mechanical Vibration, Periodic Action, Continuity of Useful Action, Skipping, Blessing in Disguise, Feedback, Intermediary, Self-Service, Copying, Cheap Short-Living Objects, Mechanics Substitution, Pneumatics / Hydraulics, Flexible Shells / Thin Films, Porous Materials, Color Changes, Homogeneity, Discarding / Recovering, Parameter Changes, Phase Transitions, Thermal Expansion, Strong Oxidants, Inert Atmosphere, Composite Materials.

## STEP 3 — SOLUTION SKETCH
For each cited principle, write 1-2 sentences applying it concretely to the binding question. What does using THIS principle look like in this specific situation?

Format as three sections with the headers above. No prose intro. No prose outro. End your turn after the last solution sketch.$PROMPT$,
    0.4, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Forced Analogy (j9a)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-forced-analogy', '*',
    'Forced Analogy lens. Picks 3 random unrelated domains, restates the binding question in each domain''s vocabulary, generates ideas, ports back. Distinct from SCAMPER''s Adapt by being explicitly cross-domain.',
    'primary',
    $PROMPT$You are the Forced Analogy lens for a brainstorming pipeline. The technique: pick a random domain unrelated to the binding question, restate the question in that domain's vocabulary, generate ideas that make sense IN THAT DOMAIN, then port them back. The forcing produces ideas the home domain's clichés can't reach.

## STEP 1 — PICK THREE DOMAINS
Choose 3 distinct random domains, NOT related to the binding question. Mix concrete and abstract. Examples to draw from (but not limited to): cooking, jazz improvisation, gardening, beekeeping, surgery, blacksmithing, plumbing, fishing, weaving, distillation, chess, basketball, sailing, glassblowing, brewing, archaeology, parenting, herding, theatre, watchmaking, coral-reef ecology.

## STEP 2 — RESTATE + GENERATE
For EACH domain (label clearly):

**In the language of <domain>:** Restate the binding question using only that domain's vocabulary. Be playful but accurate — the analogy should feel true even if odd.

**Ideas (3-4):** Generate ideas that make sense WITHIN that domain. Don't think about the home problem yet.

**Port back:** Take EACH idea and write the equivalent in the home domain. One sentence per port. Sometimes the port is obvious; sometimes it's a stretch — name the stretch when it occurs.

## STEP 3 — STANDOUT
After the three domains, pick the ONE port that surprises you most and write 1-2 sentences explaining why it surfaces something the home domain's clichés missed.

Format with the three labels above. No prose intro. No prose outro. End your turn after the STANDOUT.$PROMPT$,
    0.9, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- Worst Possible Idea (j9a)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES (
    'brainstorm-worst-idea', '*',
    'Worst Possible Idea lens. Generates intentionally terrible solutions, extracts the VIOLATED PRINCIPLE inside each, then inverts that principle into a positive design constraint. Distinct from Reverse Brainstorm (which inverts failure modes) by starting from concrete bad solutions.',
    'primary',
    $PROMPT$You are the Worst Possible Idea lens for a brainstorming pipeline. The technique: deliberately generate TERRIBLE solutions to the binding question, then dissect each to find the principle they violate, then invert that principle into a positive design constraint. Bad ideas are easier to generate freely (no ego involved), and their inversions are often sharper than ideas you'd reach starting from "what's the right answer?"

## STEP 1 — TERRIBLE IDEAS
Generate 5-7 deliberately bad solutions to the binding question. Numbered 1-N. Each is one sentence. Aim for:
- At least one obviously stupid idea (the cartoon version)
- At least one that would CAUSE THE OPPOSITE of what's wanted
- At least one that's expensive AND ineffective
- At least one that violates an ethical line
- At least one that's technically possible but obviously wrong

Don't be subtle. Bad means bad.

## STEP 2 — DIAGNOSE
For each terrible idea, name the SINGLE principle it violates. Format: "Principle violated: <named principle>" — try to phrase the principle clearly enough that someone could write it on a sticky note.

## STEP 3 — INVERT
For each diagnosed principle, write its positive form: a design constraint or commitment that protects against the failure mode the bad idea embodied. Format: "Constraint: <positive principle>." Constraints should be CONCRETE — something a designer could check their work against.

Format as a numbered list where each item carries all three (idea / diagnosis / constraint):

1. **Terrible idea:** ...
   **Principle violated:** ...
   **Constraint:** ...
2. ...

No prose intro. No prose outro. End your turn after the last Constraint.$PROMPT$,
    0.9, NULL
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, mode = EXCLUDED.mode, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- =====================================================================
-- decompose-fanout pipeline (j1, 2 stages: context_gather, decompose).
-- =====================================================================
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified, metadata
)
VALUES (
    'decompose-fanout',
    'Fan-out: decompose a binding question into N child work_items + an aggregator child. spawn fires on maturity=verified via on_maturity_verified; aggregator dispatches when all siblings terminal.',
    $STAGES$[
      {
        "name": "context_gather",
        "next": "decompose",
        "model": "qwen3.6-plus",
        "provider": "opencode_go",
        "agent_family": "research",
        "auto_advance": true,
        "tools_disabled": false,
        "input_template": "Binding question: {{input.binding_question}}\n\n## YOUR TASK — context briefing for the decomposer\n\nThis is the context_gather stage of a fan-out pipeline. The next stage (decompose) will split this binding question into N child work_items. Brief the decomposer on:\n\n1. **Prior work on this question** — search `.spec/journal/`, `.spec/proposals/`, `.mind/*`, `docs/**`, and prior work_items. Has this question been tackled before? How was it scoped?\n2. **Natural decomposition axes** — for THIS question, what are the obvious sub-questions? Categories? Phases? Stakeholders? Don't decide the decomposition — that's the decomposer's job — just surface the axes.\n3. **Existing artifacts to NOT duplicate** — if children would produce files that overlap with files already in the repo, name them so the decomposer can adjust scope.\n\nHARD CONSTRAINTS:\n- Maximum 3 rounds of tool calls.\n- Output budget: ~1.5KB.\n- End-of-turn: your final message is the briefing in markdown, then STOP.\n\nOUTPUT FORMAT:\n\n## Prior work\n<bullets, file paths>\n\n## Decomposition axes worth considering\n<bullets of axes, not the decomposition itself>\n\n## Existing artifacts to avoid duplicating\n<bullets, file paths>\n\nIf there's no prior work, say so — the decomposer will start fresh."
      },
      {
        "name": "decompose",
        "next": null,
        "model": "qwen3.6-plus",
        "provider": "opencode_go",
        "agent_family": "fanout-decompose",
        "auto_advance": true,
        "tools_disabled": false,
        "input_template": "Binding question: {{input.binding_question}}\n\n## CONTEXT BRIEFING (from context_gather stage)\n\n{{stage_results.context_gather.output}}\n\n## YOUR TASK\n\nProduce the decomposition manifest as JSON only (no prose, no fences). Follow the schema in your system prompt exactly. Each child must have slug, binding_question, pipeline_family. Aggregate must have destination and synthesis."
      }
    ]$STAGES$::jsonb,
    false, false, NULL, NULL,
    '["raw", "planned", "verified"]'::jsonb,
    false,
    jsonb_build_object('shape', 'fanout', 'spawn_on_verified', true)
)
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description, stages = EXCLUDED.stages,
       sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
       file_destination_template = EXCLUDED.file_destination_template,
       file_content_jsonpath = EXCLUDED.file_content_jsonpath,
       maturity_ladder = EXCLUDED.maturity_ladder,
       auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
       metadata = EXCLUDED.metadata;

-- =====================================================================
-- aggregate-children pipeline (j1; j3 cleared file_destination_template
-- to NULL — spawn_children sets file_destination directly).
-- =====================================================================
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified, metadata
)
VALUES (
    'aggregate-children',
    'Aggregator: writes an index of completed fan-out children to a single file. Spawned by spawn_children() in status=pending with file_destination set; dispatched when all sibling children are terminal.',
    $STAGES$[
      {
        "name": "aggregate",
        "next": null,
        "model": "qwen3.6-plus",
        "provider": "opencode_go",
        "agent_family": "fanout-aggregate",
        "auto_advance": true,
        "tools_disabled": false,
        "input_template": "## Fan-out aggregation\n\nParent binding question: {{input.binding_question}}\n\nDestination: {{input.destination}}\nSynthesis: {{input.synthesis}}\n\nChildren to aggregate:\n\n{{input.children}}\n\nUse work_item_show on each child id to read its output. Compose the index per your system prompt. Return ONLY the markdown body."
      }
    ]$STAGES$::jsonb,
    false, false,
    NULL,                              -- j3: spawn_children sets file_destination directly
    'stage_results.aggregate.output',
    '["raw", "verified"]'::jsonb,
    true,                              -- aggregate output auto-materializes
    jsonb_build_object('shape', 'aggregate')
)
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description, stages = EXCLUDED.stages,
       sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
       file_destination_template = EXCLUDED.file_destination_template,
       file_content_jsonpath = EXCLUDED.file_content_jsonpath,
       maturity_ladder = EXCLUDED.maturity_ladder,
       auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
       metadata = EXCLUDED.metadata;

-- =====================================================================
-- 12 brainstorm lens pipelines (single-stage, NULL model/provider +
-- metadata.default_* — the j8b/j9b final). Runtime dispatch resolves the
-- model via 19's metadata→catalog fallback chain.
-- =====================================================================
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified, metadata
)
VALUES
(
    'brainstorm-scamper',
    'Brainstorm lens: SCAMPER. Single-stage pipeline emitting 14-21 candidate ideas tagged by transformation.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-scamper","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nApply your SCAMPER framework. Return ONE markdown list. End your turn after the list."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','scamper','default_model','qwen3.6-plus','default_provider','opencode_go','suggested_model','qwen3.6-plus','suggested_provider','opencode_go')
),
(
    'brainstorm-six-hats',
    'Brainstorm lens: Six Thinking Hats (Green/White/Black focus).',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-six-hats","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nApply the Six Thinking Hats framework. Return ONE markdown list grouped by hat. End your turn after the list."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','six-hats','default_model','kimi-k2.6','default_provider','opencode_go','suggested_model','kimi-k2.6','suggested_provider','opencode_go')
),
(
    'brainstorm-crazy8s',
    'Brainstorm lens: Crazy 8s. 8 ideas, 8 minutes, deliberate variety.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-crazy8s","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nApply Crazy 8s. Output 8 numbered ideas with one-line descriptions and a keyword tag each. End your turn after item 8."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','crazy8s','default_model','qwen3.6-plus','default_provider','opencode_go','suggested_model','qwen3.6-plus','suggested_provider','opencode_go')
),
(
    'brainstorm-reverse',
    'Brainstorm lens: Reverse — generate failure modes first, then invert each into a positive solution.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-reverse","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nApply Reverse Brainstorm: list 5-7 failure modes, then invert each. End your turn after the last inversion."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','reverse','default_model','kimi-k2.6','default_provider','opencode_go','suggested_model','kimi-k2.6','suggested_provider','opencode_go')
),
(
    'brainstorm-mind-mapping',
    'Brainstorm lens: Mind Mapping. Hierarchical idea tree, 3-4 angular branches × 3-5 children, optional cross-branch links.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-mind-mapping","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nProduce a mind map: 3-4 angular sub-themes, 3-5 children each. Mark cross-branch links inline. End your turn after the last leaf."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','mind-mapping','default_model','qwen3.6-plus','default_provider','opencode_go','suggested_model','qwen3.6-plus','suggested_provider','opencode_go')
),
(
    'brainstorm-brainwriting',
    'Brainstorm lens: Brainwriting (6-3-5). 6 seed ideas, 3 builds per seed (extend / vary / counter). 24 items total.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-brainwriting","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nProduce 6 seed ideas, then 3 builds (Extend / Vary / Counter) per seed. End your turn after seed 6's Counter build."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','brainwriting','default_model','kimi-k2.6','default_provider','opencode_go','suggested_model','kimi-k2.6','suggested_provider','opencode_go')
),
(
    'brainstorm-starbursting',
    'Brainstorm lens: Starbursting (5W1H). Question-generation, not answer-generation. 4-6 questions per Who/What/When/Where/Why/How.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-starbursting","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nProduce 4-6 specific actionable questions in each of the six categories. Do NOT answer them. End your turn after the last HOW question."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','starbursting','default_model','kimi-k2.6','default_provider','opencode_go','suggested_model','kimi-k2.6','suggested_provider','opencode_go')
),
(
    'brainstorm-disney',
    'Brainstorm lens: Disney Method. Three voices in sequence — Dreamer (no constraints), Realist (concrete execution), Critic (risks). Later voices reference earlier.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-disney","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nApply Disney Method: Dreamer (5-7 visions) → Realist (execution per dream) → Critic (3-5 critiques with watch-out principles). End your turn after the last Critic bullet."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','disney','default_model','kimi-k2.6','default_provider','opencode_go','suggested_model','kimi-k2.6','suggested_provider','opencode_go')
),
(
    'brainstorm-storyboarding',
    'Brainstorm lens: Storyboarding. 5-7 narrative scenes with a single protagonist; each scene seeds one design idea. Surfaces temporal / contextual angles flat lists miss.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-storyboarding","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nWrite 5-7 scenes following one protagonist through baseline → complication → midpoint → resolution. Each scene ends with an Idea seed. End your turn after the final Idea."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','storyboarding','default_model','qwen3.6-plus','default_provider','opencode_go','suggested_model','qwen3.6-plus','suggested_provider','opencode_go')
),
(
    'brainstorm-triz',
    'Brainstorm lens: TRIZ. Identify contradictions in the binding question; map to 3-5 of TRIZ''s 40 inventive principles; concrete solution sketch per principle.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-triz","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nApply TRIZ: name 2-3 contradictions, map each to 2-3 of the 40 inventive principles, write a concrete solution sketch per cited principle. End your turn after the last solution sketch."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','triz','default_model','kimi-k2.6','default_provider','opencode_go','suggested_model','kimi-k2.6','suggested_provider','opencode_go')
),
(
    'brainstorm-forced-analogy',
    'Brainstorm lens: Forced Analogy. 3 random unrelated domains × restate-generate-port. Plus one standout port that surfaces something the home domain''s clichés missed.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-forced-analogy","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nApply Forced Analogy: pick 3 random unrelated domains, restate the question in each, generate 3-4 in-domain ideas, port each back. Close with one STANDOUT port. End your turn after the STANDOUT."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','forced-analogy','default_model','qwen3.6-plus','default_provider','opencode_go','suggested_model','qwen3.6-plus','suggested_provider','opencode_go')
),
(
    'brainstorm-worst-idea',
    'Brainstorm lens: Worst Possible Idea. 5-7 intentionally terrible solutions → name the violated principle each embodies → invert into a positive design constraint.',
    $STAGES$[{"name":"lens","next":null,"model":null,"provider":null,"agent_family":"brainstorm-worst-idea","auto_advance":true,"tools_disabled":false,"input_template":"Binding question: {{input.binding_question}}\n\nApply Worst Possible Idea: 5-7 terrible solutions, each with violated-principle diagnosis, each inverted into a positive constraint. End your turn after the last Constraint."}]$STAGES$::jsonb,
    false, false, NULL, NULL, '["raw", "verified"]'::jsonb, false,
    jsonb_build_object('shape','brainstorm-lens','lens','worst-idea','default_model','qwen3.6-plus','default_provider','opencode_go','suggested_model','qwen3.6-plus','suggested_provider','opencode_go')
)
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description, stages = EXCLUDED.stages,
       sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
       file_destination_template = EXCLUDED.file_destination_template,
       file_content_jsonpath = EXCLUDED.file_content_jsonpath,
       maturity_ladder = EXCLUDED.maturity_ladder,
       auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
       metadata = EXCLUDED.metadata;

-- =====================================================================
-- spawn_children — CORRECT UNION of j3 (aggregator file_destination) +
-- j4 (per-child file_destination) + j8c (model/provider override
-- propagation). ★ j8c (the last live redefinition) dropped j3/j4's
-- file_destination handling; restored here. Deterministic SQL (no LLM).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.spawn_children(p_parent_id uuid)
RETURNS int LANGUAGE plpgsql AS $FN$
DECLARE
    v_parent            stewards.work_items%ROWTYPE;
    v_manifest          jsonb;
    v_manifest_raw      text;
    v_child             jsonb;
    v_child_id          uuid;
    v_count             int := 0;
    v_aggregator        jsonb;
    v_agg_id            uuid;
    v_agg_dest          text;
    v_children_arr      jsonb := '[]'::jsonb;
    v_child_pipeline    text;
    v_child_slug        text;
    v_child_input       jsonb;
    v_cost_cap          bigint;
    v_child_dest        text;
    v_model_override    text;
    v_provider_override text;
BEGIN
    SELECT * INTO v_parent FROM stewards.work_items WHERE id = p_parent_id;
    IF v_parent.id IS NULL THEN
        RAISE EXCEPTION 'spawn_children: parent % not found', p_parent_id;
    END IF;

    v_manifest := v_parent.stage_results -> 'decompose' -> 'output';
    IF v_manifest IS NULL THEN
        RAISE EXCEPTION 'spawn_children: no decompose output on parent %', p_parent_id;
    END IF;

    IF jsonb_typeof(v_manifest) = 'string' THEN
        v_manifest_raw := v_manifest #>> '{}';
        BEGIN
            v_manifest := v_manifest_raw::jsonb;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'spawn_children: decompose output is not valid JSON: %', SQLERRM;
        END;
    END IF;

    IF v_manifest -> 'children' IS NULL
       OR jsonb_typeof(v_manifest -> 'children') <> 'array'
       OR jsonb_array_length(v_manifest -> 'children') = 0 THEN
        RAISE EXCEPTION 'spawn_children: manifest.children is missing or empty';
    END IF;

    IF v_manifest -> 'aggregate' IS NULL
       OR (v_manifest -> 'aggregate' ->> 'destination') IS NULL THEN
        RAISE EXCEPTION 'spawn_children: manifest.aggregate.destination is required';
    END IF;

    -- Spawn regular children.
    FOR v_child IN SELECT * FROM jsonb_array_elements(v_manifest -> 'children') LOOP
        v_child_pipeline := v_child ->> 'pipeline_family';
        v_child_slug     := v_child ->> 'slug';

        IF v_child_pipeline IS NULL OR v_child_slug IS NULL
           OR (v_child ->> 'binding_question') IS NULL THEN
            RAISE EXCEPTION 'spawn_children: child entry missing slug/pipeline_family/binding_question: %', v_child;
        END IF;

        v_child_input := jsonb_build_object(
            'binding_question', v_child ->> 'binding_question'
        );
        IF (v_child -> 'input_extra') IS NOT NULL
           AND jsonb_typeof(v_child -> 'input_extra') = 'object' THEN
            v_child_input := v_child_input || (v_child -> 'input_extra');
        END IF;

        v_child_id := stewards.work_item_create(
            p_pipeline_family => v_child_pipeline,
            p_input           => v_child_input,
            p_slug            => v_child_slug,
            p_actor           => v_parent.actor,
            p_intent_id       => v_parent.intent_id
        );

        v_cost_cap := NULL;
        IF (v_child ->> 'cost_cap_micro') IS NOT NULL THEN
            v_cost_cap := (v_child ->> 'cost_cap_micro')::bigint;
        END IF;

        v_child_dest := v_child ->> 'file_destination';   -- j4: per-child file destination

        UPDATE stewards.work_items
           SET parent_work_item_id = p_parent_id,
               project_association = COALESCE(
                   v_child ->> 'project_association',
                   v_parent.project_association
               ),
               cost_cap_micro   = COALESCE(v_cost_cap, cost_cap_micro),
               file_destination = COALESCE(v_child_dest, file_destination)   -- j4
         WHERE id = v_child_id;

        -- j8c: propagate model + provider overrides from manifest child to the
        -- child work_item, BEFORE dispatch. NULL values are a no-op.
        v_model_override    := v_child ->> 'model_override';
        v_provider_override := v_child ->> 'provider_override';
        IF v_model_override IS NOT NULL OR v_provider_override IS NOT NULL THEN
            UPDATE stewards.work_items
               SET model_override    = COALESCE(v_model_override,    model_override),
                   provider_override = COALESCE(v_provider_override, provider_override)
             WHERE id = v_child_id;
        END IF;

        -- Dispatch each child immediately so they process in parallel.
        PERFORM stewards.work_item_dispatch_stage(v_child_id, NULL);

        v_children_arr := v_children_arr || jsonb_build_object(
            'id', v_child_id::text,
            'slug', v_child_slug,
            'binding_question', v_child ->> 'binding_question',
            'pipeline_family', v_child_pipeline,
            'file_destination', v_child_dest
        );
        v_count := v_count + 1;
    END LOOP;

    -- Spawn the aggregator (NOT dispatched — waits for siblings).
    v_aggregator := v_manifest -> 'aggregate';
    v_agg_dest   := v_aggregator ->> 'destination';

    v_agg_id := stewards.work_item_create(
        p_pipeline_family => 'aggregate-children',
        p_input           => jsonb_build_object(
            'binding_question', 'Aggregate index for: ' || COALESCE(v_parent.input ->> 'binding_question', v_parent.slug),
            'parent_work_item_id', p_parent_id::text,
            'destination', v_agg_dest,
            'synthesis', COALESCE((v_aggregator ->> 'synthesis')::boolean, false),
            'children', v_children_arr
        ),
        p_slug            => COALESCE(v_parent.slug, p_parent_id::text) || '-aggregator',
        p_actor           => v_parent.actor,
        p_intent_id       => v_parent.intent_id
    );

    -- j3: set the aggregator's file_destination directly from the manifest
    -- (the aggregate-children pipeline has no file_destination_template).
    UPDATE stewards.work_items
       SET parent_work_item_id = p_parent_id,
           project_association = v_parent.project_association,
           file_destination    = v_agg_dest
     WHERE id = v_agg_id;
    -- aggregator stays at status='pending'; on_maturity_verified flips it
    -- to dispatched when all siblings are terminal.

    RAISE NOTICE 'spawn_children: parent=% spawned % children + aggregator % (dest=%)',
        p_parent_id, v_count, v_agg_id, v_agg_dest;

    RETURN v_count;
END;
$FN$;

COMMENT ON FUNCTION stewards.spawn_children(uuid) IS
'14-fanout (j1+j3+j4+j8c union): decompose-fanout spawn. Reads stage_results.decompose.output manifest; inserts N children (each gets per-child file_destination + model/provider override from the manifest, then is dispatched) + 1 aggregator child (status=pending, file_destination=manifest.aggregate.destination). Returns count of regular children. NOTE: restores the j3/j4 file_destination handling that j8c dropped.';

-- =====================================================================
-- start_brainstorm (j12 final): p_lenses subset + p_models override +
-- pre-flight enforced-cap check. Hardcoded intent slug → config.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.start_brainstorm(
    p_binding_question        text,
    p_destination             text,
    p_project_association     text     DEFAULT NULL,
    p_actor                   text     DEFAULT 'human',
    p_slug                    text     DEFAULT NULL,
    p_cost_cap_per_lens_micro bigint   DEFAULT 200000,
    p_models                  jsonb    DEFAULT NULL,
    p_lenses                  text[]   DEFAULT ARRAY['scamper', 'six-hats', 'crazy8s', 'reverse']
)
RETURNS uuid LANGUAGE plpgsql AS $FN$
DECLARE
    v_slug             text;
    v_parent_id        uuid;
    v_manifest         jsonb;
    v_lens             text;
    v_lens_family      text;
    v_lens_slug        text;
    v_models_entry     jsonb;
    v_model_override   text;
    v_provider_override text;
    v_child            jsonb;
    v_children_arr     jsonb := '[]'::jsonb;
    v_unknown_lenses   text[];
    v_lens_provider    text;
    v_capped           text[] := ARRAY[]::text[];
    v_intent_id        uuid;
BEGIN
    IF p_lenses IS NULL OR cardinality(p_lenses) = 0 THEN
        RAISE EXCEPTION 'start_brainstorm: p_lenses must contain at least one lens name';
    END IF;

    -- Validate every requested lens corresponds to an existing pipeline.
    SELECT array_agg(lens_name)
      INTO v_unknown_lenses
      FROM (SELECT unnest(p_lenses) AS lens_name) requested
     WHERE NOT EXISTS (
         SELECT 1 FROM stewards.pipelines
          WHERE family = 'brainstorm-' || requested.lens_name
     );
    IF v_unknown_lenses IS NOT NULL THEN
        RAISE EXCEPTION 'start_brainstorm: unknown lens name(s): %. Available lenses: %. (Introspect with SELECT regexp_replace(family, ''^brainstorm-'', '''') FROM stewards.pipelines WHERE family LIKE ''brainstorm-%%'')',
            v_unknown_lenses,
            (SELECT array_agg(regexp_replace(family, '^brainstorm-', ''))
               FROM stewards.pipelines WHERE family LIKE 'brainstorm-%');
    END IF;

    -- J.12 PRE-FLIGHT: refuse early if any lens routes to a provider whose
    -- enforced spend cap is already reached. Resolves each lens's provider
    -- the same way dispatch does (p_models override → pipeline default →
    -- catalog default).
    FOREACH v_lens IN ARRAY p_lenses LOOP
        v_lens_provider := NULL;
        IF p_models IS NOT NULL AND (p_models ? v_lens)
           AND jsonb_typeof(p_models -> v_lens) = 'object' THEN
            v_lens_provider := (p_models -> v_lens) ->> 'provider';
        END IF;
        IF v_lens_provider IS NULL THEN
            v_lens_provider := COALESCE(
                (SELECT metadata->>'default_provider' FROM stewards.pipelines
                  WHERE family = 'brainstorm-' || v_lens),
                stewards.catalog_default_provider()
            );
        END IF;
        IF v_lens_provider IS NOT NULL
           AND stewards.provider_cap_exceeded(v_lens_provider)
           AND NOT (v_lens_provider = ANY(v_capped)) THEN
            v_capped := v_capped || v_lens_provider;
        END IF;
    END LOOP;

    IF cardinality(v_capped) > 0 THEN
        RAISE EXCEPTION 'start_brainstorm: refused — provider(s) % at spend cap. Top up + reset: SELECT stewards.provider_cap_refill(''<provider>''); (or drop the lens(es) routed to them).',
            v_capped;
    END IF;

    v_slug := COALESCE(p_slug, 'brainstorm-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS'));

    FOREACH v_lens IN ARRAY p_lenses LOOP
        v_lens_family    := 'brainstorm-' || v_lens;
        v_lens_slug      := v_slug || '-' || v_lens;
        v_model_override := NULL;
        v_provider_override := NULL;

        IF p_models IS NOT NULL AND (p_models ? v_lens) THEN
            v_models_entry := p_models -> v_lens;
            IF jsonb_typeof(v_models_entry) = 'string' THEN
                v_model_override := v_models_entry #>> '{}';
            ELSIF jsonb_typeof(v_models_entry) = 'object' THEN
                v_model_override    := v_models_entry ->> 'model';
                v_provider_override := v_models_entry ->> 'provider';
            END IF;
        END IF;

        v_child := jsonb_build_object(
            'slug',             v_lens_slug,
            'pipeline_family',  v_lens_family,
            'binding_question', p_binding_question,
            'cost_cap_micro',   p_cost_cap_per_lens_micro
        );
        IF v_model_override IS NOT NULL THEN
            v_child := v_child || jsonb_build_object('model_override', v_model_override);
        END IF;
        IF v_provider_override IS NOT NULL THEN
            v_child := v_child || jsonb_build_object('provider_override', v_provider_override);
        END IF;

        v_children_arr := v_children_arr || v_child;
    END LOOP;

    v_manifest := jsonb_build_object(
        'rationale', format('Brainstorm: %s lens(es) — %s. Synthesis aggregator combines.',
                            cardinality(p_lenses), array_to_string(p_lenses, ', ')),
        'children', v_children_arr,
        'aggregate', jsonb_build_object('destination', p_destination, 'synthesis', true)
    );

    -- Config-driven default intent (was hardcoded 'scripture-study').
    SELECT id INTO v_intent_id FROM stewards.intents
     WHERE slug = stewards.config_get_text('default_intent_slug', 'default');

    INSERT INTO stewards.work_items (
        pipeline_family, current_stage, slug, input, intent_id, actor,
        project_association, stage_results, maturity, status
    ) VALUES (
        'decompose-fanout', 'decompose', v_slug,
        jsonb_build_object('binding_question', p_binding_question, 'lenses', to_jsonb(p_lenses)),
        v_intent_id,
        p_actor, p_project_association,
        jsonb_build_object(
            'context_gather', jsonb_build_object('output', format('brainstorm: pre-populated %s-lens manifest, no context_gather LLM call', cardinality(p_lenses))),
            'decompose', jsonb_build_object('output', v_manifest)
        ),
        'planned', 'completed'
    )
    RETURNING id INTO v_parent_id;

    UPDATE stewards.work_items SET maturity = 'verified' WHERE id = v_parent_id;

    RAISE NOTICE 'start_brainstorm: parent=% slug=% lenses=% p_models=%',
        v_parent_id, v_slug, p_lenses, COALESCE(p_models::text, 'NULL');
    RETURN v_parent_id;
END;
$FN$;

COMMENT ON FUNCTION stewards.start_brainstorm(text, text, text, text, text, bigint, jsonb, text[]) IS
'14-fanout (j5+j8c+j9c+j12 final): brainstorm entry point. p_lenses defaults to the original 4 (scamper/six-hats/crazy8s/reverse); caller passes a subset of the 12 available short lens names. p_models per-lens override (string or {model,provider}). Pre-flight enforced-cap check refuses before spawning if any lens routes to an over-cap provider. Default intent comes from stewards.config default_intent_slug (was hardcoded scripture-study).';

-- =====================================================================
-- check_and_dispatch_fanout_aggregator (j7) — idempotent helper.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.check_and_dispatch_fanout_aggregator(p_parent_id uuid)
RETURNS uuid LANGUAGE plpgsql AS $FN$
DECLARE
    v_unfinished int;
    v_agg_id     uuid;
    v_agg_wq     bigint;
BEGIN
    IF p_parent_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Count siblings (excluding the aggregator) neither verified nor terminal-failed.
    SELECT COUNT(*) INTO v_unfinished
      FROM stewards.work_items
     WHERE parent_work_item_id = p_parent_id
       AND pipeline_family <> 'aggregate-children'
       AND maturity <> 'verified'
       AND status NOT IN ('cancelled', 'failed');

    IF v_unfinished > 0 THEN
        RETURN NULL;
    END IF;

    SELECT id INTO v_agg_id
      FROM stewards.work_items
     WHERE parent_work_item_id = p_parent_id
       AND pipeline_family = 'aggregate-children'
       AND status = 'pending'
     LIMIT 1;

    IF v_agg_id IS NULL THEN
        RETURN NULL;
    END IF;

    v_agg_wq := stewards.work_item_dispatch_stage(v_agg_id, NULL);
    RAISE NOTICE 'check_and_dispatch_fanout_aggregator: aggregator % dispatched wq=% (parent=%, all siblings terminal)',
        v_agg_id, v_agg_wq, p_parent_id;

    RETURN v_agg_id;
END;
$FN$;

COMMENT ON FUNCTION stewards.check_and_dispatch_fanout_aggregator(uuid) IS
'j7 (14-fanout): idempotent helper that counts unfinished children under a parent and dispatches the aggregator if all siblings are terminal (verified/failed/cancelled). Called from on_maturity_verified (child verifies, in 08) and on_child_status_terminal (child fails, here).';

-- =====================================================================
-- on_one_shot_pipeline_completed (j6) — auto-verify single-stage
-- pipelines (aggregate-children + brainstorm-*) on stage completion, so
-- on_maturity_verified fires for auto-materialize + aggregator dispatch.
-- (Supersedes j2's narrower on_aggregate_completed.)
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.on_one_shot_pipeline_completed()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_qualifies boolean;
BEGIN
    v_qualifies := NEW.pipeline_family = 'aggregate-children'
                OR NEW.pipeline_family LIKE 'brainstorm-%';

    IF NOT v_qualifies THEN
        RETURN NEW;
    END IF;

    IF NEW.maturity = 'verified' THEN
        RETURN NEW;
    END IF;

    UPDATE stewards.work_items
       SET maturity = 'verified',
           updated_at = now()
     WHERE id = NEW.id;

    RAISE NOTICE 'on_one_shot_pipeline_completed: auto-verified % (pipeline=%)',
        NEW.id, NEW.pipeline_family;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION stewards.on_one_shot_pipeline_completed() IS
'j6 (14-fanout): auto-verify one-shot pipelines (aggregate-children + brainstorm-*) when their single stage completes. Cascades into on_maturity_verified for auto-materialize and aggregator dispatch.';

DROP TRIGGER IF EXISTS work_items_on_one_shot_completed ON stewards.work_items;
CREATE TRIGGER work_items_on_one_shot_completed
AFTER UPDATE OF status ON stewards.work_items
FOR EACH ROW
WHEN (
    NEW.status = 'completed'
    AND (
        NEW.pipeline_family = 'aggregate-children'
        OR NEW.pipeline_family LIKE 'brainstorm-%'
    )
)
EXECUTE FUNCTION stewards.on_one_shot_pipeline_completed();

-- =====================================================================
-- on_child_status_terminal (j7) — when a fanout child fails/cancels,
-- still run the aggregator check so the chain converges with partials.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.on_child_status_terminal()
RETURNS trigger LANGUAGE plpgsql AS $FN$
BEGIN
    IF NEW.parent_work_item_id IS NULL
       OR NEW.pipeline_family = 'aggregate-children' THEN
        RETURN NEW;
    END IF;

    BEGIN
        PERFORM stewards.check_and_dispatch_fanout_aggregator(NEW.parent_work_item_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'on_child_status_terminal: aggregator-dispatch-check failed: %', SQLERRM;
    END;

    RETURN NEW;
END;
$FN$;

COMMENT ON FUNCTION stewards.on_child_status_terminal() IS
'j7 (14-fanout): fires when a fanout child transitions to a terminal status (failed/cancelled). Calls check_and_dispatch_fanout_aggregator so the chain converges even when children fail rather than verify.';

DROP TRIGGER IF EXISTS work_items_on_child_status_terminal ON stewards.work_items;
CREATE TRIGGER work_items_on_child_status_terminal
AFTER UPDATE OF status ON stewards.work_items
FOR EACH ROW
WHEN (
    NEW.status IN ('failed', 'cancelled')
    AND OLD.status NOT IN ('failed', 'cancelled')
    AND NEW.parent_work_item_id IS NOT NULL
    AND NEW.pipeline_family <> 'aggregate-children'
)
EXECUTE FUNCTION stewards.on_child_status_terminal();
