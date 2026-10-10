-- =====================================================================
-- v64-stage-images.sql: a stage can show the model images.
--
-- A work item whose input carries "images" (a JSON array of http(s) URLs or
-- base64 data: URIs) has them attached to its stage prompt: on every chat
-- enqueue for one of the item's sessions, the first user message becomes the
-- OpenAI content-part form, [{type: text}, {type: image_url, image_url: {url}}
-- ...]. compose_messages is untouched; the attach is a BEFORE INSERT trigger on
-- work_queue, like v62's budget log, so every round of a tool loop resends the
-- images with the history (the API is stateless) and the queue row stays
-- inspectable (it holds the URLs, not the bytes).
--
-- OpenAI-format providers take image_url parts as they are. The anthropic
-- translator (bgworker.rs, same release) turns each part into an Anthropic
-- image block and, before sending, downloads URL images and inlines them as
-- base64: Anthropic's own fetch timed out on archive.org page images
-- (2026-10-10, "The request timed out while trying to download the file"),
-- while the same page sent as base64 was read correctly. That download is
-- fenced in the worker (public addresses only, every redirect hop rechecked, a
-- bounded read, a short timeout); this trigger caps a stage at 8 images.
--
-- A stage that sends images needs a model that reads them; this file does not
-- check model capability.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.attach_stage_images()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_images jsonb;
    v_msgs   jsonb;
    v_parts  jsonb;
    v_url    text;
    v_i      int;
BEGIN
    IF NEW.kind IS DISTINCT FROM 'chat' OR jsonb_typeof(NEW.payload #> '{body,messages}') IS DISTINCT FROM 'array' THEN
        RETURN NEW;
    END IF;
    SELECT w.input -> 'images' INTO v_images
      FROM stewards.work_items w
     WHERE NEW.payload ->> 'session_id' = ANY (w.session_ids)
     ORDER BY w.created_at DESC
     LIMIT 1;
    IF jsonb_typeof(v_images) IS DISTINCT FROM 'array' OR jsonb_array_length(v_images) = 0 THEN
        RETURN NEW;
    END IF;
    -- the worker downloads URL images inside a dispatcher thread; bgworker.rs MAX_IMAGES_PER_MESSAGE
    IF jsonb_array_length(v_images) > 8 THEN
        RAISE EXCEPTION 'attach_stage_images: session % lists % images; a stage may show at most 8',
            NEW.payload ->> 'session_id', jsonb_array_length(v_images)
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_parts := '[]'::jsonb;
    FOR v_url IN SELECT CASE WHEN jsonb_typeof(x) = 'string' THEN x #>> '{}' ELSE x ->> 'url' END
                   FROM jsonb_array_elements(v_images) x
    LOOP
        IF v_url IS NULL OR v_url !~ '^(https?://|data:image/[a-z0-9.+-]+;base64,)' THEN
            RAISE EXCEPTION 'attach_stage_images: session % lists an image that is neither an http(s) URL nor a base64 data:image URI: %',
                NEW.payload ->> 'session_id', left(coalesce(v_url, 'null'), 80)
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
        v_parts := v_parts || jsonb_build_array(jsonb_build_object('type', 'image_url', 'image_url', jsonb_build_object('url', v_url)));
    END LOOP;

    v_msgs := NEW.payload #> '{body,messages}';
    FOR v_i IN 0 .. jsonb_array_length(v_msgs) - 1 LOOP
        IF v_msgs -> v_i ->> 'role' = 'user' THEN
            IF jsonb_typeof(v_msgs -> v_i -> 'content') = 'string' THEN
                NEW.payload := jsonb_set(NEW.payload, ARRAY['body', 'messages', v_i::text, 'content'],
                    jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_msgs -> v_i ->> 'content')) || v_parts);
            END IF;
            EXIT;  -- the stage's prompt is the first user message; later turns are the conversation
        END IF;
    END LOOP;
    RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION stewards.attach_stage_images() IS
'v64: BEFORE INSERT on work_queue. For a chat whose session belongs to a work item with input.images, the
first user message becomes [text part, image_url part per image]. Images are http(s) URLs or base64
data:image URIs; anything else fails the enqueue by name. Content already in parts form is left alone.';

DROP TRIGGER IF EXISTS work_queue_attach_stage_images ON stewards.work_queue;
CREATE TRIGGER work_queue_attach_stage_images
    BEFORE INSERT ON stewards.work_queue
    FOR EACH ROW EXECUTE FUNCTION stewards.attach_stage_images();
