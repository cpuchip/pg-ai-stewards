# The files interface — drop in, project out

> v28 (`extension/v28-files-interface.sql` + the bridge's `dropwatcher.go` /
> `projector.go`). The two ratified increments from the files-as-interface
> verdict: **prose = files — projected FROM rows, authored IN files, ingested
> BY trigger.** Rows stay canonical (the ledger, the physics); files are the
> interface your editor, grep, and git already speak. This was the design's
> founding sentence before the substrate existed: markdown files "become
> *projections* of canonical rows, not the canonical store" (research verdict,
> 2026-05-02).

Both directions default ON in `docker-compose.yaml` — empty directories are
harmless, and each loop disables itself cleanly (one clear log line) when its
directory is missing.

## Data in: the drop directory (`./drop` → `/drop`)

Put a file under `./drop/` and within one 30-second poll the bridge ingests
it. **Poll-first is the contract** — inotify does not survive Docker Desktop
bind mounts on Windows, so there is no watcher to trust.

Routing rules:

| What | Where it goes |
|---|---|
| `drop/<project>/anything.md` | Pooled as a searchable doc, `project_association = <project>` (first path segment = project hint) |
| `drop/anything.md` (at the root) | Pooled with no project hint |
| `.md` / `.txt` (valid UTF-8) | `stewards.file_drop_ingest` → the standard `import_doc` pool path (doc + CITES graph; embedding rides the existing trigger and degrades to unembedded with no models — the lifeless core holds) |
| PDF / Office / zip / images / anything else | `stewards.file_drop_ingest_binary` → a durable `chat_attachments` row + the existing doc-extract `doc_import_corpus` path (**requires the `docker-compose.doc-extract.yaml` overlay**; without it the ledger records the failure honestly and the bytes stay safe in the attachment) |
| Dotfiles, `.git/`, `Thumbs.db`, `~$*`, `*.tmp`… | Skipped |

**Freshness:** every drop is sha256'd into the `stewards.file_drops` ledger.
Re-drop the same content → skipped silently. Re-drop *changed* content → the
same doc is re-ingested and the prior revision is archived in
`stewards.doc_versions` (the substrate's normal update idiom). Errors land as
`status='error'` rows with the reason — check `SELECT * FROM
stewards.file_drops ORDER BY first_seen_at DESC`.

## Data out: the knowledge tree (`./knowledge` ← `/knowledge`)

The projector writes wiki pages, pooled docs, and lessons as a greppable,
PR-able markdown tree:

```
knowledge/
  wiki/<scope-or-collection>/<slug>.md
  docs/<project>/<slug>.md
  lessons/lesson-<id>-<kind>.md
```

Every file carries YAML frontmatter (id, kind, project, `source_updated_at`,
`projected_at`, and a provenance line naming the database as the canonical
store). Writes are atomic (temp + rename); rows that vanish or leave scope
get their files deleted. Which doc kinds project is config:
`knowledge_projection.doc_kinds` (default `["doc","study"]`).

Cadence: once at bridge startup, hourly, and on demand:

```sh
stewards-cli project            # fire a pass now (NOTIFY to the bridge)
stewards-cli project --pending  # preview what the next pass will do
```

**Git, free:** make `./knowledge` a git repo (`git -C knowledge init`) and the
projector commits each changed pass (`projection: <n> changed`) — history of
your substrate's prose for nothing.

**One-way by default:** edits inside `knowledge/` at large are never read
back. The drop directory is the general write path — copy the file into
`drop/` (or just author it there) and the freshness ledger does the rest.
The one registered exception is below.

## Both directions: db-projected workspaces (`knowledge/_workspaces/`)

> v30 (`extension/v30-workspaces.sql` + the bridge's `workspacewatcher.go`
> and the workspace pass in `projector.go`). The ratified direction
> (.spec/proposals/db-projected-workspace.md): *"spin up claude code in a
> db projected file system, where the updates land live in the db."*

A **workspace** is an opt-in, per-scope *writable* projection: one scope of
the database (a project, a wiki, a world's canon corpus, a doc kind)
projected into its own directory, with write-back armed. Open the directory
in any harness — Claude Code via loom, a plain editor, a remote seat — and
saves land as canonical rows within one 30-second poll.

```sh
stewards-cli workspace create my-case --scope project:my-case --for-loom
#   -> prints the absolute host dir + a ready-to-run:
#      loom run --workdir <knowledge>/_workspaces/my-case
stewards-cli workspace list
```

The contract:

- **Opt-in per workspace, never global** — only dirs registered in
  `stewards.knowledge_workspaces` are ever read back (the wall).
- **Never silent clobber** — a sha triple (projected / file / row) decides
  transactionally in SQL. File changed + row unchanged → the file wins
  (it is the authoring surface): the row updates through the normal
  revision idiom (prior version archived in `doc_versions` /
  `wiki_page_revisions`). BOTH changed → the file's version parks in
  `stewards.workspace_conflicts`, ONE deduped item lands in
  `needs_attention`, the row is untouched, and the path freezes both
  directions until you resolve:
  `SELECT stewards.workspace_conflict_resolve(<id>, 'row-wins'|'file-wins'|'dismiss');`
- **Provenance on every write-back** — `doc_versions.changed_by =
  workspace:<name>:<actor>`, a `workspace_writeback` frontmatter stamp on
  the doc, `last_writeback_at` on the registry row.
- **New files become new rows in the scope** — a file with no frontmatter
  identity creates a doc (or wiki page) inside the workspace's scope; the
  projector then rewrites the file with identity frontmatter. A file
  claiming a row *outside* the scope is a conflict, never a write.
- **Live = one poll** — 30s file→row (the watcher), ~1s row→file after any
  write-back or `workspace_create` (NOTIFY-driven re-projection).

Deleting a *file* in a workspace is not a signal (rows are canonical; the
file returns on the next row change). Delete rows DB-side and the projector
removes the file.
