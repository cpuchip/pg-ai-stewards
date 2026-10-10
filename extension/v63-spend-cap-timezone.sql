-- =====================================================================
-- v63-spend-cap-timezone.sql: a daily spend cap's day starts at midnight in
-- the cap row's own time zone.
--
-- v19 made refill_cadence = 'daily' re-count spend from midnight UTC. An
-- operator who budgets by local days ("$100 today") sees the cap roll over at
-- 19:00 in Chicago, and has to refill by hand at local midnight to line it
-- up. provider_spend_caps.tz (default 'UTC', so every existing row keeps its
-- behaviour) names the zone the day is counted in; the window helper,
-- provider_spend_since and provider_cap_exceeded read it. A name Postgres
-- cannot resolve is refused when it is written, not at the next dispatch.
-- =====================================================================

ALTER TABLE stewards.provider_spend_caps
    ADD COLUMN IF NOT EXISTS tz text NOT NULL DEFAULT 'UTC';

COMMENT ON COLUMN stewards.provider_spend_caps.tz IS
'v63: the time zone a ''daily'' cap counts its day in (an IANA name from
pg_timezone_names, e.g. ''America/Chicago''). Default ''UTC'', v19''s day.
Ignored for prepaid rows (refill_cadence NULL).';

CREATE OR REPLACE FUNCTION stewards.provider_cap_tz_check()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    PERFORM now() AT TIME ZONE NEW.tz;
    RETURN NEW;
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE EXCEPTION 'provider_spend_caps.tz: "%" is not a time zone this server knows (see pg_timezone_names)', NEW.tz
        USING ERRCODE = 'invalid_parameter_value';
END;
$fn$;

DROP TRIGGER IF EXISTS provider_spend_caps_tz_check ON stewards.provider_spend_caps;
CREATE TRIGGER provider_spend_caps_tz_check
    BEFORE INSERT OR UPDATE OF tz ON stewards.provider_spend_caps
    FOR EACH ROW EXECUTE FUNCTION stewards.provider_cap_tz_check();

CREATE OR REPLACE FUNCTION stewards.provider_cap_window_start(
    p_since timestamptz, p_cadence text, p_tz text
) RETURNS timestamptz
LANGUAGE sql STABLE AS $fn$
    SELECT CASE
        WHEN p_cadence = 'daily' THEN greatest(p_since,
            date_trunc('day', now() AT TIME ZONE coalesce(p_tz, 'UTC')) AT TIME ZONE coalesce(p_tz, 'UTC'))
        ELSE p_since
    END;
$fn$;

COMMENT ON FUNCTION stewards.provider_cap_window_start(timestamptz, text, text) IS
'v63: the spend-window start for a cap row: `since` for prepaid rows,
greatest(since, today''s midnight in p_tz) for ''daily''. STABLE because it reads
the clock (v19''s note).';

-- The two-argument form keeps v19's meaning (a UTC day) for any caller outside the chain.
CREATE OR REPLACE FUNCTION stewards.provider_cap_window_start(
    p_since timestamptz, p_cadence text
) RETURNS timestamptz
LANGUAGE sql STABLE AS $fn$
    SELECT stewards.provider_cap_window_start(p_since, p_cadence, 'UTC');
$fn$;

CREATE OR REPLACE FUNCTION stewards.provider_spend_since(p_provider text)
RETURNS bigint LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(sum(ce.micro_dollars), 0)::bigint
      FROM stewards.cost_events ce
      JOIN stewards.provider_spend_caps c ON c.provider = ce.provider
     WHERE ce.provider = p_provider
       AND ce.at >= stewards.provider_cap_window_start(c.since, c.refill_cadence, c.tz);
$fn$;

COMMENT ON FUNCTION stewards.provider_spend_since(text) IS
'v63 (re-authored from v19): micro-dollars spent on a provider inside its cap
window: since refill for prepaid rows, since midnight in the row''s tz for daily
rows. 0 if no cap row.';

CREATE OR REPLACE FUNCTION stewards.provider_cap_exceeded(p_provider text)
RETURNS boolean LANGUAGE sql STABLE AS $fn$
    SELECT EXISTS (
        SELECT 1
          FROM stewards.provider_spend_caps c
         WHERE c.provider = p_provider
           AND c.enforced
           AND (SELECT coalesce(sum(ce.micro_dollars), 0)
                  FROM stewards.cost_events ce
                 WHERE ce.provider = p_provider
                   AND ce.at >= stewards.provider_cap_window_start(c.since, c.refill_cadence, c.tz)
               ) >= c.cap_micro
    );
$fn$;

COMMENT ON FUNCTION stewards.provider_cap_exceeded(text) IS
'v63 (re-authored from v19): true if the provider has an enforced cap and spend
inside its window (prepaid epoch, or the current day in the row''s tz for daily
rows) has reached it. Checked by the dispatch gate before enqueuing a chat.';
