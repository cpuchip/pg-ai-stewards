# 2026-06-14 — M2 PR landed · M3 UI extracted+running · M6 coder works out-of-the-box

**Session:** pg-ai-stewards lane. Michael fixed the bridge PAT's repo-scope and
said: "finish the test… get OSS up and running fully before Sabbath. I have
plenty of tokens. I need help opus." Drove hard on the unblocked milestones,
braking only at the council/safety lines.

## What shipped (all pushed)

- **M2 fully closed — DRAFT PR #1 landed e2e** (`pull/1` on the throwaway
  `cpuchip/pg-ai-stewards-coder-proof`). Verified the token fix with a
  bridge-side dry-run push (exit 0) BEFORE burning a 4-min run. Fresh code-pr
  work item ran the full 7 stages to a real DRAFT PR.
- **M3 — the web UI is extracted and RUNNING** (`08850f6`). Ported
  `scripts/stewards-ui` (59 files, ~11K LOC Vue+Go, 23 views / **61** API
  routes) into `cmd/stewards-ui/` in the single OSS module — no go.work, no
  sibling stubs (the workspace `ui.Dockerfile` stubbed ~30 siblings; the
  clean-room one COPYs go.mod + cmd/). New `extension/ui.Dockerfile` +
  default `ui` compose service (local-only 127.0.0.1:8081) + a committed
  `frontend/dist/index.html` stub so `go:embed` builds outside Docker.
- **M6 coder hardening — code-pr works out-of-the-box now** (`6078771`),
  proven by a fully **autonomous** PR #2 (zero manual intervention).

## The doc_* rename was schema-verified, not blind

The UI's SQL referenced the old names. I checked each against the live OSS
schema rather than find/replacing:
- `stewards.studies` → `stewards.docs`
- `study_search_text(...)` → `doc_search(...)` — **non-1:1**, the name drops
  `_text` (a blind rename would've called a function that doesn't exist).
- `study_citations`/`study_similar` → `doc_*`
- `verdicts.study_id` → `verdicts.doc_id`
- `intents.scripture_anchor` → `intents.values_anchor` — and the `docs` table
  has **no** values_anchor column (it's an intents column); a blind
  `scripture_anchor→values_anchor` everywhere would have broken the build.

Go identifiers, `/api/studies/*` routes, and JSON field labels kept stable to
preserve the frontend↔backend contract. Cosmetic "Studies"→"Docs" relabel is a
polish follow-up, not a parity blocker. **The schema audit found every other
UI-referenced object (lessons, projects, providers_loaded, all functions)
already exists in the OSS core** — much less breakage than feared.

## Route verification: the oracle beat fan-out

Michael offered Opus fan-out for the UI port. I declined for the port itself
(it's an *integration* task — one module, one schema, sequential steps; N
agents editing the same files = the flat-coordination failure). For route
verification I used a **curl-sweep oracle** instead of fan-out: each check is
"is it an HTTP 500?", a mechanical check a script does with perfect recall.
Result: **0 × 500 across all 36 GET routes**; the 4 renamed surfaces
(studies/get, studies/search→book-self-reliance, intents/get, watchman/pass)
exercised with real data → all 200. The build-the-oracle-first principle again.

## Two real public-repo defects found and fixed (M6)

The code-pr pipeline shipped defaults that would stall for ANY cloner:
1. **Review model qwen3.7-max** — 401s on opencode oa-compat, 400s on Alibaba
   when tools are on (review needs coder tools to read the diff). → glm-5.1
   (tool-capable, opencode_go, non-qwen, ≠ the kimi implementer).
2. **Verdict parser start-anchored** (`^\s*REVIEW:\s*passes`). Models preamble
   before the verdict line (glm-5.1 does), so a genuine PASS misread as REVISE
   and parked at awaiting_review. → line-anchored `(^|\n)\s*REVIEW:\s*passes`
   (cv6 + cv11). This is what blocked PR #1 (worked around manually) and what
   PR #2 proved fixed.
3. **pr stage had no round cap** → could hit steps_exhausted on git ops. → 40.

Live-applied (MSYS_NO_PATHCONV=1 for the `docker cp` — the PR.1 path-mangle
lesson) and proven with a no-touch run: clone→…→review→pr→DRAFT PR #2, hands
off. The fix is the difference between "coder proven with manual nudges" and
"coder works for any cloner."

## M4 scheduler leg is already proven

The OSS scheduler is firing autonomously: book-digest hourly (22:00→01:00),
playlist-digest at 00:00, producing real docs — including `yt-RB8vjn1QPeM`
(the self-improvement-loop reference video, picked up off the playlist on its
own). So M4's scheduler half is done; only **personas** (the ⚠ key-safety bit)
remain.

## What remains (and the brakes)

- **M4 personas** — ⚠ key-safety. The persona *pipeline* can be verified safely
  via SQL dispatch with no gateway (no live-room double-fire). Connecting a
  persona to a REAL chat room needs Michael (live keys / a test room).
- **M5 compact_context** — ⚠ **council**. Net-new capability; dominion_in_council
  says do NOT build without Michael ratifying the parked questions in
  `substrate-compact-context-sidequest.md`.
- **M6 remainder** — stamp trigger default `acceptance_criteria=''`; bgworker
  should surface (not swallow) template-render errors; capability-aware model
  substitution (probe tool-use, not just chat). Polish, not blockers.
- **M7 soak** · **CUT** — the cut is Michael's Hinge session (stop live, archive
  volume, selective import).

## Notes / gotchas
- Port 8081 was transiently held by a sibling vite dev-server (PID 30556) — NOT
  killed (presiding covenant: no force on a sibling steward's process). Verified
  the UI on 8082 this run; the committed compose default stays 8081.
- OSS UI left running (on 8082 this session). The autonomous digesters keep
  running hourly on Michael's lent keys.
- Live OSS code-pr pipeline edits from M2 (glm gates, cap=40) are now reconciled
  to canonical source — no more live↔source drift on the coder.
