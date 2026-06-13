# 2026-06-13 — Parity roadmap ratified; M1 (playlist digester) shipped

**Session:** pg-ai-stewards lane, continuation. Michael: "keep going until we
hit parity… only braking for critical matters." Mapped the road to the cutover,
ratified the shape up front, and shipped the first milestone.

## The roadmap (ratified)

Revised parity = #4 (playlist) + coder enablement + UI/CLI up, before the cut.
Milestones M1–M7 → CUT, run straight through, brake only at the marked points:

- **M1** yt-mcp + playlist digester ✅
- **M2** coder enablement — prove code-pr e2e on OSS *(brake: throwaway repo)*
- **M3** UI extraction *(see correction below)*
- **M4** personas + schedules on OSS *(brake: persona-key/test-room safety)*
- **M5** compact_context in OSS core *(brake: parked design Qs)*
- **M6** cleanups (promote_trigger sabbath-wrap, cv4→overlay, BYO-MCP docs)
- **M7** functional soak → parity-proven report
- **CUT** Michael's session, Hinge ①+③

Three up-front ratifications: yt-mcp = OSS cmd/ + opt-in layer; cockpit "write
verbs now"; compact_context in parity scope.

## Two corrections I owed Michael (verified real-path, not memory)

1. **The context engine.** OSS has the *reactive* engine (compose_messages,
   compose_system_prompt, intercept_*, extract_engrams, render_judge_brief).
   `compact_context` — the *proactive* between-turn curation Michael sketched —
   is ZERO occurrences in OSS **and** private. "Pulled in at council" never
   happened; the authoring leg only consolidated existing migrations. M5 builds
   it net-new.

2. **The UI is 10× what I said.** I twice mis-described it. There is no "just a
   terminal cockpit" — `scripts/stewards-ui/` is a **~11K-LOC Vue+Go web app, 23
   routes** (the live `pg-ai-stewards-ui` container; `extension/ui.Dockerfile`,
   `stewards-ui --addr :8080`), not in the OSS. The `cmd/stewards` CLI cockpit I
   described is a separate, smaller read-only thing that happens to be in OSS.
   My first search missed it because I scoped to `projects/` and the UI lives at
   the workspace root `scripts/`. Surfaced immediately; Michael re-ratified M3 as
   **extract-as-is** (existing write islands) + doc_* rename + single-module
   build, with the evolution-proposal features (chat/authoring) deferred
   post-cutover. The earlier "write verbs now" answer was against the wrong
   description — corrected.

## M1 — what shipped (OSS `3e5ef66`, pushed)

- **yt-mcp folded** scripts/yt-mcp → `cmd/yt-mcp` (package main, no cross-pkg
  imports, hand-rolled MCP, empty go.mod require — trivial fold).
- **NEW `yt_playlist` tool** (`yt-dlp --flat-playlist --dump-json`): enumerate a
  playlist/channel WITHOUT downloading. The discovery step the download-first
  tools (yt_download/yt_get/yt_list-over-local) structurally lacked — and the
  enabling capability for "poll a playlist for *new* videos." A genuine, generic
  improvement to the tool being folded. (Not backported to scripts/yt-mcp — the
  live tool stays untouched; deliberate fork.)
- **Opt-in, not core.** yt is a Tier-3 domain MCP (the virgin-smoke denylists
  it). So: `bridge.Dockerfile` gains `ARG WITH_YT=0` gating both the yt-mcp
  build and a python3/yt-dlp runtime; `docker-compose.yt.yaml` flips WITH_YT=1
  + a /yt transcript volume. Default `docker compose up` stays lean + python-free
  (mirrors the coder opt-in pattern).
- **`examples/playlist-digester.sql`** — the #4 digester on the book-digester
  pattern: `playlist_watch` + `playlist_seen` (global video-id dedupe) +
  `playlist_next`/`playlist_publish`/`playlist_add` tools + the yt mcp_server
  registration + a 4-stage `playlist-digest` pipeline (read→digest→critique→
  recommend; kimi-k2.6 doer, qwen3.7-plus critic — NOT -max) + a `video-study`
  intent + a 6-hourly schedule, seeded with the AI-research playlist. The read
  stage orchestrates playlist_next → yt_playlist → pick-unseen → yt_download
  (a pure-SQL book_next can't enumerate a remote playlist).
- Genericized 3 personal-domain strings ("Gospel Evaluator", book-of-mormon
  examples) in the folded source.

## Proven e2e on the OSS stack

Rebuilt the bridge WITH_YT=1; `refresh-tools` = **7/7** (yt: 5 tools incl
yt_playlist). yt-dlp 2026.06.09; flat-playlist enumeration works in-container
(no bot-detection). A real run digested **WGwRCw9TRyo** ("This 1 Book Has
Produced More Geniuses…" — the Euclid video) off the playlist:
read→digest→critique→recommend→completed, `playlist_seen`+1, a **7804-char
digest** → doc `db65c928` + a `pending_file_writes` row (study/yt/WGwRCw9TRyo.md)
+ a brain entry.

The hourly book-digester also kept running on its own overnight — the shelf shows
self-reliance/meditations/tao-te-ching DONE.

## Gotchas

- yt-mcp needs `args=['serve']` (no args → prints usage to stdout → corrupts the
  stdio JSON-RPC; refresh-tools failed with `invalid character 'y'`).
- `work_item_create` does NOT auto-dispatch the first stage — call
  `work_item_dispatch_stage(id)`. The scheduler (`watchman_scheduler_fire`) does
  both, which is why the *scheduled* book-digester ran but a manual create sat in
  `read/pending`.
- Compose recreated `pg` too on the bridge rebuild (config drift), but pgdata
  persisted (no `-v`) — data intact.

## Carry-forward

- M2 next: prove `code-pr` e2e on OSS — needs Michael to name a throwaway repo
  (real DRAFT PR, his GH token, never in the sandbox).
- M3 is a real multi-step extraction (the Vue+Go app); not a one-shot.
- The playlist 6-hourly schedule is live on the OSS dev stack — it'll keep
  digesting new AI-research videos on its own (next tick top of the 6h).
