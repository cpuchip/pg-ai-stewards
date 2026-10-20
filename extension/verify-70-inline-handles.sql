-- v70 verification: the [ctx:handle] label is off the message by default.
--
-- The same block as virgin-smoke OK 137, runnable against a LIVE record: it
-- creates its own agent family and session, composes under each
-- context_inline_handles setting, and rolls everything back (the config
-- value is restored to 'none' inside the block and the transaction is
-- rolled back regardless). Run with:
--   docker exec -i <pg> psql -U stewards -d stewards < extension/verify-70-inline-handles.sql
-- Exit 0 and the OK 137 notice = the fix is live on that record.

\set ON_ERROR_STOP 1

BEGIN;

-- OK 137 (v70): the [ctx:handle] label is off the message by default. An
-- agent family with context tools on composes a session whose older
-- assistant and tool rows are addressable: none of them starts with a label,
-- and the tail notice lists each foldable handle with its role and how the
-- message begins. context_inline_handles = 'all' restores the pre-v70 render
-- (the old assistant row is labeled; the tail is not); 'non-assistant' labels
-- the old tool row and never the assistant. The defect this pins: a model on
-- a long session read its own labeled turns and answered with only a label.
DO $vs137$
DECLARE
    v_msgs    jsonb;
    v_notice  text;
    v_asst    text;
    v_tool    text;
    v_tail    text;
    v_ah      text;
    v_th      text;
    v_n       int;
    i         int;
BEGIN
    INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, context_tools_enabled)
    VALUES ('verify70-ctx', '*', 'virgin smoke: inline handles off', 'primary', 'You are a smoke agent.', NULL, true);
    INSERT INTO stewards.sessions (id, kind) VALUES ('verify70-ctx-sess', 'agent');
    -- nine rows older than the 8-message tail: three user questions, three long
    -- assistant answers, three long tool results (long enough to be foldable)
    FOR i IN 1..3 LOOP
        INSERT INTO stewards.messages (session_id, role, content, created_at)
        VALUES ('verify70-ctx-sess', 'user', 'question ' || i, now() - (100 - i * 3) * interval '1 minute');
        INSERT INTO stewards.messages (session_id, role, content, created_at)
        VALUES ('verify70-ctx-sess', 'assistant',
                repeat('An answer the assistant gave earlier in this session, long enough to be foldable. ', 4) || '#' || i,
                now() - (99 - i * 3) * interval '1 minute');
        INSERT INTO stewards.messages (session_id, role, content, tool_call_id, created_at)
        VALUES ('verify70-ctx-sess', 'tool',
                repeat('A tool result from earlier in this session, long enough to be foldable. ', 4) || '#' || i,
                'call-' || i, now() - (98 - i * 3) * interval '1 minute');
    END LOOP;
    -- the 8-message tail, rendered raw whatever the setting
    FOR i IN 1..8 LOOP
        INSERT INTO stewards.messages (session_id, role, content, created_at)
        VALUES ('verify70-ctx-sess', CASE WHEN i % 2 = 1 THEN 'user' ELSE 'assistant' END, 'tail ' || i,
                now() - (20 - i) * interval '1 minute');
    END LOOP;
    SELECT stewards.context_handle(id) INTO v_ah FROM stewards.messages
     WHERE session_id = 'verify70-ctx-sess' AND role = 'assistant' AND content LIKE '%#1';
    SELECT stewards.context_handle(id) INTO v_th FROM stewards.messages
     WHERE session_id = 'verify70-ctx-sess' AND role = 'tool' AND content LIKE '%#1';

    -- default: no label on any history row; the notice names the handles
    v_msgs := stewards.compose_messages('verify70-ctx', 'reason', 'verify70-ctx-sess');
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_msgs) e
     WHERE e ->> 'role' IN ('user', 'assistant', 'tool') AND e ->> 'content' LIKE '[ctx:%';
    ASSERT v_n = 0, format('137: with inline handles off no history row starts with a label; %s did', v_n);
    ASSERT stewards.config_get_text('context_inline_handles') = 'none', '137: the seeded default is none';
    SELECT e ->> 'content' INTO v_notice FROM jsonb_array_elements(v_msgs) e
     WHERE e ->> 'content' LIKE '[STEWARD NOTICE%' LIMIT 1;
    ASSERT v_notice LIKE '%Foldable now%', '137: the tail notice carries the foldable list: ' || coalesce(v_notice, '<none>');
    ASSERT v_notice LIKE '%[ctx:' || v_ah || '] assistant %"An answer the assistant gave earlier%',
        '137: the notice lists the assistant handle with its role and an excerpt: ' || v_notice;
    ASSERT v_notice LIKE '%[ctx:' || v_th || '] tool %"A tool result from earlier%',
        '137: the notice lists the tool handle with its role and an excerpt: ' || v_notice;

    -- all: the pre-v70 render; the old assistant row is labeled, the tail is not
    UPDATE stewards.config SET value = '"all"'::jsonb WHERE key = 'context_inline_handles';
    v_msgs := stewards.compose_messages('verify70-ctx', 'reason', 'verify70-ctx-sess');
    SELECT e ->> 'content' INTO v_asst FROM jsonb_array_elements(v_msgs) e WHERE e ->> 'role' = 'assistant' AND e ->> 'content' LIKE '%#1';
    SELECT e ->> 'content' INTO v_tool FROM jsonb_array_elements(v_msgs) e WHERE e ->> 'role' = 'tool' AND e ->> 'content' LIKE '%#1';
    SELECT e ->> 'content' INTO v_tail FROM jsonb_array_elements(v_msgs) e WHERE e ->> 'content' = 'tail 8';
    ASSERT v_asst LIKE '[ctx:' || v_ah || '] %', '137: all labels the old assistant row; got ' || left(v_asst, 40);
    ASSERT v_tool LIKE '[ctx:' || v_th || '] %', '137: all labels the old tool row; got ' || left(v_tool, 40);
    ASSERT v_tail = 'tail 8', '137: the tail is never labeled; got ' || coalesce(v_tail, '<missing>');

    -- non-assistant: the tool row is labeled, the assistant row is not
    UPDATE stewards.config SET value = '"non-assistant"'::jsonb WHERE key = 'context_inline_handles';
    v_msgs := stewards.compose_messages('verify70-ctx', 'reason', 'verify70-ctx-sess');
    SELECT e ->> 'content' INTO v_asst FROM jsonb_array_elements(v_msgs) e WHERE e ->> 'role' = 'assistant' AND e ->> 'content' LIKE '%#1';
    SELECT e ->> 'content' INTO v_tool FROM jsonb_array_elements(v_msgs) e WHERE e ->> 'role' = 'tool' AND e ->> 'content' LIKE '%#1';
    ASSERT v_asst NOT LIKE '[ctx:%', '137: non-assistant leaves the assistant row unlabeled; got ' || left(v_asst, 40);
    ASSERT v_tool LIKE '[ctx:' || v_th || '] %', '137: non-assistant labels the old tool row; got ' || left(v_tool, 40);

    UPDATE stewards.config SET value = '"none"'::jsonb WHERE key = 'context_inline_handles';
    DELETE FROM stewards.messages WHERE session_id = 'verify70-ctx-sess';
    DELETE FROM stewards.compose_budget_log WHERE session_id = 'verify70-ctx-sess';
    DELETE FROM stewards.sessions WHERE id = 'verify70-ctx-sess';
    DELETE FROM stewards.agents WHERE family = 'verify70-ctx';
    RAISE NOTICE 'OK 137: the [ctx:handle] label is off the message by default and the notice lists each handle with its role and an excerpt; all restores the old render; non-assistant labels tool rows only (v70)';
END
$vs137$;

ROLLBACK;
