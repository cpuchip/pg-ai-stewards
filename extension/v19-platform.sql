-- ===== [was 88-credentials.sql] =====
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
-- ===== [was 89-attention.sql] =====
-- =====================================================================
-- 89-attention.sql — the unified "Needs your answer" surface (ladder Phase 2, partial)
-- =====================================================================
-- Michael's ratified ask ("stewdio for now, we could create a new panel for
-- notifications that need to be answered to make it super easy") pointed at
-- a real gap: every human-blocking case in the substrate had its OWN surface
-- — the Hinge queue (39), the tool-effect gate's tool-confirm reviews (84),
-- a paused pipeline stage (04 awaiting_review), an A2A blocking question (69
-- a2a_question) — each readable only by someone who already knew where to
-- look. This unions the real pending sets into ONE shape (needs_attention),
-- one cheap count (attention_count), and one router that resolves an answer
-- through the RIGHT existing verb per kind (attention_answer) — no
-- reimplementation of tool_confirm_verdict / hinge_record_verdict /
-- a2a_answer / work_item_dispatch_stage, all of which already enforce their
-- own bounds (84's escalate-always wall, 39's D&C 121 wall).
--
-- Also lands ladder Phase 2's ask_up: a weak/local model consults the NEXT
-- enabled rung on 84's escalation_ladder — NO authority transfer, just an
-- answer to reason with (the ladder's rung 1). When the caller is already at
-- (or above) the top enabled rung, there is nowhere higher to ask — it
-- surfaces as an 'ask' row in needs_attention instead, so it never silently
-- strands. Phase 2 minimal: no autopilot, no notify service, no min_tier
-- knob — see .spec/proposals/hinge-and-escalation-ladder.md Piece 3.
--
-- requires create_sticky_agent_family (86) — installs at the tail.
-- =====================================================================

-- =====================================================================
-- §1 — needs_attention: the union of every human-blocking source.
-- =====================================================================
-- Five source_kinds, five real pending sets (discovered by reading the SQL,
-- not guessed):
--   gate         — 84's tool-confirm reviews (hinge_reviews kind='tool-confirm',
--                  status pending/escalated). The withheld dangerous tool call.
--   ask          — a free-standing question (hinge_reviews kind='ask') — today
--                  only ask_up's top-rung fallback writes these (§3).
--   hinge        — every OTHER Hinge review kind (digest-skill-rule, graph-reorg,
--                  cutover, …) pending/escalated — the 39 queue, minus the two
--                  kinds broken out above so each row appears in exactly one bucket.
--   a2a_question — 69's INPUT_REQUIRED: work_items.status='awaiting_review' WITH
--                  a2a_question set (the exact blocking question a claimed A2A
--                  task raised).
--   review       — a paused PIPELINE stage with NO a2a_question: status=
--                  'awaiting_review' because auto_advance=false, a token-budget
--                  hit, or a dispatch failure (04 §"Status lifecycle"). Not a
--                  question-answer — a human ack-to-continue.
-- Same shape throughout so the UI renders one card type: source_kind,
-- source_id (text — the id space differs per kind: hinge_reviews.id is
-- bigint, work_items.id is uuid), title, question, options (jsonb array of
-- quick-reply strings, or NULL = free-text answer), created_at, work_item_id
-- (uuid, where one exists).
CREATE OR REPLACE VIEW stewards.needs_attention AS
SELECT
    'gate'::text                                        AS source_kind,
    id::text                                            AS source_id,
    format('Approve tool call: %s', payload->>'tool')   AS title,
    subject                                             AS question,
    '["approve","decline"]'::jsonb                      AS options,
    created_at,
    nullif(payload->>'work_item_id','')::uuid           AS work_item_id
  FROM stewards.hinge_reviews
 WHERE kind = 'tool-confirm' AND status IN ('pending','escalated')

UNION ALL
SELECT
    'ask'::text,
    id::text,
    subject,
    coalesce(payload->>'question', subject),
    NULL::jsonb,
    created_at,
    nullif(payload->>'work_item_id','')::uuid
  FROM stewards.hinge_reviews
 WHERE kind = 'ask' AND status IN ('pending','escalated')

UNION ALL
SELECT
    'hinge'::text,
    id::text,
    subject,
    coalesce(payload->>'reason', subject),
    '["approve","revise","decline"]'::jsonb,
    created_at,
    nullif(payload->>'work_item_id','')::uuid
  FROM stewards.hinge_reviews
 WHERE kind NOT IN ('tool-confirm','ask') AND status IN ('pending','escalated')

UNION ALL
SELECT
    'a2a_question'::text,
    id::text,
    coalesce(input->>'title', '(untitled)'),
    a2a_question,
    NULL::jsonb,
    updated_at,
    id
  FROM stewards.work_items
 WHERE status = 'awaiting_review' AND a2a_question IS NOT NULL

UNION ALL
SELECT
    'review'::text,
    id::text,
    coalesce(input->>'title', pipeline_family || ' / ' || current_stage),
    coalesce(error, format('Stage "%s" complete — review and continue', current_stage)),
    NULL::jsonb,
    updated_at,
    id
  FROM stewards.work_items
 WHERE status = 'awaiting_review' AND a2a_question IS NULL
;

COMMENT ON VIEW stewards.needs_attention IS
'89: every human-blocking item, one shape. gate=84 tool-confirm reviews; ask=free-standing questions (ask_up''s top-rung fallback, §3); hinge=every other Hinge review kind (39); a2a_question=69 INPUT_REQUIRED (the exact blocking question); review=a paused pipeline stage with no question (ack-to-continue). options=NULL means free-text (the UI renders a text input); a jsonb array of strings means quick-reply buttons. Backs the Stewdio "Needs your answer" bell.';

-- ── needs_attention_list — the jsonb-agg wrapper the Go API scans (mirrors
--    tool_confirm_pending's shape: one row → jsonb_agg, so a2aQuery's plain
--    "SELECT fn()" passthrough works unchanged).
CREATE OR REPLACE FUNCTION stewards.needs_attention_list(p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(a ORDER BY a.created_at), '[]'::jsonb)
      FROM (SELECT * FROM stewards.needs_attention ORDER BY created_at LIMIT p_limit) a;
$fn$;

COMMENT ON FUNCTION stewards.needs_attention_list(int) IS
'89: needs_attention as a jsonb array, oldest first, capped at p_limit. The Stewdio bell''s list call.';

-- ── attention_count — the cheap badge count.
CREATE OR REPLACE FUNCTION stewards.attention_count()
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT jsonb_build_object('count', count(*)) FROM stewards.needs_attention;
$fn$;

COMMENT ON FUNCTION stewards.attention_count() IS
'89: {"count": N} — how many items need Michael''s answer right now. Cheap (STABLE, no joins beyond the view''s own unions). The Stewdio bell badge.';

-- =====================================================================
-- §2 — ask_record_answer: the ONE kind with no existing resolver.
-- =====================================================================
-- Every other kind routes to a resolver 39/69/84 already built. 'ask' is
-- new (born here, §3) and is NOT a proposal (approve/revise/decline) — it is
-- a free-text QUESTION needing a free-text ANSWER, so hinge_record_verdict's
-- verdict vocabulary doesn't fit. GAP (named, not hidden): this records the
-- answer on the hinge_reviews row but does NOT yet deliver it back to the
-- asking agent/work item — there is no live round-trip today. That delivery
-- is Phase 3 (Stewdio surface polish / the notify service, per the proposal's
-- build-phases list); until then the asker (or a teammate) reads the answer
-- off the resolved hinge_reviews row.
CREATE OR REPLACE FUNCTION stewards.ask_record_answer(p_hinge_id bigint, p_answer text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_row stewards.hinge_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM stewards.hinge_reviews WHERE id = p_hinge_id AND kind = 'ask';
    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'note', 'no such ask (wrong id or not kind=ask)');
    END IF;
    IF v_row.status NOT IN ('pending','escalated') THEN
        RETURN jsonb_build_object('ok', false, 'note', format('ask already %s', v_row.status));
    END IF;

    UPDATE stewards.hinge_reviews
       SET status      = 'applied',
           verdict     = 'answered',
           reason      = p_answer,
           reviewed_by = 'michael',
           reviewed_at = now(),
           applied_at  = now(),
           payload     = payload || jsonb_build_object('answer', p_answer)
     WHERE id = p_hinge_id;

    RETURN jsonb_build_object('ok', true, 'hinge_id', p_hinge_id, 'status', 'applied', 'answer', p_answer);
END;
$fn$;

COMMENT ON FUNCTION stewards.ask_record_answer(bigint, text) IS
'89: records Michael''s free-text answer to an ask (hinge_reviews kind=ask). GAP: does not yet deliver the answer back to the asking agent/work item — that live round-trip is Phase 3 (Stewdio surface polish / the notify service). Today the answer lives on the resolved hinge_reviews row.';

-- =====================================================================
-- §3 — attention_answer: route to the RIGHT existing resolver per kind.
-- =====================================================================
-- p_id is text, not one narrow type — the id space genuinely differs per
-- kind (hinge_reviews.id is bigint; work_items.id is uuid), and the view
-- already carries source_id as text for exactly this reason. Each branch
-- casts to the resolver's real parameter type and calls it VERBATIM — no
-- reimplementation of tool_confirm_verdict / hinge_record_verdict /
-- a2a_answer / work_item_dispatch_stage, so their existing bounds (84's
-- escalate-always wall; 39's auto-approve/escalate-always wall) apply
-- exactly as they do everywhere else those verbs are called.
CREATE OR REPLACE FUNCTION stewards.attention_answer(
    p_kind   text,
    p_id     text,
    p_answer text
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
    IF p_kind = 'gate' THEN
        -- 84's resolver: records Michael's verdict AND executes the STORED
        -- call verbatim on approve (idempotent; declines execute nothing).
        RETURN stewards.tool_confirm_verdict(p_id::bigint, p_answer, NULL, 'michael');

    ELSIF p_kind = 'hinge' THEN
        -- 39's resolver: bounds-enforced (hinge_auto_approve_kinds /
        -- hinge_escalate_always_kinds); reviewer='michael' so the verdict
        -- is final regardless of kind.
        RETURN stewards.hinge_record_verdict(p_id::bigint, p_answer, NULL, 'michael');

    ELSIF p_kind = 'ask' THEN
        -- No existing resolver fits a free-text Q&A (§2's gap, named there).
        RETURN stewards.ask_record_answer(p_id::bigint, p_answer);

    ELSIF p_kind = 'a2a_question' THEN
        -- 69's resolver: clears a2a_question, returns the task to
        -- in_progress, drops an answer-note in the worker's inbox.
        RETURN stewards.a2a_answer(p_id::uuid, p_answer);

    ELSIF p_kind = 'review' THEN
        -- No dedicated "review" resolver exists — the real resume path IS
        -- re-dispatching the paused stage (04's own status-check already
        -- accepts 'awaiting_review'). A non-empty p_answer becomes that
        -- stage's user_input override (the same one-shot override the
        -- steward's own retries use); empty/whitespace resumes with the
        -- stage's normal templated input.
        RETURN jsonb_build_object(
            'work_item_id',  p_id::uuid,
            'dispatched',    true,
            'work_queue_id', stewards.work_item_dispatch_stage(
                                  p_id::uuid, nullif(btrim(coalesce(p_answer,'')), '')));
    ELSE
        RETURN jsonb_build_object('ok', false, 'note', format('attention_answer: unknown source_kind %s', p_kind));
    END IF;
END;
$fn$;

COMMENT ON FUNCTION stewards.attention_answer(text, text, text) IS
'89: the ONE answer-routing entry point the Stewdio bell calls. Dispatches by source_kind to the resolver that kind ALREADY has: gate->tool_confirm_verdict (84), hinge->hinge_record_verdict (39), a2a_question->a2a_answer (69), review->work_item_dispatch_stage (04, re-dispatch resumes the paused stage), ask->ask_record_answer (89 §2, the one genuinely new kind). Never reimplements a resolver''s bounds.';

-- =====================================================================
-- §4 — ask_up: ladder Phase 2's model-tier consult.
-- =====================================================================
-- escalation_ladder_current_rung — best-effort map a work_item to the rung
-- ITS CALLER is running at: model_override (the one-shot pin most callers —
-- the steward, a pinned chat turn — set) if present, else the pipeline
-- stage's own declared model. Unlisted → rung 0 (the proposal's "unlisted →
-- rung 0" — weaker than anything on the ladder, so ANY enabled rung is
-- "up" from it).
CREATE OR REPLACE FUNCTION stewards.escalation_ladder_current_rung(p_work_item uuid)
RETURNS int LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_wi    stewards.work_items%ROWTYPE;
    v_model text;
    v_rung  int;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item;
    IF v_wi.id IS NULL THEN RETURN 0; END IF;

    v_model := v_wi.model_override;
    IF v_model IS NULL THEN
        v_model := (stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage))->>'model';
    END IF;

    SELECT rung INTO v_rung FROM stewards.escalation_ladder WHERE model_alias = v_model;
    RETURN coalesce(v_rung, 0);
END;
$fn$;

COMMENT ON FUNCTION stewards.escalation_ladder_current_rung(uuid) IS
'89: the CALLER''s rung on 84''s escalation_ladder — model_override if the work_item has a one-shot pin, else the current stage''s declared model. No ladder row matches (or the work_item is gone) -> rung 0, the proposal''s "unlisted -> rung 0."';

-- ask_up — Piece 3 of the ladder (.spec/proposals/hinge-and-escalation-ladder.md):
-- consult a STRONGER model; NO authority transfer, NO side effect. The
-- caller still decides and still hits the tool-effect gate (84) for
-- anything dangerous — this only widens what it reasons with.
--   * A higher enabled rung exists above the caller's own rung: dispatch a
--     ONE-SHOT consult via the EXISTING chat machinery (dispatch_chat_turn,
--     45 — session-ensure + alias->concrete-model resolution + chat_enqueue;
--     the same enqueue path Stewdio's "chat with a work item" and the
--     model-pin escalation already use). The answer lands in stewards.messages
--     for the returned session_id; nothing here blocks on it or applies it.
--   * No higher enabled rung (the caller is already AT or ABOVE the top): there
--     is nowhere higher to ask — park it as a human 'ask' (hinge_enqueue) so
--     it surfaces in needs_attention rather than silently stranding.
-- Phase 2 minimal, per the proposal: no min_tier knob, no autopilot, no
-- notify service — just the two branches the ladder needs to exist at all.
CREATE OR REPLACE FUNCTION stewards.ask_up(
    p_work_item uuid,
    p_question  text,
    p_context   jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_rung       int  := stewards.escalation_ladder_current_rung(p_work_item);
    v_next_rung  int;
    v_next_alias text;
    v_session    text;
    v_wq_id      bigint;
    v_hinge_id   bigint;
BEGIN
    IF p_question IS NULL OR length(btrim(p_question)) = 0 THEN
        RAISE EXCEPTION 'ask_up: question is required';
    END IF;

    SELECT rung, model_alias INTO v_next_rung, v_next_alias
      FROM stewards.escalation_ladder
     WHERE enabled AND rung > v_rung
     ORDER BY rung ASC
     LIMIT 1;

    IF v_next_alias IS NOT NULL THEN
        v_session := substring(
            'askup--' || substring(p_work_item::text from 1 for 8)
            || '--' || substring(md5(p_question || clock_timestamp()::text) from 1 for 8)
            FROM 1 FOR 200);

        v_wq_id := stewards.dispatch_chat_turn(
            v_session,
            p_question || CASE WHEN coalesce(p_context, '{}'::jsonb) <> '{}'::jsonb
                                THEN E'\n\nContext: ' || p_context::text ELSE '' END,
            'work-item-chat',
            v_next_alias,
            format('You are being consulted by another agent working on work_item %s (rung %s). '
                   || 'Answer plainly — you are advising, not taking over the task.', p_work_item, v_rung));

        RETURN jsonb_build_object(
            'escalated_to',  'consult',
            'rung',          v_next_rung,
            'model_alias',   v_next_alias,
            'session_id',    v_session,
            'work_queue_id', v_wq_id,
            'note', 'no authority transfer — the answer lands in stewards.messages for this session; the caller still decides and still hits the tool-effect gate for anything dangerous.'
        );
    END IF;

    v_hinge_id := stewards.hinge_enqueue(
        'ask',
        left(p_question, 120),
        jsonb_build_object('question', p_question, 'context', coalesce(p_context, '{}'::jsonb),
                            'work_item_id', p_work_item, 'caller_rung', v_rung),
        'ask_up');

    RETURN jsonb_build_object(
        'escalated_to', 'human',
        'hinge_id',     v_hinge_id,
        'note', 'already at (or above) the top enabled rung — parked for Michael in needs_attention (kind=ask).'
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.ask_up(uuid, text, jsonb) IS
'89: ladder Phase 2 — the caller consults the NEXT enabled rung above its own (escalation_ladder_current_rung) via a one-shot dispatch_chat_turn (45''s existing enqueue machinery; NO authority transfer, NO side effect). No higher enabled rung -> hinge_enqueue(kind=ask), surfacing in needs_attention for Michael instead of silently stranding. Phase 2 minimal: no min_tier, no autopilot (Phase 4, council-gated).';

-- =====================================================================
-- End of 89-attention.sql
-- =====================================================================
-- ===== [was 90-harness-executor.sql] =====
-- =====================================================================
-- 90-harness-executor.sql — the harness executor (loom Phase 1, ratified 2026-07-03)
-- =====================================================================
-- The substrate becomes a metaharness: harness_run dispatches a stage's task
-- to a FULL Claude Code harness as a subprocess (`loom run --isolate`), the
-- tier above the native loop for hard, multi-file, corpus-grounded work. The
-- native loop stays fully capable — this is a tier, not a replacement. The Go
-- handler lives in the bridge (cmd/stewards-mcp/harness.go), the same way the
-- other agentic wrappers do; the loom Reply's session_id is the durable
-- resume handle, ledgered here on stewards.harness_runs.
--
-- Phase 1 scope (ratified plan .spec/proposals/loom-integration.md):
--   * PULL-only, read-mostly: the harness reads its mounted workdir with its
--     own tools and (where the operator wires the hinge) the substrate's
--     Arc C READ-ONLY HTTP surface. It cannot write to the substrate, submit
--     a2a work, or spawn anything — those tools are absent from the surface
--     it can reach, not merely un-prompted.
--   * NO default routing: only the harness-pilot family holds the grant, and
--     the harness-review pipeline is reached by EXPLICIT routing only.
--   * Write-back (Phase 2) and tier routing (Phase 3) are dominion_in_council
--     gates — deliberately NOT built here.
--
-- effect_class reasoning (84's taxonomy, read before classifying): harness_run
-- executes a whole agent in a sandbox. Judged against the dangerous three:
--   external_send — no: the dispatch sends nothing outward; the container's
--     only wired reach is the read-only substrate MCP surface.
--   irreversible  — no: the container is ephemeral (--rm); the workdir is the
--     only mutable surface and Phase-1 tooling is read-only (Read/Glob/Grep).
--   financial     — no: auth is a subscription credential; cost_usd is
--     accounting we ledger, not a transaction the tool performs.
-- Agentic execution is a genuinely new category none of the classes name, so
-- the honest tag is 'unclassified' — Michael ratified NOT gating unclassified
-- (84's gate_unclassified default false). An operator who flips
-- gate_unclassified gets a confirmation pause on every harness dispatch,
-- which is exactly the conservative behavior that switch promises.
--
-- requires create_sticky_agent_family (86) — installs at the tail of the
-- chain. (87–89 are sibling-build slots; the integrator re-stitches requires.)
-- =====================================================================

-- =====================================================================
-- §1 — the dispatch ledger. session_id on the ledger = the durable resume
-- handle (loom --resume <harness_session_id> + the same claude-home).
-- =====================================================================
CREATE TABLE IF NOT EXISTS stewards.harness_runs (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id         text,            -- the substrate session that dispatched (injected by the dispatcher)
    work_item_id       uuid,            -- best-effort via stewards.session_work_item(session_id)
    backend            text NOT NULL DEFAULT 'claude',
    workdir            text,            -- host dir mounted as the harness's /work (NULL = scratch)
    prompt             text NOT NULL,
    harness_session_id text,            -- loom Reply.session_id — THE durable resume handle
    cost_usd           numeric(12,6),
    turns              int,
    status             text NOT NULL DEFAULT 'done'
                       CHECK (status IN ('done','error')),
    error              text,
    created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS harness_runs_session_idx
    ON stewards.harness_runs (session_id, created_at DESC);

COMMENT ON TABLE stewards.harness_runs IS
'90: the harness-dispatch ledger — one row per harness_run (loom Phase 1). harness_session_id is the durable resume handle: a later dispatch resumes it with loom --resume + the same claude-home. cost_usd/turns come from loom''s --json Reply; work_item_id resolves best-effort from the dispatch session (84''s session_work_item). Failures ledger too (status=error) so cost and breakage share one surface.';

COMMENT ON COLUMN stewards.harness_runs.harness_session_id IS
'90: the Claude Code session id from loom''s Reply — the resume handle. Resume requires re-mounting the SAME claude-home (the session state lives there); without it an isolated --resume silently starts fresh.';

-- =====================================================================
-- §2 — tool_defs registration. mcp_proxy → the substrate''s own stdio
-- surface (the research_codebase shape); the Go handler execs loom.
-- effect_class seeds 'unclassified' (header reasoning) and the ON CONFLICT
-- deliberately does NOT touch it — an operator''s tag sticks (84 §2).
-- =====================================================================
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active)
VALUES
('harness_run',
 'Dispatch a task to a FULL Claude Code harness (via loom) running isolated in a docker sandbox — the tier above the native loop for hard, multi-file work grounded in a real directory. The harness reads the mounted workdir with its own tools and (where the hinge is wired) the substrate''s READ-ONLY doc/work-item surface. Phase 1 is read-mostly: it cannot write to the substrate, submit a2a work, or spawn anything. Returns the harness''s answer + session_id (the durable resume handle, ledgered on stewards.harness_runs) + cost. EXPENSIVE — one call is a whole agent run; use the native loop for cheap/bulk work.',
 '{"type":"object","required":["prompt"],"additionalProperties":false,"properties":{"prompt":{"type":"string","description":"The task for the harness — the full prompt Claude Code receives (the workdir is its corpus; the prompt is the task)."},"workdir":{"type":"string","description":"Optional HOST directory bind-mounted as the harness''s working dir (/work) — the code/context it reads. Default: an empty scratch dir."},"backend":{"type":"string","description":"loom backend (default claude)."},"timeout_seconds":{"type":"integer","description":"Wall-clock cap for the whole dispatch (default 600, max 3600)."}}}'::jsonb,
 jsonb_build_object('kind','mcp_proxy','server','pg-ai-stewards','tool','harness_run','inject_session',true),
 'unclassified',
 true)
ON CONFLICT (name) DO UPDATE
   SET description    = EXCLUDED.description,
       args_schema    = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target,
       active         = EXCLUDED.active;

-- ── keep inject_session sticky across refresh-tools rewrites ─────────
-- 52's trigger re-stamps the flag every time a tool_defs row is written
-- (refresh-tools rebuilds execute_target wholesale). Re-author it with
-- harness_run added: the ledger must record the DISPATCH session, and the
-- dispatcher — not the model — is the oracle for which session that is.
-- (coder_export_artifact stays excluded; see 52's header — it routes
-- cross-session on purpose.)
CREATE OR REPLACE FUNCTION stewards.tool_def_inject_session()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.name IN ('generate_image', 'harness_run') THEN
        NEW.execute_target :=
            coalesce(NEW.execute_target, '{}'::jsonb)
            || jsonb_build_object('inject_session', true);
    END IF;
    RETURN NEW;
END;
$fn$;

-- =====================================================================
-- §3 — the harness-pilot family: the ONE holder of the grant.
-- =====================================================================
-- Deny-by-default already keeps harness_run off every other family; the
-- explicit work-item-chat deny below turns the ratified wall ("no existing
-- family gets it") into a row a future session must consciously delete,
-- not merely an absence it might not notice.
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES ('harness-pilot', '*',
 'Pilot for harness_run (90). Dispatches a stage''s task to the full Claude Code harness (loom, isolated) and relays the answer verbatim. Holds harness_run and nothing else.',
 'primary',
 $PROMPT$You are the harness pilot. Your ONLY tool is harness_run — it hands the task to a FULL Claude Code harness running isolated in a docker sandbox, with read-only substrate access. You dispatch; the harness does the work.

Method:
1. Call harness_run exactly once: prompt = the task text you were given, verbatim — do not summarize, translate, or embellish it. Pass workdir only if the task names a host directory to work against.
2. When it returns, relay the harness's answer verbatim, keeping the [harness_run complete — …] metadata line (its session id is the durable resume handle).
3. If it errors, report the error plainly and stop. Do not retry on your own, do not fabricate an answer, and never claim the harness said something it did not.$PROMPT$,
 0.1, 4)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description,
       mode        = EXCLUDED.mode,
       prompt      = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature,
       steps       = EXCLUDED.steps,
       active      = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
VALUES ('harness-pilot', 'harness_run', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action,
       source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- The ratified wall, as a row: the cockpit chat must never grow this tool.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
VALUES ('work-item-chat', 'harness_run', 'deny', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action,
       source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- =====================================================================
-- §4 — the harness-review pipeline: EXPLICIT routing only.
-- =====================================================================
-- A single dispatch stage so a work item CAN route to the harness by naming
-- pipeline_family='harness-review' — and nothing routes here by default
-- (metadata.no_default_routing documents the council gate; Phase 3 tier
-- routing is where that decision would live, after council).
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES ('harness-review',
 '90: single-stage harness dispatch — harness-pilot hands the binding question to a full Claude Code harness (loom, isolated, read-mostly) and relays the answer. Explicit routing only; never a default route (Phase 3 tier routing is council-gated).',
 '[{"name": "dispatch", "next": null, "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "harness-pilot", "auto_advance": true, "input_template": "Dispatch this task to the full Claude Code harness via harness_run.\n\nTASK (pass to harness_run as prompt, verbatim):\n{{input.binding_question}}\n\nWorkdir (pass to harness_run as workdir if non-empty): {{input.workdir}}\n\nCall harness_run once, then relay its answer verbatim including the metadata line.", "tools_disabled": false}]'::jsonb,
 'f', 'f', '["raw", "verified"]'::jsonb, 'f',
 '{"shape": "harness-dispatch", "wrapper": "harness_run", "read_only": true, "no_default_routing": true, "phase": "loom-phase-1"}'::jsonb)
ON CONFLICT (family) DO UPDATE
   SET stages = EXCLUDED.stages, description = EXCLUDED.description, metadata = EXCLUDED.metadata;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('harness-review', 'dispatch', 'kimi-k2.6',
     'Thin pilot turn: call harness_run with the binding question, relay verbatim. The harness inside does the heavy lifting; this stage needs reliability, not brilliance.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('harness-review', 'dispatch', 'verified',
     'The harness answered; its session id + cost are on stewards.harness_runs.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

-- =====================================================================
-- §5 — write-back addendum (ratified "1B", 2026-07-03): "harness write-back
-- with a NARROW write set." This is a small, idempotent addition to the file
-- ABOVE rather than a new chain number, since 90 is already the harness file
-- and re-applying it whole is the documented live-install path.
--
-- What "the write set" actually is (verified against the live tool surface,
-- not guessed): 34-doc-builder.sql already built doc_create / doc_append_
-- section / doc_patch / doc_read / doc_finalize / doc_current as
-- stewards.tool_defs rows — but only the substrate's OWN internal per-
-- pipeline tool-calling loop could ever reach them; no MCP server exposed
-- them. cmd/stewards-mcp/doc_write.go is the missing wiring: real MCP tools
-- calling these SAME SQL functions, now reachable from the harness's Arc C
-- HTTP hinge (cmd/stewards-mcp/http.go) and the STEWARDS_HARNESS_ALLOWED_
-- TOOLS default (harness.go's harnessSubstrateWriteTools). a2a_note /
-- a2a_note_clear already existed as real MCP tools (69-a2a-engine.sql +
-- a2a.go) but only bundled with the FULL a2a surface (a2a_submit, a2a_claim,
-- a2a_receipt, ...); registerA2ANoteTools (a2a.go) splits them out so the
-- harness hinge can carry "leave a note" without "hand off/claim/receipt
-- work." No new SQL functions, no new semantics — a second, narrower front
-- door onto code that already worked.
--
-- Two DIFFERENT walls, both updated here for consistency (do not conflate
-- them): (a) agent_tool_perms below governs what the SUBSTRATE'S OWN
-- internal dispatch loop lets the harness-pilot family's thin pilot model
-- call THROUGH THE SUBSTRATE (today, by its own prompt in §3, that pilot
-- calls harness_run and nothing else — these grants are forward-looking
-- consistency, not a currently-exercised path). (b) the ACTUAL loom-
-- dispatched Claude Code harness reaches the substrate ONLY through the Arc C
-- HTTP MCP surface (http.go) + whatever --allowed-tools names (harness.go) —
-- an entirely separate mechanism this file's rows do not touch.
-- =====================================================================

-- the model-passthrough ledger column (harness.go's HarnessRunInput.Model /
-- resolveHarnessModel — sonnet|haiku|opus, default sonnet for the claude
-- backend). Nullable: rows ledgered before this column existed have no value.
ALTER TABLE stewards.harness_runs ADD COLUMN IF NOT EXISTS model text;
COMMENT ON COLUMN stewards.harness_runs.model IS
'90 (1B): the Claude Code --model alias this dispatch ran as (sonnet|haiku|opus). NULL for runs ledgered before model passthrough shipped.';

-- keep the tool_defs args_schema (the substrate-facing JSON schema for
-- harness_run, used when the substrate calls a model through its own
-- function-calling loop) in sync with the Go MCP tool's actual input.
UPDATE stewards.tool_defs
   SET args_schema = '{"type":"object","required":["prompt"],"additionalProperties":false,"properties":{"prompt":{"type":"string","description":"The task for the harness — the full prompt Claude Code receives (the workdir is its corpus; the prompt is the task)."},"workdir":{"type":"string","description":"Optional HOST directory bind-mounted as the harness''s working dir (/work) — the code/context it reads. Default: an empty scratch dir."},"backend":{"type":"string","description":"loom backend (default claude)."},"model":{"type":"string","enum":["sonnet","haiku","opus"],"description":"Claude model alias to run as (default sonnet). haiku for cheap/bulk, opus when the dispatch is worth it."},"timeout_seconds":{"type":"integer","description":"Wall-clock cap for the whole dispatch (default 600, max 3600)."}}}'::jsonb
 WHERE name = 'harness_run';

-- the narrow write-set grants for harness-pilot (see the header note above:
-- this governs the SUBSTRATE'S internal loop, not the external harness's Arc
-- C reach). Idempotent; source='manual' so a broadcast/reimport never
-- silently overrides an explicit decision here.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
SELECT 'harness-pilot', v.tool, 'allow', 'manual'
  FROM unnest(ARRAY[
        'doc_create', 'doc_append_section', 'doc_patch', 'doc_read', 'doc_finalize', 'doc_current',
        'a2a_note', 'a2a_note_clear'
       ]) AS v(tool)
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action,
       source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

DO $$
BEGIN
    RAISE NOTICE 'OK 90 (1B addendum): write-back — doc_write.go + registerA2ANoteTools wired onto the Arc C hinge and the harness default allowed-tools; harness_runs.model ledgers the passthrough; harness-pilot holds the narrow write-set grant (doc build/finalize + a2a_note) alongside its existing harness_run grant';
END $$;

-- =====================================================================
-- End of 90-harness-executor.sql
-- =====================================================================
-- ===== [was 91-core-compat.sql] =====
-- =====================================================================
-- 91-core-compat.sql — the compatibility guard for downstream overlays
-- =====================================================================
-- From the audit (.spec/proposals/audit-synthesis-2026-07.md §IV, "the one
-- real correctness landmine"): overlay apply-order was enforced by no runtime
-- tool, so a stale overlay could silently revert a core final (the r6/pe5/
-- cut3 saga). Fixing the apply-order (Track 2's first step) closes HALF the
-- landmine — the other half is that native `requires` on a Postgres extension
-- carries no VERSION RANGE, so nothing stops an overlay authored against core
-- 0.3.x from applying cleanly (no SQL error) against a 0.5 core whose function
-- signature or behavior it assumed has since moved. This is the guard: a
-- downstream overlay states the core range it was written for in a header
-- comment (`-- requires-core: >=X.Y[.Z] <A.B[.C]`), and the runner calls this
-- BEFORE applying that file.
--
-- Grammar: `>=X.Y[.Z] <A.B[.C]`, space-separated, EITHER bound optional (a
-- one-sided range is legal: `>=0.3` alone, or `<0.4` alone). Version segments
-- compare numerically (not lexically — "0.10" beats "0.9"); a version string
-- with fewer than 3 segments is right-padded with 0 ("0.3" == "0.3.0").
-- =====================================================================

-- ── _core_compat_ver — "0.3.0" -> ARRAY[0,3,0], missing segments = 0 ──────
-- Private helper (underscore prefix, per convention — see 15b's _context_*).
-- Postgres compares int[] of equal length element-by-element, so once every
-- version is normalized to 3 segments, plain <, >=, etc. on the arrays give
-- correct numeric (not lexical) ordering.
CREATE OR REPLACE FUNCTION stewards._core_compat_ver(p_version text)
RETURNS int[] LANGUAGE sql IMMUTABLE AS $fn$
    SELECT ARRAY[
        coalesce((string_to_array(btrim(p_version), '.'))[1]::int, 0),
        coalesce((string_to_array(btrim(p_version), '.'))[2]::int, 0),
        coalesce((string_to_array(btrim(p_version), '.'))[3]::int, 0)
    ];
$fn$;
COMMENT ON FUNCTION stewards._core_compat_ver(text) IS
'91: normalize a dotted version string to a 3-element int[] (missing segments = 0)
so range comparisons are numeric, not lexical. Private helper for assert_core_compat.';

-- ── assert_core_compat — the guard itself ─────────────────────────────────
-- p_range: the overlay's `-- requires-core: <range>` header value, VERBATIM
-- (including the >=/< tokens). Reads the installed core version straight from
-- pg_catalog (SELECT extversion FROM pg_extension WHERE extname=
-- 'pg_ai_stewards') — the one place a running database cannot be lied to
-- about which core it has. RAISEs on any out-of-range or unparseable range
-- (the runner is expected to run this under ON_ERROR_STOP=1 so the raise
-- aborts the file, and the run); returns true when the installed core
-- satisfies the range.
CREATE OR REPLACE FUNCTION stewards.assert_core_compat(p_range text)
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
    v_installed   text;
    v_installed_v int[];
    v_min_tok     text;
    v_max_tok     text;
    v_range       text := btrim(coalesce(p_range, ''));
BEGIN
    SELECT extversion INTO v_installed
      FROM pg_extension WHERE extname = 'pg_ai_stewards';
    IF v_installed IS NULL THEN
        RAISE EXCEPTION 'assert_core_compat: pg_ai_stewards is not an installed extension (nothing to check against)';
    END IF;
    v_installed_v := stewards._core_compat_ver(v_installed);

    IF v_range = '' THEN
        RETURN true;  -- no constraint stated = unconstrained (headerless files never call this)
    END IF;

    v_min_tok := (regexp_match(v_range, '>=\s*([0-9]+(?:\.[0-9]+){0,2})'))[1];
    v_max_tok := (regexp_match(v_range, '<\s*([0-9]+(?:\.[0-9]+){0,2})'))[1];

    IF v_min_tok IS NULL AND v_max_tok IS NULL THEN
        RAISE EXCEPTION 'assert_core_compat: unparseable requires-core range % (expected ">=X.Y[.Z] <A.B[.C]", either bound optional)',
            quote_literal(p_range);
    END IF;

    IF v_min_tok IS NOT NULL AND v_installed_v < stewards._core_compat_ver(v_min_tok) THEN
        RAISE EXCEPTION 'assert_core_compat: installed core % is below the required minimum % (requires-core: %)',
            v_installed, v_min_tok, p_range;
    END IF;

    IF v_max_tok IS NOT NULL AND v_installed_v >= stewards._core_compat_ver(v_max_tok) THEN
        RAISE EXCEPTION 'assert_core_compat: installed core % is at/above the required ceiling % (requires-core: %)',
            v_installed, v_max_tok, p_range;
    END IF;

    RETURN true;
END;
$fn$;
COMMENT ON FUNCTION stewards.assert_core_compat(text) IS
'91: raise if the INSTALLED core version (pg_extension.extversion) falls outside
p_range (">=X.Y[.Z] <A.B[.C]", either bound optional); else return true. The
runtime half of the compat contract — a downstream overlay states its
"-- requires-core: <range>" header, and the migration runner calls this before
applying that file so a core bump that breaks an old overlay is a loud abort,
not a silent clobber.';
