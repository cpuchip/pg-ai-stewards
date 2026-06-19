-- =====================================================================
-- 36-judge-local-routing.sql — route the background JUDGES to a local model.
-- =====================================================================
-- Three background judges dispatch chats DIRECTLY into work_queue (bypassing
-- work_item_dispatch_stage, so they get no alias resolution): the engram-extractor
-- (15a — runs on every assistant message), judge-brief (16/15b — compiles a brief
-- from an oversized fetch), and watchman-consolidator (03). All historically
-- hardcode provider 'opencode_go'. On a rate-limited subscription that floods the
-- provider with 429s (a 24h sample showed 217 such failures) — which means the
-- context engine's engram extraction and the watchman are effectively NOT RUNNING,
-- and a file_private intent's engrams would have gone to a train-on-data provider.
--
-- Rather than edit the four dispatch sites across three consolidated files (clobber
-- risk), this is ONE BEFORE-INSERT trigger on work_queue: when judge_dispatch_local
-- is on, a chat dispatch for one of the named judge families is repointed to the
-- configured local provider+model. Default OFF + opencode_go/deepseek-v4-flash, so a
-- public install is unchanged; the workspace overlay turns it on and sets a local
-- model. Local (flexllama) is no-train, so this is also SAFER for private intents.
--
-- Default local model = nemotron-4b: it has its OWN GPU lane (separate from the
-- gemma 'ingest' and qwen 'reason' slots the digesters use), so high-frequency
-- engram extraction does not contend with the digester pipeline; it is fast; and the
-- engram completion parser is forgiving of JSON shape (accepts items/engrams/array).
-- Bump judge_dispatch_model to gemma-12b or qwen3.6-27b if extraction quality matters.
-- =====================================================================

SELECT stewards.config_set('judge_dispatch_local', 'false'::jsonb,
  '36: when true, the background judges (engram-extractor/judge-brief/watchman-consolidator) dispatch to judge_dispatch_provider/model instead of their hardcoded opencode_go. Overlay turns this on for a local rig.');
SELECT stewards.config_set('judge_dispatch_provider', to_jsonb('opencode_go'::text),
  '36: provider for the background judges when judge_dispatch_local. Public default opencode_go; a local rig sets flexllama.');
SELECT stewards.config_set('judge_dispatch_model', to_jsonb('deepseek-v4-flash'::text),
  '36: model for the background judges when judge_dispatch_local. Public default deepseek-v4-flash; a local rig sets e.g. nemotron-4b (its own GPU lane, fast, forgiving JSON parse).');

-- the named judge families (the direct-dispatch ones that bypass alias resolution)
CREATE OR REPLACE FUNCTION stewards.reroute_judge_to_local()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_family text := NEW.payload ->> 'agent_family';
    v_prov   text;
    v_model  text;
BEGIN
    IF NEW.kind <> 'chat'
       OR v_family IS NULL
       OR v_family NOT IN ('engram-extractor','judge-brief','watchman-consolidator')
       OR stewards.config_get_text('judge_dispatch_local','false') <> 'true' THEN
        RETURN NEW;
    END IF;
    v_prov  := stewards.config_get_text('judge_dispatch_provider','opencode_go');
    v_model := stewards.config_get_text('judge_dispatch_model','deepseek-v4-flash');
    NEW.provider := v_prov;
    -- requested_model is for substitution logging; body.model is what the bridge
    -- actually dispatches to the provider — set BOTH (the judge dispatchers put the
    -- model in payload.body.model).
    NEW.payload  := jsonb_set(NEW.payload, '{requested_model}', to_jsonb(v_model));
    IF NEW.payload ? 'body' THEN
        NEW.payload := jsonb_set(NEW.payload, '{body,model}', to_jsonb(v_model));
    END IF;
    RETURN NEW;
END;
$fn$;
COMMENT ON FUNCTION stewards.reroute_judge_to_local() IS
'36: BEFORE-INSERT on work_queue — repoints a background-judge chat dispatch to the configured local provider/model when judge_dispatch_local is on. Single choke point for the 3 direct-dispatch judges (no edit to 15a/16/03).';

DROP TRIGGER IF EXISTS work_queue_reroute_judge_to_local ON stewards.work_queue;
CREATE TRIGGER work_queue_reroute_judge_to_local
    BEFORE INSERT ON stewards.work_queue
    FOR EACH ROW EXECUTE FUNCTION stewards.reroute_judge_to_local();

-- =====================================================================
-- End of 36-judge-local-routing.sql
-- =====================================================================
