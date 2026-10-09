-- =====================================================================
-- v60: render_stage_input carries backslashes in input values verbatim.
-- =====================================================================
-- Each {{path}} was filled with regexp_replace(rendered, pattern, v_value,
-- 'g'), and Postgres reads the replacement argument as a pattern of its
-- own: "\\" becomes "\", "\&" becomes the matched {{path}} text, "\1".."\9"
-- become empty. So any input value holding a backslash reached the model
-- altered (LaTeX line breaks, Windows and UNC paths, regexes). Found on a
-- second instance digesting a LaTeX textbook: the work item's input held two
-- "\\" line breaks and the rendered prompt held none.
--
-- The fix doubles every backslash in the value before it is used as the
-- replacement, so the rendered text equals the input. Only backslash
-- sequences are special in a Postgres replacement string. Body otherwise
-- v01's verbatim. Oracle: virgin-smoke OK 127, red on v59.

CREATE OR REPLACE FUNCTION stewards.render_stage_input(p_work_item_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_wi       stewards.work_items%ROWTYPE;
    v_stage    jsonb;
    v_template text;
    v_rendered text;
    v_match    text[];
    v_path     text;
    v_value    text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'render_stage_input: work_item % not found', p_work_item_id;
    END IF;

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION
            'render_stage_input: stage % not found in pipeline %',
            v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    v_template := v_stage->>'input_template';
    IF v_template IS NULL THEN
        RETURN NULL;  -- caller falls back
    END IF;

    v_rendered := v_template;
    -- Walk every distinct {{...}} match.
    FOR v_match IN
        SELECT regexp_matches(v_template, '\{\{\s*([^}]+?)\s*\}\}', 'g')
    LOOP
        v_path := v_match[1];
        v_value := stewards.resolve_template_path(
            v_wi.input, v_wi.stage_results, v_path);
        -- Replace every literal {{<path>}} occurrence (with surrounding
        -- whitespace tolerance via a regex_replace). The value is a
        -- replacement string, where a backslash is an escape: double them.
        v_rendered := regexp_replace(
            v_rendered,
            '\{\{\s*' || regexp_replace(v_path, '([\\.()|*+?\[\]{}^$])', '\\\1', 'g') || '\s*\}\}',
            replace(v_value, E'\\', E'\\\\'),
            'g'
        );
    END LOOP;

    RETURN v_rendered;
END;
$func$;

COMMENT ON FUNCTION stewards.render_stage_input(uuid) IS
'Render the current stage''s input_template against work_item state. Returns NULL if the stage has no template (caller falls back). Input values are carried verbatim, backslashes included (v60).';
