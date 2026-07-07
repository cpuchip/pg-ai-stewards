# UI merge map — 24 routes → ~12 (feat/lightening)

**Design + doc only. No views deleted in this pass** — this is the BEFORE/AFTER map for owner review before any code moves. Source of the "24" count: `cmd/stewards-ui/frontend/src/router.ts` has 24 route entries as of this branch. (The ratified ask framed it as "29 views" — that figure likely counts `.vue` files under `views/` rather than routes; four of those files — `ProvidersWizard.vue`, `RolesPanel.vue`, `ModelTestChat.vue` — are already sub-components mounted *inside* `/models`, not separate routes, and a fifth, `Placeholder.vue`, is dead code referenced only in a stale comment. Both counts point at the same ~12 target; this doc works from the routed 24.)

Input: `.spec/wargames/2026-07-07/wargame-OPERATOR.md` (full route-by-route walk). Seed direction from the task: Stewdio is the cockpit; merge Watchman+Bridge+Trust+Councils+Sabbath+Covenant into one **Ledger** page with tabs; Studies+Lessons+Search into a **Library**; Intents+Projects+Scheduled into a **Steering** page; keep Graphs, Wiki, Models, New; dev-menu hiding is acceptable for the rest.

---

## Target nav — 10 primary + 1 dev-tools flyout ≈ "~12"

| # | Target destination | Absorbs |
|---|---|---|
| 1 | **Dashboard** (`/`) | unchanged |
| 2 | **Work items** (`/work-items`, `/work-items/:id`) | unchanged |
| 3 | **Stewdio** (`/stewdio`) | unchanged — the cockpit |
| 4 | **Library** | Studies, Lessons, Search |
| 5 | **Ledger** | Covenant, Watchman, Bridge, Trust, Councils, Sabbath |
| 6 | **Steering** | Intents, Projects, Scheduled |
| 7 | **Graphs** (`/graph`) | unchanged (World/Cosmos + Wiki tabs already live here) |
| 8 | **Wiki** (`/wiki`, `/wiki/page/:slug`) | unchanged |
| 9 | **Models** (`/models`) | unchanged (already bundles ProvidersWizard/RolesPanel/ModelTestChat) |
| 10 | **New** (`/new`) | unchanged |
| — | **Dev tools** (flyout/menu, not a route) | Sessions (list), Brainstorm |
| — | (detail routes, not nav items) | `/studies/:slug`, `/councils/:id`, `/sessions/:sid`, `/wiki/page/:slug` stay as drill-down targets from wherever they're linked |

10 primary items + 1 dev flyout = the "~12" the ratified direction asked for (2 routes inside the flyout, `/sessions` list and `/brainstorm`, still exist — they're just not permanent top-nav real estate).

---

## Group 1 — Ledger (Covenant + Watchman + Bridge + Trust + Councils + Sabbath)

Rationale: every one of these six pages is a **governance/audit viewer** — read-mostly, low daily-traffic, "how is the system behaving/keeping its commitments" rather than "get work done." None of them (except Councils' Convene button) has a primary write action. Tabs, not separate pages, because a user asking "is the system honest right now" wants to flip between them, not navigate away and back.

| Current view | Unique data it shows today | Lands in Ledger as | War-game note |
|---|---|---|---|
| `Covenants.vue` (`/covenants`) | The active covenant's human/agent commitments, when-broken + recovery text, council-moment prose, optional teaching-extension JSON | Tab: **Covenant** | Was hard-broken (404 → raw error) — **fixed this session** (graceful empty state) |
| `Watchman.vue` (`/watchman`) | ~45 drift-detection pass rows (clean/skipped/drift counts, provider/model, token budget, dates back to 6/24) | Tab: **Watchman** | Zero drill-down today despite a `watchman_pass_show` backend tool existing — the merge is a good forcing function to finally wire pass→verdict detail, since a tab has more room to add a split view than the current full-bleed list page did |
| `BridgeState.vue` (`/bridge`) | Per-MCP-connector health (16 servers), tool counts, last-refresh age, expandable tool list for a healthy connector | Tab: **Bridge / Connectors** | 6/16 connectors down with real `fork/exec` errors — a governance/infra-honesty view, fits Ledger's theme exactly |
| `Trust.vue` (`/trust`) | Trust-ladder scores per (agent_family, pipeline_family, model): trainee/journeyman/master, successful/failed completions, human overrides, transition history | Tab: **Trust** | Currently empty (built but never populated) — merging doesn't fix that, just stops it occupying a whole nav slot for an empty state |
| `Councils.vue` + `CouncilDetail.vue` (`/councils`, `/councils/:id`) | List of convened councils (intent, binding question, status, bishop) + a detail view (members' proposer/critic/synthesizer responses, resolution text, promoted-to link) | Tab: **Councils** (list) → `/councils/:id` stays a real route for the detail (linked from the tab, not itself a nav item) | Has the one non-passive action here (+ Convene…) — keep that button live in the tab |
| `Sabbath.vue` (`/sabbath`) | Reflection log per completed work item: what was learned, carry-forward, surprises | Tab: **Sabbath log** | Currently empty-state only |

Ledger's default tab should be whichever one currently has real content most often (Watchman or Bridge, per this war-game's data) rather than always opening on the emptiest tab (Trust/Sabbath/Councils were all empty in this walk) — small thing, but the difference between "the new page looks broken" and "the new page looks alive."

## Group 2 — Library (Studies + Lessons + Search)

Rationale: all three are **"find something in the corpus"** flows over the same `stewards.docs`/`stewards.lessons` tables, just with different entry points (browse, browse-a-different-kind, type-a-query).

| Current view | Unique data it shows today | Lands in Library as | War-game note |
|---|---|---|---|
| `Studies.vue` + `StudyDetail.vue` (`/studies`, `/studies/:slug`) | Browsable doc list (391 rows today, mostly RPG-rulebook test content), kind filter, citations + similar-studies panels on detail | Tab: **Studies** (list) → `/studies/:slug` stays its own route (a full-document reading view doesn't belong squeezed into a tab strip) | Silent 100-row cap — **fixed this session** (real pagination); kind-filter taxonomy mismatch (`study`/`proposal`/`phase-doc`/`journal` all return 0, `crawl-page` isn't even an option) is a real bug still open, worth fixing in the same pass as the merge since the dropdown has to be rebuilt anyway |
| `Lessons.vue` (`/lessons`) | Lessons list: principle/decision/lesson/sabbath_reflection kind, ratified state, promoted-to link, kind + ratified filters | Tab: **Lessons** | Empty-state only in this walk, filters present and functional |
| `Search.vue` (`/search`) | One query box, three ranked panes (Hybrid/Keyword/Graph) over the same corpus, "+ wiki" collect action per hit, `/`-key global focus shortcut (`searchShortcut.ts`) | Tab: **Search** | Real, visible bugs: garbled hybrid snippet text, keyword panel returning "no hits" for a query hybrid finds 10 for, and an internal SQL function name (`stewards.refresh_doc_similarity`) leaking into user-facing copy. The `/`-key shortcut should keep working by jumping straight to Library's Search tab (not just focusing whatever tab happens to be open) — a small but real UX regression risk to flag to the owner, not silently drop |

## Group 3 — Steering (Intents + Projects + Scheduled)

Rationale: all three are **"how work gets pointed"** — the values a pipeline runs under (Intents), the corpus/bucket it's grouped into (Projects), and the cadence it fires on (Scheduled). None of these is where work is DONE (that's Stewdio/Work items); they're where its direction is set.

| Current view | Unique data it shows today | Lands in Steering as | War-game note |
|---|---|---|---|
| `Intents.vue` (`/intents`) | 8 intents (purpose, beneficiary, values hierarchy, non-goals, scripture anchor) + real work-item counts per intent | Tab: **Intents** | Loads cleanly, no bugs found |
| `Projects.vue` (`/projects`) | 10 projects with work-item counts, archived toggle | Tab: **Projects** | 6/10 projects show "0 work items" despite 95-289 real wiki pages each — `project_association` was never backfilled on ingestion. Real bug, independent of the merge, worth fixing alongside it since the tab's whole reason to exist is "trust this count" |
| `Scheduled.vue` (`/scheduled`) | Cron-style schedule rows: pattern, next/last dispatch, missed-window, enabled toggle, edit/delete | Tab: **Scheduled** | All 9-11 schedules were stalled ~14 days; the misleading "(due now)" text — **fixed this session** (now reads "paused" when `autonomy_paused` is on, via the new `AutonomyBanner`) |

## Kept as-is (seeded + confirmed no better home)

- **Dashboard** (`/`) — home; already aggregates soak/pg/in-flight/errors/rig/activity/last-7-scheduled-runs. Gets the new `AutonomyBanner` this session.
- **Work items** (`/work-items`, `/work-items/:id`) — the ops audit trail: full session list, cost breakdown, gate-decision history, steward escalation state. Distinct mental mode from Stewdio (auditing a run vs. conversing about it); heavy enough on its own that folding it into Stewdio or Ledger would bury it. Got pagination + the stale-error-banner fix this session.
- **Stewdio** (`/stewdio`) — the cockpit, per the seed. Untouched here except the two visual bugs fixed + the new banner row.
- **Graphs** (`/graph`) — World/Cosmos + Wiki tabs already live inside one route; no further merge needed.
- **Wiki** (`/wiki`, `/wiki/page/:slug`) — kept per the seed.
- **Models** (`/models`) — kept per the seed; already the densest single page (bundles ProvidersWizard, RolesPanel, ModelTestChat as sub-components, not separate routes).
- **New** (`/new`) — kept per the seed. Flagged in the war-game's Part 3 data-in-path story as the page a new user expects bulk/folder ingestion on but doesn't get (single-file only); that's a UX gap, not a merge-map concern, but worth carrying forward since New stays the front door.

## Dev-menu candidates (hide, don't delete)

| View | Why it's a dev-menu candidate, not a merge target |
|---|---|
| `Sessions.vue` list mode (`/sessions` with no `:sid`) | Duplicates Stewdio's `SessionsPanel` (same "every chat session + its target" data) with less context (no doc/work-item preview, no chat-open action). The session-DETAIL half of this component (`/sessions/:sid`) is still load-bearing — linked from Work Item detail's "Sessions" list and from Stewdio — so only the standalone *list* view moves behind the dev flyout; the detail route stays a normal drill-down target. Its "ambiguous slug → 5s timeout" bug is **fixed this session** (raised timeout + partial-data degrade) regardless of nav placement. |
| `Brainstorm.vue` (`/brainstorm`) | A power-user, multi-model, cost-capped dispatch form (12 lenses, per-lens model override, aggregator). Not in the ratified seed list for Steering/Library/Ledger; doesn't fit any of them semantically. It's closer to an "advanced New" than its own top-level destination — dev-menu now, with "fold into New as an advanced mode" as a follow-up question for the owner rather than a decision made here. |
| `Placeholder.vue` | Not routed anywhere — dead code, referenced only in a stale `router.ts` comment ("renders the Placeholder view via dynamic resolution") from an earlier phase. Not a merge target at all; flagging for deletion in a later pass (no deletions this pass per the task). |
| `ProvidersWizard.vue`, `RolesPanel.vue`, `ModelTestChat.vue` | Already correctly non-routed — mounted as sub-components inside `/models`. No action needed; noted here only so the "29 views" figure reconciles with the "24 routes" figure above. |

---

## What this map does NOT decide

- Exact tab order/default tab within Ledger/Library/Steering (flagged inline above where it matters — e.g. Ledger's default tab, Search's `/`-shortcut target).
- Whether Brainstorm folds into New or stays dev-menu-only long-term.
- Whether the "Dev tools" flyout is a nav dropdown, a `?dev=1` query flag (Stewdio already has a `store.dev` "Details" toggle precedent — `stores/stewdio.ts`), or a settings-page section.
- Any deletion — `Placeholder.vue` is dead and everything else here still exists at its current route until the owner approves the move.
