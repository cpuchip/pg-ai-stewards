-- =====================================================================
-- 84-tool-effect-gate.sql — the tool-effect gate (Hinge ladder, Phase 1)
-- =====================================================================
-- The trigger the escalation ladder was missing. Until now, once a tool
-- is granted in agent_tool_perms, invocation is UNCONDITIONAL: there is
-- no tier between "no tool" and "fires the instant the model calls it."
-- A misfiring agent with a granted send/deploy tool reproduces the
-- Lemonade "sent without approval" failure exactly.
--
-- This adds a structural wall in the ONE tool-dispatch choke point
-- (tools.rs::tool_dispatch, which every model-driven tool call flows
-- through): before executing a tool whose effect_class is dangerous
-- (external_send | irreversible | financial), the dispatcher does NOT
-- execute. It serializes the drafted call into the 39-hinge review queue
-- (kind='tool-confirm'), best-effort pauses the owning work item
-- (a2a INPUT_REQUIRED where the shape fits), and returns a WITHHELD tool
-- result so the loop adapts instead of wedging. On Michael's approval,
-- tool_confirm_apply executes the STORED call verbatim.
--
-- Phase 1 scope (ratified spec .spec/proposals/hinge-and-escalation-ladder.md):
--   * effect_class on tool_defs + tool_requires_confirmation() helper.
--   * the interceptor (tool_confirm_gate) + the executor (tool_confirm_apply).
--   * the escalation_ladder TABLE (Piece 3's data; no ask_up tool yet).
--   * tool-confirm added to hinge_escalate_always_kinds — NOTHING may
--     auto-approve a gated call until Michael grants otherwise in council.
--   NO ask_up, NO autopilot, NO notify service. This is a PURE SAFETY
--   ADD: it can only ADD a pause, never remove one; everything escalates
--   to Michael (no new authority granted). It therefore needs no new
--   grant — it is the floor everything else stands on.
--
-- requires create_code_graph (83) — installs at the tail of the chain.
-- =====================================================================

-- =====================================================================
-- §1 — effect_class on tool definitions + the confirmation predicate.
-- =====================================================================
-- The classification of what a tool DOES to the world. Only the three
-- dangerous classes gate; read / write_local pass through. 'unclassified'
-- is the default for a tool nobody has tagged (dynamically-promoted MCP
-- bridge tools land here) — NOT gated in v1 unless the operator flips
-- gate_unclassified. Deny-to-safe on a tool the operator KNOWS is
-- dangerous is the explicit tag; blanket-gating every unknown tool would
-- wedge the substrate's own internal tools, so v1 gates the explicit
-- dangerous classes and leaves the strict switch to the operator.
ALTER TABLE stewards.tool_defs
    ADD COLUMN IF NOT EXISTS effect_class text NOT NULL DEFAULT 'unclassified';

-- The CHECK is added separately + idempotently (ADD COLUMN IF NOT EXISTS
-- cannot carry a named constraint on re-apply). NOT VALID would let a
-- pre-existing bad row slide; there are none (fresh column), so a plain
-- validated constraint is correct and asserts the invariant on re-apply.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'tool_defs_effect_class_chk'
           AND conrelid = 'stewards.tool_defs'::regclass
    ) THEN
        ALTER TABLE stewards.tool_defs
            ADD CONSTRAINT tool_defs_effect_class_chk
            CHECK (effect_class IN
                ('read','write_local','external_send','irreversible','financial','unclassified'));
    END IF;
END $$;

COMMENT ON COLUMN stewards.tool_defs.effect_class IS
'84: what the tool does to the world — read | write_local | external_send | irreversible | financial | unclassified. The tool-effect gate confirms external_send/irreversible/financial (and unclassified iff config gate_unclassified=true). Set by 84''s conservative seed for the shipped tools; operators tag their own dangerous tools (dynamically-promoted MCP tools default unclassified).';

-- The strict switch: when true, a tool nobody has classified is ALSO
-- gated (deny-to-safe on unknown). Default false so the substrate's own
-- internal tools are not all wedged the day the gate ships; an operator
-- who wants belt-and-suspenders flips this to 'true'.
INSERT INTO stewards.config (key, value, description) VALUES
  ('gate_unclassified', 'false'::jsonb,
   'When true, the tool-effect gate ALSO confirms tools with effect_class=unclassified (deny-to-safe on unknown). Default false: v1 gates only the explicitly-dangerous classes so internal tools are not wedged; flip to gate everything untagged.')
ON CONFLICT (key) DO NOTHING;

-- tool_requires_confirmation(tool) — the single predicate the dispatcher
-- consults. TRUE iff the tool's class is one of the dangerous three, or
-- (when gate_unclassified) it is unclassified. Unknown/inactive tool ⇒
-- false (it errors on dispatch anyway; the gate is not the place to
-- surface a missing tool).
CREATE OR REPLACE FUNCTION stewards.tool_requires_confirmation(p_tool text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_ec text;
BEGIN
    SELECT effect_class INTO v_ec
      FROM stewards.tool_defs WHERE name = p_tool AND active;
    IF v_ec IS NULL THEN
        RETURN false;                       -- unknown/inactive: not gated
    END IF;
    IF v_ec IN ('external_send','irreversible','financial') THEN
        RETURN true;
    END IF;
    IF v_ec = 'unclassified' THEN
        RETURN stewards.config_get_text('gate_unclassified','false') = 'true';
    END IF;
    RETURN false;                           -- read / write_local pass through
END;
$fn$;

COMMENT ON FUNCTION stewards.tool_requires_confirmation(text) IS
'84: the tool-effect gate predicate. TRUE iff the tool''s effect_class is external_send/irreversible/financial, or (config gate_unclassified) unclassified. Unknown/inactive ⇒ false. tool_dispatch (tools.rs) calls this before executing each tool; TRUE ⇒ withhold + enqueue tool-confirm.';

-- =====================================================================
-- §2 — conservative seed of the SHIPPED tools.
-- =====================================================================
-- Two-stage, order-sensitive, idempotent (each stage only touches rows
-- still 'unclassified', so re-apply and operator overrides both stick):
--
--   Stage A (SAFETY-relevant): the explicit, short allow-list of tools
--   that CLEARLY act on the world outside the substrate. This is the only
--   stage whose accuracy matters for v1 gating, so it is an EXPLICIT name
--   list, never a pattern. Dynamically-promoted MCP tools (git_push,
--   gh_pr_create) may not exist at migration time — the UPDATE is a no-op
--   when the row is absent and classifies it if/when the bridge promotes
--   it (promote_mcp_tool_cache_to_tool_defs's ON CONFLICT does not touch
--   effect_class, so the tag survives re-promotion).
--
--   Stage B (informational): the read / write_local split for the
--   remaining shipped tools. Neither class gates, so a read↔write_local
--   miscategorization has ZERO effect in v1 — it only informs an operator
--   and matters only if they flip gate_unclassified. Generous patterns are
--   therefore safe here; Stage A already protected the dangerous names.
--
-- Names verified against the live tool_defs surface 2026-07-03 (git/gh/
-- coder push/PR/deploy are the outward acts; web_search/fetch_* are
-- external READS, not sends).

-- Stage A — the outward/irreversible acts (these GATE).
UPDATE stewards.tool_defs SET effect_class = 'external_send'
 WHERE effect_class = 'unclassified'
   AND name IN ('git_push','gh_pr_create','gh_issue_create','coder_push','coder_open_pr');

UPDATE stewards.tool_defs SET effect_class = 'irreversible'
 WHERE effect_class = 'unclassified'
   AND name IN ('coder_deploy');

-- Stage B1 — reads (search / get / list / show / fetch / define / …).
UPDATE stewards.tool_defs SET effect_class = 'read'
 WHERE effect_class = 'unclassified'
   AND (
        name ~ '(^|_)(search|get|list|show|read|recall|define|inbox|status|citations|similar|survey|neighbors|vocabulary|passes|frames|slides|context_for|current)($|_)'
     OR name LIKE 'fetch_%'
     OR name IN ('web_search','web_search_exa','news_search','instant_answer',
                 'deep_research','extract_links','summarize_url','summarize_doc',
                 'summarize_my_context','research_codebase','investigate_doc',
                 'investigate_session','expand_message','read_corpus_parents',
                 'reveal_tool','skill','quote_rules','audit_docs','audit_files',
                 'orient_survey','result_read','result_search','transcript_search',
                 'graph_recall','graph_vocabulary','graph_link_candidates',
                 'list_models','list_connectors','list_repos')
   );

-- Stage B2 — the remaining shipped tools are substrate-LOCAL mutators
-- (doc/graph/context/todo/coder-sandbox/a2a/persona writes). Tag every
-- still-unclassified sql_fn (all internal) write_local; leave unmatched
-- mcp_proxy tools 'unclassified' for the operator (bridge tools vary by
-- install and could be anything — the honest default is "operator, tag me").
UPDATE stewards.tool_defs SET effect_class = 'write_local'
 WHERE effect_class = 'unclassified'
   AND (execute_target->>'kind') = 'sql_fn';

-- =====================================================================
-- §3 — the escalation ladder TABLE (Piece 3's data; no ask_up yet).
-- =====================================================================
-- The model order the ladder escalates UP is DATA, not hardcode: not
-- everyone runs Opus as their Hinge, and a Fable hinge is now possible.
-- The TOP enabled rung is the default hinge model; ask_up and autopilot
-- (future phases) both resolve from this one table, so "which model is my
-- hinge" is one UPDATE. rung 1 = weakest … N = strongest.
CREATE TABLE IF NOT EXISTS stewards.escalation_ladder (
    rung        int  PRIMARY KEY,            -- 1 = weakest … N = strongest
    model_alias text NOT NULL,               -- resolves via 19/31 model aliases (BYO models)
    role_hint   text,                        -- e.g. 'local-doer', 'consult', 'hinge'
    enabled     boolean NOT NULL DEFAULT true
);

COMMENT ON TABLE stewards.escalation_ladder IS
'84: the authority ladder an ask escalates UP, as DATA (Piece 3). rung 1=weakest … N=strongest; model_alias resolves via the 19/31 alias system (BYO models). The TOP enabled rung is the default hinge model; ask_up + autopilot (future phases) resolve from here, so retargeting the hinge is one UPDATE. EMPTY in core — the operator overlay seeds rungs from the models it wired (mirrors model_aliases, which is likewise empty in core). Distinct from 06-cost model_escalation (that is the per-call cost failover; this is the authority ladder).';

COMMENT ON COLUMN stewards.escalation_ladder.role_hint IS
'84: what this rung is FOR — local-doer (rung 0/1 default worker), consult (an ask_up target), hinge (the top rung that reviews). Advisory; the mechanism keys off rung order + enabled, not the hint.';

-- Empty seed in core, deliberately: model_aliases is likewise "empty in
-- core; the operator overlay seeds the rows" (31 §4). With no wired
-- aliases there is no strength order to infer, and inventing rung order
-- from model_aliases.priority (a per-alias try-order, NOT a cross-alias
-- strength) would VIOLATE this table's "rung N = strongest" contract. The
-- operator seeds the ladder alongside their aliases, e.g.:
--   INSERT INTO stewards.escalation_ladder (rung, model_alias, role_hint) VALUES
--     (1, 'local-doer', 'local-doer'),
--     (2, 'reason',     'consult'),
--     (3, 'hinge',      'hinge');

-- =====================================================================
-- §4 — tool-confirm is escalate-always until Michael grants otherwise.
-- =====================================================================
-- Append (idempotently) to 39's hinge_escalate_always_kinds so a verdict
-- of 'approve' on a tool-confirm from the claude -p reviewer ESCALATES to
-- Michael rather than sticking — NOTHING can auto-approve a gated tool
-- call until Michael grants it per-kind in council. Michael's own approval
-- is still final (hinge_record_verdict: v_michael bypasses the wall).
UPDATE stewards.config
   SET value = value || '["tool-confirm"]'::jsonb
 WHERE key = 'hinge_escalate_always_kinds'
   AND NOT (value ? 'tool-confirm');

-- =====================================================================
-- §5 — the interceptor + the executor (the two SQL seams).
-- =====================================================================

-- session_work_item — best-effort map a dispatch session_id → the owning
-- work_item uuid. Pipeline-stage sessions look like 'wi--<8hex>--<stage>'
-- (31 §…, work_item_dispatch_stage). Returns NULL for chat/other sessions
-- (their gated call still enqueues to the Hinge queue — the reliable
-- surface; the work-item pause is opportunistic, "where the shape fits").
CREATE OR REPLACE FUNCTION stewards.session_work_item(p_session text)
RETURNS uuid LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_hex text; v_id uuid;
BEGIN
    IF p_session IS NULL THEN RETURN NULL; END IF;
    v_hex := substring(p_session from '^wi--([0-9a-fA-F]{8})--');
    IF v_hex IS NULL THEN RETURN NULL; END IF;
    SELECT id INTO v_id FROM stewards.work_items
     WHERE id::text LIKE lower(v_hex) || '%' LIMIT 1;
    RETURN v_id;
END;
$fn$;

COMMENT ON FUNCTION stewards.session_work_item(text) IS
'84: best-effort resolve a dispatch session_id to its work_item uuid via the wi--<8hex>--<stage> pipeline-session convention. NULL for chat/other sessions. Used by the tool-effect gate to opportunistically pause an owning a2a work item; the Hinge queue is the always-on surface regardless.';

-- tool_confirm_gate — THE interceptor. Called by tools.rs::tool_dispatch
-- INSTEAD OF executing a tool that requires confirmation. It (a) enqueues
-- the drafted call to the 39-hinge queue as kind='tool-confirm', (b) if
-- the session maps to an IN-PROGRESS a2a work item, marks it
-- INPUT_REQUIRED (reuse a2a_needs_input) so the assigned surface shows the
-- block, and (c) returns a WITHHELD tool result so the model can continue
-- other work or end the turn. It NEVER executes the tool — that is
-- tool_confirm_apply's job, and only after Michael approves.
CREATE OR REPLACE FUNCTION stewards.tool_confirm_gate(
    p_tool    text,
    p_args    jsonb   DEFAULT '{}'::jsonb,
    p_target  jsonb   DEFAULT '{}'::jsonb,
    p_agent   text    DEFAULT NULL,
    p_session text    DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_hinge_id bigint;
    v_wi       uuid;
    v_args     jsonb := coalesce(p_args, '{}'::jsonb);
BEGIN
    v_wi := stewards.session_work_item(p_session);

    v_hinge_id := stewards.hinge_enqueue(
        'tool-confirm',
        p_tool || ' — ' || left(v_args::text, 80),          -- subject
        jsonb_build_object(
            'tool',         p_tool,
            'args',         v_args,
            'target',       coalesce(p_target, '{}'::jsonb),
            'agent',        p_agent,
            'session',      p_session,
            'work_item_id', v_wi
        ),
        coalesce(p_agent, 'tool-effect-gate')               -- proposer
    );

    -- Opportunistically pause the owning a2a work item, where the shape
    -- fits (a claimed, in-progress a2a task). a2a_needs_input requires
    -- escalation_state='in_progress'; guard so we never touch a pipeline
    -- item in a different state model.
    IF v_wi IS NOT NULL
       AND EXISTS (SELECT 1 FROM stewards.work_items
                    WHERE id = v_wi AND escalation_state = 'in_progress') THEN
        PERFORM stewards.a2a_needs_input(
            v_wi,
            format('Approve tool call: %s? (hinge #%s)', p_tool, v_hinge_id));
    END IF;

    RETURN jsonb_build_object(
        'withheld',     true,
        'hinge_id',     v_hinge_id,
        'work_item_id', v_wi,
        'tool',         p_tool,
        'message',      format(
            'WITHHELD pending human confirmation (hinge #%s): %s. '
            || 'The call runs verbatim if approved; continue other work or end the turn.',
            v_hinge_id, p_tool)
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.tool_confirm_gate(text,jsonb,jsonb,text,text) IS
'84: the tool-effect interceptor. Enqueues the drafted call as a tool-confirm hinge review, opportunistically pauses the owning in-progress a2a work item (INPUT_REQUIRED), and returns a WITHHELD tool result. It NEVER executes — approval + execution is tool_confirm_apply. Called from tools.rs::tool_dispatch when tool_requires_confirmation is true.';

-- tool_confirm_apply — the EXECUTOR. After a verdict lands on a
-- tool-confirm review (approved by Michael, or declined), this resolves
-- the withheld call: on approved it executes the STORED draft verbatim
-- through the same path the tool normally uses, records the result, marks
-- the review 'applied', and resumes any paused work item; on declined it
-- notifies the paused work item and executes nothing. Because tool-confirm
-- is escalate-always, status can only be 'approved' when reviewer='michael'
-- (the claude -p reviewer's approve escalates instead) — so this executes
-- only on the human's authority.
CREATE OR REPLACE FUNCTION stewards.tool_confirm_apply(p_hinge_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_row    stewards.hinge_reviews%ROWTYPE;
    v_target jsonb;
    v_kind   text;
    v_args   jsonb;
    v_tool   text;
    v_session text;
    v_wi     uuid;
    v_result jsonb;
    v_child  bigint;
BEGIN
    SELECT * INTO v_row FROM stewards.hinge_reviews WHERE id = p_hinge_id;
    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'note', 'no such review');
    END IF;
    IF v_row.kind <> 'tool-confirm' THEN
        RETURN jsonb_build_object('ok', false, 'note', 'not a tool-confirm review');
    END IF;

    v_tool    := v_row.payload->>'tool';
    v_args    := coalesce(v_row.payload->'args', '{}'::jsonb);
    v_target  := coalesce(v_row.payload->'target', '{}'::jsonb);
    v_kind    := v_target->>'kind';
    v_session := v_row.payload->>'session';
    v_wi      := nullif(v_row.payload->>'work_item_id', '')::uuid;

    -- DECLINED / revise: notify the paused work item; execute nothing.
    IF v_row.status IN ('declined','revise') THEN
        IF v_wi IS NOT NULL
           AND EXISTS (SELECT 1 FROM stewards.work_items
                        WHERE id = v_wi AND a2a_question IS NOT NULL) THEN
            PERFORM stewards.a2a_answer(
                v_wi, format('%s: %s', v_row.status, coalesce(v_row.reason, 'no reason given')));
        END IF;
        RETURN jsonb_build_object('ok', true, 'hinge_id', p_hinge_id,
            'status', v_row.status, 'executed', false);
    END IF;

    IF v_row.status <> 'approved' THEN
        RETURN jsonb_build_object('ok', false, 'hinge_id', p_hinge_id,
            'note', format('review is %s — not approved/declined; nothing to apply', v_row.status));
    END IF;

    -- Already applied? Idempotent no-op (don't double-execute a send).
    IF (v_row.payload ? 'result') THEN
        RETURN jsonb_build_object('ok', true, 'hinge_id', p_hinge_id,
            'status', 'applied', 'executed', false, 'note', 'already applied',
            'result', v_row.payload->'result');
    END IF;

    -- APPROVED: execute the stored call verbatim, by kind.
    IF v_kind = 'sql_fn' THEN
        DECLARE
            v_schema text := v_target->>'schema';
            v_fn     text := v_target->>'name';
            v_xargs  jsonb := v_args;
        BEGIN
            IF v_schema !~ '^[a-zA-Z0-9_]+$' OR v_fn !~ '^[a-zA-Z0-9_]+$' THEN
                RETURN jsonb_build_object('ok', false, 'note',
                    format('unsafe identifier in stored target: %s.%s', v_schema, v_fn));
            END IF;
            -- Mirror tools.rs: inject the dispatch session so session-scoped
            -- sql_fn tools resolve their own session (most ignore the key).
            IF jsonb_typeof(v_xargs) = 'object'
               AND NOT (v_xargs ? '_session_id') AND v_session IS NOT NULL THEN
                v_xargs := v_xargs || jsonb_build_object('_session_id', v_session);
            END IF;
            EXECUTE format('SELECT %I.%I($1)', v_schema, v_fn)
               INTO v_result USING v_xargs;
        END;
    ELSIF v_kind = 'mcp_proxy' THEN
        SELECT stewards.mcp_proxy_enqueue(
                   v_target->>'server', v_target->>'tool', v_args, NULL)
          INTO v_child;
        v_result := jsonb_build_object(
            'dispatched',        v_child IS NOT NULL,
            'mcp_proxy_child_id', v_child,
            'note', CASE WHEN v_child IS NULL
                         THEN 'server disabled/unregistered — nothing dispatched'
                         ELSE 'dispatched to the bridge; the tool result resolves asynchronously' END);
    ELSE
        -- No http tool_defs ship today; SQL cannot make the outbound call.
        -- Degrade honestly rather than silently succeed.
        v_result := jsonb_build_object('error', format(
            'tool-effect apply does not support kind=%s from SQL (http re-execution needs the Rust dispatch path)',
            coalesce(v_kind, 'null')));
    END IF;

    UPDATE stewards.hinge_reviews
       SET status     = 'applied',
           applied_at = now(),
           payload    = payload || jsonb_build_object('result', v_result)
     WHERE id = p_hinge_id;

    -- Resume the paused work item with the outcome.
    IF v_wi IS NOT NULL
       AND EXISTS (SELECT 1 FROM stewards.work_items
                    WHERE id = v_wi AND a2a_question IS NOT NULL) THEN
        PERFORM stewards.a2a_answer(
            v_wi, format('Approved & executed %s: %s', v_tool, left(v_result::text, 400)));
    END IF;

    RETURN jsonb_build_object('ok', true, 'hinge_id', p_hinge_id,
        'status', 'applied', 'executed', true, 'tool', v_tool, 'result', v_result);
END;
$fn$;

COMMENT ON FUNCTION stewards.tool_confirm_apply(bigint) IS
'84: resolve a verdicted tool-confirm review. On approved, execute the STORED draft verbatim (sql_fn via EXECUTE with the dispatch session injected; mcp_proxy via mcp_proxy_enqueue), record payload.result, set status=applied, and a2a_answer the paused work item. On declined/revise, a2a_answer the work item and execute nothing. Idempotent (a second call after apply is a no-op). Only reaches execution when status=approved — which, tool-confirm being escalate-always, requires reviewer=michael.';

-- tool_confirm_verdict — the one-call approve/decline the UI uses: record
-- the verdict (as Michael) then resolve it. Keeps the Go handler thin.
CREATE OR REPLACE FUNCTION stewards.tool_confirm_verdict(
    p_hinge_id bigint,
    p_decision text,                         -- 'approve' | 'decline'
    p_reason   text DEFAULT NULL,
    p_reviewer text DEFAULT 'michael'
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_verdict jsonb; v_apply jsonb;
BEGIN
    v_verdict := stewards.hinge_record_verdict(p_hinge_id, p_decision, p_reason, p_reviewer);
    v_apply   := stewards.tool_confirm_apply(p_hinge_id);
    RETURN jsonb_build_object('verdict', v_verdict, 'apply', v_apply);
END;
$fn$;

COMMENT ON FUNCTION stewards.tool_confirm_verdict(bigint,text,text,text) IS
'84: approve/decline a tool-confirm in one call — hinge_record_verdict (reviewer defaults to michael, whose approval is final) then tool_confirm_apply. The Stewdio "Needs you" tray calls this.';

-- tool_confirm_pending — the "Needs you" worklist: tool-confirm reviews
-- awaiting Michael (pending, or escalated by the claude -p reviewer),
-- newest context first, with the drafted call pretty-fielded for the card.
CREATE OR REPLACE FUNCTION stewards.tool_confirm_pending(p_limit int DEFAULT 50)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(r ORDER BY r.created_at), '[]'::jsonb)
      FROM (
        SELECT id,
               subject,
               payload->>'tool'                AS tool,
               payload->'args'                 AS args,
               payload->>'agent'               AS agent,
               payload->'target'->>'kind'      AS target_kind,
               nullif(payload->>'work_item_id','') AS work_item_id,
               status,
               created_at
          FROM stewards.hinge_reviews
         WHERE kind = 'tool-confirm'
           AND status IN ('pending','escalated')
         ORDER BY created_at
         LIMIT p_limit
      ) r;
$fn$;

COMMENT ON FUNCTION stewards.tool_confirm_pending(int) IS
'84: the tool-effect gate worklist for the Stewdio "Needs you" tray — tool-confirm reviews still awaiting Michael (pending or escalated), with the drafted call fielded (tool/args/agent/target_kind/work_item). Approve/decline via tool_confirm_verdict.';

-- =====================================================================
-- End of 84-tool-effect-gate.sql
-- =====================================================================
