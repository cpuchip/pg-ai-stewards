-- =====================================================================
-- 70-hinge-decouple.sql — let the Hinge reviewer work on the Max plan
-- during a manual GPU pause, while an EMERGENCY pause still halts it.
-- =====================================================================
-- The Hinge reviewer (39 + scripts/hinge-review) runs on `claude -p` — cloud
-- Max, INDEPENDENT of the local 4090 rig. But `hinge_gate_status` gated it on
-- the global `autonomy_paused`, which during innovation week means "free the
-- GPUs" — so the rig-independent reviewer was idled for a reason that doesn't
-- apply to it (the 50%-of-the-Max-plan-on-the-table that Michael wants used).
--
-- This amendment (council 2026-06-26, `.spec/proposals/hinge-reviewer-amendment.md`)
-- decouples the two, WITHOUT weakening the emergency stop:
--   • hinge_runs_during_global_pause (default false) — opt-in: keep reviewing
--     during a MANUAL autonomy pause.
--   • hinge_daemon_paused (default false) — the reviewer's OWN kill switch.
--   • a WATCHMAN emergency (reflect_pause_source LIKE 'guard:%') ALWAYS halts
--     the reviewer regardless of the opt-in — emergency stays supreme.
-- Two-tier authority (hinge_record_verdict bounds) is unchanged.
-- requires create_a2a_engine (69).
-- =====================================================================

INSERT INTO stewards.config (key, value, description) VALUES
  ('hinge_runs_during_global_pause', 'false'::jsonb,
    'When true, the Hinge reviewer keeps running during a MANUAL autonomy pause (e.g. innovation-week "free the GPUs"). It runs on claude -p (cloud Max), independent of the local rig, so a GPU pause need not idle it. A watchman EMERGENCY pause (reflect_pause_source guard:*) ALWAYS halts it regardless of this flag.'),
  ('hinge_daemon_paused', 'false'::jsonb,
    'The Hinge reviewer''s own kill switch, independent of the global autonomy_paused. Set true to stop the reviewer without pausing the rest of the autonomous stack.')
ON CONFLICT (key) DO NOTHING;

-- Re-author hinge_gate_status (39) with the decoupled gate. No later file
-- re-authors this function, so this is its final form.
CREATE OR REPLACE FUNCTION stewards.hinge_gate_status()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_paused      bool := stewards.config_get_text('autonomy_paused','false') = 'true';
    v_source      text := stewards.config_get_text('reflect_pause_source','manual');
    v_run_global  bool := stewards.config_get_text('hinge_runs_during_global_pause','false') = 'true';
    v_self_pause  bool := stewards.config_get_text('hinge_daemon_paused','false') = 'true';
    -- A watchman trip sets reflect_pause_source = 'guard:<breach>'. That is a real
    -- emergency and ALWAYS halts the reviewer, opt-in or not.
    v_emergency   bool := v_paused AND v_source LIKE 'guard:%';
    v_pending     int  := (SELECT count(*) FROM stewards.hinge_reviews WHERE status = 'pending');
    v_interval    int  := coalesce(nullif(stewards.config_get_text('hinge_daemon_interval_seconds',''),'')::int, 300);
    v_should      bool;
BEGIN
    v_should := v_pending > 0
                AND NOT v_self_pause
                AND NOT v_emergency
                AND (NOT v_paused OR v_run_global);

    RETURN jsonb_build_object(
        'should_run',                v_should,
        'pending',                   v_pending,
        'paused',                    v_paused,
        'pause_source',              v_source,
        'emergency',                 v_emergency,
        'runs_during_global_pause',  v_run_global,
        'self_paused',               v_self_pause,
        'paused_reason',
            CASE WHEN v_emergency THEN 'watchman EMERGENCY (guard) — Hinge daemon halts (supreme)'
                 WHEN v_self_pause THEN 'hinge_daemon_paused — the reviewer''s own switch'
                 WHEN v_paused AND NOT v_run_global THEN 'autonomy_paused (manual) — set hinge_runs_during_global_pause=true to keep reviewing on the Max plan'
                 ELSE NULL END,
        'interval_seconds',          v_interval);
END;
$fn$;

COMMENT ON FUNCTION stewards.hinge_gate_status() IS
'39/70: the substrate-driven contract for the host Hinge daemon. should_run = pending>0 AND NOT the reviewer''s own pause AND NOT a watchman emergency AND (not globally paused OR opted-in via hinge_runs_during_global_pause). The reviewer is cloud Max (rig-independent), so a manual GPU pause need not idle it; a watchman emergency (guard:*) always halts it. interval from hinge_daemon_interval_seconds (300).';
