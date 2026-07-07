# The DB-Projected Workspace — spin up Claude Code inside the database

**Status:** RATIFIED-in-direction 2026-07-07 (Michael): *"for local installs maybe even
through loom I envision a world where we could (you or me, even remotely?) spin up
claude code in a db projected file system, where the updates land live in the db."*
Design decisions below are the steward's execution calls under that mandate; Michael
overrides on intent.

## The idea

The projection tree (v28) made rows readable as files. This makes the projected tree
**writable**: a harness — Claude Code via loom, codex, a human in VS Code, a remote
seat over the mesh — opens a directory that IS a scope of the database, edits files,
and the edits land live as canonical rows with provenance and revision history. The
filesystem becomes the API. No MCP required for authoring; grep/edit/save is the whole
contract. This completes the founding 2026-05-02 promise (".mind/ files become
projections of canonical rows") in both directions, and it is the Workspace-Host
vision ("graph-in-DB, work-in-transient-workspace") landing on the files interface.

## What it reuses (almost everything)

- **v28's sha state**: `knowledge_projections.content_sha` was designed as the
  conflict-detection anchor. `file_drops`' freshness path (changed sha → update via
  `import_doc` ON CONFLICT + `touch_doc` → prior revision archived) is the write-back
  mechanism, already proven.
- **The projector**: already projects with frontmatter carrying row identity — the
  write-back reads the same frontmatter to know which row a file IS.
- **loom**: workdir mounting exists (role home + `/work`); `loom serve` (7791) +
  NetBird mesh = the remote seat story with zero new transport.
- **D1B (#318, ratified + built)**: harness write-back with a narrow write set is
  already a standing capability; this widens the *medium* (files instead of tool
  calls), not the trust envelope.

## Design decisions (execution calls, stated for override)

1. **Opt-in per workspace, never global.** The knowledge tree stays one-way by
   default. A *workspace* is an explicitly created projection with write-back armed —
   `stewards-cli workspace create <scope>` (a project, a world, a wiki collection, a
   case file) projects the scope into its own directory and registers it in a
   `knowledge_workspaces` table (scope, dir, mode=rw, created_by, session).
2. **Never silent clobber.** Write-back applies a file edit when the source row is
   unchanged since projection (file wins — it is the authoring surface). If BOTH the
   row and the file changed since projection, the conflict parks in `needs_attention`
   with both versions; a human (or an explicitly granted agent) resolves. The sha
   triple (projected sha, current file sha, current row sha) decides deterministically.
3. **Provenance on every write-back**: actor (loom seat / session id / 'file-edit'),
   workspace id, file path, shas. The ledger sees file edits exactly as it sees tool
   calls.
4. **The wall**: write-back reads ONLY registered workspace dirs and writes ONLY the
   rows its scope projects. New rows (a new file in the workspace) are created within
   the scope's project/kind and flagged in the receipt. Frontmatter identity is
   verified against the registry — a file claiming a row outside its scope is a
   conflict, not a write.
5. **Live means the poll cadence** (the v28 watcher pattern, 30s; inotify still
   untrusted across Docker Desktop mounts). "Live in the db" = within one poll of
   save. NOTIFY-driven re-projection closes the other half of the loop so concurrent
   readers see row-side changes land in the tree.

## Phases

- **P1 — write-back on a scoped subtree**: `knowledge_workspaces` registry + the
  watcher extension (reuse dropwatcher's scan/sha discipline against workspace dirs) +
  conflict machinery + provenance. Oracle: edit-file→row-updated-with-revision;
  row-and-file-both-changed→needs_attention conflict, nothing clobbered (inverse-proven).
- **P2 — the loom seat**: `stewards-cli workspace create --for-loom <scope>` emits the
  dir + a ready-to-run `loom run --workdir <dir>` line; a Claude Code session authors
  in the projected scope; saves land as rows while the session runs. Oracle: a real
  loom dispatch edits a projected doc; the row updates with session provenance before
  the session exits.
- **P3 — remote**: the same workspace served to a remote seat via loom serve over the
  mesh. No new machinery expected beyond docs + a proof run (the mesh + serve exist);
  named as a phase so the proof is deliberate, not assumed.

## Relation to the running waves

Wave 1 (honesty patch) and Wave 2 (normalize + receipt) are independent. The case-file
digester (Wave 3) becomes this feature's best demo: project a case workspace, let a
harness refine the draft letter in files, watch the revision land in the ledger.
