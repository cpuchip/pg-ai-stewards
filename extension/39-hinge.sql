-- =====================================================================
-- 39-hinge.sql — the Hinge review queue (Phase H of the self-tending memory).
-- =====================================================================
-- Gated decisions (an RTE skill-rule, a graph reorg, a cutover) need a Hinge. Michael
-- is the ultimate Hinge, but a curated `claude -p` reviewer (scripts/hinge-review) tiers
-- UNDER him: it reviews each item against the covenant + the gate's criteria and returns
-- a verdict; the SUBSTRATE applies what's approved (judges, not executors). This is the
-- queue + the bounds. D&C 121: the reviewer holds DELEGATED dominion within bounds Michael
-- grants in council; outside them, it ESCALATES to the human — enforced HERE, not in the
-- prompt, so a generous reviewer can never exceed its grant.
-- requires create_edge_vocabulary (38).
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.hinge_reviews (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind          text NOT NULL,                 -- e.g. 'digest-skill-rule', 'graph-reorg', 'cutover'
    subject       text NOT NULL,                 -- one-line what-is-this
    payload       jsonb NOT NULL DEFAULT '{}'::jsonb,  -- the full proposal the reviewer reads
    status        text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','revise','escalated','applied','declined')),
    verdict       text,                          -- the reviewer's raw verdict (approve|revise|escalate)
    reason        text,                          -- the reviewer's reasoning
    reviewed_by   text,                          -- 'claude-hinge' | 'michael'
    proposer      text,                          -- who enqueued it (the RTE, a tending loop, …)
    created_at    timestamptz NOT NULL DEFAULT now(),
    reviewed_at   timestamptz,
    applied_at    timestamptz
);
COMMENT ON TABLE stewards.hinge_reviews IS
'39: the Hinge review queue. Proposers enqueue (hinge_enqueue); the claude -p reviewer (or Michael) records a verdict (hinge_record_verdict), which ENFORCES the bounds (config hinge_auto_approve_kinds / hinge_escalate_always_kinds) so a verdict can never exceed the reviewer''s delegated grant. The substrate applies status=approved items; status=escalated waits for Michael.';

CREATE INDEX IF NOT EXISTS hinge_reviews_status_idx ON stewards.hinge_reviews (status, created_at);

-- Bounds defaults: NOTHING auto-approves until Michael grants a kind in council; the
-- structural kinds ALWAYS escalate to the human regardless of the reviewer's verdict.
INSERT INTO stewards.config (key, value, description) VALUES
  ('hinge_auto_approve_kinds', '[]'::jsonb,
   'review kinds the claude -p Hinge may auto-approve within bounds; default none until granted in council'),
  ('hinge_escalate_always_kinds', '["cutover","new-pipeline","new-capability","spend-increase","schedule-change"]'::jsonb,
   'review kinds that ALWAYS escalate to Michael regardless of the reviewer verdict (D&C 121 — standing-behavior changes are the human''s)')
ON CONFLICT (key) DO NOTHING;

-- ── hinge_enqueue — a proposer asks for review.
CREATE OR REPLACE FUNCTION stewards.hinge_enqueue(
    p_kind text, p_subject text, p_payload jsonb DEFAULT '{}'::jsonb, p_proposer text DEFAULT NULL
) RETURNS bigint LANGUAGE sql AS $fn$
    INSERT INTO stewards.hinge_reviews (kind, subject, payload, proposer)
    VALUES (p_kind, p_subject, COALESCE(p_payload,'{}'::jsonb), p_proposer)
    RETURNING id;
$fn$;

-- ── hinge_pending — the reviewer's worklist (oldest first).
CREATE OR REPLACE FUNCTION stewards.hinge_pending(p_limit int DEFAULT 20)
RETURNS TABLE (id bigint, kind text, subject text, payload jsonb, created_at timestamptz)
LANGUAGE sql STABLE AS $fn$
    SELECT id, kind, subject, payload, created_at
      FROM stewards.hinge_reviews WHERE status = 'pending'
     ORDER BY created_at ASC LIMIT p_limit;
$fn$;

-- ── hinge_record_verdict — the reviewer (or Michael) records a verdict; BOUNDS ENFORCED.
--    A verdict of 'approve' only sticks as approved if the kind is in
--    hinge_auto_approve_kinds AND not in hinge_escalate_always_kinds; otherwise it is
--    escalated to the human. This is the wall around the reviewer's delegated dominion.
CREATE OR REPLACE FUNCTION stewards.hinge_record_verdict(
    p_id bigint, p_verdict text, p_reason text DEFAULT NULL, p_reviewer text DEFAULT 'claude-hinge'
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_row     stewards.hinge_reviews%ROWTYPE;
    v_v       text := lower(btrim(coalesce(p_verdict,'')));
    v_status  text;
    v_auto    boolean;
    v_force   boolean;
    v_michael boolean := (p_reviewer = 'michael');
BEGIN
    SELECT * INTO v_row FROM stewards.hinge_reviews WHERE id = p_id;
    IF v_row.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'note', 'no such review'); END IF;
    -- Claude reviews PENDING items; Michael can also act on an ESCALATED item (the
    -- claude reviewer escalated it to him, with its recommendation recorded).
    IF v_row.status <> 'pending' AND NOT (v_michael AND v_row.status = 'escalated') THEN
        RETURN jsonb_build_object('ok', false, 'note', 'already ' || v_row.status);
    END IF;

    v_force := (v_row.kind = ANY (SELECT jsonb_array_elements_text(stewards.config_get('hinge_escalate_always_kinds'))));
    v_auto  := (v_row.kind = ANY (SELECT jsonb_array_elements_text(stewards.config_get('hinge_auto_approve_kinds'))));

    IF v_v IN ('approve','approved') THEN
        -- Michael's approval is final; the claude reviewer's approval must be in-bounds.
        IF v_michael OR (v_auto AND NOT v_force) THEN
            v_status := 'approved';
        ELSE
            v_status := 'escalated';      -- approved out of bounds → the human decides
        END IF;
    ELSIF v_v IN ('revise','revision') THEN
        v_status := 'revise';
    ELSIF v_v IN ('decline','declined','reject') THEN
        v_status := 'declined';
    ELSE
        v_status := 'escalated';
    END IF;

    UPDATE stewards.hinge_reviews
       SET status = v_status, verdict = v_v, reason = p_reason,
           reviewed_by = p_reviewer, reviewed_at = now()
     WHERE id = p_id;

    RETURN jsonb_build_object('ok', true, 'id', p_id, 'verdict', v_v, 'status', v_status,
        'in_bounds', (v_auto AND NOT v_force), 'escalate_always', v_force,
        'note', CASE WHEN v_status='escalated' AND NOT v_michael
                     THEN 'escalated to Michael — outside the reviewer''s grant' ELSE v_status END);
END;
$fn$;

-- ── hinge_status — a glance at the queue.
CREATE OR REPLACE FUNCTION stewards.hinge_status()
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
      FROM (SELECT status, count(*) n FROM stewards.hinge_reviews GROUP BY status) x;
$fn$;

-- =====================================================================
-- End of 39-hinge.sql
-- =====================================================================
