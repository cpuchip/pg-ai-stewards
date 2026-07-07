# Model-agnostic audit — "the substrate should have no preference of default models"

Builder C, branch `feat/lightening`. Analysis only — no code changed. Live values
below were read with `scripts/db.sh` (read-only `SELECT`s) against the running
`stewards-oss-pg` container; everything else is from the checked-out tree.

## TL;DR

The substrate is **not** starting from zero. Three real passes already moved
seed data to the overlay boundary before this audit: `06-cost.sql` (pricing /
stage_models defaults / escalation matrix / provider caps — "SEED ROWS MOVED TO
THE OVERLAY"), `19-models.sql` (capability verdicts, an1 anthropic-format rows,
the opencode_zen catalog), and `31-model-aliases.sql` (the alias table itself
ships **empty**, seeded only by `examples/models.sql`, an opt-in file the
operator runs by hand). Those three are genuinely clean today — verified live:
`stewards.model_aliases` and `stewards.model_pricing` on the running container
hold only rows an operator (Michael) inserted after install; nothing in the
committed core INSERTs into them.

But the "keep names as operator-data" compromise that shipped alongside those
passes (see `13-research-pipelines.sql:64`: *"names (kimi-k2.6 / qwen3.7-plus /
opencode_go) are kept as operator-data"*) stopped one layer short of the bar
Michael just ratified. Two whole categories of hardcode survived that
compromise and are now out of bounds:

1. **Every pipeline stage's literal `"model"`/`"provider"` JSON field** — ~19
   files, well over 100 individual occurrences, naming `kimi-k2.6`,
   `qwen3.7-plus`, `deepseek-v4-flash`, `glm-5.1`, `opencode_go` directly in
   `stages` jsonb and in `stage_models` INSERTs, baked into the numbered core
   chain (not `examples/`, not an overlay).
2. **The substrate-wide last-resort fallback itself** —
   `stewards.catalog_default_provider()` and `catalog_default_model()`
   (`extension/14-fanout-brainstorm.sql:78-97`) are `IMMUTABLE` SQL functions
   that return the string literals `'opencode_go'` and `'kimi-k2.6'`. Verified
   live: `SELECT stewards.catalog_default_provider(), catalog_default_model(...)`
   → `opencode_go | kimi-k2.6`, right now, on the running database. This is the
   literal "preference of a default model" the ratified principle names — it
   is not overridable by an operator without editing SQL source, and every
   4-layer resolution ladder in the dispatcher bottoms out here.

Two more findings turned up that are more severe than "a name in a seed row":

- **Embeddings are unconditionally forced onto `lm_studio`.** The BEFORE
  INSERT trigger `trigger_embed_provider_route()` (`15a-context-engrams.sql:1388-1409`)
  rewrites `NEW.provider := 'lm_studio'` for *every* `kind='embed'` row, no
  config check, no opt-out. On a fresh install with no LM Studio running,
  every embed enqueue is silently rerouted to a provider that doesn't exist.
- **`generate_image` bypasses the provider/credential system entirely.**
  `cmd/stewards-mcp/images.go` reads `STEWARDS_PROVIDER_GOOGLE_GEMINI_API_KEY`
  directly from the process environment (not through `providers.rs`'s registry
  or the 88-credentials DB overlay), hardcodes `imgProvider = "google_gemini"`
  and defaults `model = "gemini-2.5-flash-image"`. A wizard-configured
  `google_gemini` credential does not make this tool work; only the pre-88 env
  var does.

The dispatch mechanism itself (`providers.rs`, `resolve_dispatch_provider`,
`chat()`/`embed()` in `bgworker.rs`, the alias table, `88-credentials.sql`,
the wizard) is genuinely well-built and model-agnostic — zero hardcoded names
in any of it. The problem is entirely upstream of dispatch: what gets *fed*
into the 4-layer resolution ladder before it ever reaches that clean core.

---

## 1-2. Inventory + classification

Legend: **STRIP** = core ships without it, moves verbatim to the local overlay.
**PARAMETERIZE** = the mechanism stays, the seeded default becomes
NULL/config-driven with a graceful degrade. **KEEP** = already model-agnostic
mechanism; no change needed (noted so it isn't re-litigated).

### A. The substrate-wide last-resort default — the core violation

| File:line | What's seeded | Class |
|---|---|---|
| `extension/14-fanout-brainstorm.sql:78-84` | `catalog_default_provider()` — `IMMUTABLE SQL` function, `RETURNS 'opencode_go'` unconditionally | **PARAMETERIZE** |
| `extension/14-fanout-brainstorm.sql:86-94` | `catalog_default_model(p_provider)` — `CASE p_provider WHEN 'opencode_go' THEN 'kimi-k2.6' ... ELSE NULL END` | **PARAMETERIZE** |

Verified live: `SELECT stewards.catalog_default_provider(), stewards.catalog_default_model('opencode_go')` → `opencode_go | kimi-k2.6`. Every literal-model dispatch that falls through `work_item_override → stage → pipeline.metadata` lands here. This is the ONE function that must become `stewards.config_get_text('default_provider', NULL)` / a config-driven model lookup for the "lifeless db" principle to hold anywhere in the dispatch ladder.

### B. Watchman / steward / gates / sabbath — hardcoded self-check dispatch

| File:line | What's seeded | Class |
|---|---|---|
| `extension/03-watchman.sql:539-540` | `CREATE TABLE ... default_provider text NOT NULL DEFAULT 'opencode_go', default_model text NOT NULL DEFAULT 'kimi-k2.6'` (a schema-level column DEFAULT, not just a seed row) | **PARAMETERIZE** (drop `NOT NULL DEFAULT`, allow NULL, degrade) |
| `extension/03-watchman.sql:727-728, 736-737` | `coalesce(p_provider, default_provider, 'opencode_go')` / `coalesce(p_model, default_model, 'kimi-k2.6')` — hardcoded literal at the end of the coalesce chain | **PARAMETERIZE** |
| `extension/08-gates.sql:323-324, 467-468, 593-594` | `v_gate_model := 'qwen3.7-plus'` / `'kimi-k2.6'`; `v_gate_provider := 'opencode_go'` — 3 gate self-test dispatches | **STRIP/PARAMETERIZE** (route through `catalog_default_*` once fixed, or a dedicated `gate_dispatch_model` config key mirroring 36's pattern) |
| `extension/10-sabbath-atonement.sql:254-255, 390-391` | same `v_gate_model`/`v_gate_provider` pattern, 2 occurrences | same |
| `extension/12-council.sql:218, 248, 327, 385` | `v_provider text := 'opencode_go'`; `coalesce(v_member->>'model','kimi-k2.6')`; `v_synth_model text := 'kimi-k2.6'` | **STRIP/PARAMETERIZE** |

### C. `stage_models` INSERTs — literal models across 8 pipeline files

| File:line | Pipeline / stage | Model | Class |
|---|---|---|---|
| `13-research-pipelines.sql:352-356, 705-710, 821-823, 940-943, 1043-1046` | research-write, planning, agent-proposal, revise-proposal, research-summary (12 stage rows) | `qwen3.7-plus`, `kimi-k2.6` | **STRIP** |
| `20-coder.sql:175-187` | code-write, code-pr, code-deploy (9 stage rows) | `kimi-k2.6`, `glm-5.1` | **STRIP** |
| `35-research-doc-construction.sql:149-152+` | research-summary/research-write build+critique | `reason`/`critic` (aliases — see note) | **KEEP** (already alias-based) |
| `90-harness-executor.sql:164-166` | harness-review/dispatch | `kimi-k2.6` | **STRIP** |
| `94-wiki-curator.sql:430-432, 746-747, 834-835` | wiki-organize, wiki-collect-entity, wiki-collect (4 stage rows) | `kimi-k2.6` | **STRIP** |
| `99-route-intake.sql:310-312` | route-intake classify/match | `kimi-k2.6` | **STRIP** |
| `98-crawler.sql:901-902` | crawl/step | `deepseek-v4-flash` | **STRIP** |
| `102-war-game.sql:118-121` | war-game wargame/critique | `sonnet#wargame`, `sonnet#critic` on provider `loom` | **STRIP** — this is exactly Michael's local economics (verified live: identical rows exist on the running DB), not a public default |

Note on `35-research-doc-construction.sql`: this file is the one place in the
`stage_models` inventory that already does it right — it points stages at the
**aliases** `reason`/`critic`, not literal models. This is the pattern the
other 7 files should have used from the start.

### D. Inline `stages` jsonb literals (pipeline definitions, not `stage_models`)

| File:line | Pipeline | Model/provider | Class |
|---|---|---|---|
| `04-work-items.sql:1337-1338` | (example/demo pipeline in the same file as the core table) | `kimi-k2.6` / `opencode_go` | **STRIP** |
| `14-fanout-brainstorm.sql:572-737` | 12 brainstorm-lens pipelines' `metadata.default_model/default_provider` (scamper, six-hats, crazy8s, reverse, mind-mapping, brainwriting, starbursting, disney, storyboarding, triz, forced-analogy, worst-idea) | `qwen3.7-plus` / `kimi-k2.6`, all on `opencode_go` | **STRIP** (24 literal occurrences) |
| `15a-context-engrams.sql:785,810,819,912,931,994,1008,1107,1183,1197,1201,1862,1881,1891` | engram-extractor direct `work_queue` inserts (bypasses `work_item_dispatch_stage` entirely — this is a hand-built payload, not a pipeline stage) | `deepseek-v4-flash` / `opencode_go` (14 occurrences) | **STRIP/PARAMETERIZE** — route through a `judge_dispatch_provider`/`judge_dispatch_model` config pair like `36-judge-local-routing.sql` already does for the *other* background judges |
| `15b-context-surface.sql:1369,1387,1396,1407,1559` | ES.3 judge-brief, same direct-insert shape | `deepseek-v4-flash` / `opencode_go` | same as above |
| `15b-context-surface.sql:2033,2040,2047,2054,2061,2068` | 6 subagent pipelines (url-summary, files-audit, session-investigate, doc-summary, doc-investigate, docs-audit) | `qwen3.7-plus` / `opencode_go` | **STRIP** |
| `16-subagents.sql:404,427,435` | subagent dispatch helper, direct insert | `deepseek-v4-flash` / `opencode_go` | **STRIP/PARAMETERIZE** |
| `16-subagents.sql:785` | prompt-critic pipeline | `qwen3.7-plus` / `opencode_go` | **STRIP** |
| `17-personas.sql:82` | persona-turn (the default persona pipeline) | `kimi-k2.6` / `opencode_go` | **STRIP** |
| `17-personas.sql:104, 115` | persona-turn-lmstudio, persona-turn-gemini — explicitly documented as "an example backend" | `qwen/qwen3.6-27b`/`lm_studio`, `gemini-3.5-flash`/`google_gemini` | **KEEP-as-example**, but belongs in `examples/` not the numbered core chain (naming honesty issue, not a routing-default issue) |
| `21-compact-context.sql:288` | compactor pipeline | `deepseek-v4-flash` / `opencode_go` | **STRIP/PARAMETERIZE** |
| `99-route-intake.sql:263,270` | route-intake direct dispatch (pre-`stage_models`) | `kimi-k2.6` / `opencode_go` | **STRIP** |
| `94-wiki-curator.sql:384,391,722,808` | wiki-organize/collect direct inserts | `kimi-k2.6` / `opencode_go` | **STRIP** |
| `98-crawler.sql:859` | crawler direct insert | `deepseek-v4-flash` / `opencode_zen` | **STRIP** |

### E. `model_aliases` seed mutations living in core (not overlay)

| File:line | What's seeded | Class |
|---|---|---|
| `extension/68-model-fallback-hardening.sql:90-108` | `DELETE`/`UPDATE`/`INSERT` against `model_aliases` for `ingest`/`research-local`/`reason`/`critic`, naming `gemma-4-26b-a4b`, `qwen3.6-35b-a3b` on `flexllama`, and re-prioritizing `opencode_go` members | **STRIP** — this is Michael's specific local-rig topology (two named local models on a named local server), landed directly in the numbered core chain instead of the overlay the file's own sibling files (`06`, `19`, `31`) established as the pattern |
| `examples/models.sql:85-89` | `model_aliases` seeds for `ingest`/`reason`/`critic` at **priority 5** (explicitly documented "PUBLIC defaults... a low-precedence floor... a deployer who adds local members at priority 0 overrides them") | **KEEP** — this is the correct pattern: opt-in, low-priority, openly documented as a floor an overlay outranks |

### F. The `__queue_for_opus__` escalation sentinel

| File:line | What's seeded | Class |
|---|---|---|
| `06-cost.sql:369,390,399,442-443,454` | `model_escalation.next_model` sentinel value `'__queue_for_opus__'`; the escalation matrix itself is empty in core (seed rows moved to overlay per the file's own header) | **PARAMETERIZE** (rename) |
| `07-steward.sql:408,421-422` | same sentinel, consumed at the retry site | same |
| `32-alias-failover.sql:326,339-340` | same sentinel, consumed at the failover site | same |

The escalation *matrix* (which model follows which) is already correctly
empty/overlay-seeded. But the terminal-state **sentinel string itself** names
Opus in the core vocabulary — three separate call sites test literal equality
against `'__queue_for_opus__'`. A deployer whose top-of-ladder isn't Opus (the
codebase's own `84-tool-effect-gate.sql:167-169` comment: *"not everyone runs
Opus as their Hinge, and a Fable hinge is now possible"*) inherits a sentinel
name that lies about what it does. Rename to something generic
(`'__queue_for_hinge__'` or `'__escalate_to_human__'`) — mechanical, low-risk,
three call sites.

### G. Embeddings — the most severe hardcode, in a mandatory trigger

| File:line | What's seeded | Class |
|---|---|---|
| `15a-context-engrams.sql:1391-1394` | `IF NEW.kind='embed' AND provider<>'lm_studio' THEN NEW.provider := 'lm_studio'` — **unconditional**, no config check, no opt-out, fires on every embed enqueue | **PARAMETERIZE (critical)** |
| `15a-context-engrams.sql:1400-1403` | `payload.model := config_get_text('embed_model', 'nomic-embed-text-v1.5')` when absent | **PARAMETERIZE** (mechanism already config-driven — only the seeded literal default needs to become NULL-safe; already better than the provider line) |
| `15a-context-engrams.sql:1404-1407` | `payload.dimensions := config_get_text('embed_dimensions','768')::int` | **KEEP-ish** — a dimension number isn't a provider preference, but it's still an assumption tied to `nomic-embed-text-v1.5`'s width; fine to leave as a paired default with the model key |

This is flagged separately from the provider-list findings above because it
is not a "seed row an operator can delete" — it is unconditional trigger logic
with **no config knob for the provider at all** (only the model has one). A
brand-new install with zero providers configured will still try to route
every embed to `lm_studio`, fail with "unknown provider," and — per the
dispatch trace in §3 — that failure does not currently surface anywhere a
human would see it.

### H. Judge/background-dispatch config — the pattern already done right (mostly)

| File:line | What's seeded | Class |
|---|---|---|
| `36-judge-local-routing.sql:29-32` | `config_set('judge_dispatch_provider', 'opencode_go', ...)`, `config_set('judge_dispatch_model', 'deepseek-v4-flash', ...)` — **mechanism is config-driven** (exactly the right shape) | **KEEP mechanism / PARAMETERIZE default value** |
| `36-judge-local-routing.sql:48-49` | `config_get_text('judge_dispatch_provider','opencode_go')` / `config_get_text('judge_dispatch_model','deepseek-v4-flash')` — the fallback default embedded in the read call itself | same |

This file is the closest thing in the codebase to the target shape: a named
config key, an operator-settable value, and a documented public default. The
only residual issue is that the **public default value** is still a specific
paid-subscription provider/model rather than NULL. Once `catalog_default_*`
(§A) is fixed to genuinely return NULL absent configuration, this file's
fallback should point at `catalog_default_provider()`/`catalog_default_model()`
rather than repeating its own literal — one central "lifeless" default instead
of two.

### I. `resolveHarnessModel` — the loom/Claude-Code harness (Go)

| File:line | What's seeded | Class |
|---|---|---|
| `cmd/stewards-mcp/harness.go:131` | `harnessModelAliases = map[string]bool{"sonnet": true, "haiku": true, "opus": true}` — valid-value enum | **KEEP** (this is a real technical constraint: loom's only implemented backend is Claude Code, and Claude Code's `--model` flag only accepts these three short aliases — enumerating them is correctness, not preference) |
| `cmd/stewards-mcp/harness.go:143-146` | `resolveHarnessModel`: `if model == "" && backend == "claude" { return "sonnet" }` — hardcoded default | **PARAMETERIZE** |

The enum is defensible (it describes what the wrapped tool accepts, not a
preference). The *default* is not — an unspecified `model` silently becomes
`sonnet` rather than either failing loud or reading an operator-set default.
Minor relative to §A/§G, but same shape: "no model specified" resolves to a
paid model by hardcode instead of NULL/config.

### J. `generate_image` — bypasses the entire provider abstraction (Go)

| File:line | What's seeded | Class |
|---|---|---|
| `cmd/stewards-mcp/images.go:57-59` | `os.Getenv("STEWARDS_PROVIDER_GOOGLE_GEMINI_API_KEY")` — reads a raw env var directly, not through `providers.rs`'s registry or the 88-credentials DB overlay | **PARAMETERIZE (high)** |
| `cmd/stewards-mcp/images.go:63` | `os.Getenv("STEWARDS_PROVIDER_GOOGLE_GEMINI_BASE_URL")` — same pattern for the URL | same |
| `cmd/stewards-mcp/images.go:70,83` | `model = "gemini-2.5-flash-image"` default; `const imgProvider = "google_gemini"` | same |

This tool predates 88-credentials and never got migrated. A user who
configures `google_gemini` through the wizard (writing to
`stewards.credential_providers`, decrypted only inside the Rust bgworker via
SPI) gets no benefit here — this Go binary can't see that row at all, only the
pre-88 bare env var. It is invisible to the wizard in both directions: setting
it up here doesn't touch the wizard's provider list, and the wizard can't
configure it. Flagged again in §5 (wizard gaps).

### K. `provider_is_local` — a named-provider list duplicated Go+SQL

| File:line | What's seeded | Class |
|---|---|---|
| `95-model-role-toggles.sql:68-71` | `provider_is_local(p_provider) := p_provider IN ('flexllama', 'lm_studio')` — explicitly documented as mirroring `cmd/stewards-ui/api/activity.go`'s `localProviders` map | **KEEP, low-severity naming note** |

This isn't a routing default (it doesn't select what to dispatch to); it's a
UI/UX categorization ("badge this as local, offer the bulk rest-all-local
toggle"). Classify KEEP for the ratified principle's purposes, but it is
coupled to two specific named local-inference brands. An operator running a
third local stack (vLLM, Ollama, TGI) under a provider name of their choosing
gets no "local" badge/bulk-toggle unless they literally name their provider
`lm_studio` or `flexllama`. Worth a wizard gap entry (§5), not a strip.

### L. Provider protocol-quirk tables — genuinely mechanism, not preference

| File:line | What's seeded | Class |
|---|---|---|
| `15a-context-engrams.sql:~95-118` | `provider_rules` seed rows for `opencode_go`/`deepseek`/(gemini) documenting reasoning-field handling quirks (strip `reasoning_details`, keep `reasoning_content`, etc.) | **KEEP** |
| `47-multimodal.sql:134-181, 410-411` | `gemini_normalize_tool_turns()` + the `IF v_provider IN ('google_vertex','google_gemini')` branch that repairs functionCall/functionResponse adjacency | **KEEP** |

These name specific providers, but they are compatibility **facts** about
those providers' APIs (Gemini's turn-ordering requirement is real regardless
of whether anyone ever configures Gemini), not a default the substrate reaches
for. Judgment call, but the test is right: does un-setting every provider
change this code's behavior? For these two, no — they only fire when that
specific provider is the one actually dispatched to, which requires an
operator to have configured it in the first place. Distinguish from §A's
`catalog_default_*`, which fires **regardless of what's configured**, as the
literal last resort.

### M. `87-lab.sql` — experiment definitions naming specific models

| File:line | What's seeded | Class |
|---|---|---|
| `87-lab.sql:350-351` | a lab-experiment direct dispatch, `kimi-k2.6`/`opencode_go` | **STRIP** (same shape as the other direct-insert hardcodes) |
| `87-lab.sql:377-378` | an A/B experiment's `variants` jsonb naming `rung_top_model_alias: "fable"/"opus"/"claude-p-sonnet"` — comparing which model should sit at the top of the escalation ladder | **KEEP** — these are alias *names* being compared as experiment data (the point of the experiment is literally "which model should the Hinge be"), not a routing default. Legitimate lab content once the escalation-ladder table itself stays empty-by-default (confirmed: `84-tool-effect-gate.sql:191-194` seeds it only in a comment, not a live `INSERT`) |

### N. Wizard-side (Go + Vue) — genuinely the right shape, two low-severity notes

| File:line | What's seeded | Class |
|---|---|---|
| `cmd/stewards-ui/frontend/src/views/ProvidersWizard.vue:26-36` | `presets` dict: `opencode_zen`, `opencode_go`, `google_gemini`, `google_vertex`, `loom`, `nvidia`, `lm_studio`, `anthropic`, `custom` — base URLs + hints | **KEEP** — this is precisely "the credentials wizard becomes the only way models enter." A preset picklist is the wizard's whole job, same as an OAuth login screen listing known IdPs. |
| `ProvidersWizard.vue:41-46` | `preset = ref('opencode_zen')`, `budget = ref(5)` — the form's pre-selected default when the wizard is opened fresh | **PARAMETERIZE (cosmetic)** — defaulting the picklist to a specific paid subscription rather than blank/`custom` is a soft nudge, not a hardcode with runtime effect; low priority |
| `ProvidersWizard.vue:220-236` | `prefillKnownPrices()` — hardcodes `claude-haiku-4-5`/`claude-sonnet-4-6`/`claude-opus-4-8` prices, only fires for `opencode_zen` after the operator has already picked those exact model ids from a live `/models` listing | **KEEP** — convenience data (known public pricing), not a selection; only ever pre-fills a field the operator can overwrite |
| `cmd/stewards-ui/api/credentials.go`, `providers.go`, `models.go` | grepped for every provider/model name pattern — **zero hardcoded defaults found**, only doc-comment examples (`e.g. opencode_go, google_gemini`) | **KEEP** |
| `extension/src/providers.rs` (whole file) | env-var registry + DB-credential overlay, `Provider`/`AuthMode` structs — **zero hardcoded provider or model names anywhere** | **KEEP** — this file is the reference example for what "no preference" mechanism looks like |
| `extension/src/bgworker.rs` `resolve_dispatch_provider`/`dispatch`/`chat`/`embed` | fully generic; `provider.default_model` is read from the resolved `Provider`, never hardcoded in Rust | **KEEP** |
| `extension/88-credentials.sql` (whole file) | encrypted credential store, `provider_dials_set`, `credential_providers` view — **zero hardcoded provider/model names** except one comment ("the wizard defaults opencode_zen to $5/day") describing the Vue-side default noted above | **KEEP** |
| `extension/31-model-aliases.sql` `model_aliases` table + `pick_alias_member` | table ships **empty**; verified live it holds only operator-added rows (39, none of which are in any committed file) | **KEEP** |

---

## 3. The dispatch-path trace

**Where a NULL/unconfigured model actually breaks today**, traced through
`pick_usable_model`/`work_item_dispatch_stage` (the FINAL body is
`31-model-aliases.sql:271-493`, later-file-wins over `19-models.sql` and
`20-coder.sql`'s copies) and its callers.

### The failure mode: `RAISE EXCEPTION`, not a soft landing

`work_item_dispatch_stage` raises a hard Postgres exception at eight distinct
points, three of which are exactly the "lifeless db" case:

- `v_model IS NULL` → *"could not resolve model — checked work_items.model_override, stages.model, pipelines.metadata.default_model (+ alias members), catalog_default_model(%) — all NULL"* (line 382-385)
- an alias with no usable member → *"model alias '%' has no usable member... dispatch refused"* (line 351-355)
- capability-unusable with no substitute, spend-cap exceeded, provider NULL, agent_family missing, stage/work_item not found — five more `RAISE EXCEPTION`s

None of these degrade to `needs_attention` **inside the function itself**. The
substrate already has the exact right landing spot for this — `89-attention.sql`'s
`needs_attention` view already unions a `'review'` bucket for
`work_items.status = 'awaiting_review'` with no `a2a_question`, surfacing
`coalesce(error, ...)` as the question text. Verified live: this bucket is
already catching real dispatch failures today (`code-pr / review: "chat
dispatch failed at stage review: decode chat SSE stream: sse error..."`) — the
graceful-degrade *pattern* exists and works. The problem is it's applied
inconsistently across `work_item_dispatch_stage`'s ~20 call sites.

### Callers that already catch it (safe today)

- **`04-work-items.sql:837-851`** — `handle_work_item_chat_completion()`, the
  AFTER UPDATE auto-advance trigger. Wraps the dispatch call in
  `BEGIN ... EXCEPTION WHEN OTHERS THEN UPDATE work_items SET status =
  'awaiting_review', error = ... END`. This is the majority path (every
  auto-advancing pipeline stage) and it already does exactly what §2 of the
  task asks for.
- **`18-scheduler.sql:337-366`** — `scheduled_pipelines_fire()`. Wraps
  `work_item_create` + `work_item_dispatch_stage` together in one
  `BEGIN/EXCEPTION`. Softer failure mode worth noting: on exception the whole
  sub-transaction (including the just-created `work_item` row) rolls back, so
  **no row survives to show a human anything** — the scheduled pipeline just
  silently retries next tick forever (`RAISE NOTICE` only, server log). A
  permanently-misconfigured scheduled pipeline is invisible in the UI, not
  merely delayed.

### Callers that do NOT catch it (the actual gap)

- **`89-attention.sql:215-226`** — `attention_answer()`'s `'review'` branch is
  the resume path for a *previously* paused stage. It calls
  `work_item_dispatch_stage` **unwrapped**. If the human resumes a paused item
  whose model config is still broken, the Stewdio "answer" API call throws an
  unhandled Postgres exception straight back to the HTTP caller — the exact
  "erroring cryptically" the task names, and it happens on the one surface
  (the attention bell) built specifically to make failures easy to resolve.
- **`99-route-intake.sql:675-691`** — `route_intake()`, called directly from
  an MCP tool an agent uses to submit new work. `work_item_create` then an
  unwrapped `work_item_dispatch_stage`. A misconfigured `route-intake` stage
  fails the *entire tool call* with a raw SQL exception, not a work item the
  human can go look at.
- **`16-subagents.sql:254,915`**, **`14-fanout-brainstorm.sql:891,1130`**,
  **`102-war-game.sql:215,370,377,394`**, **`94-wiki-curator.sql:638,1089`**,
  **`98-crawler.sql:709`**, **`46-chat-tasks.sql:79`**, **`49-doc-extract.sql:242`**,
  **`07-steward.sql:454`** — all first-dispatch or retry call sites, all
  unwrapped. Same failure shape as `route_intake`: whoever/whatever is
  synchronously calling the SQL function gets a raw exception instead of a
  work item parked in `needs_attention`.

### The embed path is worse: no work_item wrapper exists at all

Embeds are enqueued directly into `work_queue` (from doc/brain_entry
population triggers), not through `work_item_dispatch_stage` — there is no
`work_items` row to flip to `awaiting_review` in the first place. Combined
with §2.G's unconditional `provider := 'lm_studio'` rewrite: on an install with
no `lm_studio` configured, `resolve_dispatch_provider('lm_studio')` in
`bgworker.rs` returns `Err("unknown provider: lm_studio")`, the `work_queue`
row flips to `status='error'`, and — no trigger was found reacting to that
transition — the source doc/brain_entry simply stays permanently unembedded
with no visible signal anywhere. This is the literal "docs land unembedded"
half of the task's embedding requirement; only the "+ a nudge" half is
missing.

### The minimal fix (does not require re-architecting the dispatcher)

1. **`catalog_default_provider()`/`catalog_default_model()`** (§A): rewrite as
   `stewards.config_get_text('default_provider', NULL)` /
   a config-driven lookup keyed off the resolved provider. `config_get_text`
   already supports a NULL default cleanly (`00-config.sql:32-36`) — this is a
   two-function, mechanical change.
2. **Inside `work_item_dispatch_stage`**, narrow the blanket-vs-specific
   distinction: keep hard `RAISE EXCEPTION` for genuine programming errors
   (work_item not found, bad status transition), but for the three
   "unconfigured, not broken" cases — `v_model IS NULL`, alias-has-no-member,
   capability-unusable-with-no-substitute — catch them *at the call site*
   consistently (a small helper, e.g. `work_item_dispatch_stage_safe()`, or
   push the try/catch pattern from `04-work-items.sql` into every currently-bare
   caller) and land the work_item at `status='awaiting_review'` with
   `error = 'no model configured for stage <name> of pipeline <family> — open
   Settings → Providers & Models to assign one'`. This reuses the *existing*
   `needs_attention` `'review'` bucket verbatim — no new UI surface needed.
3. **`trigger_embed_provider_route()`**: stop unconditionally forcing
   `provider := 'lm_studio'`. Read `config_get_text('embed_provider', NULL)`
   instead; if NULL, leave `NEW.provider` as given (or fail the trigger loud
   at enqueue time with a clear message) rather than silently rerouting to a
   provider the operator may never have installed. Separately: add a
   completion-trigger arm (mirroring `handle_work_item_chat_completion`'s
   shape) that, on an embed `work_queue` row landing `status='error'`, marks
   the source doc/brain_entry row with a visible "unembedded — no embedding
   provider configured" flag rather than leaving it silently NULL forever.

---

## 4. The local overlay file

Written to `.spec/lightening/local-overlay-example.sql` — everything core
would lose under the STRIP classifications above, expressed as one idempotent
file (`ON CONFLICT DO NOTHING`/`DO UPDATE` throughout, safe to re-run). It
captures Michael's ratified local economics: loom (sonnet/haiku/opus seats,
including `sonnet#wargame`/`sonnet#critic`) as the primary doer/critic tier,
`opencode_go` as the subscription workhorse tier, local models
(`lm_studio`/`flexllama`) as non-critical extras. Verified against the LIVE
`model_aliases` table (39 rows, none committed anywhere in this repo) so the
template reflects what is actually running, not a guess.

## 5. Wizard gaps, ranked

1. **No per-pipeline-stage or per-role model assignment beyond the four
   fixed role aliases (`reason`/`ingest`/`critic`/`vision`).** The wizard can
   assign a model to a *role*, but every hardcoded `stage_models` row found in
   §2.C (research-write, code-write, code-pr, wiki-organize, route-intake,
   crawl, war-game, harness-review — 8 pipeline families, ~30 individual
   stages) has no wizard surface at all today. An operator who wants
   `code-pr/review` to use a different critic than `research-write/review`
   has to hand-edit SQL. The wizard's role-alias model is the right shape;
   it just doesn't reach far enough — either (a) grow `stage_models` rows to
   optionally reference an alias (the pattern `35-research-doc-construction.sql`
   already uses) and expose "which alias does this stage use" per pipeline in
   the wizard, or (b) add a stage-scoped override table with its own wizard
   panel.
2. **No embedding-model/provider slot in the wizard at all.** `embed_model`/
   `embed_dimensions`/(the not-yet-existing) `embed_provider` are pure
   `stewards.config` keys, invisible to `ProvidersWizard.vue` — a user has no
   UI path to say "use this provider for embeddings," only a hardcoded
   `lm_studio` (§2.G). Given embeddings are load-bearing for doc/brain search,
   this is a first-run wall as real as the one 88-credentials fixed for chat.
3. **`loom` is folded into the generic OpenAI-preset shape but isn't really
   generic.** The wizard's `loom` preset (`ProvidersWizard.vue:31`) treats loom
   as an OpenAI-compatible endpoint with a bearer token — which works for the
   `loom serve` bridge that dispatches through `chat()`/`bgworker.rs`, but is a
   *different* loom integration from `cmd/stewards-mcp/harness_run` (the
   subprocess-exec path, entirely env-var configured:
   `STEWARDS_LOOM_BIN`/`STEWARDS_HARNESS_CLAUDE_HOME`/`STEWARDS_HARNESS_MCP_URL`,
   none of it wizard-visible). An operator configuring "loom" in the wizard has
   no way to know it doesn't touch `harness_run`'s configuration at all, or
   that the model roster there (`sonnet`/`haiku`/`opus`, §2.I) is a hardcoded
   Go enum rather than anything the wizard's model-pick step could ever list.
4. *(honorable mention, not top-3 but worth recording)* **`generate_image` is
   wizard-invisible in both directions** (§2.J) — it doesn't appear in the
   credentials list and configuring `google_gemini` through the wizard doesn't
   make it work. And **no wizard action for "reset to no default"** — once a
   provider/model is wizard-configured there's no UI path back to the
   "lifeless db" state to verify the graceful-degrade behavior a fresh install
   would actually see.
