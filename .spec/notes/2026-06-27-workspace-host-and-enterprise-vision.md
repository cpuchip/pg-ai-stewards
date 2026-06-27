# pg-ai-stewards as the Workspace Host — code-as-Worlds, coding-in-the-substrate, and the path to enterprise

*Vision note (2026-06-27), Michael thinking out loud + Claude. Not a ratified spec — the durable
capture of "where my mind is at" so it survives. Sits above the multi-tenancy spec
(`.spec/proposals/multi-tenancy-and-single-user.md`) and its research
(`.spec/notes/2026-06-27-postgres-multitenancy-research.md`).*

## The dual goal

Take what innovation week built and make it **deployable + usable by everyone at the company**,
**without stepping on the solo build.** Two ends of one rope:
- *Enterprise:* knowledge shares owned by a user **or a group** (with **transfer** when people leave),
  the 270–500-repo platform represented and explorable, code review **and code authoring** across
  repos, multi-tenant.
- *Solo, untouched:* Michael's personal substrate stays his — single-tenant, his infra, no friction.

The reconciliation is the **OSS-core / overlay** split at the *deployment* level: **two installs of
the one engine.** Personal = core + Michael's overlay, single-tenant. Company = core + a company
overlay, multi-tenant, on company infra. Same code, different overlays, different tenancy posture.
Multi-tenancy is what makes the company install serve everyone; the personal install never changes.

## The load-bearing idea — graph in the DB, code in a transient workspace

You don't import 500 repos into Postgres, and you don't run a container per repo. **Two layers:**

1. **The DB holds the GRAPH (orientation).** Repos / services / groups / helm-charts as **entities**;
   the hierarchy (platform → ecosystem-group → eco-service → repo + helm) as **CONTAINS edges**,
   arbitrarily deep (multi-level worlds = nested containment, not a fixed two levels); the
   **connectivity** (DEPENDS_ON / CALLS / DEPLOYS) as edges. This is the Loreworks world-graph
   applied to code — cheap, queryable, and what you *explore* (the 3D graph). It's the index.
2. **The code lives in a transient, per-task WORKSPACE (grounding).** When a task touches several
   repos, the graph says *which* ones; you spin up **one ephemeral container** that clones *only that
   subset* (the task's repos + their graph-neighbors) on the right branches, grep-able and diff-able
   together, then tear it down. **You never hold 500 repos live** — a graph of 500 (tiny) + a
   workspace of the 3–8 a task touches (cheap, ephemeral). Containers scale with *concurrent tasks*,
   not repos.

Freshness: the graph is a slow index (re-scan on a push webhook / periodically); the code is always
fresh because it's cloned on-demand at task time on the named branch. No live 500-repo mirror.

## pg-ai-stewards as the WORKSPACE HOST

The substrate becomes the orchestrator that *builds the workspace for the agent* — the thing that
makes Claude effective here (a folder with the relevant repos splayed out, grep-able, grounded in
`context/` + `external_context/`), reproduced on demand. The host owns:
- **the graph** (scope which repos a task needs);
- **the credentials/secrets** (clone private repos; the deploy-repos hold encrypted secrets);
- **the workspace builder** — clone the scoped repos on the right branches into a container (named
  volume or bind-mount), wire the MCP servers + the grounding folders, hand it to a worker.

## Two work modes (this is the heart of the ask)

**Code IN it, not just review it.** The host builds the workspace; then either:

1. **Autonomous — `claude -p` *in* the workspace container.** The agent has the folder splayed out,
   greps + reads + **writes code** + runs tests freely — *exactly* as Claude does here, because the
   container IS the workspace and `claude -p` IS the full model on the Max plan. It commits, opens
   the PR, and receipts via A2A. This is "as real as if it's all in front of me" because, for the
   agent, **it is.** (Already most-built: the coder sandbox `coder-runtime.Dockerfile`, `code-pr` /
   coder-mcp's clone→plan→implement→verify→PR, RC-1/2/3's clone→sandbox→research_codebase, and the
   `claude -p` harness the Hinge reviewer already proves. The new part is the *multi-repo* workspace
   builder scoped by the graph.)
2. **Collaborative — VS Code Remote, tunnel in alongside the agent.** Confirmed standard pattern
   (code.visualstudio.com/docs/devcontainers + /docs/remote/tunnels): `code tunnel` runs the CLI on
   the container/host and registers a **secure tunnel — no SSH, works behind NAT/firewall, built into
   VS Code**; **Remote-Tunnels + Dev Containers compose** ("Reopen in Container" over the tunnel) so
   you edit *inside* the container over **volume mounts**, "without even a Docker client locally." So
   Michael (or Claude) **tunnels into the same volume-mounted workspace the autonomous agent is
   working in** and works alongside it — the back-and-forth loop, restored, on the live code.

## "As effective as we are now?" — the honest read

- **Coding capability: yes, replicable.** `claude -p` + a workspace container = Claude-coding (same
  tools, same splayed-out folder, same model). This is the "10000% as effective" core, and it's real.
- **The collaborative loop: the tunnel restores it.** `claude -p` alone is one-shot-autonomous; the
  Dev-Container tunnel puts a human (or a second Claude) *in* the workspace, live.
- **Accumulated context: the gap, and it's namable.** A fresh `claude -p` starts cold — it loads
  `CLAUDE.md` + memory, not a long live conversation. The substrate's session/engram memory + the
  A2A task ticket (the 7-part spec) feed it most of the way; it won't be identical to an hour of
  back-and-forth, but workspace + memory + ticket + the tunnel close most of the distance. Don't
  oversell this part — it's "very close," not "identical."
- **Grounding travels with the workspace.** `context/` + `external_context/` are cloned/mounted into
  the container; the MCP servers are configured in its `.mcp.json`. Truth stays close, by construction.

## Group ownership, transfer, and ai-chattermax (the enterprise layers)

- **Principal = user OR group.** Resources owned by a principal; ownership is a transferable column
  (the "people leave" problem = one `UPDATE`); a group-grant cascades to members. *work-corpus shared with
  the `coworkers` group, invisible to your son* (a principal with no grant) — exactly the model.
- **SSO** is the deferred federated piece, but it lands at the **edge** (verify the token → `SET LOCAL
  app.principal`), not the core. Pre-cut door, not a rewrite. **Nested-org inherited RBAC stays
  deferred** — keep it flat (groups + grants) as long as possible; that's the "ugly" part to not let
  creep in.
- **ai-chattermax folds in** once multi-tenant + personas + users live in the substrate — the chat
  platform becomes a *surface on the substrate*, not a separate app dialing in.

## Deploy-repos + DR

Each app gets a **deployment repo** (Dokploy compose / helm + **encrypted secrets**). The host can
replicate from them → a **"server down" scenario = re-deploy from the deploy-repos to a fresh
Dokploy**. Infra-as-code + DR, and the deploy-repos are also nodes in the graph.

## The playground (test small before the 500)

Our own workspace is the small version of the 270-repo problem: **become / i1828 / cpuchip.net /
mcp / gospel-engine-v2 / scripture-book** (+ this workspace). A handful of related repos with real
deploys (ibeco.me / Dokploy) — perfect to build the graph-ingest, the scoped-workspace builder, the
`claude -p`-codes-in-it loop, and the tunnel-alongside mode, *and* the deploy-repos/DR replication,
before pointing it at 500.

## Foundations needed (prerequisites, in order)

1. **★ Make hybrid search REAL and FULL across the substrate (RRF + graph-expand).** *Michael's
   explicit ask, and it's gap #3 from the review.* Today: `04:doc_search` is FTS-only, `15a` engrams
   vector-only, `57:world_entity_hybrid` is **weighted-linear `0.45·lex+0.55·sem`, NOT RRF** (despite
   `lib.rs` calling it "RRF"), and graph-expand (`41:graph_recall`, `04:doc_context_for`) is a
   *separate* agent-invoked tool, not auto-chained. **Build one fused `*_hybrid` surface — true RRF
   over `ts_rank` + `embed_query` cosine — for docs AND engrams AND worlds, with an auto-chained
   post-vector graph-expand hop.** This is the navigate-the-code-graph primitive; the whole
   code-as-Worlds vision leans on it. *(Also fix the misnamed `world_entity_hybrid` → real RRF.)*
2. **Multi-tenancy P0** (the non-super role + the RLS oracle + the tenant key) — the ownership/sharing
   substrate for group-owned, granted Worlds.
3. **The `claude -p` harness-provider** (#177) — `claude -p` in a sandbox, generalized to the
   multi-repo workspace builder.
4. **The graph-ingest** — parse repo structure / deps / helm / branches into the world-graph, kept
   fresh on push. *(The honest hard part — the graph is only as good as the ingest.)*

## The honest hard parts
The graph-ingest accuracy across hundreds of repos, the "how deep do I clone" scoping knob (real
judgment, not a constant), private-repo credential handling, SSO when it comes, and the
accumulated-context gap above. None blocked; all real work. The architecture keeps it from being
*ugly* work — but it isn't free.

## The shape, in one line
**pg-ai-stewards becomes the Workspace Host: the graph orients, an ephemeral scoped workspace
grounds, `claude -p` codes in it as freely as Claude does here, a human tunnels in alongside, and
the whole thing deploys twice — your solo install untouched, the company's multi-tenant.**
