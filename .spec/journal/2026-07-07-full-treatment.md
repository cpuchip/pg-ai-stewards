# 2026-07-07 — The full treatment: from a war-game mirror to Claude Code living inside the database

**Arc:** the same day as the lightening merge. Michael merged PRs #31/#32 to main in the
morning, sent a video as a mirror ("just something to reflect against"), and the
three-seat war-game panel (MAPPER/SKEPTIC/DEMO-PATH,
`.spec/wargames/2026-07-07-pipelines-skeleton/`) re-scored where we live. He then said
"let's do this, the full treatment" and added the vision that became the day's crown:
*"spin up claude code in a db projected file system, where the updates land live in the
db."* Delivered as **PR #33** (six commits, four builders + lead, chain v00→v30).

## What shipped

1. **v29 normalize + honesty** (Builder J) — the panel's missing primitive: typed
   `doc_facts` (verbatim spans required, kind-matched value constraints at tool AND
   table), `evidence_items` (missing documents as first-class, checklists gap-first),
   the deterministic parser floor, `doc_sections` structural chunking (the narrow
   exception the 2026-05-15 engram trade anticipated). Honesty: file_drops errors ring
   needs_attention exactly once per path — via a DEFERRED constraint trigger, because
   ingest writes a transient error row in the same transaction and a plain trigger
   would ring on every success. README stopped overpromising.
2. **Intake + the Receipt** (Builder K) — file_drops got its face the same day the
   SKEPTIC caught it faceless; every work item now opens with the reviewer-shaped
   receipt (*what was read / what changed / what needs you*) with honesty labels for
   what the ledger can't reconstruct (loom-shim stages named explicitly).
3. **v30 DB-projected workspaces** (Builder M, worktree) — the vision's machinery:
   workspace registry, sha-triple write-back IN SQL (transactional; file wins when row
   unchanged; both-changed parks with all three shas, never clobbers — inverse-proven),
   provenance on every write-back, scope walls on frontmatter identity, the projector
   riding its existing pass, `stewards-cli workspace create --for-loom`.
4. **Case-file digester + citation_check** (Builder L) — facts rendered server-side
   from typed rows so the model composes nothing it could misremember; the LLM authors
   only the letter; the text-vs-text oracle inverse-proven on the real MCP stdio path
   against a deliberately planted contradiction that SHIPS with the demo. No send tool
   exists — the gate holds by construction.

## The seat proof (the day's best minute)

Scratch stack, real `loom run -dir <projected-workspace>`: a Claude Code session opened
the directory, edited the projected doc as an ordinary file, and within one poll the
row updated — revision archived, `changed_by=workspace:seat-ws:file-edit`, the new
section readable from the database. Asked to describe the experience, the seat wrote:

> "Writing here feels like ordinary file editing until you remember that every save
> quietly becomes a database row, which makes the markdown feel less like a document
> and more like a friendly costume the data wears for me."

The founding 2026-05-02 verdict promised ".mind/ files become projections of canonical
rows." Twenty-six days later the projection breathes both directions, and the first
words written back through it were about itself.

## Lessons worth keeping

- **The panel→build pipeline worked end to end in one day**: opposed-mandate seats with
  receipts-required found three converged gaps; DEMO-PATH's estimate (3.5–4 sessions)
  landed almost exactly; SKEPTIC's sharpest catch (a table born yesterday already
  faceless) was fixed the same day it was found.
- **Builders keep catching what specs can't**: J's deferred-trigger insight (transaction-
  transient states), M's converged-heal case (watcher-races-projector), L routing around
  my in-flight merge via `git archive` from committed HEAD, H's earlier now()-is-
  transaction-constant catch. The independent-verify + inverse-hypothesis discipline is
  the floor that makes their speed safe.
- **Worktree isolation earns its cost exactly when two builders need the chain tail** —
  the lib.rs adjacency merge was trivial because M declared its integration note in the
  file itself.

## Carry-forward

- **PR #33 = Michael's Hinge.** Post-merge: live deploy (bridge rebuild + v28–v30 SQL
  apply — the same snapshot-restore discipline is NOT needed this time [no live strips],
  but the bridge restart window still wants the in-flight drain) + the first LIVE
  case-file demo with a real model (the letter stage, flagged unrun per verify_real_path).
- The cosmetic `--workdir` vs `-dir` hint mismatch in workspace.go's emitted loom line.
- citation_check onto the read-only HTTP profile (candidate, L's flag).
- #338 steward retry-lane fix; W2 remaining halves; D2A packs (the case-file digester
  and the six standalone PACK volumes are its ready-made cargo).
- P3 remote seat (loom serve over the mesh into a projected workspace) — machinery
  exists, the deliberate proof run is unperformed.
