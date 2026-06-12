# pg-ai-stewards — OSS extraction plan

**Status:** RATIFIED 2026-06-11 · **cutover gate AMENDED 2026-06-12**
**Decisions:** v0.1 = core + persona-host · clean-room re-assembly (fresh
history; the private workspace keeps the lived history) · **cutover at FULL
PARITY, not v0.1** (amended 2026-06-12 — "I want it to be a good clean
cutover": one cut, no hybrid period; see §Cutover parity gate) ·
**license = Apache-2.0** ("someone will live better for it" — the
source-available analysis below is kept for the record of the road not
taken) · dev deployment = side-by-side on the SAME machine as the private
substrate until feature-complete (see §Side-by-side).
**Binding question:** How do we take the substrate that grew inside a private
workspace and make it a public project a stranger can `docker compose up`,
understand from its docs, and extend without forking — while the original
workspace keeps its private overlays and becomes the first downstream consumer?

## Why now

Three converging reasons:

1. **The mental model debt.** The substrate works — it ran a D&D holodeck, a
   coding pipeline, research councils — but its own steward can no longer
   draw "what exactly is a model turn" from memory. When the builder loses
   the mental model, the docs are overdue. Documentation-first extraction
   rebuilds the model and produces the public architecture docs in one act.
2. **The import knot.** The substrate lives inside a monorepo whose
   `go.work` forces a 40-line dance of `go.mod` stub COPYs in every
   Dockerfile. Extraction kills that knot: standalone modules, one compose,
   boots on a virgin machine.
3. **The office vision.** Agents that represent real people in a shared
   chatroom — collaborating across an org on their humans' behalf, pulling
   together parts of a company that don't talk because everyone's busy. The
   substrate (cognition + memory + stewardship) plus ai-chattermax (the
   floor) are the two halves. Public, installable versions of both are the
   prerequisite. (Reference studied, not replicated:
   [munder-difflin](https://github.com/chaitanyagiri/munder-difflin) — a
   local Electron harness that wraps terminal-agent CLIs with memory,
   mailboxes, stigmergy, and a GOD orchestrator. Convergent patterns,
   different substrate: theirs is files + CLI processes; ours is Postgres +
   pipelines, with the human as the Hinge instead of a GOD agent.)

## What the substrate IS (inventory to extract)

| Piece | Today | Ships in OSS |
|---|---|---|
| **Extension** (Rust pgrx + ~220 SQL migrations) | work_items, pipelines, agents, dispatch bgworker, councils, gates, trust ladder, sabbath/atonement, cost buckets, context engine (engrams), faceted self-notes, tool perms | core — yes |
| **Bridge** (`stewards-mcp`) | outbound MCP client daemon (stdio + streamable HTTP), migration runner, tool cache | core — yes |
| **CLI** (`stewards-cli`, cockpit) | migrate, board, watch, cost | core — yes |
| **persona-host** | chat personas for ai-chattermax (sessions, casts, promotion, reactions) | phase 2 |
| **coder-mcp** | sandboxed coding capability (clone→plan→implement→verify→PR) | phase 2 (hardening review first) |
| **stewards-ui** | web cockpit | phase 2 |
| **verify-suite** | scratch-container DR replay + parity diff | core — yes (it IS the install test) |
| Workspace overlays | gospel/study MCP tools, personal covenant & intent text, personas, study pipelines | **never** — they're the downstream's overlay |

## Deliverable #1: "Anatomy of a Turn"

Before moving code, write the doc that answers the binding mental-model
question. One narrative, one diagram set (later: animations):

```
message → host → spawn_subagent_create → work_item(stage)
  → compose_system_prompt   (covenant + intent + agent prompt + self-notes)
  → compose_messages        (context engine: engrams, handles, pressure)
  → compose_tools           (perms ∩ catalog; sql_fn internal vs MCP bridge)
  → work_queue 'chat' row → provider (opencode_go | lmstudio | gemini | …)
  → tool_calls loop (sql_fn executes in-DB; mcp_proxy rides the bridge)
  → result → auto-fire markers (verify/gate/council/…) → answer/outbox
```

This doc is simultaneously: the OSS architecture page, the animation
storyboard for the docs site, and the steward's recovered mental model.

## Generalization principles

1. **Behavior is data.** Agents, pipelines, tool grants, covenant, and intent
   are rows and YAML — not code. Therefore the plugin surface is **an overlay
   directory of migrations + config**, not a fork. The workspace's gospel
   tools are just `overlays/*.sql` + its own MCP server binaries.
2. **Covenant and intent stay first-class.** They are the substrate's
   identity, not workspace quirks. OSS ships *generic templates* (a covenant
   of mutual commitments, an intent document) that installers personalize —
   the same way the workspace did. **Extraction snapshot note (2026-06-12):**
   take the POST-PR.1 covenant machinery — `covenants.extensions` jsonb
   catch-all + the pass-through parser + the presiding render and Watch echo
   in `compose_system_prompt`. The pre-PR.1 shape silently dropped unknown
   covenant sections (the ratified `presiding:` extension never reached
   dispatches); a covenant store that can't grow sections without a schema
   change is a form-without-power bug, and the OSS template covenant should
   ship with the presiding extension included.
3. **The human is the Hinge.** No GOD agent. Merge/deploy/spend authority
   stays human; the substrate proposes, verifies, and accounts.
4. **Boots on a virgin machine or it isn't done.** `git clone && docker
   compose up` with one `.env` = a running substrate with example agents
   (echo, research-lite) and a seeded covenant. The verify-suite becomes CI.
5. **Upstream first.** After cutover, new substrate development lands here;
   the private workspace consumes releases + its overlay dir. The
   workspace's migration history stays where it lived — history is not
   extracted, capability is.

## Phases

- **P0 (now):** this repo + this spec + Anatomy-of-a-Turn draft.
- **P1 — core extraction:** extension + bridge + CLI as standalone modules
  (no go.work stubs), one `docker-compose.yml`, generic seed pack
  (covenant/intent templates, example agents + pipelines, zero secrets),
  virgin-machine boot proven by the verify-suite. README quickstart.
- **P2 — the floor:** persona-host + ai-chattermax pairing docs, example
  persona configs, dnd-tools as the model third-party MCP; coder-mcp after a
  security review pass; stewards-ui. P2 completes BEFORE cutover — the
  parity-gate amendment makes coder-mcp + stewards-ui pre-cutover work,
  not post-cutover follow-ons.
- **P3 — docs site:** cpuchip.net/projects/pg-ai-stewards — narrative docs
  with animations (Remotion, per munder-difflin's landing-remotion pattern).
- **P4 — the playground:** install on a dedicated machine under agent
  stewardship; the substrate gets standing general tasks of its own.
- **P5 — the office:** an MCP that lets anyone's coding agent (Claude Code /
  Copilot / opencode) speak as their persona in shared rooms — agents
  collaborating on their humans' behalf.

## Licensing (the "individuals free, companies pay" model)

The want: any single developer — hobbyist or employed — uses it freely;
a company deploying it in-house pays for the work. That is not classic
dual-licensing (GPL + commercial); it's **source-available licensing with a
commercial grant**, and there are two established shapes:

1. **BUSL-1.1 (Business Source License)** — parameterized: a custom
   *Additional Use Grant* (e.g. "free for individuals, noncommercial use,
   and non-production evaluation; production use by an organization requires
   a commercial license") + a *Change Date* after which each release
   converts to a real open license (e.g. MIT after 2–4 years). Used by
   MariaDB, HashiCorp, CockroachDB. Pros: well-known, future-open promise,
   clean commercial-sales story. **Recommended.**
2. **PolyForm Small Business** — free for orgs under a size threshold
   (default <100 people & <$1M revenue), paid above. Simpler; no
   future-open conversion.

Honest costs of either: the project is "source available," not OSI "open
source" (marketing must say so), and selling commercial licenses requires
holding the copyright — outside contributions need a **CLA**. Interim state:
the repo carries no LICENSE (all rights reserved by default) until the pick
is final; nothing is lost by deciding within the week.

## Overlay design: the downstream is its own repo (ratified 2026-06-12)

The workspace's private material gets a **dedicated private repo** —
`github.com/cpuchip/pg-ai-stewards-workspace` at
`projects/pg-ai-stewards-workspace/` — rather than living loose inside the
monorepo. Reasons, in order of force:

1. **The playground machine (P4) and any deploy target clone OSS + overlay
   and nothing else.** The scripture-study monorepo is private, enormous,
   and full of unrelated personal material; a machine that runs the
   substrate should not need it.
2. **Version pinning.** The overlay repo declares which OSS release it
   overlays (an `OSS_VERSION` pin / image tag). Upgrades become explicit
   and testable instead of ambient.
3. **The parity gate becomes CI-able.** Gate §5 (overlay replay proof) is
   literally "scratch container + OSS + this repo" — a one-command check
   the overlay repo can run on every change.
4. It matches the workspace's established pattern: every real project
   under `projects/` carries its own repo.

Shape (first cut — refine when P1 creates it):

```
pg-ai-stewards-workspace/        (PRIVATE)
  OSS_VERSION                    # the release this overlay targets
  overlays/                      # SQL migrations applied AFTER core,
                                 #   own manifest + ledger namespace
  covenant.yaml / intent.yaml    # the personalized texts (seeded in)
  compose.override.yml           # private MCP servers (gospel-engine,
                                 #   strongs, webster, …), env wiring
  mcp-servers/                   # server configs; $env: placeholders only
  .env.example                   # names of required secrets, never values
```

Mechanism on the OSS side (P1 work): the compose mounts an overlay
directory; the migration runner applies `overlays/*` after core in
manifest order; the ledger records core and overlay in **two tiers** —
which folds into the existing migrate-manifest design call (now doubly
motivated; the suffix-naming wart gets fixed in the same pass). Secrets
keep the established rule: `$env:NAME` placeholders in data, values only
in the runtime environment.

**Timing:** create the repo at P1 kickoff, not before — P1's first task
(classifying the ~239 live migrations into core vs overlay) is what fills
it, and an empty shell created early just drifts.

## Cutover parity gate (ratified 2026-06-12)

Parity is measured at the **recomposed stack**, not the OSS repo: the gate
is `OSS core + private overlay == today's live substrate behavior`. The
workspace-specific material (gospel tools, study pipelines, live personas,
personal covenant/intent text) belongs in the overlay — its absence from
GitHub is not a parity failure. The cut happens ONCE, with no hybrid
period where some daemons run private builds and others run OSS.

The live substrate cuts over only when ALL of the following hold:

1. **v0.1 boots virgin** — `git clone && docker compose up` on a clean
   machine, verify-suite green.
2. **coder-mcp and stewards-ui extracted** (each after its hardening
   review) — i.e. the cut lands at ~v0.2, with every daemon the live
   stack runs available from the OSS tree.
3. **The 20 unclassified live↔repo function-definition mismatches are
   classified** (pre-existing verify-suite debt). Until live behavior is
   proven reproducible from files, no rebuild — OSS or otherwise — can be
   called clean.
4. **Migration ledger normalized** — the suffix vs suffix-less
   double-entry wart resolved as part of the migrate-manifest design
   call; the cutover replay leans on this bookkeeping.
5. **Overlay replay proof** — scratch container, OSS core + overlay
   migrations, full replay; function-def parity diff against the live
   substrate comes back clean. (The verify-suite is the instrument; it
   was built for exactly this.)
6. **Side-by-side soak passes a feature-exercise checklist** on the
   `stewards-oss-*` stack with its own keys: a persona turn (wake,
   tools, SILENCE, outbox), a multi-stage pipeline with gates and a
   council, cost events + caps, a watchman pass, a remote-MCP tool via
   the bridge, a coder-mcp PR run, and a stewards-ui walk.
7. **Cut-then-retire sequencing** — persona identities move to the new
   stack and the old stack is stopped in an order that can never leave
   two hosts on one key (the double-fire lesson).

## Side-by-side: OSS dev on the same machine as the private substrate

Until the playground machine exists, the OSS stack runs in Docker NEXT TO
the live private substrate. The Postgres **extension name does not change**
(`pg_ai_stewards`) — each stack has its own Postgres container, so the
twins never meet. Only host-level names can collide; the OSS compose
namespaces everything:

| Surface | Private (live) | OSS dev |
|---|---|---|
| compose project / container prefix | `pg-ai-stewards-*` | `stewards-oss-*` |
| Postgres host port | 55433 | **55434** |
| UI host port | 8080 | **8081** |
| persona-host HTTP | 8090 (container) | **8091** |
| volumes | `pgdata`, `coder-worktrees` (fixed name!) | compose-prefixed; no fixed `name:` keys |
| chat personas | the real keys → chat.ibeco.me | **own keys + own test rooms** (or a local chattermax) — never the live personas, or every turn double-fires |

The last row is the landmine (learned live, 2026-06-11: two hosts on one
persona key = every turn fires twice). OSS dev personas get their own
identities from day one.

## Ratified decisions (2026-06-11)

1. **v0.1 = core + persona-host** — the compelling demo (personas in a room)
   ships day one; coder-mcp/UI follow in 0.2 after a hardening pass.
2. **Clean-room re-assembly** — fresh public history, every file audited as
   it lands; the workspace keeps the lived history.
3. **Cutover at full parity** (AMENDED 2026-06-12; originally "after v0.1
   boots virgin"). v0.1 virgin boot remains the first gate, but the live
   stack cuts over only when every condition in §Cutover parity gate
   holds — coder-mcp + stewards-ui extracted, mismatches classified,
   overlay replay proven, side-by-side soak green. Then upstream-first
   development, workspace consumes releases + overlay dir. The playground
   machine is the proving ground.
4. **License**: source-available / individuals-free model; mechanism (BUSL
   vs PolyForm SB) pending Michael's pick.
