-- =====================================================================
-- 06-cost — pricing, the cost ledger, buckets, caps, escalation
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Sources folded, in original
-- ship order: 4a-cost-tracking (pricing/ledger/buckets machinery), 4a-
-- escalation-chain (stage_models + escalation matrix + pick_model), 4g
-- (nullable work_item_id + session_id on the ledger; record_cost_event
-- re-signature), es11 (upstream_micro_dollars + the final 11-arg
-- record_cost_event), j11 §1-4 (provider_spend_caps machinery; its
-- work_item_dispatch_stage gate rides with j8a's catalog at the
-- fanout consolidation), j12 §1-2 (classify_error + failures view; its
-- start_brainstorm pre-flight rides with the fanout consolidation).
--
-- SEED ROWS MOVED TO THE OVERLAY: model pricing rates, bucket caps,
-- stage_models defaults, the escalation matrix, provider cap rows, and
-- model_capability registrations (4a seeds, j10, an4, cv4, j11 §6) are
-- operator data — which providers you pay, what they charge, and how
-- your model chain escalates. The machinery here ships empty; the seed
-- pack provides generic examples. compute_cost on an unpriced model
-- returns 0 and flags 'no_pricing_row' in notes — visible, not silent.
--
-- All money in micro-dollars (1 USD = 1_000_000) for integer
-- arithmetic. All rates per million tokens.
--
-- The work_items cost/escalation columns (cost_micro_dollars,
-- cost_cap_micro, cost_capped_at, model_override, escalation_*) are
-- born in 04-work-items' CREATE TABLE.
-- =====================================================================

-- ---------------------------------------------------------------------
-- model_pricing: one row per (provider, model, effective_at).
-- Most-recent row whose effective_at <= now() wins. NULL cache rates
-- mean the provider does not expose that distinction.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.model_pricing (
    provider                    text  NOT NULL,
    model                       text  NOT NULL,
    input_micro_per_mtok        bigint NOT NULL CHECK (input_micro_per_mtok >= 0),
    output_micro_per_mtok       bigint NOT NULL CHECK (output_micro_per_mtok >= 0),
    cache_write_micro_per_mtok  bigint CHECK (cache_write_micro_per_mtok IS NULL OR cache_write_micro_per_mtok >= 0),
    cache_read_micro_per_mtok   bigint CHECK (cache_read_micro_per_mtok IS NULL OR cache_read_micro_per_mtok >= 0),
    effective_at                timestamptz NOT NULL DEFAULT now(),
    notes                       text,
    PRIMARY KEY (provider, model, effective_at)
);

COMMENT ON TABLE stewards.model_pricing IS
'Per-model pricing in micro-dollars per 1M tokens. NULL cache_*_micro_per_mtok means provider does not expose that distinction. Most-recent effective_at wins. Rows are operator data — seed yours (do not invent 0 rates for paid models; 0 silently under-tracks real spend).';

-- ---------------------------------------------------------------------
-- cost_events: append-only per-dispatch cost audit ledger.
-- work_item_id nullable: NULL = an ad-hoc chat not tied to a work_item
-- (e.g., a watchman pass) — session_id identifies the owner.
-- micro_dollars is the substrate's rate×token estimate;
-- upstream_micro_dollars is the gateway-reported real cost when the
-- provider exposes it (estimate-vs-actual stays visible).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.cost_events (
    id                          bigserial PRIMARY KEY,
    work_item_id                uuid REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    session_id                  text,
    attempt_seq                 int NOT NULL,
    at                          timestamptz NOT NULL DEFAULT now(),
    provider                    text NOT NULL,
    model                       text NOT NULL,
    input_tokens                int NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
    output_tokens               int NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
    cache_write_tokens          int NOT NULL DEFAULT 0 CHECK (cache_write_tokens >= 0),
    cache_read_tokens           int NOT NULL DEFAULT 0 CHECK (cache_read_tokens >= 0),
    micro_dollars               bigint NOT NULL,
    upstream_micro_dollars      bigint,
    pricing_effective_at        timestamptz NOT NULL,
    notes                       text
);
CREATE INDEX IF NOT EXISTS cost_events_work_item ON stewards.cost_events(work_item_id);
CREATE INDEX IF NOT EXISTS cost_events_session ON stewards.cost_events(session_id);
CREATE INDEX IF NOT EXISTS cost_events_at ON stewards.cost_events(at);
CREATE INDEX IF NOT EXISTS cost_events_provider_model ON stewards.cost_events(provider, model);

COMMENT ON TABLE stewards.cost_events IS
'Append-only audit of every LLM dispatch cost. micro_dollars is computed at insert from compute_cost(provider, model, tokens) and locked to pricing_effective_at; upstream_micro_dollars carries the gateway-reported real cost when available.';

-- ---------------------------------------------------------------------
-- cost_buckets: rolling consumption buckets per provider/kind
-- (session_5h / daily / weekly / monthly). bucket_limit_micro is
-- INFORMATIONAL — for enforced caps see provider_spend_caps below.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.cost_buckets (
    id                  bigserial PRIMARY KEY,
    provider            text NOT NULL,
    bucket_kind         text NOT NULL CHECK (bucket_kind IN ('session_5h','daily','weekly','monthly')),
    period_start        timestamptz NOT NULL,
    period_end          timestamptz NOT NULL,
    micro_dollars       bigint NOT NULL DEFAULT 0,
    bucket_limit_micro  bigint,  -- NULL = informational only
    notes               text,
    UNIQUE (provider, bucket_kind, period_start)
);
CREATE INDEX IF NOT EXISTS cost_buckets_period ON stewards.cost_buckets(provider, bucket_kind, period_end);

COMMENT ON TABLE stewards.cost_buckets IS
'Rolling consumption buckets per provider/kind. Closes at period_end; bucket_current() opens the next period lazily. bucket_limit_micro NULL means informational only (no enforcement).';

-- ---------------------------------------------------------------------
-- compute_cost(provider, model, tokens...) -> (micro_dollars,
-- pricing_effective_at). Picks the most-recent pricing row whose
-- effective_at <= now(). Returns (0, '-infinity') if no pricing row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compute_cost(
    p_provider           text,
    p_model              text,
    p_input_tokens       int,
    p_output_tokens      int,
    p_cache_write_tokens int DEFAULT 0,
    p_cache_read_tokens  int DEFAULT 0
) RETURNS TABLE (micro_dollars bigint, pricing_effective_at timestamptz)
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_pricing record;
    v_micro bigint;
BEGIN
    SELECT * INTO v_pricing
      FROM stewards.model_pricing
     WHERE provider = p_provider
       AND model = p_model
       AND effective_at <= now()
     ORDER BY effective_at DESC
     LIMIT 1;

    IF v_pricing IS NULL THEN
        -- No pricing row; zero cost and a sentinel timestamp.
        RETURN QUERY SELECT 0::bigint, '-infinity'::timestamptz;
        RETURN;
    END IF;

    -- Integer math throughout. tokens * micro_per_mtok / 1_000_000
    -- = micro_dollars contribution from that token category.
    v_micro := (p_input_tokens::bigint  * v_pricing.input_micro_per_mtok  / 1000000)
             + (p_output_tokens::bigint * v_pricing.output_micro_per_mtok / 1000000);

    IF v_pricing.cache_write_micro_per_mtok IS NOT NULL AND p_cache_write_tokens > 0 THEN
        v_micro := v_micro + (p_cache_write_tokens::bigint
                              * v_pricing.cache_write_micro_per_mtok / 1000000);
    END IF;

    IF v_pricing.cache_read_micro_per_mtok IS NOT NULL AND p_cache_read_tokens > 0 THEN
        v_micro := v_micro + (p_cache_read_tokens::bigint
                              * v_pricing.cache_read_micro_per_mtok / 1000000);
    END IF;

    RETURN QUERY SELECT v_micro, v_pricing.effective_at;
END;
$func$;

COMMENT ON FUNCTION stewards.compute_cost(text, text, int, int, int, int) IS
'Compute cost in micro-dollars from token usage. Picks most-recent pricing whose effective_at <= now().';

-- ---------------------------------------------------------------------
-- record_cost_event — the final 11-arg form (4g session plumbing +
-- es11 upstream cost). Inserts a cost_events row with computed
-- micro_dollars; the trigger updates work_items (when work_item_id is
-- non-NULL) + buckets. Pass p_session_id for chats not tied to a
-- work_item; p_upstream_micro carries the gateway-reported real cost.
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
'Records a cost_event. micro_dollars is computed (compute_cost: rate x tokens); p_upstream_micro carries the gateway-reported real cost into upstream_micro_dollars. Trigger updates work_items + buckets.';

-- ---------------------------------------------------------------------
-- cost_cap_exceeded(work_item) — true if the work_item has
-- cost_cap_micro set and cost_micro_dollars has reached it. Checked by
-- steward_tick before retry dispatch.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.cost_cap_exceeded(p_work_item_id uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $func$
    SELECT cost_cap_micro IS NOT NULL
           AND cost_micro_dollars >= cost_cap_micro
      FROM stewards.work_items
     WHERE id = p_work_item_id;
$func$;

-- ---------------------------------------------------------------------
-- Bucket helpers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.bucket_period_for(
    p_kind text,
    p_ts   timestamptz DEFAULT now()
) RETURNS TABLE (period_start timestamptz, period_end timestamptz)
LANGUAGE plpgsql IMMUTABLE AS $func$
BEGIN
    -- session_5h: 5-hour windows aligned to UTC midnight
    -- (00:00, 05:00, 10:00, 15:00, 20:00 UTC)
    IF p_kind = 'session_5h' THEN
        period_start := date_trunc('hour', p_ts)
                      - (extract(hour FROM p_ts)::int % 5) * interval '1 hour';
        period_end   := period_start + interval '5 hours';
    ELSIF p_kind = 'daily' THEN
        period_start := date_trunc('day', p_ts);
        period_end   := period_start + interval '1 day';
    ELSIF p_kind = 'weekly' THEN
        -- ISO week (Monday start).
        period_start := date_trunc('week', p_ts);
        period_end   := period_start + interval '1 week';
    ELSIF p_kind = 'monthly' THEN
        period_start := date_trunc('month', p_ts);
        period_end   := period_start + interval '1 month';
    ELSE
        RAISE EXCEPTION 'unknown bucket_kind: %', p_kind;
    END IF;
    RETURN NEXT;
END;
$func$;

-- bucket_current: the active bucket row for the current period, created
-- lazily. New periods inherit the most recent configured limit for the
-- (provider, kind).
CREATE OR REPLACE FUNCTION stewards.bucket_current(
    p_provider text,
    p_kind     text
) RETURNS stewards.cost_buckets
LANGUAGE plpgsql AS $func$
DECLARE
    v_period record;
    v_bucket stewards.cost_buckets;
    v_default_limit bigint;
BEGIN
    SELECT * INTO v_period
      FROM stewards.bucket_period_for(p_kind, now());

    SELECT * INTO v_bucket
      FROM stewards.cost_buckets
     WHERE provider = p_provider
       AND bucket_kind = p_kind
       AND period_start = v_period.period_start;

    IF v_bucket IS NOT NULL THEN
        RETURN v_bucket;
    END IF;

    SELECT bucket_limit_micro INTO v_default_limit
      FROM stewards.cost_buckets
     WHERE provider = p_provider
       AND bucket_kind = p_kind
       AND bucket_limit_micro IS NOT NULL
     ORDER BY period_start DESC
     LIMIT 1;

    INSERT INTO stewards.cost_buckets
        (provider, bucket_kind, period_start, period_end,
         micro_dollars, bucket_limit_micro)
    VALUES
        (p_provider, p_kind, v_period.period_start, v_period.period_end,
         0, v_default_limit)
    ON CONFLICT (provider, bucket_kind, period_start) DO NOTHING
    RETURNING * INTO v_bucket;

    -- If ON CONFLICT skipped (race), refetch.
    IF v_bucket IS NULL THEN
        SELECT * INTO v_bucket
          FROM stewards.cost_buckets
         WHERE provider = p_provider
           AND bucket_kind = p_kind
           AND period_start = v_period.period_start;
    END IF;

    RETURN v_bucket;
END;
$func$;

CREATE OR REPLACE FUNCTION stewards.bucket_record(
    p_provider     text,
    p_kind         text,
    p_micro_dollars bigint
) RETURNS void
LANGUAGE plpgsql AS $func$
DECLARE
    v_bucket stewards.cost_buckets;
BEGIN
    v_bucket := stewards.bucket_current(p_provider, p_kind);
    UPDATE stewards.cost_buckets
       SET micro_dollars = micro_dollars + p_micro_dollars
     WHERE id = v_bucket.id;
END;
$func$;

-- ---------------------------------------------------------------------
-- Trigger: maintain work_items.cost_micro_dollars + buckets on insert.
-- No-ops on the work_items UPDATE when work_item_id is NULL.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.cost_events_after_insert()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    UPDATE stewards.work_items
       SET cost_micro_dollars = cost_micro_dollars + NEW.micro_dollars,
           cost_capped_at = CASE
               WHEN cost_capped_at IS NOT NULL THEN cost_capped_at
               WHEN cost_cap_micro IS NOT NULL
                    AND (cost_micro_dollars + NEW.micro_dollars) >= cost_cap_micro
                    THEN now()
               ELSE NULL
           END
     WHERE id = NEW.work_item_id;

    -- Roll into all four bucket kinds for this provider.
    PERFORM stewards.bucket_record(NEW.provider, 'session_5h', NEW.micro_dollars);
    PERFORM stewards.bucket_record(NEW.provider, 'daily',      NEW.micro_dollars);
    PERFORM stewards.bucket_record(NEW.provider, 'weekly',     NEW.micro_dollars);
    PERFORM stewards.bucket_record(NEW.provider, 'monthly',    NEW.micro_dollars);

    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS cost_events_after_insert ON stewards.cost_events;
CREATE TRIGGER cost_events_after_insert
AFTER INSERT ON stewards.cost_events
FOR EACH ROW EXECUTE FUNCTION stewards.cost_events_after_insert();

-- ---------------------------------------------------------------------
-- Escalation: stage_models (per-(pipeline, stage) defaults) +
-- model_escalation ((current_model, diagnosis) -> next_model matrix) +
-- pick_model. The sentinel '__queue_for_opus__' returned by pick_model
-- means "transition to escalation_state='queued' instead of
-- dispatching" — the human-mediated escalation queue. Rows in both
-- tables are operator policy (your model chain); seed via the overlay.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.stage_models (
    pipeline_family   text NOT NULL,
    stage_name        text NOT NULL,
    default_model     text NOT NULL,
    notes             text,
    PRIMARY KEY (pipeline_family, stage_name)
);

COMMENT ON TABLE stewards.stage_models IS
'Per-(pipeline_family, stage) initial model for stage dispatch. pick_model() consults this for attempt=1. Operator policy — seed via the overlay.';

CREATE TABLE IF NOT EXISTS stewards.model_escalation (
    current_model     text NOT NULL,
    diagnosis         text NOT NULL CHECK (diagnosis IN
        ('transient','timeout','model_limit','tool_error','unknown')),
    attempt_threshold int NOT NULL DEFAULT 1 CHECK (attempt_threshold >= 1),
    next_model        text,  -- NULL = stay; '__queue_for_opus__' = sentinel
    notes             text,
    PRIMARY KEY (current_model, diagnosis),
    -- Prevent direct self-loops (multi-hop cycles still terminate via
    -- pick_model's attempt-bounded loop).
    CHECK (next_model IS NULL OR next_model != current_model)
);

COMMENT ON TABLE stewards.model_escalation IS
'Escalation matrix: given current_model + diagnosis, what model to retry on after attempt_threshold attempts. NULL next_model = stay; sentinel __queue_for_opus__ = enter the human-mediated escalation queue. Operator policy — seed via the overlay.';

CREATE OR REPLACE FUNCTION stewards.pick_model(
    p_pipeline_family text,
    p_stage_name      text,
    p_attempt         int,
    p_diagnosis       text DEFAULT 'initial'
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_current_model text;
    v_escalation    record;
    i               int;
BEGIN
    SELECT default_model INTO v_current_model
      FROM stewards.stage_models
     WHERE pipeline_family = p_pipeline_family
       AND stage_name = p_stage_name;

    IF v_current_model IS NULL THEN
        RAISE EXCEPTION 'no stage_models row for %/%',
            p_pipeline_family, p_stage_name;
    END IF;

    -- First attempt or sentinel diagnosis = no escalation.
    IF p_attempt <= 1 OR p_diagnosis = 'initial' OR p_diagnosis IS NULL THEN
        RETURN v_current_model;
    END IF;

    -- Walk the chain. For each attempt past 1, look up an escalation
    -- rule for (current_model, diagnosis) whose attempt_threshold is
    -- met. The queue sentinel returns immediately.
    FOR i IN 2..p_attempt LOOP
        SELECT * INTO v_escalation
          FROM stewards.model_escalation
         WHERE current_model = v_current_model
           AND diagnosis = p_diagnosis
           AND attempt_threshold <= i;

        IF v_escalation IS NULL OR v_escalation.next_model IS NULL THEN
            RETURN v_current_model;
        END IF;

        IF v_escalation.next_model = '__queue_for_opus__' THEN
            RETURN '__queue_for_opus__';
        END IF;

        v_current_model := v_escalation.next_model;
    END LOOP;

    RETURN v_current_model;
END;
$func$;

COMMENT ON FUNCTION stewards.pick_model(text, text, int, text) IS
'Picks the model for the next dispatch. Walks model_escalation per (attempt, diagnosis). Returns __queue_for_opus__ sentinel when the chain exhausts.';

-- ---------------------------------------------------------------------
-- provider_spend_caps — ENFORCED prepaid-balance caps (j11).
--
-- Distinct from cost_buckets (rolling + informational): a prepaid
-- balance only resets when the human refills. The dispatch gate
-- refuses a provider whose cost_events sum since `since` has reached
-- cap_micro AND enforced=true. Providers without a cap row (or
-- enforced=false) are never gated. Cap rows are operator data — seed
-- via the overlay.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.provider_spend_caps (
    provider    text PRIMARY KEY,
    cap_micro   bigint NOT NULL CHECK (cap_micro >= 0),
    since       timestamptz NOT NULL DEFAULT now(),
    enforced    boolean NOT NULL DEFAULT false,
    notes       text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.provider_spend_caps IS
'Enforced prepaid-balance spend caps per provider. The dispatch gate refuses a provider whose cost_events sum since `since` >= cap_micro AND enforced=true. Refill via provider_cap_refill(). Distinct from cost_buckets (rolling + informational).';

COMMENT ON COLUMN stewards.provider_spend_caps.since IS
'Refill epoch. Spend is summed from cost_events.at >= since. provider_cap_refill() moves this to now().';

CREATE OR REPLACE FUNCTION stewards.provider_spend_since(p_provider text)
RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT coalesce(sum(ce.micro_dollars), 0)::bigint
      FROM stewards.cost_events ce
      JOIN stewards.provider_spend_caps c ON c.provider = ce.provider
     WHERE ce.provider = p_provider
       AND ce.at >= c.since;
$$;

COMMENT ON FUNCTION stewards.provider_spend_since(text) IS
'Micro-dollars spent on a provider since its cap row''s refill epoch. 0 if no cap row.';

CREATE OR REPLACE FUNCTION stewards.provider_cap_exceeded(p_provider text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
          FROM stewards.provider_spend_caps c
         WHERE c.provider = p_provider
           AND c.enforced
           AND (SELECT coalesce(sum(ce.micro_dollars), 0)
                  FROM stewards.cost_events ce
                 WHERE ce.provider = p_provider
                   AND ce.at >= c.since) >= c.cap_micro
    );
$$;

COMMENT ON FUNCTION stewards.provider_cap_exceeded(text) IS
'True if the provider has an enforced cap and spend-since-refill has reached it. Checked by the dispatch gate before enqueuing a chat.';

CREATE OR REPLACE FUNCTION stewards.provider_cap_refill(
    p_provider      text,
    p_new_cap_micro bigint DEFAULT NULL
) RETURNS stewards.provider_spend_caps
LANGUAGE plpgsql AS $$
DECLARE
    v_row stewards.provider_spend_caps;
BEGIN
    UPDATE stewards.provider_spend_caps
       SET since      = now(),
           cap_micro  = COALESCE(p_new_cap_micro, cap_micro),
           updated_at = now()
     WHERE provider = p_provider
    RETURNING * INTO v_row;

    IF v_row.provider IS NULL THEN
        RAISE EXCEPTION 'provider_cap_refill: no cap row for provider %', p_provider;
    END IF;

    -- plpgsql RAISE supports only % substitution; pre-round the dollars.
    RAISE NOTICE 'provider_cap_refill: % refilled — since=now(), cap=% micro ($%)',
        p_provider, v_row.cap_micro, round(v_row.cap_micro / 1000000.0, 2);
    RETURN v_row;
END;
$$;

COMMENT ON FUNCTION stewards.provider_cap_refill(text, bigint) IS
'Top up a provider cap. Resets the spend-since-refill clock (since=now()) and optionally sets a new cap_micro. Run after refilling the real prepaid balance.';

-- ---------------------------------------------------------------------
-- classify_error(error_text) — read-time category for any stored error
-- string (work_items.error, work_queue.error). Most-specific first.
-- Note: some providers return HTTP 429 for BOTH rate limits and quota
-- exhaustion; the quota/RESOURCE_EXHAUSTED wording is checked first so
-- true budget exhaustion classifies as provider_budget.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.classify_error(p_error text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_error IS NULL OR btrim(p_error) = '' THEN 'none'
        WHEN p_error ILIKE '%spend cap reached%'
          OR p_error ILIKE '%provider_cap%'
          OR p_error ILIKE '%provider_cap_refill%'                 THEN 'spend_cap_reached'
        WHEN p_error ILIKE '%RESOURCE_EXHAUSTED%'
          OR p_error ILIKE '%exceeded your current quota%'
          OR p_error ILIKE '%billing%'
          OR p_error ILIKE '%out of credit%'
          OR p_error ILIKE '%insufficient%balance%'
          OR p_error ILIKE '%insufficient%credit%'
          OR p_error ILIKE '%quota%exceeded%'
          OR p_error ILIKE '%FAILED_PRECONDITION%'                 THEN 'provider_budget'
        WHEN p_error ILIKE '%rate limit%'
          OR p_error ILIKE '%rate_limit%'
          OR p_error ILIKE '%too many requests%'
          OR p_error ILIKE '%HTTP 429%'                            THEN 'rate_limited'
        WHEN p_error ILIKE '%HTTP 401%'
          OR p_error ILIKE '%HTTP 403%'
          OR p_error ILIKE '%PERMISSION_DENIED%'
          OR p_error ILIKE '%UNAUTHENTICATED%'
          OR p_error ILIKE '%API key%'
          OR p_error ILIKE '%invalid%key%'                         THEN 'auth'
        WHEN p_error ILIKE '%timeout%'
          OR p_error ILIKE '%timed out%'
          OR p_error ILIKE '%deadline%'                            THEN 'timeout'
        ELSE 'other'
    END
$$;

COMMENT ON FUNCTION stewards.classify_error(text) IS
'Classify a stored error string into a category (spend_cap_reached | provider_budget | rate_limited | auth | timeout | other | none). Read-time labeling for the work_items API + UI.';

CREATE OR REPLACE VIEW stewards.work_item_failures AS
SELECT wi.id,
       wi.slug,
       wi.pipeline_family,
       wi.status,
       stewards.classify_error(wi.error) AS error_category,
       wi.error,
       wi.updated_at
  FROM stewards.work_items wi
 WHERE wi.status = 'failed'
   AND wi.error IS NOT NULL
 ORDER BY wi.updated_at DESC;

COMMENT ON VIEW stewards.work_item_failures IS
'Failed work_items with a classified error_category. Quick triage: SELECT * FROM stewards.work_item_failures WHERE error_category = ''provider_budget'';';
