-- =====================================================================
-- packs/companion/steward-tools.sql — converse with work, by voice
-- =====================================================================
-- Born from the first real voice session (2026-07-08, Stuffy): a code-pr
-- item sat parked on dead-looking models, and the seat could DIAGNOSE it
-- but not act — no start_task on the surface, no unstick verb, no way to
-- ask "are the models even healthy?". Ratified by voice: "converse about
-- work items and get them unstuck and test out models to make sure the
-- substrate models are healthy." Apply AFTER companion.sql.
--
-- The trust shape, stated plainly:
--   forge_start        write_local  allowlisted — SAFE BY CONSTRUCTION: it
--                      only creates+dispatches a forge item, and the forge
--                      registrar is bell-gated; nothing registers without
--                      the human's approval. Rate-limited (5/hour).
--   work_item_unstick  write_local  allowlisted — narrow: only failed or
--                      awaiting_review items; optional model override is
--                      validated against the catalog/aliases. VERBAL GATE:
--                      read the item's error + intended model aloud, get
--                      an explicit yes.
--   models_health_check write_local allowlisted — bounded (≤25 tiny probes
--                      through the existing enqueue_model_probe machinery).
--   model_health       read         free — catalog + probe + alias + recent
--                      failure evidence in one spoken-friendly report.

-- ── forge_start: the wish, speakable ────────────────────────────────────
CREATE OR REPLACE FUNCTION companion.forge_start(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wish   text := btrim(coalesce(p_args->>'assignment',''));
    v_recent int;
    v_wi     uuid;
    v_wq     bigint;
BEGIN
    IF length(v_wish) < 10 THEN
        RETURN jsonb_build_object('error','assignment required — describe the capability you wish for, a sentence or three');
    END IF;
    IF length(v_wish) > 4000 THEN
        RETURN jsonb_build_object('error','assignment too long (4000 chars max)');
    END IF;
    SELECT count(*) INTO v_recent FROM stewards.work_items
     WHERE pipeline_family='forge' AND created_at > now() - interval '1 hour';
    IF v_recent >= 5 THEN
        RETURN jsonb_build_object('error','forge rate limit: 5 wishes per hour — the bell already has plans waiting');
    END IF;
    v_wi := stewards.work_item_create('forge',
              jsonb_build_object('assignment', v_wish),
              NULL, coalesce(p_args->>'_session_id','companion'), NULL,
              (SELECT id FROM stewards.intents WHERE slug='companion'));
    v_wq := stewards.work_item_dispatch_stage_safe(v_wi, NULL, false);
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_wi, 'dispatched', v_wq IS NOT NULL,
        'note', 'forge is planning. The plan STOPS on the approval bell — check companion_bell in a few minutes and read the plan aloud. Nothing is built until the human approves.');
END;
$fn$;
COMMENT ON FUNCTION companion.forge_start(jsonb) IS
'companion pack: start a forge wish from any seat. Safe by construction — the forge registrar is bell-gated, so this only ever produces a PLAN awaiting human approval. Rate-limited to 5/hour.';

-- ── work_item_unstick: the recovery verb ────────────────────────────────
CREATE OR REPLACE FUNCTION companion.work_item_unstick(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi     uuid;
    v_status text;
    v_model  text := nullif(btrim(coalesce(p_args->>'model','')),'');
    v_prov   text;
    v_name   text;
    v_ok     boolean;
    v_wq     bigint;
BEGIN
    BEGIN v_wi := (p_args->>'work_item_id')::uuid;
    EXCEPTION WHEN others THEN RETURN jsonb_build_object('error','work_item_id (uuid) required'); END;
    SELECT status INTO v_status FROM stewards.work_items WHERE id = v_wi;
    IF v_status IS NULL THEN RETURN jsonb_build_object('error','no such work item'); END IF;
    IF v_status NOT IN ('failed','awaiting_review') THEN
        RETURN jsonb_build_object('error','item is '||v_status||' — unstick only touches failed or awaiting_review items');
    END IF;

    IF v_model IS NOT NULL THEN
        IF position('/' IN v_model) > 0 THEN
            v_prov := split_part(v_model,'/',1); v_name := split_part(v_model,'/',2);
            SELECT usable INTO v_ok FROM stewards.model_catalog WHERE provider=v_prov AND model=v_name;
            IF v_ok IS DISTINCT FROM true THEN
                RETURN jsonb_build_object('error','model '||v_model||' is not a usable catalog model — model_health lists what is');
            END IF;
            UPDATE stewards.work_items SET provider_override=v_prov, model_override=v_name WHERE id=v_wi;
        ELSE
            IF NOT EXISTS (SELECT 1 FROM stewards.model_aliases WHERE alias=v_model AND enabled) THEN
                RETURN jsonb_build_object('error','no enabled alias named '||v_model||' — model_health lists aliases');
            END IF;
            UPDATE stewards.work_items SET model_override=v_model, provider_override=NULL WHERE id=v_wi;
        END IF;
    END IF;

    v_wq := stewards.work_item_dispatch_stage_safe(v_wi, NULL, true);
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_wi, 'was', v_status,
        'model_override', v_model, 'redispatched', v_wq IS NOT NULL,
        'note', 'VERBAL-GATE PROTOCOL: only call this after reading the item''s error (and the intended model, if overriding) aloud and hearing an explicit yes.');
END;
$fn$;
COMMENT ON FUNCTION companion.work_item_unstick(jsonb) IS
'companion pack: re-dispatch ONE failed/parked work item''s current stage, optionally pinning a model ("alias" or "provider/model", validated). Never touches running/pending/done items. Verbal gate is procedural: error read aloud + explicit yes first.';

-- ── model_health: the spoken-friendly health report (read) ──────────────
CREATE OR REPLACE FUNCTION companion.model_health(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    WITH recent_errors AS (
        SELECT c.provider, c.model, count(*) AS failures_7d
          FROM stewards.model_catalog c
          JOIN stewards.work_items w
            ON w.status IN ('failed','awaiting_review')
           AND w.updated_at > now() - interval '7 days'
           AND w.error LIKE '%' || c.model || '%'
         GROUP BY 1,2
    ),
    alias_use AS (
        SELECT provider, provider_model AS model,
               array_agg(alias ORDER BY alias) FILTER (WHERE enabled) AS enabled_aliases,
               array_agg(alias ORDER BY alias) FILTER (WHERE NOT enabled) AS disabled_aliases
          FROM stewards.model_aliases GROUP BY 1,2
    )
    SELECT jsonb_build_object('generated_at', now(), 'models',
        coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'model', c.provider || '/' || c.model,
            'usable', c.usable,
            'last_probed_at', c.last_probed_at,
            'probe', left(c.probe_detail, 160),
            'probed_via', c.probed_via,
            'enabled_aliases', a.enabled_aliases,
            'disabled_aliases', a.disabled_aliases,
            'recent_failures_7d', r.failures_7d
        )) ORDER BY c.usable DESC, c.provider, c.model), '[]'::jsonb))
      FROM stewards.model_catalog c
      LEFT JOIN recent_errors r ON r.provider=c.provider AND r.model=c.model
      LEFT JOIN alias_use a ON a.provider=c.provider AND a.model=c.model;
$fn$;
COMMENT ON FUNCTION companion.model_health(jsonb) IS
'companion pack: one health report per catalog model — usable flag, last probe result, alias membership, and how many work items failed mentioning it in the last 7 days. Read-only.';

-- ── models_health_check: probe the fleet (bounded) ──────────────────────
CREATE OR REPLACE FUNCTION companion.models_health_check(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_n int := 0;
    r   record;
BEGIN
    FOR r IN
        SELECT DISTINCT c.provider, c.model
          FROM stewards.model_catalog c
         WHERE c.usable
            OR EXISTS (SELECT 1 FROM stewards.model_aliases a
                        WHERE a.provider=c.provider AND a.provider_model=c.model AND a.enabled)
            OR (p_args->>'include_disabled')::boolean IS TRUE
         ORDER BY c.provider, c.model
         LIMIT 25
    LOOP
        PERFORM stewards.enqueue_model_probe(r.provider, r.model);
        v_n := v_n + 1;
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'probes_enqueued', v_n,
        'note', 'tiny probes run through the substrate''s own dispatch path; results land on model_health within a minute or two. Pass include_disabled=true to also re-test models an operator toggled off.');
END;
$fn$;
COMMENT ON FUNCTION companion.models_health_check(jsonb) IS
'companion pack: enqueue bounded (≤25) auto-probes for usable/alias-member models — include_disabled=true re-tests operator-toggled-off models too (probing is safe; only reports, never re-enables).';

-- ── register the tools ──────────────────────────────────────────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
( 'forge_start',
  'Start a forge wish: describe a missing capability in plain words; forge drafts exact SQL + its own test and STOPS on the approval bell (companion_bell shows it). Nothing is built without explicit human approval — so speaking the wish IS the consent to plan. Rate-limited 5/hour.',
  '{"type":"object","required":["assignment"],"properties":{"assignment":{"type":"string","description":"the capability you wish for, a sentence or three"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"forge_start"}'::jsonb, 'write_local', true ),
( 'work_item_unstick',
  'Re-dispatch ONE stuck (failed or awaiting_review) work item''s current stage, optionally pinning a model (an alias name like "reason", or "provider/model" from model_health). VERBAL GATE: first read the item''s error — and the intended model if overriding — aloud, and only call after an explicit yes.',
  '{"type":"object","required":["work_item_id"],"properties":{"work_item_id":{"type":"string"},"model":{"type":"string","description":"optional: alias or provider/model to pin for the retry"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"work_item_unstick"}'::jsonb, 'write_local', true ),
( 'model_health',
  'Health report for every configured model: usable flag, last probe result and when, which aliases route to it, and recent work-item failures mentioning it. Use before unsticking anything or when dispatches look flaky.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"model_health"}'::jsonb, 'read', true ),
( 'models_health_check',
  'Actively probe the model fleet (bounded, ≤25 tiny pings through the substrate''s own dispatch path). Results appear in model_health within a minute or two. include_disabled=true also re-tests models an operator toggled off — it reports, never re-enables.',
  '{"type":"object","properties":{"include_disabled":{"type":"boolean"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"models_health_check"}'::jsonb, 'write_local', true )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, effect_class = EXCLUDED.effect_class, active = true;

-- ── widen the Arc-C dynamic-write allowlist, deliberately ────────────────
-- forge_start is safe because the forge is bell-gated; work_item_unstick
-- only touches failed/parked items behind the verbal gate;
-- models_health_check is bounded and read-shaped in effect. forge_register
-- stays absent — the bell remains the wall.
SELECT stewards.config_set('arc_c_dynamic_write_allowlist',
        '["reminder_set","reminder_cancel","companion_approve","forge_start","work_item_unstick","models_health_check"]'::jsonb,
        'companion pack: write-class sql_fn tools dispatchable via substrate_tool from harness seats (Arc-C). Widened 2026-07-08 (voice-ratified): forge_start (bell-gated by construction), work_item_unstick (failed/parked only, verbal gate), models_health_check (bounded probes). forge_register stays absent.');
