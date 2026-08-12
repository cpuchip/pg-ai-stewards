-- =====================================================================
-- tests/bgworker-integration.sql — the dispatcher bgworker's own phase
-- =====================================================================
-- The virgin smoke now runs on a cluster that never preloads the library,
-- so it is deterministic (see its OK 0). That moves a real behaviour out of
-- coverage rather than fixing it — so it lives here instead, where a
-- concurrent writer is the POINT rather than a contaminant.
--
-- RUN THIS ON A PRELOADED CLUSTER:
--   docker run -d --name bg ... stewards-oss-pg:test -c shared_preload_libraries=pg_ai_stewards
--   docker exec -i bg psql -U stewards -d stewards < extension/init/00-bootstrap-roles.sql
--   docker exec -i bg psql -U stewards -d stewards -v ON_ERROR_STOP=1 < tests/bgworker-integration.sql
--
-- BOTH FACES ARE ASSERTED. An oracle that can only pass is not an oracle
-- (item 9's lesson, paid for three times): the positive proves the bell
-- rings on a lifeless install, and the inverse proves it does NOT ring once
-- a provider/model exists — otherwise "the bell rang" would be indis-
-- tinguishable from "this test enqueues a bell".
-- =====================================================================

\echo '== bgworker integration — the dispatcher is SUPPOSED to act here =='

CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE;

-- ── the actor must actually exist, or everything below is vacuous ──────
-- Bounded wait, not an instant assert: the workers are registered at
-- postmaster start but only connect once there is something to connect to,
-- and they carry restart_time=5s — so on a cluster where CREATE EXTENSION
-- just ran (including the line above), they reappear a few seconds later.
-- The first version of this assert fired immediately and failed on a fresh
-- container: the test being wrong about the world, not the world.
--
-- ★ AND pg_stat_clear_snapshot() IS LOAD-BEARING. `stats_fetch_consistency`
-- defaults to 'cache', so the FIRST read of pg_stat_activity in a transaction
-- is cached and every later read in that same transaction returns it —
-- unchanged, forever. The second version of this loop polled for 30s against
-- a snapshot frozen at "0 dispatchers" and reported none had connected while
-- a fresh session in the same container saw four. Distrust a negative from an
-- instrument you just wrote: a polling loop that cannot observe change is not
-- polling, it is repeating itself.
DO $bg1$
DECLARE v_disp int := 0; v_waited int := 0;
BEGIN
    WHILE v_waited < 30 LOOP
        PERFORM pg_stat_clear_snapshot();
        SELECT count(*) INTO v_disp FROM pg_stat_activity
         WHERE backend_type LIKE 'pg_ai_stewards dispatcher%';
        EXIT WHEN v_disp > 0;
        PERFORM pg_sleep(1);
        v_waited := v_waited + 1;
    END LOOP;
    ASSERT v_disp > 0, format(
        'BG 1: no dispatcher bgworker connected within %ss — this phase must run on a cluster started WITH "-c shared_preload_libraries=pg_ai_stewards"; without it every assertion below would pass vacuously', v_waited);
    RAISE NOTICE 'BG 1: % dispatcher bgworker(s) registered and connected (after ~%ss)', v_disp, v_waited;
END
$bg1$;

-- ── POSITIVE: on a lifeless install the watchman bell rings, by itself ──
-- Real path: nobody calls anything here. The bgworker's own 500ms tick
-- reaches its watchman check and enqueues the deduped bell. Bounded wait,
-- because "eventually" needs a limit to be a test.
DO $bg2$
DECLARE v_n int := 0; v_waited int := 0;
BEGIN
    WHILE v_waited < 90 LOOP
        SELECT count(*) INTO v_n FROM stewards.hinge_reviews
         WHERE kind = 'model-unconfigured' AND subject = 'watchman' AND status = 'pending';
        EXIT WHEN v_n > 0;
        PERFORM pg_sleep(1);
        v_waited := v_waited + 1;
    END LOOP;
    ASSERT v_n = 1, format(
        'BG 2: the dispatcher did not ring the model-unconfigured bell within %ss on a lifeless install (found %s). Either the scheduler stopped firing or the degrade path changed.', v_waited, v_n);
    RAISE NOTICE 'BG 2: the dispatcher rang the deduped model-unconfigured bell on its own, after ~%ss — the lifeless-db degrade works on the REAL path (no provider/model -> errored pass + one hinge bell, not a doomed work_queue row)', v_waited;
END
$bg2$;

-- ── and it is DEDUPED: more ticks must not pile bells up ───────────────
DO $bg3$
DECLARE v_n int;
BEGIN
    PERFORM stewards.watchman_scheduler_fire();
    PERFORM stewards.watchman_scheduler_fire();
    SELECT count(*) INTO v_n FROM stewards.hinge_reviews
     WHERE kind = 'model-unconfigured' AND subject = 'watchman' AND status = 'pending';
    ASSERT v_n = 1, format('BG 3: the bell must be deduped — two more ticks produced %s pending bells', v_n);
    RAISE NOTICE 'BG 3: extra ticks do not pile bells up (still exactly 1 pending) — a human gets one nudge, not a queue of them';
END
$bg3$;

-- ── INVERSE: with a provider/model configured, the bell must NOT ring ──
-- This is the assert with teeth. Without it, BG 2 proves only that SOMETHING
-- enqueues a bell — not that the lifeless-db condition is what causes it.
DO $bg4$
DECLARE v_n int; v_pass text;
BEGIN
    DELETE FROM stewards.hinge_reviews WHERE kind = 'model-unconfigured' AND subject = 'watchman';
    UPDATE stewards.watchman_config
       SET default_provider = 'bg-integration-probe',
           default_model    = 'bg-integration-model'
     WHERE id = 1;

    v_pass := stewards.watchman_scheduler_fire();

    SELECT count(*) INTO v_n FROM stewards.hinge_reviews
     WHERE kind = 'model-unconfigured' AND subject = 'watchman' AND status = 'pending';
    ASSERT v_n = 0, format(
        'BG 4 (inverse): a CONFIGURED watchman still rang the model-unconfigured bell (%s pending) — the bell is not actually gated on the lifeless condition', v_n);
    RAISE NOTICE 'BG 4 (inverse): with a provider/model configured the bell does NOT ring — the degrade is gated on the real condition, not fired unconditionally';

    -- restore the lifeless posture so a re-run starts where it started
    UPDATE stewards.watchman_config SET default_provider = NULL, default_model = NULL WHERE id = 1;
END
$bg4$;

\echo '== bgworker integration GREEN: the bell rings on its own when the db is lifeless, is deduped, and stays silent once a model exists =='
