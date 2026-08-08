-- =====================================================================
-- v47 — judge-gate resume regression fix
-- =====================================================================
-- The v27 re-author of apply_judge_brief (107, lifeless core) claimed
-- "byte-identical except extracted_by" but silently dropped the entire
-- es7.4 resume tail: after a judge brief landed (including the empty-brief
-- fallback), the gated parent turn was never resumed. Every judge-gated
-- dispatch since v27 wedged its work item in_progress forever. Found live
-- 2026-08-08 (cache-experiment arm E); the manual unwedge is
-- stewards.chat_post_internal(family, model, session, provider).
-- This file = the live v27 body + the v04/es7.4 resume tail grafted back,
-- plus the defensive EXCEPTION handler (the DECLAREs survived v27).
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.apply_judge_brief()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_target_id   bigint;
    v_binding     text;
    v_raw_chars   int;
    v_content     text;
    v_parsed      jsonb;
    v_engrams_in  jsonb;
    v_engram      jsonb;
    v_norm        jsonb := '[]'::jsonb;
    v_state       text;
    v_discarded   text;
    v_surface     text;
    v_engrams_obj jsonb;
    v_msg_prefix  text;
    v_dispatch_id   bigint;
    v_parent_session text;
    v_disp_row      stewards.work_queue%ROWTYPE;
    v_wi            stewards.work_items%ROWTYPE;
    v_still_pending int;
    v_chat_id       bigint;
    v_judged_by     text;
BEGIN
    v_target_id := (NEW.payload ->> '_judge_brief_target_msg_id')::bigint;
    v_binding   := NEW.payload ->> '_judge_brief_binding';
    v_raw_chars := (NEW.payload ->> '_judge_brief_raw_chars')::int;
    v_judged_by := 'judge-brief/' || COALESCE(NULLIF(NEW.payload ->> 'requested_model', ''), NEW.provider, 'unknown');
    IF v_target_id IS NULL THEN
        RETURN NEW;
    END IF;
    v_msg_prefix := substring(v_target_id::text FROM 1 FOR 8);

    IF NEW.status = 'done' THEN
        DECLARE
            v_resp_str  text;
            v_resp_json jsonb;
        BEGIN
            v_resp_str := NEW.result ->> 'response';
            IF v_resp_str IS NULL OR v_resp_str = '' THEN
                v_content := NULL;
            ELSE
                v_resp_json := v_resp_str::jsonb;
                v_content := v_resp_json #>> '{choices,0,message,content}';
                IF v_content IS NULL OR v_content = '' THEN
                    v_content := v_resp_json #>> '{choices,0,message,reasoning_content}';
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_content := NULL;
        END;

        IF v_content IS NOT NULL AND v_content <> '' THEN
            BEGIN
                v_parsed := v_content::jsonb;
            EXCEPTION WHEN OTHERS THEN
                v_parsed := NULL;
            END;
        END IF;
    END IF;

    IF v_parsed IS NOT NULL THEN
        v_state     := lower(COALESCE(v_parsed ->> 'state', 'done'));
        v_discarded := COALESCE(v_parsed ->> 'discarded', '');
        v_engrams_in := COALESCE(v_parsed -> 'engrams', v_parsed -> 'items', '[]'::jsonb);
        IF jsonb_typeof(v_engrams_in) <> 'array' THEN
            v_engrams_in := '[]'::jsonb;
        END IF;

        FOR v_engram IN SELECT * FROM jsonb_array_elements(v_engrams_in)
        LOOP
            v_norm := v_norm || jsonb_build_array(jsonb_build_object(
                'id', COALESCE(NULLIF(v_engram ->> 'id',''),
                               'judge-' || v_msg_prefix || '-e' || (jsonb_array_length(v_norm)+1)::text),
                'tier', lower(COALESCE(v_engram ->> 'tier', 'cold')),
                'topic', COALESCE(NULLIF(v_engram ->> 'topic',''),
                                  NULLIF(v_engram ->> 'title',''), ''),
                'content', COALESCE(NULLIF(v_engram ->> 'content',''),
                                    NULLIF(v_engram ->> 'context',''), ''),
                'provenance', lower(COALESCE(NULLIF(v_engram ->> 'provenance',''), 'extracted')),
                'preserved', COALESCE(v_engram -> 'preserved', '{}'::jsonb)
            ));
        END LOOP;
    ELSE
        v_state     := 'empty';
        v_discarded := 'judge brief unavailable (status=' || NEW.status
                    || COALESCE(', error=' || NEW.error, '')
                    || ') — raw document preserved, read via read_overflow_raw';
    END IF;

    v_engrams_obj := jsonb_build_object(
        'items', v_norm,
        'state', v_state,
        'discarded', v_discarded,
        'injection_suspected', COALESCE((v_parsed ->> 'injection_suspected')::boolean, false),
        'extracted_at', now(),
        'extracted_by', v_judged_by,
        'extracted_for_binding', v_binding,
        'raw_chars', v_raw_chars,
        'source', 'es3-judge'
    );

    v_surface := stewards.render_judge_brief_surface(
        v_target_id,
        jsonb_build_object('engrams', v_norm, 'state', v_state, 'discarded', v_discarded)
    );

    UPDATE stewards.messages
       SET engrams = v_engrams_obj,
           content = v_surface
     WHERE id = v_target_id;

    RAISE NOTICE 'apply_judge_brief: wq=% target_msg=% brief written (state=%, % engrams)',
        NEW.id, v_target_id, v_state, jsonb_array_length(v_norm);

    -- ================= v47: the es7.4 resume tail, restored =================
    -- The v27 re-author ("byte-identical except extracted_by") dropped
    -- everything below RETURN NEW — so a judge-gated parent turn was NEVER
    -- resumed: the brief landed, the tool_dispatch sat done, and the work
    -- item hung in_progress forever (live wedge 2026-08-08, arm E of the
    -- cache experiment; manual unwedge was chat_post_internal by hand).
    SELECT parent_work_id, session_id INTO v_dispatch_id, v_parent_session
      FROM stewards.messages WHERE id = v_target_id;
    IF v_dispatch_id IS NULL THEN
        RAISE NOTICE 'apply_judge_brief: target_msg=% has no parent_work_id; no continuation', v_target_id;
        RETURN NEW;
    END IF;

    SELECT * INTO v_disp_row FROM stewards.work_queue
     WHERE id = v_dispatch_id FOR UPDATE;
    IF v_disp_row.id IS NULL THEN
        RETURN NEW;
    END IF;

    IF COALESCE(v_disp_row.result ? 'judge_continuation_enqueued', false) THEN
        RETURN NEW;
    END IF;

    SELECT count(*) INTO v_still_pending
      FROM stewards.messages
     WHERE parent_work_id = v_dispatch_id
       AND content LIKE '[JUDGE-PENDING]%';
    IF v_still_pending > 0 THEN
        RETURN NEW;   -- the last judge to finish will resume the parent
    END IF;

    SELECT * INTO v_wi FROM stewards.work_items
     WHERE v_parent_session = ANY(session_ids)
     ORDER BY created_at DESC LIMIT 1;
    IF v_wi.id IS NOT NULL AND v_wi.status NOT IN ('pending', 'in_progress') THEN
        RAISE NOTICE 'apply_judge_brief: work_item % status=% — not resuming (brief still written)',
            v_wi.id, v_wi.status;
        UPDATE stewards.work_queue
           SET result = COALESCE(result,'{}'::jsonb)
               || jsonb_build_object('judge_continuation_skipped', v_wi.status)
         WHERE id = v_dispatch_id;
        RETURN NEW;
    END IF;

    SELECT stewards.chat_post_internal(
        v_disp_row.payload ->> 'agent_family',
        v_disp_row.payload ->> 'model',
        v_parent_session,
        v_disp_row.provider
    ) INTO v_chat_id;

    UPDATE stewards.work_queue
       SET result = COALESCE(result,'{}'::jsonb) || jsonb_build_object(
               'judge_continuation_enqueued', true,
               'next_chat_work_id', v_chat_id)
     WHERE id = v_dispatch_id;

    RAISE NOTICE 'apply_judge_brief: parent turn resumed — continuation chat wq=% for session %',
        v_chat_id, v_parent_session;

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'apply_judge_brief: handler failed for wq=% target=%: %',
        NEW.id, v_target_id, SQLERRM;
    RETURN NEW;
END;
$function$;
