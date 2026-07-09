# 2026-07-08/09 — the voice-forge loop closes, and the substrate learns to talk about its own work

**The day in one sentence:** Stuffy wished for a tool by voice, approved its exact SQL
aloud, and the tool answered him with the day's burn rate — while the seat that carried
the conversation diagnosed a real routing failure and left a note for Opus that turned
into three shipped organs and a solved provider mystery.

## Shipped (all pushed)

**1. packs/companion/steward-tools.sql** — the verbs the first voice session was
missing, ratified verbatim by voice ("converse about work items and get them unstuck
and test out models"):
- `forge_start` — allowlisted because it is safe BY CONSTRUCTION: the forge registrar
  is bell-gated, so voice can only ever produce a plan awaiting approval. 5/hour.
- `work_item_unstick` — failed/awaiting_review only, validated model pin, verbal gate.
- `model_health` (read) + `models_health_check` (≤25 probes, least-recently-probed
  sweep so repeat calls cover the fleet).
All refusal + happy paths live-verified; first real heal = a July-4 research casualty
unstuck → completed. The write-access question Stuffy delegated ("what should the
voice surface be allowed to do?") is answered by this trio + the rationale in the
pack README's trust section.

**2. The voice-forge loop, closed end to end.** spend_report: wished by voice →
plan on the bell → approved by voice (the seat read the plan aloud first) → registered
→ called: today $0.06, yesterday $0.57, by pipeline. The register stage had parked
on "no model configured" — my own hygiene disables had emptied the `ingest` alias —
refilled with stream-proven deepseek-v4-flash.

**3. Spin holds the line for an hour.** Pipecat's 300s idle default cancelled two real
sittings (log-proven: "Idle timeout detected", 5min after last exchange, mic muted).
Companion mode now defaults 3600s, SPIN_IDLE_TIMEOUT_SECS overrides (spin 2c0b6c0).

## The Console Go mystery — solved by elimination

qwen3.7-plus and mimo-v2.5 failed ~25 dispatches over two days with "may not exist or
you may not have access" as SSE error events, while non-streaming probes passed. The
full real-path matrix (curls with keys compared by sha256 fingerprint only, never
displayed):

- models.dev: opencode-go = the SAME endpoint we use (`opencode.ai/zen/go/v1`), plain
  `@ai-sdk/openai-compatible` — the CLI has no special streaming method.
- CLI key ≠ substrate key (different fingerprints) — but BOTH stream the "broken"
  models clean, ±tools.
- bgworker.rs routes per-model via `model_capability.api_format`; these models ride
  the plain OpenAI path — the same surface as the passing curls. (Discovery en route:
  the substrate speaks Anthropic `/messages` to opencode for qwen3.7-max/minimax-m2.7.)

**Verdict: intermittent, model-specific Console Go waves.** The failures clustered
07-07 → 01:42; at 02:45 everything streamed green. My interim "permanently
stream-broken" call was too strong — revised in the catalog notes. The machinery
absorbs waves now (park → bell → model_health → unstick by voice); two filed
increments make it airtight: **#359** (probe the STREAMING path — non-stream probes
keep resurrecting wave-broken models) and **#360** (dispatch ignores
work_items.model_override/provider_override — pinned unsticks went to qwen twice;
fix order: item override > stage model > alias > substitution).

## Catalog healed

`kimi-k2.7-code` and `glm-5.2` were never broken on the go sub — just never seeded
(the catalog predates them). Added with models.dev pricing, curl-verified streaming
on the substrate's own key; kimi-k2.7-code joined the `reason` alias (the kimi the
review family always wanted; the seat tried to pin it by voice and it didn't exist —
now it does). glm-5.2's upstream identifies as `frank/GLM-5.2`.

## What the seat did right (worth keeping)

Bootstrap ritual completed unprompted (companion-profile: "Stuffy, conversational"),
reminder delivered mid-sentence, read the forge plan aloud before accepting approval,
consulted model_health before unsticking, flatly refused a nonexistent model string,
told the truth about zen-vs-go pricing, and left a precise note doc for Opus. The
walls held under real use.

## Carry

- #359 + #360 = the recommended FIRST FOREMAN ARC (constitutions ≈ tonight's evidence
  chains; oracle = verify-suite + live pin-honored repro).
- coder-proof-4: redispatched with healthy routing, review agent working the sandbox
  at close.
- Companion v2 verbs (Stuffy's Jarvis list): start_task-by-voice (gated like
  forge_start), doc reports by voice, summaries read aloud.
- #347 still awaits Stuffy's call (guard counting parked items as in-flight).
