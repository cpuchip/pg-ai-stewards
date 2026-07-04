# Ingestion: the purpose-crawler + raw-to-wiki router (spec, 2026-07-03)

Status: **spec / to ratify** — nothing built. Michael's ask: "get proper tools set up" before digesting any real site. Two features and one taxonomy question.

## Part 0 — the taxonomy (Michael's question: "are wikis their own thing?")

Yes. And getting this right is the foundation for both features, so it goes first.

The clean model is **four layers**, where World and Wiki are two *projections* of the same thing — neither owns the other:

1. **Source** — raw inputs: a file, a URL, a video, a dropped thing.
2. **Corpus** (a project) — source that's been extracted, chunked, embedded, and made searchable. Everything ingests *to here* first.
3. **Two projections over a corpus:**
   - **World** — the *entity-graph* projection: `world_entities` (characters, places, factions, items, events) + `world_edges` (typed relations). Machine-navigable, structured, schema'd. Answers "how do these things relate." Built by `world-build`.
   - **Wiki** — the *page* projection: `wiki_pages` with identity + links + provenance. Human-browsable prose. Answers "let me read about X and click around." Built by `wiki-curator`.
4. **Scope** — the addressable *name* for any slice (`wikis.kind` = project / world / manual / collection / pull). A scope is how you point search, a wiki, or a crawl at a subset.

**So, precisely:**
- **Wikis are their own thing** — a wiki is pages under a named scope.
- **A world CAN be a wiki** — a wiki whose scope is `kind='world'`, one page per entity, links = the edges. That's the world's *readable face*.
- **Most wikis are NOT worlds** — a collection wiki (hand-picked search results), a project wiki (a codebase's docs), a pull wiki (what one agent read for one study) have no world graph behind them.
- **The relationship:** World and Wiki are two views of one corpus. A corpus can have both, one, or neither; when it has both they **cross-link** (entity ↔ page). This is the seam that isn't wired yet (see Part 3).

The mental one-liner: *source → corpus → {world = the graph view, wiki = the page view}.*

## Part 1 — the LLM-driven purpose-crawler

Michael's frame, verbatim: "guardrail it, or make it drivable by llm! so the substrate model can direct it. like crawling for a purpose — we wouldn't want to digest gigabytes... (though we may actually want to for some sites when I port this to work)." Private experiment; robots-honoring; never public unless a site's makers opt in.

**What already exists (the de-risk):** `fetch-md-mcp` already has `fetch_url` / `fetch_urls` / `extract_links` / `fetch_html`, each with a `js: true` headless-Chromium mode (`chromedp.go`). SPA rendering — the hard part — is done. A crawler is orchestration + guardrails over these.

**The shape — a frontier-based agentic crawl, everything-is-a-row:**
- A **crawl** is a work item carrying a **purpose** (an intent string: "pull the character-creation rules"; "find every faction and its leader") plus a **guardrail config**.
- `crawl_frontier(crawl_id, url, depth, priority, status, discovered_from, fetched_at)` — the queue as rows. Resumable by construction: kill it, it resumes from the frontier.
- **The loop (one step per bgworker dispatch, so it's interruptible + budgeted):**
  1. Pop the highest-priority `pending` URL that's still under budget.
  2. Fetch it (`js: true` when the domain needs rendering — a per-crawl or auto-detected flag).
  3. The **LLM does two jobs on the page**: (a) extract the purpose-relevant content into the corpus (skip the rest — this is what keeps it from digesting gigabytes); (b) score each outbound link (from `extract_links`) for relevance-to-purpose.
  4. Enqueue the high-scoring links at `depth+1`.
  5. The LLM may also declare **"sufficient"** — it has what the purpose needs — and stop early.
  6. Repeat until the frontier's empty, a budget trips, or the LLM says done.

**Guardrails — a structural floor the LLM can only stay UNDER, never raise** (this is the "is it grindable?" discipline: a crawl is *side-effecting* — it hits live sites, is not resettable/repeatable — so it's human-cadence work that lives or dies by hard limits, not by trusting the model):
- **Budgets:** max pages, max depth, max total bytes, wall-time cap.
- **Boundary:** same-domain by default; an explicit domain allowlist to widen (the "port to work, crawl the whole intranet" case is just a bigger allowlist + budget).
- **Politeness (NEW — the real build):** fetch + parse + **honor `robots.txt`**; per-domain **rate-limit / crawl-delay** (default ~1 req/2s); the identifying User-Agent already exists.
- **Dedup:** URL-normalized, never refetch within a crawl.
- **Kill switch:** it's a work item — the watchman/ES machinery already pauses runaways; a crawl inherits that.

**The LLM-driver is the novelty.** Instead of a dumb breadth-first spider, the model reads each page and *chooses* the frontier — so "crawl for a purpose" is literal: it follows the character-sheet links and ignores the merch store. Cheap model for link-scoring (a workhorse), stronger only if extraction is subtle.

**Effort:** M. New: `crawl_frontier` + a `crawl` pipeline (plan → step-loop → done) + robots/rate-limit in fetch-md + a Stewdio crawl card (live frontier + budget bar). Reuses fetch primitives, work-item ledger, watchman guard. **Oracle:** a fixture site (a local static tree) + assert the crawl respects budget/robots/domain and the frontier converges — deterministic on the fixture even though real crawls aren't.

## Part 2 — raw-to-wiki (the auto-magic router, with directed mode)

Michael's frame: "push over a video, a website, a file, and it's auto-sorted into a world; if one doesn't exist it'd create one by theme — the auto-magic approach. But also useful to give directions with the file: 'this is an AI video, review it for new information that can benefit us and file those away.'"

**One intake, an optional instruction.** A single **drop** endpoint takes any artifact (file / URL / video) + an *optional* directive.

**The new piece is a ROUTER stage** — an LLM classify-and-route step that runs after the artifact's content is extracted:
1. **What kind is this?** (lore/fiction → a world; technical/AI → a knowledge domain; reference → a manual wiki; personal → journal.)
2. **Where does it belong?** Semantic-match the content against existing scopes (worlds, projects, wikis) using the search we already have.
3. **Create-if-none, by theme.** No scope fits → propose a new one named from the content's theme ("Lyrian Chronicles", "AI-harness-notes"). Creating a *new* scope is a hinge-gated moment (mountain tier) so the world/wiki namespace doesn't sprawl silently; filing into an *existing* one is act-and-report.
4. **Disposition per instruction.** No instruction → infer (auto-magic). Instruction present → obey it as a *purpose filter*: "review this AI video for what benefits us" = a purpose-scoped extraction (same purpose mechanism as the crawler) into the target, not a full dump.

Then the router **dispatches the right existing pipeline**: doc-extract (files) → world-build (if it's world-shaped) and/or wiki-organize (pages); yt digest (videos); the crawler (URLs). The router is a thin, smart dispatcher over machinery that already exists — its only new logic is *classify → match-or-create-scope → set purpose*.

**Two modes, one surface:**
- **Auto:** drop it, walk away — themed, routed, scope created if needed.
- **Directed:** drop it with intent — the intent becomes the extraction's purpose and (optionally) names the destination.

**Effort:** M. New: the `route-intake` pipeline (classify → match → create-or-file → dispatch) + a scope-registry match query + the drop UI (file/url/video + an optional "instructions" box) hanging off the existing chat attach + New-work surfaces. Reuses doc-extract, yt, world-build, wiki-curator, the crawler. **Oracle:** seed 3 fixture artifacts of known kinds + assert the router lands each in the right existing scope, and that an unmatched one proposes a new scope (not silently mis-files).

## Part 3 — how they compose (the angelssword dream, done right)

Drop `https://angelssword.com/` with "build this as a world":
- **route-intake** classifies it (a URL, lore-shaped, no matching scope) → proposes a new world **Lyrian Chronicles** (hinge-gated: you approve the new scope).
- It dispatches the **crawler** with purpose = "the shared-universe lore, characters, factions, and RPG rules," `js: true` for the SPA subdomain, same-domain+allowlist for `rpg.` and `shop.`, robots honored, budget capped.
- The crawl fills a **corpus**.
- **world-build** projects the entity graph; **wiki-organize** projects the pages.
- **The world→wiki bridge** (the seam from Part 0, the one genuinely-missing cable): each world entity auto-materializes a wiki page, edges become page links. Now the world *is* browsable, and "each connected thing as its own world+wiki" (studio / RPG / novels as three worlds under one universe) falls straight out of the scope model shipped tonight.

Two flags carried from the recon: it's a **commercial studio's IP** — fine as a private local world (like your rulebooks), stays on your mesh, never published unless the makers want it; and their Discord is the right place to *ask* if they'd like it, not to surprise them with it.

## Part 4 — sequencing (nothing built; your call on order)

Three arcs, each a fleet, each ratify-first:

1. **The world→wiki bridge** (S–M) — smallest, highest-leverage, unblocks everything: wire world entities ↔ wiki pages so a world has a readable face. Worth doing even alone.
2. **The purpose-crawler** (M) — the frontier engine + robots/rate-limit + the LLM driver + SPA (already there). The tool that makes any site ingestible-with-a-purpose.
3. **The raw-to-wiki router** (M) — the auto-magic/directed intake that ties files+urls+videos into the auto-sort. Best last: it *dispatches* the crawler and the bridge, so it wants them to exist.

My lean: **1 → 2 → 3.** The bridge makes tonight's wiki+world investment pay off immediately; the crawler is the capability you actually asked for; the router is the magic wrapper that makes it one gesture. All inside the Fable window if we run them like today.
