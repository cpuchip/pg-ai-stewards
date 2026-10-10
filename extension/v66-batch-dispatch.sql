-- =====================================================================
-- v66-batch-dispatch.sql: an agent can send its chats through Anthropic's
-- Message Batches API at half price.
--
-- A batch is processed asynchronously (most finish within an hour, all within
-- 24 h) and every token in it, thinking and cache included, is billed at 50%.
-- Work that does not need an answer in seconds (book extraction overnight) pays
-- double for the immediate path. agents.dispatch_mode = 'batch' opts an agent
-- in. A BEFORE INSERT trigger routes its chat to status 'batch_pending' only
-- when the chat can be batched: the provider speaks the anthropic format and
-- the call is single-shot (tools disabled, or no tools offered). Any other chat
-- of a batch agent runs immediately, and the first such fallback per agent and
-- reason is logged in batch_fallback_log.
--
-- The bgworker claims only 'pending' rows, so batch rows are never dispatched
-- one by one. The leader's batch cycle (bgworker.rs run_batch_cycle) calls the
-- functions below: batch_open groups a provider's waiting rows into a batch
-- (refusing what an estimate says would cross the provider's enforced spend
-- cap), the worker POSTs it to {base_url}/messages/batches, polls it, and
-- writes each result through the same code an immediate chat uses, only while
-- the row is still 'batched' (a cancelled row is never written). cost_events
-- get the batch rate through the stewards.price_factor setting, which
-- record_cost_event applies when it is set for the transaction.
--
-- Failures: a submit is retried with backoff and the batch fails by name after
-- 5 attempts; a row the provider answered with overloaded or api_error goes back
-- to the next batch up to 3 times; an expired, canceled, missing or stuck
-- (no end after 25 h) row goes back once; anything else fails by name.
-- =====================================================================

ALTER TABLE stewards.agents ADD COLUMN IF NOT EXISTS dispatch_mode text NOT NULL DEFAULT 'immediate';
ALTER TABLE stewards.agents DROP CONSTRAINT IF EXISTS agents_dispatch_mode_check;
ALTER TABLE stewards.agents ADD CONSTRAINT agents_dispatch_mode_check
    CHECK (dispatch_mode IN ('immediate', 'batch'));

COMMENT ON COLUMN stewards.agents.dispatch_mode IS
'v66: ''immediate'' (default) sends each chat when it is enqueued. ''batch'' sends single-shot chats to an
anthropic-format provider through the Message Batches API at half price, answered within 24 h (usually
within the hour). The provider must support /messages/batches. Other chats of a batch agent run immediately
and are logged once per reason in batch_fallback_log.';

CREATE TABLE IF NOT EXISTS stewards.provider_batches (
    id               bigserial PRIMARY KEY,
    provider         text NOT NULL,
    external_id      text UNIQUE,
    status           text NOT NULL DEFAULT 'opening'
                     CHECK (status IN ('opening', 'submitted', 'ended', 'failed', 'stuck')),
    request_count    int NOT NULL DEFAULT 0,
    est_cost_micro   bigint NOT NULL DEFAULT 0,
    submit_attempts  int NOT NULL DEFAULT 0,
    next_attempt_at  timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    submitted_at     timestamptz,
    last_polled_at   timestamptz,
    ended_at         timestamptz,
    error            text
);

COMMENT ON TABLE stewards.provider_batches IS
'v66: one Message Batch. opening (rows grouped, not yet accepted by the provider; retried with backoff),
submitted (external_id known, polled), ended (results written), failed (5 submit attempts), stuck (no end
25 h after submit; its rows went back once). est_cost_micro is the estimate batch_open reserved against
the provider''s spend cap while the batch is open or submitted.';

CREATE INDEX IF NOT EXISTS provider_batches_open_idx
    ON stewards.provider_batches (provider) WHERE status IN ('opening', 'submitted');

CREATE TABLE IF NOT EXISTS stewards.batch_fallback_log (
    agent_family  text NOT NULL,
    reason        text NOT NULL,
    first_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (agent_family, reason)
);

COMMENT ON TABLE stewards.batch_fallback_log IS
'v66: a batch agent''s chat that could not be batched ran immediately. One row per agent and reason, the
first time it happened.';

ALTER TABLE stewards.work_queue DROP CONSTRAINT IF EXISTS work_queue_status_check;
ALTER TABLE stewards.work_queue ADD CONSTRAINT work_queue_status_check
    CHECK (status IN ('pending', 'in_progress', 'waiting_for_tools', 'done', 'error',
                      'batch_pending', 'batched'));
ALTER TABLE stewards.work_queue ADD COLUMN IF NOT EXISTS batch_id bigint
    REFERENCES stewards.provider_batches(id) ON DELETE SET NULL;
ALTER TABLE stewards.work_queue ADD COLUMN IF NOT EXISTS batch_attempts int NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS work_queue_batch_pending_idx
    ON stewards.work_queue (provider, created_at) WHERE status = 'batch_pending';
CREATE INDEX IF NOT EXISTS work_queue_batch_id_idx
    ON stewards.work_queue (batch_id) WHERE batch_id IS NOT NULL;

COMMENT ON COLUMN stewards.work_queue.batch_attempts IS
'v66: how many times this row went back to batch_pending after a batch did not answer it.';

-- ---------------------------------------------------------------------
-- Routing. Named to sort after work_queue_stamp_api_format (same-timing
-- triggers fire in name order), so it sees the final provider and format.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.route_batch_chat()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_agent  stewards.agents;
    v_reason text;
BEGIN
    IF NEW.kind IS DISTINCT FROM 'chat' OR NEW.status IS DISTINCT FROM 'pending'
       OR NEW.payload ->> 'agent_family' IS NULL
       OR jsonb_typeof(NEW.payload -> 'body') IS DISTINCT FROM 'object' THEN
        RETURN NEW;
    END IF;
    v_agent := stewards.resolve_agent(NEW.payload ->> 'agent_family', NEW.payload #>> '{body,model}');
    IF v_agent.dispatch_mode IS DISTINCT FROM 'batch' THEN
        RETURN NEW;
    END IF;
    IF coalesce(NEW.payload ->> 'api_format', 'openai') <> 'anthropic' THEN
        v_reason := 'provider format is ' || coalesce(NEW.payload ->> 'api_format', 'openai');
    ELSIF coalesce((NEW.payload ->> 'tools_disabled')::boolean, false) IS NOT TRUE
          AND coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(NEW.payload #> '{body,tools}') = 'array'
                                               THEN NEW.payload #> '{body,tools}' END), 0) > 0 THEN
        v_reason := 'chat offers tools';
    END IF;
    IF v_reason IS NULL THEN
        NEW.status := 'batch_pending';
    ELSE
        INSERT INTO stewards.batch_fallback_log (agent_family, reason)
        VALUES (NEW.payload ->> 'agent_family', v_reason)
        ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION stewards.route_batch_chat() IS
'v66: BEFORE INSERT on work_queue. A pending chat whose resolved agent has dispatch_mode = ''batch'' becomes
''batch_pending'' when its provider speaks the anthropic format and it is single-shot (tools_disabled, or
no tools in the body). Otherwise it stays pending and the reason is logged once in batch_fallback_log.';

DROP TRIGGER IF EXISTS work_queue_zz_route_batch ON stewards.work_queue;
CREATE TRIGGER work_queue_zz_route_batch
    BEFORE INSERT ON stewards.work_queue
    FOR EACH ROW EXECUTE FUNCTION stewards.route_batch_chat();

-- ---------------------------------------------------------------------
-- The batch rate. record_cost_event keeps its signature; a writer that
-- records a batch result sets stewards.price_factor for its transaction
-- (set_config(..., true)). Values outside (0, 1) are ignored.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.record_cost_event(
    p_work_item_id      uuid,
    p_attempt_seq       integer,
    p_provider          text,
    p_model             text,
    p_input_tokens      integer,
    p_output_tokens     integer,
    p_cache_write_tokens integer DEFAULT 0,
    p_cache_read_tokens  integer DEFAULT 0,
    p_session_id        text DEFAULT NULL,
    p_notes             text DEFAULT NULL,
    p_upstream_micro    bigint DEFAULT NULL
) RETURNS bigint LANGUAGE plpgsql AS $func$
DECLARE
    v_micro      bigint;
    v_pricing_at timestamptz;
    v_id         bigint;
    v_notes      text;
    v_factor     numeric;
BEGIN
    SELECT micro_dollars, pricing_effective_at
      INTO v_micro, v_pricing_at
      FROM stewards.compute_cost(p_provider, p_model,
                                  p_input_tokens, p_output_tokens,
                                  p_cache_write_tokens, p_cache_read_tokens);

    -- If no pricing row exists, flag in notes so the gap is visible.
    v_notes := p_notes;
    IF v_pricing_at = '-infinity'::timestamptz THEN
        v_notes := coalesce(v_notes || ' | ', '')
                 || 'no_pricing_row(' || p_provider || '/' || p_model || ')';
    END IF;

    v_factor := nullif(current_setting('stewards.price_factor', true), '')::numeric;
    IF v_factor > 0 AND v_factor < 1 THEN
        v_micro := round(v_micro * v_factor)::bigint;
        v_notes := coalesce(v_notes || ' ', '') || 'price_factor=' || v_factor;
    END IF;

    INSERT INTO stewards.cost_events
        (work_item_id, session_id, attempt_seq, provider, model,
         input_tokens, output_tokens, cache_write_tokens, cache_read_tokens,
         micro_dollars, pricing_effective_at, notes, upstream_micro_dollars)
    VALUES
        (p_work_item_id, p_session_id, p_attempt_seq, p_provider, p_model,
         p_input_tokens, p_output_tokens, p_cache_write_tokens, p_cache_read_tokens,
         v_micro, v_pricing_at, v_notes, p_upstream_micro)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

COMMENT ON FUNCTION stewards.record_cost_event(uuid, integer, text, text, integer, integer, integer, integer, text, text, bigint) IS
'Records a cost_event. micro_dollars is computed (compute_cost: rate x tokens), then multiplied by the
stewards.price_factor setting when it is in (0, 1) (v66: 0.5 for a Message Batches result, noted as
price_factor= in notes); p_upstream_micro carries the gateway-reported real cost into upstream_micro_dollars.
Trigger updates work_items + buckets.';

-- ---------------------------------------------------------------------
-- The estimate batch_open reserves against the cap: input from the body's
-- length at 3.5 characters a token, output from the mean of the model's
-- last 50 cost_events (else max_tokens, at most 4096), both at half rate.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.batch_row_estimate_micro(p_provider text, p_payload jsonb)
RETURNS bigint LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_model   text := coalesce(p_payload ->> 'requested_model', p_payload #>> '{body,model}');
    v_pricing stewards.model_pricing;
    v_in      bigint;
    v_out     bigint;
BEGIN
    SELECT * INTO v_pricing FROM stewards.model_pricing
     WHERE provider = p_provider AND model = v_model AND effective_at <= now()
     ORDER BY effective_at DESC LIMIT 1;
    IF NOT FOUND THEN
        RETURN 0;
    END IF;
    v_in := ceil(octet_length((p_payload -> 'body')::text) / 3.5);
    SELECT round(avg(output_tokens)) INTO v_out
      FROM (SELECT output_tokens FROM stewards.cost_events
             WHERE provider = p_provider AND model = v_model
             ORDER BY id DESC LIMIT 50) s;
    v_out := coalesce(v_out, least(coalesce((p_payload #>> '{body,max_tokens}')::bigint, 4096), 4096));
    RETURN ceil((v_in * v_pricing.input_micro_per_mtok + v_out * v_pricing.output_micro_per_mtok)
                / 1000000.0 * 0.5);
END;
$fn$;

COMMENT ON FUNCTION stewards.batch_row_estimate_micro(text, jsonb) IS
'v66: estimated batch cost of one chat in micro-dollars, for the spend-cap check at submit. 0 when the model
has no pricing row (as compute_cost records it).';

-- ---------------------------------------------------------------------
-- batch_open: group a provider's waiting rows into one batch.
-- Returns the batch id, NULL when nothing is due (the oldest row is younger
-- than batch_fill_seconds, default 30), or -1 when the cap refused even the
-- first row. Rows that fit are marked 'batched'.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.batch_open(p_provider text, p_max int DEFAULT 2000)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
    v_fill      interval := (coalesce(stewards.config_get_text('batch_fill_seconds', '30'), '30') || ' seconds')::interval;
    v_max_bytes bigint := 64 * 1024 * 1024;
    v_cap       stewards.provider_spend_caps;
    v_remaining bigint;
    v_acc       bigint := 0;
    v_bytes     bigint := 0;
    v_ids       bigint[] := ARRAY[]::bigint[];
    v_est       bigint;
    v_batch     bigint;
    r           record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM stewards.work_queue
                    WHERE status = 'batch_pending' AND provider = p_provider
                      AND created_at <= now() - v_fill) THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_cap FROM stewards.provider_spend_caps WHERE provider = p_provider AND enforced;
    IF FOUND THEN
        v_remaining := v_cap.cap_micro - stewards.provider_spend_since(p_provider)
                     - coalesce((SELECT sum(est_cost_micro) FROM stewards.provider_batches
                                  WHERE provider = p_provider AND status IN ('opening', 'submitted')), 0);
    END IF;

    FOR r IN
        SELECT id, payload FROM stewards.work_queue
         WHERE status = 'batch_pending' AND provider = p_provider
         ORDER BY created_at, id
         LIMIT greatest(p_max, 1)
         FOR UPDATE SKIP LOCKED
    LOOP
        v_est := stewards.batch_row_estimate_micro(p_provider, r.payload);
        EXIT WHEN v_remaining IS NOT NULL AND v_acc + v_est > v_remaining;
        EXIT WHEN cardinality(v_ids) > 0 AND v_bytes + octet_length(r.payload::text) > v_max_bytes;
        v_acc := v_acc + v_est;
        v_bytes := v_bytes + octet_length(r.payload::text);
        v_ids := v_ids || r.id;
    END LOOP;

    IF cardinality(v_ids) = 0 THEN
        RETURN -1;
    END IF;

    INSERT INTO stewards.provider_batches (provider, request_count, est_cost_micro)
    VALUES (p_provider, cardinality(v_ids), v_acc)
    RETURNING id INTO v_batch;
    UPDATE stewards.work_queue
       SET status = 'batched', batch_id = v_batch, claimed_at = now()
     WHERE id = ANY(v_ids);
    RETURN v_batch;
END;
$fn$;

COMMENT ON FUNCTION stewards.batch_open(text, int) IS
'v66: group up to p_max of a provider''s batch_pending rows (oldest first, at most 64 MB of payload) into a
new provider_batches row once the oldest has waited batch_fill_seconds (config, default 30). With an enforced
spend cap, rows stop where the estimate (batch_row_estimate_micro) would cross what is left after spend and
open batches. Returns the batch id, NULL when nothing is due, -1 when the cap refused the first row.';

CREATE OR REPLACE FUNCTION stewards.batch_submitted(p_batch bigint, p_external_id text)
RETURNS void LANGUAGE sql AS $fn$
    UPDATE stewards.provider_batches
       SET status = 'submitted', external_id = p_external_id, submitted_at = now(),
           submit_attempts = submit_attempts + 1, error = NULL
     WHERE id = p_batch AND status = 'opening';
$fn$;

-- A row that leaves the batch path for good: status 'error', named.
CREATE OR REPLACE FUNCTION stewards.batch_fail_row(p_id bigint, p_error text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
    UPDATE stewards.work_queue
       SET status = 'error', error = p_error, done_at = now(),
           result = jsonb_build_object('error', p_error, 'batch_id', batch_id)
     WHERE id = p_id;
    PERFORM pg_notify('stewards_done', p_id::text);
END;
$fn$;

CREATE OR REPLACE FUNCTION stewards.batch_submit_failed(p_batch bigint, p_error text, p_retryable boolean DEFAULT true)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_attempts int;
    r          record;
BEGIN
    UPDATE stewards.provider_batches
       SET submit_attempts = submit_attempts + 1, error = p_error,
           next_attempt_at = now() + make_interval(secs => 30 * power(2, submit_attempts))
     WHERE id = p_batch AND status = 'opening'
    RETURNING submit_attempts INTO v_attempts;
    IF v_attempts IS NULL THEN
        RETURN 'skipped';
    END IF;
    IF p_retryable AND v_attempts < 5 THEN
        RETURN 'retry';
    END IF;
    UPDATE stewards.provider_batches SET status = 'failed', ended_at = now() WHERE id = p_batch;
    FOR r IN SELECT id FROM stewards.work_queue WHERE batch_id = p_batch AND status = 'batched' LOOP
        PERFORM stewards.batch_fail_row(r.id,
            format('batch submit failed after %s attempt(s): %s', v_attempts, p_error));
    END LOOP;
    RETURN 'failed';
END;
$fn$;

COMMENT ON FUNCTION stewards.batch_submit_failed(bigint, text, boolean) IS
'v66: a POST to /messages/batches failed. A retryable failure waits 30 s, 60 s, 120 s, 240 s between
attempts; the fifth failure, or any non-retryable one, fails the batch and its rows by name.';

-- batch_row_failed: the provider did not answer one row with a message.
-- p_kind is the result type (expired, canceled), the error type of an
-- errored result, or missing / stuck. Returns requeued, failed or skipped.
CREATE OR REPLACE FUNCTION stewards.batch_row_failed(p_id bigint, p_kind text, p_message text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_attempts int;
    v_limit    int;
BEGIN
    SELECT batch_attempts INTO v_attempts FROM stewards.work_queue
     WHERE id = p_id AND status = 'batched' FOR UPDATE;
    IF NOT FOUND THEN
        RETURN 'skipped';
    END IF;
    v_limit := CASE
        WHEN p_kind IN ('overloaded_error', 'api_error') THEN 3
        WHEN p_kind IN ('expired', 'canceled', 'missing', 'stuck') THEN 1
        ELSE 0
    END;
    IF v_attempts < v_limit THEN
        UPDATE stewards.work_queue
           SET status = 'batch_pending', batch_id = NULL, claimed_at = NULL,
               batch_attempts = batch_attempts + 1
         WHERE id = p_id;
        RETURN 'requeued';
    END IF;
    PERFORM stewards.batch_fail_row(p_id, format('batch %s: %s', p_kind, p_message));
    RETURN 'failed';
END;
$fn$;

COMMENT ON FUNCTION stewards.batch_row_failed(bigint, text, text) IS
'v66: a batched row came back without a message. overloaded_error / api_error go back to batch_pending up
to 3 times; expired, canceled, missing (absent from the results) and stuck go back once; anything else
(invalid_request_error and the rest) fails by name. A row no longer ''batched'' is skipped.';

CREATE OR REPLACE FUNCTION stewards.batch_poll_list(p_interval_seconds int DEFAULT 60)
RETURNS TABLE (batch_id bigint, provider text, external_id text)
LANGUAGE sql STABLE AS $fn$
    SELECT id, provider, external_id FROM stewards.provider_batches
     WHERE status = 'submitted'
       AND (last_polled_at IS NULL OR last_polled_at <= now() - make_interval(secs => p_interval_seconds))
     ORDER BY id;
$fn$;

CREATE OR REPLACE FUNCTION stewards.batch_polled(p_batch bigint)
RETURNS void LANGUAGE sql AS $fn$
    UPDATE stewards.provider_batches SET last_polled_at = now() WHERE id = p_batch;
$fn$;

CREATE OR REPLACE FUNCTION stewards.batch_ended(p_batch bigint)
RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE
    v_missing int := 0;
    r         record;
BEGIN
    UPDATE stewards.provider_batches
       SET status = 'ended', ended_at = now(), last_polled_at = now()
     WHERE id = p_batch AND status = 'submitted';
    FOR r IN SELECT id FROM stewards.work_queue WHERE batch_id = p_batch AND status = 'batched' LOOP
        PERFORM stewards.batch_row_failed(r.id, 'missing', 'no result for this row in the batch results');
        v_missing := v_missing + 1;
    END LOOP;
    RETURN v_missing;
END;
$fn$;

COMMENT ON FUNCTION stewards.batch_ended(bigint) IS
'v66: the batch''s results were read. Rows of the batch still ''batched'' had no result line and go through
batch_row_failed as missing. Returns how many.';

CREATE OR REPLACE FUNCTION stewards.batch_sweep_stuck()
RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE
    v_n int := 0;
    b   record;
    r   record;
BEGIN
    FOR b IN SELECT id FROM stewards.provider_batches
              WHERE status = 'submitted' AND submitted_at < now() - interval '25 hours'
              FOR UPDATE SKIP LOCKED LOOP
        UPDATE stewards.provider_batches
           SET status = 'stuck', ended_at = now(), error = 'no end 25 h after submit'
         WHERE id = b.id;
        FOR r IN SELECT id FROM stewards.work_queue WHERE batch_id = b.id AND status = 'batched' LOOP
            PERFORM stewards.batch_row_failed(r.id, 'stuck', 'the batch had not ended 25 h after submit');
        END LOOP;
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END;
$fn$;

COMMENT ON FUNCTION stewards.batch_sweep_stuck() IS
'v66: a submitted batch with no end 25 h after submit (the provider expires them at 24 h) is marked stuck
and its rows go back once. Returns the number of batches marked.';

-- ---------------------------------------------------------------------
-- work_item_cancel (v04's ES.1.s1 cascade) also stops batch rows. A row
-- already inside a submitted batch is marked error here, and its result,
-- when it arrives, is not written (the writer requires 'batched').
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_cancel(
    p_work_item_id uuid,
    p_reason text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $FN$
DECLARE
    v_sessions text[];
    v_killed   int;
BEGIN
    UPDATE stewards.work_items
       SET status       = 'cancelled',
           error        = coalesce(p_reason, error),
           updated_at   = now(),
           completed_at = now()
     WHERE id = p_work_item_id
       AND status NOT IN ('completed', 'cancelled')
    RETURNING session_ids INTO v_sessions;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'work_item_cancel: % not found or already in terminal status',
            p_work_item_id;
    END IF;

    IF v_sessions IS NOT NULL AND array_length(v_sessions, 1) > 0 THEN
        WITH killed AS (
            UPDATE stewards.work_queue
               SET status = 'error'
             WHERE status IN ('pending', 'in_progress', 'waiting_for_tools', 'batch_pending', 'batched')
               AND payload->>'session_id' = ANY(v_sessions)
            RETURNING 1
        )
        SELECT count(*) INTO v_killed FROM killed;

        RAISE NOTICE 'work_item_cancel: % cancelled; cascade killed % non-terminal work_queue row(s) across % session(s)',
            p_work_item_id, v_killed, array_length(v_sessions, 1);
    END IF;
END;
$FN$;

COMMENT ON FUNCTION stewards.work_item_cancel(uuid, text) IS
'ES.1.s1: cancel a work_item AND hard-stop its session chat loops. Marks every pending/in_progress/waiting_for_tools work_queue row for the work_item''s session_ids as error so the chat→tool_dispatch→chat loop cannot keep spending after cancellation. v66: batch_pending and batched rows too; a cancelled batched row''s result is not written.';
