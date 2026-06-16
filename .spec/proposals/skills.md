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

Session state mirrors `session_facets`:

```
stewards.session_skills (session_id text, slug text, loaded_at timestamptz,
                         PRIMARY KEY (session_id, slug))
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

- **P0 — the lever works.** `stewards.skills` + `session_skills` tables; the SKILLS
  catalog in `compose_system_prompt`; `skill_load`/`skill_unload` tools + the
  budget gate; body injection. Seed 1–2 skills, prove an agent loads → uses →
  unloads, with the token delta visible. virgin-smoke assertion.
- **P1 — authoring + import.** `SKILL.md` frontmatter format + `stewards-cli import
  --source skill:`. Migrate a real procedure (e.g. source-verification) to a skill.
- **P2 — judge integration.** compact_context can unload stale skills; optional TTL.
- **P3 — `.stewards/` succession.** If per-model agent tuning is still alive,
  reframe `.stewards/` as the skills-authoring dir; otherwise archive it.

## Decisions needed from Michael

- **D1** — ratify the shape (registry + catalog + load/unload lever + body inject).
- **D2** — manual on/off only for P0 (✓ per your ask), judge-driven unload deferred to P2?
- **D3** — budget-gate behavior: refuse (recommended) vs. evict-oldest.
- **D4** — humans-author-only for P0 (no persona `skill_propose` yet)?
- **D5** — shared authoring format with the harness-side `.claude/.github` skills, or substrate-only?
