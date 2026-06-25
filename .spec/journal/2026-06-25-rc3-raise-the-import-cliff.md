# 2026-06-25 — RC-3: lift the ~120s bulk-import cliff (per-tool timeout)

The third of Michael's "finish rc-2 and rc-3." Closing the cliff his real use hit:
a big archive dropped in chat → `doc_extract` / `doc_import_corpus` → "context
deadline exceeded (session invalidated)" at exactly 120006ms.

## The actual cliff (diagnosed, not guessed)

Three timeouts stack: the bridge daemon's per-tool-call timeout
(`bridge_run.go:59 --call-timeout 120`), the extract container (180s), and the
converter's own `-timeout 120` (`cmd/doc-extract/main.go`). The BINDING one is the
bridge daemon's **uniform 120s** applied to every mcp_proxy call — that's the
"session invalidated" + 120006ms. A bulk extract over hundreds of files
legitimately needs minutes, so it died there.

## The fix (surgical, Go-only, in the bridge image)

- `bridge_run.go`: a `--slow-call-timeout` (default **600s**) for an
  inherently-slow tool set (`doc_extract`, `doc_import_corpus`, overridable via
  `STEWARDS_SLOW_TOOLS`); every other tool keeps the snappy `--call-timeout 120`
  (so a hung fast tool still bounds quickly). `dispatchOne` now reads the payload
  first, then applies the per-TOOL timeout — `callTimeoutFor` (oracle-tested).
- `runner/run.go`: `ExtractArgs.TimeoutSecs` raises BOTH the converter `-timeout`
  and the container ctx (a window slightly larger than the converter's, so the
  converter reports cleanly instead of a docker SIGKILL).
- `doc-extract-mcp/tools.go`: both extract paths pass `TimeoutSecs = 540` (under
  the 600s bridge window). Aligned chain: bridge 600 ≥ container 570 ≥ converter 540.

A fast single file finishes early regardless (the high value is a ceiling, not a
floor). A slow import blocks one of the 4 bridge workers for its duration; it's
visible the whole time in the Activity → "Tools & sandboxes" pane (the feature
built this session). Oracle `bridge_run_test.go` `TestCallTimeoutFor`; go
build/vet green.

## The honest design call

Task #261 framed RC-3 as "async work item + progress card." I chose the simpler
mechanism that removes the actual problem ("no 180s cliff"): **raise the cliff 5×
for the slow tools** rather than rearchitect the import into a return-immediately
background job. Reasons: (1) RC-2 already routes the common painful case — a CODE
repo — to explore-in-sandbox, which has NO extract step and NO cliff; (2) the
remaining case (a genuinely huge DOC corpus) now fits the 600s window; (3) a full
async job crosses the Go-tool / Rust-bgworker boundary and fights the single-
threaded-per-process bgworker — real over-engineering for a rare case. If big
corpora become common, the async version is the next step (the slow-tool plumbing
+ the activity feed are the foundation it would build on). The cliff — the thing
that broke his chat — is gone.

## Carry

The dev-stack bridge + pg still need a rebuild to bring RC-1/RC-2/RC-3 live there
(all the Go is in the bridge image; pg has the 53 grant + 20-coder). That deploy +
end-to-end verification is the immediate next step.
