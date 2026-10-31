-- =====================================================================
-- v77: messages.tokens_prompt, the whole prompt a call billed.
-- =====================================================================
-- On the Anthropic provider, messages.tokens_in holds only the uncached share of the prompt: parse_anthropic_sse
-- maps usage.input_tokens to prompt_tokens, and Anthropic's input_tokens leaves out cache_read_input_tokens and
-- cache_creation_input_tokens. On a session that is mostly cache hits tokens_in reads 2 to 4 while the prompt is
-- 100K or more (one instance, 16 calls: tokens_in 4, then 2; the same calls' cost_events grew from 19,746 to
-- 141,687). Anything that reads tokens_in as prompt size is blind there: a context check never fires, and session
-- totals under-read by the cached share. (#27)
--
-- tokens_in keeps its meaning, because the cost path prices it as the uncached share beside the cache shares at
-- their own rates; making it the full sum would charge the cache twice. The whole prompt gets its own column:
--   messages.tokens_prompt   Anthropic: input + cache_creation + cache_read (summed where the response is
--                            parsed, the only place the format is known); every other format: prompt_tokens,
--                            which already counts cached tokens. NULL where the provider reported no usage, and
--                            on rows written before v77 (unknown, never 0).
--   result.tokens_prompt     the same figure on the chat row's work_queue result, beside tokens_in.
--   session_status           gains total_tokens_prompt: sum(coalesce(tokens_prompt, tokens_in)).
-- A gateway that passes Anthropic's cache fields through beside an OpenAI prompt_tokens is not summed: whether
-- its prompt_tokens already counts them is the gateway's to say, so tokens_prompt is its prompt_tokens.
-- Oracle: the bgworker tokens_prompt_tests (Rust), and virgin-smoke OK 144. Idempotent.
-- =====================================================================

ALTER TABLE stewards.messages ADD COLUMN IF NOT EXISTS tokens_prompt int;

COMMENT ON COLUMN stewards.messages.tokens_prompt IS
'v77: the whole prompt the provider billed for this turn, every share summed (Anthropic: input + cache_creation + cache_read; other formats: prompt_tokens, which already counts cached tokens; a gateway passing Anthropic cache fields beside prompt_tokens is taken at its prompt_tokens). NULL when the provider reported no usage or the row predates v77. tokens_in stays the uncached share the cost path prices.';

-- session_status (schema.rs) with total_tokens_prompt appended; every other column as before
CREATE OR REPLACE VIEW stewards.session_status AS
SELECT
    s.id AS session_id,
    s.kind,
    s.label,
    -- Latest assistant message in the session
    (SELECT m.finish_reason FROM stewards.messages m
     WHERE m.session_id = s.id AND m.role = 'assistant'
     ORDER BY m.id DESC LIMIT 1) AS last_finish_reason,
    (SELECT m.created_at FROM stewards.messages m
     WHERE m.session_id = s.id AND m.role = 'assistant'
     ORDER BY m.id DESC LIMIT 1) AS last_assistant_at,
    -- Latest chat work_queue row's loop_stop_reason (e.g.
    -- 'steps_exhausted' or 'truncated_tool_calls')
    (SELECT (w.result->>'loop_stop_reason') FROM stewards.work_queue w
     WHERE w.kind = 'chat'
       AND w.payload->>'session_id' = s.id
     ORDER BY w.id DESC LIMIT 1) AS last_loop_stop_reason,
    -- Anything pending or in_progress for this session?
    (SELECT count(*)::int FROM stewards.work_queue w
     WHERE w.payload->>'session_id' = s.id
       AND w.status IN ('pending', 'in_progress')) AS pending_work,
    -- Anything errored?
    (SELECT count(*)::int FROM stewards.work_queue w
     WHERE w.payload->>'session_id' = s.id
       AND w.status = 'error') AS errored_work,
    -- Token + cost rollup across all assistant turns
    (SELECT coalesce(sum(m.tokens_in), 0)::bigint
     FROM stewards.messages m
     WHERE m.session_id = s.id) AS total_tokens_in,
    (SELECT coalesce(sum(m.tokens_out + coalesce(m.reasoning_tokens, 0)), 0)::bigint
     FROM stewards.messages m
     WHERE m.session_id = s.id) AS total_billable_out,
    s.created_at,
    -- v77: the whole prompt across the session's turns; a row from before v77 (or a provider that reported no
    -- usage split) counts its tokens_in
    (SELECT coalesce(sum(coalesce(m.tokens_prompt, m.tokens_in)), 0)::bigint
     FROM stewards.messages m
     WHERE m.session_id = s.id) AS total_tokens_prompt
FROM stewards.sessions s;
