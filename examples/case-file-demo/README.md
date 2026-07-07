# case-file-demo — drop a folder of paperwork in, get an inspectable case file out

Four **synthetic** documents (no real person, insurer, policy, or claim) plus a
runnable walkthrough of the `case-file` pipeline's deterministic spine
(`examples/case-file-digester.sql`). The pack reproduces the shape of an
insurance-denial appeal:

| File | What it is | Typed facts it carries |
|------|------------|------------------------|
| `denial-letter.md` | the adverse determination | notice date, service date, **appeal deadline 2026-07-15**, amount $4,850.00, claim number, the cited policy section |
| `policy.md` | the policy excerpt the letter cites | sections `s1.1`–`s1.4`, including 4.2(b) |
| `claim-history.md` | three prior claims | dates + amounts, plus the emergency-care context |
| `supporting-note.md` | the evidence inventory | one item explicitly **NOT PROVIDED** |

## The planted contradiction (do not "fix" it)

The denial letter claims, citing Policy Section 4.2(b):

> "Pre-authorization is required for all outpatient procedures."

The policy's actual 4.2(b) reads:

> "Pre-authorization is required **only for elective, non-emergency** outpatient
> procedures. Emergency and urgent outpatient care is exempt…"

That mismatch is the **inverse-hypothesis fixture** for the `citation_check`
sanity oracle. The demo must CATCH it (verified=false, with the honest
nearest-excerpt of what the policy actually says), go CLEAN when the policy
text is temporarily fixed to match, and CATCH again when the plant is restored.
The pack ships with the plant — surfacing it as **Finding #1** is the point of
the whole demo.

## Run it

Prerequisites: the compose stack up (`pg` at minimum; the `bridge` service for
the citation-check step), and the digester applied:

```bash
docker compose exec -T pg psql -U stewards -d stewards < examples/case-file-digester.sql
docker compose exec bridge stewards-mcp bridge refresh-tools   # once, so the tool cache learns citation_check
examples/case-file-demo/demo.sh
```

`demo.sh` boots nothing; it drives psql against the running stack (override
with `PSQL="docker exec -i <container> psql -U stewards -d stewards"`). It:

1. ingests the 4 files via `file_drop_ingest` (the same deterministic path the
   drop watcher takes — you can equally copy the folder into
   `$STEWARDS_DROP_DIR/smith-appeal/` and wait one 30s poll),
2. queues the case (`case_add`) and runs `case_normalize_floor` — every doc is
   split into addressable sections and the typed fact floor is extracted
   (the deadline lands as a real `date` column, the amounts as `numeric`),
3. plays the normalize stage's two judgment writes by hand (deadline
   promotion via `doc_fact_add`, the missing physician letter via
   `evidence_set`) so the full spine runs with **zero models configured**,
4. runs `citation_check` through the bridge against the planted contradiction
   — CATCH → CLEAN → CATCH, asserted in both directions,
5. assembles + publishes the case file (`case_assemble` → `case_file_publish`,
   both server-side renders) and asserts the body contains the timeline with
   the deadline, the checklist with the gap first, the findings, the denial
   map, and section anchors.

Every step asserts its expected shape and exits non-zero on the first failure.

## Inspect the result

```bash
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT body FROM stewards.docs WHERE slug='case-file-smith-appeal';"
```

or, after the next projector pass, on disk under the knowledge tree
(`knowledge/docs/smith-appeal/case-file-smith-appeal.md` — kind `case-file` is
appended to `knowledge_projection.doc_kinds` by the digester import).

## The full pipeline (LLM stages)

The demo above is the floor. The real run — where models do the judgment
steps (normalize/sanity/letter) and the letter stage authors the one
generative section — is a normal work item (needs `examples/models.sql` + a
provider configured):

```bash
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT stewards.work_item_create('case-file',
     jsonb_build_object('assignment','Build the case file for the next case on the shelf.'),
     NULL, 'human', NULL,
     (SELECT id FROM stewards.intents WHERE slug='case-file'));"
# watch it walk: sections -> normalize -> sanity -> assemble -> letter
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT current_stage, status FROM stewards.work_items
    WHERE pipeline_family='case-file' ORDER BY created_at DESC LIMIT 1;"
```

(If demo.sh already ran, reopen the case first:
`UPDATE stewards.case_shelf SET status='queued', done_at=NULL WHERE slug='smith-appeal';`
and clear its ledger: `DELETE FROM stewards.case_citations WHERE case_slug='smith-appeal';`)

## The gate

The pipeline ends at the assembled case file + draft letter. Nothing sends
anything, and no send capability exists to be talked into:

```bash
grep -ri "case_.*send\|appeal_send" extension/*.sql examples/*.sql cmd/stewards-mcp/*.go
# zero results
```
