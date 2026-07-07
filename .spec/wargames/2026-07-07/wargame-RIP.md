# RIP Advocate Brief — Dismantle pg-ai-stewards into Files + Claude Code + Cron

*Opposed-mandate war-game panel, 2026-07-06. Mandate: argue the full teardown. Grounded in: README.md, docs/anatomy-of-a-turn.md, .spec/proposals/audit-synthesis-2026-07.md, the extension/ listing (files 00–102 plus 20+ verify scripts), scripts/migrate.sh, and the workspace's own .mind/ + .spec/journal (256 entries).*

---

## 0. The opening exhibit is the defendant's own testimony

Three witnesses, all from inside the house:

**Michael, this week:** "a part of me just thinks I need to go file based, and let you in claude code do the heavy lifting... pg-ai-stewards is really helpful but heavy." The maintainer of a one-person system calling it *heavy* is not a mood — it is the system reporting its own carry cost through the only sensor that matters.

**The migrate.sh header, 60 lines long.** Read it as a confession. It exists because `ls | sort -V` silently applied `cut3-restore-core-finals.sql` *first* instead of last and a stale overlay reverted a core function. The fix required: a manifest-as-contract, a hard-error for unlisted files, an `--allow-unlisted` escape hatch, a `requires-core` compat guard, a pre-apply clobber-check gate, an adopt ledger, and a `--skip-clobber-check` flag. That is seven mechanisms to safely do the thing `git pull` does for markdown. The audit itself (§IV) calls the overlay packaging "a hand-rolled reimplementation of something Postgres gives natively." I go one further: the *whole substrate* is a hand-rolled reimplementation of something the harness now gives natively.

**The July 3 audit's headline finding:** "the stranger's first run... a 30-60-minute gauntlet dominated by a cold Rust build and hand-writing two SQL seeds. For a stranger who does not write SQL it is effectively blocked." And the killer sentence it quotes from its own positioning doc: **"the builder has been building for the builder."** Michael's own profile memory says he is NOT a Rust/SQL person — the substrate's owner *is* that stranger, permanently, and the entire verification-discipline apparatus (virgin-smoke, parity-check, port-fn.sh, run-verify-suite.ps1) exists to compensate for a system its steward cannot read.

The precedent: Qodo, February 2026, ripped out their entire code-RAG indexing layer because "the extra lift from the index layer had dropped low enough that, once you set it against the infrastructure and the maintenance, the ROI on that layer was sitting right around zero." Agents with grep, git, and big contexts ate the index. They kept exactly one thing: PR-decision history — the thing agents cannot rediscover. That is the template. And Google's ADK Go 2.0 shipping durable graph workflows + HITL + resumable state as a commodity library means even the substrate's proudest engineering — durable execution without Temporal — is now a `go get` away for anyone. The moat's engine half was just commoditized; the state half was always just data, and data can be files.

The final exhibit: **this workspace already runs the replacement architecture, at scale, today.** `.mind/` (identity, active board, principles, session lanes with a file inbox), 256 journal entries in `.spec/journal/`, CLAUDE.md-composed context, skills as markdown, oracles as scripts, git as provenance. Nobody runs a parity-check on `.mind/active.md`. It has never shipped a stale image. It survives machine moves by `git clone`.

---

## 1. The file-based architecture — subsystem by subsystem

Root layout (a plain git repo, private, e.g. `stewards-files/`):

```
stewards-files/
  CLAUDE.md                  # the composed context: covenant + intent + house rules (replaces compose_system_prompt)
  intent.yaml                # standing intent — already exists as a file in this workspace
  covenant.yaml              # already a file
  work/                      # work items (see below)
    inbox/  active/  review/  done/
  corpus/                    # gathered sources, one md per doc, frontmatter = provenance
    <source-slug>/<doc>.md
  artifacts/                 # produced documents, reports, dossiers
  worlds/                    # loreworks — one dir per world
    <world>/canon/  entities/  wiki/  sessions/  minds/
  decisions/                 # THE QODO KEEP: gate verdicts, Hinge rulings, council votes, ratifications
    ledger.md  2026/...
  ledger/                    # spend: append-only jsonl per month
    2026-07.jsonl
  cron/                      # the automation manifest + wrapper scripts
    jobs.md  run-job.ps1
  oracles/                   # deterministic checks over the tree (linters, link-validators, quote-verifiers)
  .claude/
    skills/                  # pipelines live here now
    commands/                # /gather, /digest, /world-build, /wiki-tend
    agents/                  # digester, critic, curator, persona subagent defs
```

### Pipelines → skills + slash commands + `claude -p`

A pipeline today is a JSON list of stages dispatched by a Rust bgworker through 100+ SQL files of composition machinery. Anatomy-of-a-turn's own worked example admits the machinery is uniform: "a persona reply and a multi-stage research run differ only in how many stages the pipeline declares." Fine — then a pipeline is a *document*, and the executor is the harness:

- Each pipeline becomes a skill: `.claude/skills/research-council/SKILL.md` describing gather → digest → fact-find → synthesize → critique, with the critic as a **subagent** (the Agent tool is the fan-out primitive; the `fan-out` skill already codifies it, and the 62-file scratch audit proved it outperforms serial).
- Stage state = the work item file itself. Claude Code writes "## Stage 2: digest — done, 14 sources, 3 flagged" into the work item as it goes. Crash? The file says exactly where it died; the re-run resumes from the file. This is Temporal-shaped durability at markdown prices — the checkpoint is prose a human can read.
- Multi-model dispatch (the judge-local routing, alias failover, 19/31/32/36/68-*.sql) collapses into llama-chip's existing OpenAI router (:8090, federation live) + loom's trust ladder. Routing already lives outside the DB in Michael's stack; the SQL layer duplicates it.

### Work items → directory-as-queue with frontmatter

```markdown
---
id: wi-2026-07-06-battery-research
status: active          # inbox | active | review | done | cancelled
pipeline: research-council
budget_usd: 2.50
spent_usd: 0.83
created: 2026-07-06T09:00Z
intent: skunkworks-market-scan
---
## Binding question
...
## Stage log
- [x] gather — 14 sources into corpus/battery-scan/ (09:12)
- [x] digest — engrams inline below (09:31)
- [ ] synthesize
## Review
(Hinge writes here or moves the file to done/)
```

Moving a file between `inbox/ → active/ → review/ → done/` *is* the state machine. The 📬 session-lane inbox already proved directory-as-queue works for agent-to-agent handoff in this exact workspace — A2A (69-a2a-engine.sql) is a re-implementation of `.mind/sessions/inbox/` with more joins.

### Provenance → git + frontmatter, with one sacred keep

"Every action is a row" becomes "every artifact is a file and every change is a commit." `git log -p artifacts/dossier.md` is version history; frontmatter `sources:` lists the corpus files each claim traces to; the workspace's verify-quotes/study-lint pattern already enforces citation integrity deterministically over files. The **Qodo keep** applies verbatim: what agents cannot rediscover is *decision* history — so gate verdicts, Hinge rulings, council votes, and ratification records get a first-class `decisions/` ledger (the audit's own "Ratification record" section is already this, in markdown, and it is the most legible governance artifact the project has ever produced).

### Spend caps → wrapper checks + flat-rate reality

Honest downgrade, claimed openly in §4 — but note what Michael ratified on July 3: route harness work to Claude Code on the **Max sub** ("~30% weekly surplus ≈ free") + the opencode sub, "local models rest." The economic ground truth is that the marginal cost of a Claude Code turn is already zero; refuse-before-spend in SQL is guarding a meter that mostly isn't running. For metered dispatches, `cron/run-job.ps1` reads `ledger/2026-07.jsonl`, sums the month, and refuses to launch if over budget — cap enforced at *dispatch* granularity instead of *call* granularity. Cruder, sufficient for one human.

### Embeddings / search → grep + big context (the Qodo move), plus a disposable index

Claude Code with Grep/Glob over a markdown corpus is the proven daily driver of this workspace (469-file walks, gospel-library at tens of thousands of files). Where semantic recall genuinely earns its keep, run a *disposable* index: a cron job rebuilds a single sqlite-vec file from the tree nightly. Key property: the index is a cache, never the system of record — delete it and nothing is lost. The substrate's hybrid-RRF stack (71/72/73/75/76-*.sql, plus the engram embed-misroute saga that burned a debugging day at 72% failure) is five files of load-bearing infrastructure doing what a regenerable cache does.

### Wiki / worlds → markdown wiki with typed links

`worlds/<name>/entities/vex.md` with frontmatter `relations: [{to: cave-of-echoes, kind: dwells-in}]` — the typed edge vocabulary (38-edge-vocabulary.sql) becomes a YAML enum. Wikilinks are the graph. The Loreworks memory already says it: "Engine=public, content=local-private" — the *content* was always going to be files-shaped; this admits it. Obsidian or VS Code is the browser; the wiki-curator (94-*.sql) becomes a nightly `claude -p /wiki-tend` that walks changed files and fixes links/canon drift, with study-lint-style oracles catching contradictions deterministically.

### The UI / Stewdio / 3D graph → the editor + regenerated static views

The audit's §V already ratified the Karpathy split: content immutable markdown, presentation a render-time-derived view. Take it to its conclusion: cron renders a static site nightly (wiki + a self-contained force-graph HTML built from the link structure — the 3D graph as an *artifact*, not a service). The three UI features found dead/hidden/broken this week by hand-walking pages are the argument: a UI is a second product needing its own QA, and the file tree needs none — VS Code is maintained by someone else.

### Scheduler / reflect-steward / crawler / nightly lab → OS cron (Task Scheduler)

`cron/jobs.md` is the manifest; each job is one line: `schtasks` → `run-job.ps1 <job>` → `claude -p "/reflect-intent"` (or `/gather-crawl`, `/wiki-tend`, `/run-oracles`). Claude Code's own `schedule`/`loop` skills and headless `-p` mode are the dispatch tier. The reflect-steward that "researches an intent on a schedule and proposes work" becomes a nightly job that writes proposals into `work/inbox/` — same behavior, no bgworker, and the proposal is a file Michael reads over breakfast.

### Gates / HITL / the Hinge → PRs and the review/ directory

The strongest governance the stack has ever had is already file-shaped: **the human merge on code-pr**. Generalize it — pipelines commit to a branch; the Hinge is `git merge`. For non-code artifacts, landing in `work/review/` + a line in the session inbox is the ask-card. The ratified notify path (bell-on-mesh now, ntfy push queued) attaches to a directory watcher in twenty lines.

### Personas / chat → thin host + file minds

The one subsystem that genuinely needs a live process keeps one: ai-chattermax's persona host stays, but shells to `claude -p` (or llama-chip for cheap turns) with the persona's mind loaded from `worlds/<w>/minds/callie/` (core.md + facets as files + a recent-episodes log). Facet-scoped memory becomes facet-named files. Costs stated in §4.

---

## 2. Migration path

1. **Freeze + final backup.** Substrate to read-only; one last `pg_dump` + volume snapshot. This tarball is kept *forever* — the old brain's PITR, cold. Nothing is destroyed; it is decommissioned.
2. **Write the exporter (one session of Claude Code work — the substrate is queryable SQL, which is the one time its schema helps us).** Exports:
   - `docs`/corpus rows → `corpus/**.md`, frontmatter carrying source URL, ingest date, model, cost, doc id (provenance survives the crossing).
   - `work_items` + stage history + gate verdicts → `work/done/<id>.md`, full trajectory inline — every closed item becomes a readable case file.
   - Hinge rulings, council votes, covenant/intent versions, ratifications → `decisions/` (the Qodo keep, executed).
   - Wiki pages + world graph → `worlds/**` (edges to frontmatter relations).
   - Engrams flagged important + persona facets → `minds/**`.
   - Cost rows → `ledger/*.jsonl` (the historical spend record).
3. **Verify the export with an oracle, not vibes:** row-count manifest vs file-count manifest; spot-check N random docs round-trip; run link/quote linters over the tree. Green before step 4.
4. **Transition month:** a thin read-only MCP (or just Grep) serves old `doc_search`-style queries over the export; ai-chattermax repointed to the file-mind host; cron jobs armed one at a time, each with its oracle.
5. **Decommission:** stop containers, reclaim the box (the ComfyUI/asset-harness VRAM note in memory says the hardware has a waiting customer). The public repo is *archived with honor*, not deleted — README pointing at the book and the pattern; others may fork. Michael stops *operating* it; the ideas remain published.
6. **What is kept, explicitly:** the covenant/intent (already files), the decisions ledger, the corpus, the worlds, the oracles (rewritten against the tree), loom + llama-chip (they were never the substrate), and the *book* — the pattern was always the product; the Postgres instantiation was one proof of it.

---

## 3. What genuinely gets better

- **Updates.** `git pull` replaces build → COPY-line check → migrate.sh → virgin-smoke → parity-check → clobber-check. The audit's entire §IV — the manifest contract, the cut3 landmine, the adopt ledger, version drift four ways — is a bug class that *cannot exist* in a file tree. Adding a "migration" is saving a file. The rebuild-discipline memory ("live↔repo drift bit 3×; worst: 11 stale core fns hid 3 weeks") describes a disease whose organ is being removed.
- **Portability.** The system of record becomes a folder: clone it on any machine, back it up by pushing, restore it by pulling. Cross-machine migration — named pain, cited in the mandate — becomes a non-event. No Docker, no volume, no image freshness question.
- **Legibility.** Michael reads Go, Python, TypeScript — not Rust or SQL (his own profile: "verification discipline matters most on the substrate" *because* he can't eyeball it). Every stage log, every mind, every decision becomes prose he audits at reading speed. The Hinge gets stronger when the Hinge can read the whole system.
- **Claude-Code-nativeness.** Skills, CLAUDE.md composition, subagents, hooks, headless `-p`, schedule/loop — the harness ships the substrate's compose_system_prompt, skills table, spawn_subagent, and scheduler as maintained product, improving monthly, for free. Qodo's math: when the platform underneath you absorbs your layer, the ROI of maintaining your version goes to zero. Anthropic is absorbing this layer in public, on a monthly cadence.
- **Onboarding strangers.** The audit's headline finding dies: first run becomes "clone, open Claude Code, ask." No cold Rust build, no hand-written SQL seeds, no wizard to build (#256 becomes unnecessary rather than solved).
- **The oracle story simplifies.** Two heavyweight DB oracles (virgin-smoke, parity) existed to answer "did the deploy match the code?" — a question files don't raise. Oracles refocus on *content* (links, quotes, canon consistency, ledger sums), which is where they always paid best in this workspace.
- **The maintenance budget comes home.** Every hour on Dockerfile forensics, wedged sweepers (the poison-pill memory: "hours of nothing worked... never the model"), embed-misroute backfills, and parity ports is an hour returned to research, worlds, and the book — the things the substrate exists to serve.

---

## 4. Honest costs — stated fairly

- **Durable execution regresses.** The turn-as-a-row engine survives worker crashes mid-turn with zero loss and heals via reapers; a dead `claude -p` loses its in-flight turn and resumes only at file-checkpoint granularity. The audit is right that the field paid Temporal prices for what the substrate got natively. Cron + stage-logged work items is *coarser* durability, genuinely.
- **Refuse-before-spend becomes advise-before-dispatch.** SQL caps refuse at the individual call; a wrapper refuses at job launch. A runaway loop inside one job on a *metered* API gets caught at the next ledger check, not at the next call. Mitigated by flat-rate reality, not eliminated.
- **Concurrency and locking.** Postgres gave transactions; files give the session-lanes protocol and hope. Two agents writing one work item is a merge conflict, not a serialized commit. Fine at one-human scale; a real ceiling.
- **Multi-tenancy is not deferred, it is foreclosed.** The ratified answer was "tenancy when a second human is real." Files + one Max sub cannot RLS. If a second human ever becomes real, this decision gets re-litigated from scratch.
- **Live glass-box observability dies.** `SELECT` over live cognition, OTel spans per stage (built three days ago), watching a pipeline walk plan→build→deliver in Stewdio, streaming dashboards — gone. You get harness logs, jsonl, and post-hoc files. The 3D graph becomes a nightly still photo of a thing that used to be alive.
- **Trajectory eval and the Lab lose their substrate.** BINEVAL and the spiral oracle score the execution *trace as data*; the audit calls glass-box trajectory eval "a true lead" over the entire field, and the nightly lab regression was armed 72 hours ago. Harness transcripts are a poorer trace than costed, typed rows. RIP kills the flywheel the audit ranked #1 — this is the single largest real loss.
- **Associative multi-hop recall flattens.** Hybrid RRF over engrams + graph edges answers "what connects X to Y across three hops" in one query; grep does not. Persona minds get shallower at corpus scale, and chat-persona latency worsens on cold harness starts.
- **An identity cost.** The README says "pg-ai-stewards is that pattern instantiated" — the book's pattern made runnable, public, Apache-2.0. Archiving it retires the instantiation and the "stewards not agents" flag it planted. The pattern survives in files; the *artifact* the field could cite does not.

---

## 5. Closing argument

The audit's own §VIII, written to defend the substrate, concedes the case when read carefully: the moat was never "where the AI runs" but "where the AI remembers, decides, and is held accountable" — and this workspace has spent a year proving that files, git, and a covenant in CLAUDE.md deliver remembering (256 journal entries, .mind/), deciding (a decisions ledger more legible than any SQL gate), and accountability (oracles, PRs, the human merge) at a carry cost so low nobody has ever had to write a 60-line header explaining how to safely apply `.mind/active.md`. Meanwhile the substrate's operating tax is documented in its own repo: seven safety mechanisms to order SQL files, two oracles to trust a deploy, a first run its own audit calls effectively blocked, three UI features found dead by hand, and a steward who cannot read the two languages it is written in. Qodo ran this exact experiment with real revenue on the line and found the index layer's ROI at zero once agents could grep with big contexts; Google just commoditized the durable-workflow half as a library; Anthropic absorbs another slice of the composition layer every month. Keep what cannot be rediscovered — the decisions, the corpus, the worlds, the covenant — as files under git, let Claude Code be the executor it has already become for everything else in this workspace, let cron be the scheduler it has been for fifty years, and retire the beautiful, heavy machine with honor: archived, cited by the book, its one irreplaceable lesson (govern the agent, not the prompt) already safely extracted into markdown that will outlive any schema. Michael said it himself, and the maintainer's fatigue is data no dashboard can override: *really helpful, but heavy.* Heavy loses.
