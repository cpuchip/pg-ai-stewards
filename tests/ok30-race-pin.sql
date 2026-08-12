-- =====================================================================
-- tests/ok30-race-pin.sql — the OK 30 race, reproduced ON DEMAND
-- =====================================================================
-- RED-FIRST ARTIFACT for the smoke-determinism fix. The defect was found
-- the hard way: an item-8 red run died at OK 30 nowhere near its edit,
-- while a control run of the unmodified file on the SAME image was green
-- minutes later. A race, not a regression — and a race you can only
-- observe by luck is a race you cannot fix with confidence.
--
-- This pins it. No waiting, no probability:
--
--   bgworker.rs:414  check_watchman_schedule()
--        -> stewards.watchman_scheduler_fire()          <-- called here, by hand
--        -> watchman_pass_start()
--        -> v27-lifeless-core.sql:936: with NO provider/model configured,
--           enqueue a deduped PENDING 'model-unconfigured' hinge bell
--
-- and virgin-smoke.sql:1527 (OK 30) asserts
--   hinge_gate_status()->>'should_run' = false   -- "a virgin queue"
--
-- A pending bell makes should_run TRUE. So whether the RELEASE GATE passes
-- depends on whether a 500ms-tick bgworker beats one psql session to line
-- 1527. Measured on a preloaded cluster: 4 dispatcher backends and the bell
-- present within seconds of CREATE EXTENSION.
--
-- RUN THIS ON AN ISOLATED CLUSTER (no shared_preload_libraries), so the
-- only actor is this file — that is what makes the reproduction exact
-- rather than merely likely.
--
--   docker run -d --name pin -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=x \
--       -e POSTGRES_DB=stewards stewards-oss-pg:test          # NO -c shared_preload_libraries
--   docker exec -i pin psql -U stewards -d stewards < extension/init/00-bootstrap-roles.sql
--   docker exec -i pin psql -U stewards -d stewards -v ON_ERROR_STOP=1 < tests/ok30-race-pin.sql
-- =====================================================================

\echo '== OK 30 race pin — forcing the bgworker tick by hand =='

CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE;

DO $pin$
DECLARE
    v_disp    int;
    v_before  boolean;
    v_pass    text;
    v_pending int;
    v_after   boolean;
BEGIN
    -- The pin is only exact if nothing else can act. Prove that first.
    SELECT count(*) INTO v_disp FROM pg_stat_activity
     WHERE backend_type LIKE 'pg_ai_stewards dispatcher%';
    ASSERT v_disp = 0,
        format('race pin must run on an ISOLATED cluster (no shared_preload_libraries): %s dispatcher bgworker(s) are running, so a green or red here would prove nothing about who did it', v_disp);

    -- OK 30's premise, before we touch anything.
    v_before := (stewards.hinge_gate_status()->>'should_run')::bool;
    ASSERT v_before = false,
        format('the pin needs a genuinely virgin queue to start from; should_run was already %s', v_before);

    -- THE BGWORKER'S OWN CALL, made by hand — bgworker.rs:414 invokes
    -- exactly this function on its tick. Nothing here is a stand-in.
    v_pass := stewards.watchman_scheduler_fire();

    SELECT count(*) INTO v_pending FROM stewards.hinge_reviews
     WHERE kind = 'model-unconfigured' AND subject = 'watchman' AND status = 'pending';
    v_after := (stewards.hinge_gate_status()->>'should_run')::bool;

    ASSERT v_pending = 1,
        format('the tick did not ring the bell (pending=%s) — the mechanism is not what this file claims, and the fix would be aimed at the wrong thing', v_pending);
    ASSERT v_after = true,
        'a pending bell must flip should_run to TRUE — that is the whole hazard';

    RAISE NOTICE 'RACE PINNED: one watchman tick (pass %) rang a pending model-unconfigured bell and flipped should_run false -> TRUE. OK 30 asserts should_run=false on a "virgin" queue, so any tick landing before virgin-smoke.sql:1527 reds the release gate — non-attributably, for a reason unrelated to whatever change is being tested.', v_pass;
END
$pin$;

\echo '== race pin GREEN: the mechanism is proven on demand, not waited for =='
