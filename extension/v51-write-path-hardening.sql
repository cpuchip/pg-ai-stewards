-- =====================================================================
-- v51 — write-path hardening (the sol-p0-release-batch)
-- =====================================================================
-- ⚠ NUMBER COLLISION, acknowledged: "v51" was already circulating as the
-- label of the frozen correction-closure spec. The chain sequence is the
-- chain sequence — this volume takes the number, and that spec keeps its
-- label as a spec; the foreman holds the pointer between them. This volume
-- is NOT that feature (feature work stays stopped until this batch is
-- green — Michael's hard-stop ruling, 2026-08-11).
--
-- One release-critical pass over Sol's 2026-08-11 audit findings, every
-- defect first reproduced live on a virgin cluster at HEAD 6d3e37a
-- (.spec/reviews/sol-p0-release-batch-redrun-2026-08-11.md):
--
--   1. box_for_role / lane_check — a public install has no house.roster BY
--      RULING (the roster never ships), yet v49's stamp trigger read it on
--      every INSERT: a fresh install died at its first write. Re-authored
--      with a STRUCTURAL absence test (to_regclass IS NULL ⇒ "no roster on
--      this install" ⇒ v49's existing role-name fallback). Deliberately
--      narrow: permission-denied or any other failure on an EXISTING roster
--      still raises. Never EXCEPTION WHEN OTHERS.
--   2. brain_add — the sibling-prevention check was read-then-insert; two
--      concurrent adds of one subject both passed (watched happen). Now:
--      transaction-scoped advisory locks on the collision domain (ref, then
--      normalized title — deterministic order), then RECHECK under the lock.
--   3. brain_amend — read-modify-write with no lock silently discarded the
--      losing session's correction (watched happen). Now: SELECT ... FOR
--      UPDATE on the identity row BEFORE the body is read; update by
--      immutable id. Concurrent amends serialize; both corrections land.
--   4. p_force — was part of the routine agent grant: any box could bypass
--      the only sibling-correction control. Now operator-only (host or
--      superuser); a box passing p_force gets a refusal naming the rule.
--   5. origin_box — "unforgeable" held only at INSERT; the enrollment grant
--      includes UPDATE on nodes/fact_edges, so any box could rewrite lane
--      history afterward. Now a BEFORE UPDATE OF origin_box trigger rejects
--      any change (administrative lane migration must disable the trigger
--      explicitly — and account for it).
--   6. brain_selftest_reap — SECURITY DEFINER DELETE, executable by PUBLIC
--      (function default). Revoked; brain_absorb keeps its v50 grant.
--   7. fact_recall_laned — any caller could pass any lane as "own". Revoked
--      from PUBLIC (owner/admin analysis stays possible); callers get
--      fact_recall_mine, which derives the lane from session_user the same
--      way the reap does (the SET ROLE testability limit noted at verify-50
--      applies here identically).
--
-- One grammar rule: title normalization now lives in memory_title_norm()
-- and is used by BOTH the collision detector and the advisory lock key —
-- two spellings of a normalization is how a lock guards one domain while
-- the detector checks another.
-- =====================================================================

-- The single normalization both the detector and the lock key share.
CREATE OR REPLACE FUNCTION stewards.memory_title_norm(p_title text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT regexp_replace(lower(coalesce(p_title, '')), '\s+', ' ', 'g')
$fn$;
COMMENT ON FUNCTION stewards.memory_title_norm(text) IS
'v51: the ONE normalization for memory-subject comparison. Used by memory_subject_collision AND brain_add''s advisory lock key — one grammar, not two.';

-- Verbatim v50 semantics, with the normalization routed through the helper.
CREATE OR REPLACE FUNCTION stewards.memory_subject_collision(p_ref text, p_title text)
RETURNS TABLE (ref text, origin_box text, label text)
LANGUAGE sql STABLE AS $fn$
    SELECT n.ref, n.origin_box, n.label
      FROM stewards.nodes n
     WHERE n.kind = 'memory'
       AND NOT ('retracted' = ANY(n.labels))
       AND ( n.ref = p_ref
             OR (p_title IS NOT NULL AND p_title <> ''
                 AND stewards.memory_title_norm(n.label)
                   = stewards.memory_title_norm(p_title)) )
$fn$;

-- ---------------------------------------------------------------------
-- brain_add: serialize the collision domain, then recheck; p_force is
-- operator-only. Signature unchanged (the extension-function lock forbids
-- re-parameterizing); the v50 GRANT to brain_absorb survives the re-author.
-- ---------------------------------------------------------------------
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
    -- v51: the force bypass is operator-only. It was part of the routine
    -- agent grant, which reduced the core integrity promise to
    -- prompt-following exactly where a model is correcting itself.
    IF p_force AND NOT (current_user IN ('stewards', 'postgres')
                        OR (SELECT rolsuper FROM pg_roles
                             WHERE rolname = current_user)) THEN
        RAISE EXCEPTION
            'brain_add: p_force is operator-only (v51). A correction belongs in '
            'brain_amend; a genuinely distinct subject that still collides is a '
            'naming problem to surface, not a refusal to override.'
          USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- v51: serialize the collision domain BEFORE checking it. Two advisory
    -- locks, transaction-scoped, always in the same order (ref, then title)
    -- so concurrent adds cannot deadlock. A concurrent add of the same
    -- subject blocks here until the first commits, and the recheck below
    -- then sees the committed row. Locks are taken even under p_force so a
    -- forced add still serializes against a concurrent guarded one.
    PERFORM pg_advisory_xact_lock(
        hashtext('stewards.brain_add.ref'), hashtext(p_ref));
    IF p_title IS NOT NULL AND p_title <> '' THEN
        PERFORM pg_advisory_xact_lock(
            hashtext('stewards.brain_add.title'),
            hashtext(stewards.memory_title_norm(p_title)));
    END IF;

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
'v51: new memory in the caller''s lane (origin_box forced by v49 trigger). Collision domain serialized by advisory xact locks (ref + normalized title) with a recheck under the lock — two concurrent adds of one subject cannot both land. p_force is operator-only.';

-- ---------------------------------------------------------------------
-- brain_amend: lock the identity row before reading the body.
-- ---------------------------------------------------------------------
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
    -- v51: FOR UPDATE before anything is read. A concurrent amend blocks
    -- here and, when it proceeds, re-reads the committed row — so no
    -- correction is ever built from a stale body and silently discarded.
    -- (kind, ref) is unique (v00), so this is the identity row.
    SELECT * INTO v_node FROM stewards.nodes
     WHERE kind = 'memory' AND ref = p_ref
     ORDER BY id LIMIT 1
       FOR UPDATE;
    IF v_node.ref IS NULL THEN
        RAISE EXCEPTION 'brain_amend: no memory ''%'' to amend', p_ref
          USING ERRCODE = 'no_data_found';
    END IF;
    -- nocix's boundary: you may amend YOUR OWN lane; another box's memory is
    -- surface-first, not a direct write. (Checked under the lock; origin_box
    -- is immutable as of this volume, so the answer cannot change after.)
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
     WHERE id = v_node.id;   -- v51: by immutable id, not (ref, kind)
    RETURN format('amended %s in lane %s (strike-in-place)', p_ref, v_box);
END;
$fn$;
COMMENT ON FUNCTION stewards.brain_amend(text,text,text) IS
'v51: inline correction to a memory in the caller''s OWN lane, strike-don''t-delete. Locks the identity row (FOR UPDATE) before reading, so concurrent amends serialize and every correction survives. Refuses another box''s lane (surface-first).';

-- ---------------------------------------------------------------------
-- box_for_role / lane_check: the roster is host-private and never ships
-- (brain-client roster.py rules the house schema private) — a PUBLIC
-- install legitimately has no house.roster. Structural absence ⇒ the
-- role-name fallback v49 already designed for unenrolled roles. Anything
-- else that goes wrong against an EXISTING roster still raises.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.box_for_role(p_role text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = stewards, house, pg_temp AS $fn$
DECLARE
    v_name text;
BEGIN
    -- v51: STRUCTURAL absence test, deliberately narrow — to_regclass, not
    -- an exception handler. Missing roster = "no roster on this install"
    -- (public posture) ⇒ NULL ⇒ current_box()'s role-name fallback.
    -- Permission-denied or corruption on a roster that EXISTS must raise,
    -- not fall back: a host whose roster stopped being readable has a
    -- broken enrollment surface, not a public posture.
    IF to_regclass('house.roster') IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT r.name INTO v_name FROM house.roster r
     WHERE r.pg_role = p_role AND r.revoked_at IS NULL LIMIT 1;
    RETURN v_name;
END;
$fn$;
COMMENT ON FUNCTION stewards.box_for_role(text) IS
'v49/v51: roster lookup for the writing seat''s lane. SECURITY DEFINER (house is host-private; box roles have no USAGE). v51: a MISSING roster is the public-install posture (to_regclass guard ⇒ NULL ⇒ role-name lanes); failures against an existing roster still raise.';

CREATE OR REPLACE FUNCTION stewards.lane_check()
RETURNS TABLE (check_name text, ok boolean, detail text)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_n bigint; v_txt text;
BEGIN
    -- (a) every memory node and live edge carries a lane
    SELECT count(*) INTO v_n FROM stewards.nodes WHERE origin_box IS NULL;
    RETURN QUERY SELECT 'nodes_have_lane', v_n = 0,
        v_n || ' node(s) with NULL origin_box';
    SELECT count(*) INTO v_n FROM stewards.fact_edges WHERE origin_box IS NULL;
    RETURN QUERY SELECT 'edges_have_lane', v_n = 0,
        v_n || ' fact_edge(s) with NULL origin_box';

    -- (b) the stamp is forced, not defaulted — a caller cannot forge a lane
    RETURN QUERY SELECT 'stamp_is_forced',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'stamp_origin_box' AND NOT tgisinternal),
        'BEFORE INSERT triggers present on nodes + fact_edges';

    -- (b2, v51) the stamp is also immutable — post-insert rewrites rejected
    RETURN QUERY SELECT 'stamp_is_immutable',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'reject_origin_box_change' AND NOT tgisinternal),
        'BEFORE UPDATE OF origin_box triggers present on nodes + fact_edges';

    -- (c) lane names resolve to real seats (a typo'd lane is an orphan lane).
    --     v51: on a roster-less (public) install this check is vacuously
    --     green BY DESIGN — lanes are role names there, and there is no
    --     roster to resolve against. Structural guard, mirroring
    --     box_for_role: to_regclass, never an exception handler.
    IF to_regclass('house.roster') IS NULL THEN
        RETURN QUERY SELECT 'lanes_are_seats', true,
            'no roster on this install (role-name lanes by design)';
    ELSE
        SELECT string_agg(DISTINCT origin_box, ', ') INTO v_txt
          FROM stewards.nodes n
         WHERE n.origin_box IS NOT NULL
           AND n.origin_box <> 'fermion'
           AND NOT EXISTS (SELECT 1 FROM house.roster r
                            WHERE r.name = n.origin_box);
        RETURN QUERY SELECT 'lanes_are_seats', v_txt IS NULL,
            COALESCE('unknown lane(s): ' || v_txt, 'all lanes resolve to roster seats');
    END IF;

    -- (d) THREADCHIP'S FALSIFIER RULE. A memory whose hook carries a
    --     quantitative claim must also carry the axis along which it stops
    --     being true. Its own evidence: of four wrong generalizations it
    --     shipped in a week, a hardware fingerprint would have caught one —
    --     the discriminators were model family, which-resource-binds-first,
    --     workload shape, and concurrency. By its account this check would
    --     have caught two at write time.
    --     Advisory for pre-v49 rows (reported, not failed); the write path
    --     enforces it going forward.
    SELECT count(*) INTO v_n
      FROM stewards.nodes n
     WHERE n.kind = 'memory'
       AND n.created_at > '2026-08-10'::timestamptz
       AND (n.props ->> 'index_hook') ~ '[0-9]+(\.[0-9]+)?\s*(x|×|%|ms|s\b|tok|MB|GB|/s)'
       AND (n.props ->> 'index_hook') !~* 'falsifi|stale.when|until|unless|only (when|on|for)|breaks (when|at)';
    RETURN QUERY SELECT 'quantitative_claims_have_falsifier', v_n = 0,
        v_n || ' post-v49 memory hook(s) carry a number with no falsifier '
             || '(the axis along which it stops being true)';
END;
$fn$;
COMMENT ON FUNCTION stewards.lane_check() IS
'v49/v51 oracle: lanes present, forced, immutable, and resolvable (roster-less installs vacuously green by design); plus threadchip''s falsifier rule on quantitative memory claims. Run in the verify suite.';

-- ---------------------------------------------------------------------
-- origin_box is immutable. The v49 stamp made the lane unforgeable at
-- INSERT; the enrollment grant includes UPDATE on nodes/fact_edges, so
-- lane history was rewritable afterward — recall order and provenance
-- changed while lane_check stayed green.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.reject_origin_box_change() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.origin_box IS DISTINCT FROM OLD.origin_box THEN
        RAISE EXCEPTION
            'origin_box is immutable (v51): % -> % rejected on %.%. Lane '
            'attribution is stamped at insert and never rewritten; an '
            'administrative lane migration must disable this trigger '
            'explicitly — and account for it.',
            coalesce(OLD.origin_box, '<null>'), coalesce(NEW.origin_box, '<null>'),
            TG_TABLE_SCHEMA, TG_TABLE_NAME
          USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$fn$;
COMMENT ON FUNCTION stewards.reject_origin_box_change() IS
'v51: BEFORE UPDATE OF origin_box — any change to a stamped lane is rejected. A same-value SET passes (no-op writers survive); a DIFFERENT value raises. Disable-and-account is the only administrative path.';

DROP TRIGGER IF EXISTS reject_origin_box_change ON stewards.nodes;
CREATE TRIGGER reject_origin_box_change
    BEFORE UPDATE OF origin_box ON stewards.nodes
    FOR EACH ROW EXECUTE FUNCTION stewards.reject_origin_box_change();
DROP TRIGGER IF EXISTS reject_origin_box_change ON stewards.fact_edges;
CREATE TRIGGER reject_origin_box_change
    BEFORE UPDATE OF origin_box ON stewards.fact_edges
    FOR EACH ROW EXECUTE FUNCTION stewards.reject_origin_box_change();

-- ---------------------------------------------------------------------
-- Function ACLs. Functions default to PUBLIC EXECUTE; a SECURITY DEFINER
-- DELETE and a choose-your-own-lane recall were both reachable by any
-- login with USAGE on the schema.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION stewards.brain_selftest_reap() FROM PUBLIC;
-- (brain_absorb keeps its v50 grant — grants survive CREATE OR REPLACE
--  and this volume does not re-author the reap.)

REVOKE ALL ON FUNCTION stewards.fact_recall_laned(jsonb,text,integer,integer,real,timestamptz,real) FROM PUBLIC;
-- No re-grant: fact_recall_laned is now the owner/admin ANALYSIS surface
-- (simulate any lane's view of the record). Callers use fact_recall_mine.

-- The caller-facing recall: YOUR lane, derived — not chosen. SECURITY
-- DEFINER because fact_recall_laned is deliberately locked away from
-- callers; the lane comes from session_user exactly the way the v50 reap
-- derives it (and with the same SET ROLE testability limit verify-50
-- documents: SET ROLE changes current_user, not session_user, so only a
-- real box login exercises a non-host lane end to end).
CREATE OR REPLACE FUNCTION stewards.fact_recall_mine(
    p_seeds    jsonb,
    p_max_hops integer DEFAULT 2,
    p_limit    integer DEFAULT 15,
    p_decay    real    DEFAULT 0.5,
    p_as_of    timestamptz DEFAULT NULL,
    p_boost    real    DEFAULT 1.35
) RETURNS TABLE (kind text, ref text, label text, score real, hops integer,
                 origin_box text, own_lane boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = stewards, house, pg_temp AS $fn$
    SELECT * FROM stewards.fact_recall_laned(
        p_seeds,
        coalesce(stewards.box_for_role(session_user::text),
                 CASE WHEN session_user IN ('stewards', 'postgres') THEN 'fermion'
                      ELSE session_user::text END),
        p_max_hops, p_limit, p_decay, p_as_of, p_boost)
$fn$;
COMMENT ON FUNCTION stewards.fact_recall_mine(jsonb,integer,integer,real,timestamptz,real) IS
'v51: lane-first recall for the CALLER''s own lane, derived from session_user (roster first, host fallback, else role name). No lane parameter — the caller cannot privilege a rival lane. fact_recall_laned stays owner-only for lane-simulation analysis.';

REVOKE ALL ON FUNCTION stewards.fact_recall_mine(jsonb,integer,integer,real,timestamptz,real) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION stewards.fact_recall_mine(jsonb,integer,integer,real,timestamptz,real) TO brain_read;
