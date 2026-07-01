# loom integration — driving Claude Code as a substrate worker

**Status:** plan for ratification (2026-07-01). The loom side is built + real-path
verified; the loom-side contract is `cpuchip/loom` → `docs/pg-ai-stewards-integration.md`
(read it — this plan is the substrate half, not a re-derivation). **The first live
dispatch with write-back is a new standing capability (`dominion_in_council`)** — §5 is
the gate.

## Why

The substrate already has a `claude -p` Hinge reviewer (#195) and a local coder loop
(coder sandbox + `code-pr`, clone→plan→implement→verify→PR). **loom is the durable,
steerable, walled upgrade to that plumbing** — the concrete "claude-p in a transient
workspace" of the Workspace-Host vision, and the real fulfillment of the pending
**harness-provider** task (#177). It is a *tier*, not a replacement: the local coder loop
stays for cheap/bulk work; the hard, multi-file, full-harness tasks route to loom-claude.

Two walls, handed per dispatch (the presiding covenant made operational): **filesystem**
(`--isolate` docker / `--remote` ssh / direct) and **capability** (`--mcp-config` +
`--allowed-tools`). Autonomous dispatch is always `--isolate` — the container is what
makes `--skip-permissions` (headless) safe.

## What the substrate already has (grounding, verified this session)

- **HTTP MCP surface** — `cmd/stewards-mcp/http.go` + `bridge.go`'s
  `StreamableClientTransport`. The substrate both *consumes* remote HTTP MCPs and can
  *serve* over HTTP. The loom prereq ("expose the substrate MCP as an HTTP endpoint so a
  walled/remote claude can hinge") is **most of the way there** — confirm external
  reachability + a scoped auth token, don't build from zero.
- **Clone + sandbox** — `cmd/git-mcp` (clone) + `cmd/coder-mcp` (hardened sandbox). loom
  points `--dir` at a clone the substrate already knows how to provision.
- **Work-items + a2a + session ledger** — the durable handle (`session_id`) has a home
  (store it on the work-item), and `a2a_submit` is the write-back verb.

## Phases (each independently shippable; the gate is between 1 and 2)

### Phase 0 — prereqs (infra, no new standing capability)
- **0.1** Confirm the substrate MCP is reachable over HTTP from a container/remote box,
  behind a token (reuse the existing remote-MCP auth pattern). If external reach isn't
  wired, add it — but it's config, not a new subsystem.
- **0.2** Build the `loom-claude` image on the substrate host
  (`docker build -t loom-claude -f docker/Dockerfile.claude .` in the loom repo) and
  confirm a claude subscription cred is available for loom to mount read-only.
- **0.3** Define **two named toolset allowlists**: `read-mostly`
  (`doc_get, doc_search, research_codebase, a2a_inbox, Bash, Read, Write, Edit`) and
  `write-back` (adds `a2a_submit, doc_import_corpus, brain_create`). The first dispatch
  uses `read-mostly` only.

### Phase 1 — the dispatch primitive, PULL-only, one gated dispatch (the viability proof)
A `loom_dispatch(work_item)` step in the harness-provider (Go, alongside the coder loop):
1. Provision the clone (reuse the clone step) → `/var/loom/wi-<id>/clone`.
2. Seed a per-work-item `--claude-home` (`/var/loom/wi-<id>/home`) with the substrate's
   skills + `CLAUDE.md` + an `mcp.json` pointing at the HTTP endpoint (container path
   `/root/.claude/mcp.json`).
3. Run the canonical dispatch **pull-only** (zero container egress):
   `loom run --agent claude --isolate --dir <clone> --claude-home <home>
   --mcp-config /root/.claude/mcp.json --allowed-tools <read-mostly> --skip-permissions
   --json --events "<task from the work item>"`.
4. Parse the one-line `--json` `Reply` from **stdout** → store `text` + `session_id` on
   the work-item; read the bind-mounted `/work` clone for the diff/artifacts. Streaming
   events (`--events`) logged from stderr.

**Pull-only** = the substrate reads `/work` + stdout and *its own code* ingests — no
container→MCP egress, the more secure default, composes with a network-isolated sandbox.
This first dispatch is a **manual, one-off proof on a single real work item**, inspected
by hand. It does *not* make loom a default route.

### Phase 2 — the hinge (write-back) — AFTER the council moment
Swap the allowlist to `write-back` and open container egress to the HTTP MCP, so claude
closes the loop itself (`a2a_submit` / `doc_import_corpus`) as it works — the **push**
model, best for digestion. This is the step that turns loom into an autonomous
substrate actor; it is the `dominion_in_council` line.

### Phase 3 — tier routing — AFTER the council moment
A tier policy on the work-item dispatcher: task classes (hard / multi-file / needs-a-real-
harness) route to loom-claude; cheap/bulk stay on the local coder loop. Only here does
loom-claude become a *default* route. Resume (`--resume <session_id>` + re-mount the same
`--claude-home`) makes a multi-dispatch work-item durable.

## The exfil discipline (bake into `loom_dispatch`)
Work leaves the container only through a channel you opened. **code-build → pull**
(bind-mount `/work` + `--json` stdout, zero egress). **digestion → push** (MCP hinge,
needs egress). Anything written to an unmounted path (`/tmp`, `/root/foo`) dies with
`--rm` — plan the channel per dispatch.

## Council gate (§11 of the loom contract)
Dispatching a full Claude Code harness **with write-back** into the substrate is a new
standing capability. **Phase 1 (pull-only, read-mostly, one manual dispatch, inspected)
is safe to build + run now as the viability proof** — it cannot write to the substrate.
**Phases 2–3 (write-back + default routing) need a council moment with Michael.** Start
narrow, prove one dispatch, inspect, then widen.

## Recommended first move
Build Phase 1 and run **one** pull-only dispatch on a small, real, read-mostly work item
(e.g. "read this repo, summarize its cross-service surface, write findings to `/work`").
Inspect the diff + the `--json` Reply + the stored `session_id`. Bring that result to the
council moment as the evidence for greenlighting Phase 2.

*loom-side gap to flag to general-workspace:* an optional `--clone <git-url>` convenience
would fold the provision-the-clone step into loom; not needed to start.
```
```
