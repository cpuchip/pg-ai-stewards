# DEMO-PATH — the shortest real path to Build 2 (the insurance case file)

**Mandate:** design the shortest real path from merged `main` to a live, honest reproduction of "Every AI Agent Demo Stops at Email" (Nate B Jones, 2026-07-03, `yt/ai-news-strategy-daily-nate-b-jones/U4TmrlWEY4M`) **Build 2**: drop a folder of delicate paperwork in, get an inspectable case file out. Not a slide deck of what the substrate *could* do — a runnable sequence, with an oracle at every step, that a human can execute today and watch fail honestly or pass honestly.

**Substrate assessed:** merged `main`, `extension/v00…v28`. Cross-referenced against `MAPPER.md` in this same directory (the 9-primitive grading pass) — where MAPPER answers "do we have the primitive," this document answers "given what we have, what's the smallest build, in what order, with what proof." No claim below is asserted from memory; every load-bearing one carries a `file:line` receipt, and everything marked **NEW** is a proposal, not a finding.

---

## 0. The bar, restated precisely

Build 2's shape, read straight off the transcript (`transcript.md:138-180`): context pack (denial letter + policy + claim history + supporting docs; goal = "a case file I can inspect," not a vibes letter, `t477-t481`) → chunking into tagged, addressable pieces (`t487-t506`) → normalizing (dates as dates, amounts as amounts, **missing documents as missing documents**, `t509-t516`) → stored locally, inspectable (`t523-t532`) → retrieved by structure, not vector search — "you already know the address" (`t541-t549`) → sanity check: does the cited policy section actually say what the letter claims? Mismatch = finding #1 (`t563-t570`) → export: timeline, denial map, exact policy language, evidence checklist (have/missing), draft appeal letter, all citation-anchored (`t572-t589`) → gate: the agent never sends; it stops with a receipt (`t625-t655`).

---

## 1. What already exists (verified this session, condensed — full grading in `MAPPER.md`)

| Step | Verdict | The load-bearing receipt |
|---|---|---|
| **Context pack** | HAVE, sharper than guessed | `a2a_submit`'s required `spec` object is literally `{outcome, sources, context, allowed_actions, stop_condition, definition_of_done}` (`extension/v13-a2a.sql`) — a formal context-pack shape already exists at the work-item boundary. Pair it with `tool_groups`/`agent_tool_perms` scoping (`extension/v09-routing-and-hinge.sql:40-56`) for "what the agent may touch," and the pack is fully expressible as data on a new work item, zero new code. |
| **Ingest** | HAVE, core | `stewards.file_drops` (`extension/v28-files-interface.sql:69-90`) + `cmd/stewards-mcp/dropwatcher.go` (30s poll, sha256 identity, `file_drop_ingest`/`_binary`). Plain text/markdown ingests fully in core, zero overlay. PDFs route through `doc-extract` (opt-in overlay, see §6). |
| **Chunk (structural)** | **the sharpest tension, not just a gap** | The substrate deliberately *walked away* from deterministic leaf-chunking in council: `extension/v04-context-engine.sql:11-23` names the dropped `l14…l17` leaf-chunk-and-embed chain, replaced by judge-compiled-brief engram extraction (ES.3, 2026-05-15). `doc_import_corpus`'s only remaining chunker is size-based (`~12000 chars`, `cmd/doc-extract-mcp/tools.go:69-95`) — not structural. There is **no existing case for un-reversing that ruling** except this one: a denial letter and a policy document have real, cheap, structural fields (a date, a claim number, a section number) the way a research PDF does not. Building a narrow, domain-scoped structural chunker here is not a reversal of ES.3 — it's the one workload ES.3 didn't have in view. |
| **Normalize (typed dates/amounts/missing-docs)** | **MISSING, confirmed, no substitute of any shape** | Checked (grep, zero hits): `structured_data`, `extracted_fields`, `normalize_field`, `typed_extract` anywhere in `extension/`. `graph_node_upsert`/`graph_node_tool` (`extension/v00-foundations.sql:175-191`, `v09-routing-and-hinge.sql:1216-1234`) gives a generic `props jsonb` write primitive an agent *could* fill with `{amount, deadline}` — but nothing parses a date out of prose today, and jsonb an LLM fills on a good day is not a typed, CHECK-constrained column. |
| **Store, inspectable** | HAVE, deeper than the video's SQLite framing | `stewards.docs` + `file_drops` + `doc_versions` (append-only revision archive on re-drop) — real FKs, real CHECK constraints, queryable via `psql` or the Stewdio UI. Heavier to open than a `.db` file a non-technical user double-clicks (the weight tension, §7). |
| **Retrieve by structure** | HAVE | `stewards.doc_get(slug)` / `stewards.doc_citations(slug)` are pure address-known lookups, no embedding involved (`cmd/stewards-mcp/tools.go:38-53`). |
| **Citation-anchored chunk addressability** | HAVE as a *convention*, not yet as *our* table | Found **twice** already in the codebase, independently: `stewards.page_sources.chunk_ref` — "free-form pointer into the doc (a heading, a line range, a message id)" (`extension/v20-wiki.sql:198-210`) — and `stewards.world_entities.source_refs jsonb` — `[{doc, chunk, quote}]` (`extension/v11-loreworks.sql:44-45`). The case-file chunk table below (§3, Increment 1) is a *third instance of an already-proven shape*, not an invention. |
| **Sanity check (cited section vs. actual text)** | GAP, but the pattern is proven adjacent | `stewards.doc_citations`/`doc_citations_resolved` (`extension/src/schema.rs:1604-1793`) resolve a cited **URI**, never re-check the cited **text**. The one genuine text-verification oracle in the repo, `scripts/verify-digest-quotes/verify-digest-quotes.py`, is hardcoded to `book-<slug>`/`yt-<id>` sources and gates the *materialize* step, not the *draft* step — its own roadmap names the fix: "a future `verify_quotes` substrate tool could let the critic check its own quotes... before publish — moving the gate left, into the run" (README, "Roadmap"). Build 2's sanity check **is that roadmap item**, generalized to a new source pair. |
| **Export (structured multi-part packet)** | PARTIAL, cheaper than guessed for the *materialization*, but "structured" needs a design choice | The knowledge projection tree (`extension/v28-files-interface.sql:417-507`, `cmd/stewards-mcp/projector.go`) needs **zero new code** for a new doc kind — appending `"case-file"` to `knowledge_projection.doc_kinds` config (`v28:573-576`) is the entire lift. What it does NOT give you is *structure* (a timeline object, a denial-map object) — it projects prose. §3 below resolves this with a specific design choice (server-rendered facts, LLM-authored letter only), not a new schema layer. |
| **Gate (never sends, leaves a receipt)** | HAVE, structurally deeper than the video's | `tool_confirm_gate`/`tool_confirm_apply` (`extension/v17-gates-worldchat.sql:243-297`) — a tool tagged `effect_class='dangerous'` is **WITHHELD**, never executed, until a human approves. `stewards.needs_attention` view (`v19-platform.sql:371-433`) and `a2a_receipt` (`v13-a2a.sql:513-580`) hold the receipt *data* but not yet assembled into one screen — the gap is UX synthesis, not substance (MAPPER's finding, confirmed). |

---

## 2. The gap list

Five real gaps, ordered by how much new *design judgment* each one costs (not file count — most of these are small):

| # | Gap | Why it's real | Shape of the fix |
|---|---|---|---|
| **G1** | No structural chunk table for a denial letter / policy document | Confirmed above — ES.3 removed the general mechanism on purpose | **NEW** `case_chunks` table, third instance of the proven `{doc, chunk_ref, quote}` shape |
| **G2** | No typed normalization (dates/amounts/missing-docs as first-class rows) | Confirmed above — zero substitute anywhere in 28 volumes | **NEW** `case_facts` table with real `date`/`numeric`/`boolean` columns, not jsonb |
| **G3** | No citation sanity-check that compares two *texts*, only two *URIs* | `doc_citations` resolves URIs; nothing diffs claimed-text vs. actual-text | **NEW** in-turn tool (`case_citation_check`), Go, stdlib string compare — see §3 for why not Python/pg_trgm |
| **G4** | No domain export template (timeline / denial-map / evidence-checklist as *facts*, not prose an LLM might misremember) | The projection tree exports whatever body text lands in `stewards.docs`; nothing renders case_facts into a section deterministically | **NEW** SQL function `case_section_render()` — server-side markdown from typed rows, LLM never re-types a fact |
| **G5** | No one-screen receipt | Confirmed by both this research and `MAPPER.md` independently | **NEW** SQL function `case_receipt()` assembling existing ingredients (`doc_citations_resolved` shape + case_facts completeness + a fixed "needs your review" line) |

Everything else — ingest, storage, retrieval, projection, the gate primitive, the pipeline engine, `route_on` — is reuse. No new Go/Rust engine code is required anywhere; G1/G2/G4/G5 are SQL tables and functions, G3 is the one piece that needs the bridge (Go) because it must run **synchronously inside a pipeline turn** so `route_on` can branch on its verdict same-turn.

---

## 3. The build plan

**Design decision that resolves G4 honestly:** the case file has two kinds of content, and they should not be built the same way. *Facts* (timeline, denial map, exact policy language, evidence checklist) are queries, not compositions — an LLM asked to "write the timeline" is exactly the vibes-letter failure mode the video is arguing against. So those four sections are **server-rendered** from `case_facts`/`case_chunks` by `case_section_render()` and the model's only job is to paste the rendered markdown verbatim via `doc_append_section` — it cannot drift from the DB even on a bad day. The **draft appeal letter** is the one genuinely generative section, and it must cite `chunk_ref`s pulled from the same tables, so it stays checkable the same way. This is the single design choice that makes "case file, not vibes letter" real rather than a slogan.

All new SQL below lives in **one new file, `examples/case-file-digester.sql`**, mirroring `examples/book-digester.sql` line-for-line in structure (shelf table → next/publish tool pair → pipeline row → schedule) — same reuse posture as the existing worked example, applied to a new domain. This keeps it out of core (`extension/`) per the overlays boundary (`overlays/README.md:1-6`: core is domain-free; domain content is examples/overlay) while staying runnable with one `psql < examples/case-file-digester.sql` after core.

| # | Increment | Builds on | Oracle (the done-signal) |
|---|---|---|---|
| **0** | Ops prereq: bring up the doc-extract overlay if any source doc is a PDF | `docker-compose.doc-extract.yaml` (already ships, opt-in) | `docker compose -f docker-compose.yaml -f docker-compose.doc-extract.yaml ps` shows `doc-extract` healthy; a dropped test PDF flips `file_drops.status='ingested'`, not `'error'` |
| **1** | Schema: `case_shelf` (mirrors `book_shelf` exactly — slug/title/status), `case_chunks` (doc_id, chunk_ref, kind CHECK IN date/denial-reason/claim-number/deadline/evidence-para/policy-section/definition/exclusion/appeal-rule, quote, claims_section), `case_facts` (case_slug, fact_type CHECK, value_date date, value_amount numeric, value_text text, is_missing bool, source_doc_id, chunk_ref) | `book_shelf`'s exact shape (`examples/book-digester.sql:17-31`) | `\d stewards.case_shelf` / `case_chunks` / `case_facts` show the expected columns; one manual INSERT + SELECT round-trips each table |
| **2** | Ingest convention: drop `STEWARDS_DROP_DIR/case-<slug>/*` (4 synthetic files); no new code | v28 drop-by-file (`v28-files-interface.sql` §4/§5) | 4 files dropped → 4 `stewards.docs` rows with `project_association='case-<slug>'`; `file_drops.status='ingested'` for all 4; re-drop the same files → `skipped_unchanged` |
| **3** | `case_chunk_add` tool (~40 lines SQL, styled on `observation_add`, `extension/v26-knowledge.sql` §2) + a **chunk** pipeline stage whose prompt walks each dropped doc via `doc_get` and tags spans | `observation_add`'s validate-then-insert shape | `SELECT kind, count(*) FROM stewards.case_chunks WHERE case_slug=... GROUP BY kind` — every required tag present at least once (5 for the letter, 3+ for the policy) — a completeness check, not a vibes read |
| **4** | `case_fact_add` tool + a **normalize** stage (typed args: fact_type + exactly one of value_date/value_amount/value_text/is_missing, DB CHECK enforces the exclusivity — dates are DATE columns an LLM cannot mangle into a string) | `case_chunks` from Increment 3 | `SELECT * FROM case_facts WHERE fact_type='appeal_deadline'` returns exactly one row, a real `date`, not NULL |
| **5** | `case_citation_check` — **NEW Go tool** (`cmd/stewards-mcp/`), not Python/pg_trgm. For every `case_chunks` row `kind='denial-reason'` with a `claims_section`, fetch the matching `kind='policy-section'` row by `chunk_ref`, normalize both quotes (lowercase, collapse whitespace), substring-check. Verdict per pair: `MATCH` / `MISMATCH`. On MISMATCH: insert two `observations` rows (`extension/v26-knowledge.sql:48-70`) — the letter's claim, then the policy's actual text with `counter_of` pointing at the first. This *is* "finding #1," expressed in the schema's own counter-evidence idiom, not a bolted-on flag. A **sanity_check** stage calls this tool and emits a sentinel line (`"MISMATCH: N"` / `"CLEAN"`) for `route_on`. | `observations.counter_of` (already first-class, `v26:64-65`); `verify-digest-quotes.py`'s substring-check logic, ported to Go because a pipeline stage needs a synchronous in-turn tool call, not an external batch script — *why not pg_trgm*: the codebase twice states "no pg_trgm" as a deliberate boundary (`extension/v02-governance.sql:4977`, `v22-route-intake.sql:79`); exact/normalized substring matching (what `verify-digest-quotes.py` uses as its *primary* check before fuzzy) respects that boundary and is the right strength for policy language, which is usually quoted near-verbatim in a denial letter | **Inverse-hypothesis test (the load-bearing oracle of this whole build):** run against the synthetic pack with the planted contradiction (§5) — MUST report 1 mismatch. Edit the synthetic policy doc to remove the contradiction, re-drop (new sha), re-run — MUST report 0. Both directions checked, not just "it flagged once." |
| **6** | `case_section_render(case_slug, section)` — SQL function rendering Timeline / Denial Map / Exact Policy Language / Evidence Checklist as markdown straight from `case_facts`/`case_chunks` (no LLM in this path) + a **route_on** rule on the sanity_check stage's sentinel (`extension/v09-routing-and-hinge.sql:818-834`; MISMATCH → inject a "Findings" section before the letter, CLEAN → skip it — pure config, the same primitive that already migrated `code-pr`'s `review→implement` loop-back) + a **build** stage (doc_create/doc_append_section per section, `extension/v08-aliases-docbuilder.sql:1230-1280`, mirrors `book-digest`'s BUILD stage) that pastes the four rendered sections verbatim and *composes* only the draft letter, citing `chunk_ref`s | `book-digest`'s BUILD/CRITIQUE stage pair (`examples/book-digester.sql:229-296`) as the direct template | Published doc body contains all 5 required headers, non-empty, and the 4 fact sections are byte-identical to a fresh `case_section_render()` call (proves no LLM drift) |
| **7** | `case_file_publish_tool` (mirrors `book_publish_draft_tool`, `examples/book-digester.sql:117-166`, verbatim structure) — pulls the draft server-side, `import_doc` with `kind='case-file'`, marks `case_shelf` done | `book_publish_draft`'s exact pattern | `SELECT kind, frontmatter->>'source_type' FROM stewards.docs WHERE slug=...` → `case-file` / `case-file`; append `"case-file"` to `knowledge_projection.doc_kinds` (one `config_set` call, `v28:573-576`) → `knowledge/docs/<project>/case-<slug>.md` exists on disk after the next projector pass |
| **8** | `case_receipt(case_slug)` — SQL function assembling sources_used (distinct docs cited), what_changed, findings (from Increment 5), evidence_checklist (`is_missing=true` rows), and a fixed `needs_approval: ["review before appealing — nothing was sent"]` | `doc_citations_resolved` shape (`schema.rs:1774-1793`), `a2a_receipt` (`v13-a2a.sql:513-580`), `needs_attention` (`v19-platform.sql:371-433`) — ingredients only, new assembly | `case_receipt('<slug>')` returns non-null jsonb with all 4 required keys present for a completed case |

**Increment 9 — explicitly out of scope.** The video's own agent never builds a send button either ("it stops," `t633-t655`). Nothing in this plan implements `appeal_send`. If ever wanted, it is free: tag it `effect_class='dangerous'` and `tool_confirm_gate` (already shipped, `v17:243-297`) withholds it automatically. The gate for *this* demo is simpler and stronger than a withheld-tool call — **the send tool does not exist.** An absent capability cannot be jailbroken.

---

## 4. Estimate

Reading the increments against the pace this workspace actually ships at (a book-digest-shaped pipeline recast is a worked ~470-line file; Kernel Panic's P0 sim-plus-UI landed in one session; the files-interface v28 volume — ingest, provenance, projection, config — landed as one merge):

| Increment(s) | Session cost | Why |
|---|---|---|
| 0 | ~15 min, not a session | Ops only, already-shipped overlay |
| 1–2 | 0.5 session | Near-verbatim copy of `book_shelf` + the drop convention is already documented behavior |
| 3–4 | 0.5–1 session | Two small `*_add` tools styled on `observation_add`, plus prompt authorship (the CHECK constraints are the actual "normalization," and Postgres enforces them for free) |
| 5 | 1 session | The one genuinely novel artifact — new Go tool, plus building and hand-verifying the synthetic pack's planted contradiction both directions (inverse hypothesis) |
| 6–7 | 1 session | Mirrors `book-digest`'s three-stage BUILD/CRITIQUE shape closely; the render-vs-compose split (§3) is the one new design decision, not new mechanics |
| 8 | 0.5 session | Pure assembly of existing shapes |

**Total: 3.5–4 build-sessions — a night, or a night and a half if increment 5 needs a second pass on the synthetic pack.** This tracks the "team ships a verified wave in roughly a night" pace already evidenced this week (Little Farm Game Phase 1, Kernel Panic P1e, the v28 files-interface merge itself). The pacing item is Increment 5; everything else is templated reuse of `book-digester.sql`, `observation_add`, `route_on`, and the projection tree.

---

## 5. The demo script

Synthetic documents (like the video — real policy *shape*, synthetic patient, one **planted contradiction** as the inverse-hypothesis fixture). All four as plain markdown/text, so the whole demo runs on **core**, no overlay required (PDF variant noted at the end).

**The pack** (`STEWARDS_DROP_DIR/case-smith-appeal/`):
- `denial-letter.md` — claim #A-88214, denial date 2026-06-01, appeal deadline 2026-07-15, denial reason: *"Per Policy Section 4.2(b), pre-authorization is required for all outpatient procedures; none was obtained."* Evidence paragraph: *"This determination may be reversed upon submission of a physician's letter of medical necessity."*
- `policy-excerpt.md` — Section 4.2(b), worded to **contradict** the letter: *"Pre-authorization under 4.2(b) is required only for elective, non-emergency outpatient procedures."* (The claim was emergency care — this is the planted mismatch.)
- `claim-history.md` — three prior claims, dates, amounts, all approved, for context.
- `supporting-docs.md` — a checklist with one item explicitly marked NOT PROVIDED: *"Physician letter of medical necessity — missing."*

**Run:**

```bash
# 1. Drop the pack (core, no overlay — all four files are text/markdown)
mkdir -p "$STEWARDS_DROP_DIR/case-smith-appeal"
cp denial-letter.md policy-excerpt.md claim-history.md supporting-docs.md \
   "$STEWARDS_DROP_DIR/case-smith-appeal/"

# 2. Watch the drop watcher ingest (within one 30s poll — dropwatcher.go)
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT path, status, sha256 FROM stewards.file_drops WHERE project_hint='case-smith-appeal';"
# expect: 4 rows, status='ingested'

docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT slug, title, project_association FROM stewards.docs WHERE project_association='case-smith-appeal';"
# expect: 4 docs

# 3. Seed the case + kick off the pipeline (examples/case-file-digester.sql applied once beforehand)
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT stewards.case_add('smith-appeal', 'Smith — claim A-88214');"
# then dispatch a work_item on the 'case-file' pipeline family the normal way
# (stewards-cli work-item start case-file, or the Stewdio /new page)

# 4. Watch it walk: chunk -> normalize -> sanity_check -> build -> publish
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT current_stage, status FROM stewards.work_items WHERE input->>'case_slug'='smith-appeal';"

# 5. Inspect the chunks and facts directly — this is the "not vibes" proof
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT kind, chunk_ref, left(quote,60) FROM stewards.case_chunks WHERE case_slug='smith-appeal' ORDER BY kind;"
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT fact_type, value_date, value_amount, is_missing FROM stewards.case_facts WHERE case_slug='smith-appeal';"
# expect: appeal_deadline=2026-07-15, is_missing=true for the physician letter

# 6. Confirm the sanity check caught the planted contradiction — finding #1
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT claim, counter_of FROM stewards.observations WHERE source_doc_id IN
     (SELECT id FROM stewards.docs WHERE project_association='case-smith-appeal') AND counter_of IS NOT NULL;"
# expect: 1 row — the policy's actual (elective-only) language, counter_of pointing at the letter's claim

# 7. Materialize the case file to the inspectable tree
docker compose exec -T pg psql -U stewards -d stewards -c "SELECT stewards.knowledge_project_now();"
cat knowledge/docs/case-smith-appeal/case-smith-appeal.md
# expect: Timeline / Denial Map / Exact Policy Language / Evidence Checklist / Findings / Draft Appeal Letter
# — the first 4 sections byte-identical to a fresh case_section_render() call

# 8. The one-screen receipt
docker compose exec -T pg psql -U stewards -d stewards -c \
  "SELECT stewards.case_receipt('smith-appeal');"
# expect jsonb: sources_used[4], findings[1 mismatch], evidence_checklist[1 missing],
# needs_approval: ["review before appealing — nothing was sent"]

# 9. Prove the gate the honest way: grep for a send tool. There isn't one.
grep -ri "case_.*send\|appeal_send" extension/*.sql cmd/stewards-mcp/*.go
# expect: zero results. Nothing sends because nothing CAN send.

# 10. Inverse hypothesis: remove the contradiction, re-drop, re-check
sed -i 's/elective, non-emergency/all/' policy-excerpt.md
cp policy-excerpt.md "$STEWARDS_DROP_DIR/case-smith-appeal/"
# new sha -> freshness update -> re-run sanity_check -> expect 0 mismatches this time
```

Step 6 and step 10 together are the load-bearing proof for the whole demo: the sanity check must fire on the planted contradiction and go quiet when it's removed. Anything less is theater, not an oracle.

**PDF variant:** identical script, but bring up `docker-compose.doc-extract.yaml` first (Increment 0) and the four files are PDFs — `file_drop_ingest_binary` routes them through the sandbox; everything downstream is unchanged, since chunking/normalizing reads `stewards.docs.body` regardless of how it got there.

---

## 6. Where the substrate's weight fights the personal use case (a finding, not a failure)

This needs saying plainly because the build plan above is honest work, not a rationalization for using the tool at hand. **For one insurance appeal, run once, this is more infrastructure than the job needs.** The video's framing — "a little database called SQLite and a folder, nothing leaves your machine" (`t523-t532`) — is a genuinely lighter claim than what §5's demo requires: Postgres, a pgrx extension, the bridge process, migrations, and (for PDFs) a sandboxed sibling container with a ClamAV sidecar. None of that is wrong to build — it's what makes the case file *auditable* rather than *asserted* — but it is not what a person with one denial letter needs to open tonight.

A genuinely lighter path exists in this same workspace already, one level up: a Claude Code skill (this workspace already has the pattern — `quote-log`, "externalize verified quotes and observations to a scratch file as you read," and `study-workflow`'s externalized-memory discipline) that `Read`s a drop folder directly off disk, does the chunk/normalize/sanity-check/export work as LLM judgment plus `Grep`-verified quoting against the actual policy text, and writes `case-file.md` + `receipt.json` back to that same folder. No Postgres, no docker, no migration, no schema to design — session-scoped and disposable, exactly matched to a use-once artifact. It reuses none of the substrate's machinery, but it also needs none of it.

**The honest tradeoff, stated once:** the substrate's advantage — typed facts a query can't lie about, a gate that's a database constraint rather than a norm, a permanent case history across many future appeals, free materialization into a durable knowledge tree — pays for itself only if this becomes a *repeated practice* (an ongoing family paperwork-triage archive, or the video's own flywheel argument extended to taxes next). That's a real and plausible bet, not a stretch — but it is a bet about future reuse, and it should be named as one rather than assumed. **Recommendation:** build the light Claude Code skill first, this week, as the cheapest possible proof that the video's *shape* is real on real documents — it validates §3's render-vs-compose design decision (the one idea in this plan that isn't just reused plumbing) at near-zero cost. Only port it into the substrate's pipeline machinery (§3–§5 above) once there's a second and third case to run, where the ledger, the gate, and the durable archive start earning their weight.

---

## 7. Summary

- **Six of nine primitives are already load-bearing** with no new engine code: context pack, ingest, store, retrieve-by-structure, the gate, and (with one config line) export-to-a-durable-tree.
- **Three real gaps** — structural chunking, typed normalization, text-vs-text citation sanity-checking — are each small (a table, a table, one synchronous Go tool) *because* the addressability convention (`{doc, chunk, quote}`) and the counter-evidence primitive (`observations.counter_of`) already exist twice over in the codebase for other domains.
- **The build is ~3.5–4 sessions**, almost entirely templated off `examples/book-digester.sql`, with Increment 5 (the sanity-check oracle, inverse-hypothesis-verified) as the one genuinely novel artifact and the one that makes "finding #1" real rather than narrated.
- **The weight tension is real and worth naming**: build the light Claude-Code-skill version first to prove the shape cheaply; port to the substrate only when a second case makes the ledger and the gate worth their infrastructure cost.
