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

// 45-work-item-chat — "chat with a work item": a read-only retrieval agent +
// dispatch_chat_turn (persistent chat sessions over chat_enqueue) — the backend
// for Stewdio's chat panel (.spec/proposals/stewards-studio.md).
extension_sql_file!(
    "../45-work-item-chat.sql",
    name = "create_work_item_chat",
    requires = ["create_graph_organize"],
);

// chat delegation: the chat can spawn a sub work_item (Delegate mode), linked
// back to the work item it's grounded in (.spec/proposals/stewards-studio.md).
extension_sql_file!(
    "../46-chat-tasks.sql",
    name = "create_chat_tasks",
    requires = ["create_work_item_chat"],
);

// rich documents in chat, P1: the substrate carries an image — content_parts
// jsonb on messages + compose_messages passthrough + a `vision` alias on
// dispatch_chat_turn (.spec/proposals/rich-docs-in-chat.md). Re-authors
// compose_messages (15b), page_in_cap (33), dispatch_chat_turn (45).
// 47 RE-AUTHORS page_in_cap (33), compose_messages (15b), and dispatch_chat_turn
// (45) to add the multimodal array guard. cargo-pgrx topologically sorts these
// extension_sql_file! entries by `requires`; for 47's versions to WIN, 47 must
// sort AFTER every file that also authors those functions. create_chat_tasks
// (46→45) covers dispatch_chat_turn, but create_page_in (33) and
// create_context_surface (15b) must be listed explicitly — without them the sort
// is under-constrained and a rebuild can silently revert page_in_cap /
// compose_messages to their pre-multimodal versions (caught by virgin-smoke OK
// 36 when adding 49 perturbed the sort, 2026-06-24).
extension_sql_file!(
    "../47-multimodal.sql",
    name = "create_multimodal",
    requires = ["create_chat_tasks", "create_page_in", "create_context_surface"],
);

// rich documents in chat, P2: durable session-scoped attachments — bytea +
// chat_attachment_parts() assembles the 47 content_parts a vision model sees
// (.spec/proposals/rich-docs-in-chat.md).
extension_sql_file!(
    "../48-chat-attachments.sql",
    name = "create_chat_attachments",
    requires = ["create_multimodal"],
);

// rich documents in chat, P3: document extraction surface — parent-linked page
// images + scan verdict columns on chat_attachments, chat_attachment_parts
// re-authored for the pixel overlay + doc_extract nudge, the doc-extract MCP
// server, and the doc_extract grant. The hardened extraction itself runs in the
// bridge's doc-extract-mcp + the doc-extract sandbox image
// (.spec/proposals/doc-extract-sandbox.md).
extension_sql_file!(
    "../49-doc-extract.sql",
    name = "create_doc_extract",
    requires = ["create_chat_attachments"],
);

// rich chat + artifacts, Arc B: doc-build — generate documents (pdf/xlsx/pptx/
// docx/zip) in the coder sandbox (now doc-toolchain-equipped) and export them as
// downloadable artifacts. The doc-build pipeline + the coder_export_artifact
// grant. (.spec/proposals/rich-chat-and-artifacts.md)
extension_sql_file!(
    "../50-doc-build.sql",
    name = "create_doc_build",
    requires = ["create_doc_extract"],
);

// 51: doc-build artifact-exists gate (an empty build must fail, not pose as
// success) + chat→brainstorm grant. From the doc-build e2e findings.
extension_sql_file!(
    "../51-rich-chat-hardening.sql",
    name = "create_rich_chat_hardening",
    requires = ["create_doc_build"],
);

// 52: session-scoped tools — mark generate_image / coder_export_artifact
// `inject_session` so tools.rs::exec_one_tool overrides any model-supplied
// session_id with the authoritative dispatch session. The dispatcher is the
// oracle for which conversation an artifact attaches to, not the model.
extension_sql_file!(
    "../52-session-scoped-tools.sql",
    name = "create_session_scoped_tools",
    requires = ["create_rich_chat_hardening"],
);

// 53: explore public repos (RC-1) — grant research_codebase to work-item-chat
// so the chat can clone + read a PUBLIC repo in a read-only sandbox (no DB
// embedding). Pairs with the public-repo clone lane in cmd/coder-mcp/sandbox.
extension_sql_file!(
    "../53-explore-repos.sql",
    name = "create_explore_repos",
    requires = ["create_session_scoped_tools"],
);

// 54: Loreworks engine — worlds + world_entities + world_edges (the relational
// lore graph) + world_upsert/entity_upsert/edge_upsert/show/graph/entity_search.
// A World = a named canon (project corpus) + an extracted entity/relationship
// knowledge graph. Generic core; private worlds set is_private (local-only).
extension_sql_file!(
    "../54-loreworks.sql",
    name = "create_loreworks",
    requires = ["create_explore_repos"],
);

// 55: world-build tools + agent — the two sql_fn tools a model calls to
// populate a world from its canon (world_entity_upsert / world_edge_upsert) +
// world_show/world_entity_search read tools + the world-build agent family and
// its allow-list. "Build a world" = one dispatch to this agent.
extension_sql_file!(
    "../55-loreworks-build.sql",
    name = "create_loreworks_build",
    requires = ["create_loreworks"],
);

// 56: Glass-Box trajectory evaluation (Google SDLC) — assemble_trajectory + the
// generic trajectory-critic judge + critique_trajectory; AND the Loreworks
// application: world_edge_list/world_edge_prune tools + the world-critic agent
// that grounds a world's edges against its canon and prunes misreads (B's fix).
extension_sql_file!(
    "../56-trajectory-critic.sql",
    name = "create_trajectory_critic",
    requires = ["create_loreworks_build"],
);

// 57: Loreworks C/G — hybrid lore search (world_entity_hybrid = the embed_query
// semantic leg the 54 comment promised) + the lore tools (lore_search/
// lore_entity/lore_neighbors) + the read-only loremaster agent + lore_inject
// for grounding a persona in a world room. (57's fusion was weighted-linear;
// 71 upgrades world_entity_hybrid to real equal-weight RRF.)
extension_sql_file!(
    "../57-loreworks-chat.sql",
    name = "create_loreworks_chat",
    requires = ["create_trajectory_critic"],
);

// 58: the deterministic floor under the world-critic — a lore verb vocabulary
// (world_rel_kinds, kind-typed endpoints + inverses) + world_edge_audit that
// flags unknown-verb / endpoint-kind-violation (the "Dwarves home_of Shire"
// misread) / no-evidence with perfect recall. The world-critic now leads with it.
extension_sql_file!(
    "../58-world-edge-audit.sql",
    name = "create_world_edge_audit",
    requires = ["create_loreworks_chat"],
);

// 59: the self-improvement loop (dominion_in_council, ratified 2026-06-25) — the
// trajectory critic's verdicts → recurring failure patterns → the agent-improver
// proposes ONE scoped guidance clause → a DETERMINISTIC GATE (eval-gaming guard:
// judges/critics/gates/base-prompts escalate to the human; only short additive
// guidance to a worker agent auto-applies, trailed + reversible).
extension_sql_file!(
    "../59-self-improvement.sql",
    name = "create_self_improvement",
    requires = ["create_world_edge_audit"],
);

extension_sql_file!(
    "../60-chat-model-pin.sql",
    name = "create_chat_model_pin",
    requires = ["create_self_improvement"],
);

extension_sql_file!(
    "../61-world-build-worklist.sql",
    name = "create_world_build_worklist",
    requires = ["create_chat_model_pin"],
);

extension_sql_file!(
    "../62-orientation.sql",
    name = "create_orientation",
    requires = ["create_world_build_worklist"],
);

extension_sql_file!(
    "../63-orient-survey.sql",
    name = "create_orient_survey",
    requires = ["create_orientation"],
);

extension_sql_file!(
    "../64-auto-critique.sql",
    name = "create_auto_critique",
    requires = ["create_orient_survey"],
);

extension_sql_file!(
    "../65-rigor-mode.sql",
    name = "create_rigor_mode",
    requires = ["create_auto_critique"],
);

extension_sql_file!(
    "../66-rigor-verify.sql",
    name = "create_rigor_verify",
    requires = ["create_rigor_mode"],
);

extension_sql_file!(
    "../67-rigor-force-final.sql",
    name = "create_rigor_force_final",
    requires = ["create_rigor_verify"],
);

extension_sql_file!(
    "../68-model-fallback-hardening.sql",
    name = "create_model_fallback_hardening",
    requires = ["create_rigor_force_final"],
);

extension_sql_file!(
    "../69-a2a-engine.sql",
    name = "create_a2a_engine",
    requires = ["create_model_fallback_hardening"],
);

extension_sql_file!(
    "../70-hinge-decouple.sql",
    name = "create_hinge_decouple",
    requires = ["create_a2a_engine"],
);

// 71: make hybrid search REAL Reciprocal Rank Fusion. Replaces 57's
// weighted-linear world_entity_hybrid (0.45·lex + 0.55·sem) with canonical
// equal-weight RRF (Σ 1/(k+rank), k=60), and adds doc_search_hybrid so the doc
// corpus finally has a semantic leg (docs already carry a vector(768)
// embedding) — repointing the agent-facing doc_search tool to it. The bare
// doc_search FTS function stays as the lexical primitive. "RRF" now matches
// the SQL.
extension_sql_file!(
    "../71-hybrid-rrf.sql",
    name = "create_hybrid_rrf",
    requires = ["create_hinge_decouple"],
);

// 72: extend 71's real-RRF treatment to EVERY remaining doc-corpus surface
// (pool_search and the engram search were single-leg), and add an opt-in 1-hop
// graph-expand hop to all four hybrid surfaces. The engram FTS leg is a genuine
// schema change: a GENERATED tsvector + GIN index on engram_embeddings (was
// vector-only). pool_search/search_engrams_hybrid are authored once at their
// final signature (with p_expand); doc_search_hybrid + world_entity_hybrid gain
// p_expand via the drop-then-create idiom (cf. 32's pick_alias_member).
extension_sql_file!(
    "../72-hybrid-rrf-everywhere.sql",
    name = "create_hybrid_rrf_everywhere",
    requires = ["create_hybrid_rrf"],
);

// 73: the last doc-corpus surface to get real RRF — the personal brain.
// brain_entries already carries BOTH a GENERATED body_tsv (+GIN) and an
// embedding vector(768) (+HNSW), so this is zero schema change: it only
// fuses the existing brain_search_text (FTS) and brain_search_vec (vector)
// legs into stewards.brain_search_hybrid via equal-weight RRF (k=60). The
// query embedding is a PARAMETER (mirroring brain_search_vec / 72's
// search_engrams_hybrid; NULL ⇒ FTS-only fallback). No graph-expand (brain
// entries are not graph nodes); MCP wiring deferred (query-side embed is a
// Go-layer change, exactly like 72 left search_engrams_hybrid's Go wiring).
extension_sql_file!(
    "../73-brain-hybrid.sql",
    name = "create_brain_hybrid",
    requires = ["create_hybrid_rrf_everywhere"],
);

// 74: the North Star — the substrate's Intent (step 1), on every call. Gives
// the engine the one piece of the creation cycle it ran without: the named
// *why*. render_north_star() composes a short standing block from the
// operator-owned north_star.* config (generic real default in the core; an
// operator names their own; an empty why opts out). compose_system_prompt is
// re-authored (later-file-wins over 09) to prepend it FIRST and echo it last,
// with directions that re-root the substrate's existing covenant behaviors so
// the why is load-bearing — the tie-breaker when values conflict.
extension_sql_file!(
    "../74-north-star.sql",
    name = "create_north_star",
    requires = ["create_brain_hybrid"],
);

// 75: wire the AGENT-FACING brain search to 73's brain_search_hybrid. 73 built
// the hybrid fn but left the tool_def 'brain_search_text' dispatching (sql_fn
// brain_search_text_tool) to the FTS-only brain_search_text. This repoints that
// wrapper — exactly as 71 §3 repointed doc_search_tool — to embed the query
// INLINE via the embed_query pg_extern (EXCEPTION → NULL ⇒ FTS-only fallback)
// and call brain_search_hybrid. It is a clean SQL swap, NOT the Go-layer change
// 73's header expected: the brain tool is a sql_fn (unlike the engram search,
// whose wrapper is Go), and embed_query is a synchronous pg_extern callable in
// SQL. The documented brain_search_semantic, finally real. The engram search
// has no agent-facing tool in this repo; 75 flagged that gap, and 76 fills it.
extension_sql_file!(
    "../75-wire-brain-hybrid.sql",
    name = "create_brain_search_wire",
    requires = ["create_north_star"],
);

// 76: the agent-facing ENGRAM search — the twin of 75's brain wiring. 72 built
// search_engrams_hybrid but no agent could reach it (no tool_def, no Go handler;
// unlike the brain search, the engram search had no agent surface at all). This
// adds engram_search_tool (text-in → embed_query inline → search_engrams_hybrid,
// same FTS-only-degrade guard), the engram_search tool_def, and a grant that
// MIRRORS brain_search_text's families exactly (only stewards-explore needs an
// explicit allow; the rest reach it by the resolver's default-allow — no
// broadening). 75 flagged this gap; 76 fills it.
extension_sql_file!(
    "../76-wire-engram-search.sql",
    name = "create_engram_search_wire",
    requires = ["create_brain_search_wire"],
);

// 77: the Tool Shelf — progressive disclosure for TOOLS (the dynamic half of
// 37's static tool-group scoping; the tool twin of 24's skill shelf). When
// enabled for a family (master config tool_shelf_enabled AND agents.
// tool_shelf_enabled), compose_tools/compose_system_prompt/dry_run_chat fold
// every tool to a one-line <folded_tools> catalog and ship only reveal_tool/
// pin_tool/unpin_tool + the schemas the agent reveals on demand. A cooldown
// auto-refolds idle tools (inferred from messages.tool_calls); pin exempts a
// tool. Default OFF ⇒ byte-for-byte pre-77 (gated branches + gated-off levers).
// GREENLIT by the P0.5 probe (both local models opened the right tools).
extension_sql_file!(
    "../77-tool-shelf.sql",
    name = "create_tool_shelf",
    requires = ["create_engram_search_wire"],
);

// 78: yt slide frames — captioned vision frames (Part B of yt-slide-frames.md).
// Teach the EXISTING vision mechanism (47 multimodal + 49 doc-extract page
// images) to read a slide frame ALONGSIDE the transcript narration spoken over
// it: chat_attachments gains a `caption`, chat_attachment_parts (re-authored,
// later-file-wins over 49) emits the caption as a text part right before the
// image, and align_slide_captions(frames, cues) is the pure frame↔cue alignment
// the digester reads. The frame INGESTION (reading the /yt volume) is operator
// glue in examples/yt-transcripts.sql, like import_yt_transcript. create_doc_extract
// is listed EXPLICITLY (not just transitively via create_tool_shelf): 78
// re-authors chat_attachment_parts, so it MUST sort after 49 for its version to
// win (the 2026-06-24 under-constrained-sort lesson — see 47's header). Flag-off:
// an image with no caption renders byte-identically to 49.
extension_sql_file!(
    "../78-yt-slide-frames.sql",
    name = "create_yt_slide_frames",
    requires = ["create_tool_shelf", "create_doc_extract"],
);

// 79: BINEVAL — force the trajectory-critic (56) to DECOMPOSE its verdict into
// binary yes/no answers via a submit_trajectory_verdict TOOL (the required args
// ARE the questions, so a weak model can't skip them) instead of free-text JSON.
// `committed` is one of the questions ⇒ the spiral becomes a verdict signal that
// flows to 59's agent-improver. Re-authors the trajectory-critic agent (UPDATE),
// so it requires create_trajectory_critic. ("Ask, Don't Judge", arXiv:2606.27226.)
extension_sql_file!(
    "../79-bineval.sql",
    name = "create_bineval",
    requires = ["create_yt_slide_frames", "create_trajectory_critic"],
);

// 80: the REST — every rest_every_n_steps assistant rounds (config, default 0=off)
// fold tools to a housekeeping set + inject a [REST] tidy-up nudge, then full tools
// resume. Re-authors chat_post_internal (later-file-wins over 67), so it MUST sort
// after create_rigor_force_final; force-final near the cap still takes precedence.
// Also carries the per-dispatch _sampling override (the qwen3.6-MoE repetition-loop
// fix: presence_penalty=1.5 / temp 0.6). Default OFF ⇒ pre-80 behavior.
extension_sql_file!(
    "../80-rest.sql",
    name = "create_rest",
    requires = ["create_bineval", "create_rigor_force_final"],
);

// 81: the spiral oracle — deterministic session_spiraled() + spiral_report() over
// stewards.messages (the over-gather-never-commit gauge for the uplift arc).
// Read-only; no behavior change. requires create_rest only for chain order.
extension_sql_file!(
    "../81-spiral-oracle.sql",
    name = "create_spiral_oracle",
    requires = ["create_rest"],
);

// 82: the world-graph — projects become an n-level hierarchy (parent_slug) with
// worlds as leaves (FK); cross_world_edges link entities across world/project
// boundaries; resolve_cross_service_http pairs HTTP producers/consumers across a
// project subtree on a normalized contract key (contract-as-node — the existing
// (world,kind,name) dedup IS the matcher); project_tree() is the picker. Uses the
// loreworks tables, so it requires create_loreworks. (world-graph-spec.md D1-D5.)
extension_sql_file!(
    "../82-world-graph.sql",
    name = "create_world_graph",
    requires = ["create_spiral_oracle", "create_loreworks"],
);

// 83: the code-graph ingest (D5) — lands a lodestar (github.com/cpuchip/lodestar)
// extraction into the world-graph. import_code_graph takes one world's {nodes,edges};
// import_lodestar_graph takes a whole {worlds,nodes,edges,cross_edges} and stores
// lodestar's already-computed cross-service edges directly in cross_world_edges
// (lodestar is the single deterministic extraction authority, no re-resolve in SQL).
// Reuses world_*_upsert + cross_world_edges, so it requires create_world_graph.
extension_sql_file!(
    "../83-code-graph.sql",
    name = "create_code_graph",
    requires = ["create_world_graph"],
);

// 84: the tool-effect gate (Hinge escalation ladder, Phase 1) — the missing
// TRIGGER. effect_class on tool_defs + tool_requires_confirmation(); the
// interceptor (tool_confirm_gate) that withholds a dangerous tool call and
// enqueues it to the 39-hinge queue as kind='tool-confirm'; the executor
// (tool_confirm_apply) that runs the STORED call verbatim on Michael's
// approval; the escalation_ladder table (Piece 3 data, no ask_up yet); and
// tool-confirm added to hinge_escalate_always_kinds. A PURE SAFETY ADD — can
// only add a pause, never remove one; everything escalates to Michael. Reuses
// 39-hinge + 69-a2a, so it requires both (via the 83→…→39 chain; a2a is 69).
extension_sql_file!(
    "../84-tool-effect-gate.sql",
    name = "create_tool_effect_gate",
    requires = ["create_code_graph", "create_hinge", "create_a2a_engine"],
);

// 85: cross-world lore neighbors + "Chat with this world". world_neighbors_tool
// is the cross-world SUPERSET of 57's lore_neighbors — its BFS frontier is
// world_edges (intra, origin-pinned) UNION 82's cross_world_edges (the service
// seam), so "what services does this market pain touch?" is finally answerable
// from the graph. Also grants the read-only lore tools to the cockpit chat agent
// (the "Chat with this world" button's follow-up turns dispatch as work-item-chat)
// and re-authors the loremaster prompt to name world_neighbors. create_loreworks_chat
// (57) + create_world_graph (82) are listed EXPLICITLY (not just transitively via
// the 84→83→82→…→57 chain): 85 re-authors the loremaster agent 57 owns AND reads
// cross_world_edges 82 owns, so it MUST sort after both for its UPDATE to win (the
// under-constrained-sort lesson — see 47/78's headers).
extension_sql_file!(
    "../85-world-chat.sql",
    name = "create_world_chat",
    requires = ["create_tool_effect_gate", "create_loreworks_chat", "create_world_graph"],
);

// 86 — session-sticky agent family: sessions.agent_family + the COALESCE lookup the
// chat handlers use, so a session opened AS a specialized agent (85's loremaster)
// stays that agent on follow-up turns. Also retires 85's bridge grants off
// work-item-chat, so it must sort after create_world_chat.
extension_sql_file!(
    "../86-sticky-agent-family.sql",
    name = "create_sticky_agent_family",
    requires = ["create_world_chat"],
);

// 87 — the Lab (audit #1): stewards.experiments/experiment_runs (declare-once
// A/B rows + the runs that fill them; dispatch is future work) and
// stewards.golden_cases/lab_regression_run() (a deterministic, synchronous
// regression suite over the substrate's own invariants — sql_assert /
// function_result case kinds today, LLM-dispatch kinds addable later without
// a schema change). A failed run alerts via 39-hinge (kind=lab-regression-
// failure) AND the always-queryable lab_regression_failures view. Ships the
// nightly-run MACHINERY (a 'lab-regression' pipeline + agent + tool) but NOT
// a scheduled_pipelines row (that stays operator data — see the file's own
// header). Also registers the two experiments from
// .spec/proposals/lab-and-wiki.md (Fable-hinge A/B; opposed-mandate panels).
// requires create_sticky_agent_family (86) — installs at the tail of the
// chain; reuses hinge_enqueue (39), pipelines (04), tool_defs/agents (schema.rs).
extension_sql_file!(
    "../87-lab.sql",
    name = "create_lab",
    requires = ["create_sticky_agent_family"],
);

// 88 — in-app credentials + daily budgets (#256): the encrypted credential store
// behind the setup wizard (stewards.credentials + credential_set/status/delete,
// never-echo-the-key), provider dials in stewards.config, the
// credential_providers view the Rust registry overlay reads at dispatch (a
// wizard-saved key goes live with no restart), and provider_spend_caps'
// refill_cadence='daily' (budget window = midnight UTC, computed not mutated).
extension_sql_file!(
    "../88-credentials.sql",
    name = "create_credentials",
    requires = ["create_lab"],
);

// 89 — the unified "Needs your answer" surface (ladder Phase 2, partial). Every
// human-blocking item — 39's Hinge queue, 84's tool-confirm gate, a paused
// pipeline stage (04 awaiting_review), a 69 A2A blocking question — unions
// into needs_attention (one shape), attention_count (the badge), and
// attention_answer (routes to the RIGHT existing resolver per kind:
// tool_confirm_verdict / hinge_record_verdict / a2a_answer /
// work_item_dispatch_stage; ask_record_answer is the one genuinely new
// resolver, for the free-text 'ask' kind). Also lands ask_up: a caller
// consults the NEXT enabled rung on 84's escalation_ladder via the existing
// dispatch_chat_turn enqueue (45) — no authority transfer; at/above the top
// enabled rung it parks a human 'ask' instead of stranding silently. Phase 2
// minimal per the proposal — no autopilot (Phase 4, council-gated).
extension_sql_file!(
    "../89-attention.sql",
    name = "create_attention",
    requires = ["create_credentials"],
);

// 90 — the harness executor (loom Phase 1, ratified 2026-07-03): harness_run
// tool_def (mcp_proxy → the bridge's own stdio surface; the Go handler execs
// `loom run --isolate`), the harness_runs dispatch ledger (session_id = the
// durable resume handle), the harness-pilot family (sole grant holder;
// work-item-chat carries an explicit deny), and the explicit-routing-only
// harness-review pipeline. Read-mostly: write-back + default routing are
// dominion_in_council gates, deliberately absent. Re-authors 52's
// inject_session trigger fn (adds harness_run) and tags 84's effect_class,
// both satisfied transitively via the 86→85→84→…→52 chain.
extension_sql_file!(
    "../90-harness-executor.sql",
    name = "create_harness_executor",
    requires = ["create_attention"],
);

// 91 — the compat contract's runtime guard (audit §IV Track 2, first step):
// stewards.assert_core_compat(range) raises if the installed core's extversion
// falls outside a downstream overlay's `-- requires-core: <range>` header,
// else returns true. Read-only / additive (two new functions, no re-authoring
// of anything upstream) — chain-order only, no functional dependency on 87-90.
extension_sql_file!(
    "../91-core-compat.sql",
    name = "create_core_compat",
    requires = ["create_harness_executor"],
);

// 95 — model-role toggles (2026-07-03 ux ease-of-life): a per-alias-member
// `enabled` column, pick_alias_member re-authored (32's FINAL 3-arg form +
// `AND a.enabled`) so both the dispatcher (31) and the runtime failover walk
// (32) skip a disabled member through the one function they already share,
// provider_is_local (mirrors activity.go's localProviders), and the
// model_aliases_set_local_enabled bulk switch the cockpit's "rest all local
// models" button (+ its inverse) wraps. Additive only — no re-author of
// work_item_dispatch_stage or steward_tick themselves.
extension_sql_file!(
    "../95-model-role-toggles.sql",
    name = "create_model_role_toggles",
    requires = ["create_wiki_curator"],
);

// 92 — the Wiki (WIKI-CORE, first of a 6-builder fleet; lab-and-wiki.md
// Part 2): wiki_pages/wiki_page_revisions (regenerable pages + their
// safety-net ledger), wiki_assets (schema only — the assets builder fills
// it), page_links (red links allowed) + page_sources (per-claim-cluster
// provenance), wikis/wiki_members (a wiki is a named scope over many
// pages). Functions: wiki_page_upsert (revision-aware), wiki_create,
// wiki_add_member, wiki_page_dedup_check{,_vec} (the >=0.90 lightning-tier
// dedup gate), wiki_merge_propose + a Hinge-applied trigger (mountain-tier
// merges are never auto). Also doc_pull_sources/doc_blind_spots — pure
// views mining a produced doc's producing work_item for what it actually
// retrieved vs. what it never touched in scope (Michael's "diff that
// against the full source and see blind spots" ask). Reuses hinge_enqueue
// (39), work_items.session_ids (04), docs (schema.rs), chat_attachments
// (48), embed_query (this file). Installs at the tail of the chain.
extension_sql_file!(
    "../92-wiki.sql",
    name = "create_wiki",
    requires = ["create_core_compat"],
);

// 94 — wiki-curator (6-builder wiki fleet, parallel with 92-wiki-core and
// 93-<sibling>, neither present in this worktree at authoring time — see
// 94-wiki-curator.sql's header for the full integration-point account).
// wiki-organize (gather->propose->deterministic-apply) + wiki-collect
// (plan->spawn_children fan-out, reused unmodified->aggregate, bridged
// into a real wiki page by two additive triggers) + the wiki_search lens.
// requires create_core_compat (91) ONLY because 92/93 are absent here —
// this MUST become ["create_wiki_core"] (or whatever 92 names itself) at
// fleet integration, once this file's wiki_* calls have a real callee.
extension_sql_file!(
    "../94-wiki-curator.sql",
    name = "create_wiki_curator",
    requires = ["create_recall"],
);

// 93 — the Atlas steal (study/ai/elastic-atlas-agent-memory.md takeaway 1):
// last_used_at/use_count on stewards.docs + stewards.engram_embeddings, a
// shared stewards.recall_boost(use_count, last_used_at, ...) scoring term
// (frequency boost + recency decay, config-driven via 00's dial surface),
// folded into doc_search_hybrid/pool_search_hybrid/search_engrams_hybrid
// (still STABLE/pure), plus `*_recall` wrapper fns that bump usage on
// actually-returned rows — the surfaces doc_search_tool/pool_search_tool/
// engram_search_tool now call. Built in a parallel worktree alongside
// WIKI-CORE's 92 (a wiki table + wiki_create/wiki_add_member/
// wiki_page_upsert, not present in THIS worktree) — requires the last entry
// found here (91); the integrator re-stitches this to require 92's
// registered name once both land, so the merged chain reads 91 -> 92 -> 93.
extension_sql_file!(
    "../93-recall.sql",
    name = "create_recall",
    requires = ["create_wiki"],
);

// 96 — WIKI-ASSETS (the 6-builder wiki fleet, 2026-07-03): PDF/web images as
// addressable, embeddable wiki assets. Populates stewards.wiki_assets (owned
// by WIKI-CORE, 92-wiki.sql — landed on main while this file was authored in
// an isolated worktree against a SKETCHED contract; reconciled here to the
// REAL schema: id bigserial, doc_id text (matches docs.id), bytes bytea +
// source_attachment_id bigint (the P2/P3 rich-docs convention — NOT a
// storage_path column, see 92-wiki.sql's header deviation #3), caption,
// page_no. requires create_model_role_toggles (95) — the true tail of the
// chain as merged, not create_core_compat (91), which was only correct while
// this worktree hadn't yet seen 92-95 land. See 96-wiki-assets.sql's header
// for the full contract + the markdown-embed convention.
extension_sql_file!(
    "../96-wiki-assets.sql",
    name = "create_wiki_assets",
    requires = ["create_model_role_toggles"],
);

// 98 — the purpose-crawler (ingestion fleet, 2026-07-03; spec
// .spec/proposals/ingestion-crawler-and-raw-to-wiki.md Part 1): the
// LLM-driven, guardrailed crawl. crawl_frontier (queue-as-rows, resumable),
// crawl_start/crawl_next/crawl_save/crawl_enqueue (model proposes, SQL
// disposes — page/byte/depth budgets + domain wall + dedup are a structural
// floor the model can only stay under), the single-stage 'crawl' pipeline
// looping via route_on (42), the 'crawler' agent family (exactly five
// tools), and crawl_status written into stage_results.crawl_status so the
// existing work-item card is the UI. The politeness half (robots.txt +
// per-domain rate floor) lives in cmd/fetch-md-mcp/politeness.go behind the
// enforce_robots param. requires create_wiki_assets (96) — the tail of the
// chain in THIS worktree; a parallel builder owns 97, and the integrator
// re-stitches this to require 97's registered name when both land.
extension_sql_file!(
    "../98-crawler.sql",
    name = "create_crawler",
    requires = ["create_wiki_assets"],
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
