# pg-ai-stewards — OSS extraction plan

**Status:** RATIFIED 2026-06-11 (license model pending final pick — see §Licensing)
**Decisions:** v0.1 = core + persona-host · clean-room re-assembly (fresh
history; the private workspace keeps the lived history) · cutover after v0.1
boots virgin · license = source-available, individuals free / companies pay
(mechanism below).
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
   the same way the workspace did.
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
  security review pass.
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

## Ratified decisions (2026-06-11)

1. **v0.1 = core + persona-host** — the compelling demo (personas in a room)
   ships day one; coder-mcp/UI follow in 0.2 after a hardening pass.
2. **Clean-room re-assembly** — fresh public history, every file audited as
   it lands; the workspace keeps the lived history.
3. **Cutover after v0.1 boots virgin** (verify-suite green on a clean
   machine); then upstream-first development, workspace consumes releases +
   overlay dir. The playground machine is the proving ground.
4. **License**: source-available / individuals-free model; mechanism (BUSL
   vs PolyForm SB) pending Michael's pick.
