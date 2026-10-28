-- =====================================================================
-- v72-cache-ttl.sql: an agent can keep its prompt cache for an hour.
--
-- The anthropic translator marks four cache breakpoints (the last tool, the
-- system block, the v68 cache-break head, the last message's tail), each with
-- the 5-minute lifetime. A 5-minute entry is gone between two turns more than
-- five minutes apart, and the next turn writes the whole prefix again at 1.25x
-- input; a 1-hour entry costs 2x input to write and is read back for an hour.
-- Measured on one persona (573 turns, 2026-10-24 to 27): 18% of the gaps
-- between turns fell between 5 and 60 minutes, each re-writing a ~24K-token
-- prefix. A family that fetches a page once has no reuse to keep.
--
-- agents.anthropic_options.cache_ttl = {"prefix": "5m"|"1h", "tail": "5m"|"1h"}
-- (either key may be left out: 5m). The prefix marks are the tool, system and
-- cache-break ones; the tail is the last message's. Absent, the body is what it
-- was before v72, byte for byte. The API refuses a shorter mark before a longer
-- one, so a 5m prefix with a 1h tail is refused here and normalized in Rust.
-- An instance default sits in config key anthropic_cache_ttl (same shape);
-- attach_agent_anthropic_options gives it to an agent with no cache_ttl of its
-- own, so the translator reads one place, the body. cache_ttl never reaches the
-- request.
--
-- Cost: Anthropic reports usage.cache_creation.ephemeral_1h_input_tokens inside
-- the cache_creation total. cost_events.cache_write_1h_tokens carries that
-- share (cache_write_tokens keeps the 5-minute one), priced at
-- model_pricing.cache_write_1h_micro_per_mtok; a model with no 1h rate is
-- priced at its 5m rate and noted no_1h_rate(provider/model), never at an
-- invented rate. The new compute_cost (7 args) and record_cost_event (12 args)
-- have no defaults, so no call can match both them and the older forms, which
-- stay as wrappers for every existing caller.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.cache_ttl_ok(p_ttl jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
    SELECT p_ttl IS NULL
        OR (jsonb_typeof(p_ttl) = 'object'
            AND p_ttl - 'prefix' - 'tail' = '{}'::jsonb
            AND coalesce(p_ttl ->> 'prefix', '5m') IN ('5m', '1h')
            AND coalesce(p_ttl ->> 'tail', '5m') IN ('5m', '1h')
            AND NOT (coalesce(p_ttl ->> 'prefix', '5m') = '5m' AND coalesce(p_ttl ->> 'tail', '5m') = '1h'));
$fn$;

COMMENT ON FUNCTION stewards.cache_ttl_ok(jsonb) IS
'v72: is this a cache_ttl the API accepts? An object with only prefix and tail, each 5m or 1h (missing = 5m),
and not a 5m prefix before a 1h tail. NULL is fine (no cache_ttl).';

ALTER TABLE stewards.agents DROP CONSTRAINT IF EXISTS agents_anthropic_options_keys;
ALTER TABLE stewards.agents ADD CONSTRAINT agents_anthropic_options_keys CHECK (
    anthropic_options IS NULL
    OR (jsonb_typeof(anthropic_options) = 'object'
        AND anthropic_options - 'output_config' - 'thinking' - 'cache_ttl' = '{}'::jsonb
        AND stewards.cache_ttl_ok(anthropic_options -> 'cache_ttl')));

COMMENT ON COLUMN stewards.agents.anthropic_options IS
'v65: request fields for Anthropic models, copied into every chat this agent makes. output_config
(e.g. {"effort": "low"}) and thinking (e.g. {"type": "disabled"}) go on the request; v72: cache_ttl
({"prefix": "1h", "tail": "5m"}) sets the prompt-cache lifetimes and is read by the translator, never sent.
NULL = the model''s defaults and 5-minute marks. A model that rejects a value fails the row with 400.';

CREATE OR REPLACE FUNCTION stewards.attach_agent_anthropic_options()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_agent   stewards.agents;
    v_opts    jsonb;
    v_default jsonb;
BEGIN
    IF NEW.kind IS DISTINCT FROM 'chat' OR NEW.payload ->> 'agent_family' IS NULL
       OR jsonb_typeof(NEW.payload -> 'body') IS DISTINCT FROM 'object' THEN
        RETURN NEW;
    END IF;
    v_agent := stewards.resolve_agent(NEW.payload ->> 'agent_family', NEW.payload #>> '{body,model}');
    v_opts := v_agent.anthropic_options;
    -- v72: the instance default lifetimes, for an agent with none of its own; a malformed default is passed over
    IF v_opts IS NULL OR NOT (v_opts ? 'cache_ttl') THEN
        v_default := stewards.config_get('anthropic_cache_ttl');
        IF jsonb_typeof(v_default) = 'object' AND stewards.cache_ttl_ok(v_default) THEN
            v_opts := coalesce(v_opts, '{}'::jsonb) || jsonb_build_object('cache_ttl', v_default);
        END IF;
    END IF;
    IF v_opts IS NOT NULL THEN
        NEW.payload := jsonb_set(NEW.payload, '{body,anthropic_options}', v_opts);
    END IF;
    RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION stewards.attach_agent_anthropic_options() IS
'v65: BEFORE INSERT on work_queue. For a chat, the agent resolve_agent picks for (agent_family, body.model)
lends its anthropic_options to payload.body.anthropic_options. v72: an agent without a cache_ttl of its own
takes config anthropic_cache_ttl when that is a valid one. Non-chat rows are untouched.';

-- ---------------------------------------------------------------------
-- The 1-hour write: its rate and its tokens.
-- ---------------------------------------------------------------------
ALTER TABLE stewards.model_pricing ADD COLUMN IF NOT EXISTS cache_write_1h_micro_per_mtok bigint
    CHECK (cache_write_1h_micro_per_mtok IS NULL OR cache_write_1h_micro_per_mtok >= 0);
COMMENT ON COLUMN stewards.model_pricing.cache_write_1h_micro_per_mtok IS
'v72: the rate for prompt-cache writes with the 1-hour lifetime (Anthropic: 2x input). Operator data; NULL
prices them at cache_write_micro_per_mtok and record_cost_event notes no_1h_rate.';

ALTER TABLE stewards.cost_events ADD COLUMN IF NOT EXISTS cache_write_1h_tokens integer NOT NULL DEFAULT 0
    CHECK (cache_write_1h_tokens >= 0);
COMMENT ON COLUMN stewards.cost_events.cache_write_1h_tokens IS
'v72: prompt-cache tokens written with the 1-hour lifetime. cache_write_tokens is the 5-minute share; their sum
is the provider''s cache_creation total.';

CREATE OR REPLACE FUNCTION stewards.compute_cost(
    p_provider              text,
    p_model                 text,
    p_input_tokens          int,
    p_output_tokens         int,
    p_cache_write_tokens    int,
    p_cache_read_tokens     int,
    p_cache_write_1h_tokens int
) RETURNS TABLE (micro_dollars bigint, pricing_effective_at timestamptz)
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_pricing record;
    v_micro bigint;
    v_1h_rate bigint;
BEGIN
    SELECT * INTO v_pricing
      FROM stewards.model_pricing
     WHERE provider = p_provider
       AND model = p_model
       AND effective_at <= now()
     ORDER BY effective_at DESC
     LIMIT 1;

    IF v_pricing IS NULL THEN
        RETURN QUERY SELECT 0::bigint, '-infinity'::timestamptz;
        RETURN;
    END IF;

    v_micro := (p_input_tokens::bigint  * v_pricing.input_micro_per_mtok  / 1000000)
             + (p_output_tokens::bigint * v_pricing.output_micro_per_mtok / 1000000);

    IF v_pricing.cache_write_micro_per_mtok IS NOT NULL AND p_cache_write_tokens > 0 THEN
        v_micro := v_micro + (p_cache_write_tokens::bigint
                              * v_pricing.cache_write_micro_per_mtok / 1000000);
    END IF;

    -- v72: 1-hour writes at their own rate; with none, at the 5-minute rate (record_cost_event notes it)
    v_1h_rate := coalesce(v_pricing.cache_write_1h_micro_per_mtok, v_pricing.cache_write_micro_per_mtok);
    IF v_1h_rate IS NOT NULL AND p_cache_write_1h_tokens > 0 THEN
        v_micro := v_micro + (p_cache_write_1h_tokens::bigint * v_1h_rate / 1000000);
    END IF;

    IF v_pricing.cache_read_micro_per_mtok IS NOT NULL AND p_cache_read_tokens > 0 THEN
        v_micro := v_micro + (p_cache_read_tokens::bigint
                              * v_pricing.cache_read_micro_per_mtok / 1000000);
    END IF;

    RETURN QUERY SELECT v_micro, v_pricing.effective_at;
END;
$func$;

COMMENT ON FUNCTION stewards.compute_cost(text, text, int, int, int, int, int) IS
'v72: cost in micro-dollars from token usage, 1-hour cache writes included. Picks the most recent pricing whose
effective_at <= now(). No defaults, so it never competes with the 6-argument form for a call.';

-- the 6-argument form every existing caller uses: unchanged signature and defaults, no 1-hour writes
CREATE OR REPLACE FUNCTION stewards.compute_cost(
    p_provider           text,
    p_model              text,
    p_input_tokens       int,
    p_output_tokens      int,
    p_cache_write_tokens int DEFAULT 0,
    p_cache_read_tokens  int DEFAULT 0
) RETURNS TABLE (micro_dollars bigint, pricing_effective_at timestamptz)
LANGUAGE sql STABLE AS $func$
    SELECT * FROM stewards.compute_cost(p_provider, p_model, p_input_tokens, p_output_tokens,
                                        p_cache_write_tokens, p_cache_read_tokens, 0);
$func$;

COMMENT ON FUNCTION stewards.compute_cost(text, text, int, int, int, int) IS
'Compute cost in micro-dollars from token usage. Picks most-recent pricing whose effective_at <= now().
v72: a wrapper over the 7-argument form with no 1-hour cache writes.';

CREATE OR REPLACE FUNCTION stewards.record_cost_event(
    p_work_item_id          uuid,
    p_attempt_seq           integer,
    p_provider              text,
    p_model                 text,
    p_input_tokens          integer,
    p_output_tokens         integer,
    p_cache_write_tokens    integer,
    p_cache_write_1h_tokens integer,
    p_cache_read_tokens     integer,
    p_session_id            text,
    p_notes                 text,
    p_upstream_micro        bigint
) RETURNS bigint LANGUAGE plpgsql AS $func$
DECLARE
    v_micro      bigint;
    v_pricing_at timestamptz;
    v_id         bigint;
    v_notes      text;
    v_factor     numeric;
    v_1h         integer := coalesce(p_cache_write_1h_tokens, 0);
BEGIN
    SELECT micro_dollars, pricing_effective_at
      INTO v_micro, v_pricing_at
      FROM stewards.compute_cost(p_provider, p_model,
                                  p_input_tokens, p_output_tokens,
                                  p_cache_write_tokens, p_cache_read_tokens, v_1h);

    v_notes := p_notes;
    IF v_pricing_at = '-infinity'::timestamptz THEN
        v_notes := coalesce(v_notes || ' | ', '')
                 || 'no_pricing_row(' || p_provider || '/' || p_model || ')';
    ELSIF v_1h > 0 AND (SELECT cache_write_1h_micro_per_mtok IS NULL FROM stewards.model_pricing
                         WHERE provider = p_provider AND model = p_model AND effective_at = v_pricing_at
                         LIMIT 1) THEN
        v_notes := coalesce(v_notes || ' | ', '')
                 || 'no_1h_rate(' || p_provider || '/' || p_model || ')';
    END IF;

    v_factor := nullif(current_setting('stewards.price_factor', true), '')::numeric;
    IF v_factor > 0 AND v_factor < 1 THEN
        v_micro := round(v_micro * v_factor)::bigint;
        v_notes := coalesce(v_notes || ' ', '') || 'price_factor=' || v_factor;
    END IF;

    INSERT INTO stewards.cost_events
        (work_item_id, session_id, attempt_seq, provider, model,
         input_tokens, output_tokens, cache_write_tokens, cache_write_1h_tokens, cache_read_tokens,
         micro_dollars, pricing_effective_at, notes, upstream_micro_dollars)
    VALUES
        (p_work_item_id, p_session_id, p_attempt_seq, p_provider, p_model,
         p_input_tokens, p_output_tokens, p_cache_write_tokens, v_1h, p_cache_read_tokens,
         v_micro, v_pricing_at, v_notes, p_upstream_micro)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

COMMENT ON FUNCTION stewards.record_cost_event(uuid, integer, text, text, integer, integer, integer, integer, integer, text, text, bigint) IS
'v72: records a cost_event with the 1-hour cache writes apart (cache_write_1h_tokens, priced at the 1h rate, or at
the 5m rate with a no_1h_rate note). Otherwise as the 11-argument form: compute_cost, then stewards.price_factor
when in (0, 1), upstream cost kept. No defaults, so it never competes with the 11-argument form for a call.';

-- the 11-argument form every existing caller uses: unchanged signature and defaults, no 1-hour writes
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
) RETURNS bigint LANGUAGE sql AS $func$
    SELECT stewards.record_cost_event(p_work_item_id, p_attempt_seq, p_provider, p_model, p_input_tokens,
                                      p_output_tokens, p_cache_write_tokens, 0, p_cache_read_tokens, p_session_id,
                                      p_notes, p_upstream_micro);
$func$;

COMMENT ON FUNCTION stewards.record_cost_event(uuid, integer, text, text, integer, integer, integer, integer, text, text, bigint) IS
'Records a cost_event. micro_dollars is computed (compute_cost: rate x tokens), then multiplied by the
stewards.price_factor setting when it is in (0, 1) (v66: 0.5 for a Message Batches result, noted as
price_factor= in notes); p_upstream_micro carries the gateway-reported real cost into upstream_micro_dollars.
v72: a wrapper over the 12-argument form with no 1-hour cache writes. Trigger updates work_items + buckets.';
