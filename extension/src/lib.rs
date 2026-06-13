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
//   - Provider registry types + GospelEngineConfig → providers.rs
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
