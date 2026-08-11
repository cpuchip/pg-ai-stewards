-- =====================================================================
-- tests/concurrency-write-path.sql — two-session write-path regressions
-- =====================================================================
-- CI-ONLY. Installs dblink and drives genuinely concurrent sessions against
-- the v50/v51 lane write path. NEVER run this against a live substrate — it
-- installs an extension and writes probe rows outside a transaction (dblink
-- work is not rolled back by an outer BEGIN).
--
-- Red-first provenance (2026-08-11): both blocks were watched FAIL against
-- the HEAD image (6d3e37a, pre-v51) — RACE A landed 2 live memories with one
-- normalized title; RACE B silently discarded correction-ONE — before the
-- v51 guards (advisory lock + recheck; SELECT ... FOR UPDATE) turned them
-- green. Evidence: .spec/reviews/sol-p0-release-batch-redrun-2026-08-11.md.
--
--   docker exec -i <pg> psql -U stewards -d stewards -v ON_ERROR_STOP=1 \
--       < tests/concurrency-write-path.sql
-- =====================================================================
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS dblink;

-- re-runnable: clear any prior run's probes
DELETE FROM stewards.nodes WHERE ref LIKE 'ccy-race-%';

\echo '=== RACE A: concurrent brain_add, same normalized title — exactly one must win ==='
DO $$
DECLARE v_n int; v_refused boolean := false; v_t0 timestamptz;
BEGIN
    -- session c2: add inside an OPEN transaction (uncommitted)
    PERFORM dblink_connect('c2', 'dbname=stewards user=stewards');
    PERFORM dblink_exec('c2', 'BEGIN');
    PERFORM * FROM dblink('c2',
      $q$SELECT stewards.brain_add('ccy-race-a-s2','Ccy Race Title','h','body2')$q$)
      AS t(r text);

    -- session c3: the SAME subject, different ref, async — with the v51
    -- advisory lock it must BLOCK here; at HEAD it sails through.
    PERFORM dblink_connect('c3', 'dbname=stewards user=stewards');
    PERFORM dblink_send_query('c3',
      $q$SELECT stewards.brain_add('ccy-race-a-s1','ccy  race   title','h','body1')$q$);

    PERFORM pg_sleep(1);
    PERFORM dblink_exec('c2', 'COMMIT');

    v_t0 := clock_timestamp();
    WHILE dblink_is_busy('c3') = 1 LOOP
        IF clock_timestamp() - v_t0 > interval '15 seconds' THEN
            RAISE EXCEPTION 'RACE A: second add neither refused nor completed in 15s';
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
    BEGIN
        PERFORM * FROM dblink_get_result('c3') AS t(r text);
    EXCEPTION WHEN unique_violation THEN v_refused := true;
    END;
    PERFORM dblink_disconnect('c2');
    PERFORM dblink_disconnect('c3');

    SELECT count(*) INTO v_n FROM stewards.nodes
     WHERE kind='memory' AND NOT ('retracted' = ANY(labels))
       AND regexp_replace(lower(label), '\s+', ' ', 'g') = 'ccy race title';

    IF v_n <> 1 OR NOT v_refused THEN
        RAISE EXCEPTION 'RACE A RED: % live memories share one subject (refusal seen: %) — sibling-prevention lost the race',
            v_n, v_refused;
    END IF;
    RAISE NOTICE 'RACE A GREEN: one add won, the concurrent duplicate was refused';
END $$;

\echo '=== RACE B: concurrent brain_amend — both corrections must survive ==='
SELECT stewards.brain_add('ccy-race-b', 'Ccy Race B Subject', 'h', 'original body');

DO $$
DECLARE v_body text; v_t0 timestamptz;
BEGIN
    -- session c2: amend inside an OPEN transaction (row lock held)
    PERFORM dblink_connect('c2', 'dbname=stewards user=stewards');
    PERFORM dblink_exec('c2', 'BEGIN');
    PERFORM * FROM dblink('c2',
      $q$SELECT stewards.brain_amend('ccy-race-b', 'correction-ONE')$q$)
      AS t(r text);

    -- session c3: concurrent amend, async. With v51's SELECT ... FOR UPDATE
    -- it blocks BEFORE reading the body; at HEAD it reads the stale body and
    -- overwrites correction-ONE after the lock clears.
    PERFORM dblink_connect('c3', 'dbname=stewards user=stewards');
    PERFORM dblink_send_query('c3',
      $q$SELECT stewards.brain_amend('ccy-race-b', 'correction-TWO')$q$);

    PERFORM pg_sleep(1);
    PERFORM dblink_exec('c2', 'COMMIT');

    v_t0 := clock_timestamp();
    WHILE dblink_is_busy('c3') = 1 LOOP
        IF clock_timestamp() - v_t0 > interval '15 seconds' THEN
            RAISE EXCEPTION 'RACE B: concurrent amend did not finish in 15s';
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
    PERFORM * FROM dblink_get_result('c3') AS t(r text);
    PERFORM dblink_disconnect('c2');
    PERFORM dblink_disconnect('c3');

    SELECT props->>'body' INTO v_body FROM stewards.nodes WHERE ref='ccy-race-b';
    IF v_body NOT LIKE '%correction-ONE%' OR v_body NOT LIKE '%correction-TWO%' THEN
        RAISE EXCEPTION 'RACE B RED: a correction was silently discarded. Final body: %', v_body;
    END IF;
    RAISE NOTICE 'RACE B GREEN: both concurrent corrections survived (deterministic order)';
END $$;

-- leave no probes behind
DELETE FROM stewards.nodes WHERE ref LIKE 'ccy-race-%';
\echo 'concurrency-write-path: ALL GREEN'
