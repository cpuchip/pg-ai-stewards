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

-- ── INVERSE: with a provider/model configured, THE BGWORKER stays silent ──
--
-- This is the assert with teeth, and its first version did not have them. It
-- did the config UPDATE, the DELETE, a hand-made scheduler call and the
-- zero-count assert all inside ONE DO block — one transaction. The other
-- workers cannot see an uncommitted posture, so the only actor ever tested
-- against "configured" was my own call. The phase claims to test the
-- BGWORKER; the inverse did not involve it. Worse, a tick already in flight
-- could still be acting on the old lifeless snapshot.
--
-- So the steps below are separate top-level statements — each one COMMITS —
-- and the observation window contains no hand-made call at all. The actor is
-- the dispatcher or nothing.

-- 1. Commit the configured posture, so every worker can actually see it.
UPDATE stewards.watchman_config
   SET default_provider = 'bg-integration-probe',
       default_model    = 'bg-integration-model'
 WHERE id = 1;

-- 2. Let any tick that snapshotted the OLD lifeless posture finish, then
--    clear the bell it (legitimately) rang. Deleting first would race them.
SELECT pg_sleep(8) AS drain_in_flight_ticks;
DELETE FROM stewards.hinge_reviews WHERE kind = 'model-unconfigured' AND subject = 'watchman';

-- 3. Record where the actor is, then WAIT FOR IT TO ACT — adaptively, not on
--    a fixed sleep. Measured cadence: the scheduler fires about every 60s
--    (observed passes at ~10s, ~70s, ~130s on a fresh preloaded cluster), so
--    a fixed 75s window caught exactly one pass — true, but one unlucky run
--    from failing on vacuity. Waiting until the actor has demonstrably acted
--    removes both the vacuum and the false red.
--
--    (This poll DOES see other backends' commits, unlike BG 1's: each
--    statement in a READ COMMITTED transaction takes a fresh snapshot of
--    ordinary tables. It was pg_stat_activity — statistics, cached per
--    transaction — that needed pg_stat_clear_snapshot().)
CREATE TEMP TABLE bg4_baseline AS
SELECT count(*) AS passes, now() AS at FROM stewards.watchman_passes;

DO $bg4$
DECLARE v_bells int; v_new int; v_unset int; v_waited int := 0; v_base bigint; v_since timestamptz;
BEGIN
    SELECT passes, at INTO v_base, v_since FROM bg4_baseline;

    WHILE v_waited < 150 LOOP
        SELECT count(*) - v_base INTO v_new FROM stewards.watchman_passes;
        EXIT WHEN v_new > 0;
        PERFORM pg_sleep(5);
        v_waited := v_waited + 5;
    END LOOP;

    SELECT count(*) INTO v_bells FROM stewards.hinge_reviews
     WHERE kind = 'model-unconfigured' AND subject = 'watchman' AND status = 'pending';
    SELECT count(*) INTO v_unset FROM stewards.watchman_passes
     WHERE provider = '(unset)' AND started_at > v_since;

    -- The actor must have ACTED, or silence proves nothing at all.
    ASSERT v_new > 0, format(
        'BG 4 (inverse) is VACUOUS: the dispatcher started no watchman pass within %ss (new passes=%s). "No bell" cannot be read as "stayed silent" when nothing fired.', v_waited, v_new);
    -- And what it ran must be the CONFIGURED path, not the lifeless one.
    ASSERT v_unset = 0, format(
        'BG 4 (inverse): %s pass(es) in the window still recorded provider "(unset)" — the worker took the lifeless branch despite a configured posture', v_unset);
    ASSERT v_bells = 0, format(
        'BG 4 (inverse): the dispatcher rang the model-unconfigured bell %s time(s) with a provider/model configured — the bell is not gated on the lifeless condition', v_bells);

    RAISE NOTICE 'BG 4 (inverse): across % real dispatcher pass(es) (first seen after ~%ss) with a provider/model configured, ZERO took the lifeless branch and ZERO bells rang — the degrade is gated on the real condition, and the actor tested is the bgworker itself, not a hand-made call', v_new, v_waited;
END
$bg4$;

-- 4. Restore the lifeless posture so a re-run starts where this one started.
UPDATE stewards.watchman_config SET default_provider = NULL, default_model = NULL WHERE id = 1;
DROP TABLE bg4_baseline;

\echo '== bgworker integration GREEN: the bell rings on its own when the db is lifeless, is deduped, and stays silent once a model exists =='
