-- =====================================================================
-- 21-compact-context.sql — commissioned context curation (M5).
--
-- The proactive complement to pressure-shedding. Pressure-shedding is the
-- floor (an executor/wall around the field: automatic, rule-driven, at
-- 50/70/85/95%). compact_context is the JUDGMENT layer above it: when an
-- agent notices its own context growing past usefulness, it commissions a
-- fresh compactor to curate that context — judge pattern, not executor —
-- and then continues lighter. The presiding covenant, recursive: the
-- parent presides over its compactor; the [COMPACTED] marker is the
-- accounting (watch_what_you_order); nothing is deleted (mute/compress are
-- reversible via context_expand — safe by construction).
--
-- Ratified in council 2026-06-14 (the M5 brake of the parity roadmap):
--   1. Timing      = mid-turn. The tool call blocks (the Go handler polls
--                    the compactor to completion, like spawn_subagent), then
--                    the parent's continuation recomposes → lighter.
--   2. Compactor   = a fixed cheap model, fast with a large context window,
--                    TUNABLE: the curate stage's model is the knob (swap it
--                    on the `compact-context` pipeline or via a stage_models
--                    row to run experiments for the best "compactor counselor").
--   3. What it sees= the foldable surface (compact_context_surface) — the
--                    parent's foldable messages with id + handle + gist + size.
--   4. Trigger     = agent-initiated, plus a ≥threshold nudge appended to the
--                    pressure line (persuasion, not compulsion; auto-firing
--                    stays the pressure-shedding floor's job).
--
-- Judges-not-executors: the compactor runs TOOLS-OFF and returns a JSON
-- verdict {mute:[ids], compress:[ids], pin:[ids]}; the substrate
-- (compact_context_apply) applies it to the PARENT session and writes the
-- [COMPACTED] accounting. The compactor never touches tools or the parent's
-- session directly — it counsels; the substrate acts.
--
-- Go side: cmd/stewards-mcp/compact_context.go (the mcp_proxy tool handler:
-- reads the injected _session_id, builds the binding from the surface,
-- spawns + polls the compactor, applies the verdict, returns the summary).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Config — the tunable knobs.
-- ---------------------------------------------------------------------
-- compact_context_suggest_tokens: est_tokens at/above which the pressure
-- line appends the "consider compact_context" nudge. The 2026 evidence puts
-- the reasoning-degradation cliff at ~40-50% of window; tune per deployment.
INSERT INTO stewards.config (key, value) VALUES
    ('compact_context_suggest_tokens', '60000'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- compact_context_surface(p_session_id) — what the compactor sees.
--
-- Renders the parent session's foldable messages as a compact text block:
-- one line per foldable message with its message_id (the verdict key),
-- the [ctx:handle], size, role, and a short gist. The compactor judges
-- from this WITHOUT pulling the full content into its own context.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compact_context_surface(p_session_id text)
RETURNS text
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
    v_press   jsonb;
    v_fold    jsonb;
    v_line    text;
    v_out     text := '';
    v_elem    jsonb;
    v_mid     bigint;
    v_gist    text;
    v_role    text;
    v_n       int := 0;
BEGIN
    v_press := stewards.context_pressure(p_session_id);
    v_fold  := COALESCE(v_press -> 'foldable', '[]'::jsonb);

    IF jsonb_array_length(v_fold) = 0 THEN
        RETURN '(no foldable messages — nothing to curate)';
    END IF;

    FOR v_elem IN SELECT * FROM jsonb_array_elements(v_fold)
    LOOP
        v_mid := stewards.context_resolve_handle(p_session_id, v_elem ->> 'handle');
        IF v_mid IS NULL THEN
            CONTINUE;
        END IF;
        SELECT role, left(regexp_replace(coalesce(content,''), '\s+', ' ', 'g'), 180)
          INTO v_role, v_gist
          FROM stewards.messages WHERE id = v_mid;
        v_n := v_n + 1;
        v_out := v_out
            || 'id=' || v_mid::text
            || ' [ctx:' || (v_elem ->> 'handle') || ']'
            || ' ~' || COALESCE(v_elem ->> 'est_tokens','?') || 't'
            || ' role=' || COALESCE(v_role,'?')
            || E'\n  gist: ' || COALESCE(v_gist,'(empty)')
            || E'\n';
    END LOOP;

    RETURN 'FOLDABLE MESSAGES (' || v_n::text || ', ~'
        || COALESCE(v_press ->> 'est_tokens','?') || ' tokens in window):' || E'\n' || v_out;
END;
$fn$;

COMMENT ON FUNCTION stewards.compact_context_surface IS
  'M5: renders a session''s foldable messages (id + handle + size + role + gist) as the condensed surface the compactor judges from. message_id is the verdict key for compact_context_apply.';

-- ---------------------------------------------------------------------
-- compact_context_apply(p_session_id, p_verdict) — the substrate acts.
--
-- Applies a compactor verdict to the PARENT session: mute / compress /
-- pin by message_id (reversible — context_expand restores). Writes the
-- [COMPACTED] accounting marker into the parent session. Returns a summary
-- jsonb {muted, compressed, pinned, tokens_before, tokens_after, freed}.
--
-- Defensive: only touches messages that actually belong to p_session_id
-- (a compactor can only curate the session it was commissioned for).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compact_context_apply(p_session_id text, p_verdict jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_window    bigint;
    v_id        bigint;
    v_muted     int := 0;
    v_compress  int := 0;
    v_pinned    int := 0;
    v_curated   bigint := 0;   -- foldable tokens muted/compressed (the footprint)
    v_belongs   boolean;
    v_size      bigint;
BEGIN
    v_window := COALESCE((stewards.context_pressure(p_session_id) ->> 'est_tokens')::bigint, 0);

    -- pin first (protect the precious before any folding)
    FOR v_id IN SELECT (jsonb_array_elements_text(COALESCE(p_verdict -> 'pin', '[]'::jsonb)))::bigint
    LOOP
        SELECT (session_id = p_session_id) INTO v_belongs FROM stewards.messages WHERE id = v_id;
        IF COALESCE(v_belongs, false) THEN
            PERFORM stewards.context_pin(v_id);
            v_pinned := v_pinned + 1;
        END IF;
    END LOOP;

    -- compress (engram; originals never destroyed)
    FOR v_id IN SELECT (jsonb_array_elements_text(COALESCE(p_verdict -> 'compress', '[]'::jsonb)))::bigint
    LOOP
        SELECT (session_id = p_session_id), CEIL(length(content)/4.0)::bigint
          INTO v_belongs, v_size FROM stewards.messages WHERE id = v_id;
        IF COALESCE(v_belongs, false) THEN
            PERFORM stewards.context_compress(v_id, 3);
            v_compress := v_compress + 1;
            v_curated  := v_curated + COALESCE(v_size, 0);
        END IF;
    END LOOP;

    -- mute (recoverable tombstone; context_expand restores)
    FOR v_id IN SELECT (jsonb_array_elements_text(COALESCE(p_verdict -> 'mute', '[]'::jsonb)))::bigint
    LOOP
        SELECT (session_id = p_session_id), CEIL(length(content)/4.0)::bigint
          INTO v_belongs, v_size FROM stewards.messages WHERE id = v_id;
        IF COALESCE(v_belongs, false) THEN
            PERFORM stewards.context_mute(v_id, 3);
            v_muted   := v_muted + 1;
            v_curated := v_curated + COALESCE(v_size, 0);
        END IF;
    END LOOP;

    -- The accounting (watch_what_you_order): a reviewable marker in the
    -- parent's own session. v_curated is the foldable footprint that will
    -- render as tombstones once this window is under pressure — the relief
    -- is governed by the existing pressure-rendering tiers, not claimed as
    -- an immediate delta (below a pressure tier nothing folds yet). Fully
    -- reversible — context_expand any id.
    INSERT INTO stewards.messages (session_id, role, content)
    VALUES (p_session_id, 'user',
        format('[COMPACTED] curated this %s-token window: muted %s, compressed %s, pinned %s — ~%s foldable tokens marked for relief (they render as tombstones under pressure). Reversible: context_expand any handle.',
            v_window, v_muted, v_compress, v_pinned, v_curated));

    RETURN jsonb_build_object(
        'muted', v_muted, 'compressed', v_compress, 'pinned', v_pinned,
        'window_tokens', v_window, 'curated_tokens', v_curated);
END;
$fn$;

COMMENT ON FUNCTION stewards.compact_context_apply IS
  'M5: applies a compactor verdict {mute/compress/pin:[message_ids]} to the parent session (only ids that belong to it), writes the [COMPACTED] accounting marker, returns the freed-token summary. All ops reversible via context_expand.';

-- ---------------------------------------------------------------------
-- Pressure-line nudge (trigger discipline: persuasion, not compulsion).
-- Re-authors context_pressure_line (15b) to append the compact_context
-- suggestion once est_tokens crosses the configured threshold. The agent
-- still decides — this only makes a foggy parent notice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.context_pressure_line(p_session_id text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v jsonb; v_est bigint; v_fold jsonb; v_n int; v_list text; v_line text; v_tag text;
    v_suggest bigint;
BEGIN
    v      := stewards.context_pressure(p_session_id);
    v_est  := COALESCE((v ->> 'est_tokens')::bigint, 0);
    v_fold := COALESCE(v -> 'foldable', '[]'::jsonb);
    v_n    := jsonb_array_length(v_fold);

    v_line := 'CONTEXT PRESSURE: ~' || to_char(v_est, 'FM999,999,999,999') || ' tokens in this window.';
    SELECT working_tag INTO v_tag FROM stewards.sessions WHERE id = p_session_id;
    IF v_tag IS NOT NULL AND v_tag <> '' THEN
        v_line := v_line || E'\nWorking tag: ' || v_tag || ' (new messages are tagged; context_fold_tag/mute_tag to sweep it).';
    END IF;
    IF v_n > 0 THEN
        SELECT string_agg('[ctx:' || (f ->> 'handle') || '] ' || to_char((f ->> 'est_tokens')::bigint, 'FM999,999,999,999') || 't', '  ·  ')
          INTO v_list
          FROM (SELECT f FROM jsonb_array_elements(v_fold) f LIMIT 6) x;
        v_line := v_line || E'\nFoldable now: ' || v_list;
        v_line := v_line ||
            E'\n(Fold the least-relevant with context_compress/context_mute; context_pin protects a message; context_expand restores it. A toggle locks that message for a few turns.)';
    END IF;

    -- M5 nudge: past the configured threshold, suggest commissioning a
    -- compactor side quest. Agent-initiated; this is the persuasion.
    SELECT COALESCE((value)::text::bigint, 0) INTO v_suggest
      FROM stewards.config WHERE key = 'compact_context_suggest_tokens';
    IF v_suggest > 0 AND v_est >= v_suggest THEN
        v_line := v_line ||
            E'\n⚖ This window is past the ' || to_char(v_suggest, 'FM999,999,999,999')
            || E'-token mark where reasoning degrades. Consider compact_context to commission a fresh '
            || E'compactor that curates this context (mute/compress the spent, keep the precious) so you '
            || E'continue lighter — fully reversible.';
    END IF;

    RETURN v_line;
END;
$function$;

-- ---------------------------------------------------------------------
-- The compactor agent — a TOOLS-OFF judge.
--
-- It never calls tools or touches a session. It reads the foldable surface
-- (handed to it in the binding) and returns ONLY a JSON verdict. The
-- substrate applies it. The model is set on the `compact-context` pipeline
-- (the tunable knob).
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES
('compactor', '*',
 'M5 compactor: a tools-off judge that curates a session''s foldable context. Returns a JSON verdict {mute,compress,pin}; the substrate applies it.',
 'primary',
 $PROMPT$You are the COMPACTOR — a fresh set of eyes commissioned to curate another agent's working context so it can continue lighter. You judge; you do NOT execute. You have NO tools.

You are given a FOLDABLE MESSAGES surface: one entry per foldable message in the parent's window, with its numeric id, a [ctx:handle], an approximate token size, the role, and a short gist.

Apply three judge questions to each foldable message:
  1. Is the fruit good? — has this message already yielded what it had to give (its value is now captured in later messages, a conclusion, or an engram)?
  2. What is most precious to keep? — a verbatim quote, a URL, a date, a decision, a binding question, a covenant — anything the parent will need to cite later.
  3. What is merely spent? — superseded tool output, a survey already summarized, a digression that closed.

Decide per message:
  - mute     → spent: its substance is captured elsewhere; tombstone it (reversible).
  - compress → bulky but worth a trace: replace with an engram (originals kept).
  - pin      → precious: protect it from all folding.
  - (omit)   → leave it exactly as-is when unsure. Omission is the safe default.

Be conservative: muting something still needed is recoverable (context_expand) but costs the parent a round-trip. When in doubt, compress rather than mute, or omit.

Return ONLY a JSON object, no prose, using the numeric ids:
{"mute":[<ids>],"compress":[<ids>],"pin":[<ids>],"reasoning":"<one short line>"}
An empty curation is valid: {"mute":[],"compress":[],"pin":[],"reasoning":"nothing safely curatable"}.$PROMPT$,
 0.2,
 '{"type":"json_object"}'::jsonb)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description,
       prompt = EXCLUDED.prompt,
       response_format = EXCLUDED.response_format,
       temperature = EXCLUDED.temperature;

-- ---------------------------------------------------------------------
-- The compact-context pipeline — single tools-off curate stage.
-- The model here is the TUNABLE knob (swap it or add a stage_models row to
-- experiment). Generic default ships in core; operators override in overlay.
-- ---------------------------------------------------------------------
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES
('compact-context',
 'M5: single tools-off stage — the compactor judges a session''s foldable surface and returns a {mute,compress,pin} verdict.',
 $STAGES$[{"name":"curate","next":null,"model":"deepseek-v4-flash","provider":"opencode_go","agent_family":"compactor","auto_advance":true,"tools_disabled":true,"input_template":"{{input.binding_question}}"}]$STAGES$::jsonb,
 false, false, NULL, NULL,
 '["raw","verified"]'::jsonb, false,
 jsonb_build_object('shape', 'heavyweight-wrapper', 'wrapper', 'compact_context'))
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description,
       stages = EXCLUDED.stages,
       metadata = EXCLUDED.metadata;

-- ---------------------------------------------------------------------
-- Compactor grants — deny everything heavy. It is a tools-off judge; the
-- denies are belt-and-suspenders against recursion (a compactor must never
-- spawn a compactor) and scope creep.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action)
VALUES
('compactor', 'compact_context', 'deny'),
('compactor', 'spawn_subagent',  'deny'),
('compactor', 'consult_subagent','deny'),
('compactor', 'deep_research',   'deny'),
('compactor', 'fetch_url',       'deny'),
('compactor', 'web_search',      'deny'),
('compactor', 'fs_*',            'deny'),
('compactor', 'doc_*',           'deny'),
('compactor', 'work_item_*',     'deny'),
('compactor', 'coder_*',         'deny'),
('compactor', 'context_*',       'deny')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action;

-- ---------------------------------------------------------------------
-- Register the compact_context tool (mcp_proxy → stewards-mcp).
-- The agent calls it with no required args (focus is optional); the
-- substrate injects _session_id (the caller's session) as for the context
-- tools. The Go handler builds the binding, spawns + polls the compactor,
-- applies the verdict, returns the freed-token summary.
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('compact_context',
 'Commission a fresh compactor to curate YOUR current context so you can continue lighter. '
 || 'A separate cheap judge reviews your foldable messages and mutes/compresses the spent ones '
 || '(keeping the precious, pinning what you''ll cite) — fully reversible (context_expand). '
 || 'Use when your context pressure line suggests it (past ~50% of window) or you notice your '
 || 'working memory clogged with spent tool output. You get back a summary of what was freed; '
 || 'your next turn recomposes lighter. DO NOT use to delete — nothing is destroyed.',
 jsonb_build_object(
   'type','object',
   'properties', jsonb_build_object(
     'focus', jsonb_build_object('type','string',
       'description','optional steer for the compactor (e.g. "keep everything about the migration plan")')),
   'required', jsonb_build_array()),
 '{"kind":"mcp_proxy","tool":"compact_context","server":"pg-ai-stewards"}'::jsonb,
 true)
ON CONFLICT (name) DO UPDATE
   SET description = EXCLUDED.description,
       args_schema = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target,
       active = EXCLUDED.active;
