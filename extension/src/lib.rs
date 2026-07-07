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
mod gcp_sa;
mod providers;
mod schema;
mod tools;
mod types;
mod yaml;
use providers::{Provider, ProviderRegistry, ProviderSummary, PROVIDER_REGISTRY};

::pgrx::pg_module_magic!();


// =====================================================================
// The install chain — consolidated into themed VOLUME files.
//
// (feat/lightening, 2026-07-07) The historical 109-file chain
// (00-config.sql … 107-lifeless-core.sql, incl. 15a/15b) was consolidated
// into 28 contiguous themed volumes. Each volume is a BYTE-PRESERVING
// concatenation of the original files in pgrx topological install order,
// separated only by `-- ===== [was <file>] =====` banners — no semantic
// edits. extension/verify-consolidation.py proves the move byte-for-byte
// against the pre-consolidation git blobs; extension/consolidation-map.txt
// records old-file -> volume (read by verify-consolidation.py and by
// scripts/migrate.sh to adopt an old-name ledger onto the volumes).
//
// The volumes form a LINEAR requires chain (each requires the previous).
// Because every volume is a contiguous segment of a valid topological
// linearization of the old requires DAG, a linear chain reproduces the
// exact install order — including the two non-numeric moves the old DAG
// forced: 36-judge-local-routing installs right after 16-subagents (its
// only dep), and 35-research-doc-construction installs dead last (a DAG
// sink). Both are now baked into their volumes at fixed textual positions.
//
// The six future-PACK files (14-fanout-brainstorm, 83-code-graph, 87-lab,
// 98-crawler, 99-route-intake, 101-lab-dispatch) stay as their own
// single-file volumes so the D2A pack-extraction option remains clean.
//
// Idempotency is unchanged: every block uses CREATE OR REPLACE, ADD COLUMN
// IF NOT EXISTS, ON CONFLICT DO UPDATE, etc.
// =====================================================================

// v00-foundations.sql — was: 00-config, 01-graph, 02-workstreams
extension_sql_file!(
    "../v00-foundations.sql",
    name = "create_v00_foundations",
    requires = ["create_doc_show"],
);

// v01-work-substrate.sql — was: 03-watchman, 04-work-items, 05-mcp-bridge, 06-cost, 07-steward
extension_sql_file!(
    "../v01-work-substrate.sql",
    name = "create_v01_work_substrate",
    requires = ["create_v00_foundations"],
);

// v02-governance.sql — was: 08-gates, 09-intents-covenants, 10-sabbath-atonement, 11-trust, 12-council, 13-research-pipelines
extension_sql_file!(
    "../v02-governance.sql",
    name = "create_v02_governance",
    requires = ["create_v01_work_substrate"],
);

// v03-fanout-brainstorm.sql — was: 14-fanout-brainstorm
extension_sql_file!(
    "../v03-fanout-brainstorm.sql",
    name = "create_v03_fanout_brainstorm",
    requires = ["create_v02_governance"],
);

// v04-context-engine.sql — was: 15a-context-engrams, 15b-context-surface
extension_sql_file!(
    "../v04-context-engine.sql",
    name = "create_v04_context_engine",
    requires = ["create_v03_fanout_brainstorm"],
);

// v05-subagents.sql — was: 16-subagents, 36-judge-local-routing
extension_sql_file!(
    "../v05-subagents.sql",
    name = "create_v05_subagents",
    requires = ["create_v04_context_engine"],
);

// v06-agents-runtime.sql — was: 17-personas, 18-scheduler, 19-models, 20-coder, 21-compact-context, 22-reflect-steward, 23-reflect-watchman
extension_sql_file!(
    "../v06-agents-runtime.sql",
    name = "create_v06_agents_runtime",
    requires = ["create_v05_subagents"],
);

// v07-agent-surface.sql — was: 24-skills, 25-corpus, 26-productivity, 27-context-search, 28-guard-autoresume, 29-intent-private-routing, 30-tool-primers
extension_sql_file!(
    "../v07-agent-surface.sql",
    name = "create_v07_agent_surface",
    requires = ["create_v06_agents_runtime"],
);

// v08-aliases-docbuilder.sql — was: 31-model-aliases, 32-alias-failover, 33-page-in, 34-doc-builder
extension_sql_file!(
    "../v08-aliases-docbuilder.sql",
    name = "create_v08_aliases_docbuilder",
    requires = ["create_v07_agent_surface"],
);

// v09-routing-and-hinge.sql — was: 37-tool-groups, 38-edge-vocabulary, 39-hinge, 40-rte, 41-memory-tend, 42-route-on, 43-request-research, 44-graph-organize
extension_sql_file!(
    "../v09-routing-and-hinge.sql",
    name = "create_v09_routing_and_hinge",
    requires = ["create_v08_aliases_docbuilder"],
);

// v10-chat.sql — was: 45-work-item-chat, 46-chat-tasks, 47-multimodal, 48-chat-attachments, 49-doc-extract, 50-doc-build, 51-rich-chat-hardening, 52-session-scoped-tools, 53-explore-repos
extension_sql_file!(
    "../v10-chat.sql",
    name = "create_v10_chat",
    requires = ["create_v09_routing_and_hinge"],
);

// v11-loreworks.sql — was: 54-loreworks, 55-loreworks-build, 56-trajectory-critic, 57-loreworks-chat, 58-world-edge-audit, 59-self-improvement, 60-chat-model-pin, 61-world-build-worklist, 62-orientation, 63-orient-survey, 64-auto-critique
extension_sql_file!(
    "../v11-loreworks.sql",
    name = "create_v11_loreworks",
    requires = ["create_v10_chat"],
);

// v12-rigor.sql — was: 65-rigor-mode, 66-rigor-verify, 67-rigor-force-final, 68-model-fallback-hardening
extension_sql_file!(
    "../v12-rigor.sql",
    name = "create_v12_rigor",
    requires = ["create_v11_loreworks"],
);

// v13-a2a.sql — was: 69-a2a-engine, 70-hinge-decouple
extension_sql_file!(
    "../v13-a2a.sql",
    name = "create_v13_a2a",
    requires = ["create_v12_rigor"],
);

// v14-search-and-disclosure.sql — was: 71-hybrid-rrf, 72-hybrid-rrf-everywhere, 73-brain-hybrid, 74-north-star, 75-wire-brain-hybrid, 76-wire-engram-search, 77-tool-shelf, 78-yt-slide-frames, 79-bineval, 80-rest, 81-spiral-oracle
extension_sql_file!(
    "../v14-search-and-disclosure.sql",
    name = "create_v14_search_and_disclosure",
    requires = ["create_v13_a2a"],
);

// v15-world-graph.sql — was: 82-world-graph
extension_sql_file!(
    "../v15-world-graph.sql",
    name = "create_v15_world_graph",
    requires = ["create_v14_search_and_disclosure"],
);

// v16-code-graph.sql — was: 83-code-graph
extension_sql_file!(
    "../v16-code-graph.sql",
    name = "create_v16_code_graph",
    requires = ["create_v15_world_graph"],
);

// v17-gates-worldchat.sql — was: 84-tool-effect-gate, 85-world-chat, 86-sticky-agent-family
extension_sql_file!(
    "../v17-gates-worldchat.sql",
    name = "create_v17_gates_worldchat",
    requires = ["create_v16_code_graph"],
);

// v18-lab.sql — was: 87-lab
extension_sql_file!(
    "../v18-lab.sql",
    name = "create_v18_lab",
    requires = ["create_v17_gates_worldchat"],
);

// v19-platform.sql — was: 88-credentials, 89-attention, 90-harness-executor, 91-core-compat
extension_sql_file!(
    "../v19-platform.sql",
    name = "create_v19_platform",
    requires = ["create_v18_lab"],
);

// v20-wiki.sql — was: 92-wiki, 93-recall, 94-wiki-curator, 95-model-role-toggles, 96-wiki-assets, 97-world-wiki-bridge
extension_sql_file!(
    "../v20-wiki.sql",
    name = "create_v20_wiki",
    requires = ["create_v19_platform"],
);

// v21-crawler.sql — was: 98-crawler
extension_sql_file!(
    "../v21-crawler.sql",
    name = "create_v21_crawler",
    requires = ["create_v20_wiki"],
);

// v22-route-intake.sql — was: 99-route-intake
extension_sql_file!(
    "../v22-route-intake.sql",
    name = "create_v22_route_intake",
    requires = ["create_v21_crawler"],
);

// v23-schedule-chat.sql — was: 100-schedule-chat
extension_sql_file!(
    "../v23-schedule-chat.sql",
    name = "create_v23_schedule_chat",
    requires = ["create_v22_route_intake"],
);

// v24-lab-dispatch.sql — was: 101-lab-dispatch
extension_sql_file!(
    "../v24-lab-dispatch.sql",
    name = "create_v24_lab_dispatch",
    requires = ["create_v23_schedule_chat"],
);

// v25-war-game.sql — was: 102-war-game, 103-abort-conditions
extension_sql_file!(
    "../v25-war-game.sql",
    name = "create_v25_war_game",
    requires = ["create_v24_lab_dispatch"],
);

// v26-knowledge.sql — was: 104-observations, 105-seams, 106-schedule-visibility
extension_sql_file!(
    "../v26-knowledge.sql",
    name = "create_v26_knowledge",
    requires = ["create_v25_war_game"],
);

// v27-lifeless-core.sql — was: 107-lifeless-core, 35-research-doc-construction
extension_sql_file!(
    "../v27-lifeless-core.sql",
    name = "create_v27_lifeless_core",
    requires = ["create_v26_knowledge"],
);

// v28-files-interface.sql — NEW (feat/files-interface): ingest-by-drop +
// the knowledge projection tree, the two ratified files-interface
// increments (.spec/proposals/files-as-interface-db-as-engine.md,
// Layer 3 / lightening item 6). Companion bridge loops:
// cmd/stewards-mcp/dropwatcher.go + projector.go.
extension_sql_file!(
    "../v28-files-interface.sql",
    name = "create_v28_files_interface",
    requires = ["create_v27_lifeless_core"],
);

// v29-normalize.sql — NEW (feat/full-treatment): the NORMALIZE primitive
// (typed doc_facts + evidence_items with missing-as-first-class + the
// deterministic parser floor + on-demand structural doc_sections) and
// the file-drop honesty patch (status=error rings needs_attention,
// deduped per path). Panel mandate:
// .spec/wargames/2026-07-07-pipelines-skeleton/SYNTHESIS.md.
extension_sql_file!(
    "../v29-normalize.sql",
    name = "create_v29_normalize",
    requires = ["create_v28_files_interface"],
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

/// List the providers the substrate can dispatch to: the env registry the
/// postmaster loaded at boot UNIONED with the 88 credential overlay
/// (wizard-added providers in stewards.config + stewards.credentials — a DB
/// row wins on name collision, so a rotated key reads as configured). Alias
/// resolution gates on this via provider_is_loaded(), which is what makes a
/// wizard-added provider live with no restart.
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
    let providers = crate::providers::merged_summaries_spi();

    TableIterator::new(providers.into_iter().map(|p| {
        (p.name, p.base_url, p.default_model, p.kind, p.has_api_key)
    }))
}

/// The honest pg-side check behind the wizard's "is this key live HERE?"
/// badge: fetch the named credential's ciphertext and attempt the same
/// AES-256-GCM decryption dispatch will do. Returns 'ok' or the error text —
/// NEVER the plaintext (which is dropped on the floor here). The Go cockpit
/// verifying a key proves the key works against the provider; only this
/// proves the Postgres process can decrypt it (same STEWARDS_MASTER_KEY).
#[pg_extern]
fn credential_decrypt_check(name: &str) -> String {
    let ct: Option<Vec<u8>> = match Spi::get_one_with_args::<Vec<u8>>(
        "SELECT secret_encrypted FROM stewards.credentials WHERE name = $1",
        &[name.into()],
    ) {
        Ok(v) => v,
        Err(_) => None, // no row (get_one errors on zero rows) or pre-88 chain
    };
    let Some(ct) = ct else {
        return format!("no credential named '{}'", name);
    };
    match crate::providers::decrypt_secret(&ct) {
        Ok(_plaintext_dropped) => "ok".to_string(),
        Err(e) => e,
    }
}

/// Synchronously embed `text` and return the raw vector (the caller casts
/// `::vector`). This is the query-time embedding primitive the substrate lacked:
/// `doc_search`/`pool_search` are full-text and `doc_similar` uses *precomputed*
/// edges, so nothing could embed an arbitrary query at search time. With this, a
/// hybrid full-text + semantic search becomes pure SQL over any embedded table —
/// realized in 71 (`world_entity_hybrid`, `doc_search_hybrid`) as real
/// Reciprocal Rank Fusion (RRF, Σ 1/(k+rank), k=60).
///
/// Resolution: `provider` (else `stewards.config 'embed_provider'`), `model`
/// (else the provider's default), `dimensions` (default 768 = nomic; pass 1536
/// for Vertex gemini-embedding). `dimensions` is REQUESTED of the provider (sent
/// as the OpenAI-compat `dimensions` field, which MRL models honor) — not merely
/// validated — so one MRL model can serve multiple widths. The provider is
/// resolved in THIS backend,
/// preferring the postmaster-inherited `PROVIDER_REGISTRY` and falling back to
/// parsing env on demand (covers a not-preloaded backend).
///
/// **Latency:** blocks the backend for one embeddings round-trip (~100-500ms, up
/// to 120s on a cold local model). Fine for interactive search; bulk embedding
/// keeps the async work-queue path (`stewards.enqueue('embed', ...)`).
#[pg_extern]
fn embed_query(
    text: &str,
    provider: default!(Option<&str>, "NULL"),
    model: default!(Option<&str>, "NULL"),
    dimensions: default!(i32, 768),
) -> Vec<f32> {
    match embed_query_impl(text, provider, model, dimensions) {
        Ok(v) => v,
        Err(e) => error!("embed_query: {}", e),
    }
}

/// Resolve a provider by name in a backend: the 88 credential overlay first
/// (a wizard-added provider or rotated key must win), then the registry the
/// postmaster set in `_PG_init` (inherited via fork), else parse env on
/// demand and memoize it for this backend.
fn resolve_embed_provider(name: &str) -> Result<crate::providers::Provider, String> {
    // Backend context — SPI is already legal here (we're inside a pg_extern).
    match crate::providers::merged_provider_spi(name) {
        Ok(Some(p)) => return Ok(p),
        Ok(None) => {}
        Err(e) => return Err(e),
    }
    if let Some(reg) = PROVIDER_REGISTRY.get() {
        if let Some(p) = reg.providers.iter().find(|p| p.name == name) {
            return Ok(p.clone());
        }
    }
    static FALLBACK: std::sync::OnceLock<crate::providers::ProviderRegistry> =
        std::sync::OnceLock::new();
    let reg = FALLBACK.get_or_init(crate::providers::ProviderRegistry::from_env);
    reg.providers
        .iter()
        .find(|p| p.name == name)
        .cloned()
        .ok_or_else(|| format!("unknown embed provider: {}", name))
}

fn embed_query_impl(
    text: &str,
    provider: Option<&str>,
    model: Option<&str>,
    dimensions: i32,
) -> Result<Vec<f32>, String> {
    let provider_name: String = match provider {
        Some(p) if !p.is_empty() => p.to_string(),
        _ => Spi::get_one::<String>("SELECT stewards.config_get_text('embed_provider', NULL)")
            .map_err(|e| format!("read config 'embed_provider': {}", e))?
            .ok_or_else(|| {
                "no embed provider: pass a provider arg or set stewards.config 'embed_provider'"
                    .to_string()
            })?,
    };
    let prov = resolve_embed_provider(&provider_name)?;
    let model_name: String = match model {
        Some(m) if !m.is_empty() => m.to_string(),
        _ => prov.default_model.clone(),
    };
    let dims = if dimensions > 0 { dimensions } else { 768 };
    crate::bgworker::embed_one(&prov, text, &model_name, dims)
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
// (audit-synthesis-2026-07 §II: a stale `mod tests` hardcoding
// `stewards.version()` == "0.1.0" lived here — dead code, never run by CI
// (no `cargo pgrx test` step exists in .github/workflows/ci.yml), and stale
// against Cargo.toml's actual version. Deleted rather than bumped in place —
// a hardcoded-version assertion drifts every release; if pg_test coverage of
// `version()` is wanted again, assert it equals `env!("CARGO_PKG_VERSION")`,
// not a literal.)

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // For `cargo pgrx test` the bgworker needs to be preloaded.
        vec!["shared_preload_libraries='pg_ai_stewards'"]
    }
}
