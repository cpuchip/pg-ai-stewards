# The Tool Shelf — progressive disclosure for tools

**Status:** **RATIFIED in council 2026-06-27 (probe-first).** Build proceeds per the ruling below.
**Date:** 2026-06-27.
**Touches:** `compose_tools` (a core dispatch path) → wants a council read first.
**Relation:** finishes what `37-tool-groups.sql` started; mirrors `24-skills.sql` exactly.

## Council ruling (2026-06-27)

Ratified the design as written (§4), with one amendment and the four questions (§9) answered:

- **Probe-first amendment.** Insert **P0.5 — an adoption probe** between P0 (build mechanism) and
  P1 (assign groups + flip on). The shelf exists for the *local* model (the 156-tool dump wedged the
  local MoE, not a cloud model), but the local model is also the one most likely to fail the
  open-the-right-group behavior. So measure before committing. **★ The probe is cheap because the
  proxy already ships:** the **skills shelf** (`skill_group_open`/`skill_load`) is progressive
  disclosure in production — so "do local models reach for an on-demand load tool?" is answerable from
  the ledger *today*. (That telemetry pass is running as of this ruling; it doubles as the answer to
  "are the context-management tools used at all?")
- **Q1 always-open floor — yes, as a flag.** `always_open boolean` on `tool_groups`; default floor =
  search/doc/context/productivity. Operator tunes membership.
- **Q2 group-level only for P0 — yes.** Per-tool `tool_load` deferred (likely never needed).
- **Q3 P3 auto-opener (the "tools engram") — timing set by the probe.** If local self-opens reliably →
  P3 stays a future nicety. If not → P3 (embed+RRF pre-open top-N groups) becomes load-bearing and
  ships *with* P0, not after.
- **Q4 membership in the overlay — yes.** Core ships mechanism + flag-off + a generic group set.
- **Michael's steer:** current models are generally capable tool-callers, so the probe is expected to
  greenlight the *manual* shelf (no auto-opener needed) — but we test rather than assume.

## Probe RESULT + the revised P0 (2026-06-28) — GREENLIT

The P0.5 probe ran as a standalone harness (`scratchpad/shelf_probe.py`): the work-corpus research-draft
task, **157 tools folded** to a name+purpose catalog + a `reveal_tool(name)` lever + a note, driving
the **local** models against the live corpus. Result:

| model | opened the right tools? | completed the task? |
|---|---|---|
| `qwen3.6-35b-a3b` | ✅ turn 1, 0 misses; **100% of 33 calls on revealed tools** | ✗ — its *known* over-gather (not the shelf); never committed |
| `gemma-4-26b-a4b` | ✅ (1 stray, self-corrected) | ✅ grounded answer, `finish=stop`, 4 calls |

**Findings (these supersede Q1/Q2/Q3 above):**
1. **The manual shelf works on local models** — decisively. The `skill_group_open=0` telemetry was the
   confound we suspected (skills autoload, so nobody manually opens); with a *real* fold + a clear note,
   both models reach for the lever correctly.
2. **Per-tool `reveal_tool(name)` is the granularity** (not `tool_group_open(group)`) — the named reflex
   the telemetry favored, now confirmed. **Supersedes Q2's group-level answer.**
3. **Default-fold EVERYTHING works** — the probe folded all 157 with no always-open core and the model
   still opened the right tools. **Supersedes Q1's "always-open floor"** — the floor shrinks to just the
   shelf-management levers (`reveal_tool`/`pin_tool`/`unpin_tool`); everything else folds by default.
4. **The fold degrades gracefully** — gemma's one stray reveal cost a single call and self-corrected.
5. **P3 auto-opener NOT needed** (Q3 resolved) — the manual shelf earns its keep.
6. qwen's non-completion is its documented over-gather (force-final / route-to-gemma already handle it),
   orthogonal to the shelf — gemma completing the identical setup proves it.

### The revised P0 design (Michael, 2026-06-28) — the self-folding shelf
An LRU cache for tool schemas: **the tools put themselves away.**
- **Default-fold all.** Flag `tool_shelf_enabled` (config, default **false**). When on: every tool folds
  to the catalog; only `reveal_tool` / `pin_tool` / `unpin_tool` are always present.
- **Catalog** (`<folded_tools>` block): every tool name + one-line purpose + "`reveal_tool(name)` to load."
- **`reveal_tool(name)`** loads a tool's full schema for the session (a `session_tool_reveals` row).
- **★ Cooldown auto-refold.** A revealed tool not *used* within the last N tool-call rounds
  (config `tool_shelf_cooldown`, default 4) **auto-folds** — its schema drops, the catalog line stays.
  Inferred from recent `messages.tool_calls` (no separate write path). Keeps the open set tiny over a
  long task without the model curating it.
- **`pin_tool(name)` / `unpin_tool(name)`** — pin exempts a tool from the cooldown (stays open); the
  model pins what it'll reuse.
- **Composition** lives at the dispatch body-builder chokepoint (gated on the flag); **flag-off ⇒
  byte-for-byte today's path** (the load-bearing oracle assert).

### Build plan (incremental, each tested)
- **P0a — the core fold:** `session_tool_reveals` + `reveal_tool` + catalog render + open-schema render
  + the flag. Test: real dispatch through the substrate with the flag on (re-run the probe task on the
  *real* path, not the harness). This is the proven core.
- **P0b — self-folding:** the cooldown auto-refold + `pin_tool`/`unpin_tool`. Test: a long run shows
  idle tools re-folding and the open set staying small.

---

## 1. The problem (with live numbers)

`compose_tools` is a **deny-list**: every active tool ships on every dispatch unless the agent's
family explicitly denies it. Measured on the live dev substrate (2026-06-27):

| agent family | tools shipped | scoped? |
|---|---|---|
| `reflect-research` | **179** | ❌ full dump |
| `research` (ad-hoc / interactive) | **156** | ❌ |
| `research` (inside a `tool_groups` pipeline stage) | ~10–26 | ✅ via 37 |
| `stewards-explore` | 59 | ❌ |
| `persona` | 36 | ❌ |
| `work-item-chat` | 16 | hand-trimmed |

A research GATHER turn once shipped a **54k-token prompt that was mostly tool `args_schema`** — the
load that wedged the local MoE (memory: the 159-tool gather). The schemas are the cost: a tool's name
+ one-line description is cheap; its full JSON-Schema `args_schema` is not, and the model pays for all
of them on every turn whether it calls them or not.

## 2. The research that points the way

Google's *New SDLC with Vibe Coding* (Day 1, "Context Engineering — Static vs. Dynamic", Fig. 4) names
the pattern, verbatim:

> "Agent Skills allow the agent to remain a lightweight generalist that flexes into specialist roles
> **on demand through progressive disclosure**. The agent sees only lightweight metadata at startup,
> loads full instructions when a task matches, and pulls deep reference material only when explicitly
> needed. The result is that an agent can carry **dozens of specialized capabilities while paying the
> token cost for only the one it is actively using.**"

The substrate **already does this for skills** — the 3-tier shelf in `24-skills.sql`
(group summaries → `skill_group_open` → `skill_load` the body), finalized in `65`. A tool schema is
just procedural knowledge with a token cost, the same as a skill. **The insight is to do the identical
thing to tools.**

## 3. What exists today — the asymmetry

|  | progressive disclosure? | how |
|---|---|---|
| **Skills** | ✅ yes | `skill_groups`/`session_skill_groups`/`session_skills` + `skill_group_open`/`_close`/`skill_load`/`_unload`; `render_skills_block` renders catalog (closed) vs opened vs standing |
| **Tools** | ❌ **no** | `37-tool-groups` does **static** per-pipeline-stage scoping — `compose_tools_scoped(family, session_tool_scope(session))`. The set is fixed at dispatch; the agent can't reveal more mid-session, and even a scoped stage hands over every in-scope tool's full schema up front. |

`37` is the **first half** of "do to tools what we do to skills": it narrows the *universe* per stage.
It is missing the **dynamic half**: the agent seeing lightweight tool metadata and pulling a tool
group's schemas *when the task matches*. That dynamic half is this spec.

## 4. Design — the Tool Shelf (mirror the skills mechanism)

The whole point is symmetry: build for tools the exact shape `24-skills.sql` built for skills, reusing
the `tool_groups` table that `37` already ships.

### 4.1 State (one new table)
- `stewards.tool_groups` — **already exists** (37): `name`, `description`, `tool_patterns[]`.
- **NEW** `stewards.session_tool_groups (session_id text, name text, opened_at timestamptz)` — which
  tool groups are *open* in a session. Exact mirror of `session_skill_groups`.

### 4.2 Levers (two new tool_defs, gated like the skill levers)
- `tool_group_open(name text)` — reveal a group's full tool schemas for this session. Mirror of
  `skill_group_open`.
- `tool_group_close(name text)` — collapse a group back to its catalog line. Mirror of
  `skill_group_close`.

(Group-level granularity matches skills' group/body split and keeps it simple; a per-tool
`tool_load` is possible later but not in P0 — a group is the natural unit, and `tool_patterns` already
defines it.)

### 4.3 Rendering (re-author `compose_tools` once more, later-file-wins)
`compose_tools` returns the OpenAI `tools` array. Under the shelf it renders three tiers, mirroring
`render_skills_block`:

- **Always-open (standing):** tools in NO group, plus any group flagged `always_open`. Full schemas.
  This is the safety floor — the essential core (search, doc, context, productivity) is never hidden.
- **Opened groups:** full schemas for every group in `session_tool_groups`.
- **Closed groups (the catalog):** a single lightweight line per unopened group — `name`,
  `description`, and the **tool names** it contains, plus `tool_group_open("<name>") to load its N
  tools`. Names only; **no `args_schema`** (that's the saving).

So the research agent's startup payload becomes ~the always-open core + a dozen one-line group
summaries, and it opens (say) `web-research` when it needs to search — paying for those 8 schemas, not
all 156.

### 4.4 Composition with `37` (they stack, not fight)
`37`'s static stage scope sets the **universe** a stage may see; the shelf governs **which of that
universe is open**. `compose_tools_scoped` already narrows by stage; the shelf's closed/open split
applies *within* whatever set `compose_tools` returns. A pipeline stage that wants the old static
behavior keeps declaring `tool_groups` and (optionally) marks them pre-opened. Nothing about `37`'s 12
adopted stages has to change.

### 4.5 Default-off rollout (the conservative path)
A config flag `tool_shelf_enabled` (default **false** in core, like `auto_critique` / context tools).
- **OFF:** `compose_tools` behaves exactly as today (full set, or `37`-scoped). Zero behavior change.
- **ON:** grouped tools start **closed**; ungrouped/always-open stay standing; the agent opens what it
  needs. Operators flip it per overlay once they've tuned their groups.

## 5. The adoption risk (the one that actually matters)

A schema the model can't see, it can't call — so the shelf only works if the model reliably **opens
the right group**. This is the same problem `30-tool-primers` solved for native tools (surfacing ≠
adoption). Mitigations, in order:
1. **Keep the essentials always-open.** Search/doc/context/productivity never go in a closed group, so
   a model that opens *nothing* can still do the common path. The shelf hides the long tail (coder,
   dnd, gospel, image-gen, publishing), not the daily drivers.
2. **A primer** (`30`-style) teaching the open-then-use loop, gated on the shelf flag.
3. **A self-naming catalog.** The closed line lists the tool *names*, so the model can pick the right
   group in one shot ("I need `web_search` → open `web-research`").
4. **Measure before widening.** Start with only the heavy domain groups closed on `reflect-research` /
   `research`; watch trajectory critic for "wanted a tool it didn't open" before closing more.

If adoption proves weak on a given model, the fallback is graceful: that operator leaves the flag off,
or marks more groups `always_open` — it degrades to today's behavior, never to a broken toolbox.

## 6. Phasing

- **P0 — mechanism.** `session_tool_groups` table + `tool_group_open/close` tool_defs +
  re-author `compose_tools` for the three tiers + `tool_shelf_enabled` flag (default off) +
  `always_open` on `tool_groups`. Virgin-smoke `OK 67` (below). No behavior change while the flag is
  off.
- **P1 — assign the groups.** Put the long-tail domain tools into closed groups; keep the core
  always-open. Pure data (`tool_groups` rows). Flip the flag on dev, measure the token drop on
  `research`/`reflect-research`.
- **P2 — the primer + the watch.** Ship the shelf primer; run a handful of real gathers on dev with
  the trajectory critic watching for missed-open events; tune group membership.
- **P3 (optional, later) — the auto-opener.** The "tools engram": embed the task + each tool group's
  description, `embed_query` + RRF-rank, and pre-open the top-N groups for the agent (so it doesn't
  even have to ask). This is the fancier selector; the shelf is the floor it sits on, and the search
  RRF work (71–73) is the infra it would reuse. Explicitly **out of P0–P2**; named here so the shelf is
  built to admit it.

## 7. Risks & tensions (council fodder)

- **An extra round-trip.** Opening a group costs one turn. But the catalog names the tools, so it's a
  one-shot open, and one turn is cheap against a 40k-token-per-turn schema tax across a multi-round
  gather. Net win grows with conversation length.
- **`compose_tools` is hot and core.** Re-authoring it touches every dispatch. Mitigation: flag-gated
  (off = byte-for-byte today's path), and the oracle proves the off-path is unchanged.
- **Cross-surface reach.** Skills' levers are gated on the `skill` perm + having a surface; the tool
  levers should gate on a parallel condition (shelf enabled + the agent having a closed group), so a
  tools-off one-shot judge/critic never sees them. Mirror `24`'s gating exactly.
- **Eval-gaming guard:** N/A — this changes no grader/critic/gate; it only changes which tool *schemas*
  are visible. (Worth stating so the council sees it was checked.)

## 8. How to verify (the oracle)

Virgin-smoke `OK 67`, deterministic, with the inverse hypothesis:
- **flag OFF ⇒ unchanged.** `compose_tools(family)` returns the identical set with the shelf disabled
  (the backward-compat assert — the load-bearing one).
- **flag ON, closed by default.** A grouped tool's full schema is ABSENT from the startup payload; its
  group appears as a catalog line naming it.
- **open reveals.** After `tool_group_open('g')` (writes `session_tool_groups`), that group's full
  schemas are PRESENT; **inverse hypothesis:** `tool_group_close('g')` → schemas gone again.
- **always-open floor.** An ungrouped / `always_open` tool's schema is present regardless of opens.
- Standard chain hygiene: new file `extension/76-*.sql` (or next free number) registered in `lib.rs`
  (`requires` the current head) + added to the `Dockerfile` COPY list + fresh-image virgin-smoke green
  end-to-end before any push. `go build`/`vet` unaffected (SQL-only expected).

## 9. Open questions for council

1. **Default group membership.** Which tools are "always-open core" vs "closed long-tail"? Proposed
   floor: search/doc/context/productivity always-open; coder/dnd/gospel/image/publishing closed.
   (P1 data, but the council should bless the principle.)
2. **Group granularity vs. per-tool load.** Group-level only (P0), or also a per-tool `tool_load` for
   surgical reveals? Recommendation: group-only first; revisit if real use wants finer.
3. **P3 auto-opener now or later?** Recommendation: later — prove the manual shelf earns its keep
   first; the RRF infra isn't going anywhere.
4. **Where the flag/membership live.** Core ships the mechanism + flag-off + a generic group set; the
   operator tunes membership in their overlay (config-as-code), same split as everything else.

---

*One line of provenance:* this is the **dynamic** half of `37`'s static scoping, the **tool** twin of
`24`'s skill shelf, and the **named realization** of Google's progressive-disclosure pattern — three
witnesses to one move. The substrate stays a lightweight generalist that flexes into a specialist on
demand, paying only for the capability it is using.
