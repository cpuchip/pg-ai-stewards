//! pg_ai_stewards — Phase 1, step 2.
//!
//! Scope of this revision:
//!   1. Bgworker registered via `shared_preload_libraries`.
//!   2. `stewards.work_queue` table for asynchronous work.
//!   3. `stewards.enqueue(kind, provider, payload)` — produces work.
//!   4. Bgworker polls every 500ms, claims one row at a time using
//!      `FOR UPDATE SKIP LOCKED`, runs a stub "echo" provider,
//!      writes result back, `NOTIFY stewards_done '<id>'`.
//!   5. Provider registry parsed from `STEWARDS_PROVIDER_*` env vars
//!      at worker startup. Visible (without secrets) via
//!      `stewards.providers_loaded()`.
//!
//! Out of scope:
//!   - Real HTTP provider calls (tokio + reqwest land in step 6/7).
//!   - LISTEN-driven wake-up (we poll; NOTIFY on completion still works).
//!   - Brain schema (step 3).

use pgrx::prelude::*;

mod bgworker;
mod providers;
mod schema;
mod tools;
mod types;
mod yaml;
use providers::{Provider, ProviderRegistry, ProviderSummary, PROVIDER_REGISTRY};

::pgrx::pg_module_magic!();


// =====================================================================
// The install chain — extension_sql_file! blocks in dependency order.
//
// The .sql files are the canonical source of each block's text
// (extension_sql_file! reads them at compile time via include_str!
// semantics). Editing the SQL files is the right move; editing the
// macro signatures here is only for renames/dependency changes.
//
// Idempotency: every block uses CREATE OR REPLACE, ADD COLUMN IF NOT
// EXISTS, ON CONFLICT DO UPDATE, etc. so applying the same block twice
// is a no-op. This matters for `cargo pgrx schema` which may run blocks
// multiple times during development.
//
// Consolidation leg (2026-06-12): the authored chain begins here.
// 00-config, 01-graph, and 02-workstreams are the new foundation;
// numbered subsystem files progressively replace the historical
// chain below (see .spec/proposals/authoring-blueprint.md).
// =====================================================================

extension_sql_file!(
    "../00-config.sql",
    name = "create_config",
    requires = ["create_doc_show"],
);

extension_sql_file!(
    "../01-graph.sql",
    name = "create_graph",
    requires = ["create_config"],
);

extension_sql_file!(
    "../02-workstreams.sql",
    name = "create_workstreams",
    requires = ["create_graph"],
);

extension_sql_file!(
    "../03-watchman.sql",
    name = "create_watchman",
    requires = ["create_workstreams"],
);

extension_sql_file!(
    "../04-work-items.sql",
    name = "create_work_items",
    requires = ["create_watchman"],
);

extension_sql_file!(
    "../05-mcp-bridge.sql",
    name = "create_mcp_bridge",
    requires = ["create_work_items"],
);

// (OSS extraction 2026-06-12: four downstream seed migrations removed from
//  the bundle chain here — fetch-md/git-mcp server seeds, per-agent grant
//  broadening, and container-path rewrites are operator/overlay data, not
//  machinery. They apply as overlay migrations in a downstream repo.)

// ---------------------------------------------------------------------------
// Phase 4a — Substrate-Phase-A schema (D-A4 cost tracking + D-B1 escalation
// chain + D-EC3 human-mediated escalation queue).
// Spec: projects/pg-ai-stewards/.spec/proposals/{cost-tracking,escalation-chain}.md
// ---------------------------------------------------------------------------

extension_sql_file!(
    "../06-cost.sql",
    name = "create_cost",
    requires = ["create_mcp_bridge"],
);

extension_sql_file!(
    "../07-steward.sql",
    name = "create_steward",
    requires = ["create_cost"],
);

// =====================================================================
// Consolidation leg B3 (2026-06-13): the historical 5a–5g4/6d/am1 chain
// is replaced by five authored subsystem files. Each is a single, final
// definition (no per-phase redefinitions); see the authoring-blueprint.
//   08-gates   — maturity ladder, gate eval, scenarios/verify, the
//                review-prefix BEFORE gate + the maturity→verified
//                AFTER producer trigger.
//   09-intents — intents + covenants (values_anchor, extensions catch-all,
//                presiding render + Watch echo), config-driven intent
//                defaulting, covenant_check.
//   10-sabbath — endings (Sabbath) + lessons-from-failure (Atonement) +
//                the file-materialize queue + producers.
//   11-trust   — trust ladder + counters + the trust-gated
//                apply_gate_decision (authored HERE: its trust check
//                SELECTs from trust_scores, born in this file).
//   12-council — convene → deliberate → synthesize → bishop resolution +
//                the resolution-file producer.
// Linear requires chain; sweep for non-linear edges on any future cut.
// =====================================================================

extension_sql_file!(
    "../08-gates.sql",
    name = "create_gates",
    requires = ["create_steward"],
);

extension_sql_file!(
    "../09-intents-covenants.sql",
    name = "create_intents_covenants",
    requires = ["create_gates"],
);

extension_sql_file!(
    "../10-sabbath-atonement.sql",
    name = "create_sabbath_atonement",
    requires = ["create_intents_covenants"],
);

extension_sql_file!(
    "../11-trust.sql",
    name = "create_trust",
    requires = ["create_sabbath_atonement"],
);

extension_sql_file!(
    "../12-council.sql",
    name = "create_council",
    requires = ["create_trust"],
);

// =====================================================================
// Consolidation leg B4 (2026-06-13): research / planning / agent-write-back
// pipeline seeds + their apply functions. Single final definitions.
//   13-research-pipelines — research-write (4-stage), planning (5-stage),
//                agent-proposal, revise-proposal, research-summary +
//                enqueue_proposed_work_items / apply_agent_proposal (i7
//                final, incl. i6 gate) / apply_revision. on_maturity_verified
//                is NOT redefined here — 08 owns its single final form and
//                calls these functions as wrapped forward refs.
// =====================================================================

extension_sql_file!(
    "../13-research-pipelines.sql",
    name = "create_research_pipelines",
    requires = ["create_council"],
);

// 14-fanout-brainstorm — fan-out decomposition + the 12-lens brainstorm
// library. catalog_default_* helpers (j8a), spawn_children (j3+j4+j8c
// union), start_brainstorm (j12), check_and_dispatch_fanout_aggregator +
// the one-shot / child-terminal triggers. on_maturity_verified's fanout
// branches are folded into 08's single final form (calls these as
// late-bound forward refs).
extension_sql_file!(
    "../14-fanout-brainstorm.sql",
    name = "create_fanout_brainstorm",
    requires = ["create_research_pipelines"],
);

// =====================================================================
// Consolidation leg B4/15 (2026-06-13): the context engine, split in two.
//   15a-context-engrams — the engram + corpus DATA layer: messages.engrams
//                schema + extractor agent/pipeline (provenance-tagged),
//                provider_rules + budget cascade + graduated-render helper,
//                engram_embeddings + search, map-reduce extraction, the
//                injection regex screen, embed-route + model-substitution
//                logging, the work-kind crash-loop breaker, and the engram
//                tools (expand_message / mark_engram_important /
//                re_extract_engrams / summarize_my_context / read_corpus_parents).
//                Authors the FINAL post-ES.3 state — the es9-dropped leaf
//                machinery (chunk_and_index, contextualize_leaf, the leaves
//                table, retrieve_with_merge, render_judge_surface) and its
//                orphaned helpers are simply not built (no build-then-drop).
//   15b-context-surface — the live composition + judge surface: compose_messages
//                FINAL (ct2-7a2 — folds k2→l13 + the §7 self-notes line), the
//                CT2 state model / levers / self-notes / working tags, the
//                judge-brief dispatch path (es7; intercept content-sha via
//                built-in sha256 — pgcrypto-free), the heavyweight wrappers
//                (the 3 study-corpus ones renamed → doc_*), tool-round caps
//                (chat_post_internal final), the 5-arg dry_run_chat wrapper,
//                and the work_item_cancel hard-stop cascade. compose_tools'
//                final is deferred to 16 (its ct2-7e CASE gate calls
//                self_prompt_on, a CREATE-time sql dep born there).
// =====================================================================

extension_sql_file!(
    "../15a-context-engrams.sql",
    name = "create_context_engrams",
    requires = ["create_fanout_brainstorm"],
);

extension_sql_file!(
    "../15b-context-surface.sql",
    name = "create_context_surface",
    requires = ["create_context_engrams"],
);

extension_sql_file!(
    "../16-subagents.sql",
    name = "create_subagents",
    requires = ["create_context_surface"],
);

extension_sql_file!(
    "../17-personas.sql",
    name = "create_personas",
    requires = ["create_subagents"],
);

extension_sql_file!(
    "../18-scheduler.sql",
    name = "create_scheduler",
    requires = ["create_personas"],
);

extension_sql_file!(
    "../19-models.sql",
    name = "create_models",
    requires = ["create_scheduler"],
);

extension_sql_file!(
    "../20-coder.sql",
    name = "create_coder",
    requires = ["create_models"],
);

extension_sql_file!(
    "../21-compact-context.sql",
    name = "create_compact_context",
    requires = ["create_coder"],
);

extension_sql_file!(
    "../22-reflect-steward.sql",
    name = "create_reflect_steward",
    requires = ["create_compact_context"],
);

// 23: the substrate's self-presiding guard — a deterministic watchman tick
// wired into watchman_scheduler_fire (later-file-wins) that auto-pauses the
// reflect-steward on a runaway signal and logs every trip. Re-authors
// reflect_status + watchman_scheduler_fire, so it follows 22.
extension_sql_file!(
    "../23-reflect-watchman.sql",
    name = "create_reflect_watchman",
    requires = ["create_reflect_steward"],
);

// 24: skills — on-demand, agent-managed instruction modules. The base skills
// table + flat catalog already exist (schema.rs / 09); this adds the 3-tier
// catalog (groups -> frontmatter -> loaded bodies), the load/unload/open/close
// levers, the loaded-skill budget gate, and render_skills_block (called by
// compose_system_prompt, late-bound). Re-authors compose_tools (later-file-wins)
// to surface the skill_* levers, so it follows everything it reads.
extension_sql_file!(
    "../24-skills.sql",
    name = "create_skills",
    requires = ["create_reflect_watchman"],
);

// 25: corpus treatment — the intent→project map + an additive BEFORE-INSERT
// trigger that fills work_items.project_association when NULL. Lets the digest
// loops (book/video/news) feed a compounding pool like the reflect-steward
// (08's pool-publish is now decoupled from file-materialize and gates on
// project_association). Empty map in core; the operator overlay seeds it.
extension_sql_file!(
    "../25-corpus.sql",
    name = "create_corpus",
    requires = ["create_skills"],
);

// 26: agent productivity surface — todos + goals coupled to the working-tag
// lifecycle (todo_done auto-folds via context_mute_tag). The usage-driver for
// the context engine. Re-authors compose_tools (later-file-wins) to surface
// todo_/goal_ levers; compose_system_prompt (09) calls render_agenda (late-bound).
extension_sql_file!(
    "../26-productivity.sql",
    name = "create_productivity",
    requires = ["create_corpus"],
);

// 27: context_search — deterministic grep over an agent's OWN durable context
// (+ the watch over non-private descendants) with a manual session `private`
// wall. The Ctrl-F a model can't do over its lossy window. context_* names, so
// compose_tools (26) already surfaces them on context-enabled agents.
extension_sql_file!(
    "../27-context-search.sql",
    name = "create_context_search",
    requires = ["create_productivity"],
);

// 28: the guard's narrow auto-resume — releases its own brake once a self-clearing
// breach (spend/in_flight) passes the deadband. Re-authors reflect_pause /
// reflect_watchman_tick / watchman_scheduler_fire / reflect_status (later-file-wins).
extension_sql_file!(
    "../28-guard-autoresume.sql",
    name = "create_guard_autoresume",
    requires = ["create_context_search"],
);

// 29: a "private" intent routes its materialized file drops under private/<intent>/
// instead of the shared public pipeline dirs (one BEFORE-trigger on file_destination).
extension_sql_file!(
    "../29-intent-private-routing.sql",
    name = "create_intent_private_routing",
    requires = ["create_guard_autoresume"],
);

// 30: per-tool-group usage primers — teach the model WHEN to reach for its
// substrate-native tools (it wasn't trained on them). compose_system_prompt (09)
// calls render_tool_primers late-bound, like render_skills_block/render_agenda.
extension_sql_file!(
    "../30-tool-primers.sql",
    name = "create_tool_primers",
    requires = ["create_intent_private_routing"],
);

// 31: logical model aliases (a name -> ordered provider/provider_model members)
// + the file_private no-train guard rail. Re-authors work_item_dispatch_stage so
// the requested model may be an alias that falls back across providers, and a
// file_private intent never dispatches to a train-on-data provider.
extension_sql_file!(
    "../31-model-aliases.sql",
    name = "create_model_aliases",
    requires = ["create_tool_primers"],
);

// 32: runtime failover across alias members — when a provider fails mid-call
// (transient/timeout), the steward walks an alias-dispatched stage to its next
// untried member. Also broadens diagnose_failure to the real outage shapes
// (any 5xx incl. Cloudflare 52x, 529 overloaded).
extension_sql_file!(
    "../32-alias-failover.sql",
    name = "create_alias_failover",
    requires = ["create_model_aliases"],
);

// 33: page in large tool results — compose_messages caps a single oversized
// rendered message to a head + a page-in banner (page_in_cap), and the model
// reads the rest via result_read / result_search. Stops one fat fresh fetch
// from blowing a small window; pairs with the window-aware budget (15a 2.5).
extension_sql_file!(
    "../33-page-in.sql",
    name = "create_page_in",
    requires = ["create_alias_failover"],
);

// 34: agentic doc construction — the model BUILDS a doc via small tool-call
// diffs (doc_create/append/patch/read/finalize over a self-contained
// doc_drafts table) instead of one-shot emitting it; its chat output becomes
// a journal. Sidesteps the local-model soak's reaper/contention/grammar
// failures; pairs with the page-in tools (33) for bounded source reads.
extension_sql_file!(
    "../34-doc-builder.sql",
    name = "create_doc_builder",
    requires = ["create_page_in"],
);

// R2b/R2c of the local-learnings rollout: recast research-summary + research-write
// onto doc-construction (synthesize->build via doc_*, review->critique + doc_finalize),
// so the small local model never one-shots the whole digest/piece. Needs both the
// research pipelines (13) and the doc tools (34).
extension_sql_file!(
    "../35-research-doc-construction.sql",
    name = "create_research_doc_construction",
    requires = ["create_research_pipelines", "create_doc_builder"],
);

// Route the 3 background judges (engram-extractor/judge-brief/watchman-consolidator)
// to a local model via a config-gated BEFORE-INSERT reroute on work_queue, instead of
// their hardcoded opencode_go. Needs work_queue (04) + the engram/subagent/watchman
// judges (15a/16/03) to exist as the families it targets.
extension_sql_file!(
    "../36-judge-local-routing.sql",
    name = "create_judge_local_routing",
    requires = ["create_subagents"],
);

// Per-stage TOOL scoping (the tool-side mirror of skill groups): a pipeline stage
// names tool_groups it needs, and dry_run_chat narrows compose_tools to that scope —
// so a research gather turn ships ~15 tools, not ~150. Needs compose_tools (26 final)
// + dry_run_chat + work-items/pipelines.
extension_sql_file!(
    "../37-tool-groups.sql",
    name = "create_tool_groups",
    requires = ["create_productivity"],
);

extension_sql_file!(
    "../38-edge-vocabulary.sql",
    name = "create_edge_vocabulary",
    requires = ["create_tool_groups"],
);

extension_sql_file!(
    "../39-hinge.sql",
    name = "create_hinge",
    requires = ["create_edge_vocabulary"],
);

extension_sql_file!(
    "../40-rte.sql",
    name = "create_rte",
    requires = ["create_hinge"],
);

extension_sql_file!(
    "../41-memory-tend.sql",
    name = "create_memory_tend",
    requires = ["create_rte"],
);

// 42-route-on — the route_on primitive: re-authors work_item_advance to replace
// the hardcoded code-pr loop-backs (cv6/cv11) with one data-driven conditional /
// loop-back evaluator (when/unless -> goto, with a counted loop guard). Tail of
// the chain (pure re-author of work_item_advance).
extension_sql_file!(
    "../42-route-on.sql",
    name = "create_route_on",
    requires = ["create_memory_tend"],
);

// 43-request-research — primitive B (the analyze->gather feedback loop) as core:
// request_research parks a targeted, deduped, approve-gated research proposal that
// drains into the pool; the gather-feedback tool_group is the opt-in per-stage scope.
// The tool-side dual of route_on (42 loops within a run; this feeds the pool for a
// later cycle). Composes existing core (work_item_create, the reflect queue, tool_groups).
extension_sql_file!(
    "../43-request-research.sql",
    name = "create_request_research",
    requires = ["create_route_on"],
);

// 44-graph-organize — the ORGANIZE keystone: corpus -> graph, time-aware. Adds the
// missing node-maker (graph_node), supersession (graph_supersede + SUPERSEDES), an
// opt-in fresh_only on graph_recall, and the graph-organize/graph-read tool_groups so
// a deliberate gather->organize stage can build typed, freshness-stamped knowledge.
extension_sql_file!(
    "../44-graph-organize.sql",
    name = "create_graph_organize",
    requires = ["create_request_research"],
);

// ---------------------------------------------------------------------------
// Diagnostic SQL functions
// ---------------------------------------------------------------------------

/// Build version of the extension. First sanity check from step 1.
#[pg_extern]
fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// pgrx version this extension was compiled against.
#[pg_extern]
fn pgrx_version() -> &'static str {
    "0.18.0"
}

/// Enqueue a work item. Returns the new row's id.
///
/// `kind` is a free-form string the worker uses to dispatch (e.g.
/// "echo", "embed", "chat"). `provider` is the friendly id of a
/// provider in the registry (e.g. "ollama", "lm_studio", "opencode_go",
/// or "echo" for the stub). `payload` is jsonb passed to the provider.
#[pg_extern]
fn enqueue(kind: &str, provider: &str, payload: pgrx::JsonB) -> i64 {
    Spi::get_one_with_args::<i64>(
        "INSERT INTO stewards.work_queue (kind, provider, payload) \
         VALUES ($1, $2, $3) RETURNING id",
        &[kind.into(), provider.into(), payload.into()],
    )
    .expect("INSERT returned a row")
    .expect("id is non-null")
}

/// List the providers the bgworker loaded from env at startup.
/// Returns one row per provider; **never returns the API key**.
#[pg_extern]
fn providers_loaded() -> TableIterator<
    'static,
    (
        name!(name, String),
        name!(base_url, String),
        name!(default_model, String),
        name!(kind, String),
        name!(has_api_key, bool),
    ),
> {
    let providers = PROVIDER_REGISTRY
        .get()
        .map(|r| r.summary())
        .unwrap_or_default();

    TableIterator::new(providers.into_iter().map(|p| {
        (p.name, p.base_url, p.default_model, p.kind, p.has_api_key)
    }))
}

// ---------------------------------------------------------------------------
// Module-split breadcrumbs (Phase 3c.3.6, 2026-05-08):
//   - Provider registry types + ResolverConfig → providers.rs
//   - WorkOutcome enum → types.rs
//   - _PG_init + bgworker tick loop + dispatch/embed/chat → bgworker.rs
//   - resolve_ref + tool_dispatch + exec_* helpers → tools.rs
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Tests (run with `cargo pgrx test`)
// ---------------------------------------------------------------------------

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn version_returns_pkg_version() {
        let got = Spi::get_one::<&str>("SELECT stewards.version()")
            .expect("SPI succeeded")
            .expect("non-null result");
        assert_eq!(got, "0.1.0");
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // For `cargo pgrx test` the bgworker needs to be preloaded.
        vec!["shared_preload_libraries='pg_ai_stewards'"]
    }
}
