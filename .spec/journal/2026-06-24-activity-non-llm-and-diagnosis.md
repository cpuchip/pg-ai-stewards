# 2026-06-24 — Activity pane: non-LLM tool/sandbox pulse + a live diagnosis

Michael, using the live cockpit: "I dispatched new work under AI(50)… the model
errored out, look into that" + "can the activity feed show docker-container /
non-LLM activity, like virus scans?"

## The diagnosis (what actually errored)

"AI(50)" = the chat `stewdio-project-ai-mqsvo8va` (the "ai" project, 50 docs).
He attached the **pg-ai-stewards repo zip** (attachments 42/43). The agent called
`doc_import_corpus` (corpus "pg-ai-stewards-repo") and `doc_extract render=true` →
**both hit the converter deadline (~120s) → "context deadline exceeded"** → the
agent surfaced "I encountered a session error." So it was NOT the model — it was
`doc_extract` timing out on a big repo. **= the RC-3 gap, exactly as Michael
suspected ("premature without RC-2/3").** The real fix is RC-3 (async import) +
RC-2 (route code→explore, which we just shipped the detector for).

Separately there IS a real model wave, but it self-heals: opencode's free promos
are expiring — `opencode_zen/qwen3.6-plus-free` now 401 ("Free promotion ended");
~half of `opencode_go` 429. The **auto-probe correctly marks them unusable**, and
`reason` fails over to the **local flexllama gemma** (priority 0/1, both usable —
cost_events prove it's serving). LLM dispatch is fine; the dead members are just
probe-noise (a follow-up: prune the dead free members from the overlay seeds).

## What shipped — the Activity pane now shows non-LLM activity

`/api/activity` gained a `tools` array (a 5th parallel query): recent `mcp_proxy`
work_queue rows — each is a container the box spawns (doc-extract = ClamAV scan +
unpack; coder sandbox ops; etc.) with tool / server / status / error / duration.
The Activity (Details) pane renders a **"Tools & sandboxes"** section: in-flight
rows pulse (live containers), errored rows show the failure. Live-proven: it shows
`doc_extract → error → 120006ms` — i.e. it would have shown Michael "doc_extract
running 120s → error" instead of a silent stall, which is the whole point.

No docker socket needed (the UI API reads the work_queue from the DB). Additive,
read-only; oracle `dev-toggle.oracle.sh` 21/21 (+ Tools-&-sandboxes assertion).
The `scan_verdict` column would feed this too, but it's empty right now precisely
because the timed-out extracts die before ClamAV writes a verdict.

## Carry-forward

- RC-3 (async doc-extract/import — kill the ~120s cliff) is now the clear next
  build: a big repo zip should not synchronously block a chat turn.
- RC-2 detector is shipped; the dropped-archive→explore seam is still deferred.
- Optional: prune dead opencode free-tier members from the overlay model seeds
  (the engine handles it via failover, but it's noise).
