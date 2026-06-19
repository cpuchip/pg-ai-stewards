# 2026-06-19 — Local-model soak → parallelism → doc-construction

A long, compounding session: get pg-ai-stewards running on the **local FlexLLama rig** (free,
on-box), watch it overnight, learn how the small models actually hold up, and turn the lessons into
two real changes — gemma parallelism and the agentic doc-construction reframe.

## The arc

**Rig fixes first (the enabler).** qwen3.6-27b was crawling (13 tok/s). Root cause: at f16/128k it
filled GPU0 to ~478MB-free, and on Windows/WDDM the KV overflow spills to **system RAM** — the KV is
read every token, so spilled KV = PCIe tax per token. Fix: the KV must live in DEDICATED VRAM; q8 KV
halves the bytes. qwen → q8@192k (47 tok/s, for Garrison's big-context need); nemotron had the same
trap on GPU1 → q8@512k (223 tok/s).

**The overnight soak.** Re-enabled the autonomous loop (books/ai-news/videos/work-corpus) routed to the
local role-aliases (ingest=gemma, reason/critic=qwen). The guard had auto-paused on "6 consecutive
failures" — which were **opencode_go 429s (paid plan usage cap)**, exactly what local fixes. Watched
it via an hourly cron + an 8am report (`.mind/sessions/pg-ai-stewards-soak-watch.md`). Result: **244
flexllama chats, $0.00**, books + ai-news + work-corpus all completing on local; quality genuinely good
(philosophy digests, a cited AI news digest). Three failure modes surfaced — the real "how do they
hold up" answers:
1. **15-min reaper too short** for big-book reads on gemma (hardcoded, cloud-tuned) → false-kills.
2. **gemma `--parallel 1` contends** under concurrent ingest; later proven it actually **WEDGES**
   (slot stuck 91% util, 600s timeout) — worse than slow.
3. **qwen "peg-native format" 500** on grammar-constrained one-shot output (it's a reasoning model;
   thinking tokens break the grammar) → the videos leg broken.

**Parallelism experiment (Michael's call).** gemma `--parallel 2` (f16) → 155 tok/s @ 2 concurrent,
no wedge. Then his "2× gemma / 4×130k" idea, done the efficient way (one instance `--parallel 4`, not
two — shared weights + continuous batching): **q8 `--parallel 4 @ 524288` = 4×131k slots, 248 tok/s @
4 concurrent**, fits beside nemotron (q8 the enabler). Codified (live window 131072 + overlay + setup
script). The lesson: `--parallel` gives N request streams for one weight copy; `--parallel 1` is a
trap under concurrency.

**Doc-construction reframe (Michael's idea, the big one).** The fix for all three findings at once:
the model should **build the artifact via small tool-call diffs** (doc_create/append/patch) and make
its chat output a **journal** — how the coder already works, how Claude writes anything large. We were
asking small models to one-shot a huge structured doc, which even the big models don't do. Plans:
`.spec/proposals/{agentic-doc-construction,local-throughput-experiments}.md`. Phase 1 (`34-doc-builder.sql`:
the tool surface over a self-contained `doc_drafts` table) shipped + proven. **Thesis proven on the
broken model**: a tools-on build on qwen ran 8 chats / 0 errors / 0 peg failures and built a coherent
digest. Then the **playlist-digest recast** (the broken leg) proven e2e on live: read (gemma, emits
header only — no transcript re-emit) → build (qwen, yt_get + doc_* + `playlist_publish_draft` from the
draft handle). work_item completed, 14 chats + 12 tool_dispatch, 0 errors, a real 7253-char digest
pooled, journal output. All three soak findings cleared on the real pipeline.

## Surprises / things worth recalling
- The read stage was about to **recreate** the problem — echoing the full transcript is itself a
  one-shot generation. Planning caught it; the recast pages the source via yt_get instead.
- `playlist_publish` takes the body as a **tool arg** — which would force the one-shot generation
  again. The bridge `playlist_publish_draft` pulls the body **server-side** by handle. This is the
  load-bearing detail of the whole pattern (same as doc_finalize).
- The video qwen digested in the e2e test: *"Don't build more AI agents until you watch this"* —
  argues agents improve through **harness maintenance, not more tools**. The thesis proving itself.
- `reflect_resume()` leaves the stale `reflect_pause_source` marker; clear it manually.
- work_items has `session_ids` (array), not `session_id`.

## Carry-forward
- **Generalize doc-construction** to book-digest + research-summary (still one-shot → reaper-prone).
  Pattern is proven; it's wiring + a per-pipeline finalize bridge where needed.
- **Re-add a separate critic stage** (reads the draft via doc_read, doc_patches objections) — the
  pilot folded the null-case into the builder; the distinct D&C 88:122 second-model pass is a follow-up.
- **Pgrx image rebuild** to bake `34-doc-builder.sql` (applied live + in the lib.rs chain; not yet in
  an image). Sweep the inert `doc-build-test` pipeline (FK-pinned) at that rebuild.
- **The 5-family local routing is live-only drift** — codify as a workspace overlay (or decide to keep
  the paid catalog default + a local overlay).
- **Reaper + judges**: config-ize the 15-min reaper (raise for local); route the 3 background judges
  (engram-extractor/judge-brief/watchman-consolidator, hardcoded to opencode_go) to local too.

## State at close
Autonomy **resumed, live on local, $0, guard clean.** Rig: qwen q8@192k (GPU0) + gemma q8 --parallel
4 @524288 + nemotron q8@512k (GPU1). Commits: parallelism ws `b2eb206`; doc-builder OSS `6145d51`;
playlist recast OSS `06282eb`. It was good.
