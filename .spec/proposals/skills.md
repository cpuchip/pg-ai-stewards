# Proposal: Skills — on-demand, agent-managed instruction modules

**Status:** draft for ratification · **Date:** 2026-06-16 · **Author:** Claude (Opus 4.8) with Michael

## The idea

A **skill** is a reusable instruction module — a named bundle of "here's how to do
X well" — that an agent or persona can pull into its context *when a task calls
for it*, and drop when done. It works like Claude Code's `SKILL.md`: a short
**frontmatter** (name + when-to-use) is always visible in the prompt; the full
**body** is loaded only on demand.

The key design move, and Michael's framing: **skills are a context lever, the same
shape as the context engine** (15a/15b's mute/pin/expand). The catalog of skills
costs almost nothing (one line each); a loaded skill body costs real tokens but
buys real capability; the agent **turns skills on and off itself** to spend its
context budget where the current task needs it. This is the read-side twin of
`compact_context` — where the judge frees space by muting *spent* context, skills
let the model *acquire* the right context just-in-time and release it after.

### Why the substrate doesn't have this yet

The substrate's building blocks are **agents** (a `(family, model_match)` system
prompt), **agent_tool_perms** (grants), and **pipelines** (stage workflows). An
agent's prompt is a *persistent identity* baked at dispatch. There is no way to
say "for this turn, also know how to run a redline" without either (a) bloating
the base prompt with every contingency, or (b) forking a new agent family. Skills
are the missing middle: modular, composable, on-demand instruction.

The nearest existing things: `.stewards/` (markdown agent-prompt files imported
into `stewards.agents` — but whole-prompt, not modular/on-demand) and the CT2
self-notes (`session_facets` — agent-written durable notes, but free-text memory,
not curated procedure). Skills sit between them: curated like an agent prompt,
session-scoped + loadable like a self-note.

## Design

### 1. The registry — `stewards.skills`

```
stewards.skills (
  slug         text PRIMARY KEY,        -- 'redline', 'source-verification'
  name         text NOT NULL,           -- display
  description  text NOT NULL,           -- the WHEN-TO-USE line; always visible in the catalog
  body         text NOT NULL,           -- the full instructions; injected only when loaded
  applies_to   text,                    -- agent_family glob ('*'=all, 'persona-%', 'analyst'); NULL=none
  auto_load    boolean NOT NULL DEFAULT false,  -- inject the body unconditionally for applicable agents
  est_tokens   int,                     -- body size estimate, for the loaded-budget gate
  active       boolean NOT NULL DEFAULT true,   -- globally enabled
  created_at, updated_at timestamptz
)
```

`description` is the load-bearing field — it's the only thing the model sees by
default, so (per Claude Code's own guidance) it must say *what the skill does AND
when to reach for it*. Bad descriptions = skills never loaded or loaded wrongly.

### 1b. Skill groups — the multi-tier catalog (the engram move)

A flat catalog doesn't scale: with dozens of skills, even one frontmatter line
each becomes a tax on every prompt. So skills belong to **groups**, and the
catalog renders in **three tiers** — the same graduated-rendering idea the context
engine uses for engrams (a spent block collapses to a summary; expand to see more):

```
stewards.skill_groups (
  slug        text PRIMARY KEY,    -- 'storytelling', 'tool-use', 'voice'
  name        text NOT NULL,
  summary     text NOT NULL,       -- ONE line; the tier-0 default ("the engram")
  applies_to  text,                -- agent_family glob; NULL=none
  active      boolean NOT NULL DEFAULT true
)
-- stewards.skills gains:  group_slug text REFERENCES stewards.skill_groups(slug)
```

| Tier | What's in the prompt | Cost | Lever to expand |
|------|----------------------|------|-----------------|
| **0 — group summary** (default) | one line per applicable *group* | ~N_groups lines | `skill_group_open(slug)` |
| **1 — skill frontmatter** (group opened) | the when-to-use line per skill *in that group* | ~N_skills_in_group lines | `skill_load(slug)` |
| **2 — skill body** (loaded) | the full instructions | the body's tokens | `skill_unload` / `skill_group_close` |

Default context cost is just the group summaries (a handful of lines) no matter how
large the library. The model **opens a group** when a task is in its territory (now
it sees that group's skills), then **loads** the one skill it needs. Closing a group
or unloading a skill collapses it back. Michael's framing exactly: an unneeded group
*is* engrammed down to its one-line summary; you can carry a lot of varied skills
across many tiers and still pay almost nothing until you reach for them.

Session state grows one table: `stewards.session_skill_groups (session_id, slug,
opened_at)` alongside `session_skills`. `compose_system_prompt` renders tier-0 for
all applicable groups, tier-1 for opened groups, tier-2 for loaded skills.

### Where this pays off (the first groups)

The richest near-term use is **persona craft**, especially the fiction/gamemaster
personas running D&D campaigns:

- **`storytelling` group** — `believable-villains` (motivation from the inside, no
  evil-for-evil's-sake), `therefore-but-not-and-then` (causal scene-to-scene
  momentum for a campaign), `character-voice` (distinct dialogue per NPC),
  `emotional-resonance`, `sacrifice-and-loss`. These already exist as harness-side
  `.claude/skills/*` — strong candidates to import as the first substrate skill
  group (see D5).
- **`tool-use` group** — how to use a given MCP/CLI/Docker tool well (the
  instruction layer Michael flagged: skills teach *how to wield* a capability; the
  grant gives the capability).
- **`voice` group** — prose/voicing guides (e.g. a persona's house style).

A gamemaster persona carries only the one-line "storytelling: narrative-craft
skills for scenes, villains, pacing" until a scene needs a villain — then it opens
the group and loads `believable-villains` for that beat.

### 2. The catalog — cheap, always visible

`compose_system_prompt` gains a **SKILLS** section listing the skills whose
`applies_to` matches the dispatched agent's family, one line each:

```
## Skills available (load on demand)
- redline: critique a draft against the panel rubric. Use when asked to review/redline a study.
- source-verification: read-before-quoting checklist. Use before citing any scripture/talk.
Call skill_load("<slug>") to pull in the full instructions; skill_unload("<slug>") to free the space when done.
```

Cost is ~1 line/skill. `auto_load` skills skip the catalog line and have their body
injected directly (for instructions an agent should *always* carry — the escape
hatch back to "baked into the prompt" when on-demand isn't wanted).

### 3. The levers — `skill_load` / `skill_unload` (the on/off)

Two tools, granted like any tool (`agent_tool_perms`), mirroring the context
levers:

- `skill_load(slug)` — mark the skill active in this session; its body is injected
  into the next compose. Refused (with the reason surfaced) if the slug is unknown,
  not applicable to this agent, or would push loaded-skill tokens over
  `skill_loaded_budget_tokens` (config) — the budget gate is what makes "save
  context space" real.
- `skill_unload(slug)` — deactivate; body dropped from the next compose.

Plus the **group** levers (tier-0 ↔ tier-1, §1b):
- `skill_group_open(slug)` — reveal a group's skills' frontmatter.
- `skill_group_close(slug)` — collapse the group back to its one-line summary.

Session state mirrors `session_facets`:

```
stewards.session_skills        (session_id text, slug text, loaded_at  timestamptz, PRIMARY KEY (session_id, slug))
stewards.session_skill_groups  (session_id text, slug text, opened_at  timestamptz, PRIMARY KEY (session_id, slug))
```

### 4. Body injection — the context-lever pattern

`compose_system_prompt` (or a late `compose_messages` section) injects the bodies
of the session's loaded skills under a **LOADED SKILLS** heading. Loading/unloading
is fully reversible — exactly how mute/pin/expand work on messages. A loaded skill
body is conceptually a *pinned* block; unloading is *muting* it.

### 5. Authoring — markdown + frontmatter → import

Skills are authored as `SKILL.md`-shaped files (frontmatter: `name`,
`description`, `applies_to`, `auto_load`; body below) and imported into
`stewards.skills` via `stewards-cli import --source skill:<dir>` (the same
importer pattern `.stewards/` uses for agents). This makes skills git-versioned,
diffable, and reviewable — and gives `.stewards/` a clear successor (see below).

### 6. compact_context integration (the read/write symmetry)

The `compact_context` judge already returns `{mute, compress, pin}` over a
session's messages. Extend its remit so it can also recommend **unloading a skill
that hasn't been used in the recent turns** — closing the loop: the same judge that
frees spent message-context also reclaims spent skill-context. (P2; the manual
`skill_unload` lever ships first.)

## What skills are NOT (the guardrails)

- **Not capabilities.** A skill is pure instruction text. It MUST NOT grant tools
  or change perms — that stays `agent_tool_perms`. No privilege escalation via a
  loaded skill. (A skill may *say* "use doc_search," but the agent only can if it's
  already granted.)
- **Not agent identity.** The base agent prompt remains the who/how; skills are
  optional procedure layered on top.
- **Not memory.** `session_facets` (CT2 self-notes) stay the durable per-persona
  memory; skills are curated, shared, read-only procedure.

## Critical analysis / open questions (for the council)

1. **Catalog token cost vs. body savings.** The catalog itself costs tokens (one
   line × N applicable skills). With a large library + loose `applies_to`, the
   catalog could rival what it saves. Mitigations: tight `applies_to` scoping,
   terse descriptions, and possibly a *semantic* catalog (only surface skills whose
   description embeds-near the current task) — but that adds a retrieval step.
   **Decision:** start with `applies_to` scoping only; revisit semantic surfacing
   if catalogs get long.
2. **Auto-unload policy.** Manual-only (Michael's "the model turns it on/off") is
   the P0. But models forget to clean up. Options for later: unload on compaction,
   TTL (N turns unused), or the compact_context judge (§6). **Decision:** P0 manual;
   P2 judge-driven.
3. **Loaded-skill budget + eviction.** If `skill_load` hits the budget, refuse vs.
   evict-oldest? Refuse is safer (no surprise context loss); evict is smoother.
   **Lean:** refuse + tell the model to unload something first.
4. **Who governs the library?** Skills are shared instruction — a bad skill
   misguides every agent that loads it. Authoring should go through the same review
   as agent prompts. Should personas be able to *write* skills (a `skill_propose`
   like `propose_prompt_change`, human-gated)? **Open** — default no; humans author.
5. **Overlap with `.github/skills` + `.claude/skills`.** Those are *harness-side*
   (Claude Code / Copilot) skills for the IDE agent. Substrate skills are for the
   *dispatched* agents/personas. Same idea, different runtime — keep them separate
   but consider a shared authoring format so a skill can target either.

## Phasing

- **P0 — the lever + the tiers work.** `stewards.skills` + `skill_groups` +
  `session_skills` + `session_skill_groups` tables; the 3-tier SKILLS catalog in
  `compose_system_prompt` (group summaries → opened-group frontmatter → loaded
  bodies); `skill_group_open/close` + `skill_load/unload` tools + the budget gate.
  Seed one group (e.g. `storytelling` with `believable-villains` +
  `therefore-but-not-and-then`), prove a gamemaster persona opens the group →
  loads a skill → uses it → collapses, with the token delta visible at each tier.
  virgin-smoke assertion.
- **P1 — authoring + import.** `SKILL.md` frontmatter format + `stewards-cli import
  --source skill:`. Migrate a real procedure (e.g. source-verification) to a skill.
- **P2 — judge integration.** compact_context can unload stale skills; optional TTL.
- **P3 — `.stewards/` succession.** If per-model agent tuning is still alive,
  reframe `.stewards/` as the skills-authoring dir; otherwise archive it.

## RATIFIED 2026-06-16 (Michael, via ask-tool)

- **D1** ✓ the shape (registry + catalog + load/unload + groups/tiers).
- **D2** ✓ manual on/off in P0; judge-driven unload P2.
- **D3** ✓ budget gate **refuses** a new load over budget (no surprise eviction).
- **D4** ✓ humans author skills in P0.
- **D5** ✓ shared `SKILL.md` format with the harness-side `.claude/.github` skills
  (write once, target either runtime).
- **D6** ✓ **groups + the 3-tier catalog ship in P0** (it's the context-savings value).

**Build note:** P0 is a new core chain file (`24-skills.sql`) — tables + the four
levers + the budget gate are clean/additive, but the catalog injection requires
**re-authoring `compose_system_prompt`** (the presiding-render fn, 16/ct2-7e
final) to add the SKILLS section (group summaries → opened-group frontmatter →
loaded bodies). That's a careful later-file-wins re-author + rebuild + virgin-smoke
+ the overlay-clobber-check — same discipline as 23-watchman. First group
(storytelling) = operator overlay, seeded from the D&D-transcript study.

## Decisions needed from Michael

- **D1** — ratify the shape (registry + catalog + load/unload lever + body inject).
- **D2** — manual on/off only for P0 (✓ per your ask), judge-driven unload deferred to P2?
- **D3** — budget-gate behavior: refuse (recommended) vs. evict-oldest.
- **D4** — humans-author-only for P0 (no persona `skill_propose` yet)?
- **D5** — shared authoring format with the harness-side `.claude/.github` skills, or substrate-only?
- **D6** — skill **groups + the 3-tier catalog** (§1b): in P0 (it's the whole
  "save more context" value, and the engram pattern is already proven in the
  context engine), or flat skills in P0 and groups in P1? **Lean:** groups in P0 —
  the tiering is cheap to build on top of the lever and is the reason the library
  can grow without taxing every prompt.
