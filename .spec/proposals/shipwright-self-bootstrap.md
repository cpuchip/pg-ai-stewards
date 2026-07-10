# The shipwright — self-bootstrap via a standing external seat

**Recorded 2026-07-09 from Michael's framing:** "pg-ai-stewards cannot bootstrap
itself… it becomes possible with a long-lived external loom that could run opus or
fable coordinating that upgrade." And the companion wish: "I normally leave you in
VS Code in a terminal, with remote control on, chatting from my phone — if we could
replicate that with loom over the mesh, that's it."

Status: PROPOSAL — council-gated (new standing capability). Nothing here is built.

## Why the substrate can't upgrade itself from inside

The walls are deliberate. The substrate runs inside the pg container: it cannot
rebuild its own image, cannot `--force-recreate` itself, and its coder sandboxes
are hardened away from the host Docker daemon on purpose. A system cannot hold the
ladder it is standing on. The wave-2 deploy (2026-07-09) is the proof-by-example:
every step ran from OUTSIDE — a Claude Code session on the host doing build →
verify → recreate → migrate → probe. Self-bootstrap therefore does not mean
removing the walls; it means giving the outside a standing, accountable body.

## The shipwright seat

A **long-lived loom-hosted seat on the host** (opus for routine runs; fable when
the upgrade needs judgment), with its own role home (CLAUDE.md + grounding +
resume), whose only stewardship is the upgrade dance. It takes work orders FROM
the substrate over A2A — the carrier already exists (`a2a_*`, Phase 1 live) — and
acts on the host with narrow grants: repo pull, docker build, compose recreate,
migrate.sh, verify-suite, health probes.

The flow, with the covenant intact:

1. Substrate (or Michael by voice/chat) files an upgrade work order: "upgrade live
   to main@<sha>."
2. Shipwright claims it, runs the GRINDABLE half unattended: fetch → build image →
   virgin-scratch verify-suite → migration-chain dry-walk → report.
3. **The gate:** results post to the bell (and ntfy #321 when built) — Michael
   sanctions the restart from his phone. The pg-restart rule stays exactly as it
   is: no live recreate outside his word. His two words (merge Hinge, restart
   sanction) are the same two words as the full-foreman night; only the mechanical
   hands change.
4. On sanction: `--force-recreate` → migrate.sh (ledger-walked) → version marker +
   health probes + streaming probes → receipt with the inverse-hypothesis evidence
   (old marker gone, new marker live). Rollback recipe pre-staged (previous image
   tag + down-migration note) BEFORE the recreate, not after.

**Grindability honesty (why the gate sits where it does):** build + verify on
scratch is grindable + oracled — automate hard, retry freely. The live recreate is
a one-shot state change — no oracle quality makes it grindable, so it stays on
Michael's cadence. The shipwright moves everything up to and after that moment;
the moment itself remains his.

## The mesh-remote convergence (the second wish)

The same seat pattern answers "leave VS Code": `loom serve` warm-resident on the
host (built, ~95% latency drop proven), reachable over the NetBird mesh, fronted
by the thin mobile chat (#332, already ratified "worth it"). Prereq: the **mTLS
build** — ratified in design, explicitly NOT green-lit to build; that green light
is its own council word. With it: a standing fable/opus seat he can chat with from
his phone, whose durable memory is the substrate, and whose visibility surface is
FLEET-GLASS (#367, Stewdio advanced mode — diffs + mid-thoughts + jump-in). VS
Code then becomes a preference, not a tether.

## Phases

- **P0 (this doc):** spec + the council moment. No build.
- **P1 — prove the dance, scripted:** encode wave-2's by-hand deploy as
  `scripts/upgrade-dance.sh` (or .ps1) with per-step oracles; I run it as the
  hands, from VS Code, on the next real upgrade. Zero new capability — same actor,
  same sanction, now deterministic.
- **P2 — the seat:** loom role home + warm-resident shipwright on the host; A2A
  work-order wiring; bell/ntfy sanction path. THIS is the dominion_in_council
  gate: a standing agent with docker/compose grants is a new body, not a new
  script.
- **P3 — mesh reach:** mTLS build (own green light) + #332 thin UI; the shipwright
  and the chat seat become reachable off-box.

## Council items (Michael's, explicitly)

1. Green-light P2's standing seat at all (a long-lived agent with host docker
   grants — the narrowest useful grant set to be enumerated at that council).
2. The mTLS build green light (standing prerequisite for anything mesh-reachable).
3. Whether the restart sanction may EVER be pre-delegated for a class of upgrades
   (e.g. verify-suite-green + additive-only migrations). Default and recommendation:
   no — keep the one-shot moment his, revisit only after the shipwright has a
   receipt history.

## What this is not

Not a removal of the container walls; not a self-merging substrate (PRs stay the
Hinge); not a replacement for the foreman pattern — the shipwright IS a foreman
worker whose unit happens to be "the ship itself," blind-checked by the same
oracles as everything else.
