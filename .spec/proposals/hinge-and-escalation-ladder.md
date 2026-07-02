# The Hinge tool + the escalation ladder — SPEC (not built)

**Status: SPEC, awaiting Michael's ratify. Do NOT build off this yet.** Drafted
2026-07-02 from Michael's design + a video study (Nate B Jones "OpenBrain" / the
Lemonade send-without-approval story) that surfaced the trigger gap. This unifies
primitives the substrate ALREADY has; it is mostly wiring + one new interceptor +
one autopilot upgrade, not a greenfield system.

## The problem, in one story

Nate's cautionary tale: an insurance agent drafted a reply the human explicitly did
**not** approve — and the agent sent it anyway. Mapped to the substrate: once a tool
is granted in `agent_tool_perms` (deny-by-default, but binary), invocation is
**unconditional**. There is no tier between "no tool" and "fires the instant it's
called." Today the draft-vs-send line is held only by *never granting* the dangerous
tool, or by trusting the agent to voluntarily call `a2a_needs_input`. A misfiring
agent with a granted `send_email`-shaped tool reproduces the Lemonade failure exactly.

Michael's framing turns the fix into a general capability: a **Hinge tool** the agent
calls when it needs input, surfaced as a Stewdio card/dialog (or on the work item when
Stewdio isn't open); an **`ask_up`** variant that lets a weaker model consult a
stronger one; and an **autopilot** mode where the Hinge role itself is delegated to a
well-contexted Opus session via loom.

## What already exists (build on this, don't reinvent)

- **`39-hinge.sql` — the Hinge review queue WITH bounds.** `hinge_enqueue(kind,
  subject, payload, proposer)` → `hinge_pending` worklist → `hinge_record_verdict`,
  which **enforces D&C 121 in SQL**: a verdict only sticks as `approved` if the kind
  is in config `hinge_auto_approve_kinds` (default `[]`) AND not in
  `hinge_escalate_always_kinds` (default `cutover / new-pipeline / new-capability /
  spend-increase / schedule-change`) — otherwise it `escalated`s to Michael. The
  reviewer is a `claude -p` process (`scripts/hinge-review`) or Michael. **This is the
  spine of the whole ladder.** The autopilot Michael wants is largely "upgrade this
  reviewer."
- **`a2a_needs_input` (69-a2a-engine.sql) — the human ask.** Marks a claimed work item
  `INPUT_REQUIRED`, stores the exact blocking question, drops a question-note in the
  owner's inbox; `a2a_answer` resumes it. `INPUT_REQUIRED` is already "the Hinge, as a
  first-class handoff state" (its own comment). This IS `ask` — it just surfaces as an
  inbox note today, not a card.
- **`model_escalation` (06-cost.sql)** + model aliases/tiers (19-models, #186) + the
  in-loop alias failover (#243). The plumbing `ask_up` routes over.
- **loom** (`cpuchip/loom`) — drives a persistent, contexted Claude Code session as a
  worker. The vehicle for the autopilot Opus-Hinge.

So: the queue exists, the human-ask exists, the bounds exist, the model-tier plumbing
exists, and the harness for an Opus-Hinge exists. The spec connects them and adds the
missing **trigger**.

## The escalation ladder (the unifying frame)

When an agent reaches a decision it shouldn't make alone, it escalates up a ladder of
increasing authority and cost. The rung is chosen by the situation, not the agent's mood:

```
  0. self            decide and act                         default, free
  1. ask_up          consult a STRONGER model, then decide  cheap, NO authority transfer
  2. ask  (human)    request Michael's input/approval        blocks; Stewdio card / work-item
  3. tool-effect gate a dangerous tool call is INTERCEPTED   structural; forces rung 2 (or 4)
  4. autopilot       the Hinge role → loom-Opus, in bounds   council-gated; out-of-bounds → 2
```

Rungs 2–4 all flow through the **one** `39-hinge` queue, so bounds, escalation, and
audit are shared, not re-implemented per feature.

## Piece 1 — the tool-effect gate (the TRIGGER) · NEW

The only genuinely new mechanism. Add to tool definitions an **`effect_class`** (e.g.
`read` | `write_local` | `external_send` | `irreversible` | `financial`) and a derived
**`requires_confirmation`** flag. In the dispatch loop, before executing a tool whose
class requires confirmation:

1. Do NOT execute. Serialize the drafted call (tool + args) into the work item.
2. `hinge_enqueue(kind => 'tool-confirm', subject => '<tool> on <target>', payload =>
   {drafted_call, work_item, agent})`.
3. Mark the work item `INPUT_REQUIRED` (reuse `a2a_needs_input`'s state) and pause the
   loop.
4. On `approved` (rung 2 human, or rung 4 autopilot-in-bounds) → execute the *stored*
   call verbatim and resume. On `revise`/`declined` → return the verdict to the agent
   as a tool result ("send withheld: <reason>") so it can adapt.

This is the substrate's own **"bound structurally, not behaviorally"** principle
(`docs/delegation-limits.md`, same as spawn depth/width). Crucially it is
**model-independent**: the gate fires no matter which model drives, so it is a *better*
fix than the video's own answer (an LLM intent-classifier "auto-review" — the same
judgment-based class that FAILED in the Lemonade story). It also closes the `ask_up`
loophole: a weak model cannot ask a strong model "should I send?" to bypass the gate —
the gate is not a decision the models make, it is a wall the dispatch loop enforces.

Default posture: `tool-confirm` is in `hinge_escalate_always_kinds` until Michael grants
otherwise, so a fresh install always routes external sends to the human.

## Piece 2 — the `ask` tool + Stewdio surface

Generalize `a2a_needs_input` into a first-class **`ask(question, [options], [context])`**
tool any agent can call (not only inside an a2a work item). It enqueues to the Hinge
queue (`kind => 'ask'`) and surfaces on a ladder of visibility:

- **Stewdio open on this work item** → a **card/dialog** in the chat stream: the
  question, optional quick-reply buttons (the `options`), a free-text answer, and for a
  `tool-confirm` the drafted call rendered for approve/deny/edit. (Michael: "pops a
  dialog or a card.")
- **Stewdio open elsewhere** → a badge/toast + an entry in a "Needs you" tray (the
  existing escalation surface), click-through to the item.
- **Stewdio not open** → the work-item annotation + a **notification** (the deferred
  shared notify service — this is a concrete near-term consumer of it). Michael answers
  async; `a2a_answer` resumes.

The point Michael named: the ask must be visible *somewhere the human will see it* — the
surface degrades from live card → tray → notification, never silently strands.

## Piece 3 — `ask_up` (model-tier consult) · low risk, no council

**`ask_up(question, [min_tier])`**: the current (often weak/local) model consults a
STRONGER model and gets the answer back to reason with — it does NOT hand off authority
or produce a side effect. The answer returns as a tool result; the asking agent still
decides and still hits the tool-effect gate for anything dangerous.

**★ The escalation ladder is DATA, not hardcode (Michael, 2026-07-02).** Not everyone
has Opus to stand in as their Hinge — and we might want a *Fable* hinge now that it's
available. So the model order lives in a table that can grow or shrink:

```sql
CREATE TABLE stewards.escalation_ladder (
    rung        int  PRIMARY KEY,          -- 1 = weakest … N = strongest
    model_alias text NOT NULL,             -- resolves via 19-models aliases (BYO models)
    role_hint   text,                      -- e.g. 'local-doer', 'consult', 'hinge'
    enabled     boolean NOT NULL DEFAULT true
);
```

Resolution: when an ask comes in, find the CALLER's rung (its model alias → ladder
position; unlisted → rung 0) and route to the next enabled rung above (or the first
rung ≥ `min_tier`). The TOP enabled rung is the default **hinge model** — whoever the
operator has: Opus, Fable, a strong local MoE, anything. Adopters edit rows, not code;
`ask_up` and the autopilot reviewer both resolve from the same ladder, so "which model
is my hinge" is one UPDATE. (Same genericity constraint as the loom hub: no model
name hardcoded in the mechanism — ours is just one configuration of it.) A seed
migration inserts a sensible default ladder from the models the install has wired;
`model_escalation` (06-cost) keeps its role as the per-call failover, distinct from
this authority ladder.

Because it transfers no authority and causes no external effect, `ask_up` is **safe
autonomous** (bins 1–2) — gated only by cost/budget, not by council. It is the cheap
rung that should absorb most "this is hard" moments before they reach the human. (It is
NOT a substitute for rung 2/3 — see the loophole note in Piece 1.)

## Piece 4 — autopilot: the Hinge role → loom-Opus · council-gated

Today `39-hinge`'s reviewer is a `claude -p` one-shot. Autopilot **upgrades the reviewer
to a persistent, properly-contexted Opus session driven by loom** — Michael's "hinge all
of that to Opus through loom (with proper context to actually be the hinge)." The
requirements that make it safe:

- **Proper context (load-bearing).** The Opus-Hinge is opened with the full Hinge
  context, not a thin prompt: `intent.yaml`, `covenant.yaml` (esp. `presiding`), the
  Michael-profile decision-oracle, the work item's history, and the specific gate's
  criteria. A Hinge without the context isn't a Hinge — it's a rubber stamp. This is
  exactly what loom's `--mcp-config` + `--claude-home` + `--system-prompt-file` +
  persistent stream-json session provide; the warm-resident keeps it cheap.
- **Bounds are the EXISTING SQL wall.** The Opus-Hinge calls `hinge_record_verdict` like
  any reviewer; `hinge_auto_approve_kinds` / `hinge_escalate_always_kinds` still gate it.
  It can only auto-approve kinds Michael granted in council; `tool-confirm` /
  `external_send` / `financial` stay escalate-always unless explicitly granted per kind.
- **Accountable + reversible.** Every autopilot verdict is logged (reviewer=
  `loom-opus-hinge`, reason recorded) and, per the presiding covenant, emergency/edge
  decisions are accounted the same session. Autopilot is a config toggle Michael flips;
  off by default.

**This is a `dominion_in_council` new standing capability** — delegating the Hinge/merge
authority to an AI reviewer for a class of decisions. It requires a council moment with
Michael to grant, per kind, and the escalate-always wall is the standing floor it can
never cross. Build LAST, behind the safety floor.

## Covenant / D&C 121 read

`39-hinge` already embodies the presiding doctrine: delegated dominion within
council-granted bounds, escalation outside them, enforced in SQL not prompt. The ladder
extends it consistently:

- `ask_up` — no authority transfer, no council (asking a smarter peer).
- `ask` / tool-effect gate — routes authority TO the human; strengthens the human Hinge.
- autopilot — transfers a bounded slice of Hinge authority to loom-Opus; council-gated
  per kind; the escalate-always kinds are the permanent human reservation; every
  decision accounted same-session.

The tool-effect gate is a pure safety add (it can only *add* a pause, never remove one),
so it needs no new grant — it's the floor everything else stands on.

## Build phases (NOT tonight)

1. **Tool-effect gate + `ask`-to-human** — the safety floor. `effect_class` on tool
   defs, the dispatch interceptor, enqueue `tool-confirm`, reuse `INPUT_REQUIRED`, a
   Stewdio approve/deny card. No new authority granted (everything escalates to Michael).
   Oracle: a tagged tool call in a scratch container must NOT execute until an approval
   row lands; inverse — an untagged tool still fires unconfirmed.
2. **`ask_up`** — model-tier consult over the alias/tier system + budget guard. Oracle:
   a weak-model consult resolves a stronger model and returns its answer; no side effect.
3. **Stewdio surface polish** — live card ↔ tray ↔ notification degradation; wire the
   notify service.
4. **Autopilot (loom-Opus Hinge)** — council-gated. The contexted Opus reviewer draining
   `hinge_pending` within granted bounds; out-of-bounds → Michael. Oracle: an
   out-of-bounds kind escalates to the human even when the Opus-Hinge votes approve
   (the `39-hinge` bounds test, extended to the loom reviewer).

## Open questions for Michael (the forks)

1. **`effect_class` source of truth** — hand-tag tools in `tool_defs`, or infer from MCP
   tool metadata / name heuristics with a manual override? (Lean: explicit tag column,
   deny-to-safe on unknown.)
2. **`ask` vs `a2a_needs_input`** — one generalized tool with an optional work-item, or
   keep `a2a_needs_input` for the engine flow and add `ask` for free-standing? (Lean:
   one tool, work-item optional.)
3. **Autopilot scope** — which kinds may loom-Opus ever auto-approve (grant list), and
   does `tool-confirm` for `external_send` EVER leave escalate-always? (Council.)
4. **Notify dependency** — does Phase 3 wait on the shared notify service, or ship with
   Stewdio-only surfacing first?
```
