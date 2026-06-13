# MCP packaging — what ships with pg-ai-stewards, and where

**Status:** RATIFIED 2026-06-13. Decisions: (1) **main repo, one module** — no
separate `pg-ai-stewards-mcp`; (2) ship **`fetch-md-mcp` + `git-mcp`** in `cmd/`;
(3) **archive `search-mcp`** (the old 2026-02-03 DuckDuckGo server, predates the
substrate, unreliable — repeated hits throttle/error) and **standardize web search
on Exa** (`web_search_exa`, the remote `mcp.exa.ai` MCP the operator registers with
their own key).

## The question

Several MCP servers exist across the workspace. Which ship with the OSS
`pg-ai-stewards` repo, and do we want a separate `pg-ai-stewards-mcp` repo or
incorporate them into the main repo (Michael leans: main repo)?

## The deciding signal: Go-module coupling

How each server is moduled tells you where it belongs:

- `github.com/cpuchip/pg-ai-stewards/cmd/*` — the substrate's own binaries. The
  daemon leg (2026-06-12) *deliberately* collapsed five of them into **one
  module** (`stewards-mcp`, `fs-read-mcp`, `persona-host`, `stewards`,
  `stewards-cli`) and killed the `go.work` knot. They share the substrate's Go
  types + bridge client.
- **Own module / own repo** — `github.com/cpuchip/webster-mcp`,
  `github.com/cpuchip/gospel-engine`, `strongs-concordance-mcp`, `md-mcp`,
  `dnd-tools`, `github.com/cpuchip/brain`. Standalone domain tools, reusable on
  their own, not substrate-coupled.
- `github.com/cpuchip/scripture-study/scripts/*` — workspace-coupled utilities
  (`search-mcp`, `fetch-md-mcp`, `git-mcp`, `byu-citations`, `yt-mcp`, the
  `gospel-*` family, `becoming`).

## Inventory → three tiers

### Tier 1 — substrate-intrinsic (ship in `cmd/`; this is the substrate's tool surface)
| Server | State | Notes |
|--------|-------|-------|
| `stewards-mcp` | ✅ in OSS `cmd/` | The bridge itself (`stewards-mcp bridge …`) + the substrate's own tools (spawn_subagent, consult_subagent, the doc/work-item tools, research_codebase). |
| `fs-read-mcp` | ✅ in OSS `cmd/` | Sandboxed filesystem read. |
| `persona-host` | ✅ in OSS `cmd/` | The persona sidecar (not an MCP server, but a substrate daemon). |
| **`coder-mcp`** | **⬜ pull from private `cmd/`** | The sandbox coding tools (the SQL surface shipped in `20-coder.sql`, OSS `a943a95`, and is INERT until this binary lands). The hardening review of this one is the public-ship Hinge. |

### Tier 2 — generic utilities the CORE pipelines call (ship in `cmd/`)
**Ship (ratified):**
| Server | Provides | Note |
|--------|----------|------|
| `fetch-md-mcp` | `fetch_url` / markdown fetch (used by `summarize_url`) | re-author into `cmd/`, generic |
| `git-mcp` | general git ops | re-author into `cmd/`, generic (distinct from coder-mcp's sandbox-scoped git) |

**Web search → Exa, NOT a shipped server.** `search-mcp` (first commit 2026-02-03,
"duck duck go search mcp" — predates the substrate; the `web_search` tool_def routes
to it via `server='search'`) is **ARCHIVED**: DuckDuckGo throttle-errors on repeated
hits. There is no substrate-custom search server. The substrate currently leans on
`web_search` (12 agent grants), so M2 re-points the core `web_search` →
`web_search_exa` (the remote `mcp.exa.ai` MCP) and drops the search-server
registration. Exa is **operator-registered with their own key** — a documented
prerequisite for the research pipelines to do web search.

### Tier 3 — domain / content servers (NOT in the repo)
`gospel-engine(-v2)`, `webster-mcp`, `strongs-concordance-mcp`, `byu-citations`,
`becoming`, `yt-mcp`, `brain`, `md-mcp`. These are the operator's own domain MCPs
— several already have public repos. pg-ai-stewards does **not** absorb them;
they are the "bring your own MCP" pattern the README already describes. The OSS
ships an **example overlay** that shows how to register an external MCP server
(the `seed-3e2-*` overlays already do this in the workspace), plus a docs page.

## Recommendation: main repo, one module (no `pg-ai-stewards-mcp`)

1. **The substrate servers already live in the main repo's `cmd/` as one module.**
   coder-mcp + the Tier-2 utilities belong alongside them — they share the
   substrate's Go types and bridge client. A separate `pg-ai-stewards-mcp` repo
   would re-introduce the cross-module / `go.work` coupling the daemon leg just
   removed. That's a regression for zero benefit.
2. **Domain MCPs stay as their own repos** (webster, strongs, gospel-engine, md,
   dnd-tools) — that IS the right pattern for standalone, reusable domain tools,
   and it keeps the substrate core clean (the virgin-smoke asserts no personal
   MCP leaks). pg-ai-stewards references them as examples, not dependencies.
3. **One `docker compose up`** (the README's promise): the runtime/bridge image
   cross-compiles the `cmd/*-mcp` binaries to `/usr/local/bin`; the bridge spawns
   them as stdio subprocesses. Adding a server = a `cmd/<name>-mcp/` dir + a COPY
   line, not a new repo.

## Prerequisite gap to close first

The OSS repo has **no runtime/bridge image or `docker compose`** yet — only the
extension Dockerfile. The `cmd/*` binaries aren't built into any image. So before
coder-mcp can run, the OSS needs:
- a **bridge/runtime Dockerfile** that builds the Go module and cross-compiles
  `stewards-mcp` + `fs-read-mcp` (+ `coder-mcp`) to `/usr/local/bin/`,
- a **`docker-compose.yml`** wiring pg (the extension image) + bridge + persona-host.

This is the P1 "side-by-side docker compose" deliverable; the MCP packaging rides on it.

## Phased work

- **M0 — runtime image + compose** (prerequisite): bridge Dockerfile (cross-compile
  the existing `cmd/*-mcp`) + `docker-compose.yml`. Proves the existing
  stewards-mcp/fs-read-mcp actually run in the OSS.
- **M1 — coder-mcp** (Tier 1, the immediate ask + Hinge ②): port `cmd/coder-mcp`
  into the OSS module, COPY into the bridge image, and do the **hardening review**
  (docker-sandbox isolation against the host daemon, the bridge-side GitHub token
  never entering the sandbox, the repo allow-list, resource caps mem/cpu/pids,
  the reaper). The public-ship gate. After this the `20-coder.sql` surface comes alive.
- **M2 — Tier-2 utilities + web-search re-point** (makes research/code pipelines
  work OOTB): re-author `fetch-md-mcp` + `git-mcp` into `cmd/`, generic and
  personal-free; register via a core seed. **No search binary ships** —
  `search-mcp` is archived (DuckDuckGo throttle-errors) and the core `web_search`
  tool_def is **re-pointed to `web_search_exa`** (the remote `mcp.exa.ai` MCP).
  Exa is operator-registered with their own key; the seed wires the remote
  server and the docs name the key as a research-pipeline prerequisite.
- **M3 — domain-MCP docs + example overlay**: a docs page on "bring your own MCP"
  + a generic example registration overlay (the `seed-3e2-*` shape), pointing at
  the existing standalone repos (webster, strongs, gospel-engine, dnd-tools, md).

## Hinges (Michael's)
- **Live:** coder-mcp public-ship nod after the M1 hardening review (Hinge ②).
- ~~Whether Tier-2 ships in core or stays "bring your own."~~ **Resolved
  2026-06-13:** fetch-md + git ship; search-mcp archived; web search standardizes
  on Exa.
