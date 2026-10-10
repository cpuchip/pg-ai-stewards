-- =====================================================================
-- v65-agent-anthropic-options.sql: an agent can set how much an Anthropic
-- model thinks.
--
-- The Claude 5.5 models think by default (adaptive thinking), and thinking is
-- billed as output. On one instance's book work, thinking was 40-86% of each
-- agent's billed output tokens (2026-10-10). The controls are request fields:
-- output_config.effort (low | medium | high | xhigh | max; it shapes all output,
-- thinking included) and thinking (Haiku 5.5 accepts {"type": "disabled"} at
-- high effort or below; Sonnet 5.5's floor is {"type": "between_tools"}; Opus
-- 5.5 cannot turn thinking off). A model that rejects an option answers 400,
-- and the row fails with the provider's message (send_with_retry does not retry
-- a 400); nothing is stripped silently.
--
-- agents.anthropic_options holds those two keys and nothing else (a CHECK), so
-- it cannot override the model, max_tokens or the messages. A BEFORE INSERT
-- trigger on work_queue copies the resolved agent's options into
-- payload.body.anthropic_options for every chat, the pattern v64 set;
-- dry_run_chat is untouched. The anthropic translator copies the two keys into
-- the request; the OpenAI path drops the field. The effective options and the
-- reported thinking tokens go into cost_events.notes.
-- =====================================================================

ALTER TABLE stewards.agents ADD COLUMN IF NOT EXISTS anthropic_options jsonb;

ALTER TABLE stewards.agents DROP CONSTRAINT IF EXISTS agents_anthropic_options_keys;
ALTER TABLE stewards.agents ADD CONSTRAINT agents_anthropic_options_keys CHECK (
    anthropic_options IS NULL
    OR (jsonb_typeof(anthropic_options) = 'object'
        AND anthropic_options - 'output_config' - 'thinking' = '{}'::jsonb));

COMMENT ON COLUMN stewards.agents.anthropic_options IS
'v65: request fields for Anthropic models, copied into every chat this agent makes. Only output_config
(e.g. {"effort": "low"}) and thinking (e.g. {"type": "disabled"}) are allowed. NULL = the model''s defaults
(medium effort on Opus/Haiku 5.5, high on Sonnet 5.5). A model that rejects a value fails the row with 400.';

CREATE OR REPLACE FUNCTION stewards.attach_agent_anthropic_options()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_agent stewards.agents;
BEGIN
    IF NEW.kind IS DISTINCT FROM 'chat' OR NEW.payload ->> 'agent_family' IS NULL
       OR jsonb_typeof(NEW.payload -> 'body') IS DISTINCT FROM 'object' THEN
        RETURN NEW;
    END IF;
    v_agent := stewards.resolve_agent(NEW.payload ->> 'agent_family', NEW.payload #>> '{body,model}');
    IF v_agent.anthropic_options IS NOT NULL THEN
        NEW.payload := jsonb_set(NEW.payload, '{body,anthropic_options}', v_agent.anthropic_options);
    END IF;
    RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION stewards.attach_agent_anthropic_options() IS
'v65: BEFORE INSERT on work_queue. For a chat, the agent resolve_agent picks for (agent_family, body.model)
lends its anthropic_options to payload.body.anthropic_options. Agents without options, and non-chat rows,
are untouched.';

DROP TRIGGER IF EXISTS work_queue_attach_anthropic_options ON stewards.work_queue;
CREATE TRIGGER work_queue_attach_anthropic_options
    BEFORE INSERT ON stewards.work_queue
    FOR EACH ROW EXECUTE FUNCTION stewards.attach_agent_anthropic_options();
