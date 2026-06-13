# 2026-06-13 — MCP packaging, the coder ships, and the substrate becomes usable

**Session:** pg-ai-stewards lane, a long continuation. The authored chain
(00→20) was already done; this session took the OSS from "boots virgin" to
"actually usable for a real project," and closed the coder Hinge.

## What shipped (all pushed to public `cpuchip/pg-ai-stewards` unless noted)

1. **MCP-packaging plan** ratified + committed (`f603e34`) — deciding signal:
   Go-module coupling. No separate `-mcp` repo; one module. Three tiers.
2. **M0 — runtime stack** (`8287967`): `bridge.Dockerfile` + `persona-host.Dockerfile`
   + root `docker-compose.yaml` + `.env.example`. Clean-room single-module win —
   the bridge builds 3 binaries in ~6s (no go.work, no stub COPYs, no personal
   MCP). **Virgin boot proven:** CREATE EXTENSION installs the core, bridge
   connects + `refresh-tools` spawns the real stdio MCP servers.
3. **gospel-engine resolver → generic** (core `4bb80ab` + workspace overlay
   `90906f7`). The "resolver" was a whole scripture-citation subsystem hiding in
   `schema.rs` (the file the SQL-file audit never saw): `parse_gospel_links`,
   `normalize_book` (the LDS book table), `parse_reference`, verse-fanout
   refresh/doc_citations_resolved — none used by a core pipeline. Now:
   `ResolverConfig` + `STEWARDS_RESOLVER_URL` ({ref} template), `parse_doc_links`
   (all links → CITES, external|doc), scripture machinery → workspace overlay
   (`scripture-resolver.sql`, replay-proven). Behavior change flagged: core
   `import_doc` now cites all links generically.
4. **Harness scripture cleanup** (`b6ec106`) — purged residual scripture fixtures
   (verify-* + the init brain smoke → water-cycle; verify-3e2-2 re-pointed to
   fs-read). Extension is now scripture-free.
5. **Study-pipeline proposal** (`dfa3ff4`, DRAFT) — `.spec/proposals/study-pipeline.md`:
   generalize the phased study-agent workflow into a corpus-agnostic pipeline
   (frame→gather→outline→draft→**critique/null-case**→revise→final→review) on
   existing primitives. The substrate's flagship demo. Build after cutover.
6. **M1 — coder-mcp** (`321176c`+`7897093`) — the sandbox coding capability.
   Ported into the root module, hardened, `SECURITY.md` written (the ship-gate
   doc). **Hinge ② closed** — Michael read the review and gave three ship
   decisions: socket off-by-default (on for us via a gitignored override),
   egress on-by-default + `CODER_SANDBOX_NETWORK=off` kill-switch, coder row
   stays enabled. `coder-mcp -smoke` PASS; refresh-tools coder [OK] 16 tools.
7. **M2 — fetch-md + git utilities** (`4a31b03`) — ported into `cmd/`, seeded in
   core (deny-by-default grants). refresh-tools 5/5.
8. **#1 exa web search as the default** + **#2 model-wiring examples** (`fd08fea`):
   exa-search seeded as the keyless-free-tier default web search (search works
   OOTB); `docs/wiring-up-models.md` + `examples/models.sql` (the four provider
   setups + a real-price catalog snapshot). refresh-tools 6/6 incl exa-search.

## Key decisions + reversals

- **Web search: BYO → default.** M2 kept web search out of core, assuming Exa
  needed a key (the virgin-smoke denylisted exa-search). Michael then showed the
  Exa free tier works keyless — verified by a **real `web_search_exa` call
  through the live bridge** (got the Euclid Wikipedia article back). So #1
  reversed it: exa-search ships as the keyless default; the old DuckDuckGo
  `search` stays archived. The smoke now treats exa-search as core.
- **The coder is the one Hinge.** Everything else ships freely; the coder
  (host docker socket = host-root) waited for Michael's explicit nod after the
  hardening review. Honored by committing it locally and holding the push.
- **Verify the real path, not the config.** The exa "is it enabled?" question
  was answered by an actual search, not by reading rows — and it caught that
  "enabled=true" with no key still works (free tier).

## Discoveries / surprises

- `schema.rs` is the blind spot of the SQL-file audit — two domain subsystems
  (the resolver, and example agent/skill prompts) lived there untouched.
- `down -v` gotcha: the scratch `pgdata` volume persists old seeds, so new core
  seeds don't appear until a fresh install. Real-path verification needs it.
- Exa's hosted MCP is keyless-free-tier usable; that quietly changed the
  packaging shape.

## Carry-forward — Michael's 7-item roadmap (this session did #1, #2)

- **#3 — book-digester** (NEXT, his new idea): pick a public-domain/free book,
  digest + learn from it with scripture-study rigor, working through the classics.
- **#4 — playlist digester**: poll his "AI research" YT playlist, digest new
  videos, make actionable recs. kimi-k2.6 doer + **qwen3.7-plus critic (NOT
  qwen3.7-max — ~2× cost)**. = study-pipeline + scheduler + yt_transcripts.
- **#5 — finish the cutover** (Hinge ①): stop work on the old/live, move to OSS.
- **#6 — self-improvement loop** (council/spec/ratify/build): hourly autonomous
  turn, agent picks a subject within a sphere, learns, does something, idles.
  Ref video https://youtu.be/RB8vjn1QPeM — watch first, spec carefully.
- **#7 — have fun.**
- Smaller: cv4 minimax-m3 catalog row → workspace overlay; M3 (BYO-MCP docs +
  example web_search_exa grant overlay) is the last packaging milestone.

## State of the world
Search works in the live instance (free tier, granted to research/study agents).
Both scheduled pipelines (ai-news-7am, science-news-weekly) run live + are
ported to the overlay. The OSS boots clean with web search, fetch, git, and the
coder all live; model wiring is documented with free options.
