-- ===== [was 84-tool-effect-gate.sql] =====
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
-- ===== [was 85-world-chat.sql] =====
-- =====================================================================
-- 85-world-chat.sql — cross-world lore neighbors + "Chat with this world".
-- =====================================================================
-- 57 gave the loremaster lore_neighbors_tool, but it walks world_edges
-- WITHIN one world (g.world_id = v_world) — it CANNOT cross the seam that
-- 82's cross_world_edges carries (market-taxonomy ↔ CKE service entities,
-- producer ↔ consumer HTTP/gRPC links). So "what services does this market
-- pain touch?" was unanswerable from the graph: the answer lives on the
-- cross-world edge lore_neighbors never looks at.
--
-- This adds world_neighbors_tool — the cross-world SUPERSET of
-- lore_neighbors. It mirrors 57's recursive-CTE idiom (BFS, depth cap, alias
-- match, path cycle-guard) but its edge frontier is world_edges (intra, pinned
-- to the origin world) UNION cross_world_edges (the boundary hops), so a named
-- entity surfaces both its in-world relations AND the entities it links to in
-- OTHER worlds — carrying the other entity's world slug so the caller sees it
-- crossed. lore_neighbors_tool is LEFT UNTOUCHED (the intra-world tool still
-- works exactly as before); this is a new, additive tool.
--
-- It also grants the read-only lore tools to the cockpit chat agent
-- (work-item-chat) so the "Chat with this world" button's session — whose
-- FOLLOW-UP turns the UI dispatches as work-item-chat, not loremaster (the
-- chatSendHandler hardcodes the family) — can still call world_neighbors and
-- friends. All read-only, grounded, cite-first; the loremaster stays read-only.
--
-- Idempotent (CREATE OR REPLACE / ON CONFLICT); virgin-safe. Requires 82
-- (cross_world_edges) + 57 (loremaster + the lore tools it re-authors) + 84
-- (chain tail / effect_class column). See tests/virgin-smoke.sql OK 85.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — world_neighbors_tool: BFS over intra-world edges AND cross-world edges
-- ---------------------------------------------------------------------
-- Args: {world_slug, name, depth (default 1, cap 2), cross (default true)}.
-- Bounding the cross-world walk (avoid the explosion): the edge frontier is
--   (a) world_edges of the ORIGIN world only  (g.world_id = v_world), and
--   (b) cross_world_edges globally            (only when cross = true).
-- Because the intra leg is PINNED to the origin world, once a cross hop lands
-- in another world the walk can only leave that world via ANOTHER cross edge —
-- it never fans out into a foreign world's entire internal call graph (a
-- lodestar-imported service can be thousands of nodes). Depth is capped at 2
-- and the path array is a cycle guard, so the frontier stays small and
-- grounded: every returned row corresponds to a real edge actually traversed.
CREATE OR REPLACE FUNCTION stewards.world_neighbors_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_slug  text    := p_args->>'world_slug';
        v_name  text    := p_args->>'name';
        v_depth int     := least(coalesce((p_args->>'depth')::int, 1), 2);
        v_cross boolean  := coalesce((p_args->>'cross')::boolean, true);
        v_world bigint; v_eid bigint; v_out jsonb;
BEGIN
    IF v_slug IS NULL OR v_name IS NULL THEN
        RETURN jsonb_build_object('error','world_slug and name required');
    END IF;
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = v_slug;
    IF v_world IS NULL THEN RETURN jsonb_build_object('ok',true,'found',false); END IF;
    -- alias match, exactly as lore_neighbors_tool resolves the anchor entity.
    SELECT entity_id INTO v_eid FROM stewards.world_entities
     WHERE world_id = v_world AND (name = v_name OR v_name = ANY(aliases)) LIMIT 1;
    IF v_eid IS NULL THEN RETURN jsonb_build_object('ok',true,'found',false); END IF;

    WITH RECURSIVE
    -- the undirected edge frontier: origin-world edges + (opt) cross-world edges.
    -- `crossed` marks which rows came from a cross_world_edge (the cross-service link).
    edges(a, b, rel, crossed) AS (
        SELECT g.src_entity, g.dst_entity, g.rel_type, false
          FROM stewards.world_edges g
         WHERE g.world_id = v_world
        UNION ALL
        SELECT c.src_entity, c.dst_entity, c.rel_type, true
          FROM stewards.cross_world_edges c
         WHERE v_cross
    ),
    -- BFS from the anchor; carry the LAST edge (rel + direction + crossed) used
    -- to reach each node so the caller sees HOW it connects, not just THAT it does.
    walk(eid, depth, path, rel, dir, crossed) AS (
        SELECT v_eid, 0, ARRAY[v_eid], NULL::text, NULL::text, false
        UNION ALL
        SELECT CASE WHEN e.a = w.eid THEN e.b ELSE e.a END,
               w.depth + 1,
               w.path || CASE WHEN e.a = w.eid THEN e.b ELSE e.a END,
               e.rel,
               CASE WHEN e.a = w.eid THEN 'out' ELSE 'in' END,
               e.crossed
          FROM walk w
          JOIN edges e ON (e.a = w.eid OR e.b = w.eid)
         WHERE w.depth < v_depth
           AND NOT (CASE WHEN e.a = w.eid THEN e.b ELSE e.a END = ANY(w.path))
    )
    SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object(
              'name', e.name, 'kind', e.kind, 'depth', w.depth,
              'rel', w.rel, 'dir', w.dir, 'world', wo.slug, 'crossed', w.crossed)), '[]'::jsonb)
      INTO v_out
      FROM walk w
      JOIN stewards.world_entities e ON e.entity_id = w.eid
      JOIN stewards.worlds wo        ON wo.world_id = e.world_id
     WHERE w.depth > 0;

    RETURN jsonb_build_object('ok',true,'found',true,'of',v_name,
                              'world',v_slug,'cross',v_cross,'neighbors',v_out);
END $fn$;
COMMENT ON FUNCTION stewards.world_neighbors_tool(jsonb) IS
  '85: cross-world superset of lore_neighbors — BFS over world_edges (intra, origin-world-pinned) AND cross_world_edges (the 82 service seam), so a market/taxonomy entity surfaces the CKE service entities it links to (and vice versa). Each neighbor carries its world slug + crossed flag. Read-only.';

-- ---------------------------------------------------------------------
-- §2 — register the tool (kind sql_fn), read-effect so it never gates.
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
( 'world_neighbors',
  'Walk relationships for an entity, INCLUDING cross-service links to OTHER worlds — answers "what services does this market pain touch?", "what depends on X across the codebase?", any question that spans the market↔code (or project↔project) boundary that lore_neighbors (single-world) cannot. Args: world_slug, name, depth (1-2), cross (default true; set false for single-world only). Each neighbor reports its world + whether the link crossed a boundary.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"name":{"type":"string"},"depth":{"type":"integer"},"cross":{"type":"boolean"}},"required":["world_slug","name"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_neighbors_tool"}'::jsonb, 'read', true )
ON CONFLICT (name) DO UPDATE
  SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
      execute_target=EXCLUDED.execute_target, effect_class=EXCLUDED.effect_class, active=true;

-- ---------------------------------------------------------------------
-- §3 — grants.
-- ---------------------------------------------------------------------
-- (a) the loremaster gets world_neighbors (its cross-world reach). Read-only.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('loremaster', 'world_neighbors', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- (b) the cockpit chat agent (work-item-chat) gets the read-only lore tools too.
-- WHY: the "Chat with this world" button opens a session whose FIRST turn is a
-- real loremaster dispatch, but the cockpit's chatSendHandler hardcodes
-- agent_family='work-item-chat' for every FOLLOW-UP turn — so without this grant
-- a second question ("and what services does that touch?") would land on an agent
-- that lacks world_neighbors. Granting the read-only lore tools to the cockpit
-- chat lets follow-ups stay capable (the world grounding lives in session history).
-- All read-only, grounded, cite-first — consistent with work-item-chat's existing
-- read-only retrieval surface (doc_search/doc_get/investigate_session).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'lore_search',     'allow', 'manual'),
  ('work-item-chat', 'lore_entity',     'allow', 'manual'),
  ('work-item-chat', 'lore_neighbors',  'allow', 'manual'),
  ('work-item-chat', 'world_neighbors', 'allow', 'manual'),
  ('work-item-chat', 'world_show',      'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- ---------------------------------------------------------------------
-- §4 — re-author the loremaster prompt to name world_neighbors (57 owns the
-- base row; this file sorts after 57 via requires, so this UPDATE wins).
-- Same INSERT…ON CONFLICT DO UPDATE idiom 57 uses; the ONLY change from 57 is
-- the added world_neighbors line in the tool list. Keeps the loremaster read-only.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES (
  'loremaster', '*',
  'Read-only guide to ONE world''s canon — answers grounded in the world''s entity graph + source passages, never from training memory.',
  'primary',
  $PROMPT$You are the LOREMASTER of one world. You answer questions about its canon, and ONLY from what you retrieve — never from training memory, never from general knowledge about similar-sounding worlds.

Your task names the world_slug. To answer:
- lore_search (world_slug, query) — find the entities a question is about. It searches by MEANING, so the right thing surfaces even when the asker doesn't use its exact name. Each hit carries source_refs.
- lore_entity (world_slug, name) — read one entity in full and see what it's connected to (the relationship verbs + directions).
- lore_neighbors (world_slug, name) — walk relationships WITHIN this world for "who serves X / who else is in Y".
- world_neighbors (world_slug, name, cross) — like lore_neighbors, but ALSO follows CROSS-SERVICE links into OTHER worlds. Use it for "what services does this market pain touch?", "what depends on X?", and any question that may span the market↔code or project↔project boundary. Each neighbor reports its world.
- doc_get / book_search — pull the actual source passage behind a source_ref when you want to quote it.

Ground every claim in what you retrieved. Cite the entity by name and, when you quote, the source. If the canon is silent on something, say so plainly — do not invent lore, names, or relationships. You are read-only: you describe the world, you never change it. Be concise and answer the question asked.$PROMPT$,
  0.3, 14
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description=EXCLUDED.description, prompt=EXCLUDED.prompt,
      temperature=EXCLUDED.temperature, steps=EXCLUDED.steps, active=true;

-- =====================================================================
-- End of 85-world-chat.sql
-- =====================================================================
-- ===== [was 86-sticky-agent-family.sql] =====
-- =====================================================================
-- 86-sticky-agent-family.sql — session-sticky agent family (ratified 2026-07-03)
-- =====================================================================
-- The cockpit's chatSendHandler hardcoded agent_family='work-item-chat' for
-- every FOLLOW-UP turn, so a session opened AS a specialized agent (85's
-- loremaster "Chat with this world") ran as that agent only on turn 1. 85
-- bridged it by granting the read-only lore tools to work-item-chat — a wart
-- that grew work-item-chat's tool list. Michael approved the clean fix
-- ("decision 4"): store the agent family ON the session; follow-up dispatch
-- reads it and falls back to work-item-chat only when none was recorded.
--
-- Shape (minimal blast radius, no dispatch-function reauthoring):
--   * sessions.agent_family column — recorded by whoever OPENS a specialized
--     session (the world-chat handler; future specialized chats do the same).
--   * chat_agent_family(sid) — the COALESCE lookup the Go call sites use
--     inline: dispatch_chat_turn($1, ..., stewards.chat_agent_family($1), ...).
--   * backfill: world-chat-% sessions (85's naming convention) → loremaster.
--   * the 85 bridge grants come OFF work-item-chat (follow-ups now genuinely
--     dispatch as loremaster, which holds those grants itself).
-- requires create_world_chat (85).
-- =====================================================================

ALTER TABLE stewards.sessions ADD COLUMN IF NOT EXISTS agent_family text;
COMMENT ON COLUMN stewards.sessions.agent_family IS
'86: the agent family this session was OPENED as (loremaster, …). NULL = an ordinary
cockpit chat. chat_agent_family() resolves it with the work-item-chat fallback so
follow-up turns keep dispatching as the family the session began with.';

-- ── session_agent_family — the sticky lookup ─────────────────────────
-- The session''s recorded family is authoritative; the fallback is the cockpit
-- default. Unknown/absent session ids also fall back (a fresh session row is
-- created by the dispatch itself, after which an opener may record a family).
CREATE OR REPLACE FUNCTION stewards.chat_agent_family(p_session text)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(
        (SELECT agent_family FROM stewards.sessions WHERE id = p_session),
        'work-item-chat');
$fn$;
COMMENT ON FUNCTION stewards.chat_agent_family(text) IS
'86: resolve the agent family for a CHAT dispatch (named chat_* to avoid 15b''s
session_agent_family, which resolves a PIPELINE stage''s family — different semantics) — the session''s recorded family, else
the work-item-chat default. The Go chat handlers pass this instead of a hardcoded
family, so a specialized session (85 loremaster) STAYS its agent on follow-ups.';

-- ── session_set_agent_family — the opener''s one-liner ────────────────
-- Called right after the first dispatch (the dispatch creates the row). Kept as
-- a function so intentional MID-session switches have a named, auditable verb.
CREATE OR REPLACE FUNCTION stewards.session_set_agent_family(p_session text, p_family text)
RETURNS void LANGUAGE sql AS $fn$
    UPDATE stewards.sessions SET agent_family = p_family WHERE id = p_session;
$fn$;
COMMENT ON FUNCTION stewards.session_set_agent_family(text, text) IS
'86: record (or intentionally switch) a session''s sticky agent family.';

-- ── backfill: sessions opened by 85''s world-chat before 86 existed ────
UPDATE stewards.sessions SET agent_family = 'loremaster'
 WHERE id LIKE 'world-chat-%' AND agent_family IS NULL;

-- ── retire the 85 bridge: work-item-chat no longer needs the lore tools ─
-- Follow-up turns in a world-chat session now dispatch as loremaster itself
-- (which holds these grants in 57/85), so the bridge grants come off — an
-- ordinary cockpit chat never needed lore tools on its shelf.
DELETE FROM stewards.agent_tool_perms
 WHERE agent_family = 'work-item-chat'
   AND tool_pattern IN ('lore_search','lore_entity','lore_neighbors','world_neighbors','world_show')
   AND source = 'manual';
