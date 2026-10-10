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

    // STEWARDS_DATABASE first: the official postgres image's entrypoint now
    // unsets every POSTGRES_* variable before it execs the server, so
    // POSTGRES_DB no longer reaches this process on a fresh image build.
    let dbname = std::env::var("STEWARDS_DATABASE")
        .or_else(|_| std::env::var("POSTGRES_DB"))
        .unwrap_or_else(|_| "stewards".to_string());
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
        abort_failed_transaction();
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

    // v66: Message Batches cycle (run_batch_cycle). Leader-only, like the
    // other ticks; batch_open's SKIP LOCKED would make a second caller safe
    // but useless.
    let mut last_batch: Option<Instant> = None;
    const BATCH_INTERVAL: Duration = Duration::from_secs(30);

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

        if is_leader && last_batch.map_or(true, |t| t.elapsed() >= BATCH_INTERVAL) {
            last_batch = Some(Instant::now());
            run_batch_cycle();
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
            abort_failed_transaction();
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
            abort_failed_transaction();
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
            abort_failed_transaction();
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
            abort_failed_transaction();
            pgrx::log!("stewards: periodic reaper errored: {} (bgworker survived)", e);
        }
    }
}

/// A Postgres error or a panic caught around BackgroundWorker::transaction
/// leaves that transaction open (CommitTransactionCommand never ran), so the
/// worker's next StartTransactionCommand fails with "unexpected state STARTED",
/// outside any catch, and the worker exits (seen on a v66 roll, 2026-10-10,
/// while the image ran ahead of its SQL). Call this after the PgTryBuilder has
/// returned the error (the error state is flushed by then). When the error was
/// an Err value the closure returned, BackgroundWorker::transaction committed and
/// no transaction is open, so this does nothing.
pub(crate) fn abort_failed_transaction() {
    unsafe {
        if pg_sys::IsTransactionOrTransactionBlock() {
            pg_sys::AbortCurrentTransaction();
        }
    }
}

/// v66: one SPI step of the batch cycle in its own transaction. A Postgres
/// error or a panic is logged and gives None, so one bad row can neither stop
/// the leader nor crash it in a loop over the same batch.
fn batch_spi<T, F>(label: &str, f: F) -> Option<T>
where
    F: FnOnce(&mut pgrx::spi::SpiClient<'_>) -> Result<T, pgrx::spi::Error>,
{
    use pgrx::PgTryBuilder;
    use std::panic::AssertUnwindSafe;
    let f = AssertUnwindSafe(f);
    let result: Result<T, String> = PgTryBuilder::new(AssertUnwindSafe(move || {
        let f = f;
        BackgroundWorker::transaction(AssertUnwindSafe(move || Spi::connect_mut(|client| (f.0)(client))))
            .map_err(|e| format!("spi: {}", e))
    }))
    .catch_others(|cause| Err(format!("postgres error: {:?}", cause)))
    .execute();
    match result {
        Ok(v) => Some(v),
        Err(e) => {
            abort_failed_transaction();
            pgrx::log!("stewards: batch {}: {} (bgworker survived)", label, e);
            None
        }
    }
}

/// v66: the Message Batches cycle, every 30 s on the leader. Marks batches
/// with no end 25 h after submit, opens a batch per provider from rows that
/// have waited the fill window, submits opening batches whose backoff has
/// passed, and polls submitted batches, writing each result through
/// write_outcome. HTTP runs between transactions, never inside one.
fn run_batch_cycle() {
    // An image ahead of its SQL (the minutes between a roll and migrate.sh
    // apply) has no batch functions to call yet.
    let installed = batch_spi("installed", |c| {
        Ok(c.select("SELECT to_regprocedure('stewards.batch_open(text,integer)') IS NOT NULL", Some(1), &[])?
            .into_iter()
            .next()
            .and_then(|r| r.get::<bool>(1).ok().flatten())
            .unwrap_or(false))
    });
    thread_local! {
        static SAID_MISSING: std::cell::Cell<bool> = std::cell::Cell::new(false);
    }
    if installed != Some(true) {
        if !SAID_MISSING.with(|s| s.replace(true)) {
            pgrx::log!("stewards: batch cycle skipped: batch SQL not installed (v66); it starts once migrate.sh applies it");
        }
        return;
    }
    SAID_MISSING.with(|s| s.set(false));

    let stuck = batch_spi("sweep", |c| {
        Ok(c.update("SELECT stewards.batch_sweep_stuck()", Some(1), &[])?
            .into_iter()
            .next()
            .and_then(|r| r.get::<i32>(1).ok().flatten())
            .unwrap_or(0))
    });
    if let Some(n) = stuck.filter(|n| *n > 0) {
        pgrx::log!("stewards: {} batch(es) had no end 25 h after submit; their rows went back once", n);
    }

    let providers: Vec<String> = batch_spi("providers", |c| {
        let rows = c.select(
            "SELECT DISTINCT provider FROM stewards.work_queue WHERE status = 'batch_pending'",
            None,
            &[],
        )?;
        Ok(rows.into_iter().filter_map(|r| r.get::<String>(1).ok().flatten()).collect())
    })
    .unwrap_or_default();
    for p in &providers {
        let opened = batch_spi("open", |c| {
            Ok(c.update("SELECT stewards.batch_open($1)", Some(1), &[p.as_str().into()])?
                .into_iter()
                .next()
                .and_then(|r| r.get::<i64>(1).ok().flatten()))
        })
        .flatten();
        if opened == Some(-1) {
            log_batch_cap_refusal(p);
        }
    }

    let opening: Vec<(i64, String)> = batch_spi("opening", |c| {
        let rows = c.select(
            "SELECT id, provider FROM stewards.provider_batches \
             WHERE status = 'opening' AND (next_attempt_at IS NULL OR next_attempt_at <= now()) \
             ORDER BY id",
            None,
            &[],
        )?;
        Ok(rows
            .into_iter()
            .filter_map(|r| Some((r.get::<i64>(1).ok()??, r.get::<String>(2).ok()??)))
            .collect())
    })
    .unwrap_or_default();
    for (batch, provider) in &opening {
        submit_batch(*batch, provider);
    }

    let polls: Vec<(i64, String, String)> = batch_spi("poll list", |c| {
        let rows = c.select(
            "SELECT batch_id, provider, external_id FROM stewards.batch_poll_list(60)",
            None,
            &[],
        )?;
        Ok(rows
            .into_iter()
            .filter_map(|r| {
                Some((r.get::<i64>(1).ok()??, r.get::<String>(2).ok()??, r.get::<String>(3).ok()??))
            })
            .collect())
    })
    .unwrap_or_default();
    for (batch, provider, external_id) in &polls {
        poll_batch(*batch, provider, external_id);
    }
}

/// Rows refused by the spend cap wait in batch_pending; say so at most every
/// ten minutes per provider rather than every cycle.
fn log_batch_cap_refusal(provider: &str) {
    thread_local! {
        static LAST: std::cell::RefCell<std::collections::HashMap<String, Instant>> =
            std::cell::RefCell::new(std::collections::HashMap::new());
    }
    LAST.with(|m| {
        let mut m = m.borrow_mut();
        if m.get(provider).map_or(true, |t| t.elapsed() >= Duration::from_secs(600)) {
            m.insert(provider.to_string(), Instant::now());
            pgrx::log!(
                "stewards: batch rows for provider {} are waiting: the next row's estimate would cross its enforced spend cap (raise or refill the cap to send them)",
                provider
            );
        }
    });
}

/// The provider's batch id goes into a URL path; accept only its own alphabet.
fn valid_batch_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// v66: one batched chat as Message Batches `params`: the same body an
/// immediate anthropic chat sends, without `stream` (a batch rejects it).
fn anthropic_batch_params(payload: &serde_json::Value) -> Result<serde_json::Value, String> {
    let body = payload.get("body").ok_or_else(|| "payload.body missing".to_string())?;
    let tools_disabled = payload.get("tools_disabled").and_then(|v| v.as_bool()).unwrap_or(false);
    let mut b = anthropic_body_from_openai(&sanitize_phantom_tool_history(body), tools_disabled);
    inline_remote_images(&mut b);
    if let Some(m) = b.as_object_mut() {
        m.remove("stream");
    }
    Ok(b)
}

fn batch_submit_failed(batch: i64, error: &str, retryable: bool) {
    let action = batch_spi("submit failed", |c| {
        Ok(c.update(
            "SELECT stewards.batch_submit_failed($1, $2, $3)",
            Some(1),
            &[batch.into(), error.into(), retryable.into()],
        )?
        .into_iter()
        .next()
        .and_then(|r| r.get::<String>(1).ok().flatten()))
    })
    .flatten();
    pgrx::log!(
        "stewards: batch {} submit failed ({}): {}",
        batch,
        action.as_deref().unwrap_or("?"),
        error
    );
}

/// POST an opening batch's rows to {base_url}/messages/batches.
fn submit_batch(batch: i64, provider_name: &str) {
    let Some(rows) = batch_spi("rows", |c| {
        let rows = c.select(
            "SELECT id, payload FROM stewards.work_queue WHERE batch_id = $1 AND status = 'batched' ORDER BY id",
            None,
            &[batch.into()],
        )?;
        Ok(rows
            .into_iter()
            .filter_map(|r| Some((r.get::<i64>(1).ok()??, r.get::<pgrx::JsonB>(2).ok()??.0)))
            .collect::<Vec<(i64, serde_json::Value)>>())
    }) else {
        return;
    };

    let mut requests = Vec::with_capacity(rows.len());
    for (id, payload) in &rows {
        match anthropic_batch_params(payload) {
            Ok(params) => requests.push(serde_json::json!({ "custom_id": format!("wq{}", id), "params": params })),
            Err(e) => {
                let msg = format!("batch params: {}", e);
                batch_spi("bad row", |c| {
                    c.update("SELECT stewards.batch_fail_row($1, $2)", None, &[(*id).into(), msg.as_str().into()])?;
                    Ok(())
                });
            }
        }
    }
    if requests.is_empty() {
        // Every row was cancelled or refused before the POST.
        batch_spi("empty", |c| {
            c.update(
                "UPDATE stewards.provider_batches SET status = 'ended', ended_at = now(), \
                 error = 'no rows left to send' WHERE id = $1 AND status = 'opening'",
                None,
                &[batch.into()],
            )?;
            Ok(())
        });
        return;
    }

    let provider = match resolve_dispatch_provider(provider_name) {
        Ok(p) => p,
        Err(e) => return batch_submit_failed(batch, &format!("provider {}: {}", provider_name, e), false),
    };
    let Some(key) = provider.api_key.clone() else {
        return batch_submit_failed(batch, &format!("provider {} has no api_key", provider_name), false);
    };
    let url = format!("{}/messages/batches", provider.base_url.trim_end_matches('/'));
    let sent = http_client()
        .post(&url)
        .timeout(Duration::from_secs(300))
        .header("x-api-key", key.as_str())
        .header("anthropic-version", "2023-06-01")
        .json(&serde_json::json!({ "requests": requests }))
        .send();
    match sent {
        Ok(r) if r.status().is_success() => {
            let id = r
                .json::<serde_json::Value>()
                .ok()
                .and_then(|v| v.get("id").and_then(|x| x.as_str()).map(String::from));
            match id {
                Some(ext) if valid_batch_id(&ext) => {
                    batch_spi("submitted", |c| {
                        c.update("SELECT stewards.batch_submitted($1, $2)", None, &[batch.into(), ext.as_str().into()])?;
                        Ok(())
                    });
                    pgrx::log!("stewards: batch {} submitted to {} as {} ({} request(s))", batch, provider_name, ext, requests.len());
                }
                // Accepted, so a retry could send the rows twice; fail them by name instead.
                _ => batch_submit_failed(batch, "the provider accepted the batch but its response had no usable id", false),
            }
        }
        Ok(r) => {
            let status = r.status();
            let body: String = r.text().unwrap_or_default().chars().take(500).collect();
            let retryable = status.as_u16() == 408 || status.as_u16() == 429 || status.is_server_error();
            batch_submit_failed(batch, &format!("HTTP {}: {}", status, body), retryable);
        }
        Err(e) => batch_submit_failed(batch, &format!("POST: {}", e), true),
    }
}

/// GET a submitted batch; once it has ended, stream its results (JSONL, any
/// order, matched by custom_id) and write each one.
fn poll_batch(batch: i64, provider_name: &str, external_id: &str) {
    use std::io::BufRead;
    let mark_polled = || {
        batch_spi("polled", |c| {
            c.update("SELECT stewards.batch_polled($1)", None, &[batch.into()])?;
            Ok(())
        });
    };
    if !valid_batch_id(external_id) {
        pgrx::log!("stewards: batch {} has an unusable provider id; left for the stuck sweep", batch);
        return mark_polled();
    }
    let provider = match resolve_dispatch_provider(provider_name) {
        Ok(p) => p,
        Err(e) => {
            pgrx::log!("stewards: batch {} poll: provider {}: {}", batch, provider_name, e);
            return mark_polled();
        }
    };
    let Some(key) = provider.api_key.clone() else {
        pgrx::log!("stewards: batch {} poll: provider {} has no api_key", batch, provider_name);
        return mark_polled();
    };
    // The results URL is built from the configured base_url, not taken from the
    // provider's results_url, so the key only ever goes to the configured host.
    let base = format!("{}/messages/batches/{}", provider.base_url.trim_end_matches('/'), external_id);
    let get = |url: &str, secs: u64| {
        http_client()
            .get(url)
            .timeout(Duration::from_secs(secs))
            .header("x-api-key", key.as_str())
            .header("anthropic-version", "2023-06-01")
            .send()
            .and_then(|r| r.error_for_status())
    };
    let state = get(&base, 60).and_then(|r| r.json::<serde_json::Value>());
    let ended = match state {
        Ok(v) => v.get("processing_status").and_then(|s| s.as_str()) == Some("ended"),
        Err(e) => {
            pgrx::log!("stewards: batch {} ({}) poll failed: {}", batch, external_id, e);
            false
        }
    };
    if !ended {
        return mark_polled();
    }

    let resp = match get(&format!("{}/results", base), 1800) {
        Ok(r) => r,
        Err(e) => {
            pgrx::log!("stewards: batch {} ({}) results fetch failed: {}", batch, external_id, e);
            return mark_polled();
        }
    };
    let mut counts: std::collections::BTreeMap<&'static str, u32> = std::collections::BTreeMap::new();
    for line in std::io::BufReader::new(resp).lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                // Rows written so far are no longer 'batched'; the next poll re-reads and skips them.
                pgrx::log!("stewards: batch {} ({}) results read failed: {}", batch, external_id, e);
                return mark_polled();
            }
        };
        if line.trim().is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let Some(id) = v
            .get("custom_id")
            .and_then(|c| c.as_str())
            .and_then(|c| c.strip_prefix("wq"))
            .and_then(|n| n.parse::<i64>().ok())
        else {
            continue;
        };
        *counts.entry(apply_batch_result(batch, external_id, id, &v)).or_insert(0) += 1;
    }
    let missing = batch_spi("ended", |c| {
        Ok(c.update("SELECT stewards.batch_ended($1)", Some(1), &[batch.into()])?
            .into_iter()
            .next()
            .and_then(|r| r.get::<i32>(1).ok().flatten())
            .unwrap_or(0))
    })
    .unwrap_or(0);
    pgrx::log!("stewards: batch {} ({}) ended: {:?}, {} missing", batch, external_id, counts, missing);
}

/// The WorkOutcome a `succeeded` result stands for, built the way chat() builds one.
fn batch_outcome(payload: &serde_json::Value, msg: &serde_json::Value) -> Result<WorkOutcome, String> {
    let field = |k: &str| {
        payload
            .get(k)
            .and_then(|v| v.as_str())
            .map(String::from)
            .ok_or_else(|| format!("payload.{} missing", k))
    };
    let (session_id, agent_family, requested_model) =
        (field("session_id")?, field("agent_family")?, field("requested_model")?);
    let body_model = payload.pointer("/body/model").and_then(|v| v.as_str()).unwrap_or("?");
    outcome_from_completion(completion_from_anthropic_message(msg), body_model, session_id, agent_family, requested_model)
}

fn batch_row_failed(id: i64, kind: &str, message: &str) -> &'static str {
    let action = batch_spi("row failed", |c| {
        Ok(c.update(
            "SELECT stewards.batch_row_failed($1, $2, $3)",
            Some(1),
            &[id.into(), kind.into(), message.into()],
        )?
        .into_iter()
        .next()
        .and_then(|r| r.get::<String>(1).ok().flatten()))
    })
    .flatten();
    match action.as_deref() {
        Some("requeued") => "requeued",
        Some("failed") => "failed",
        Some("skipped") => "skipped",
        _ => "unrecorded",
    }
}

/// One result line: write a succeeded message, route anything else through
/// batch_row_failed. Returns what happened, for the batch's log line.
fn apply_batch_result(batch: i64, external_id: &str, id: i64, line: &serde_json::Value) -> &'static str {
    let row = batch_spi("row", |c| {
        let rows = c.select(
            "SELECT kind, provider, payload FROM stewards.work_queue \
             WHERE id = $1 AND batch_id = $2 AND status = 'batched'",
            Some(1),
            &[id.into(), batch.into()],
        )?;
        Ok(rows.into_iter().next().and_then(|r| {
            Some((r.get::<String>(1).ok()??, r.get::<String>(2).ok()??, r.get::<pgrx::JsonB>(3).ok()??.0))
        }))
    })
    .flatten();
    let Some((kind, provider, payload)) = row else {
        return "skipped";
    };
    let result = line.get("result");
    match result.and_then(|r| r.get("type")).and_then(|t| t.as_str()) {
        Some("succeeded") => {
            let msg = result.and_then(|r| r.get("message")).cloned().unwrap_or(serde_json::Value::Null);
            let outcome = batch_outcome(&payload, &msg);
            let written: Result<bool, String> = pgrx::PgTryBuilder::new(std::panic::AssertUnwindSafe(|| {
                Ok(write_outcome(id, &kind, &provider, &payload, &outcome, Some(external_id)))
            }))
            .catch_others(|cause| Err(format!("{:?}", cause)))
            .execute();
            match written {
                Ok(true) => "written",
                Ok(false) => "skipped",
                Err(e) => {
                    abort_failed_transaction();
                    let msg = format!("batch result could not be written: {}", e);
                    pgrx::log!("stewards: work_item id={} {}", id, msg);
                    batch_spi("unwritable", |c| {
                        c.update(
                            "SELECT stewards.batch_fail_row($1, $2) FROM stewards.work_queue WHERE id = $1 AND status = 'batched'",
                            None,
                            &[id.into(), msg.as_str().into()],
                        )?;
                        Ok(())
                    });
                    "failed"
                }
            }
        }
        Some(t @ ("expired" | "canceled")) => batch_row_failed(id, t, "the provider did not run this request"),
        Some("errored") => {
            // result.error is the API's error shape: {"type": "error", "error": {"type", "message"}}.
            let err = result.and_then(|r| r.get("error"));
            let inner = err.and_then(|e| e.get("error")).or(err);
            let etype = inner.and_then(|e| e.get("type")).and_then(|t| t.as_str()).unwrap_or("errored");
            let emsg = inner.and_then(|e| e.get("message")).and_then(|t| t.as_str()).unwrap_or("");
            batch_row_failed(id, etype, emsg)
        }
        other => batch_row_failed(id, "unknown_result", &format!("result type {:?}", other)),
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
    write_outcome(id, &kind, &provider, &payload, &outcome, None);
    true
}

/// Phase 3 of a dispatch: one transaction writes the outcome (the assistant
/// message, its cost_event, the apply handlers, the row's status) and NOTIFYs.
/// v66: a Message Batches result passes `batch` (the provider's batch id). It is
/// written only while the row is still 'batched', so a row cancelled or already
/// answered is left alone, and its cost_event is recorded at the batch rate.
/// Returns whether the outcome was written.
fn write_outcome(
    id: i64,
    kind: &str,
    provider: &str,
    payload: &serde_json::Value,
    outcome: &Result<WorkOutcome, String>,
    batch: Option<&str>,
) -> bool {
    let write: Result<bool, pgrx::spi::Error> = BackgroundWorker::transaction(|| {
        Spi::connect_mut(|client| {
            if batch.is_some() {
                let still_batched = client
                    .update(
                        "SELECT 1 FROM stewards.work_queue WHERE id = $1 AND status = 'batched' FOR UPDATE",
                        Some(1),
                        &[id.into()],
                    )?
                    .into_iter()
                    .next()
                    .is_some();
                if !still_batched {
                    return Ok(false);
                }
                client.update("SELECT set_config('stewards.price_factor', '0.5', true)", Some(1), &[])?;
            }
            match outcome {
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
                    reasoning_in_completion,
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
                        // v65: the effort/thinking settings the request carried and the thinking tokens the
                        // provider reported, so cost comparisons read from cost_events, not from logs.
                        let mut notes = format!("work_id={} response_model={}", id, model);
                        let opts = payload.pointer("/body/anthropic_options");
                        if let Some(e) = opts.and_then(|o| o.pointer("/output_config/effort")).and_then(|v| v.as_str()) {
                            notes.push_str(&format!(" effort={e}"));
                        }
                        if let Some(t) = opts.and_then(|o| o.pointer("/thinking/type")).and_then(|v| v.as_str()) {
                            notes.push_str(&format!(" thinking={t}"));
                        }
                        if let Some(r) = reasoning_tokens {
                            notes.push_str(&format!(" thinking_tokens={r}"));
                        }
                        if let Some(b) = batch {
                            notes.push_str(&format!(" batch={b}"));
                        }

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
                                notes.into(),
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
                            + if *reasoning_in_completion { 0 } else { reasoning_tokens.unwrap_or(0) },
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
                    &[kind.to_string().into()],
                );
            }

            // NOTIFY listeners with the row id as payload.
            let notify_sql = format!("NOTIFY stewards_done, '{}'", id);
            client.update(&notify_sql, None, &[])?;
            Ok(true)
        })
    });

    match write {
        Ok(written) => written,
        Err(e) => {
            pgrx::log!("stewards: write phase errored for id={}: {}", id, e);
            false
        }
    }
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

#[cfg(test)]
mod sse_tests {
    // #361: a named `event: error` frame must terminate the parse with the
    // upstream payload — never be dropped, never read as content.
    use super::parse_chat_sse_reader;

    #[test]
    fn named_error_event_errors_with_payload_and_not_content() {
        // content arrives first, then a named error frame mid-stream.
        let sse = "\
data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"}}]}\n\
\n\
event: error\n\
data: {\"message\":\"upstream overloaded\",\"code\":529}\n\
\n";
        let err = parse_chat_sse_reader(sse.as_bytes())
            .expect_err("a named error event must terminate the parse");
        // The error carries the payload …
        assert!(
            err.contains("upstream overloaded"),
            "error must carry the payload, got: {err}"
        );
        assert!(err.starts_with("sse error event:"), "got: {err}");
        // … and because it is an Err, the "hello" delta is NOT returned as
        // content: there is no Ok value at all, so the payload cannot be
        // mis-read as assistant content.
    }

    #[test]
    fn error_event_without_space_is_handled() {
        // Some servers emit `event:error` (no space).
        let sse = "event:error\ndata: {\"detail\":\"model not available\"}\n\n";
        let err = parse_chat_sse_reader(sse.as_bytes()).expect_err("must error");
        assert!(err.contains("model not available"), "got: {err}");
    }

    #[test]
    fn non_error_named_event_does_not_hijack_following_data() {
        // A benign named event must NOT route its data to error handling.
        let sse = "\
event: message\n\
data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\
data: [DONE]\n";
        let v = parse_chat_sse_reader(sse.as_bytes()).expect("must parse");
        assert_eq!(v["choices"][0]["message"]["content"], "ok");
    }

    #[test]
    fn normal_stream_still_reassembles() {
        let sse = "\
data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\
data: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}\n\
data: [DONE]\n";
        let v = parse_chat_sse_reader(sse.as_bytes()).expect("must parse");
        assert_eq!(v["choices"][0]["message"]["content"], "hi there");
    }

    #[test]
    fn embedded_error_in_data_still_errors() {
        // The pre-existing `data: {"error": {...}}` path is unchanged.
        let sse = "data: {\"error\":{\"message\":\"boom\"}}\n";
        let err = parse_chat_sse_reader(sse.as_bytes()).expect_err("must error");
        assert!(err.contains("boom"), "got: {err}");
    }
}

#[cfg(test)]
mod anthropic_cache_tests {
    use super::anthropic_body_from_openai;

    fn marked(v: &serde_json::Value) -> bool {
        v.get("cache_control").and_then(|c| c.get("type")) == Some(&serde_json::json!("ephemeral"))
    }

    fn count_marks(v: &serde_json::Value) -> usize {
        match v {
            serde_json::Value::Object(m) => {
                m.contains_key("cache_control") as usize + m.values().map(count_marks).sum::<usize>()
            }
            serde_json::Value::Array(a) => a.iter().map(count_marks).sum(),
            _ => 0,
        }
    }

    #[test]
    fn marks_last_tool_system_and_last_user_text() {
        let body = serde_json::json!({
            "model": "claude-haiku-5-5",
            "messages": [
                {"role": "system", "content": "You are a careful extractor."},
                {"role": "user", "content": "Differentiate y = x^13."}
            ],
            "tools": [
                {"type": "function", "function": {"name": "a", "parameters": {"type": "object"}}},
                {"type": "function", "function": {"name": "b", "parameters": {"type": "object"}}}
            ]
        });
        let out = anthropic_body_from_openai(&body, false);
        let tools = out["tools"].as_array().unwrap();
        assert!(!marked(&tools[0]) && marked(&tools[1]), "only the last tool is marked: {tools:?}");
        assert!(marked(&out["system"][0]), "system becomes a marked text block: {}", out["system"]);
        assert_eq!(out["system"][0]["text"], "You are a careful extractor.");
        let last = &out["messages"][0]["content"];
        assert!(marked(&last[0]), "the final user text is marked: {last}");
        assert_eq!(last[0]["text"], "Differentiate y = x^13.");
        assert_eq!(count_marks(&out), 3, "three breakpoints of the four allowed");
    }

    #[test]
    fn marks_the_last_tool_result_block_and_skips_absent_parts() {
        let body = serde_json::json!({
            "model": "claude-sonnet-5-5",
            "messages": [
                {"role": "user", "content": "go"},
                {"role": "assistant", "content": "", "tool_calls": [
                    {"id": "t1", "function": {"name": "a", "arguments": "{}"}},
                    {"id": "t2", "function": {"name": "a", "arguments": "{}"}}
                ]},
                {"role": "tool", "tool_call_id": "t1", "content": "one"},
                {"role": "tool", "tool_call_id": "t2", "content": "two"}
            ]
        });
        let out = anthropic_body_from_openai(&body, true);
        assert!(out.get("tools").is_none() && out.get("system").is_none());
        let blocks = out["messages"].as_array().unwrap().last().unwrap()["content"].as_array().unwrap().clone();
        assert_eq!(blocks.len(), 2);
        assert!(!marked(&blocks[0]) && marked(&blocks[1]), "only the last tool_result is marked: {blocks:?}");
        assert_eq!(count_marks(&out), 1);
    }

    #[test]
    fn a_single_round_call_marks_no_tail() {
        let body = serde_json::json!({"model": "claude-opus-5-5", "messages": [
            {"role": "system", "content": "Adjudicate."}, {"role": "user", "content": "One record."}]});
        let out = anthropic_body_from_openai(&body, true);
        assert_eq!(out["messages"][0]["content"], "One record.", "the only message stays unmarked: {}", out["messages"]);
        assert_eq!(count_marks(&out), 1, "the system prompt only");
    }

    #[test]
    fn a_cache_break_marks_the_shared_part() {
        let body = serde_json::json!({"model": "claude-opus-5-5", "messages": [
            {"role": "system", "content": "Adjudicate."},
            {"role": "user", "content": "THE SET: 1. x+1\n<<<cache-break>>>\nTHE RECORD: {\"number\": 1}"}]});
        let single = anthropic_body_from_openai(&body, true);
        let blocks = single["messages"][0]["content"].as_array().unwrap().clone();
        assert_eq!(blocks.len(), 2, "split in two: {blocks:?}");
        assert_eq!(blocks[0]["text"], "THE SET: 1. x+1\n");
        assert_eq!(blocks[1]["text"], "THE RECORD: {\"number\": 1}");
        assert!(marked(&blocks[0]) && !marked(&blocks[1]), "the shared part is marked, the record is not: {blocks:?}");
        assert_eq!(count_marks(&single), 2);
        let session = anthropic_body_from_openai(&body, false);
        let blocks = session["messages"][0]["content"].as_array().unwrap().clone();
        assert!(marked(&blocks[0]) && marked(&blocks[1]), "with tools on, the tail is marked too: {blocks:?}");
    }

    #[test]
    fn a_cache_break_in_history_is_removed() {
        let body = serde_json::json!({"model": "claude-haiku-5-5", "messages": [
            {"role": "user", "content": "A\n<<<cache-break>>>\nB"},
            {"role": "assistant", "content": "ok"},
            {"role": "user", "content": "C\n<<<cache-break>>>\nD"}]});
        let out = anthropic_body_from_openai(&body, false);
        assert_eq!(out["messages"][0]["content"], "A\nB", "an older marked message is stripped: {}", out["messages"]);
        let last = out["messages"][2]["content"].as_array().unwrap().clone();
        assert_eq!(last[0]["text"], "C\n");
        assert!(marked(&last[0]) && marked(&last[1]), "the newest is split, its tail marked (tools on): {last:?}");
        assert!(!out.to_string().contains(super::CACHE_BREAK));
        let mut msgs = vec![serde_json::json!({"role": "user", "content": [{"type": "text", "text": "x\n<<<cache-break>>>\ny"}]})];
        super::strip_cache_break_in(&mut msgs);
        assert_eq!(msgs[0]["content"][0]["text"], "x\ny");
    }

    #[test]
    fn a_stage_call_followed_by_a_notice_shares_its_set() {
        let body = serde_json::json!({"model": "claude-opus-5-5", "messages": [
            {"role": "system", "content": "Adjudicate."},
            {"role": "user", "content": "THE SET\n<<<cache-break>>>\nTHE RECORD"},
            {"role": "user", "content": "[STEWARD NOTICE] pressure"}]});
        let out = anthropic_body_from_openai(&body, true);
        let stage = out["messages"][0]["content"].as_array().unwrap().clone();
        assert!(marked(&stage[0]) && !marked(&stage[1]), "the set is marked, the record not: {stage:?}");
        assert_eq!(out["messages"][1]["content"], "[STEWARD NOTICE] pressure", "the notice is not marked");
        assert_eq!(count_marks(&out), 2, "system and the shared set");
    }
}

#[cfg(test)]
mod batch_tests {
    // v66: a batch result's message reads like a streamed reply, and the params
    // a batch sends are the immediate body without `stream`.
    use super::{anthropic_batch_params, completion_from_anthropic_message, valid_batch_id};

    #[test]
    fn batch_message_becomes_a_completion() {
        let msg = serde_json::json!({
            "id": "msg_01", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
            "content": [
                {"type": "thinking", "thinking": "Item 15 is on page 40.", "signature": "x"},
                {"type": "text", "text": "{\"quote\": "},
                {"type": "text", "text": "\"Find x.\"}"}
            ],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 1200, "output_tokens": 90, "cache_creation_input_tokens": 0,
                      "cache_read_input_tokens": 800, "output_tokens_details": {"thinking_tokens": 40}}
        });
        let c = completion_from_anthropic_message(&msg);
        assert_eq!(c["choices"][0]["message"]["content"], "{\"quote\": \"Find x.\"}");
        assert_eq!(c["choices"][0]["message"]["reasoning_content"], "Item 15 is on page 40.");
        assert_eq!(c["choices"][0]["finish_reason"], "stop");
        assert_eq!(c["model"], "claude-haiku-5-5");
        assert_eq!(c["usage"]["prompt_tokens"], 1200);
        assert_eq!(c["usage"]["completion_tokens"], 90);
        assert_eq!(c["usage"]["cache_read_input_tokens"], 800);
        assert_eq!(c["usage"]["completion_tokens_details"]["reasoning_tokens"], 40);
        assert!(c["choices"][0]["message"].get("tool_calls").is_none());
    }

    #[test]
    fn batch_params_drop_stream_and_keep_options() {
        let payload = serde_json::json!({
            "tools_disabled": true,
            "body": {
                "model": "claude-haiku-5-5", "max_tokens": 4096,
                "messages": [{"role": "system", "content": "Extract."}, {"role": "user", "content": "Chapter 1."}],
                "tools": [{"type": "function", "function": {"name": "t", "parameters": {}}}],
                "anthropic_options": {"output_config": {"effort": "low"}}
            }
        });
        let p = anthropic_batch_params(&payload).unwrap();
        assert!(p.get("stream").is_none());
        assert!(p.get("tools").is_none());
        assert_eq!(p["output_config"]["effort"], "low");
        assert_eq!(p["model"], "claude-haiku-5-5");
    }

    #[test]
    fn batch_ids_are_path_safe() {
        assert!(valid_batch_id("msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d"));
        assert!(!valid_batch_id("../../v1/files"));
        assert!(!valid_batch_id("a?b"));
        assert!(!valid_batch_id(""));
    }
}

#[cfg(test)]
mod anthropic_image_tests {
    // v64: a stage that shows images sends OpenAI image_url parts; the anthropic
    // body must carry them as image blocks.
    use super::{anthropic_body_from_openai, sniff_image};

    #[test]
    fn image_url_parts_become_image_blocks() {
        let body = serde_json::json!({
            "model": "claude-haiku-5-5",
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": "Quote item 15."},
                {"type": "image_url", "image_url": {"url": "data:image/png;base64,iVBORw0KGgo="}},
                {"type": "image_url", "image_url": {"url": "https://archive.org/download/x/page/n79_w1400.jpg"}}
            ]}]
        });
        let out = anthropic_body_from_openai(&body, true);
        let c = out["messages"][0]["content"].as_array().unwrap();
        assert_eq!(c.len(), 3);
        assert_eq!(c[0]["type"], "text");
        assert_eq!(c[0]["text"], "Quote item 15.");
        assert_eq!(
            c[1]["source"],
            serde_json::json!({"type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="})
        );
        assert_eq!(c[2]["type"], "image");
        assert_eq!(c[2]["source"]["type"], "url");
        assert_eq!(c[2]["source"]["url"], "https://archive.org/download/x/page/n79_w1400.jpg");
        assert_eq!(c[2]["cache_control"]["type"], "ephemeral", "the breakpoint lands on the last block: {c:?}");
    }

    #[test]
    fn anthropic_options_pass_only_effort_and_thinking() {
        // v65: agents.anthropic_options reaches the request as output_config and thinking, nothing else.
        let body = serde_json::json!({
            "model": "claude-haiku-5-5",
            "messages": [{"role": "user", "content": "x"}],
            "anthropic_options": {
                "output_config": {"effort": "low"},
                "thinking": {"type": "disabled"},
                "model": "smuggled"
            }
        });
        let out = anthropic_body_from_openai(&body, true);
        assert_eq!(out["output_config"], serde_json::json!({"effort": "low"}));
        assert_eq!(out["thinking"], serde_json::json!({"type": "disabled"}));
        assert_eq!(out["model"], "claude-haiku-5-5", "the options cannot replace the model");
        assert!(out.get("anthropic_options").is_none());
    }

    #[test]
    fn string_content_is_unchanged_by_parts_handling() {
        let body = serde_json::json!({"model": "m", "messages": [{"role": "user", "content": "plain"}]});
        let out = anthropic_body_from_openai(&body, true);
        assert_eq!(out["messages"][0]["content"][0]["text"], "plain");
        assert!(out["messages"][0]["content"][0].get("source").is_none());
    }

    #[test]
    fn only_public_addresses_pass() {
        use super::is_public_ip;
        for ip in ["127.0.0.1", "10.1.2.3", "172.20.0.4", "192.168.1.1", "169.254.169.254", "100.110.60.2",
                   "100.64.0.1", "0.0.0.0", "255.255.255.255", "224.0.0.1", "::1", "::", "fc00::1", "fd12::1",
                   "fe80::1", "::ffff:10.0.0.1", "::ffff:127.0.0.1", "2001:db8::1"] {
            assert!(!is_public_ip(ip.parse().unwrap()), "{ip} must be refused");
        }
        for ip in ["8.8.8.8", "207.241.224.2", "100.63.255.255", "100.128.0.1", "2606:4700::1111"] {
            assert!(is_public_ip(ip.parse().unwrap()), "{ip} is public");
        }
    }

    #[test]
    fn non_http_and_internal_literals_are_refused_before_any_request() {
        use super::fetch_image;
        for url in ["ftp://example.org/x.jpg", "file:///etc/passwd", "http://127.0.0.1:5432/x.png",
                    "http://[::1]/x.png", "http://169.254.169.254/latest/meta-data/", "http://100.110.60.2:8090/"] {
            let e = fetch_image(url).expect_err(url);
            assert_eq!(e.0, "refused", "{url}: {e:?}");
        }
    }

    #[test]
    fn sniffs_media_type_from_magic_bytes() {
        assert_eq!(sniff_image(&[0xFF, 0xD8, 0xFF, 0xE0]), Some("image/jpeg"));
        assert_eq!(sniff_image(b"\x89PNG\r\n\x1a\n"), Some("image/png"));
        assert_eq!(sniff_image(b"GIF89a"), Some("image/gif"));
        assert_eq!(sniff_image(b"RIFF\x00\x00\x00\x00WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniff_image(b"<!DOCTYPE html>"), None, "a 404 page is not an image");
    }
}

#[cfg(test)]
mod dsml_tests {
    // #362: DeepSeek V4 DSML tool-call markup leaking as assistant text.
    use super::translate_dsml_tool_calls;

    // ｜ is U+FF5C (fullwidth vertical bar). The token DeepSeek emits is
    // `｜DSML｜`; build fixtures from it so the bytes are exactly right.
    const TOK: &str = "\u{ff5c}DSML\u{ff5c}";

    #[test]
    fn translates_a_clean_single_tool_call() {
        let f = format!(
            "<{t}tool_calls>\n<{t}invoke name=\"get_current_weather\">\n\
             <{t}parameter name=\"location\" string=\"true\">Tokyo</{t}parameter>\n\
             </{t}invoke>\n</{t}tool_calls>",
            t = TOK
        );
        let (calls, cleaned) =
            translate_dsml_tool_calls(&f).expect("clean block must translate");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["function"]["name"], "get_current_weather");
        let args: serde_json::Value = serde_json::from_str(
            calls[0]["function"]["arguments"].as_str().unwrap(),
        )
        .unwrap();
        assert_eq!(args["location"], "Tokyo");
        assert!(cleaned.is_empty(), "cleaned content should be empty: {cleaned:?}");
    }

    #[test]
    fn non_string_parameter_is_a_json_literal() {
        let f = format!(
            "<{t}tool_calls><{t}invoke name=\"set\">\
             <{t}parameter name=\"count\" string=\"false\">3</{t}parameter>\
             <{t}parameter name=\"on\" string=\"false\">true</{t}parameter>\
             </{t}invoke></{t}tool_calls>",
            t = TOK
        );
        let (calls, _) = translate_dsml_tool_calls(&f).expect("must translate");
        let args: serde_json::Value = serde_json::from_str(
            calls[0]["function"]["arguments"].as_str().unwrap(),
        )
        .unwrap();
        assert_eq!(args["count"], 3);
        assert_eq!(args["on"], true);
    }

    #[test]
    fn translates_multiple_invokes() {
        let f = format!(
            "prelude <{t}tool_calls>\
             <{t}invoke name=\"a\"><{t}parameter name=\"x\" string=\"true\">1</{t}parameter></{t}invoke>\
             <{t}invoke name=\"b\"></{t}invoke>\
             </{t}tool_calls>",
            t = TOK
        );
        let (calls, cleaned) = translate_dsml_tool_calls(&f).expect("must translate");
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0]["function"]["name"], "a");
        assert_eq!(calls[1]["function"]["name"], "b");
        // an invoke with no parameters yields an empty args object
        assert_eq!(calls[1]["function"]["arguments"], "{}");
        assert_eq!(cleaned, "prelude");
    }

    #[test]
    fn passthrough_on_unclosed_block() {
        let f = format!(
            "<{t}tool_calls><{t}invoke name=\"x\">(never closed)",
            t = TOK
        );
        assert!(
            translate_dsml_tool_calls(&f).is_none(),
            "an unclosed block must pass through unchanged"
        );
    }

    #[test]
    fn passthrough_on_bare_word_in_prose() {
        // The word "DSML" in ordinary prose is not a tool_calls block.
        assert!(translate_dsml_tool_calls("I read about the DSML spec today.").is_none());
        assert!(translate_dsml_tool_calls("no markup here at all").is_none());
    }

    #[test]
    fn passthrough_on_non_json_literal_value() {
        // string="false" with a value that is not valid JSON => refuse.
        let f = format!(
            "<{t}tool_calls><{t}invoke name=\"x\">\
             <{t}parameter name=\"p\" string=\"false\">not-json</{t}parameter>\
             </{t}invoke></{t}tool_calls>",
            t = TOK
        );
        assert!(translate_dsml_tool_calls(&f).is_none());
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
        let mut b = anthropic_body_from_openai(&body_sane, tools_disabled);
        inline_remote_images(&mut b);
        b
    } else {
        let mut b = body_sane.clone();
        if let serde_json::Value::Object(ref mut m) = b {
            // v65: Anthropic request settings mean nothing to an OpenAI-format provider.
            m.remove("anthropic_options");
            // v68: the cache-break line is an anthropic split point, plain text anywhere else.
            if let Some(msgs) = m.get_mut("messages").and_then(|v| v.as_array_mut()) {
                strip_cache_break_in(msgs);
            }
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

    let body_model = body.get("model").and_then(|v| v.as_str()).unwrap_or("?");
    outcome_from_completion(parsed, body_model, session_id, agent_family, requested_model)
}

/// A completion in the OpenAI chat.completion shape (what both SSE parsers and
/// the batch result reader produce) as a WorkOutcome::Chatted.
fn outcome_from_completion(
    mut parsed: serde_json::Value,
    body_model: &str,
    session_id: String,
    agent_family: String,
    requested_model: String,
) -> Result<WorkOutcome, String> {
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
    let mut assistant_content = message
        .get("content")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let mut assistant_tool_calls = message.get("tool_calls").cloned();
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
        .unwrap_or(body_model)
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
    // Set by parse_anthropic_sse: Anthropic's thinking tokens are part of
    // output_tokens, unlike kimi/o1 reasoning tokens.
    let reasoning_in_completion = usage
        .and_then(|u| u.get("completion_tokens_details"))
        .and_then(|d| d.get("reasoning_included_in_completion"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

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

    // #362: DSML tool-call leak recovery. When the gateway gave us NO
    // structured tool_calls but the assistant text carries DeepSeek's native
    // DSML tool_calls block, translate it into the normal structure so the
    // tool loop fires. Conservative: only when the block parses cleanly.
    let has_structured_calls = assistant_tool_calls
        .as_ref()
        .and_then(|v| v.as_array())
        .map(|a| !a.is_empty())
        .unwrap_or(false);
    if !has_structured_calls && !assistant_content.is_empty() {
        match translate_dsml_tool_calls(&assistant_content) {
            Some((calls, cleaned)) => {
                pgrx::log!(
                    "stewards: recovered {} DSML tool_call(s) that leaked as assistant text (deepseek native markup via openai-compat gateway) — executing instead of passing through as content",
                    calls.len()
                );
                let calls_val = serde_json::Value::Array(calls);
                // Keep the stored response object consistent so trace/telemetry
                // and any re-parse of result.response see structured tool_calls
                // and cleaned content, not the raw markup.
                if let Some(msg) = parsed.pointer_mut("/choices/0/message") {
                    msg["content"] = if cleaned.is_empty() {
                        serde_json::Value::Null
                    } else {
                        serde_json::Value::String(cleaned.clone())
                    };
                    msg["tool_calls"] = calls_val.clone();
                }
                assistant_content = cleaned;
                assistant_tool_calls = Some(calls_val);
            }
            None => {
                // Not a clean DSML block — leave the text intact. Only note it
                // when the tell-tale token is present, so a normal text turn
                // stays silent.
                if assistant_content.contains("DSML")
                    || assistant_content.contains("\u{2581}tool\u{2581}calls")
                {
                    pgrx::log!(
                        "stewards: assistant text contains DSML-like markers but did not parse cleanly as a tool_calls block — left as text (no translation)"
                    );
                }
            }
        }
    }

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
        reasoning_in_completion,
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
    parse_chat_sse_reader(std::io::BufReader::new(resp))
}

/// Inner body of `parse_chat_sse`, generic over the byte source so the parse
/// can be unit-tested against an in-memory SSE fixture (see `sse_tests`)
/// without constructing a live `reqwest::blocking::Response`.
fn parse_chat_sse_reader<R: std::io::BufRead>(
    reader: R,
) -> Result<serde_json::Value, String> {
    let mut content = String::new();
    let mut reasoning = String::new();
    let mut role = String::from("assistant");
    let mut finish_reason: Option<String> = None;
    let mut model: Option<String> = None;
    let mut usage: Option<serde_json::Value> = None;
    let mut tool_calls: Vec<ToolCallAccum> = Vec::new();
    // #361: the SSE event type of the frame currently being read. Per the SSE
    // spec an `event:` field sets the type for the event dispatched at the
    // next blank line (which resets it). A named `event: error` frame carries
    // an upstream error in its `data:` payload; that payload must terminate
    // the parse — not be dropped as an unknown-shaped chunk or read as content.
    let mut current_event: Option<String> = None;

    for line in reader.lines() {
        let line = line.map_err(|e| format!("sse read: {}", e))?;
        let line = line.trim_end();
        if line.is_empty() {
            // Dispatch boundary: the event type does not carry across frames.
            current_event = None;
            continue;
        }
        // Track named SSE event types. The payload rides `data:`; `id:` and
        // comment lines are ignored — but a named `event:` (notably
        // `event: error`) changes how the following `data:` is routed, so it
        // must be captured, not skipped as "not a data line".
        if let Some(ev) = line.strip_prefix("event:") {
            current_event = Some(ev.trim().to_string());
            continue;
        }
        // SSE: only `data:` fields carry payload; ignore id:/comments.
        let data = match line.strip_prefix("data:") {
            Some(d) => d.trim(),
            None => continue,
        };
        if data == "[DONE]" {
            break;
        }
        // #361: a named `event: error` frame routes its payload to error
        // handling. Terminate the parse and surface the payload verbatim so an
        // upstream mid-stream error can never be silently dropped (unknown
        // shape → no `choices` → `continue`) or mis-read as assistant content.
        if current_event.as_deref() == Some("error") {
            return Err(format!("sse error event: {}", data));
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

/// #362: recover DeepSeek's native "DSML" tool-call markup that leaks as
/// assistant TEXT through some OpenAI-compat gateways (opencode_go / Console
/// Go) when tools+stream are combined — the gateway forwards the model's
/// native serialization verbatim instead of parsing it into a `tool_calls`
/// array, so the substrate's tool loop never fires and the turn ends
/// verdict-less (live evidence: queue rows 43904/43906, 2026-07-09).
///
/// The V4 block is Anthropic-tool-use-shaped (verified against
/// deepseek-ai/DeepSeek-V4-Pro `encoding/encoding_dsv4.py`):
///
/// ```text
/// <｜DSML｜tool_calls>
/// <｜DSML｜invoke name="TOOL_NAME">
/// <｜DSML｜parameter name="P" string="true">VALUE</｜DSML｜parameter>
/// ...
/// </｜DSML｜invoke>
/// </｜DSML｜tool_calls>
/// ```
///
/// where `｜` is U+FF5C (a FULLWIDTH vertical bar, not an ASCII pipe) and the
/// `DSML` token may be wrapped in one or more of them. We derive the exact
/// token from the opening marker and match it on every inner tag, so the
/// parser is robust to the wrap count.
///
/// Conservative by contract: returns `None` (caller leaves the text intact and
/// logs) unless the block parses CLEANLY into ≥1 tool call. Never emits a
/// partial translation. On success returns the OpenAI-shaped `tool_calls`
/// array plus the assistant content with the block removed.
fn translate_dsml_tool_calls(
    content: &str,
) -> Option<(Vec<serde_json::Value>, String)> {
    // Locate the "DSML" token and the run of fullwidth (or, defensively,
    // ASCII) vertical bars around it. Require ≥1 bar on each side so the bare
    // word "DSML" in prose does not match.
    let is_bar = |c: char| c == '\u{ff5c}' || c == '|';
    let dsml_at = content.find("DSML")?;
    // left bar run
    let mut left = dsml_at;
    for (idx, ch) in content[..dsml_at].char_indices().rev() {
        if is_bar(ch) {
            left = idx;
        } else {
            break;
        }
    }
    if left == dsml_at {
        return None; // no leading bar
    }
    // right bar run
    let after_dsml = dsml_at + "DSML".len();
    let mut right = after_dsml;
    for (idx, ch) in content[after_dsml..].char_indices() {
        if is_bar(ch) {
            right = after_dsml + idx + ch.len_utf8();
        } else {
            break;
        }
    }
    if right == after_dsml {
        return None; // no trailing bar
    }
    // token = "｜DSML｜" (whatever wrap count was found). The tag prefixes are
    // built from it so open/close markers use the identical token.
    let token = &content[left..right];
    let open_tc = format!("<{token}tool_calls>");
    let close_tc = format!("</{token}tool_calls>");
    let open_invoke = format!("<{token}invoke");
    let close_invoke = format!("</{token}invoke>");
    let open_param = format!("<{token}parameter");
    let close_param = format!("</{token}parameter>");

    // The block must have both a well-formed open and close.
    let block_start = content.find(&open_tc)?;
    let tc_open_end = block_start + open_tc.len();
    let close_rel = content[tc_open_end..].find(&close_tc)?;
    let block_end = tc_open_end + close_rel; // start of close_tc
    let block_body = &content[tc_open_end..block_end];

    // Read an attribute value: `name="..."` starting from a tag slice.
    let attr = |tag: &str, key: &str| -> Option<String> {
        let needle = format!("{key}=\"");
        let s = tag.find(&needle)? + needle.len();
        let e = tag[s..].find('"')? + s;
        Some(tag[s..e].to_string())
    };

    let mut calls: Vec<serde_json::Value> = Vec::new();
    let mut cursor = 0usize;
    while let Some(inv_rel) = block_body[cursor..].find(&open_invoke) {
        let inv_start = cursor + inv_rel;
        // tag runs from `<..invoke` to the next '>'
        let tag_gt_rel = block_body[inv_start..].find('>')?;
        let tag_end = inv_start + tag_gt_rel; // index of '>'
        let inv_tag = &block_body[inv_start..tag_end];
        let name = attr(inv_tag, "name")?;
        if name.is_empty() {
            return None;
        }
        let body_start = tag_end + 1; // past '>'
        let inv_close_rel = block_body[body_start..].find(&close_invoke)?;
        let inv_body_end = body_start + inv_close_rel;
        let inv_body = &block_body[body_start..inv_body_end];

        // Parameters -> an arguments object.
        let mut args = serde_json::Map::new();
        let mut pcur = 0usize;
        while let Some(p_rel) = inv_body[pcur..].find(&open_param) {
            let p_start = pcur + p_rel;
            let p_gt_rel = inv_body[p_start..].find('>')?;
            let p_tag_end = p_start + p_gt_rel;
            let p_tag = &inv_body[p_start..p_tag_end];
            let p_name = attr(p_tag, "name")?;
            if p_name.is_empty() {
                return None;
            }
            // `string="true"` => the value is a literal string; `false` => the
            // value is a raw JSON literal (number/bool/object/array/null).
            // Default (attribute absent) to string, the safe interpretation.
            let is_string = attr(p_tag, "string")
                .map(|s| s != "false")
                .unwrap_or(true);
            let p_body_start = p_tag_end + 1;
            let p_close_rel = inv_body[p_body_start..].find(&close_param)?;
            let raw = &inv_body[p_body_start..p_body_start + p_close_rel];
            let value = if is_string {
                serde_json::Value::String(raw.to_string())
            } else {
                // Clean-parse contract: a non-string value that isn't valid
                // JSON means the block is malformed — refuse the whole
                // translation rather than guess.
                serde_json::from_str::<serde_json::Value>(raw.trim()).ok()?
            };
            args.insert(p_name, value);
            pcur = p_body_start + p_close_rel + close_param.len();
        }

        let arguments = serde_json::to_string(&serde_json::Value::Object(args))
            .ok()?;
        calls.push(serde_json::json!({
            "id": format!("dsml_call_{}", calls.len()),
            "type": "function",
            "function": { "name": name, "arguments": arguments },
        }));

        cursor = inv_body_end + close_invoke.len();
    }

    if calls.is_empty() {
        return None;
    }

    // Cleaned content: everything outside the block (prose the model emitted
    // before/after the markup), trimmed. Usually empty for a tool-call turn.
    let mut cleaned = String::with_capacity(content.len());
    // the block spans from the '<' of open_tc to the end of close_tc
    cleaned.push_str(&content[..block_start]);
    cleaned.push_str(&content[block_end + close_tc.len()..]);
    Some((calls, cleaned.trim().to_string()))
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

            // Plain user/assistant text. Content stays a string; content parts (a
            // stage that shows images, v64) are translated part by part.
            let content = match m.get("content") {
                Some(serde_json::Value::Array(parts)) => {
                    serde_json::Value::Array(parts.iter().map(anthropic_part).collect())
                }
                Some(c) => c.clone(),
                None => serde_json::Value::String(String::new()),
            };
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
    // Several composers write 'temperature', v_agent.temperature unconditionally,
    // so an agent with no temperature arrives here as null. Omit it then: Claude
    // 5.5 models reject the field outright.
    if let Some(temp) = body_orig.get("temperature").filter(|t| !t.is_null()) {
        out["temperature"] = temp.clone();
    }
    // v65: the agent's effort and thinking settings (agents.anthropic_options, copied in by the queue
    // trigger). Only these two keys pass; a model that rejects a value answers 400 and the row fails.
    if let Some(opts) = body_orig.get("anthropic_options").and_then(|v| v.as_object()) {
        for key in ["output_config", "thinking"] {
            if let Some(v) = opts.get(key) {
                out[key] = v.clone();
            }
        }
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
    // v68: a tools-off request with no reply in it yet is the whole conversation (a stage's single call,
    // which compose may follow with a short notice); nothing will ever read its tail back from the cache.
    let single_round = is_single_round(tools_disabled, &out);
    add_cache_breakpoints(&mut out, single_round);
    out
}

/// One OpenAI content part as an Anthropic block. An image_url part becomes an
/// image block: a base64 data: URI keeps its bytes, any other URL becomes a url
/// source (inline_remote_images swaps it for base64 before sending). Text parts,
/// and parts already in Anthropic's shape, pass through.
fn anthropic_part(p: &serde_json::Value) -> serde_json::Value {
    if p.get("type").and_then(|t| t.as_str()) != Some("image_url") {
        return p.clone();
    }
    let url = p
        .get("image_url")
        .and_then(|u| u.get("url"))
        .and_then(|u| u.as_str())
        .unwrap_or("");
    if let Some((meta, data)) = url.strip_prefix("data:").and_then(|r| r.split_once(',')) {
        if let Some(media_type) = meta.strip_suffix(";base64") {
            return serde_json::json!({
                "type": "image",
                "source": { "type": "base64", "media_type": media_type, "data": data },
            });
        }
    }
    serde_json::json!({ "type": "image", "source": { "type": "url", "url": url } })
}

/// Anthropic downloads url image sources itself and times out on slow hosts
/// (archive.org page images, 2026-10-10: "The request timed out while trying to
/// download the file"), so the worker downloads each one and sends it as base64.
/// The download is the worker reaching out on an input's say-so, so it is fenced:
/// http(s) only; the host must resolve to public addresses only, the connection
/// is pinned to the address that was checked, and every redirect hop is checked
/// again; the read stops at the size limit; a short timeout; at most
/// MAX_IMAGES_PER_MESSAGE per message. An image that is refused or fails becomes
/// a text note naming the kind of failure (never the URL or an address), so an
/// internal URL never reaches the provider; the details go to the log.
fn inline_remote_images(body: &mut serde_json::Value) {
    let Some(msgs) = body.get_mut("messages").and_then(|m| m.as_array_mut()) else {
        return;
    };
    for m in msgs.iter_mut() {
        let Some(blocks) = m.get_mut("content").and_then(|c| c.as_array_mut()) else {
            continue;
        };
        let mut images = 0;
        for b in blocks.iter_mut() {
            if b.get("type").and_then(|t| t.as_str()) != Some("image") {
                continue;
            }
            images += 1;
            if b.pointer("/source/type").and_then(|t| t.as_str()) != Some("url") {
                continue;
            }
            let url = b.pointer("/source/url").and_then(|u| u.as_str()).unwrap_or("").to_owned();
            let fetched = if images > MAX_IMAGES_PER_MESSAGE {
                Err(("refused", format!("more than {} images in one message", MAX_IMAGES_PER_MESSAGE)))
            } else {
                fetch_image(&url)
            };
            match fetched {
                Ok((media_type, bytes)) => {
                    use base64::Engine as _;
                    b["source"] = serde_json::json!({
                        "type": "base64",
                        "media_type": media_type,
                        "data": base64::engine::general_purpose::STANDARD.encode(bytes),
                    });
                }
                Err((kind, detail)) => {
                    pgrx::warning!("stewards: image not sent ({}: {}): {}", kind, detail, url);
                    *b = serde_json::json!({ "type": "text", "text": format!("[image not sent: {}]", kind) });
                }
            }
        }
    }
}

/// Anthropic's limit is 5 MB per image.
const MAX_IMAGE_BYTES: u64 = 5 * 1024 * 1024;
/// A dispatcher thread waits on these downloads, so they are few and quick.
const MAX_IMAGES_PER_MESSAGE: usize = 8;
const IMAGE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(25);
const MAX_IMAGE_REDIRECTS: usize = 3;

/// (the kind the model is told: refused | unavailable | too large | not an image, the detail for the log)
type ImageFetchError = (&'static str, String);

fn fetch_image(url: &str) -> Result<(&'static str, Vec<u8>), ImageFetchError> {
    let mut url = reqwest::Url::parse(url).map_err(|e| ("refused", format!("not a URL: {e}")))?;
    for _hop in 0..=MAX_IMAGE_REDIRECTS {
        let (host, addr) = vet_image_url(&url)?;
        let client = reqwest::blocking::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(IMAGE_TIMEOUT)
            .resolve(&host, addr)
            .build()
            .map_err(|e| ("unavailable", e.to_string()))?;
        let resp = client.get(url.clone()).send().map_err(|e| ("unavailable", e.to_string()))?;
        if resp.status().is_redirection() {
            let location = resp
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or(("unavailable", format!("HTTP {} with no Location", resp.status())))?;
            url = url.join(location).map_err(|e| ("refused", format!("bad redirect target: {e}")))?;
            continue;
        }
        if !resp.status().is_success() {
            return Err(("unavailable", format!("HTTP {}", resp.status())));
        }
        if resp.content_length().is_some_and(|n| n > MAX_IMAGE_BYTES) {
            return Err(("too large", format!("Content-Length over {MAX_IMAGE_BYTES} bytes")));
        }
        let mut bytes = Vec::new();
        use std::io::Read as _;
        resp.take(MAX_IMAGE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| ("unavailable", e.to_string()))?;
        if bytes.len() as u64 > MAX_IMAGE_BYTES {
            return Err(("too large", format!("body over {MAX_IMAGE_BYTES} bytes")));
        }
        let media_type = sniff_image(&bytes).ok_or(("not an image", "not a JPEG, PNG, GIF or WebP".to_string()))?;
        return Ok((media_type, bytes));
    }
    Err(("unavailable", format!("more than {MAX_IMAGE_REDIRECTS} redirects")))
}

/// The host and the one address the download may connect to: http(s) only, and
/// every address the host resolves to must be public (one private answer refuses
/// the host, so a name that mixes public and internal records cannot be raced).
fn vet_image_url(url: &reqwest::Url) -> Result<(String, std::net::SocketAddr), ImageFetchError> {
    if url.scheme() != "http" && url.scheme() != "https" {
        return Err(("refused", format!("scheme {} is not http(s)", url.scheme())));
    }
    let host = url.host_str().ok_or(("refused", "no host".to_string()))?.to_owned();
    let port = url.port_or_known_default().unwrap_or(443);
    use std::net::ToSocketAddrs as _;
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    let addrs: Vec<std::net::SocketAddr> = (bare, port)
        .to_socket_addrs()
        .map_err(|e| ("unavailable", format!("cannot resolve {host}: {e}")))?
        .collect();
    let first = *addrs.first().ok_or(("unavailable", format!("{host} resolves to nothing")))?;
    if let Some(bad) = addrs.iter().find(|a| !is_public_ip(a.ip())) {
        return Err(("refused", format!("{host} resolves to {} (not a public address)", bad.ip())));
    }
    Ok((host, first))
}

/// A globally routable unicast address. Refused: loopback, private (RFC 1918),
/// link-local (169.254/16 holds cloud metadata), CGNAT 100.64/10 (the NetBird
/// mesh range), 0/8, 192.0.0/24, benchmarking 198.18/15, 240/4 and broadcast,
/// documentation, multicast, unspecified; for IPv6, ::1, ::, multicast,
/// unique-local fc00::/7, link-local fe80::/10 and 2001:db8::/32. An IPv4-mapped
/// IPv6 address is judged as its IPv4.
fn is_public_ip(ip: std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(v4) => {
            let o = v4.octets();
            !(v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || v4.is_multicast()
                || v4.is_documentation()
                || o[0] == 0
                || (o[0] == 100 && (o[1] & 0xC0) == 64)
                || (o[0] == 192 && o[1] == 0 && o[2] == 0)
                || (o[0] == 198 && (o[1] & 0xFE) == 18)
                || o[0] >= 240)
        }
        std::net::IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_public_ip(std::net::IpAddr::V4(v4));
            }
            let s = v6.segments();
            !(v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (s[0] & 0xfe00) == 0xfc00
                || (s[0] & 0xffc0) == 0xfe80
                || (s[0] == 0x2001 && s[1] == 0x0db8))
        }
    }
}

/// The media type from the file's own magic bytes (a server's Content-Type is not trusted).
fn sniff_image(b: &[u8]) -> Option<&'static str> {
    if b.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if b.starts_with(&[0x89, b'P', b'N', b'G']) {
        Some("image/png")
    } else if b.starts_with(b"GIF8") {
        Some("image/gif")
    } else if b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

/// Prompt caching: mark three points of the request (of the four Anthropic
/// allows) so the stable prefix is read from cache on the next turn at the
/// cache-read rate: the last tool definition, the system block, and the last
/// content block of the final message (a tool loop's history grows by
/// appending, so this turn's end is the next turn's cached prefix). A prefix
/// shorter than the model's minimum cacheable length is simply not cached.
/// The default 5-minute TTL is used; the 1-hour TTL ("ttl": "1h") bills
/// writes at 2x input instead of 1.25x and is left off.
/// v68: a line a stage template puts between the text its calls share (an exercise set, a chapter) and
/// the text each call adds (one record). The anthropic translator splits the message there and marks the
/// shared part for the prompt cache, so calls on the same set read it back instead of writing it again;
/// every other path removes the line.
const CACHE_BREAK: &str = "<<<cache-break>>>";

/// The text with the cache-break line removed (with its newline, when it stands on a line of its own).
fn strip_cache_break(t: &str) -> String {
    t.replace(&format!("{CACHE_BREAK}\n"), "").replace(CACHE_BREAK, "")
}

/// Removes the cache-break line from every text a body's messages carry (strings and text parts). The
/// OpenAI path and the earlier messages of an anthropic body use it.
fn strip_cache_break_in(msgs: &mut [serde_json::Value]) {
    for m in msgs.iter_mut() {
        match m.get_mut("content") {
            Some(serde_json::Value::String(t)) if t.contains(CACHE_BREAK) => *t = strip_cache_break(t),
            Some(serde_json::Value::Array(parts)) => {
                for p in parts.iter_mut() {
                    if let Some(serde_json::Value::String(t)) = p.get_mut("text") {
                        if t.contains(CACHE_BREAK) {
                            *t = strip_cache_break(t);
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

fn is_single_round(tools_disabled: bool, out: &serde_json::Value) -> bool {
    tools_disabled && !out["messages"].as_array().map_or(false, |m| m.iter().any(|x| x["role"] == "assistant"))
}

fn add_cache_breakpoints(out: &mut serde_json::Value, single_round: bool) {
    let eph = serde_json::json!({ "type": "ephemeral" });
    if let Some(last) = out
        .get_mut("tools")
        .and_then(|v| v.as_array_mut())
        .and_then(|a| a.last_mut())
    {
        last["cache_control"] = eph.clone();
    }
    if let Some(s) = out.get("system").and_then(|v| v.as_str()).map(str::to_owned) {
        out["system"] = serde_json::json!([{ "type": "text", "text": s, "cache_control": eph.clone() }]);
    }
    let Some(msgs) = out.get_mut("messages").and_then(|v| v.as_array_mut()) else {
        return;
    };
    let n = msgs.len();
    if n == 0 {
        return;
    }
    // The newest message that carries a cache-break line is split there and its shared part marked; the
    // line is removed from every other message. Compose may follow the stage input with a short notice, so
    // that message need not be the last.
    let target = (0..n).rev().find(|&i| carries_cache_break(&msgs[i]));
    for i in 0..n {
        if Some(i) != target {
            strip_cache_break_in(&mut msgs[i..i + 1]);
        }
    }
    if let Some(k) = target {
        split_at_cache_break(&mut msgs[k], &eph);
    }
    // The tail mark lets the next round read this prefix back (and lets this request read the last round's);
    // a request that is the whole conversation has neither, so it would only pay the cache write.
    if !single_round {
        let last = &mut msgs[n - 1];
        match last.get("content").cloned() {
            Some(serde_json::Value::String(t)) if !t.is_empty() => {
                last["content"] = serde_json::json!([{ "type": "text", "text": t, "cache_control": eph }]);
            }
            Some(serde_json::Value::Array(_)) => {
                if let Some(b) = last.get_mut("content").and_then(|c| c.as_array_mut()).and_then(|a| a.last_mut()) {
                    b["cache_control"] = eph;
                }
            }
            _ => {}
        }
    }
}

fn carries_cache_break(m: &serde_json::Value) -> bool {
    match m.get("content") {
        Some(serde_json::Value::String(t)) => t.contains(CACHE_BREAK),
        Some(serde_json::Value::Array(a)) => a
            .iter()
            .any(|b| b.get("text").and_then(|t| t.as_str()).map_or(false, |t| t.contains(CACHE_BREAK))),
        _ => false,
    }
}

/// The message's first text with a cache-break line becomes a marked shared part and the unmarked rest.
fn split_at_cache_break(m: &mut serde_json::Value, eph: &serde_json::Value) {
    let mut blocks: Vec<serde_json::Value> = match m.get("content").cloned() {
        Some(serde_json::Value::String(t)) => vec![serde_json::json!({ "type": "text", "text": t })],
        Some(serde_json::Value::Array(a)) => a,
        _ => return,
    };
    let Some(k) = blocks
        .iter()
        .position(|b| b.get("text").and_then(|t| t.as_str()).map_or(false, |t| t.contains(CACHE_BREAK)))
    else {
        return;
    };
    let text = blocks[k]["text"].as_str().unwrap_or("").to_string();
    let (head, tail) = text.split_once(CACHE_BREAK).unwrap_or((text.as_str(), ""));
    let tail = tail.strip_prefix('\n').unwrap_or(tail);
    let mut parts = Vec::new();
    if !head.trim().is_empty() {
        parts.push(serde_json::json!({ "type": "text", "text": head, "cache_control": eph.clone() }));
    }
    if !tail.is_empty() {
        parts.push(serde_json::json!({ "type": "text", "text": strip_cache_break(tail) }));
    }
    blocks.splice(k..k + 1, parts);
    m["content"] = serde_json::Value::Array(blocks);
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
    // usage.output_tokens_details.thinking_tokens on the closing message_delta.
    // Claude 5.5 models think by default (Haiku adaptively), and these tokens
    // are part of output_tokens.
    let mut thinking_tokens: Option<i64> = None;
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
                    thinking_tokens = u
                        .get("output_tokens_details")
                        .and_then(|d| d.get("thinking_tokens"))
                        .and_then(|v| v.as_i64())
                        .or(thinking_tokens);
                }
            }
            _ => {} // ping, content_block_start/stop, message_stop
        }
    }

    Ok(anthropic_completion(
        content,
        reasoning,
        tool_uses.into_values().collect(),
        stop_reason,
        model,
        input_tokens,
        output_tokens,
        cache_creation,
        cache_read,
        thinking_tokens,
    ))
}

/// An Anthropic reply, streamed or a batch result's message, in the OpenAI
/// chat.completion shape the rest of the worker reads. tool_uses are
/// (id, name, arguments-json) in content-block order.
#[allow(clippy::too_many_arguments)]
fn anthropic_completion(
    content: String,
    reasoning: String,
    tool_uses: Vec<(String, String, String)>,
    stop_reason: Option<String>,
    model: Option<String>,
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    cache_creation: Option<i64>,
    cache_read: Option<i64>,
    thinking_tokens: Option<i64>,
) -> serde_json::Value {
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
            .iter()
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
    if let Some(t) = thinking_tokens {
        usage.insert(
            "completion_tokens_details".to_string(),
            serde_json::json!({ "reasoning_tokens": t, "reasoning_included_in_completion": true }),
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
    resp_obj["usage"] = serde_json::Value::Object(usage);
    resp_obj
}

/// v66: a Message Batches `succeeded` result's message (a non-streaming
/// Messages API response) in the chat.completion shape.
fn completion_from_anthropic_message(msg: &serde_json::Value) -> serde_json::Value {
    let mut content = String::new();
    let mut reasoning = String::new();
    let mut tool_uses: Vec<(String, String, String)> = Vec::new();
    for block in msg.get("content").and_then(|v| v.as_array()).into_iter().flatten() {
        let text = |k: &str| block.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
        match block.get("type").and_then(|v| v.as_str()) {
            Some("text") => content.push_str(&text("text")),
            Some("thinking") => reasoning.push_str(&text("thinking")),
            Some("tool_use") => tool_uses.push((
                text("id"),
                text("name"),
                block.get("input").map(|v| v.to_string()).unwrap_or_default(),
            )),
            _ => {}
        }
    }
    let usage = msg.get("usage");
    let n = |p: &str| usage.and_then(|u| u.pointer(p)).and_then(|v| v.as_i64());
    anthropic_completion(
        content,
        reasoning,
        tool_uses,
        msg.get("stop_reason").and_then(|v| v.as_str()).map(String::from),
        msg.get("model").and_then(|v| v.as_str()).map(String::from),
        n("/input_tokens"),
        n("/output_tokens"),
        n("/cache_creation_input_tokens"),
        n("/cache_read_input_tokens"),
        n("/output_tokens_details/thinking_tokens"),
    )
}
