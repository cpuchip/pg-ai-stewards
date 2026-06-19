# Local-rig throughput experiments — how much can we push through?

**Status:** EXPERIMENT PLAN (empirical; runnable now — no ratify needed, it's config + measure).
**Date:** 2026-06-19. **Companion to:** `agentic-doc-construction.md` (the deeper fix). Parallelism is
the cheap immediate lever; doc-construction is the structural one. They compound.

## Goal
Quantify the local FlexLLama rig's real throughput ceiling and validate the soak's contention finding:
does raising `--parallel` let more concurrent ingest through, and at what cost?

## Rig baseline (the dance, from the soak)
- GPU0: qwen3.6-27b q8 @192k (47 tok/s). GPU1: gemma-12b f16 @256k (94 tok/s) + nemotron-4b q8 @512k (223 tok/s).
- Each model runs `--parallel 1` → one request at a time → a long call monopolizes the slot
  (the soak's gemma-contention failure: concurrent ingest → HTTP "error sending request").
- Config: `external_context/flexllama/stewards-dance.json`. Harness: `external_context/flexllama/throughput_test.py`
  (`--both --pair a,b`), plus the soak metric queries in `.mind/sessions/pg-ai-stewards-soak-watch.md`.

## The KV tradeoff to watch
`--parallel N` splits a runner's `n_ctx` across N slots: at `--parallel 2`, gemma's 256k → ~128k per
slot; qwen's 192k → ~96k. So more concurrency = smaller per-request context. The book-`read` stage
needs a big window → find where shrinking it starts to hurt (reads overflowing the per-slot ctx). The
sweet spot is per-model and per-workload.

## Experiment A — gemma `--parallel` 1 → 2 (→4?)
1. Edit gemma's runner in `stewards-dance.json`: `"args": "--parallel 2"` (n_ctx stays 262144 → 131072/slot).
2. Restart the container; confirm load + per-slot n_ctx in `runner_g1a.log` ("new slot, n_ctx=").
3. Fire 2–4 concurrent gemma chats (`throughput_test.py gemma-12b --concurrency 2/4`) → aggregate tok/s,
   per-request tok/s, any errors. Then 4 → find the cliff.
4. Real test: dispatch 2 concurrent ingest work_items (book read + a gather) → do both complete, or does
   one still HTTP-timeout? Compare to the `--parallel 1` baseline (1 succeeds, 1 errors).
**Record:** aggregate throughput, per-req latency, contention-failure rate, per-slot ctx, VRAM (parallel
may raise compute-buffer use → watch the GPU1 headroom, ~1.9GB free with gemma+nemotron).

## Experiment B — reaper scope + threshold
Confirm whether the periodic reaper is per-call or per-work-item (load-bearing for doc-construction
finding #1). If per-call and config-izable, test raising "15min" → 30min for local; if hardcoded, note
it for the daylight fn change. (The reaper fn is hardcoded — no config key found in the soak.)

## Experiment C — split ingest across gemma + nemotron
nemotron sat **idle** all soak (ingest pri-1; gemma pri-0 always picked). Route some ingest to nemotron
(fast 223 tok/s, 512k) — e.g. book-read→gemma, gather→nemotron — and measure whether splitting the load
removes contention without raising `--parallel` at all. (Caveat: confirm nemotron's tool-call reliability
for gather loops — unproven; qwen/gemma proven.)

## Findings table — Experiment A RUN 2026-06-19 (autonomy paused for clean measurement)
| Exp | Config | Aggregate tok/s | Per-req tok/s | Contention fails | Per-slot ctx | Verdict |
|-----|--------|-----------------|---------------|------------------|--------------|---------|
| baseline | gemma --parallel 1, c2 | — | — | **2/2 WEDGED** (600s timeout; slot stuck 91% util, even a later c1 hung) | 256k | **hangs under concurrency** |
| A1 | gemma --parallel 2, c1 | 71.1 | 71.2 | 0 | 131k | single-stream -25% vs 94 (the cost) |
| **A2** | gemma --parallel 2, c2 | **155.2** | 77.7 | **0** | 131k | **2× throughput, both finish 1.5s, no wedge ✅** |
| A4 | gemma --parallel 2, c4 | 153.1 | 56.8 med | 0 | 131k | queues gracefully behind 2 slots; plateau = 2-slot ceiling |

**Verdict: adopt `--parallel 2`.** Doubles concurrent throughput (71→155) and ELIMINATES the wedge
(--parallel 1 didn't just contend — concurrent requests hung the slot indefinitely). Cost: lone-request
-25% (94→71) + per-slot ctx halved 256k→131k. The 131k is the only catch — a >131k book read would
overflow a slot → **this is why --parallel 2 pairs with `agentic-doc-construction.md`** (page-in keeps
reads bounded). LOCKSTEP if codified: gemma `context_window` 262144→131072 in live model_capability +
`overlays/flexllama-models.sql` + `--parallel 2` in `scripts/setup-flexllama.ps1` (dance.json already set).
Harness `throughput_test.py` timeout 600→120 (faster fail).

### Experiment B — Michael's "2× gemma / 4×130k" idea, done the efficient way (2026-06-19)
He asked for 2 gemma instances on one GPU for 4×130k. The efficient equivalent = ONE instance at
`--parallel 4 @ n_ctx 524288` (4 slots × 131072, weights loaded ONCE + continuous batching) vs 2
instances (duplicate ~7GB weights, compete for compute, won't fit beside nemotron). At f16 that's ~17GB
(no fit); **q8 KV → ~12.5GB → FITS beside nemotron** (GPU1 23.7GB loaded, 868MB free, no OOM, no spill).

| Exp | Config | c1 | c2 | c4 | c6 | per-slot ctx | Verdict |
|-----|--------|----|----|----|----|--------------|---------|
| B | gemma **q8 --parallel 4 @524288** | 69.7 | 147.3 | **248.7** | 192.1 (queues) | 131k | **peak at c4; +60% over --parallel 2's 153** |

**REVISED VERDICT: adopt gemma `q8 --parallel 4 @ n_ctx 524288` (4×131k).** GPU was NOT saturated at 2
slots — 4 slots push 248 tok/s aggregate (vs 153 at --parallel 2, vs --parallel 1 WEDGING). Fits beside
nemotron (q8 the enabler). The 4-schedule burst now runs all-4-concurrent, no queue/wedge. Cost: gemma
KV f16→q8 (fine for ingest), 868MB GPU1 headroom (tight but stable — watch if GPU1 gains other load).
LOCKSTEP to codify: gemma `context_window` → **131072** (per-slot; live model_capability +
`overlays/flexllama-models.sql`) + the q8/--parallel-4/524288 block in `scripts/setup-flexllama.ps1`
(dance.json already set). Per-slot value 131k is the same whether --parallel 2 or 4, so the lockstep is unchanged.
| C | gather→nemotron | | | | 512k | | |

## Connection
If `--parallel 2` clears contention cheaply AND the doc-construction reframe removes the long
monopolizing calls, the two together likely retire findings #1 and #2 entirely; #3 needs the
tool-call reframe (or routing grammar stages off qwen). Codify the winners into `stewards-dance.json`
+ `scripts/setup-flexllama.ps1` + `overlays/flexllama-models.sql` in lockstep (same discipline as the
qwen/nemotron q8 fixes).
