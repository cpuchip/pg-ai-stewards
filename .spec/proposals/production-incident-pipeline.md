# The production-incident pipeline — assemble what we already own

**Recorded 2026-07-14 from the IndyDevDan "loops vs SDLC" digest** (private
workspace, `study/yt/VQy50fuxI34-indydevdan-loops-vs-sdlc.md`, steal #1): the one
clean gap that digest found is *"a production-incident pipeline we don't have
named yet."* We have every piece — Race, the Hinge, the coder sandbox, A2A
dispatch, the aborts table, per-app deploy oracles — but nothing wires them for
the specific shape *"prod is broken, right now."*

**Status: ★ RATIFIED 2026-07-14 (gate placement · spend cap · incident sources —
see §Ratifications) — UNBUILT.** Nothing here is built; the BUILD is the carry.
The pipeline is a new standing capability; the council moment has passed.

## The binding problem

When a production app breaks, the response today is ad-hoc: a human opens a
session, diagnoses, writes a fix, tests it, deploys it. The pieces to do this as a
*named pipeline* all exist and are proven separately — assembling them for the
incident case means one thing above all: **speed with the covenant intact.** A
hotfix pipeline that removes the human from the ship decision is fast and wrong;
one that gates every stage is safe and too slow to matter when prod is down. The
job is to place Michael's word at exactly the one boundary the covenant requires
and nowhere it only adds latency.

## The shape (five stages, each a normal pipeline stage)

An incident pipeline is just another `pipelines` row — a JSON list of stages
(`docs/anatomy-of-a-turn.md`); the machinery is identical to a persona turn or a
research run. The stages, with the grindability green-light called out per stage
(the twin test: *what's the oracle, and is it grindable?*):

1. **scout** — diagnose from logs + the code-graph, produce ONE narrow finding
   (the failing surface, the suspected cause, the blast radius). Read-only;
   grindable, side-effect-free. Oracle: the finding names a concrete file/endpoint
   the app owner can confirm.
2. **hotfix** — a narrow agent family (system prompt: *smallest possible change,
   get the fix out, not the fancy way*) drafts the patch in a `cmd/coder-mcp`
   hardened sandbox — the same clone→implement→verify loop as `code-pr`. Writes
   only to the sandbox clone; grindable + oracled (the app's tests run in-sandbox),
   zero production effect.
3. **race** — the shipped `loom race` shape verbatim (`loom race --contenders
   codex:gpt-5.6-terra,claude:sonnet --oracle "<cmd>"`, isolated dirs, `-oracle`
   REQUIRED, first oracle-passing contender wins, rest cancelled). Heterogeneous
   seats each attempt the narrow fix; the deterministic oracle names the winner.
   Grindable + oracled by construction — this is exactly what Race is for.
4. **★ the human gate** — the load-bearing boundary. See below.
5. **ship** — deploy per the target app's established deploy oracle (the
   `curl /version` / `GET /api/version` build-marker pattern; the substrate's own
   is `scripts/upgrade-dance.sh apply`). One-shot state change: NOT grindable, no
   oracle makes it so — therefore it sits AFTER the gate, always.

Everything in stages 1–3 is grindable + oracled + side-effect-free, so it runs
autonomously and fast. Only stage 5 touches the world.

## ★ The human gate — where Michael's word sits (the load-bearing question)

**Recommendation: one blocking gate, immediately before ship — and the front
boundary is his own hand, not a second pause.**

The reasoning is pure grindability, the same cut the shipwright makes: racing
candidate fixes is cheap, sandboxed, and reversible, so it needs no gate to *run*;
shipping one to production is one-shot and irreversible, so it is gated
*regardless of oracle quality*. One blocking pause, placed last — after the
winning fix and all its evidence are assembled, so his three-minute read is a real
read of a real artifact, not a preview of an intention.

Why not a second gate before the race (Dan's diagram puts the one gate there)?
Because **v1 acts only on explicit dispatch** (see Non-goals) — Michael *opens*
the incident and sets its spend cap, and that dispatch IS his authorization going
in; a second pre-race pause re-asks a question he just answered. To keep "watch
what you order" honest without it, **the scout's finding surfaces to him the moment
it lands** (non-blocking `a2a_note` / bell) so he can abort a mis-aimed race early
— the pipeline does not wait on it.

**What the gate surfaces** (so the read is a read, not a rubber stamp — modeled on
the `upgrade-dance.sh gate` preview and the Hinge Stewdio card):

- **The winning diff**, rendered to read — the actual smallest-change patch.
- **Oracle results** — which contender won, which of the app's checks (build /
  test / lint / the named deploy oracle) went green, and the losers' status, so he
  sees it was a real race.
- **A blast-radius estimate** — files touched, endpoints/services affected,
  migrations yes/no, and the pre-staged rollback recipe (staged BEFORE ship, per
  the shipwright rule).
- **The scout's finding** — the original narrow diagnosis, so he can judge whether
  the fix addresses the cause or a symptom.
- **The deploy oracle that will confirm the ship** — the exact `curl /version`
  check that will prove the new marker is live after his sanction.

Verdicts reuse the Hinge shape: **approve** (ship) / **revise** (back to hotfix
with a note) / **decline** (close, no ship). The ship itself routes through the
Hinge as a `cutover`-kind action — already `escalate-always` in `39-hinge.sql`, so
bounds and audit are shared, not reinvented.

## Reuse inventory (name the anchors — nothing new but the wiring)

- **hotfix drafting** — `cmd/coder-mcp` hardened sandbox + the `code-pr`
  clone→implement→verify loop (`.spec/proposals/loom-integration.md`).
- **race** — `loom race` (`cpuchip/loom` → `race.go`; `-oracle` required, isolated
  dirs, first-passing wins) + `duo`/`pair`, verbatim.
- **pipeline spine** — `spawn_subagent_create` → `work_item_dispatch_stage` →
  recorded `stage_results` (`docs/anatomy-of-a-turn.md`); the incident pipeline is
  one more `pipelines` row.
- **dispatch + the blocking gate** — A2A (`69-a2a-engine.sql`; `a2a_register/submit/
  claim/needs_input/answer/receipt`): `a2a_needs_input` marks the item
  `INPUT_REQUIRED`, `a2a_answer` resumes it — *already* "the Hinge as a first-class
  handoff state."
- **the ship sanction** — the Hinge (`39-hinge.sql` → `70-hinge-decouple.sql`;
  `hinge_escalate_always_kinds` already lists `cutover`) + the tool-effect gate
  (`.spec/proposals/hinge-and-escalation-ladder.md`); the wall is SQL, not prompt.
- **self-halt** — the aborts table (`work_item_abort_conditions` + the
  `steward_tick` sweep, v25/v33 war-game work, #331) arms per-incident conditions
  (spend cap hit, oracle never green after N, timeout) so a mis-aimed race stops
  instead of burning to the cap. Plus cost-cap quarantine (anatomy doc).
- **the deploy oracle** — per-app `curl /version` / `GET /api/version` build-marker;
  the substrate's own is `scripts/upgrade-dance.sh` (`docs/upgrade-dance.md`).

## Phases (each independently useful; the gate is real from P1)

- **P0 (this doc):** spec + the council moment. No build.
- **P1 — the pipeline, dispatch-only, single real incident:** register an
  `incident` pipeline family (scout → hotfix → race → gate → ship) and a `hotfix`
  agent family. Run it once, by hand, on ONE real broken app, gate included.
  Reuses shipped mechanisms end to end; the new part is the pipeline row + the
  narrow agent prompt.
- **P2 — the gate surface:** render the five-part gate card in Stewdio with
  approve/revise/decline. Until P2 it degrades to an `INPUT_REQUIRED` note + bell
  (never silent).
- **P3 — arm aborts + a per-app deploy-oracle registry:** per-incident abort
  conditions, and a small table mapping target-app → deploy oracle + rollback
  recipe, so ship is app-agnostic.

## Non-goals (explicit)

- **No auto-trigger / standing watcher in v1.** The pipeline acts ONLY on explicit
  dispatch. A watcher that opens incidents on its own is a new autonomous loop —
  its own council, not this one.
- **No factory-router.** Reading a ticket cold and auto-selecting the incident
  pipeline is parked (same digest, steal #3: real blast radius, bin-3
  surface-first).
- **No new model seats.** Race reuses the existing loom-configured foreman pool.
- **No delegated ship sanction.** The autopilot/loom-Opus Hinge
  (`hinge-and-escalation-ladder.md` Piece 4) is a separate council-gated item; the
  incident ship gate stays Michael's, full stop.

## What this is not

Not a removal of the container walls; not a self-deploying substrate (ship stays
the Hinge); not a replacement for the foreman pattern — the incident pipeline IS a
foreman shape whose unit is "a broken production app," sharing the shipwright's
exact spine (grindable half runs free; the one-shot moment stays Michael's)
pointed at a different target.

## Open questions for Michael (the forks — his ruling before build)

1. **Gate placement** (the load-bearing one). Recommendation above: ONE blocking
   gate before ship; the dispatch is the front authorization; scout finding
   surfaced non-blocking. Alternative he may prefer: a second *blocking* pre-race
   gate (Dan's placement) if he wants to sanction the spend before N seats race,
   accepting the latency. **Lean: single ship-gate.**
2. **What counts as an "incident" source in v1** — Michael's word only, or may a
   trusted seat file an incident over A2A (e.g. the shipwright noticing a failed
   health probe)? Either way the SHIP gate stays his — an agent may *open* an
   incident, only Michael *closes* it to prod. **Lean: allow A2A-filed incidents;
   the gate is the real control, so the source can be wider.**
3. **Spend cap per incident** — the ceiling on racing N heterogeneous full-harness
   seats (`loom race` ran ~$0.19/contender on a trivial task; real multi-file fixes
   cost more). The aborts table enforces whatever number he picks. **Needs a
   number — no lean; his call.**


## Ratifications (2026-07-14, Michael)

1. **Gate placement — RATIFIED:** one blocking gate, immediately before ship.
2. **Spend cap — RATIFIED as config:** `incident_spend_cap` is instance
   configuration, fillable by whoever installs an OSS pg-ai-stewards (no
   hardcoded number). This instance sets **$10/incident** for pay-per-use
   seats; Claude Code seats are exempt (subscription-based — bounded by the
   sub, not dollars).
3. **Incident sources — ★ RATIFIED 2026-07-14** ("yes incident sources yes, it makes sense now"): Clarified reading: v1 sources =
   Michael's word (dispatch) + A2A-filed by ALREADY-GRANTED seats; only
   Michael closes an incident to prod (the ship gate). Narrow ON PURPOSE:
   anything watching-and-auto-filing (health probes, deploy oracles) is a
   standing autonomous loop = the parked capability class; the named widening
   path is v2 after fleet-glass (#367) exists, back through council.
