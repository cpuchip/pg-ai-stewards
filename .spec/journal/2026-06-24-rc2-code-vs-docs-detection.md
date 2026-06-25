# 2026-06-24 — RC-2 (detection half): code-vs-docs classifier + doc_extract routing hint

Michael: "move on RC-2 and whatever else is left." RC-2 (F2) = when a CODE archive
is dropped, route it to *explore in a sandbox* rather than *embed every file*.

## What shipped (the safe, deterministic foundation)

- `internal/docextract/classify.go` — `Classify(paths []string) (kind, reason)`,
  kind ∈ {code, docs, mixed}. List-only (no content), so it's a pure oracle: a
  build manifest (go.mod / package.json / Cargo.toml / Dockerfile / …) or a `.git`
  directory is decisive for code; otherwise the dominant file class wins; ambiguous
  folders stay "mixed" so the caller asks rather than guesses. Oracle
  `classify_test.go` **14/14**.
- Wired into `doc_extract` (cmd/doc-extract-mcp/tools.go): a dropped archive now
  carries `repo_kind` + `repo_reason`, and when it's **code** the summary tells the
  agent to EXPLORE it (research_codebase / the RC-1 `/explore` path for a public
  URL) instead of embedding every file — `doc_import_corpus` only makes it
  keyword-searchable.

So the **routing brain** exists and is wired: a dropped code repo no longer reads
as "just another corpus to embed" — the engine recognizes it and recommends the
right path. No security surface (advisory, list-based), so no adversarial QA was
warranted (match rigor to risk; RC-1's clone lane needed it, this doesn't).

## Deferred — the untrusted-unpack seam (the hot half)

The FULL "explore a *dropped* code archive end-to-end" needs three more pieces,
one of which is a fresh untrusted-input security surface (the same class RC-1 just
had two real vulns in) — deliberately NOT rushed at session depth:

1. **Safe unpack into a worktree** — `sandbox.UnpackArchive(wi, bytes)`: unzip the
   attachment into `/worktrees/<wi>` with zip-slip + bomb caps (reuse
   `internal/docextract` archive caps — already hardened) + chown. READ-ONLY
   explore only (no exec), so the blast radius is bounded.
2. **`coder_sandbox_start` gains an `attachment_id` mode** (unpack instead of
   clone), or a sibling tool.
3. **`research_codebase` taught to explore a LOCAL unpacked tree** — today it only
   takes a repo URL (its subagent calls `coder_sandbox_start(repo=URL)`); a dropped
   zip has no URL. This is the genuine seam decision: extend research_codebase to
   accept an attachment, vs. a new `explore_archive` tool.

Recommendation: build #1 with its own zip-slip oracle + an adversarial pass (untrusted
unpack), then #2/#3. Until then, the detection hint steers a dropped code repo to the
RC-1 URL path (give the URL → `/explore`) or to import-as-corpus.

RC-3 (async corpus import — kill the 180s zip cliff) is still queued (#261).
