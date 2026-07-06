//! Bgworker entry point, tick loop, and provider dispatch helpers.
//!
//! Owns:
//! - `_PG_init` — registers the background worker at postmaster startup
//! - `check_watchman_schedule` — 60s scheduler tick decisions
//! - `process_one_pending` — claim + run + write loop body
//! - `dispatch` / `embed` / `chat` — per-kind work_queue handlers
//!
//! Per the pgrx-rust skill, `_PG_init` works in any submodule — Postgres
//! finds the symbol at `dlopen` time via C linkage. plain `mod bgworker;`
//! in lib.rs is enough.
//!
//! Extracted from lib.rs as Phase 3c.3.6 v4 (2026-05-08).

use crate::providers::{
    http_client, ProviderRegistry, ResolverConfig, PROVIDER_REGISTRY, RESOLVER_CONFIG,
};
use crate::tools::{resolve_ref, tool_dispatch};
use crate::types::WorkOutcome;
use pgrx::bgworkers::*;
use pgrx::prelude::*;
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Bgworker registration
// ---------------------------------------------------------------------------

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    // Only register the bgworker when we are actually being preloaded
    // via shared_preload_libraries. Otherwise `CREATE EXTENSION` in a
    // database that doesn't preload us would fail.
    if unsafe { !pgrx::pg_sys::process_shared_preload_libraries_in_progress } {
        return;
    }

    // Parse provider registry once, in the postmaster. All backends
    // (and the bgworker) inherit it via fork() copy-on-write, so
    // `stewards.providers_loaded()` works from any psql session and
    // the worker doesn't need to re-parse.
    let registry = ProviderRegistry::from_env();
    pgrx::log!(
        "stewards: postmaster loaded {} provider(s) from env",
        registry.providers.len()
    );
    for p in &registry.providers {
        pgrx::log!(
            "stewards:   provider '{}' kind={} auth={} base_url={} model={} api_key={}",
            p.name,
            p.kind,
            p.auth_label(),
            p.base_url,
            p.default_model,
            if p.api_key.is_some() { "yes" } else { "no" }
        );
    }
    let _ = PROVIDER_REGISTRY.set(registry);

    // External-resource resolver config from env. STEWARDS_RESOLVER_URL is
    // a URL template (a "{ref}" placeholder is substituted with the
    // url-encoded reference; if absent, the encoded ref is appended).
    // STEWARDS_RESOLVER_TOKEN, if set, is sent as a bearer token. Taken
    // literally — the operator owns the full template, so no slash munging.
    let resolver_cfg = ResolverConfig {
        url: std::env::var("STEWARDS_RESOLVER_URL")
            .ok()
            .filter(|s| !s.is_empty()),
        token: std::env::var("STEWARDS_RESOLVER_TOKEN")
            .ok()
            .filter(|s| !s.is_empty()),
    };
    pgrx::log!(
        "stewards: resolver url={} token={}",
        resolver_cfg.url.as_deref().unwrap_or("<unset>"),
        if resolver_cfg.token.is_some() { "yes" } else { "no" }
    );
    let _ = RESOLVER_CONFIG.set(resolver_cfg);

    // Phase 3e.2.a — register N dispatcher workers. Each worker runs
    // the same tick loop but claims rows independently via FOR UPDATE
    // SKIP LOCKED, so concurrent draining is safe. The first worker
    // (index 0) is also responsible for once-per-postmaster startup
    // chores (stale-claim reaper) and the periodic Watchman scheduler
    // tick — those would race or duplicate work if all N ran them.
    //
    // Worker count is configurable via STEWARDS_DISPATCHER_WORKERS,
    // defaulting to 4. Cap at 16 to keep postmaster registration tidy.
    let worker_count: usize = std::env::var("STEWARDS_DISPATCHER_WORKERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(4)
        .min(16)
        .max(1);
    pgrx::log!("stewards: registering {} dispatcher worker(s)", worker_count);
    for i in 0..worker_count {
        BackgroundWorkerBuilder::new(&format!("pg_ai_stewards dispatcher #{}", i))
            .set_function("stewards_dispatcher_main")
            .set_library("pg_ai_stewards")
            .enable_spi_access()
            .set_restart_time(Some(Duration::from_secs(5)))
            .set_argument(Some(pg_sys::Datum::from(i as u64)))
            .load();
    }
}

/// Worker entry point. Polls `stewards.work_queue` every 500ms,
/// claims one row, runs the stub provider, writes the result back.
///
/// `arg` carries the worker index assigned at registration time
/// (0..N). Worker 0 is the "leader" — it owns the stale-claim reaper
/// and the Watchman scheduler tick, both of which must not run from
/// every worker simultaneously. All workers share the claim loop
/// (FOR UPDATE SKIP LOCKED makes that safe).
#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn stewards_dispatcher_main(arg: pg_sys::Datum) {
    let worker_index: usize = arg.value() as usize;
    let is_leader: bool = worker_index == 0;

    BackgroundWorker::attach_signal_handlers(
        SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM,
    );

    let dbname = std::env::var("POSTGRES_DB").unwrap_or_else(|_| "stewards".to_string());
    BackgroundWorker::connect_worker_to_spi(Some(&dbname), None);

    let provider_count = PROVIDER_REGISTRY.get().map(|r| r.providers.len()).unwrap_or(0);
    pgrx::log!(
        "stewards: bgworker #{} entering poll loop (500ms tick); leader={}; {} provider(s) inherited from postmaster",
        worker_index, is_leader, provider_count
    );

    // Stale-claim reaper: any row left in 'in_progress' by a previous
    // bgworker crash is unreachable \u2014 we never reclaim our own
    // claims (that would risk double-side-effects). Mark them errored
    // at startup with a clear message so the caller knows what
    // happened and can decide whether to re-enqueue.
    //
    // For tool_dispatch rows specifically, also call
    // synthesize_tool_failure: write the missing role='tool' replies
    // and enqueue a continuation chat. Otherwise the parent chat's
    // loop stalls forever waiting for tool replies that will never
    // come (Phase 1.6.1).
    //
    // Leader-only (worker 0): otherwise N workers race to reap and
    // synthesize, producing duplicate continuation chats.
    if is_leader {
    use pgrx::PgTryBuilder;
    // Phase A (Batch I + tonight, 2026-05-12): wrap the startup reaper
    // in PgTryBuilder. The SPI calls themselves should never ereport
    // on a healthy substrate, but if a corrupt row or missing function
    // is hit, PgTryBuilder lets the bgworker survive and log instead
    // of crashing into pg_ctl restart.
    let reaper_result: Result<(), String> = PgTryBuilder::new(|| {
        let outer: Result<(), pgrx::spi::Error> = BackgroundWorker::transaction(|| {
        Spi::connect_mut(|client| {
            // Pull the rows we're about to reap so we can synthesize
            // continuations for tool_dispatch ones.
            //
            // Phase 3e.2.b: skip kind='mcp_proxy'. Those rows belong
            // to the bridge daemon's lifecycle, not the bgworker's.
            // The bridge has its own startup reaper for stale
            // mcp_proxy rows it left in_progress at last shutdown.
            let stale_rows: Vec<(i64, String, String, serde_json::Value)> = {
                let rows = client.select(
                    "SELECT id, kind, provider, payload \
                     FROM stewards.work_queue \
                     WHERE status = 'in_progress' \
                       AND kind <> 'mcp_proxy'",
                    None, &[],
                )?;
                rows.into_iter().filter_map(|r| {
                    let id: i64 = r.get(1).ok()??;
                    let kind: String = r.get(2).ok()??;
                    let provider: String = r.get(3).ok()??;
                    let payload: pgrx::JsonB = r.get(4).ok()??;
                    Some((id, kind, provider, payload.0))
                }).collect()
            };

            for (id, kind, provider, payload) in &stale_rows {
                if kind == "tool_dispatch" {
                    if let (Some(parent), Some(session), Some(family), Some(model)) = (
                        payload.get("parent_work_id").and_then(|v| v.as_i64()),
                        payload.get("session_id").and_then(|v| v.as_str()),
                        payload.get("agent_family").and_then(|v| v.as_str()),
                        payload.get("model").and_then(|v| v.as_str()),
                    ) {
                        let synth = client.select(
                            "SELECT stewards.synthesize_tool_failure($1, $2, $3, $4, $5, $6)",
                            Some(1),
                            &[
                                parent.into(),
                                family.to_string().into(),
                                model.to_string().into(),
                                session.to_string().into(),
                                provider.to_string().into(),
                                format!(
                                    "bgworker crashed mid-dispatch on work_item id={}; loop continued via reaper",
                                    id
                                ).into(),
                            ],
                        );
                        if let Err(e) = synth {
                            pgrx::log!(
                                "stewards: reaper synthesize failed for id={}: {}",
                                id, e
                            );
                        } else {
                            pgrx::log!(
                                "stewards: reaper synthesized tool failure for tool_dispatch id={} (parent={})",
                                id, parent
                            );
                        }
                    }
                }
            }

            client.update(
                "UPDATE stewards.work_queue \
                 SET status = 'error', \
                     error  = coalesce(error, '') \
                              || 'bgworker crashed before completion (stale in_progress reaped at startup)', \
                     done_at = now() \
                 WHERE status = 'in_progress' \
                   AND kind <> 'mcp_proxy'",
                None, &[]
            )?;

            // ES.1.s3: record one crash per distinct kind reaped. A
            // genuine crash loop runs the reaper on every restart, so
            // the per-kind counter accumulates to the pause threshold.
            // One reaper pass = +1 per kind (not +1 per row) so a
            // single bad restart with many in-flight rows doesn't
            // instantly trip the breaker.
            {
                let mut seen: Vec<String> = Vec::new();
                for (_id, kind, _provider, _payload) in &stale_rows {
                    if !seen.iter().any(|k| k == kind) {
                        seen.push(kind.clone());
                        let _ = client.update(
                            "SELECT stewards.record_kind_crash($1)",
                            Some(1),
                            &[kind.clone().into()],
                        );
                    }
                }
            }
            Ok::<(), pgrx::spi::Error>(())
        })
        });
        outer.map_err(|e| format!("startup reaper SPI: {}", e))
    })
    .catch_others(|cause| {
        Err(format!("startup reaper PG error: {:?}", cause))
    })
    .execute();
    if let Err(e) = reaper_result {
        pgrx::log!("stewards: startup reaper failed: {} (bgworker survived)", e);
    }
    }

    // Phase 2.7b.2 — Watchman scheduler tick.
    //
    // The bgworker drains the work_queue every 500ms. Independently
    // (and much more rarely), it checks whether a Watchman pass should
    // fire. Decision logic lives entirely in SQL (stewards.watchman_
    // should_fire); Rust just calls it on a 60s tick and dispatches.
    //
    // last_sched=None on entry forces an immediate check on first tick,
    // useful when a fresh bgworker comes up after being down for a
    // while (don't make the user wait 60s for the first decision).
    let mut last_sched: Option<Instant> = None;
    const SCHED_INTERVAL: Duration = Duration::from_secs(60);

    // Phase 4d — Steward tick.
    //
    // Same pattern as the Watchman scheduler tick: independent of the
    // 500ms work_queue drain, the leader periodically calls
    // stewards.steward_tick() which walks failed work_items applying
    // cost-cap + breaker + diagnosis + escalation logic and dispatching
    // retries. 30s tick is chosen to balance retry latency against
    // log noise (the function returns 0 most of the time).
    //
    // Leader-only because steward_tick uses FOR UPDATE SKIP LOCKED
    // internally — multiple workers calling it would be SAFE but would
    // double the SQL traffic without throughput gain (the lock-skip
    // means each item is processed once anyway).
    let mut last_steward: Option<Instant> = None;
    const STEWARD_INTERVAL: Duration = Duration::from_secs(30);

    // Phase A (2026-05-12) — Periodic reaper tick.
    //
    // Mirrors the startup reaper but runs every 60s. Catches rows that
    // were left in_progress because a worker crashed mid-dispatch
    // WITHOUT a process restart (e.g. a PgTryBuilder catch where the
    // worker survived but didn't unwind the row claim). Threshold:
    // 15 minutes — longer than any legitimate model call. Bumped from
    // 10 min on 2026-05-14 after K.1 smoke showed engram extraction
    // on 426K-char inputs takes >10 min via DeepSeek V4 Flash on
    // OpenCode Go. 15min gives outlier extractions room to land while
    // still catching real hangs in reasonable time.
    //
    // Leader-only: same reasoning as the other ticks.
    let mut last_reaper: Option<Instant> = None;
    const REAPER_INTERVAL: Duration = Duration::from_secs(60);

    while BackgroundWorker::wait_latch(Some(Duration::from_millis(500))) {
        if BackgroundWorker::sighup_received() {
            pgrx::log!("stewards: SIGHUP received");
        }

        // Drain whatever's pending. process_one_pending() returns
        // false when the queue is empty, so the loop bounds itself.
        let mut processed = 0u32;
        while process_one_pending() {
            processed += 1;
            // Cap a single tick to avoid starving signal handling.
            if processed >= 16 {
                break;
            }
        }

        // Phase 3e.2.b — async-fan-out completion pass. Promotes any
        // tool_dispatch row whose mcp_proxy children have all
        // resolved out of 'waiting_for_tools' into 'done', writing
        // tool messages and enqueueing the continuation chat. All
        // workers run this (FOR UPDATE SKIP LOCKED inside the SQL
        // function keeps them from racing) so tool reply latency
        // doesn't hinge on a single leader.
        complete_waiting_tool_dispatches();

        // Watchman scheduler tick. Cheap when no trigger is hot
        // (single SPI call returning NULL). Two SPI calls when a
        // trigger fires (decide → enqueue chats). Leader-only —
        // running it from every worker would multiply the firing
        // decisions and risk duplicate passes despite cooldown logic.
        if is_leader && last_sched.map_or(true, |t| t.elapsed() >= SCHED_INTERVAL) {
            last_sched = Some(Instant::now());
            check_watchman_schedule();
        }

        // Phase 4d — Steward tick. Walks failed work_items that need
        // retry decisions. Returns count of actions taken (cost-cap
        // quarantine, breaker defer, queue-for-opus, retry dispatch,
        // or tick_error). Leader-only.
        if is_leader && last_steward.map_or(true, |t| t.elapsed() >= STEWARD_INTERVAL) {
            last_steward = Some(Instant::now());
            check_steward_tick();
        }

        // Phase A (2026-05-12) — Periodic reaper tick. Catches rows
        // orphaned mid-session (worker survived a PgTryBuilder catch
        // without unwinding the claim). Threshold 10 min so genuinely-
        // slow chats finish. Leader-only.
        if is_leader && last_reaper.map_or(true, |t| t.elapsed() >= REAPER_INTERVAL) {
            last_reaper = Some(Instant::now());
            run_periodic_reaper();
        }
    }

    pgrx::log!("stewards: bgworker #{} received SIGTERM, exiting", worker_index);
}

/// Phase 3e.2.b — completion pass for waiting tool_dispatch rows.
///
/// Calls `stewards.tool_dispatch_complete_waiting()` which scans
/// `kind='tool_dispatch' AND status='waiting_for_tools'` rows, joins
/// each one's pending children to check whether they've all resolved,
/// and (if so) inserts the tool messages, enqueues the continuation
/// chat, and promotes the parent to status='done'. Concurrent-safe
/// via FOR UPDATE SKIP LOCKED inside the function.
///
/// Errors are logged but never propagated — a transient SPI failure
/// shouldn't kill the bgworker. The next tick retries.
fn complete_waiting_tool_dispatches() {
    use pgrx::PgTryBuilder;
    // Phase A: PgTryBuilder wrap so a corrupted child row or missing
    // function can't kill the bgworker.
    let result: Result<Option<i32>, String> = PgTryBuilder::new(|| {
        let outer: Result<Option<i32>, pgrx::spi::Error> =
            BackgroundWorker::transaction(|| {
                Spi::connect_mut(|client| {
                    let row = client.select(
                        "SELECT stewards.tool_dispatch_complete_waiting()",
                        Some(1), &[],
                    )?;
                    let n: Option<i32> = row.into_iter().next()
                        .and_then(|r| r.get(1).ok().flatten());
                    Ok::<Option<i32>, pgrx::spi::Error>(n)
                })
            });
        outer.map_err(|e| format!("spi: {}", e))
    })
    .catch_others(|cause| Err(format!("postgres error: {:?}", cause)))
    .execute();

    match result {
        Ok(Some(n)) if n > 0 => {
            pgrx::log!("stewards: completed {} waiting tool_dispatch row(s)", n);
        }
        Ok(_) => {
            // Silent on zero — runs every tick, would flood the log.
        }
        Err(e) => {
            pgrx::log!("stewards: tool_dispatch completion pass errored: {} (bgworker survived)", e);
        }
    }
}

/// Phase 2.7b.2 — invoke the Watchman scheduler decision function.
///
/// Calls `stewards.watchman_scheduler_fire()` which itself calls
/// `watchman_should_fire()` and (if non-NULL) `watchman_pass_start()`.
/// Always logs the outcome:
///   - `pass_id != NULL` → a pass was started
///   - `pass_id == NULL` → either disabled, in cooldown, or no trigger
///
/// Errors here are swallowed (logged only) so a transient SPI failure
/// doesn't take down the bgworker. The next tick will try again.
fn check_watchman_schedule() {
    // Use connect_mut even though our SPI client only does a SELECT —
    // the SQL function it invokes (watchman_scheduler_fire) does
    // INSERTs/UPDATEs internally, and a read-only SPI context would
    // block those. Mirrors process_one_pending() and the reaper.
    //
    // Phase A: PgTryBuilder wrap so a watchman SQL bug can't kill the
    // bgworker. The scheduler fires every 60s — a kill here would mean
    // a restart loop until the bad row is cleared.
    use pgrx::PgTryBuilder;
    let result: Result<Option<String>, String> = PgTryBuilder::new(|| {
        let outer: Result<Option<String>, pgrx::spi::Error> =
            BackgroundWorker::transaction(|| {
                Spi::connect_mut(|client| {
                    let row = client.select(
                        "SELECT stewards.watchman_scheduler_fire()",
                        Some(1), &[],
                    )?;
                    let pass_id: Option<String> = row.into_iter().next()
                        .and_then(|r| r.get(1).ok().flatten());
                    Ok::<Option<String>, pgrx::spi::Error>(pass_id)
                })
            });
        outer.map_err(|e| format!("spi: {}", e))
    })
    .catch_others(|cause| Err(format!("postgres error: {:?}", cause)))
    .execute();

    match result {
        Ok(Some(pass_id)) => {
            pgrx::log!(
                "stewards: scheduler fired Watchman pass: {}",
                pass_id
            );
        }
        Ok(None) => {
            // No-op (no trigger, disabled, in cooldown). Don't log
            // every 60 seconds — that floods the postmaster log.
        }
        Err(e) => {
            pgrx::log!("stewards: scheduler check errored: {} (bgworker survived)", e);
        }
    }
}

/// Phase 4d — invoke the steward tick.
///
/// Calls `stewards.steward_tick()` which walks failed work_items and
/// applies cost-cap + breaker + diagnosis + escalation logic, then
/// dispatches retries via work_item_dispatch_stage. Returns count of
/// actions taken in this tick (0 = no failed work_items needed
/// attention). Errors swallowed — next tick retries.
fn check_steward_tick() {
    use pgrx::PgTryBuilder;
    // Phase A: PgTryBuilder wrap. The steward_tick SQL function walks
    // many tables — a corrupt row could ereport. Survive and log.
    let result: Result<Option<i32>, String> = PgTryBuilder::new(|| {
        let outer: Result<Option<i32>, pgrx::spi::Error> =
            BackgroundWorker::transaction(|| {
                Spi::connect_mut(|client| {
                    let row = client.select(
                        "SELECT stewards.steward_tick()",
                        Some(1), &[],
                    )?;
                    let n: Option<i32> = row.into_iter().next()
                        .and_then(|r| r.get(1).ok().flatten());
                    Ok::<Option<i32>, pgrx::spi::Error>(n)
                })
            });
        outer.map_err(|e| format!("spi: {}", e))
    })
    .catch_others(|cause| Err(format!("postgres error: {:?}", cause)))
    .execute();

    match result {
        Ok(Some(n)) if n > 0 => {
            pgrx::log!("stewards: steward_tick processed {} action(s)", n);
        }
        Ok(_) => {
            // Silent on zero — runs every 30s, would flood the log.
        }
        Err(e) => {
            pgrx::log!("stewards: steward_tick errored: {} (bgworker survived)", e);
        }
    }
}

/// Phase A (2026-05-12) — Periodic reaper.
///
/// Runs every 60s (leader-only). Reaps work_queue rows that have been
/// `in_progress` longer than the `reaper_stale_minutes` config (default 15;
/// a local rig raises it since a slow local model legitimately runs longer).
/// Mirrors the startup reaper's logic:
/// for `tool_dispatch` parents, synthesize tool-failure replies + enqueue
/// continuation so the chain doesn't stall; for everything else, mark
/// status=error with a clear diagnostic.
///
/// Threshold 10min (per ratification 2026-05-12): legitimate model
/// calls can take several minutes, especially with cold-start. 10x the
/// 60s call-timeout buffer means anything reaped is almost certainly
/// orphaned by a worker that died mid-dispatch.
///
/// Wrapped in PgTryBuilder so the reaper itself can't take down the
/// bgworker — a corrupted row or a broken synthesize_tool_failure call
/// logs and we continue.
fn run_periodic_reaper() {
    use pgrx::PgTryBuilder;
    let result: Result<i64, String> = PgTryBuilder::new(|| {
        let outer: Result<i64, pgrx::spi::Error> = BackgroundWorker::transaction(|| {
            Spi::connect_mut(|client| {
                // Identify stale rows (mirrors startup reaper's logic
                // but with the 10min threshold). Skip kind='mcp_proxy'
                // (bridge owns those).
                let stale_rows: Vec<(i64, String, String, serde_json::Value)> = {
                    let rows = client.select(
                        "SELECT id, kind, provider, payload \
                         FROM stewards.work_queue \
                         WHERE status = 'in_progress' \
                           AND kind <> 'mcp_proxy' \
                           AND claimed_at < now() - (stewards.config_get_text('reaper_stale_minutes', '15') || ' minutes')::interval",
                        None, &[],
                    )?;
                    rows.into_iter().filter_map(|r| {
                        let id: i64 = r.get(1).ok()??;
                        let kind: String = r.get(2).ok()??;
                        let provider: String = r.get(3).ok()??;
                        let payload: pgrx::JsonB = r.get(4).ok()??;
                        Some((id, kind, provider, payload.0))
                    }).collect()
                };

                if stale_rows.is_empty() {
                    return Ok::<i64, pgrx::spi::Error>(0);
                }

                let reaped_count = stale_rows.len() as i64;

                for (id, kind, provider, payload) in &stale_rows {
                    if kind == "tool_dispatch" {
                        if let (Some(parent), Some(session), Some(family), Some(model)) = (
                            payload.get("parent_work_id").and_then(|v| v.as_i64()),
                            payload.get("session_id").and_then(|v| v.as_str()),
                            payload.get("agent_family").and_then(|v| v.as_str()),
                            payload.get("model").and_then(|v| v.as_str()),
                        ) {
                            let synth = client.select(
                                "SELECT stewards.synthesize_tool_failure($1, $2, $3, $4, $5, $6)",
                                Some(1),
                                &[
                                    parent.into(),
                                    family.to_string().into(),
                                    model.to_string().into(),
                                    session.to_string().into(),
                                    provider.to_string().into(),
                                    format!(
                                        "periodic reaper: tool_dispatch id={} stale >15min, synthesizing failure",
                                        id
                                    ).into(),
                                ],
                            );
                            if let Err(e) = synth {
                                pgrx::log!(
                                    "stewards: periodic reaper synthesize failed for id={}: {}",
                                    id, e
                                );
                            } else {
                                pgrx::log!(
                                    "stewards: periodic reaper synthesized tool failure for tool_dispatch id={} (parent={})",
                                    id, parent
                                );
                            }
                        }
                    }
                }

                client.update(
                    "UPDATE stewards.work_queue \
                     SET status = 'error', \
                         error  = coalesce(error, '') \
                                  || 'periodic reaper: stale in_progress >15min', \
                         done_at = now() \
                     WHERE status = 'in_progress' \
                       AND kind <> 'mcp_proxy' \
                       AND claimed_at < now() - (stewards.config_get_text('reaper_stale_minutes', '15') || ' minutes')::interval",
                    None, &[]
                )?;

                Ok::<i64, pgrx::spi::Error>(reaped_count)
            })
        });
        outer.map_err(|e| format!("spi: {}", e))
    })
    .catch_others(|cause| Err(format!("postgres error: {:?}", cause)))
    .execute();

    match result {
        Ok(n) if n > 0 => {
            pgrx::log!("stewards: periodic reaper reaped {} stale in_progress row(s)", n);
        }
        Ok(_) => {
            // Silent on zero — runs every 60s, would flood the log.
        }
        Err(e) => {
            pgrx::log!("stewards: periodic reaper errored: {} (bgworker survived)", e);
        }
    }
}

/// Try to claim and process exactly one pending row. Returns true if
/// a row was processed (caller may want to immediately try again),
/// false if the queue was empty.
///
/// The work happens in three phases so we don't hold a row lock
/// across a slow HTTP call (LM Studio first-request model load can
/// be 30s+):
///
///   1. Tx A: claim oldest pending row, mark `in_progress`. Commit.
///   2. No tx: dispatch by kind, possibly making HTTP calls.
///   3. Tx B: write result or error, `NOTIFY stewards_done`. Commit.
fn process_one_pending() -> bool {
    // ----- Phase 1: claim -----
    let claim: Result<Option<(i64, String, String, serde_json::Value)>, pgrx::spi::Error> =
        BackgroundWorker::transaction(|| {
            Spi::connect_mut(|client| {
                // Phase 3e.2.b: bgworker explicitly skips kind='mcp_proxy'
                // rows. Those are owned by the bridge daemon
                // (cmd/stewards-mcp/bridge.go `bridge run`), which uses
                // the same SKIP LOCKED claim against this queue but
                // filters TO kind='mcp_proxy'. The two sides partition
                // by kind without coordinating beyond the row lock.
                // ES.1.s3: skip kinds the circuit breaker has paused
                // (5+ consecutive crash-reaps). The pause auto-expires
                // after the cooldown; a successful completion resets it.
                let claimed = client.update(
                    "WITH next AS ( \
                         SELECT id FROM stewards.work_queue \
                         WHERE status = 'pending' AND kind <> 'mcp_proxy' \
                           AND kind NOT IN ( \
                               SELECT kind FROM stewards.kind_circuit_breaker \
                                WHERE paused_until > now() \
                           ) \
                         ORDER BY created_at \
                         FOR UPDATE SKIP LOCKED \
                         LIMIT 1 \
                     ) \
                     UPDATE stewards.work_queue q \
                     SET status = 'in_progress', claimed_at = now() \
                     FROM next \
                     WHERE q.id = next.id \
                     RETURNING q.id, q.kind, q.provider, q.payload",
                    Some(1),
                    &[],
                )?;

                let mut iter = claimed.into_iter();
                let Some(row) = iter.next() else {
                    return Ok(None);
                };

                let id: i64 = row.get(1)?.expect("id non-null");
                let kind: String = row.get(2)?.expect("kind non-null");
                let provider: String = row.get(3)?.expect("provider non-null");
                let payload: pgrx::JsonB = row.get(4)?.expect("payload non-null");
                Ok(Some((id, kind, provider, payload.0)))
            })
        });

    let Some((id, kind, provider, payload)) = (match claim {
        Ok(opt) => opt,
        Err(e) => {
            pgrx::log!("stewards: claim phase errored: {}", e);
            return false;
        }
    }) else {
        return false;
    };

    pgrx::log!(
        "stewards: claimed work_item id={} kind={} provider={}",
        id,
        kind,
        provider
    );

    // ----- Phase 2: dispatch (no tx; HTTP allowed) -----
    let outcome = dispatch(&kind, &provider, &payload);

    // ----- Phase 3: write result -----
    let write: Result<(), pgrx::spi::Error> = BackgroundWorker::transaction(|| {
        Spi::connect_mut(|client| {
            match &outcome {
                Ok(WorkOutcome::Embedded {
                    target_table,
                    target_id,
                    model,
                    embedding_text,
                    dimensions,
                }) => {
                    // Write the vector back to the target row. target_table was
                    // validated against the EMBED_TARGETS allowlist at parse time
                    // in embed() — never reaches this identifier position raw.
                    // The cast to vector(N) validates dimensions; a mismatch
                    // raises a Postgres error the outer match converts to a row
                    // error. (The old "hard-code brain_entries" comment was stale
                    // and misleading — the audit's A1 flagged both.)
                    let update_target = format!(
                        "UPDATE stewards.{} \
                         SET embedding = $2::vector({}), \
                             embedded_at = now(), \
                             embedded_model = $3, \
                             embedding_error = NULL \
                         WHERE id = $1",
                        target_table, dimensions
                    );
                    client.update(
                        &update_target,
                        None,
                        &[
                            target_id.clone().into(),
                            embedding_text.clone().into(),
                            model.clone().into(),
                        ],
                    )?;

                    let result_jsonb = pgrx::JsonB(serde_json::json!({
                        "kind": "embed",
                        "provider": provider,
                        "model": model,
                        "dimensions": dimensions,
                        "target": format!("{}#{}", target_table, target_id),
                    }));
                    client.update(
                        "UPDATE stewards.work_queue \
                         SET status = 'done', result = $2, done_at = now() \
                         WHERE id = $1",
                        None,
                        &[id.into(), result_jsonb.into()],
                    )?;
                }
                Ok(WorkOutcome::Echo(value)) => {
                    let result_jsonb = pgrx::JsonB(value.clone());
                    client.update(
                        "UPDATE stewards.work_queue \
                         SET status = 'done', result = $2, done_at = now() \
                         WHERE id = $1",
                        None,
                        &[id.into(), result_jsonb.into()],
                    )?;
                }
                Ok(WorkOutcome::Chatted {
                    response,
                    session_id,
                    model,
                    agent_family,
                    requested_model,
                    assistant_content,
                    assistant_tool_calls,
                    reasoning_content,
                    reasoning_details,
                    finish_reason,
                    tokens_in,
                    tokens_out,
                    reasoning_tokens,
                    cache_creation_tokens,
                    cache_read_tokens,
                    upstream_cost_micro,
                }) => {
                    // Insert the assistant turn. tool_calls and the
                    // reasoning fields are stored verbatim so the
                    // next compose_messages call can echo them back
                    // (required by Moonshot when thinking is enabled).
                    // parent_work_id ties this message back to THIS
                    // work item so tool_dispatch can find it.
                    let tool_calls_jsonb = assistant_tool_calls
                        .clone()
                        .map(pgrx::JsonB);
                    let reasoning_details_jsonb = reasoning_details
                        .clone()
                        .map(pgrx::JsonB);
                    client.update(
                        "INSERT INTO stewards.messages \
                            (session_id, role, content, model, \
                             tool_calls, finish_reason, \
                             tokens_in, tokens_out, reasoning_tokens, \
                             reasoning_content, reasoning_details, \
                             parent_work_id) \
                         VALUES ($1, 'assistant', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
                        None,
                        &[
                            session_id.clone().into(),
                            assistant_content.clone().into(),
                            model.clone().into(),
                            tool_calls_jsonb.into(),
                            finish_reason.clone().into(),
                            (*tokens_in).into(),
                            (*tokens_out).into(),
                            (*reasoning_tokens).into(),
                            reasoning_content.clone().into(),
                            reasoning_details_jsonb.into(),
                            id.into(),
                        ],
                    )?;

                    // Phase 4f/4g/4h — Record a cost_event for every chat
                    // dispatch (work-item-tied OR ad-hoc, e.g., watchman).
                    //
                    // Phase 4g: cost_events.work_item_id is now nullable.
                    // For ad-hoc chats, work_item_id is NULL and session_id
                    // is the canonical owner identifier (a watchman pass
                    // dispatches multiple chats; each chat has its own
                    // session derived from the pass + slug).
                    //
                    // Phase 4h: cache_creation_tokens + cache_read_tokens
                    // are passed through. compute_cost gates each on the
                    // model's per-rate column being non-NULL, so providers
                    // that don't expose cache distinction (e.g., most
                    // OpenCode Go Chinese models) silently skip those
                    // contributions.
                    //
                    // Use `requested_model` (canonical short name like
                    // 'kimi-k2.6'), NOT `model` (the provider's full
                    // versioned identifier). model_pricing is keyed on
                    // the canonical name. The response model is preserved
                    // in cost_events.notes for audit.
                    //
                    // Errors logged, never propagated.
                    let in_tok = tokens_in.unwrap_or(0);
                    let out_tok = tokens_out.unwrap_or(0);
                    let cache_write_tok = cache_creation_tokens.unwrap_or(0);
                    let cache_read_tok = cache_read_tokens.unwrap_or(0);

                    if in_tok > 0 || out_tok > 0 || cache_write_tok > 0 || cache_read_tok > 0 {
                        let wi_opt: Option<&str> = payload
                            .get("_work_item_id")
                            .and_then(|v| v.as_str());

                        let cost_result = client.update(
                            "SELECT stewards.record_cost_event( \
                                $1::uuid, \
                                CASE \
                                  WHEN $1::uuid IS NULL \
                                    THEN (SELECT count(*)::int + 1 FROM stewards.cost_events WHERE session_id = $7) \
                                  ELSE (SELECT count(*)::int + 1 FROM stewards.cost_events WHERE work_item_id = $1::uuid) \
                                END, \
                                $2, $3, $4, $5, $6, $8, $7, $9, $10)",
                            Some(1),
                            &[
                                wi_opt.into(),
                                provider.to_string().into(),
                                requested_model.clone().into(),
                                in_tok.into(),
                                out_tok.into(),
                                cache_write_tok.into(),
                                session_id.clone().into(),
                                cache_read_tok.into(),
                                format!(
                                    "work_id={} response_model={}",
                                    id, model
                                ).into(),
                                // ES.3.s5: gateway-reported upstream cost.
                                (*upstream_cost_micro).into(),
                            ],
                        );
                        if let Err(e) = cost_result {
                            pgrx::log!(
                                "stewards: record_cost_event failed for work_id={} session={}: {}",
                                id, session_id, e
                            );
                        }
                    }

                    // Phase 5a/5b — Gate auto-fire (3 variants).
                    // After a gate-style chat completes, parse the JSON
                    // response and call the appropriate apply_* function.
                    // Three markers: _gate_eval, _scenarios_gen, _verify.
                    // Errors logged, never propagated — chat is already
                    // saved + work_queue is 'done'; failed auto-apply
                    // leaves the work_item un-transitioned for human
                    // hand-apply or re-trigger.
                    let wi_opt = payload
                        .get("_work_item_id")
                        .and_then(|v| v.as_str());
                    let is_gate_eval = payload
                        .get("_gate_eval")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    let is_scenarios_gen = payload
                        .get("_scenarios_gen")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    let is_verify = payload
                        .get("_verify")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    // Phase 5e (D.4): two more markers for Sabbath + Atonement.
                    let is_sabbath = payload
                        .get("_sabbath")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    let is_atonement = payload
                        .get("_atonement")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    // Phase 5g (F.4): two more for Council. _council_member
                    // routes by role: proposer/critic just store the response
                    // and check whether all members have responded; synthesizer
                    // dispatches go straight to apply_synthesize_result.
                    let council_id_opt = payload
                        .get("_council_id")
                        .and_then(|v| v.as_str());
                    let is_council_member = payload
                        .get("_council_member")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    let is_council_synth = payload
                        .get("_council_synthesize")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    let council_role = payload
                        .get("_council_role")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");

                    // Council member chats don't have _work_item_id;
                    // process them BEFORE the wi_opt check below.
                    if let Some(council_id) = council_id_opt {
                        if is_council_member {
                            let role = council_role;
                            // Pull the assistant content from the just-saved
                            // message (the loop above already INSERTed it).
                            let r: Result<Option<String>, pgrx::spi::Error> =
                                client.update(
                                    "SELECT content FROM stewards.messages WHERE session_id = $1 AND role='assistant' ORDER BY id DESC LIMIT 1",
                                    Some(1),
                                    &[session_id.as_str().into()],
                                ).and_then(|rs| {
                                    let mut it = rs.into_iter();
                                    if let Some(r) = it.next() {
                                        Ok(r.get::<String>(1)?)
                                    } else { Ok(None) }
                                });
                            if let Ok(Some(content)) = r {
                                let upd: Result<(), pgrx::spi::Error> =
                                    client.update(
                                        "UPDATE stewards.council_members SET response = $1, completed_at = now() WHERE council_id = $2::uuid AND role = $3 AND work_id = $4",
                                        Some(1),
                                        &[content.into(), council_id.into(), role.into(), id.into()],
                                    ).map(|_| ());
                                if let Err(e) = upd {
                                    pgrx::log!(
                                        "stewards: council_members update failed for council={} role={}: {}",
                                        council_id, role, e
                                    );
                                }

                                // Fire synthesize when all proposer + critic
                                // members are done (synthesizer member, if any
                                // dispatched at convene time, is ignored — the
                                // canonical synthesizer is the one fired here).
                                let count_done: Result<Option<i64>, pgrx::spi::Error> =
                                    client.update(
                                        "SELECT count(*) FROM stewards.council_members WHERE council_id=$1::uuid AND role IN ('proposer','critic') AND completed_at IS NULL",
                                        Some(1),
                                        &[council_id.into()],
                                    ).and_then(|rs| {
                                        let mut it = rs.into_iter();
                                        if let Some(r) = it.next() {
                                            Ok(r.get::<i64>(1)?)
                                        } else { Ok(None) }
                                    });
                                if let Ok(Some(remaining)) = count_done {
                                    if remaining == 0 {
                                        let synth: Result<Option<i64>, pgrx::spi::Error> =
                                            client.update(
                                                "SELECT stewards.synthesize_council($1::uuid)",
                                                Some(1),
                                                &[council_id.into()],
                                            ).and_then(|rs| {
                                                let mut it = rs.into_iter();
                                                if let Some(r) = it.next() {
                                                    Ok(r.get::<i64>(1)?)
                                                } else { Ok(None) }
                                            });
                                        match synth {
                                            Ok(Some(wid)) => pgrx::log!(
                                                "stewards: council {} all members done → synthesize work_id={}",
                                                council_id, wid),
                                            Ok(None) => {},
                                            Err(e) => pgrx::log!(
                                                "stewards: synthesize_council failed for council={}: {}",
                                                council_id, e),
                                        }
                                    }
                                }
                            }
                        } else if is_council_synth {
                            // Parse the synthesizer's JSON response and apply
                            let parsed: Result<Option<pgrx::JsonB>, pgrx::spi::Error> =
                                client.update(
                                    "SELECT stewards.parse_gate_response($1)",
                                    Some(1),
                                    &[id.into()],
                                ).and_then(|rs| {
                                    let mut it = rs.into_iter();
                                    if let Some(r) = it.next() {
                                        Ok(r.get::<pgrx::JsonB>(1)?)
                                    } else { Ok(None) }
                                });
                            match parsed {
                                Ok(Some(json)) => {
                                    let r: Result<Option<pgrx::Uuid>, pgrx::spi::Error> =
                                        client.update(
                                            "SELECT stewards.apply_synthesize_result($1::uuid, $2, $3)",
                                            Some(1),
                                            &[council_id.into(), json.into(), id.into()],
                                        ).and_then(|rs| {
                                            let mut it = rs.into_iter();
                                            if let Some(r) = it.next() {
                                                Ok(r.get::<pgrx::Uuid>(1)?)
                                            } else { Ok(None) }
                                        });
                                    match r {
                                        Ok(Some(rid)) => pgrx::log!(
                                            "stewards: council {} synthesize → resolution {}",
                                            council_id, rid),
                                        Ok(None) => pgrx::log!(
                                            "stewards: apply_synthesize_result returned null for council={}",
                                            council_id),
                                        Err(e) => pgrx::log!(
                                            "stewards: apply_synthesize_result failed for council={}: {}",
                                            council_id, e),
                                    }
                                }
                                Ok(None) => pgrx::log!(
                                    "stewards: synthesize response unparseable for council={} work_id={}",
                                    council_id, id),
                                Err(e) => pgrx::log!(
                                    "stewards: parse_gate_response failed for synthesize work_id={}: {}",
                                    id, e),
                            }
                        }
                    }

                    if let Some(wi_str) = wi_opt {
                        if is_gate_eval || is_scenarios_gen || is_verify || is_sabbath || is_atonement {
                            let parsed: Result<Option<pgrx::JsonB>, pgrx::spi::Error> =
                                client.update(
                                    "SELECT stewards.parse_gate_response($1)",
                                    Some(1),
                                    &[id.into()],
                                ).and_then(|rs| {
                                    let mut it = rs.into_iter();
                                    if let Some(r) = it.next() {
                                        Ok(r.get::<pgrx::JsonB>(1)?)
                                    } else {
                                        Ok(None)
                                    }
                                });

                            match parsed {
                                Ok(Some(json)) => {
                                    if is_gate_eval {
                                        let r: Result<Option<String>, pgrx::spi::Error> =
                                            client.update(
                                                "SELECT stewards.apply_gate_decision($1::uuid, $2, $3)",
                                                Some(1),
                                                &[wi_str.into(), json.into(), id.into()],
                                            ).and_then(|rs| {
                                                let mut it = rs.into_iter();
                                                if let Some(r) = it.next() {
                                                    Ok(r.get::<String>(1)?)
                                                } else { Ok(None) }
                                            });
                                        match r {
                                            Ok(Some(m)) => pgrx::log!(
                                                "stewards: gate decision applied for work_item={} → maturity={}",
                                                wi_str, m),
                                            Ok(None) => pgrx::log!(
                                                "stewards: gate apply returned null for work_item={}",
                                                wi_str),
                                            Err(e) => pgrx::log!(
                                                "stewards: apply_gate_decision failed for work_item={}: {}",
                                                wi_str, e),
                                        }
                                    } else if is_scenarios_gen {
                                        let r: Result<Option<i32>, pgrx::spi::Error> =
                                            client.update(
                                                "SELECT stewards.apply_scenarios_result($1::uuid, $2, $3)",
                                                Some(1),
                                                &[wi_str.into(), json.into(), id.into()],
                                            ).and_then(|rs| {
                                                let mut it = rs.into_iter();
                                                if let Some(r) = it.next() {
                                                    Ok(r.get::<i32>(1)?)
                                                } else { Ok(None) }
                                            });
                                        match r {
                                            Ok(Some(n)) => pgrx::log!(
                                                "stewards: {} scenarios generated for work_item={}",
                                                n, wi_str),
                                            Ok(None) => pgrx::log!(
                                                "stewards: scenarios apply returned null for work_item={}",
                                                wi_str),
                                            Err(e) => pgrx::log!(
                                                "stewards: apply_scenarios_result failed for work_item={}: {}",
                                                wi_str, e),
                                        }
                                    } else if is_verify {
                                        let r: Result<Option<bool>, pgrx::spi::Error> =
                                            client.update(
                                                "SELECT stewards.apply_verify_result($1::uuid, $2, $3)",
                                                Some(1),
                                                &[wi_str.into(), json.into(), id.into()],
                                            ).and_then(|rs| {
                                                let mut it = rs.into_iter();
                                                if let Some(r) = it.next() {
                                                    Ok(r.get::<bool>(1)?)
                                                } else { Ok(None) }
                                            });
                                        match r {
                                            Ok(Some(passed)) => pgrx::log!(
                                                "stewards: verify {} for work_item={}",
                                                if passed { "PASSED" } else { "FAILED" },
                                                wi_str),
                                            Ok(None) => pgrx::log!(
                                                "stewards: verify apply returned null for work_item={}",
                                                wi_str),
                                            Err(e) => pgrx::log!(
                                                "stewards: apply_verify_result failed for work_item={}: {}",
                                                wi_str, e),
                                        }
                                    } else if is_sabbath {
                                        let r: Result<Option<i64>, pgrx::spi::Error> =
                                            client.update(
                                                "SELECT stewards.apply_sabbath_result($1::uuid, $2, $3)",
                                                Some(1),
                                                &[wi_str.into(), json.into(), id.into()],
                                            ).and_then(|rs| {
                                                let mut it = rs.into_iter();
                                                if let Some(r) = it.next() {
                                                    Ok(r.get::<i64>(1)?)
                                                } else { Ok(None) }
                                            });
                                        match r {
                                            Ok(Some(lid)) => pgrx::log!(
                                                "stewards: sabbath reflection #{} written for work_item={}",
                                                lid, wi_str),
                                            Ok(None) => pgrx::log!(
                                                "stewards: sabbath apply returned null for work_item={}",
                                                wi_str),
                                            Err(e) => pgrx::log!(
                                                "stewards: apply_sabbath_result failed for work_item={}: {}",
                                                wi_str, e),
                                        }
                                    } else if is_atonement {
                                        let r: Result<Option<i32>, pgrx::spi::Error> =
                                            client.update(
                                                "SELECT stewards.apply_atonement_result($1::uuid, $2, $3)",
                                                Some(1),
                                                &[wi_str.into(), json.into(), id.into()],
                                            ).and_then(|rs| {
                                                let mut it = rs.into_iter();
                                                if let Some(r) = it.next() {
                                                    Ok(r.get::<i32>(1)?)
                                                } else { Ok(None) }
                                            });
                                        match r {
                                            Ok(Some(n)) => pgrx::log!(
                                                "stewards: {} atonement lessons written for work_item={}",
                                                n, wi_str),
                                            Ok(None) => pgrx::log!(
                                                "stewards: atonement apply returned null for work_item={}",
                                                wi_str),
                                            Err(e) => pgrx::log!(
                                                "stewards: apply_atonement_result failed for work_item={}: {}",
                                                wi_str, e),
                                        }
                                    }
                                }
                                Ok(None) => {
                                    pgrx::log!(
                                        "stewards: gate response unparseable for work_item={} work_id={} (gate_eval={} scenarios={} verify={} sabbath={} atonement={})",
                                        wi_str, id, is_gate_eval, is_scenarios_gen, is_verify, is_sabbath, is_atonement
                                    );
                                }
                                Err(e) => {
                                    pgrx::log!(
                                        "stewards: parse_gate_response failed for work_id={}: {}",
                                        id, e
                                    );
                                }
                            }
                        }
                    }

                    // Loop continuation: if assistant returned
                    // tool_calls AND we haven't exhausted agent.steps,
                    // enqueue a tool_dispatch row. The bgworker will
                    // pick it up on the next poll (~500ms).
                    //
                    // Key off the PRESENCE of a non-empty tool_calls array, not
                    // finish_reason: most providers signal a tool turn with
                    // finish_reason="tool_calls", but Gemini's OpenAI-compat
                    // endpoint returns finish_reason="stop" alongside a COMPLETE
                    // tool_calls array. Only genuine token-limit truncation
                    // (finish_reason="length") yields a partial/corrupt call list
                    // we must not dispatch.
                    let has_tool_calls = assistant_tool_calls
                        .as_ref()
                        .and_then(|v| v.as_array())
                        .map(|a| !a.is_empty())
                        .unwrap_or(false);
                    let truncated_mid_call = finish_reason.as_deref() == Some("length");
                    let mut continuation_enqueued: Option<i64> = None;
                    let mut stop_reason: Option<&'static str> = None;
                    if has_tool_calls && !truncated_mid_call {
                        // Pull iteration count and agent.steps in one
                        // round-trip. Default steps to 8 if the agent
                        // row's steps column is somehow NULL.
                        let iter_row = client.select(
                            "SELECT \
                                stewards.iteration_count($1) AS iter, \
                                coalesce((stewards.resolve_agent($2, $3)).steps, 8) AS max_steps",
                            Some(1),
                            &[
                                session_id.clone().into(),
                                agent_family.clone().into(),
                                requested_model.clone().into(),
                            ],
                        )?;
                        let mut iter_iter = iter_row.into_iter();
                        let iter_r = iter_iter.next().expect("iter row");
                        let iter_count: i32 = iter_r.get(1)?.unwrap_or(0);
                        let max_steps: i32 = iter_r.get(2)?.unwrap_or(8);

                        if iter_count < max_steps {
                            let enq_row = client.select(
                                "SELECT stewards.tool_dispatch_enqueue($1, $2, $3, $4, $5)",
                                Some(1),
                                &[
                                    id.into(),
                                    agent_family.clone().into(),
                                    requested_model.clone().into(),
                                    session_id.clone().into(),
                                    provider.to_string().into(),
                                ],
                            )?;
                            let mut e_iter = enq_row.into_iter();
                            let e_r = e_iter.next().expect("enqueue returns id");
                            continuation_enqueued = Some(e_r.get(1)?.unwrap_or(0));
                        } else {
                            pgrx::log!(
                                "stewards: agent step budget exhausted ({} >= {}); not continuing",
                                iter_count, max_steps
                            );
                            stop_reason = Some("steps_exhausted");
                        }
                    } else if has_tool_calls {
                        // Reached only when truncated_mid_call: the provider
                        // returned tool_calls but finish_reason='length', so the
                        // call list was cut off by the token limit. Don't
                        // dispatch — an incomplete call list would corrupt the
                        // conversation.
                        stop_reason = Some("truncated_tool_calls");
                    }

                    let result_jsonb = pgrx::JsonB(serde_json::json!({
                        "kind": "chat",
                        "provider": provider,
                        "model": model,
                        "session_id": session_id,
                        "finish_reason": finish_reason,
                        "tokens_in": tokens_in,
                        "tokens_out": tokens_out,
                        "reasoning_tokens": reasoning_tokens,
                        "billable_output":
                            tokens_out.unwrap_or(0)
                            + reasoning_tokens.unwrap_or(0),
                        "tool_call_count":
                            assistant_tool_calls.as_ref()
                                .and_then(|v| v.as_array())
                                .map(|a| a.len())
                                .unwrap_or(0),
                        "continuation_enqueued": continuation_enqueued,
                        "loop_stop_reason": stop_reason,
                        "response": response,
                    }));
                    client.update(
                        "UPDATE stewards.work_queue \
                         SET status = 'done', result = $2, done_at = now() \
                         WHERE id = $1",
                        None,
                        &[id.into(), result_jsonb.into()],
                    )?;
                }
                Ok(WorkOutcome::ToolsDispatched {
                    parent_work_id,
                    session_id,
                    agent_family,
                    model,
                    tool_messages,
                }) => {
                    // Insert one role='tool' message per dispatched
                    // call, with tool_call_id echoing the assistant's
                    // tool_call.id (provider requirement: each tool
                    // reply must reference its call). parent_work_id
                    // points at THIS tool_dispatch row for trace.
                    for (tc_id, _name, content) in tool_messages.iter() {
                        client.update(
                            "INSERT INTO stewards.messages \
                                (session_id, role, content, \
                                 tool_call_id, parent_work_id) \
                             VALUES ($1, 'tool', $2, $3, $4)",
                            None,
                            &[
                                session_id.clone().into(),
                                content.clone().into(),
                                tc_id.clone().into(),
                                id.into(),
                            ],
                        )?;
                    }

                    // Enqueue the next chat round. compose_messages
                    // will pick up the new tool messages automatically
                    // because they're now in the session history.
                    let next_row = client.select(
                        "SELECT stewards.chat_post_internal($1, $2, $3, $4)",
                        Some(1),
                        &[
                            agent_family.clone().into(),
                            model.clone().into(),
                            session_id.clone().into(),
                            provider.to_string().into(),
                        ],
                    )?;
                    let mut n_iter = next_row.into_iter();
                    let next_chat_work_id: i64 = n_iter
                        .next()
                        .and_then(|r| r.get(1).ok().flatten())
                        .unwrap_or(0);

                    let result_jsonb = pgrx::JsonB(serde_json::json!({
                        "kind": "tool_dispatch",
                        "parent_work_id": parent_work_id,
                        "session_id": session_id,
                        "tool_count": tool_messages.len(),
                        "tools": tool_messages.iter()
                            .map(|(tc_id, name, _)| serde_json::json!({
                                "tool_call_id": tc_id,
                                "name": name,
                            }))
                            .collect::<Vec<_>>(),
                        "next_chat_work_id": next_chat_work_id,
                    }));
                    client.update(
                        "UPDATE stewards.work_queue \
                         SET status = 'done', result = $2, done_at = now() \
                         WHERE id = $1",
                        None,
                        &[id.into(), result_jsonb.into()],
                    )?;
                }
                Ok(WorkOutcome::WaitingForTools {
                    parent_work_id,
                    session_id,
                    agent_family,
                    model,
                    resolved,
                    pending,
                }) => {
                    // Phase 3e.2.b — async fan-out. The dispatch
                    // emitted at least one mcp_proxy child; we
                    // pause this tool_dispatch row in
                    // 'waiting_for_tools' and store enough state
                    // for the SQL completion pass to finish the
                    // job once children resolve. NO message inserts
                    // and NO continuation chat enqueue here — both
                    // happen inside tool_dispatch_complete_waiting().
                    let resolved_json: Vec<serde_json::Value> = resolved
                        .iter()
                        .map(|(tc_id, name, content)| serde_json::json!({
                            "tc_id":   tc_id,
                            "name":    name,
                            "content": content,
                        }))
                        .collect();
                    let pending_json: Vec<serde_json::Value> = pending
                        .iter()
                        .map(|(tc_id, name, child_id)| serde_json::json!({
                            "tc_id":         tc_id,
                            "name":          name,
                            "child_work_id": child_id,
                        }))
                        .collect();
                    let result_jsonb = pgrx::JsonB(serde_json::json!({
                        "kind": "tool_dispatch_waiting",
                        "parent_work_id": parent_work_id,
                        "session_id": session_id,
                        "agent_family": agent_family,
                        "model": model,
                        "provider": provider,
                        "resolved": resolved_json,
                        "pending":  pending_json,
                        "started_waiting_at": format!("{:?}", std::time::SystemTime::now()),
                    }));
                    client.update(
                        "UPDATE stewards.work_queue \
                         SET status = 'waiting_for_tools', result = $2 \
                         WHERE id = $1",
                        None,
                        &[id.into(), result_jsonb.into()],
                    )?;
                    pgrx::log!(
                        "stewards: tool_dispatch id={} waiting on {} mcp_proxy child(ren)",
                        id, pending.len()
                    );
                }
                Ok(WorkOutcome::Resolved {
                    ref_str,
                    content,
                    error,
                }) => {
                    // UPSERT the cache row. attempt_count increments
                    // on conflict so we can see how many tries a
                    // flaky ref has taken.
                    let content_jsonb = content.clone().map(pgrx::JsonB);
                    client.update(
                        "INSERT INTO stewards.resolved_refs \
                            (ref, content, error, fetched_at, attempt_count) \
                         VALUES ($1, $2, $3, now(), 1) \
                         ON CONFLICT (ref) DO UPDATE \
                         SET content = EXCLUDED.content, \
                             error   = EXCLUDED.error, \
                             fetched_at = now(), \
                             attempt_count = stewards.resolved_refs.attempt_count + 1",
                        None,
                        &[
                            ref_str.clone().into(),
                            content_jsonb.into(),
                            error.clone().into(),
                        ],
                    )?;
                    let result_jsonb = pgrx::JsonB(serde_json::json!({
                        "kind": "resolve_ref",
                        "ref":  ref_str,
                        "cached": content.is_some(),
                        "error": error,
                    }));
                    client.update(
                        "UPDATE stewards.work_queue \
                         SET status = 'done', result = $2, done_at = now() \
                         WHERE id = $1",
                        None,
                        &[id.into(), result_jsonb.into()],
                    )?;
                }
                Err(msg) => {
                    pgrx::log!("stewards: work_item id={} failed: {}", id, msg);
                    // Best-effort: also stamp the brain row's
                    // embedding_error if this was an embed job, so
                    // the failure surfaces in app queries.
                    if kind == "embed" {
                        if let (Some(table), Some(target_id)) = (
                            payload.get("target_table").and_then(|v| v.as_str()),
                            payload.get("target_id").and_then(|v| v.as_str()),
                        ) {
                            let stamp = format!(
                                "UPDATE stewards.{} SET embedding_error = $2 WHERE id = $1",
                                table
                            );
                            // Ignore secondary errors (e.g., table
                            // we don't know about) — primary error
                            // is already on its way to the queue.
                            let _ = client.update(
                                &stamp,
                                None,
                                &[target_id.to_string().into(), msg.clone().into()],
                            );
                        }
                    }
                    // tool_dispatch failures: write synthetic
                    // role='tool' replies + enqueue continuation so
                    // the loop never stalls. Phase 1.6 left this
                    // gap open. Phase 1.6.1 closes it.
                    let mut continuation: Option<i64> = None;
                    if kind == "tool_dispatch" {
                        if let (Some(parent), Some(session), Some(family), Some(model_str)) = (
                            payload.get("parent_work_id").and_then(|v| v.as_i64()),
                            payload.get("session_id").and_then(|v| v.as_str()),
                            payload.get("agent_family").and_then(|v| v.as_str()),
                            payload.get("model").and_then(|v| v.as_str()),
                        ) {
                            let synth = client.select(
                                "SELECT stewards.synthesize_tool_failure($1, $2, $3, $4, $5, $6)",
                                Some(1),
                                &[
                                    parent.into(),
                                    family.to_string().into(),
                                    model_str.to_string().into(),
                                    session.to_string().into(),
                                    provider.to_string().into(),
                                    msg.clone().into(),
                                ],
                            );
                            match synth {
                                Ok(rows) => {
                                    continuation = rows.into_iter().next()
                                        .and_then(|r| r.get(1).ok().flatten());
                                    pgrx::log!(
                                        "stewards: synthesized tool failure for parent={}; continuation={:?}",
                                        parent, continuation
                                    );
                                }
                                Err(e) => {
                                    pgrx::log!(
                                        "stewards: synthesize_tool_failure SPI failed: {} (loop will stall)",
                                        e
                                    );
                                }
                            }
                        }
                    }
                    let err_result = pgrx::JsonB(serde_json::json!({
                        "error": msg,
                        "continuation_after_failure": continuation,
                    }));
                    client.update(
                        "UPDATE stewards.work_queue \
                         SET status = 'error', error = $2, result = $3, \
                             done_at = now() \
                         WHERE id = $1",
                        None,
                        &[id.into(), msg.clone().into(), err_result.into()],
                    )?;
                }
            }

            // ES.1.s3: a clean completion resets this kind's circuit-
            // breaker crash counter (and clears any pause). No-op when
            // the kind is already healthy.
            if outcome.is_ok() {
                let _ = client.update(
                    "SELECT stewards.record_kind_success($1)",
                    Some(1),
                    &[kind.clone().into()],
                );
            }

            // NOTIFY listeners with the row id as payload.
            let notify_sql = format!("NOTIFY stewards_done, '{}'", id);
            client.update(&notify_sql, None, &[])?;
            Ok(())
        })
    });

    if let Err(e) = write {
        pgrx::log!("stewards: write phase errored for id={}: {}", id, e);
    }
    true
}

// `WorkOutcome` enum moved to types.rs (Phase 3c.3.6 v2 module split).

/// Dispatch a work item by `kind`. Returns `Ok(WorkOutcome)` on
/// success, `Err(message)` on failure (the message is stored in
/// `work_queue.error` and surfaces to callers).
fn dispatch(
    kind: &str,
    provider: &str,
    payload: &serde_json::Value,
) -> Result<WorkOutcome, String> {
    match kind {
        "echo" => Ok(WorkOutcome::Echo(serde_json::json!({
            "echo": payload,
            "kind": kind,
            "provider": provider,
            "stub": "pg_ai_stewards echo",
        }))),
        "embed" => embed(provider, payload),
        "chat"  => chat(provider, payload),
        "tool_dispatch" => tool_dispatch(payload),
        "resolve_ref"   => resolve_ref(payload),
        other => Err(format!("unknown work kind: {}", other)),
    }
}

/// The static allowlist of embed-target tables — exactly the ones carrying
/// embedding/embedded_at/embedded_model columns. `enqueue` is PUBLIC-executable
/// and `target_table` is interpolated into an identifier position in the
/// Phase-3 UPDATE, so this is the audit-A1 injection seam: anything not on
/// this list must be refused before the HTTP embed call is even spent.
const EMBED_TARGETS: [&str; 5] = [
    "book_chunks",
    "brain_entries",
    "docs",
    "engram_embeddings",
    "messages",
];

/// Pure check for the A1 injection guard — no pgrx types, so it's a plain
/// `#[test]`-able unit independent of a live Postgres (see `embed_target_tests`
/// below). Case-sensitive, exact-match against `EMBED_TARGETS`; anything else
/// (an unknown table, an injection payload, an empty string, a case variant)
/// is rejected.
fn embed_target_allowed(target_table: &str) -> bool {
    EMBED_TARGETS.contains(&target_table)
}

#[cfg(test)]
mod embed_target_tests {
    use super::{embed_target_allowed, EMBED_TARGETS};

    #[test]
    fn allows_every_allowlisted_table() {
        for t in EMBED_TARGETS {
            assert!(embed_target_allowed(t), "expected {:?} to be allowed", t);
        }
    }

    #[test]
    fn rejects_a_system_catalog() {
        assert!(!embed_target_allowed("pg_authid"));
    }

    #[test]
    fn rejects_an_injection_payload() {
        assert!(!embed_target_allowed("evil; DROP TABLE x;--"));
    }

    #[test]
    fn rejects_empty_string() {
        assert!(!embed_target_allowed(""));
    }

    #[test]
    fn rejects_a_case_variant() {
        // exact-match, not case-insensitive — "Docs" must NOT alias "docs".
        assert!(!embed_target_allowed("Docs"));
    }
}

/// Resolve a provider at dispatch time: the 88 credential overlay first (a
/// wizard-saved key must beat a stale env key), then the boot-time env
/// registry. Dispatch runs OUTSIDE any transaction (phase 2), so the overlay
/// read opens its own short one — one indexed SELECT against the view, noise
/// next to the HTTP call that follows. An unusable DB row (bad ciphertext,
/// credential with no dials anywhere) is a loud Err, not a silent fallback to
/// the key the operator just tried to replace.
fn resolve_dispatch_provider(provider_name: &str) -> Result<crate::providers::Provider, String> {
    let overlay: Result<Option<crate::providers::Provider>, String> =
        BackgroundWorker::transaction(|| crate::providers::merged_provider_spi(provider_name));
    match overlay {
        Ok(Some(p)) => return Ok(p),
        Ok(None) => {}
        Err(e) => return Err(e),
    }
    PROVIDER_REGISTRY
        .get()
        .ok_or_else(|| "provider registry not initialized".to_string())?
        .providers
        .iter()
        .find(|p| p.name == provider_name)
        .cloned()
        .ok_or_else(|| format!("unknown provider: {}", provider_name))
}

/// Call an OpenAI-compatible /v1/embeddings endpoint and format the
/// response as a Postgres `vector` text literal (e.g. "[0.1,0.2,...]").
fn embed(provider_name: &str, payload: &serde_json::Value) -> Result<WorkOutcome, String> {
    let provider = resolve_dispatch_provider(provider_name)?;

    let text = payload
        .get("text")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "payload.text missing".to_string())?;
    let model = payload
        .get("model")
        .and_then(|v| v.as_str())
        .unwrap_or(&provider.default_model);
    let target_table = payload
        .get("target_table")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "payload.target_table missing".to_string())?
        .to_string();
    // ★ Injection guard (audit A1): target_table is interpolated into an
    // identifier position in the Phase-3 UPDATE, and `enqueue` is
    // PUBLIC-executable — so an arbitrary payload string here would run
    // attacker SQL at WORKER privilege (SPI accepts multiple statements).
    // Validate against the static allowlist of embed-target tables (exactly
    // the ones carrying embedding/embedded_at/embedded_model columns).
    // Failing here also fails FAST — before the HTTP embed call is spent.
    // The check itself is `embed_target_allowed` (below) — a pure fn with no
    // pgrx types, so it's unit-testable without a live Postgres (the
    // grindable regression oracle for this fix; audit A1 follow-up).
    if !embed_target_allowed(&target_table) {
        return Err(format!(
            "embed: target_table {:?} is not an allowed embed target {:?}",
            target_table, EMBED_TARGETS
        ));
    }
    let target_id = payload
        .get("target_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "payload.target_id missing".to_string())?
        .to_string();
    let expected_dim = payload
        .get("dimensions")
        .and_then(|v| v.as_i64())
        .unwrap_or(768) as i32;

    // HTTP + parse + dim-check now lives in embed_one (shared with the
    // synchronous stewards.embed_query() pg_extern). The async work path keeps
    // its pgvector-text formatting + work-queue write below.
    let embedding = embed_one(&provider, text, model, expected_dim)?;

    // Build pgvector's text format: "[v1,v2,...]". No spaces.
    let mut s = String::with_capacity(embedding.len() * 12);
    s.push('[');
    for (i, v) in embedding.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!("{}", v));
    }
    s.push(']');

    Ok(WorkOutcome::Embedded {
        target_table,
        target_id,
        model: model.to_string(),
        embedding_text: s,
        dimensions: expected_dim,
    })
}

/// Embed one text and return the raw vector — no DB write, no target_table/id.
/// The side-effect-free HTTP+parse core, shared by the async `embed()` work
/// path and the synchronous `stewards.embed_query()` pg_extern (lib.rs). Reuses
/// `send_with_retry` (#243 backoff) and the 120s blocking client (a cold local
/// model's first request can take that long).
pub(crate) fn embed_one(
    provider: &crate::providers::Provider,
    text: &str,
    model: &str,
    expected_dim: i32,
) -> Result<Vec<f32>, String> {
    let url = format!("{}/embeddings", provider.base_url.trim_end_matches('/'));
    let mut body = serde_json::json!({
        "model": model,
        "input": text,
    });
    // Request the embedding width. For Matryoshka (MRL) models (Google
    // gemini-embedding, OpenAI text-embedding-3) the default output is the FULL
    // width; the truncated size is obtained only by asking for it via the
    // OpenAI-compat `dimensions` field (Vertex maps it to output_dimensionality).
    // Without this, embed_query(..., 768) gets the model default back and the
    // length check below rejects it. Fixed-size providers (e.g. nomic@768) ignore
    // the field and still return their native width — the check stays as the
    // safety net if any provider honors neither. (Follow-up: a per-provider
    // capability flag if a provider *rejects* rather than ignores the field.)
    if expected_dim > 0 {
        body["dimensions"] = serde_json::json!(expected_dim);
    }

    let client = http_client();

    // Bearer minted once, reused across retries (same as chat).
    let bearer: Option<String> = provider.bearer_token()?;
    let resp = send_with_retry(
        || {
            let mut req = client
                .post(&url)
                .timeout(std::time::Duration::from_secs(120))
                .json(&body);
            if let Some(token) = &bearer {
                req = req.bearer_auth(token);
            }
            req
        },
        "embeddings",
    )?;

    let parsed: serde_json::Value = resp
        .json()
        .map_err(|e| format!("decode embeddings response: {}", e))?;

    let arr = parsed
        .get("data")
        .and_then(|d| d.as_array())
        .and_then(|a| a.first())
        .and_then(|d| d.get("embedding"))
        .and_then(|e| e.as_array())
        .ok_or_else(|| format!("unexpected embeddings response shape: {}", parsed))?;

    if arr.len() as i32 != expected_dim {
        return Err(format!(
            "embedding dimension mismatch: got {}, expected {}",
            arr.len(),
            expected_dim
        ));
    }

    let mut out = Vec::with_capacity(arr.len());
    for (i, v) in arr.iter().enumerate() {
        let f = v
            .as_f64()
            .ok_or_else(|| format!("embedding[{}] not a number", i))?;
        // pgvector stores f32; cast now so embed_query returns float4[].
        out.push(f as f32);
    }
    Ok(out)
}

/// Call an OpenAI-compatible /v1/chat/completions endpoint.
///
/// Payload shape (built by stewards.chat_enqueue):
///   {
///     "session_id":      "<id>",
///     "agent_family":    "<family>",
///     "requested_model": "<model>",
///     "meta":            { ... audit only, not sent ... },
///     "body":            { "model":..., "messages":[...], "tools":[...], ... }
///   }
///
/// On success, returns Chatted with the parsed assistant message
/// extracted into top-level fields. Phase 3 inserts that message
/// into stewards.messages and stamps usage.
/// Exponential backoff for retry `attempt` (1-based): base * 2^(attempt-1), capped at 10s.
fn backoff_delay(attempt: u32, base_ms: u64) -> std::time::Duration {
    let shift = attempt.saturating_sub(1).min(6);
    let ms = base_ms.saturating_mul(1u64 << shift).min(10_000);
    std::time::Duration::from_millis(ms)
}

/// POST a request with retry + exponential backoff on TRANSIENT failures —
/// HTTP 408/429/any 5xx (incl. Cloudflare 52x), or a network/connection error.
/// A `reqwest` RequestBuilder is consumed by `.send()`, so `build` reconstructs
/// the request on each attempt. Non-transient responses (4xx other than
/// 408/429) fail fast — no point retrying a 400/401/404. Returns the first
/// successful Response, or the final error string after exhausting attempts.
///
/// This closes the #243 gap: a transient blip MID-tool-loop (a Vertex
/// preview-model 429 "Resource exhausted", an Anthropic 529 overload, a
/// Cloudflare 52x) used to fail the whole stage — the stage model is resolved
/// once and a single failed turn errored the chat row → failed the work_item.
/// Now the blip is absorbed in place; only a PERSISTENT transient falls through
/// to the steward's stage-level alias failover (32-alias-failover.sql) as the
/// backstop. Tunable without a rebuild: STEWARDS_HTTP_RETRY_MAX (total attempts,
/// default 3), STEWARDS_HTTP_RETRY_BASE_MS (backoff base ms, default 800).
fn send_with_retry(
    build: impl Fn() -> reqwest::blocking::RequestBuilder,
    label: &str,
) -> Result<reqwest::blocking::Response, String> {
    let max_attempts: u32 = std::env::var("STEWARDS_HTTP_RETRY_MAX")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|&n| n >= 1)
        .unwrap_or(3);
    let base_ms: u64 = std::env::var("STEWARDS_HTTP_RETRY_BASE_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(800);
    let mut attempt: u32 = 0;
    loop {
        attempt += 1;
        match build().send() {
            Ok(resp) => {
                let status = resp.status();
                if status.is_success() {
                    return Ok(resp);
                }
                let code = status.as_u16();
                let transient = code == 408 || code == 429 || status.is_server_error();
                if transient && attempt < max_attempts {
                    pgrx::log!(
                        "stewards: {} transient HTTP {} (attempt {}/{}); backing off",
                        label, code, attempt, max_attempts
                    );
                    std::thread::sleep(backoff_delay(attempt, base_ms));
                    continue;
                }
                let body = resp.text().unwrap_or_default();
                return Err(format!("{} HTTP {}: {}", label, status, body));
            }
            Err(e) => {
                // Network / connection error — treat as transient and retry.
                if attempt < max_attempts {
                    pgrx::log!(
                        "stewards: {} send error (attempt {}/{}): {}; backing off",
                        label, attempt, max_attempts, e
                    );
                    std::thread::sleep(backoff_delay(attempt, base_ms));
                    continue;
                }
                return Err(format!("{} POST: {}", label, e));
            }
        }
    }
}

fn chat(provider_name: &str, payload: &serde_json::Value) -> Result<WorkOutcome, String> {
    // 88: overlay-aware resolution — a wizard-added provider (or a rotated
    // key) dispatches without a restart. Env registry is the fallback.
    let provider = resolve_dispatch_provider(provider_name)?;

    let session_id = payload
        .get("session_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "payload.session_id missing".to_string())?
        .to_string();
    let agent_family = payload
        .get("agent_family")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "payload.agent_family missing".to_string())?
        .to_string();
    let requested_model = payload
        .get("requested_model")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "payload.requested_model missing".to_string())?
        .to_string();
    let body_orig = payload
        .get("body")
        .ok_or_else(|| "payload.body missing".to_string())?;

    // Phase 5d (C.6): tools_disabled flag. When set on the payload,
    // strip the `tools` key from the body before POST. Used by
    // gate-style dispatches (gate eval, scenarios, verify, sabbath,
    // atonement, covenant_check) where the model returns structured
    // JSON and tool loops 5x the cost (Phase B lesson 2026-05-11).
    let tools_disabled = payload
        .get("tools_disabled")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    // AN.2: which gateway API shape this model needs — stamped onto the
    // payload by the work_queue BEFORE INSERT trigger from
    // model_capability.api_format. 'anthropic' models (qwen3.7-max,
    // minimax-m2.7) use /messages with x-api-key; default 'openai' is the
    // existing /chat/completions path.
    let api_format = payload
        .get("api_format")
        .and_then(|v| v.as_str())
        .unwrap_or("openai");
    let is_anthropic = api_format == "anthropic";
    // ES.6: always clone the body — strip tools if disabled, and set
    // stream:true. A non-streaming request sends no bytes during
    // generation, so a proxy in front of OpenCode Zen kills the idle
    // connection at ~125s (HTTP 500). Streaming keeps tokens flowing —
    // the connection never idles. Empirically confirmed 2026-05-15:
    // non-streaming 500 at 125.2s, streaming 200 at 185.8s.
    // ES.6: stream:true keeps the connection alive (a non-streaming request
    // idles and a proxy kills it ~125s). J.11: stream_options.include_usage
    // so streamed usage records cost (Gemini omits it otherwise; opencode
    // includes it regardless). AN.2: anthropic-format models take a different
    // body shape (system extracted, max_tokens required) — see
    // anthropic_body_from_openai — and a different endpoint (/messages).
    // Phantom-history sanitize (ALL providers, before any format branch): a
    // history stored before the phantom-slot accumulator fix may carry an
    // assistant tool_call with an empty function.name plus its orphan
    // role:tool result. deepseek/kimi tolerate replaying it; Google's
    // OpenAI-compat translation 400s ("function_response.name: Name cannot
    // be empty") and Anthropic 400s ("name: String should have at least 1
    // character"). One choke point beats per-format guards.
    let body_sane = sanitize_phantom_tool_history(body_orig);
    let body_owned = if is_anthropic {
        anthropic_body_from_openai(&body_sane, tools_disabled)
    } else {
        let mut b = body_sane.clone();
        if let serde_json::Value::Object(ref mut m) = b {
            if tools_disabled {
                m.remove("tools");
            }
            // `tool_choice` without a non-empty `tools` array is a 400 on
            // Alibaba/qwen (invalid_parameter_error) though other providers
            // tolerate it. The combo arises when a hard tool-round cap sets
            // tools_disabled + tool_choice='none' (80-rest final form): the
            // strip above removes tools but the choice key survived. Omitting
            // both is equivalent everywhere — no tools means no tool calls —
            // so drop tool_choice whenever tools is absent or empty.
            let tools_empty = m
                .get("tools")
                .and_then(|v| v.as_array())
                .map(|a| a.is_empty())
                .unwrap_or(true);
            if tools_empty {
                m.remove("tools");
                m.remove("tool_choice");
            }
            // #333: carry the dispatch session in OpenAI's standard `user`
            // field (providers ignore it) so a downstream shim (loom) can
            // propagate it into its MCP hinge — restoring doc→work-item
            // provenance when the DRAFT CREATOR itself is a loom stage
            // (the shared arc-c-* session otherwise has no wi-- to key on).
            if let Some(sid) = payload.get("session_id").and_then(|v| v.as_str()) {
                m.insert(
                    "user".to_string(),
                    serde_json::Value::String(sid.to_string()),
                );
            }
            m.insert("stream".to_string(), serde_json::Value::Bool(true));
            m.insert(
                "stream_options".to_string(),
                serde_json::json!({ "include_usage": true }),
            );
        }
        b
    };
    let body: &serde_json::Value = &body_owned;

    let url = if is_anthropic {
        format!("{}/messages", provider.base_url.trim_end_matches('/'))
    } else {
        format!("{}/chat/completions", provider.base_url.trim_end_matches('/'))
    };

    // Chat timeout. 120s was the original (matched embeddings) but
    // reasoning models on big inputs blow past that — the proposal
    // doc + ~50KB scratch files timed out during Phase 3a Watchman
    // smoke. Default raised to 600s; override via STEWARDS_CHAT_TIMEOUT_SECONDS
    // for ops tuning without a binary rebuild. The bgworker is
    // single-threaded per process, so a long chat blocks the queue —
    // the right Phase 3b move is also CLI-side input trimming, not
    // unbounded server time.
    let timeout_secs: u64 = std::env::var("STEWARDS_CHAT_TIMEOUT_SECONDS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(600);
    let client = http_client();

    // Mint the bearer once (the SA token is cached anyway) so it's reused across
    // retries; propagate an SA-mint error before entering the retry loop.
    let bearer: Option<String> = if is_anthropic { None } else { provider.bearer_token()? };
    // POST with transient retry/backoff (#243): a 429/5xx blip is absorbed here
    // instead of failing the whole tool-loop stage.
    let resp = send_with_retry(
        || {
            let mut req = client
                .post(&url)
                .timeout(std::time::Duration::from_secs(timeout_secs))
                .json(body);
            if is_anthropic {
                // Anthropic format auths via x-api-key + a version header, not Bearer.
                if let Some(key) = &provider.api_key {
                    req = req
                        .header("x-api-key", key.as_str())
                        .header("anthropic-version", "2023-06-01");
                }
            } else if let Some(token) = &bearer {
                // OpenAI-compat: a static api_key, or a freshly-minted Google SA
                // token (Vertex no-train) for the google_sa auth mode.
                req = req.bearer_auth(token);
            }
            req
        },
        "chat",
    )?;

    // ES.6: the request streams (stream:true). Parse the SSE event
    // stream and reassemble it into the standard non-streaming response
    // shape, so every downstream extraction below — and the SQL apply
    // handlers that re-parse result.response — are unchanged.
    let parsed: serde_json::Value = if is_anthropic {
        parse_anthropic_sse(resp).map_err(|e| format!("decode anthropic SSE stream: {}", e))?
    } else {
        parse_chat_sse(resp).map_err(|e| format!("decode chat SSE stream: {}", e))?
    };

    // Standard OpenAI shape: { choices: [{ message: { role, content,
    // tool_calls? }, finish_reason }], usage: { prompt_tokens,
    // completion_tokens } }
    let choice = parsed
        .get("choices")
        .and_then(|c| c.as_array())
        .and_then(|a| a.first())
        .ok_or_else(|| format!("no choices[0] in response: {}", parsed))?;
    let message = choice
        .get("message")
        .ok_or_else(|| format!("no choices[0].message: {}", parsed))?;

    // OpenAI returns content as either a string OR null (when only
    // tool_calls are present). NOT NULL on messages.content with
    // default '' handles both — we coerce to "".
    let assistant_content = message
        .get("content")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let assistant_tool_calls = message.get("tool_calls").cloned();
    // Reasoning capture. Field names vary by gateway:
    //   OpenRouter / OpenCode Go: `reasoning` (string), `reasoning_details` (array)
    //   Moonshot direct:          `reasoning_content` (string)
    // Coalesce both string forms; keep details verbatim for fidelity.
    let reasoning_content = message
        .get("reasoning_content")
        .or_else(|| message.get("reasoning"))
        .and_then(|v| v.as_str())
        .map(String::from);
    let reasoning_details = message.get("reasoning_details").cloned();
    let finish_reason = choice
        .get("finish_reason")
        .and_then(|v| v.as_str())
        .map(String::from);

    let model = parsed
        .get("model")
        .and_then(|v| v.as_str())
        .unwrap_or_else(|| {
            body.get("model").and_then(|v| v.as_str()).unwrap_or("?")
        })
        .to_string();

    let usage = parsed.get("usage");
    let tokens_in = usage
        .and_then(|u| u.get("prompt_tokens"))
        .and_then(|v| v.as_i64())
        .map(|v| v as i32);
    let tokens_out = usage
        .and_then(|u| u.get("completion_tokens"))
        .and_then(|v| v.as_i64())
        .map(|v| v as i32);
    // OpenAI's newer usage shape:
    //   usage.completion_tokens_details.reasoning_tokens
    // Reasoning tokens are NOT a subset of completion_tokens for kimi/
    // o1-class models — they're billed separately. The OpenCode Go
    // dashboard's "OUTPUT" column sums both; we record them apart so
    // cost math stays honest.
    let reasoning_tokens = usage
        .and_then(|u| u.get("completion_tokens_details"))
        .and_then(|d| d.get("reasoning_tokens"))
        .and_then(|v| v.as_i64())
        .map(|v| v as i32);

    // Phase 4h — Anthropic-style cache token fields.
    // Anthropic API exposes:
    //   usage.cache_creation_input_tokens (writes to cache, billed ~1.25x input)
    //   usage.cache_read_input_tokens     (reads from cache, billed ~0.1x input)
    // OpenCode Zen passes these through verbatim for Anthropic models.
    // OpenAI-compatible endpoints (most non-Anthropic models) don't
    // expose this; the fields will be None and compute_cost will skip
    // their contribution (it gates on the per-model rate being non-NULL
    // in model_pricing).
    let cache_creation_tokens = usage
        .and_then(|u| u.get("cache_creation_input_tokens"))
        .and_then(|v| v.as_i64())
        .map(|v| v as i32);
    let cache_read_tokens = usage
        .and_then(|u| u.get("cache_read_input_tokens"))
        .and_then(|v| v.as_i64())
        .map(|v| v as i32);

    // ES.3.s5 — gateway-reported upstream inference cost. OpenCode Zen
    // streams usage.cost_details.upstream_inference_cost (float dollars)
    // — the real cost the upstream provider charged. The top-level
    // `cost` field is 0 (subscription billing), so this detail is the
    // meaningful measured number. Convert to micro-dollars.
    let upstream_cost_micro = usage
        .and_then(|u| u.get("cost_details"))
        .and_then(|d| d.get("upstream_inference_cost"))
        .and_then(|v| v.as_f64())
        .map(|c| (c * 1_000_000.0).round() as i64);

    Ok(WorkOutcome::Chatted {
        response: parsed,
        session_id,
        model,
        agent_family,
        requested_model,
        assistant_content,
        assistant_tool_calls,
        reasoning_content,
        reasoning_details,
        finish_reason,
        tokens_in,
        tokens_out,
        reasoning_tokens,
        cache_creation_tokens,
        cache_read_tokens,
        upstream_cost_micro,
    })
}

// ES.6: a streamed tool_call, accumulated across SSE delta chunks.
// OpenAI streaming sends a tool_call's id + function.name once, then
// streams function.arguments as fragments — all keyed by `index`.
#[derive(Default)]
struct ToolCallAccum {
    id: String,
    name: String,
    arguments: String,
    // Provider-specific passthrough that must round-trip on the follow-up
    // request. Gemini 3.x thinking models attach a `thought_signature` here
    // (extra_content.google.thought_signature) and 400 the next call with
    // "Function call is missing a thought_signature" if it isn't echoed back.
    extra_content: Option<serde_json::Value>,
}

/// Parse an OpenAI-compatible SSE chat-completion stream and reassemble
/// it into the standard NON-streaming response object:
///   { choices: [{ message: {role, content, tool_calls?,
///                           reasoning_content?}, finish_reason }],
///     usage: {...}, model: ... }
/// so callers (and the SQL apply handlers reading result.response) see
/// the same shape they did before ES.6. `[DONE]` ends the stream;
/// an `error` event aborts with Err.
fn parse_chat_sse(resp: reqwest::blocking::Response) -> Result<serde_json::Value, String> {
    use std::io::BufRead;

    let reader = std::io::BufReader::new(resp);
    let mut content = String::new();
    let mut reasoning = String::new();
    let mut role = String::from("assistant");
    let mut finish_reason: Option<String> = None;
    let mut model: Option<String> = None;
    let mut usage: Option<serde_json::Value> = None;
    let mut tool_calls: Vec<ToolCallAccum> = Vec::new();

    for line in reader.lines() {
        let line = line.map_err(|e| format!("sse read: {}", e))?;
        let line = line.trim_end();
        if line.is_empty() {
            continue;
        }
        // SSE: only `data:` fields carry payload; ignore event:/id:/comments.
        let data = match line.strip_prefix("data:") {
            Some(d) => d.trim(),
            None => continue,
        };
        if data == "[DONE]" {
            break;
        }
        let chunk: serde_json::Value = match serde_json::from_str(data) {
            Ok(v) => v,
            Err(_) => continue, // tolerate a stray non-JSON line
        };
        if let Some(err) = chunk.get("error") {
            if !err.is_null() {
                return Err(format!("sse error event: {}", err));
            }
        }
        if model.is_none() {
            if let Some(m) = chunk.get("model").and_then(|v| v.as_str()) {
                model = Some(m.to_string());
            }
        }
        if let Some(u) = chunk.get("usage") {
            if !u.is_null() {
                usage = Some(u.clone());
            }
        }
        let choice0 = match chunk
            .get("choices")
            .and_then(|c| c.as_array())
            .and_then(|a| a.first())
        {
            Some(c) => c,
            None => continue, // usage-only / cost-only tail chunk
        };
        if let Some(fr) = choice0.get("finish_reason").and_then(|v| v.as_str()) {
            finish_reason = Some(fr.to_string());
        }
        let delta = match choice0.get("delta") {
            Some(d) => d,
            None => continue,
        };
        if let Some(r) = delta.get("role").and_then(|v| v.as_str()) {
            if !r.is_empty() {
                role = r.to_string();
            }
        }
        if let Some(c) = delta.get("content").and_then(|v| v.as_str()) {
            content.push_str(c);
        }
        // reasoning streams as `reasoning_content` (Moonshot/Zen) or
        // `reasoning` (OpenRouter) — coalesce both.
        if let Some(rc) = delta.get("reasoning_content").and_then(|v| v.as_str()) {
            reasoning.push_str(rc);
        } else if let Some(rc) = delta.get("reasoning").and_then(|v| v.as_str()) {
            reasoning.push_str(rc);
        }
        if let Some(tcs) = delta.get("tool_calls").and_then(|v| v.as_array()) {
            for tc in tcs {
                let id_opt = tc
                    .get("id")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty());
                // Separate parallel/sequential tool calls by the delta `index`
                // when the provider sends it (OpenAI / Moonshot / qwen). Gemini's
                // OpenAI-compat stream OMITS index — so two calls would both
                // default to slot 0 and their names+args would concatenate into
                // one malformed call ("coder_sandbox_startdoc_get"). Fall back to
                // the per-call `id` (which Gemini does send on each new call's
                // first delta); an id-less continuation delta appends to the last.
                let idx = if let Some(i) = tc.get("index").and_then(|v| v.as_u64()) {
                    i as usize
                } else if let Some(id) = id_opt {
                    match tool_calls.iter().position(|t| t.id == id) {
                        Some(pos) => pos,
                        None => {
                            tool_calls.push(ToolCallAccum::default());
                            tool_calls.len() - 1
                        }
                    }
                } else if tool_calls.is_empty() {
                    tool_calls.push(ToolCallAccum::default());
                    0
                } else {
                    tool_calls.len() - 1
                };
                while tool_calls.len() <= idx {
                    tool_calls.push(ToolCallAccum::default());
                }
                let acc = &mut tool_calls[idx];
                if let Some(id) = tc.get("id").and_then(|v| v.as_str()) {
                    if !id.is_empty() {
                        acc.id = id.to_string();
                    }
                }
                if let Some(f) = tc.get("function") {
                    if let Some(n) = f.get("name").and_then(|v| v.as_str()) {
                        if !n.is_empty() {
                            acc.name.push_str(n);
                        }
                    }
                    if let Some(a) = f.get("arguments").and_then(|v| v.as_str()) {
                        acc.arguments.push_str(a);
                    }
                }
                // Preserve provider passthrough (Gemini's thought_signature lives
                // in extra_content) so it can be echoed back next turn.
                if let Some(ec) = tc.get("extra_content") {
                    if !ec.is_null() {
                        acc.extra_content = Some(ec.clone());
                    }
                }
            }
        }
    }

    // Reassemble the non-streaming message object.
    let mut message = serde_json::Map::new();
    message.insert("role".to_string(), serde_json::Value::String(role));
    if content.is_empty() && !tool_calls.is_empty() {
        // tool-call-only turn: OpenAI uses null content here.
        message.insert("content".to_string(), serde_json::Value::Null);
    } else {
        message.insert("content".to_string(), serde_json::Value::String(content));
    }
    if !tool_calls.is_empty() {
        // Drop phantom slots the index gap-filler materialized. OpenCode Zen's
        // sonnet stream keeps Anthropic CONTENT-BLOCK indices in its OpenAI-compat
        // tool_call deltas — a text block at index 0 pushes the first real call to
        // index 1, and `while len <= idx` back-fills an empty slot 0. Storing it
        // poisons the session: the tool loop wastes a round on tool '' and an
        // Anthropic-format replay 400s ("name: String should have at least 1
        // character"). A name-less call is un-executable — skip it, loudly.
        let arr: Vec<serde_json::Value> = tool_calls
            .iter()
            .filter(|tc| {
                if tc.name.is_empty() {
                    pgrx::warning!(
                        "stewards: dropping phantom streamed tool_call (empty name, id={:?}, {} arg bytes) — provider indexed deltas past a non-tool block",
                        tc.id, tc.arguments.len()
                    );
                    false
                } else {
                    true
                }
            })
            .map(|tc| {
                let mut o = serde_json::Map::new();
                o.insert("id".to_string(), serde_json::Value::String(tc.id.clone()));
                o.insert("type".to_string(), serde_json::Value::String("function".to_string()));
                o.insert(
                    "function".to_string(),
                    serde_json::json!({ "name": tc.name, "arguments": tc.arguments }),
                );
                // Echo provider passthrough (Gemini thought_signature) back into
                // the stored tool_call so compose_messages replays it next turn.
                if let Some(ec) = &tc.extra_content {
                    o.insert("extra_content".to_string(), ec.clone());
                }
                serde_json::Value::Object(o)
            })
            .collect();
        if !arr.is_empty() {
            message.insert("tool_calls".to_string(), serde_json::Value::Array(arr));
        }
    }
    if !reasoning.is_empty() {
        message.insert(
            "reasoning_content".to_string(),
            serde_json::Value::String(reasoning),
        );
    }

    let mut resp_obj = serde_json::json!({
        "object": "chat.completion",
        "choices": [ {
            "index": 0,
            "message": serde_json::Value::Object(message),
            "finish_reason": finish_reason,
        } ],
    });
    if let Some(m) = model {
        resp_obj["model"] = serde_json::Value::String(m);
    }
    if let Some(u) = usage {
        resp_obj["usage"] = u;
    }
    Ok(resp_obj)
}

/// Strip phantom tool history from an OpenAI-shaped body before sending:
/// assistant tool_calls with an empty function.name (the streamed index
/// gap-filler artifact) are removed, and role:tool results that can no longer
/// pair with a surviving call (empty or now-dangling tool_call_id) are dropped
/// with them. Providers with strict request validation (Google, Anthropic)
/// reject the whole request over one such entry; lenient ones waste a round.
fn sanitize_phantom_tool_history(body: &serde_json::Value) -> serde_json::Value {
    let mut b = body.clone();
    let Some(msgs) = b.get_mut("messages").and_then(|v| v.as_array_mut()) else {
        return b;
    };
    let mut dropped_ids: Vec<String> = Vec::new();
    let mut dropped_calls = 0usize;
    for m in msgs.iter_mut() {
        if m.get("role").and_then(|v| v.as_str()) != Some("assistant") {
            continue;
        }
        let Some(tcs) = m.get_mut("tool_calls").and_then(|v| v.as_array_mut()) else {
            continue;
        };
        tcs.retain(|tc| {
            let name_ok = tc
                .get("function")
                .and_then(|f| f.get("name"))
                .and_then(|v| v.as_str())
                .map(|n| !n.is_empty())
                .unwrap_or(false);
            if !name_ok {
                dropped_calls += 1;
                dropped_ids.push(
                    tc.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                );
            }
            name_ok
        });
        // Normalize surviving calls' arguments: strict providers translate the
        // OpenAI arguments STRING into a tool_use input OBJECT, and "" / "null"
        // / non-object JSON 400s there ("Input should be an object"). An empty
        // arguments string means "no args" — say it as "{}".
        for tc in tcs.iter_mut() {
            let bad = tc
                .get("function")
                .and_then(|f| f.get("arguments"))
                .and_then(|v| v.as_str())
                .map(|a| {
                    serde_json::from_str::<serde_json::Value>(a)
                        .map(|v| !v.is_object())
                        .unwrap_or(true)
                })
                .unwrap_or(true);
            if bad {
                if let Some(f) = tc.get_mut("function").and_then(|f| f.as_object_mut()) {
                    f.insert(
                        "arguments".to_string(),
                        serde_json::Value::String("{}".to_string()),
                    );
                }
            }
        }
        if tcs.is_empty() {
            if let Some(o) = m.as_object_mut() {
                o.remove("tool_calls");
                // OpenAI stores tool-call-only turns with null content; without
                // the calls the turn needs SOME content to stay valid.
                if o.get("content").map(|c| c.is_null()).unwrap_or(true) {
                    o.insert(
                        "content".to_string(),
                        serde_json::Value::String(String::new()),
                    );
                }
            }
        }
    }
    if dropped_calls > 0 {
        msgs.retain(|m| {
            if m.get("role").and_then(|v| v.as_str()) != Some("tool") {
                return true;
            }
            let tcid = m.get("tool_call_id").and_then(|v| v.as_str()).unwrap_or("");
            !(tcid.is_empty() || dropped_ids.iter().any(|d| d == tcid))
        });
        pgrx::warning!(
            "stewards: sanitized {} phantom tool_call(s) (empty function.name) + paired results out of replayed history",
            dropped_calls
        );
    }
    b
}

/// AN.2 + AT.1: translate an OpenAI chat body into an Anthropic /messages body.
///   - system message(s) -> top-level `system` (Anthropic disallows system in messages)
///   - max_tokens is REQUIRED by Anthropic -> default 4096 if absent
///   - assistant turns carrying tool_calls -> assistant content with tool_use blocks
///   - role:tool results -> grouped into ONE user message of tool_result blocks
///     (consecutive tool messages merge; Anthropic wants tool_results in a user turn)
///   - tool defs: OpenAI {type:function,function:{name,description,parameters}} ->
///     Anthropic {name,description,input_schema}; stripped when tools_disabled
///   - stream:true (ES.6)
fn anthropic_body_from_openai(
    body_orig: &serde_json::Value,
    tools_disabled: bool,
) -> serde_json::Value {
    let model = body_orig.get("model").and_then(|v| v.as_str()).unwrap_or("");
    let max_tokens = body_orig
        .get("max_tokens")
        .and_then(|v| v.as_i64())
        .unwrap_or(4096);

    let mut system = String::new();
    let mut messages: Vec<serde_json::Value> = Vec::new();
    let mut pending_tool_results: Vec<serde_json::Value> = Vec::new();

    if let Some(arr) = body_orig.get("messages").and_then(|v| v.as_array()) {
        for m in arr {
            let role = m.get("role").and_then(|v| v.as_str()).unwrap_or("");

            // role:tool -> accumulate; Anthropic groups tool_results in a user turn.
            if role == "tool" {
                let tu_id = m.get("tool_call_id").and_then(|v| v.as_str()).unwrap_or("");
                // A result with no tool_use_id can't pair with any tool_use (the
                // phantom-slot artifact stored id="") — Anthropic rejects it; skip.
                if tu_id.is_empty() {
                    pgrx::warning!(
                        "stewards: skipping orphan tool_result (empty tool_call_id) in anthropic replay"
                    );
                    continue;
                }
                let content = m.get("content").and_then(|v| v.as_str()).unwrap_or("");
                pending_tool_results.push(serde_json::json!({
                    "type": "tool_result",
                    "tool_use_id": tu_id,
                    "content": content,
                }));
                continue;
            }

            // Any non-tool message flushes the pending tool_results first.
            if !pending_tool_results.is_empty() {
                messages.push(serde_json::json!({
                    "role": "user",
                    "content": std::mem::take(&mut pending_tool_results),
                }));
            }

            if role == "system" {
                if let Some(s) = m.get("content").and_then(|v| v.as_str()) {
                    if !system.is_empty() {
                        system.push_str("\n\n");
                    }
                    system.push_str(s);
                }
                continue;
            }

            // Assistant turn carrying tool_calls -> tool_use content blocks.
            let tool_calls = m.get("tool_calls").and_then(|v| v.as_array());
            if role == "assistant" && tool_calls.map(|a| !a.is_empty()).unwrap_or(false) {
                let mut blocks: Vec<serde_json::Value> = Vec::new();
                if let Some(text) = m.get("content").and_then(|v| v.as_str()) {
                    if !text.is_empty() {
                        blocks.push(serde_json::json!({ "type": "text", "text": text }));
                    }
                }
                for tc in tool_calls.unwrap() {
                    let id = tc.get("id").and_then(|v| v.as_str()).unwrap_or("");
                    let f = tc.get("function");
                    let name = f
                        .and_then(|f| f.get("name"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    // Replay guard: histories stored before the phantom-slot fix
                    // may carry a name-less tool_call; Anthropic validation 400s
                    // the whole request on it. Skip it (its empty-id tool_result
                    // is skipped by the orphan guard in the role:tool arm above).
                    if name.is_empty() {
                        pgrx::warning!(
                            "stewards: skipping empty-name tool_use in anthropic replay (id={:?})",
                            id
                        );
                        continue;
                    }
                    let args_str = f
                        .and_then(|f| f.get("arguments"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("{}");
                    // Anthropic requires input to be an OBJECT. Stored arguments
                    // can be "" (unparseable -> {}) but also "null"/"[]"/bare
                    // scalars from lenient providers — coerce all non-objects.
                    let input: serde_json::Value =
                        serde_json::from_str(args_str).unwrap_or_else(|_| serde_json::json!({}));
                    let input = if input.is_object() { input } else { serde_json::json!({}) };
                    blocks.push(serde_json::json!({
                        "type": "tool_use", "id": id, "name": name, "input": input,
                    }));
                }
                messages.push(serde_json::json!({ "role": "assistant", "content": blocks }));
                continue;
            }

            // Plain user/assistant text. Content stays a string.
            let content = m
                .get("content")
                .cloned()
                .unwrap_or_else(|| serde_json::Value::String(String::new()));
            messages.push(serde_json::json!({ "role": role, "content": content }));
        }
    }
    if !pending_tool_results.is_empty() {
        messages.push(serde_json::json!({
            "role": "user",
            "content": pending_tool_results,
        }));
    }

    let mut out = serde_json::json!({
        "model": model,
        "max_tokens": max_tokens,
        "messages": messages,
        "stream": true,
    });
    if !system.is_empty() {
        out["system"] = serde_json::Value::String(system);
    }
    if let Some(temp) = body_orig.get("temperature") {
        out["temperature"] = temp.clone();
    }
    // AT.1: translate tool definitions unless disabled.
    if !tools_disabled {
        if let Some(tools) = body_orig.get("tools").and_then(|v| v.as_array()) {
            let atools: Vec<serde_json::Value> = tools
                .iter()
                .filter_map(|t| {
                    let f = t.get("function")?;
                    let name = f.get("name").and_then(|v| v.as_str())?;
                    let desc = f.get("description").and_then(|v| v.as_str()).unwrap_or("");
                    let schema = f
                        .get("parameters")
                        .cloned()
                        .unwrap_or_else(|| serde_json::json!({ "type": "object" }));
                    Some(serde_json::json!({
                        "name": name, "description": desc, "input_schema": schema,
                    }))
                })
                .collect();
            if !atools.is_empty() {
                out["tools"] = serde_json::Value::Array(atools);
            }
        }
    }
    out
}

/// AN.2: parse opencode's Anthropic-format (/messages) SSE stream and
/// reassemble it into the SAME OpenAI non-streaming shape parse_chat_sse
/// produces, so all downstream extraction in chat() is unchanged.
///   text blocks      -> message.content
///   thinking blocks  -> message.reasoning_content
///   stop_reason      -> finish_reason (end_turn/stop_sequence->stop,
///                       max_tokens->length, tool_use->tool_calls)
///   input_tokens     -> usage.prompt_tokens
///   output_tokens    -> usage.completion_tokens
fn parse_anthropic_sse(resp: reqwest::blocking::Response) -> Result<serde_json::Value, String> {
    use std::io::BufRead;

    let reader = std::io::BufReader::new(resp);
    let mut content = String::new();
    let mut reasoning = String::new();
    let mut model: Option<String> = None;
    let mut stop_reason: Option<String> = None;
    let mut input_tokens: Option<i64> = None;
    let mut output_tokens: Option<i64> = None;
    let mut cache_creation: Option<i64> = None;
    let mut cache_read: Option<i64> = None;
    // AT.2: tool_use blocks keyed by content-block index -> (id, name, args-json).
    let mut tool_uses: std::collections::BTreeMap<usize, (String, String, String)> =
        std::collections::BTreeMap::new();

    for line in reader.lines() {
        let line = line.map_err(|e| format!("sse read: {}", e))?;
        let line = line.trim_end();
        if line.is_empty() {
            continue;
        }
        // Only `data:` lines carry JSON; `event:` / comments are ignored.
        let data = match line.strip_prefix("data:") {
            Some(d) => d.trim(),
            None => continue,
        };
        let chunk: serde_json::Value = match serde_json::from_str(data) {
            Ok(v) => v,
            Err(_) => continue,
        };
        match chunk.get("type").and_then(|v| v.as_str()) {
            Some("error") => {
                return Err(format!(
                    "anthropic sse error: {}",
                    chunk.get("error").unwrap_or(&chunk)
                ));
            }
            Some("message_start") => {
                if let Some(msg) = chunk.get("message") {
                    if model.is_none() {
                        if let Some(m) = msg.get("model").and_then(|v| v.as_str()) {
                            model = Some(m.to_string());
                        }
                    }
                    if let Some(u) = msg.get("usage") {
                        input_tokens = u
                            .get("input_tokens")
                            .and_then(|v| v.as_i64())
                            .or(input_tokens);
                        cache_creation = u
                            .get("cache_creation_input_tokens")
                            .and_then(|v| v.as_i64())
                            .or(cache_creation);
                        cache_read = u
                            .get("cache_read_input_tokens")
                            .and_then(|v| v.as_i64())
                            .or(cache_read);
                    }
                }
            }
            Some("content_block_start") => {
                // tool_use blocks announce their id + name here; text/thinking
                // blocks need no start handling (their deltas carry everything).
                if let Some(cb) = chunk.get("content_block") {
                    if cb.get("type").and_then(|v| v.as_str()) == Some("tool_use") {
                        let idx =
                            chunk.get("index").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                        let id = cb.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let name = cb
                            .get("name")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        tool_uses.insert(idx, (id, name, String::new()));
                    }
                }
            }
            Some("content_block_delta") => {
                let idx = chunk.get("index").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                if let Some(d) = chunk.get("delta") {
                    match d.get("type").and_then(|v| v.as_str()) {
                        Some("text_delta") => {
                            if let Some(t) = d.get("text").and_then(|v| v.as_str()) {
                                content.push_str(t);
                            }
                        }
                        Some("thinking_delta") => {
                            if let Some(t) = d.get("thinking").and_then(|v| v.as_str()) {
                                reasoning.push_str(t);
                            }
                        }
                        Some("input_json_delta") => {
                            if let Some(pj) = d.get("partial_json").and_then(|v| v.as_str()) {
                                if let Some(tu) = tool_uses.get_mut(&idx) {
                                    tu.2.push_str(pj);
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            Some("message_delta") => {
                if let Some(sr) = chunk
                    .get("delta")
                    .and_then(|d| d.get("stop_reason"))
                    .and_then(|v| v.as_str())
                {
                    stop_reason = Some(sr.to_string());
                }
                if let Some(u) = chunk.get("usage") {
                    output_tokens = u
                        .get("output_tokens")
                        .and_then(|v| v.as_i64())
                        .or(output_tokens);
                }
            }
            _ => {} // ping, content_block_start/stop, message_stop
        }
    }

    let finish_reason = stop_reason.as_deref().map(|sr| {
        match sr {
            "end_turn" | "stop_sequence" => "stop",
            "max_tokens" => "length",
            "tool_use" => "tool_calls",
            other => other,
        }
        .to_string()
    });

    let mut message = serde_json::Map::new();
    message.insert(
        "role".to_string(),
        serde_json::Value::String("assistant".to_string()),
    );
    message.insert("content".to_string(), serde_json::Value::String(content));
    if !reasoning.is_empty() {
        message.insert(
            "reasoning_content".to_string(),
            serde_json::Value::String(reasoning),
        );
    }
    // AT.2: emit accumulated tool_use blocks as OpenAI-shaped tool_calls (in
    // content-block index order) so the provider-agnostic tool loop drives them.
    if !tool_uses.is_empty() {
        let arr: Vec<serde_json::Value> = tool_uses
            .values()
            .map(|(id, name, args)| {
                serde_json::json!({
                    "id": id,
                    "type": "function",
                    "function": {
                        "name": name,
                        "arguments": if args.is_empty() { "{}" } else { args.as_str() },
                    }
                })
            })
            .collect();
        message.insert("tool_calls".to_string(), serde_json::Value::Array(arr));
    }

    let mut usage = serde_json::Map::new();
    if let Some(i) = input_tokens {
        usage.insert("prompt_tokens".to_string(), serde_json::json!(i));
    }
    if let Some(o) = output_tokens {
        usage.insert("completion_tokens".to_string(), serde_json::json!(o));
    }
    if let Some(c) = cache_creation {
        usage.insert(
            "cache_creation_input_tokens".to_string(),
            serde_json::json!(c),
        );
    }
    if let Some(c) = cache_read {
        usage.insert("cache_read_input_tokens".to_string(), serde_json::json!(c));
    }

    let mut resp_obj = serde_json::json!({
        "object": "chat.completion",
        "choices": [ {
            "index": 0,
            "message": serde_json::Value::Object(message),
            "finish_reason": finish_reason,
        } ],
    });
    if let Some(m) = model {
        resp_obj["model"] = serde_json::Value::String(m);
    }
    resp_obj["usage"] = serde_json::Value::Object(usage);
    Ok(resp_obj)
}
