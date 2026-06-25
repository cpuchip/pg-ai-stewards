# 2026-06-25 — RC-2 complete: explore a DROPPED code archive (the unpack seam)

Michael (away, kids to bed): "finish rc-2 and rc-3 … I know you are capable of it."
With the loop as the ceiling under context depth — and it earned that trust.

## What shipped (the seam)

A dropped code archive (a zipped repo) can now be EXPLORED read-only in a sandbox
instead of embedded file-by-file. The hardened in-memory unpack already existed;
RC-2 writes the vetted members to a worktree and teaches the tools an attachment path:

- `docextract.Unpack` (exported) + `sandbox.UnpackArchiveToWorktree` → `writeMembers`
  (writes members under the worktree, `withinDir` re-verifies containment per write).
- `coder_sandbox_start` gains `attachment_id` (unpack instead of clone); `research_codebase`
  gains `attachment_id`; the doc_extract code-detection hint now says "call research_codebase
  with attachment_id=N to explore THIS dropped repo directly — no URL needed."
- 20-coder.sql tool_def + subagent prompt updated for the attachment path.

## The adversarial QA found a BLOCKER I missed — and it was severe

I hardened the archive MEMBER NAMES (zip-slip via the existing safeArchiveName) and
wrote a zip-slip oracle — but missed the OTHER untrusted input: the **sandbox id**.
`sanitize(".")=="."` and `sanitize("..")==".."`, so a prompt-injected `sandbox=".."`
makes `root=/worktrees/..` → **`rm -rf /` + `chown -R /`** on the bridge. Catastrophic,
and *pre-existing* in CloneRepo too. The QA (`wf_9059f0b6`) reproduced it empirically.

**Fixed in layers (all oracle-covered):**
- BLOCKER: `sanitize` strips leading dots (never "." / ".."); a `worktreeChildOK`
  strict-parent guard refuses any rm -rf/chown whose root isn't a direct child of
  /worktrees (applied to UnpackArchiveToWorktree AND CloneRepo — the sibling fix);
  a tool-boundary check rejects a sandbox id with path separators / whitespace / "..".
- HIGH: the reuse early-return skipped the unpack on an existing sandbox →
  attachment_id now always (re)unpacks. HIGH: the untrusted unpack inherited
  default-ON network → the attachment branch now forces `NetOff` (no egress, so even
  an exec-capable caller can't exfil from a dropped archive).
- MED: per-member structural scan (docextract.Scan, no-ClamAV-DB structural floor)
  skips malicious members, mirroring doc_extract's quarantine; tighter 128MB unpack
  caps (coupled to the 25MB upload cap); whitespace id-rejection closes the lossy
  sanitize-collision.

Oracle (`sandbox_test.go`): zip-slip (`TestWriteMembers_NoEscape`/`TestWithinDir`) +
`TestSanitize_ComponentSafe` (the "." / ".." blocker) + `TestWorktreeChildOK`. All Go
build/vet/test green; chain 00→53 virgin-smoke green (the 20-coder edits).

## Lesson (kept)

I hardened the input I was thinking about (archive names) and wrote an oracle for it —
then the adversarial pass found the input I wasn't (the id flowing into rm -rf). "I
wrote a zip-slip test" is not "I found every untrusted input." The destructive-op
guard (`worktreeChildOK`) is the lesson generalized: never let a derived path reach
`rm -rf`/`chown` without proving it's a child of the dir you meant.

## Deferred / carry

Full chat→explore-a-dropped-zip e2e needs the coder overlay + a model (dev-stack
bridge not yet rebuilt with RC-1/2). Nit: unpack warnings aren't surfaced to the
exploring subagent. RC-3 next (raise the converter ~120s cliff for bulk DOC import).
