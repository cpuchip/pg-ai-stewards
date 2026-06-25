-- 53-explore-repos.sql — let the chat explore a PUBLIC repo (RC-1).
--
-- Michael's ask (2026-06-24): "do research and build off of public repos …
-- no db embeddings is good for that." The explore-in-sandbox machinery already
-- exists — research_codebase clones a repo into a read-only sandbox and
-- greps/reads it (no write/exec/git), returning Summary / Findings / Citations
-- with file:line — and the public-repo CLONE lane is now open bridge-side
-- (cmd/coder-mcp/sandbox: cloneMode → "anon", anonymous clone from an allowed
-- public host, self-enforcing public-only). The remaining gap was the GRANT:
-- research_codebase was never granted to the work-item-chat agent, so the chat
-- couldn't reach it. This file closes that gap.
--
-- NOTE: nothing here embeds repo content into the docs pool. Exploration stays
-- in the sandbox (read it where it lives), per the ask. A dropped CODE archive
-- routing to this same path, and async corpus import for document folders, are
-- the follow-on RC-2 / RC-3.

-- ── grant research_codebase to the work-item-chat agent ──────────────
-- Read-only allow (longest-glob-wins, so this specific allow beats the agent's
-- deny '*' base). research_codebase is the read-only research wrapper: it spawns
-- the cheap subagent-research-codebase pipeline, which clones into a sandbox and
-- answers grounded in the repo. The /explore slash command in the chat UI frames
-- the turn so the agent calls this with the repo URL + the user's question.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'research_codebase', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;
