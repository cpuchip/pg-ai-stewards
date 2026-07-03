-- =====================================================================
-- 88-credentials.sql — in-app provider credentials + daily budgets (#256)
-- =====================================================================
-- Providers used to be env-only: STEWARDS_PROVIDER_<NAME>_* parsed once at
-- postmaster boot into an in-process registry, so adding a key meant .env
-- archaeology + a container restart + hand-written SQL seeds. The audit named
-- this the single largest first-run wall, and the field research converged on
-- the n8n/OpenHands/Dify/Airflow pattern: a setup wizard over an ENCRYPTED
-- in-app credential store, with two rules stolen verbatim — test-on-save
-- (validate the key when saved) and never echo the key (expose only is_set).
--
-- Shape (the encryption boundary is the point):
--   * stewards.credentials — name → AES-256-GCM ciphertext (bytea). SQL only
--     ever STORES bytes; encryption/decryption happens outside the table:
--     the Go cockpit encrypts on save, the Rust bgworker decrypts at
--     dispatch. Both sides key off the same STEWARDS_MASTER_KEY env var, so
--     no plaintext secret ever exists in a table, a log, or a query string.
--   * provider dials (base_url / kind / default_model) are NOT secret — they
--     live in stewards.config under provider.<name>.* keys (the audit's
--     "dials to config, secrets to credentials" split). credential_providers
--     joins the two into the one view the Rust registry overlay reads.
--   * a DB provider goes LIVE without a rebuild or restart: chat()/embed()
--     resolve through the view at dispatch time (providers.rs), and
--     providers_loaded() unions it, so alias resolution sees it too.
--   * budgets: provider_spend_caps (06) gains refill_cadence='daily' — the
--     cap window becomes "spend since midnight UTC" with NO reset job, by
--     computing the window start in the STABLE functions instead of mutating
--     `since`. NULL cadence keeps the existing prepaid-epoch behavior.
-- requires create_sticky_agent_family (86).
-- =====================================================================

-- ── the credential store ─────────────────────────────────────────────
-- No plaintext secret column, ever. secret_encrypted is AES-256-GCM
-- (12-byte nonce || ciphertext || 16-byte tag), keyed by STEWARDS_MASTER_KEY.
CREATE TABLE IF NOT EXISTS stewards.credentials (
    name             text PRIMARY KEY,
    provider         text NOT NULL,
    secret_encrypted bytea NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    last_verified_at timestamptz,
    note             text
);

COMMENT ON TABLE stewards.credentials IS
'88: encrypted provider API keys (the in-app credential store behind the setup
wizard). secret_encrypted is AES-256-GCM ciphertext produced by the Go cockpit
and decrypted by the Rust bgworker at dispatch — SQL never sees plaintext.
Surface it ONLY via credential_status(), which returns an is_set boolean and
never the bytes. Provider dials (base_url/kind/default_model) are non-secret
and live in stewards.config under provider.<name>.* keys.';

COMMENT ON COLUMN stewards.credentials.last_verified_at IS
'88: when the key last passed test-on-save (a live GET /models against the
provider, fired by the cockpit when the key is saved). NULL = never verified.';

-- ── credential_set — upsert ciphertext, never plaintext ──────────────
-- Deliberately takes bytea so a caller CANNOT pass a plaintext key through
-- SQL by accident — the encryption step is forced to happen before the call.
CREATE OR REPLACE FUNCTION stewards.credential_set(
    p_name             text,
    p_provider         text,
    p_secret_encrypted bytea,
    p_note             text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $fn$
BEGIN
    IF p_name IS NULL OR p_name = '' THEN
        RAISE EXCEPTION 'credential_set: name is required';
    END IF;
    IF p_provider IS NULL OR p_provider !~ '^[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'credential_set: provider must match ^[a-z0-9_]+$ (got %)', p_provider;
    END IF;
    IF p_secret_encrypted IS NULL OR length(p_secret_encrypted) = 0 THEN
        RAISE EXCEPTION 'credential_set: secret_encrypted is required (encrypt before storing; keyless providers need only dials — see provider_dials_set)';
    END IF;
    INSERT INTO stewards.credentials (name, provider, secret_encrypted, note)
    VALUES (p_name, p_provider, p_secret_encrypted, p_note)
    ON CONFLICT (name) DO UPDATE
       SET provider         = EXCLUDED.provider,
           secret_encrypted = EXCLUDED.secret_encrypted,
           note             = COALESCE(EXCLUDED.note, stewards.credentials.note),
           updated_at       = now(),
           -- a replaced key is an UNVERIFIED key until test-on-save passes again
           last_verified_at = NULL;
END;
$fn$;

COMMENT ON FUNCTION stewards.credential_set(text, text, bytea, text) IS
'88: upsert an encrypted credential. bytea-only on purpose — plaintext cannot
transit this function. Rotating a key clears last_verified_at (re-verify on save).';

-- ── credential_status — the ONLY read surface. Never the bytes. ──────
CREATE OR REPLACE FUNCTION stewards.credential_status()
RETURNS TABLE (
    name             text,
    provider         text,
    is_set           boolean,
    last_verified_at timestamptz,
    note             text
)
LANGUAGE sql STABLE AS $fn$
    SELECT c.name,
           c.provider,
           (length(c.secret_encrypted) > 0) AS is_set,
           c.last_verified_at,
           c.note
      FROM stewards.credentials c
     ORDER BY c.provider, c.name;
$fn$;

COMMENT ON FUNCTION stewards.credential_status() IS
'88: the never-echo-the-key read surface — name/provider/is_set/last_verified_at.
The ciphertext (let alone the plaintext) is deliberately absent from the columns.';

-- ── credential_mark_verified — test-on-save records its pass here ────
CREATE OR REPLACE FUNCTION stewards.credential_mark_verified(p_name text)
RETURNS boolean
LANGUAGE sql AS $fn$
    UPDATE stewards.credentials
       SET last_verified_at = now(), updated_at = now()
     WHERE name = p_name
    RETURNING true;
$fn$;

COMMENT ON FUNCTION stewards.credential_mark_verified(text) IS
'88: stamp last_verified_at after a successful live probe (test-on-save).
Returns true when the row existed, no rows otherwise.';

-- ── credential_delete ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.credential_delete(p_name text)
RETURNS boolean
LANGUAGE sql AS $fn$
    DELETE FROM stewards.credentials WHERE name = p_name RETURNING true;
$fn$;

COMMENT ON FUNCTION stewards.credential_delete(text) IS
'88: remove a stored credential. Dials in stewards.config are left alone
(a keyless provider — LM Studio — is dials with no credential row).';

-- ── provider_dials_set — the non-secret half of a wizard-added provider ──
-- Writes the provider.<name>.* config keys the credential_providers view (and
-- through it the Rust registry overlay) reads. Idempotent via config_set.
CREATE OR REPLACE FUNCTION stewards.provider_dials_set(
    p_provider      text,
    p_base_url      text,
    p_kind          text DEFAULT 'openai',
    p_default_model text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $fn$
BEGIN
    IF p_provider IS NULL OR p_provider !~ '^[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'provider_dials_set: provider must match ^[a-z0-9_]+$ (got %)', p_provider;
    END IF;
    IF p_base_url IS NULL OR p_base_url !~ '^https?://' THEN
        RAISE EXCEPTION 'provider_dials_set: base_url must be http(s) (got %)', p_base_url;
    END IF;
    IF p_kind NOT IN ('openai', 'anthropic') THEN
        RAISE EXCEPTION 'provider_dials_set: kind must be openai|anthropic (got %)', p_kind;
    END IF;
    PERFORM stewards.config_set('provider.' || p_provider || '.base_url',
                                to_jsonb(p_base_url),
                                '88: wizard-added provider endpoint');
    PERFORM stewards.config_set('provider.' || p_provider || '.kind',
                                to_jsonb(p_kind),
                                '88: wizard-added provider API kind');
    IF p_default_model IS NOT NULL AND p_default_model <> '' THEN
        PERFORM stewards.config_set('provider.' || p_provider || '.default_model',
                                    to_jsonb(p_default_model),
                                    '88: wizard-added provider default model');
    END IF;
END;
$fn$;

COMMENT ON FUNCTION stewards.provider_dials_set(text, text, text, text) IS
'88: write a provider''s non-secret dials to stewards.config (provider.<name>.*).
Pair with credential_set for keyed providers; alone for keyless (local) ones.';

-- ── credential_providers — the one view the Rust overlay reads ───────
-- A row per provider named by EITHER dials (config) OR a credential. Dials
-- may be NULL (credential-only row = a key rotation for an env-defined
-- provider: Rust merges the DB key over the env base_url/kind). Ciphertext is
-- exposed here for the DECRYPTING consumers (bgworker dispatch, the
-- decrypt-check) — it is the same bytes as the table, never plaintext.
CREATE OR REPLACE VIEW stewards.credential_providers AS
WITH dials AS (
    SELECT split_part(key, '.', 2) AS provider,
           split_part(key, '.', 3) AS field,
           value #>> '{}'          AS val
      FROM stewards.config
     WHERE key LIKE 'provider.%.%'
), byprov AS (
    SELECT provider,
           max(val) FILTER (WHERE field = 'base_url')      AS base_url,
           max(val) FILTER (WHERE field = 'kind')          AS kind,
           max(val) FILTER (WHERE field = 'default_model') AS default_model
      FROM dials
     GROUP BY provider
), cred AS (
    -- newest credential per provider wins (the schema allows several per
    -- provider for rotation; dispatch uses the freshest)
    SELECT DISTINCT ON (provider) provider, name AS credential_name, secret_encrypted
      FROM stewards.credentials
     ORDER BY provider, updated_at DESC
)
SELECT COALESCE(b.provider, c.provider)  AS provider,
       b.base_url,
       COALESCE(b.kind, 'openai')        AS kind,
       COALESCE(b.default_model, '')     AS default_model,
       c.credential_name,
       c.secret_encrypted
  FROM byprov b
  FULL JOIN cred c ON c.provider = b.provider;

COMMENT ON VIEW stewards.credential_providers IS
'88: DB-defined providers = config dials FULL JOIN newest credential. Read by
the Rust registry overlay (providers.rs) at dispatch time and by
providers_loaded() for the union — a wizard-added provider is live the moment
the row commits, no restart. base_url NULL = credential-only (key rotation for
an env provider); secret NULL = keyless local provider.';

-- ── daily budgets: provider_spend_caps grows a cadence ───────────────
-- 06's caps are prepaid-epoch ("spend since last refill"). A wizard budget
-- wants "N dollars per DAY" with zero moving parts — so the window start is
-- COMPUTED in the check ('daily' → midnight UTC caps the epoch), never
-- mutated. No reset job, no scheduler row, STABLE functions stay STABLE.
ALTER TABLE stewards.provider_spend_caps
    ADD COLUMN IF NOT EXISTS refill_cadence text
        CHECK (refill_cadence IN ('daily'));

COMMENT ON COLUMN stewards.provider_spend_caps.refill_cadence IS
'88: NULL = prepaid-epoch cap (06 behavior, window starts at `since`).
''daily'' = the window starts at greatest(since, date_trunc(''day'', now())) —
spend re-counts from midnight UTC each day, no reset job needed.';

-- Window helper: where does this cap row's spend window start right now?
CREATE OR REPLACE FUNCTION stewards.provider_cap_window_start(
    p_since timestamptz, p_cadence text
) RETURNS timestamptz
LANGUAGE sql STABLE AS $fn$
    SELECT CASE
        WHEN p_cadence = 'daily' THEN greatest(p_since, date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')
        ELSE p_since
    END;
$fn$;

COMMENT ON FUNCTION stewards.provider_cap_window_start(timestamptz, text) IS
'88: the effective spend-window start for a cap row — `since` for prepaid,
greatest(since, midnight UTC) for ''daily''. STABLE (not IMMUTABLE) on purpose:
it reads the clock, and constant-folding it into a cached plan would freeze
"midnight" on the plan''s day.';

-- Re-authored from 06 to honor the cadence. Same names + signatures, so the
-- dispatch gate and pick_alias_member keep working unchanged.
CREATE OR REPLACE FUNCTION stewards.provider_spend_since(p_provider text)
RETURNS bigint LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(sum(ce.micro_dollars), 0)::bigint
      FROM stewards.cost_events ce
      JOIN stewards.provider_spend_caps c ON c.provider = ce.provider
     WHERE ce.provider = p_provider
       AND ce.at >= stewards.provider_cap_window_start(c.since, c.refill_cadence);
$fn$;

COMMENT ON FUNCTION stewards.provider_spend_since(text) IS
'88 (re-authored from 06): micro-dollars spent on a provider inside its cap
window — since refill for prepaid rows, since midnight UTC for daily rows.
0 if no cap row.';

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
                   AND ce.at >= stewards.provider_cap_window_start(c.since, c.refill_cadence)
               ) >= c.cap_micro
    );
$fn$;

COMMENT ON FUNCTION stewards.provider_cap_exceeded(text) IS
'88 (re-authored from 06): true if the provider has an enforced cap and spend
inside the cap window (prepaid epoch, or the current UTC day for daily rows)
has reached it. Checked by the dispatch gate before enqueuing a chat.';

-- ── provider_budget_set — the wizard's one budget verb ───────────────
CREATE OR REPLACE FUNCTION stewards.provider_budget_set(
    p_provider  text,
    p_cap_micro bigint,               -- NULL = remove the cap entirely
    p_cadence   text DEFAULT 'daily'  -- 'daily' | NULL (prepaid epoch)
) RETURNS void
LANGUAGE plpgsql AS $fn$
BEGIN
    IF p_cap_micro IS NULL THEN
        DELETE FROM stewards.provider_spend_caps WHERE provider = p_provider;
        RETURN;
    END IF;
    IF p_cadence IS NOT NULL AND p_cadence <> 'daily' THEN
        RAISE EXCEPTION 'provider_budget_set: cadence must be ''daily'' or NULL (got %)', p_cadence;
    END IF;
    INSERT INTO stewards.provider_spend_caps (provider, cap_micro, enforced, refill_cadence, notes)
    VALUES (p_provider, p_cap_micro, true, p_cadence, '88: set via the setup wizard')
    ON CONFLICT (provider) DO UPDATE
       SET cap_micro      = EXCLUDED.cap_micro,
           refill_cadence = EXCLUDED.refill_cadence,
           enforced       = true,
           updated_at     = now();
END;
$fn$;

COMMENT ON FUNCTION stewards.provider_budget_set(text, bigint, text) IS
'88: upsert an ENFORCED per-provider budget ($5/day = (provider, 5000000,
''daily'')). NULL cap removes the row (no gate). The wizard defaults
opencode_zen to $5/day so sonnet-on-zen runs with a ceiling from day one.';
