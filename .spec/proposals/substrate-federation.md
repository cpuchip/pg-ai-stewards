# Substrate federation — pg-ai-stewards talking to pg-ai-stewards

**Michael's vision (2026-07-14):** *"I want to get pg-ai-stewards communicating
with pg-ai-stewards, so work can stay work, and we can — or loom, or our
pg-ai-stewards — talk to my work instance."*

**Origin.** Today the personal instance was purged of its work pool — dozens of
docs, hundreds of engram embeddings, a hundred-plus work items, and an imported
graph of a work platform — dumped (full pg_dump, verified, held privately for
work-side import) and deleted, because work content must not live in the personal
instance. Federation is how work comes *back into reach*: as a **remote peer**,
never as local rows. The editorial wall — never work/client content in personal or
public spaces — stops being only a publishing rule and becomes a **federation
boundary property** of the peer link.

**Status: DRAFT — awaiting Michael's ratification (draft-first, council-gated).**
Federation is a new standing capability class, and a data boundary is a one-way
door (once a link leaks, it has leaked). Nothing here is built. §7 is the council
moment.

---

## 1. Binding problem

Work content must not live in the personal instance — proven today by having to
purge it — yet work must stay *reachable*. The human is currently the only path
between his personal AI and his work AI: the copy-paste hallway. Federation must
let two pg-ai-stewards instances hand work to each other **without the work
instance's corpus ever replicating home**, and without the human carrying state.

Trace every decision below to this: *work stays work; only envelopes cross;
identity is established at the door, not asserted; the gate fails closed.*

## 2. What we already own (real surfaces, verified)

- **The A2A engine** (`extension/v13-a2a.sql`, live single-instance): `a2a_agents`
  (registry — `kind` includes `external`, `endpoint` for webhook delivery,
  `token_hash` for external auth, and **`scope` jsonb = "the D&C 121 wall: which
  projects/intents/tools this agent may touch"**), the assigned-work_item handoff
  (`a2a_assignee`/`a2a_owner`/`a2a_question`), and verbs `a2a_submit / inbox / claim
  / needs_input / answer / receipt / note`. The cross-agent loop already exists — it
  just terminates inside one instance.
- **The A2A proposal's Phase 3** (private workspace `.spec/proposals/a2a-open-engine.md`
  §5, §7): "outside / other people" over a mesh + minted tokens; trust model *"you
  cannot assume trust by proximity"*; scope = the wall; receipts = the accounting.
  Federation *is* Phase 3, narrowed to Michael's own two instances.
- **The wall theology** (private workspace `study/ai/stewardship-consecration-and-the-wall.md`):
  identity must ride the *session, established at the door* — never a request
  "asserting about itself" (false witness, inheriting another's portion). The wall
  is lawful (D&C 121, no compulsion); the *gift through it* is consecration.
- **Multi-tenancy notes** (identity-at-transport, secure views, **fails CLOSED**).
  Federation reuses the *posture* but is a **separate mechanism** — see §5.
- **The deterministic wall-check engine** (`scripts/wall-check/`, private workspace):
  a regex pattern set + a pass/fail script — the gate primitive, already in daily
  use for publishing.
- **Transport facts:** a NetBird/WireGuard mesh already federates Michael's machines
  (encrypted, authenticated at the network layer). loom's mTLS design is RATIFIED but
  its build is NOT green-lit — a dependency to *reuse if ready*, never to block on.

## 3. Design decisions — the v1 positions

**3.1 What crosses — envelopes + explicit per-item payloads only.** The unit that
crosses is an **A2A envelope**: a `submit` ticket, a `claim`, a `needs_input`
question, an `answer`, a `receipt` (summary + artifact *references/handles*), a
`note`. Never a pool sync, doc bodies, engram embeddings, or a graph import. "Work
stays work" means the work instance's corpus is never mirrored here — a receipt
carries a summary and a *pointer the work side resolves internally*, not the
content. Raw content bytes crossing is a §7 question, defaulted OFF.

**3.2 Directionality + the employer boundary — mesh-peer to mesh-peer; the
work-side deploy is HIS act.** Both sides may address the other (`peer:agent`), so
either can submit work or deliver a receipt. But *who deploys what* is sharply
divided: **we build the protocol + the personal endpoint; deploying any connector
on the work side is Michael's own act, on his work machine, under his employer's
policy.** The proposal presumes nothing about that network and grants itself no
reach into it. Topology lean: the tighter-boundary side dials *out* to the mesh peer
(no inbound port opened into the work network). His judgment — possibly his
employer's policy — governs whether a personal-substrate connector may touch a work
network at all (§7-Q1).

**3.3 Transport + identity — NetBird mesh + app-layer cert-pin; reuse loom mTLS if
it ships.** The mesh gives a private, encrypted, authenticated network between his
machines; v1 rides it rather than exposing anything to the public internet. Instance
identity is an **app-layer mutual cert-pin** per peer (loom's ratified mTLS is the
target; a minimal pinned-fingerprint check stands in if its build isn't ready —
federation must not block on loom). **Identity is the transport cert, not a
`claimer=` argument** — closing the known `a2a_claim(claimer=…)` self-asserted-identity
hole and enacting "established at the door." A new **`a2a_peers`** table holds
instance identity: `peer_id`, mesh endpoint, pinned cert fingerprint, per-direction
grants, wall profile (§3.4). Distinct from `a2a_agents` (agents *within* an
instance); a federated address `peer_id:agent_id` resolves to a local `a2a_agents`
row on the far side.

**3.4 The wall as code — a per-direction, per-peer deterministic gate, fail-closed.**
Every crossing payload runs a deterministic pattern gate *at the boundary*, trusting
no caller (confused-deputy defense):
- **Outbound work→personal:** an egress filter (the `scripts/wall-check/` engine,
  work-confidential pattern set) scans the receipt/note/answer; a hit **blocks or
  redacts** and logs. Nothing work-confidential enters the personal instance's logs
  or docs.
- **Inbound personal→work:** an ingress filter (personal/private pattern set) blocks
  personal or private content from crossing into the work instance.
- Both are named on the peer link as a **`wall_profile`** (which pattern set applies
  each direction). The boundary is a property of the *link*, not a global rule.
- **Fails closed:** a gate error, unparseable payload, or missing profile blocks the
  crossing — never opens it.

## 4. Phases — each names its oracle

- **Phase 0 — council ratify (this doc).** A federation boundary is a one-way door;
  ratify the pattern before any column, table, or wire lands. **Oracle:** Michael's
  ruling on §7.
- **Phase 1 — peer registry + the wall gate, on a loopback.** Add `a2a_peers`, the
  `federation_wall_check(payload, direction, peer)` gate wrapping the
  `scripts/wall-check/` engine, and federated `submit/receipt` routing — proven with
  **one instance addressing itself as a peer** (no work network touched). **Oracle:**
  a wall-gate test corpus, virgin-smoke style — known-leaky MUST block, known-clean
  MUST pass, a gate error MUST block (fail-closed) — plus the inverse hypothesis
  (remove the leaky token → passes; restore → blocks).
- **Phase 2 — real wire between two of Michael's *personal* instances.** Two of his
  own machines over the mesh, cert-pinned, personal↔personal — the wire and
  identity-at-transport, with zero work content in play. **Oracle:** a federated
  say-hello handshake (the A2A say-hello, across the wire) + identity inverse
  hypothesis (a wrong/absent cert refused, a valid one accepted).
- **Phase 3 — the work instance (HIS act, employer-gated).** Michael deploys the
  connector on his work machine under employer policy; personal↔work handoff runs
  with the confidential `wall_profile` live. **Oracle (real-path):** submit a task to
  the work peer, receive a receipt, then run the personal-side wall-check over the
  instance's *stored* docs/logs and assert **zero** confidential-pattern hits —
  verified on the real stored rows, not a probe.

## 5. Non-goals (v1)

No pool replication. No shared/synced embeddings. No graph import across the link.
No cross-instance model dispatch (loom carries model transport separately). No
public-internet exposure (mesh-only). No multi-tenancy — federation is peer-to-peer
between two *single-steward* instances; the RLS/`owner_id` one-way-door change is a
**separate** decision and must not be smuggled in under federation. No automatic
sync of anything: every crossing is an explicit, gated envelope.

## 6. Costs & risks

- **One-way-door leak.** A link that leaks once has leaked → fail-closed gate,
  per-direction profiles, a blocked-crossing audit log.
- **Employer policy.** Any connector touching a work network is Michael's decision
  and may need employer sign-off; the proposal grants itself no work-side reach.
- **New attack surface.** A network edge on the substrate is new surface →
  mesh-only, cert-pinned identity, envelope-only verbs (the OpenClaw lesson: reach,
  done walled and send-only, not an open gateway).
- **Confused deputy.** The gate runs at the boundary and trusts no caller-asserted
  identity or scope.

## 7. Open questions for council

1. **Employer boundary (load-bearing).** Is running a personal-substrate connector
   that touches a work network acceptable under Michael's employer policy at all — and
   is the topology "work side dials out only"? Everything downstream depends on this
   being *his* call, possibly with employer sign-off.
2. **Wall-gate failure semantics.** Fail-closed confirmed? When an *outbound* crossing
   is blocked, does the sender (personal) get told "I withheld something" — or is even
   that silent, since acknowledging a withheld item can itself leak that it existed?
   Who reviews the blocked-crossing audit log?
3. **Identity dependency.** Cert-pin now, or wait for loom's mTLS build? And per-peer
   pinned fingerprint vs a shared CA for the two-instance case.
4. **Receipt granularity.** Confirm receipts carry summary + *reference/handle* only
   (work side resolves internally), never raw content bytes — or is a wall-checked
   content-bytes mode wanted, defaulted off?

## 8. Provenance

`extension/v13-a2a.sql` (read: the A2A engine — registry `scope`/`token_hash`/
`endpoint`, the handoff verbs). Private workspace: `.spec/proposals/a2a-open-engine.md`
§5/§7 (Phase 3 mesh + tokens + scope-wall), `study/ai/stewardship-consecration-and-the-wall.md`
(identity at the door, the lawful wall, consecration), `scripts/wall-check/` (the gate
primitive), the multi-tenancy notes (fail-closed, identity-at-transport). Transport
facts (NetBird mesh live; loom mTLS ratified, build not green-lit) noted as
dependencies, not assumptions.


## Ruling (2026-07-14, Michael — council question 1 answered)

**Personal↔work substrate federation: NO.** "Work pg-ai-stewards shouldn't
connect to personal pg-ai-stewards." The former P3 is struck. The standing
boundary: **work content stays off the personal box entirely** — the maximum
work-coordination channel is a **loom bridge** (harness-level coordination of
work-vs-OSS tasks), never substrate-to-substrate links, never corpus rows.

**What proceeds (practice scope):** federation development continues against
**multiple local instances on the same box** (the loopback P1 and a
second-local-instance P2) — the protocol, the wall gates, the cert-pinned
peer identity all get built and proven locally. The eventual real second peer
is a **second personal machine** (planned), not the work instance.

Remaining council questions (2-4: wall-gate failure semantics, cert-pin vs
mTLS timing, receipt granularity) apply to the practice/personal scope and
stay open.
