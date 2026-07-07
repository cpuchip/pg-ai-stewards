# SKEPTIC Brief — "close to Nate B Jones's bar" does not survive a code read

**Opposed mandate:** argue pg-ai-stewards is NOT meaningfully closer, after today's
`feat/lightening` + `feat/files-interface` merges (PR #31, PR #32; commits `4ef1fb0`,
`faa8e15`), to the bar set by Nate B Jones's "Every AI Agent Demo Stops at Email"
(transcript: `yt/ai-news-strategy-daily-nate-b-jones/U4TmrlWEY4M/transcript.md`). His
thesis in one line: a MESSY PERSONAL FOLDER becomes an inspectable CASE FILE — timeline,
denial map, typed ledger, evidence checklist with missing items first-class,
citation-anchored draft, questions-for-the-expert — on SQLite + a folder, nine
primitives (context pack, ingest, chunk, normalize, store, retrieve, cite, export, gate),
human owns the final click.

Every claim below is grounded in a file I read this session. Where I reconstructed a
failure mode from code rather than observing it directly (I did not run Docker — this
was a read-only investigation), I say so explicitly.

---

## Verdict table (ranked by severity)

| # | Attack | Verdict |
|---|---|---|
| 1 | The walkthrough test: a PDF dropped into `drop/work-corpus/` on a stock install dead-ends invisibly | **SUSTAINED** |
| 2 | Normalize is not a primitive here — no typed dates/amounts/deadlines, no first-class "missing document" | **SUSTAINED** |
| 3 | The case-file export (one inspectable packet) does not exist and cannot be assembled from existing primitives | **SUSTAINED** |
| 4 | The receipt as UX (sources used / what changed / needs approval, one screen) does not exist | **SUSTAINED** |
| 5 | Retrieval-by-structure ("the exact policy section") does not exist — only FTS/RRF over character-count chunks | **SUSTAINED** |
| 6 | Weight: Postgres+pgrx+Rust+4 Docker services is the wrong instrument for scared-person-with-a-denial-letter, and today's merges didn't move this number at all | **SUSTAINED** |
| 7 | The substrate's own freshness machinery is currently dead, undercutting the freshness half of the pitch | **SUSTAINED** (corroborating, not new) |
| 8 | The technology underneath doc-extract is fake/vaporware | **REJECTED** |
| 9 | "the builder's own e2e showed exit 125" — literal artifact | **UNVERIFIED as written, but the mechanism that would PRODUCE exit 125 is confirmed in code** |

---

## 1. The walkthrough test — SUSTAINED

**Claim under test:** drop a real insurance-denial PDF into `drop/work-corpus/`; trace what
actually happens on a stock install.

**Evidence.**

- `cmd/stewards-mcp/dropwatcher.go` routes any non-`.md/.txt` file to
  `stewards.file_drop_ingest_binary` (line 253).
- `extension/v28-files-interface.sql` §5: binary drops go bytes → durable
  `chat_attachments` row → `mcp_proxy_enqueue('doc-extract','doc_import_corpus', ...)`.
  The function's own comment says it plainly: *"Needs the docker-compose.doc-extract.yaml
  overlay to actually extract; absent it, the extract errors CLEARLY and
  file_drop_reconcile() writes that outcome back onto the ledger row."*
- `docs/files-interface.md` states it even more bluntly in the routing table: PDF/Office/
  zip/images "→ `stewards.file_drop_ingest_binary` … (**requires the
  `docker-compose.doc-extract.yaml` overlay**; without it the ledger records the failure
  honestly and the bytes stay safe in the attachment)."
- The overlay is NOT part of the base stack. `docker-compose.doc-extract.yaml`'s own
  header: *"# build the converter image once: docker build -f
  extension/doc-extract.Dockerfile -t doc-extract:latest . / # then bring the stack up
  WITH doc-extract: docker compose -f docker-compose.yaml -f
  docker-compose.doc-extract.yaml up -d"* — a manual image build plus a second compose
  file, not part of `docker compose up`.
- README.md line 119, unchanged by either of today's PRs: *"One `docker compose up`
  boots it on a clean machine."* Line 91 (also unchanged), under "Start here: Stewdio":
  *"Drag in a PDF, Office doc, or zipped folder and it becomes safe, searchable subject
  material"* — stated with **zero caveat** that this needs a second, hand-built overlay.

**What the user actually sees.** I traced the mechanism precisely (see §9 below): on a
stock install, `stewards.mcp_servers` already has a `doc-extract` row **registered and
enabled=true by default** (`extension/v10-chat.sql` §3), and `doc-extract-mcp` is
compiled into the base bridge image unconditionally (`extension/bridge.Dockerfile`
line 73 builds it in every image; `docker-cli` is `apk add`-ed unconditionally too, line
112). So the drop is NOT rejected up front — it is accepted, ingested, and the extract
attempt is dispatched. It then fails downstream when `doc-extract-mcp` tries to
`exec.Command("docker","run",...)` a sandbox container (`cmd/doc-extract-mcp/runner/
run.go` line 164) and finds no `/var/run/docker.sock` mounted (that mount is added ONLY
by the opt-in overlay). The failure lands, per design, as a row in
`stewards.file_drops` with `status='error'` and a real message.

**And that ledger has no UI.** I grepped the entire frontend for `file_drops` —
zero hits in `cmd/stewards-ui/`. I read the full route table
(`cmd/stewards-ui/frontend/src/router.ts`) — there is no `/drops`, `/ingest`, or
`/files` route, before or after today's nav-consolidation commit (`d927d7a`,
"24 routes -> 10 primary + Dev flyout"). The files-interface.md doc's own instruction
for checking failures is: `SELECT * FROM stewards.file_drops ORDER BY first_seen_at
DESC` — raw SQL, run outside the app. Nate's bar is "a normal person can run this
stack"; the failure-visibility floor here is a normal person running `psql`.

**Net effect for the owner's scenario:** the person is anxious about an insurance
denial, drops the PDF into a folder because that's what the docs told them to do, and
gets no error, no toast, no dashboard flag — the bytes are safe (a real, honest design
choice — nothing is silently discarded) but nothing readable is produced, and nothing
tells them so.

---

## 2. Normalize is not a primitive — SUSTAINED, and this is the crux

Nate's whole video turns on one sentence: *"dates become dates, people become people…
amounts are becoming amounts… missing documents are becoming missing documents."* That
is a specific claim — typed, addressable, queryable structured output, not prose that
merely mentions a date.

**Evidence there is no typed extraction anywhere in the doc-extract path.**
`internal/docextract/result.go` defines the ENTIRE extraction output contract:

```go
type FileResult struct {
    Path      string
    MimeType  string
    DocType   string
    Text      string          // extracted markdown — the always-on path
    WordCount int
    Pages     []PageImage     // rendered page bitmaps
    Images    []EmbeddedImage // embedded picture XObjects
    Scan      ScanResult      // malware verdict
    Skipped   bool
    Error     string
}
```

That is the complete surface: one markdown blob, some bitmaps, a malware verdict.
No `dates []Date`, no `amounts []Money`, no `deadline`, nothing structured at all.
Everything downstream of extraction — `doc_import_corpus` in
`cmd/doc-extract-mcp/tools.go` — takes that `Text` blob and chunks it by raw
character count (see §5) into more prose. There is no stage anywhere in this pipeline
that turns a string like "you must appeal within 180 days of this letter" into a row
with a `deadline_date` column.

**Evidence the closest analog (the knowledge-graph "worlds" system) is
lore-shaped, not ledger-shaped.** `extension/v11-loreworks.sql` line 41:
`world_entities.kind` — *"character|place|faction|item|event|lore|concept."* That is the
entire entity-type vocabulary the substrate's LLM-extraction machinery knows how to
produce. There is no `date`, `amount`, `deadline`, or `person`(as a claimant/insurer
role) kind. The newer `stewards.observations` table (`extension/v26-knowledge.sql`,
today's "Builder E"/"knowledge engine core" work) is closer in spirit — a sourced,
confidence-labelled claim — but its `claim` column is `text`, and its only structured
fields are `confidence` (high/medium/low/anecdotal) and `fidelity`
(verbatim/paraphrase/inferred). No date column, no amount column, no currency, no unit.
A "deadline" observation and an "I like pizza" observation are the identical shape.

**Evidence "missing documents" is not a first-class object anywhere.** I grepped for
`missing.*doc` and `checklist` across every SQL migration and every Go command. The
only "checklist" concept in the entire codebase is the pipeline **plan/progress**
checklist — `cmd/stewards-ui/api/pipelines.go` line 20 and
`cmd/stewards-ui/frontend/src/views/stewdio/ArtifactPanel.vue` line 3, both describing
"Devin's plan=progress" pattern (stage 1 done, stage 2 running). That is an *operational*
checklist about the pipeline's own execution, not a *domain* checklist about which
evidence documents a case has versus still needs. There is no table, column, or tool
anywhere that models "I have the denial letter and the policy but not the doctor's
letter" as a queryable state.

**Even Michael's own real-world precedent for this exact use case stays generic.**
`examples/corpus-organize.sql` — explicitly shared, per its own header, "by the
digesters and by the work-corpus assembly line" — is the actual template for turning a
gathered document into structured knowledge. Its entity vocabulary: *"kind: a short
type (concept | claim | principle | person | category)."* Even the pipeline built for
Michael's own real paperwork uses the generic lore-graph shape, not typed
date/amount/deadline fields. If a normalize primitive existed anywhere in this
codebase's actual practice, it would be here, and it isn't.

**Verdict:** SUSTAINED, and I'd flag it as the single most important gap — normalize is
the one primitive Nate says is "boring but worth it," the one that lets you drop to a
cheap model later, and it is the one primitive this substrate has not built at any
layer, general-purpose "worlds" graph included.

---

## 3. The case-file export (one inspectable packet) — SUSTAINED

Nate's build-2 deliverable is ONE artifact: timeline + denial map + exact policy
language + evidence checklist (present/missing) + draft letter, inspectable as a
single packet.

**Evidence for what document construction actually produces.**
`extension/v08-aliases-docbuilder.sql` (the "34-doc-builder" agentic construction
system, today unchanged): a draft lives in `stewards.doc_drafts` as one `body text`
column, built incrementally via `doc_create` → `doc_append_section` → `doc_patch` →
`doc_finalize`. That is a single markdown document assembled section-by-section by an
LLM free-writing prose under headings. Nothing about that mechanism gives you a
separately addressable, independently-queryable timeline object, a denial-map object,
or a checklist object with per-item present/missing state — a heading that SAYS
"Evidence checklist" in the rendered markdown is not the same claim as Nate's system,
where the checklist is backed by rows the software itself can query ("what's still
missing?") without an LLM re-reading the whole document.

**Evidence no starter template for this shape exists.** `examples/` contains
`book-corpus.sql`, `book-digester.sql`, `corpus-organize.sql`, `playlist-digester.sql`,
`yt-transcripts.sql`, `models.sql` — no insurance/tax/case-file/ledger example. The
closest namesake, "the work-corpus assembly line" referenced in `corpus-organize.sql`'s
header, uses the same generic concept/claim/principle vocabulary (§2 above), so even
that precedent is not a case-file template.

**What building it would actually require:** (a) the typed-extraction primitive from
§2, which does not exist at any layer; (b) a new pipeline family (this codebase's
pipelines are declared as JSON stage arrays in `stewards.pipelines`, e.g.
`examples/corpus-organize.sql` line 12) authored specifically for
denial-appeal/tax-prep shape; (c) a new export/render step, since `doc_drafts` renders
to one markdown blob, not a multi-pane packet. This is not "point the existing thing at
new folder" — it is net-new authoring on top of a primitive that itself doesn't exist
yet.

---

## 4. The receipt as UX — SUSTAINED

Nate's receipt is one screen a non-technical person reads before clicking send: sources
used / what changed / what needs approval.

**Evidence the word "receipt" means something else entirely here.** The only
"receipt" concept in the whole codebase is `stewards.a2a_receipt`
(`extension/v13-a2a.sql` §"a2a_receipt — post what I did + the artifact + proof; mark
done"). Its own comment: *"The receipt is the accounting — 'I want to know it got
done.'"* This is agent-to-agent task-completion accounting (one agent proving to
another agent, or to the delegating owner, that a HANDED-OFF task finished) — not a
consumer-facing review screen for a specific document before it goes out the door. Same
word, unrelated function; a search for "receipt" that stopped at the grep hit would be
misled into thinking this exists.

**Evidence the closest human-facing analog is built for a different persona.**
`cmd/stewards-ui/frontend/src/views/WorkItemDetail.vue` lines 944–980, the "Gate
decisions" panel — the nearest thing to an approval screen in the UI — renders
`from_maturity`, `work_id`, `rev #`, a `<pre>`-dumped `raw_response` JSON blob behind a
`<details>` toggle, and an "Override gate decision…" button that opens a modal
requiring a free-text justification of at least 10 characters and a dropdown of
`advance`/`revise`/`surface`. This is a pipeline-maturity audit log for an operator
debugging a research/build pipeline, not "here's what changed in your appeal letter,
click send." It has no concept of "sources used" as a discrete, scannable list; sources
would be buried, if present at all, in the doc's own prose citations.

**Independent corroboration, same panel, same day.** The OPERATOR brief
(`.spec/wargames/2026-07-07/wargame-OPERATOR.md`), walking the live UI hands-on hours
before this brief, found the Study-detail page's "Sources pulled" tab is **explicitly
not wired**: *"honest about not being wired (WIKI-CORE's `doc_pull_sources`/
`doc_blind_spots` haven't landed)"* — and that the same page leaks internal codenames
to the end user. The one UI surface whose NAME matches what a receipt would need
("sources pulled") is a stub.

---

## 5. Retrieval-by-structure — SUSTAINED

Nate's point is specific: an insurer must cite the exact policy section it relied on,
so the agent doesn't search for something it can't find — it retrieves BY ADDRESS
("the exact policy section"), no vector DB required for that step.

**Evidence retrieval here is chunk-index, not structure-index.**
`cmd/doc-extract-mcp/tools.go` — `importCorpusFn` chunks extracted PDF text via
`chunkText(fr.Text, chunkChars)` (line 387), a pure character-count splitter that snaps
to the nearest newline (`chunkText`, lines 72–95) — it has no awareness of headings,
sections, or numbering. Each chunk becomes a doc with slug
`fmt.Sprintf("%s-%03d", baseSlug, pi+1)` (line 402) — i.e. "part 2 of 5," not "Section
4.2(b) Exclusions." The example starter corpus (`examples/book-corpus.sql`)
`book_chunks` table has the identical shape: `chunk_idx int` (line 60), an arbitrary
sequence position, retrieved via `doc_search`/`doc_search_hybrid`
(`extension/v01-work-substrate.sql` line 2371, `extension/v14-search-and-disclosure.sql`
line 103) — FTS + hybrid RRF ranking over those numbered chunks. There is no function
anywhere in this codebase that resolves "policy section 4.2(b)" to a specific row by
that address; the only path is fuzzy rank-and-hope.

**Consequence for Nate's specific "sanity check" move** (does the cited section
actually say what the denial letter implies?) — that check depends on being able to
pull the EXACT cited section, not "whichever ~2000-character window scored highest."
Without structural addressing, this system can approximate the check by feeding the
model several top-ranked chunks and trusting it to notice a mismatch, which is a
strictly weaker guarantee than Nate's address-based retrieval.

---

## 6. Weight — SUSTAINED (the honest steelman)

Nate's stack: SQLite + a folder. Inspectable with a text editor and a free SQLite
browser; zero daemons, zero compilers, zero containers.

**This stack, unchanged by today's merges:** `docker-compose.yaml` defines four
services on the base install — `pg`, `bridge`, `ui`, `persona-host` (grepped the file
directly). The `pg` image build (`extension/Dockerfile` line 14):
`FROM rust:1-bookworm AS builder`, installing `cargo-pgrx` and running `cargo pgrx
package` — a genuine cold Rust compile of a Postgres C-extension on first
`docker compose up`, not a pulled prebuilt image (`pg:` service has `build: context:
./extension`, no registry image reference). Today's `feat/files-interface` diff to
`docker-compose.yaml` (`git show 6b461f4 -- docker-compose.yaml`) added exactly 19
lines — two new bind-mount volumes (`./drop:/drop`, `./knowledge:/knowledge`) on the
`bridge` service. It did not touch the `pg` build stage, did not add a prebuilt-image
path, did not reduce the service count.

**This project's own audit says the same thing, dated the same week, unmoved by
today's work.** `.spec/proposals/audit-synthesis-2026-07.md` line 58: *"Path B (an
agent actually answers) is a 30-60-minute gauntlet dominated by a cold Rust build and
hand-writing two SQL seeds… For a stranger who does not write SQL it is effectively
blocked."* Nothing in `feat/lightening` or `feat/files-interface` — SQL-migration
consolidation and two bind-mount directories — addresses cold-build time, provider
seeding, or the Rust dependency. The "closer to the bar" claim, insofar as it implies
weight moved, has zero evidence behind it from today's diffs.

**Steelman, stated plainly:** for Nate's specific persona — an anxious, non-technical
person with one denial letter — asking them to `git clone`, install Docker Desktop,
wait through a Rust compile, hand-seed two SQL tables for a model provider (per the
audit), and THEN separately `docker build` a second image and re-run compose with a
second `-f` flag just to read their own PDF, is a mismatch of instrument to task
independent of whether the eventual output would be good. This is true whether or not
the underlying engine is well-engineered — and the doc-extract sandbox itself (§8) IS
well-engineered. The weight critique is about the delivery vehicle for THIS use case,
not the quality of the parts.

---

## 7. Corroborating finding — the freshness half of the pitch is not demonstrated by the system's own operation

Not a new claim of mine — the OPERATOR brief from the same panel, same day
(`.spec/wargames/2026-07-07/wargame-OPERATOR.md`), found live: *"Every scheduled
pipeline has been dead for ~14 days, silently, with no warning styling distinguishing
'slightly late' from 'dead.'"* Nate's exact worry — *"you won't get a surprise a few
days before some kind of deadline"* — is the failure mode currently live and unflagged
in this substrate's own instance. I'm not re-verifying that finding independently
(it's a live hands-on UI walk, a different verification method than mine), but it's
directly relevant: the "files-interface increments... the freshness principle" language
in `.spec/proposals/files-as-interface-db-as-engine.md` claims freshness as "the
product's spine," while the system's actual cron/scheduler machinery has been silently
dead for two weeks with zero UI alarm. The claim and the demonstrated behavior point in
opposite directions.

---

## 8. What does NOT sustain — the extraction technology itself is real, not vaporware — REJECTED

In fairness: I looked hard for a claim that the doc-extract sandbox is fake or
half-built, and that does not hold up. `.spec/proposals/doc-extract-sandbox.md` is
marked "BUILT + SHIPPED 2026-06-24," and I read real, substantial code backing it:
`internal/docextract` (pure-Go converter core with unit tests —
`docextract_test.go`, `classify_test.go`, `embedded_images_test.go`), a genuine
four-layer defense (ClamAV + structural maldoc scan → no-network container → non-
execution → content-gate), `cmd/doc-extract` and `cmd/doc-extract-mcp` as real Go
binaries, a real `extension/doc-extract.Dockerfile`, real archive-bomb/zip-slip caps
(`cmd/doc-extract-mcp/tools.go` `archiveCaps()`). This is a genuinely well-engineered
piece of infrastructure. The problem the SUSTAINED findings above identify is not "the
tech doesn't work" — it's "the tech is opt-in, undiscoverable when off, produces no
typed output even when on, and the headline README oversells what's on by default."
Any version of this brief that argued the extraction capability is fake would be a
strawman; I'm dropping it explicitly rather than let it stand unstated.

---

## 9. The "exit 125" hint — UNVERIFIED as a literal artifact, but the failure mechanism is confirmed

I could not find the literal string "125" anywhere in `.spec/`, `docs/`, or any
committed log tied to this feature — it is not a claim I can point at a specific file
and say "there, verbatim." What I COULD do, and did, is trace the exact code path that
would produce it:

1. `extension/v10-chat.sql` §3 registers `doc-extract` in `stewards.mcp_servers` with
   `enabled='t'` **by default**, and `extension/bridge.Dockerfile` builds
   `doc-extract-mcp` into the base image unconditionally (line 73) and `apk add`s
   `docker-cli` unconditionally (line 112) — so on a stock install the tool is present,
   registered, and callable; nothing short-circuits before it tries to run.
2. `cmd/doc-extract-mcp/runner/run.go` line 164: `exec.CommandContext(ctx, "docker",
   args...)` — a raw `docker run` invocation, no preflight check for the socket's
   existence.
3. The base `docker-compose.yaml` does not mount `/var/run/docker.sock` into the
   `bridge` service — that mount exists ONLY in `docker-compose.doc-extract.yaml`
   (and, separately, `docker-compose.coder.yaml`, with an explicit warning against
   mounting it twice).
4. Docker's own CLI convention: when the client cannot reach the daemon (no socket),
   it fails immediately with its own non-zero exit code — the well-documented Docker
   CLI convention for "the docker command itself failed" is exit code 125, distinct
   from 126/127 (container command problems) or the containerized process's own exit
   status. Go's `cmd.Run()` (line 169) surfaces that as an `*exec.ExitError`, and line
   171-172 wraps it verbatim into the returned error string ("doc-extract container:
   %w\nstderr: %s") — exactly the shape that would read "exit status 125" in a log or
   an MCP tool-result error.

So: I'm not claiming to have read a transcript that says "exit 125." I'm reporting
that I independently reconstructed, from the actual code, the precise failure this
hint describes, and it is real and reachable on a stock install by BOTH the new
drop-directory path (silently, into `file_drops`, per §1) AND the pre-existing live
chat-attach path (`makeDocExtract`, `cmd/doc-extract-mcp/tools.go` line 173, which
calls the identical `run.Extract`). The one architectural difference worth naming: the
chat-attach path fails inside a live model turn, where an MCP tool error is visible to
the model and (ordinarily) gets narrated back to the user in the same conversation; the
new drop-directory path fails inside a 30-second background poll loop with nobody
watching (`dropwatcher.go`'s own docstring: "POLL-FIRST BY DESIGN... no watcher to
trust"), landing only in a table with no UI. The feature that's supposed to be the
closer, more personal-folder-native answer to Nate's bar is strictly worse than the
feature it's layered on top of, for the one thing Nate insists matters most: telling
the human, honestly and visibly, when something didn't work.

---

## Summary for the panel

Six independent, code-grounded lines converge on the same shape of gap: this substrate
has a real, general-purpose knowledge-graph extraction engine, a real hardened
document-extraction sandbox, and a real agentic doc-construction tool — and NONE of the
three primitives Nate's video says are load-bearing (typed normalize, structural
retrieve, a human-legible receipt) exist at any layer, in any of today's two merges, or
in the closest prior real-world attempt at this exact use case (`corpus-organize.sql`,
"the work-corpus assembly line"). The walkthrough test dead-ends on a stock install for a
reason traceable to specific, cited lines of Go and SQL, not speculation. And the one
dimension the "closer" claim would need to move — weight, for a scared person with one
PDF — has zero evidence of having moved today: the diff to `docker-compose.yaml` added
two directories, not a lighter path to a working answer.

None of this says the underlying engineering is bad — §8 is a real concession, and the
extraction sandbox specifically is excellent work. It says the distance between "we have
a powerful general substrate" and "we have Nate's nine primitives, working, on the thing
Michael actually cares about (his own work-corpus paperwork)" is not closing at the pace the
"close to this" claim implies, because the two things that shipped today were not aimed
at the three missing primitives at all.
