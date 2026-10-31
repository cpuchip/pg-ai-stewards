-- =====================================================================
-- v78: a long-context rate card on model_pricing.
-- =====================================================================
-- model_pricing holds one card per (provider, model, effective_at), but some models are priced by prompt length.
-- Claude Haiku 5.5 bills $0.10 input / $0.50 output per MTok when the prompt is 100,000 tokens or under, and five
-- times every column above that; the prompt counts every input share (uncached input, cache writes, cache reads),
-- and each request is priced on its own, so a request over the line pays the higher card even when most of it is a
-- cache hit. cost_events recorded those calls at the low card, a fifth of the price. One instance's invoice for two
-- days billed $2.78 and $2.69 at the long-context rate; its cost_events re-priced at five times the base card for
-- every call over 100K give $2.78 and $2.70, and a split at 200K would not reconcile. (#28)
--
-- The long card is extra columns on the same row, so one lookup still finds the card and "the most recent
-- effective_at wins" keeps one meaning:
--   long_context_from_tokens            the line; NULL means one card, as before
--   long_input_micro_per_mtok, long_output_micro_per_mtok                    required when the line is set
--   long_cache_write_micro_per_mtok, long_cache_write_1h_micro_per_mtok,
--   long_cache_read_micro_per_mtok      optional; a NULL one falls back to the base rate of its kind
-- compute_cost (7 arguments) sums the four input shares; over the line every share is priced at the long card,
-- output included, and it returns long_context so the caller can tell which card priced the row. The 1-hour write
-- rate keeps v72's fallback onto the 5-minute rate. record_cost_event notes long_context=1 on such a row. The
-- 6-argument compute_cost and the 11-argument record_cost_event keep their signatures and results.
-- Oracle: virgin-smoke OK 145. Idempotent.
-- =====================================================================

ALTER TABLE stewards.model_pricing ADD COLUMN IF NOT EXISTS long_context_from_tokens bigint
    CHECK (long_context_from_tokens IS NULL OR long_context_from_tokens > 0);
ALTER TABLE stewards.model_pricing ADD COLUMN IF NOT EXISTS long_input_micro_per_mtok bigint
    CHECK (long_input_micro_per_mtok IS NULL OR long_input_micro_per_mtok >= 0);
ALTER TABLE stewards.model_pricing ADD COLUMN IF NOT EXISTS long_output_micro_per_mtok bigint
    CHECK (long_output_micro_per_mtok IS NULL OR long_output_micro_per_mtok >= 0);
ALTER TABLE stewards.model_pricing ADD COLUMN IF NOT EXISTS long_cache_write_micro_per_mtok bigint
    CHECK (long_cache_write_micro_per_mtok IS NULL OR long_cache_write_micro_per_mtok >= 0);
ALTER TABLE stewards.model_pricing ADD COLUMN IF NOT EXISTS long_cache_write_1h_micro_per_mtok bigint
    CHECK (long_cache_write_1h_micro_per_mtok IS NULL OR long_cache_write_1h_micro_per_mtok >= 0);
ALTER TABLE stewards.model_pricing ADD COLUMN IF NOT EXISTS long_cache_read_micro_per_mtok bigint
    CHECK (long_cache_read_micro_per_mtok IS NULL OR long_cache_read_micro_per_mtok >= 0);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'model_pricing_long_card_complete') THEN
        ALTER TABLE stewards.model_pricing ADD CONSTRAINT model_pricing_long_card_complete
            CHECK (long_context_from_tokens IS NULL
                   OR (long_input_micro_per_mtok IS NOT NULL AND long_output_micro_per_mtok IS NOT NULL));
    END IF;
END $$;

COMMENT ON COLUMN stewards.model_pricing.long_context_from_tokens IS
'v78: a request whose prompt (input + cache writes + cache reads) is larger than this is priced entirely at the long_* card, output included. NULL: one card.';
COMMENT ON COLUMN stewards.model_pricing.long_input_micro_per_mtok IS
'v78: input rate above long_context_from_tokens; required when the line is set (as is long_output_micro_per_mtok). A NULL long cache rate falls back to the base rate of its kind.';

-- the return type gains long_context, which CREATE OR REPLACE cannot change; record_cost_event (below) and the
-- 6-argument wrapper (below) are its only callers, and both are re-created here
DROP FUNCTION IF EXISTS stewards.compute_cost(text, text, int, int, int, int, int);

CREATE FUNCTION stewards.compute_cost(
    p_provider              text,
    p_model                 text,
    p_input_tokens          int,
    p_output_tokens         int,
    p_cache_write_tokens    int,
    p_cache_read_tokens     int,
    p_cache_write_1h_tokens int
) RETURNS TABLE (micro_dollars bigint, pricing_effective_at timestamptz, long_context boolean)
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_pricing record;
    v_micro bigint;
    v_long boolean;
    v_in bigint;
    v_out bigint;
    v_write bigint;
    v_write_1h bigint;
    v_read bigint;
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
        RETURN QUERY SELECT 0::bigint, '-infinity'::timestamptz, false;
        RETURN;
    END IF;

    -- v78: the prompt is every input share; over the line, every rate is the long card's
    v_long := v_pricing.long_context_from_tokens IS NOT NULL
          AND coalesce(p_input_tokens, 0)::bigint + coalesce(p_cache_write_tokens, 0)
              + coalesce(p_cache_write_1h_tokens, 0) + coalesce(p_cache_read_tokens, 0)
              > v_pricing.long_context_from_tokens;
    IF v_long THEN
        v_in       := v_pricing.long_input_micro_per_mtok;
        v_out      := v_pricing.long_output_micro_per_mtok;
        v_write    := coalesce(v_pricing.long_cache_write_micro_per_mtok, v_pricing.cache_write_micro_per_mtok);
        v_write_1h := coalesce(v_pricing.long_cache_write_1h_micro_per_mtok, v_pricing.cache_write_1h_micro_per_mtok);
        v_read     := coalesce(v_pricing.long_cache_read_micro_per_mtok, v_pricing.cache_read_micro_per_mtok);
    ELSE
        v_in       := v_pricing.input_micro_per_mtok;
        v_out      := v_pricing.output_micro_per_mtok;
        v_write    := v_pricing.cache_write_micro_per_mtok;
        v_write_1h := v_pricing.cache_write_1h_micro_per_mtok;
        v_read     := v_pricing.cache_read_micro_per_mtok;
    END IF;

    v_micro := (p_input_tokens::bigint  * v_in  / 1000000)
             + (p_output_tokens::bigint * v_out / 1000000);

    IF v_write IS NOT NULL AND p_cache_write_tokens > 0 THEN
        v_micro := v_micro + (p_cache_write_tokens::bigint * v_write / 1000000);
    END IF;

    -- v72: 1-hour writes at their own rate; with none, at the 5-minute rate (record_cost_event notes it)
    v_1h_rate := coalesce(v_write_1h, v_write);
    IF v_1h_rate IS NOT NULL AND p_cache_write_1h_tokens > 0 THEN
        v_micro := v_micro + (p_cache_write_1h_tokens::bigint * v_1h_rate / 1000000);
    END IF;

    IF v_read IS NOT NULL AND p_cache_read_tokens > 0 THEN
        v_micro := v_micro + (p_cache_read_tokens::bigint * v_read / 1000000);
    END IF;

    RETURN QUERY SELECT v_micro, v_pricing.effective_at, v_long;
END;
$func$;

COMMENT ON FUNCTION stewards.compute_cost(text, text, int, int, int, int, int) IS
'v78: cost in micro-dollars from token usage, 1-hour cache writes included, and whether the long-context card
priced it (the prompt, input + cache writes + cache reads, over model_pricing.long_context_from_tokens: every share
at the long card, output included). Picks the most recent pricing whose effective_at <= now(). No defaults, so it
never competes with the 6-argument form for a call.';

-- the 6-argument form every existing caller uses: unchanged signature, defaults and result
CREATE OR REPLACE FUNCTION stewards.compute_cost(
    p_provider           text,
    p_model              text,
    p_input_tokens       int,
    p_output_tokens      int,
    p_cache_write_tokens int DEFAULT 0,
    p_cache_read_tokens  int DEFAULT 0
) RETURNS TABLE (micro_dollars bigint, pricing_effective_at timestamptz)
LANGUAGE sql STABLE AS $func$
    SELECT c.micro_dollars, c.pricing_effective_at
      FROM stewards.compute_cost(p_provider, p_model, p_input_tokens, p_output_tokens,
                                 p_cache_write_tokens, p_cache_read_tokens, 0) c;
$func$;

COMMENT ON FUNCTION stewards.compute_cost(text, text, int, int, int, int) IS
'Compute cost in micro-dollars from token usage. Picks most-recent pricing whose effective_at <= now().
v72: a wrapper over the 7-argument form with no 1-hour cache writes. v78: the long-context card applies here too.';

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
    v_long       boolean;
    v_id         bigint;
    v_notes      text;
    v_factor     numeric;
    v_1h         integer := coalesce(p_cache_write_1h_tokens, 0);
BEGIN
    SELECT micro_dollars, pricing_effective_at, long_context
      INTO v_micro, v_pricing_at, v_long
      FROM stewards.compute_cost(p_provider, p_model,
                                  p_input_tokens, p_output_tokens,
                                  p_cache_write_tokens, p_cache_read_tokens, v_1h);

    v_notes := p_notes;
    IF v_pricing_at = '-infinity'::timestamptz THEN
        v_notes := coalesce(v_notes || ' | ', '')
                 || 'no_pricing_row(' || p_provider || '/' || p_model || ')';
    ELSIF v_1h > 0 AND (SELECT cache_write_1h_micro_per_mtok IS NULL
                               AND (NOT v_long OR long_cache_write_1h_micro_per_mtok IS NULL)
                          FROM stewards.model_pricing
                         WHERE provider = p_provider AND model = p_model AND effective_at = v_pricing_at
                         LIMIT 1) THEN
        v_notes := coalesce(v_notes || ' | ', '')
                 || 'no_1h_rate(' || p_provider || '/' || p_model || ')';
    END IF;

    -- v78: the long-context card priced this row
    IF v_long THEN
        v_notes := coalesce(v_notes || ' ', '') || 'long_context=1';
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
the 5m rate with a no_1h_rate note). v78: a row the long-context card priced is noted long_context=1. Otherwise as
the 11-argument form: compute_cost, then stewards.price_factor when in (0, 1), upstream cost kept. No defaults, so
it never competes with the 11-argument form for a call.';
