-- =====================================================================
-- v50 — the lane write path: add / amend, guarded
-- =====================================================================
-- Specced by the seats (2026-08-10), from threadchip's one invariant:
-- LANE-FIRST READ IS ONLY SAFE BECAUSE CORRECTION IS INLINE. A box's own
-- lane is weighted first in recall, so it re-reads its own stories
-- preferentially — and if a correction lands as a SIBLING memory, the stale
-- claim out-orders its own retraction, to the reader most likely to act on
-- it. So the write path makes sibling-correction hard, not merely discouraged.
--
-- Fermion's lane stays FILE-BACKED (MEMORY.md -> project-memory-index.py);
-- this path is for the RECORD-NATIVE lanes the remote boxes write, which have
-- no file store. Body lives in props->>'body', hook in props->>'index_hook';
-- origin_box is FORCED by the v49 trigger regardless of what is passed.
--
-- Two verbs, guarded:
--   brain_add    — new memory in the caller's lane. REFUSES when the subject
--                  collides with an existing live memory (side-quests' cheaper
--                  deterministic half: subject collision is checkable without
--                  judging intent), unless p_force. A refusal you can override
--                  beats a silent sibling you cannot see.
--   brain_amend  — append a correction to an existing memory IN THE CALLER'S
--                  OWN LANE, strike-don't-delete. REFUSES to amend another
--                  box's memory (that stays surface-first — nocix's boundary).
--
-- Oracle: brain_write_check() — the two refusals a static check cannot prove,
-- run in verify-50 under SET ROLE.
-- =====================================================================

-- Subject-collision detector. Deterministic, precision-over-recall (so the
-- adjudicator keeps trusting it): a collision is an existing LIVE memory whose
-- ref matches, OR whose normalized title matches, in ANY lane. Cross-lane
-- collisions matter most — that is exactly where a box would unknowingly write
-- a rival to another box's claim.
CREATE OR REPLACE FUNCTION stewards.memory_subject_collision(p_ref text, p_title text)
RETURNS TABLE (ref text, origin_box text, label text)
LANGUAGE sql STABLE AS $fn$
    SELECT n.ref, n.origin_box, n.label
      FROM stewards.nodes n
     WHERE n.kind = 'memory'
       AND NOT ('retracted' = ANY(n.labels))
       AND ( n.ref = p_ref
             OR (p_title IS NOT NULL AND p_title <> ''
                 AND regexp_replace(lower(n.label), '\s+', ' ', 'g')
                   = regexp_replace(lower(p_title), '\s+', ' ', 'g')) )
$fn$;

CREATE OR REPLACE FUNCTION stewards.brain_add(
    p_ref   text,
    p_title text,
    p_hook  text,
    p_body  text,
    p_mtype text DEFAULT 'reference',
    p_force boolean DEFAULT false
) RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_collision text;
    v_box text := stewards.current_box();
BEGIN
    IF NOT p_force THEN
        SELECT string_agg(ref || ' (' || origin_box || ')', ', ')
          INTO v_collision FROM stewards.memory_subject_collision(p_ref, p_title);
        IF v_collision IS NOT NULL THEN
            RAISE EXCEPTION
                'brain_add refused: subject collides with existing memory(s): %. '
                'If this CORRECTS one of them, use brain_amend (a correction must '
                'not be a sibling — lane-first recall would out-order the fix). '
                'If it is genuinely distinct, pass p_force := true.', v_collision
              USING ERRCODE = 'unique_violation';
        END IF;
    END IF;

    INSERT INTO stewards.nodes (kind, ref, label, summary, props, labels)
    VALUES ('memory', p_ref, p_title, coalesce(p_hook,''),
            jsonb_build_object('index_title', p_title, 'index_hook', p_hook,
                               'body', p_body, 'lane_native', true),
            ARRAY['mtype:' || p_mtype]::text[]);
    RETURN format('added %s to lane %s', p_ref, v_box);
END;
$fn$;
COMMENT ON FUNCTION stewards.brain_add(text,text,text,text,text,boolean) IS
'v50: new memory in the caller''s lane (origin_box forced by v49 trigger). Refuses on subject collision unless p_force — the deterministic half of sibling-correction prevention.';

CREATE OR REPLACE FUNCTION stewards.brain_amend(
    p_ref        text,
    p_correction text,
    p_supersedes text DEFAULT NULL   -- the span/claim now struck, quoted
) RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_box  text := stewards.current_box();
    v_node stewards.nodes;
    v_body text;
    v_stamp text := to_char(now(), 'YYYY-MM-DD');
BEGIN
    SELECT * INTO v_node FROM stewards.nodes
     WHERE kind = 'memory' AND ref = p_ref LIMIT 1;
    IF v_node.ref IS NULL THEN
        RAISE EXCEPTION 'brain_amend: no memory ''%'' to amend', p_ref
          USING ERRCODE = 'no_data_found';
    END IF;
    -- nocix's boundary: you may amend YOUR OWN lane; another box's memory is
    -- surface-first, not a direct write.
    IF v_node.origin_box IS DISTINCT FROM v_box THEN
        RAISE EXCEPTION
            'brain_amend refused: ''%'' is in lane % , not yours (%). Amending '
            'another box''s memory is surface-first, not a direct write.',
            p_ref, v_node.origin_box, v_box
          USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Append inline, strike-don't-delete: the superseded span stays visible,
    -- struck, correction beside it — the kv-cache-sharing.md pattern.
    v_body := coalesce(v_node.props->>'body','');
    IF p_supersedes IS NOT NULL AND p_supersedes <> '' THEN
        v_body := replace(v_body, p_supersedes, '~~' || p_supersedes || '~~');
    END IF;
    v_body := v_body || E'\n\n> ⚠ CORRECTED ' || v_stamp || ' — ' || p_correction;

    UPDATE stewards.nodes
       SET props = props || jsonb_build_object('body', v_body,
                     'last_amended_at', v_stamp,
                     'amend_count', coalesce((props->>'amend_count')::int,0)+1)
     WHERE ref = p_ref AND kind = 'memory';
    RETURN format('amended %s in lane %s (strike-in-place)', p_ref, v_box);
END;
$fn$;
COMMENT ON FUNCTION stewards.brain_amend(text,text,text) IS
'v50: inline correction to a memory in the caller''s OWN lane, strike-don''t-delete. Refuses another box''s lane (surface-first) — the sibling-correction failure lane-first recall would otherwise surface stale.';

-- Selftest reap (added same-day, threadchip's finding): box roles have
-- INSERT-via-function but no DELETE on nodes, so the client selftest's
-- cleanup failed SILENTLY on every remote box and left a permanent probe in
-- that box's own lane — exactly where lane-first recall serves it first, from
-- inside the gate that was supposed to bless its own fix. SECURITY DEFINER,
-- scoped hard: only selftest-prefixed refs, only the CALLER'S lane
-- (box_for_role(session_user) — session_user survives SECURITY DEFINER;
-- current_user inside a definer body is the owner, the v49 lesson).
CREATE OR REPLACE FUNCTION stewards.brain_selftest_reap()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'stewards', 'house', 'pg_temp' AS $fn$
DECLARE
    v_box text := stewards.box_for_role(session_user::text);
    v_n int;
BEGIN
    IF v_box IS NULL THEN
        v_box := stewards.current_box();   -- host path (stewards itself)
    END IF;
    DELETE FROM stewards.nodes
     WHERE kind = 'memory'
       AND ref LIKE 'brainwrite-selftest-%'
       AND origin_box = v_box;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$fn$;
COMMENT ON FUNCTION stewards.brain_selftest_reap() IS
'v50: delete selftest probes from the CALLER''s own lane only (selftest-prefixed refs only). Exists because box roles cannot DELETE on nodes and a silently-failing cleanup left probes in the lane recall trusts most.';

GRANT EXECUTE ON FUNCTION stewards.brain_add(text,text,text,text,text,boolean),
                          stewards.brain_amend(text,text,text),
                          stewards.memory_subject_collision(text,text),
                          stewards.brain_selftest_reap()
     TO brain_absorb;

-- THE ORACLE — the two refusals a static check cannot prove.
CREATE OR REPLACE FUNCTION stewards.brain_write_check()
RETURNS TABLE (check_name text, ok boolean, detail text)
LANGUAGE plpgsql VOLATILE AS $fn$
DECLARE
    v_ref text; v_err text; v_got_refusal boolean;
BEGIN
    -- (a) subject-collision refusal fires
    v_ref := 'brainwritecheck-collide-' || substr(md5(clock_timestamp()::text),1,6);
    PERFORM stewards.brain_add(v_ref, 'Collision Probe Alpha', 'first', 'body');
    v_got_refusal := false;
    BEGIN
        PERFORM stewards.brain_add(v_ref || '-2', 'Collision Probe Alpha', 'dup', 'body');
    EXCEPTION WHEN unique_violation THEN v_got_refusal := true;
    END;
    RETURN QUERY SELECT 'collision_refused', v_got_refusal,
        CASE WHEN v_got_refusal THEN 'duplicate subject refused'
             ELSE 'a colliding subject was ALLOWED as a sibling' END;

    -- (b) p_force overrides it
    v_got_refusal := true;
    BEGIN
        PERFORM stewards.brain_add(v_ref || '-3', 'Collision Probe Alpha', 'forced', 'body', 'reference', true);
        v_got_refusal := false;
    EXCEPTION WHEN unique_violation THEN v_got_refusal := true;
    END;
    RETURN QUERY SELECT 'force_overrides', NOT v_got_refusal,
        CASE WHEN v_got_refusal THEN 'p_force did NOT override' ELSE 'p_force overrode as designed' END;

    -- clean the probes
    DELETE FROM stewards.nodes WHERE kind='memory' AND ref LIKE 'brainwritecheck-collide-%';
END;
$fn$;
COMMENT ON FUNCTION stewards.brain_write_check() IS
'v50 oracle: proves the collision refusal fires and p_force overrides it. The cross-lane amend refusal needs two roles, so it lives in verify-50 under SET ROLE.';
