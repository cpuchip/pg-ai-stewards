-- =====================================================================
-- 20-coder.sql — the coder wave: write / PR / deploy / research code in a
-- hardened sandbox (P2; the coder-mcp / stewards-ui wave after hardening review)
-- =====================================================================
-- The substrate's code capability: a `coder` MCP server exposes a sandboxed
-- tool surface (start/stop/write/read/edit/apply_patch/shell/glob/grep/lsp +
-- git commit/push/open_pr + deploy), and the code-write / code-pr / code-deploy
-- pipelines drive a write→build→test→GREEN loop (real exit codes = ground
-- truth), a clone→plan→plan_review→implement→verify→review→pr loop that lands a
-- DRAFT PR, and an always-escalate deploy. research_codebase is the read-only
-- agentic code-search tool.
--
-- ★ INERT until the Go binary lands: the `coder` MCP server points at
-- /usr/local/bin/coder-mcp, which is NOT yet built into the image — that Go
-- extraction + its hardening review (sandbox isolation, the bridge-side GitHub
-- token, the repo allow-list, resource caps) is the public-ship Hinge and a
-- separate pass. With no binary, the bridge can't catalog the coder_* tools, so
-- the grants below are dormant. Authoring the SQL cannot expose a working coder.
--
-- Consolidated (clean-room: the FINAL state). Sources: cc2 (server + dev grants),
-- cc3 (code-write), cc4 (lsp grant), cc5 (code-deploy + the always-escalate
-- Hinge), cc6 (sandbox list/reap grants), cv2-2 (git env + commit/push/open_pr
-- grants), cv3+cv5+cv6+cv8/9+cv11 (code-pr final, 7 stages), cv12 (stamp +
-- feedback defaults), r10+r12 (research_codebase). The multiply-evolved code-pr
-- pipeline is taken from its live FINAL (l13 lesson) and genericized.
--
-- requires create_models (19): the dispatch-final graft (§9) is the 19 r3 body +
-- the cv7/cv10 code-pr review model-immunity branch; work_item_advance (§8) is
-- the 08 body + the cv6/cv11 code-pr loop-backs.
--
-- HARDENING (the SQL surface): the `dev` agent is GENERIC (the workspace's 17K
-- personal dev/debug prompts stay in the overlay; a runtime seed can override
-- this one). Dangerous grants are scoped to `dev`; research_codebase's sub-agent
-- is read-only by construction (every write/exec/git/deploy/recurse tool denied).
-- code-deploy's `prepare` stays auto_advance=false (the always-escalate Hinge);
-- code-pr surfaces awaiting_review past the revise cap (never auto-PRs a
-- thrice-deficient change). No secret is stored — the GitHub token is a
-- bridge-resolved `$env:GITHUB_TOKEN` reference, never the value, never in the
-- sandbox. Example repos genericized (your-org/your-repo).
--
-- OVERLAY (not core): minimax-m3 (cv4) is a model seed → the workspace overlay
-- (B5/19 rule); the code-pr critic defaults to glm-5.1 (a tool-capable,
-- non-qwen provider — qwen3.7-max 401s on oa-compat and 400s on Alibaba when
-- tools are on) and dev to kimi-k2.6 (both name-only strings; unrowed models
-- default usable).
-- =====================================================================


-- =====================================================================
-- §1 — the generic `dev` coder agent (clean-room).
-- =====================================================================
-- The coder pipelines dispatch to agent_family='dev'. This is a clean, generic
-- engineering agent; an operator's overlay/runtime seed can override the prompt
-- with their own (the workspace's 17K dev/debug prompts live downstream).
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps, kind)
VALUES
('dev', '*',
 'Coder agent: writes, builds, tests, and ships code in an isolated sandbox via the coder tools. Ground truth is a passing build/test, not a self-report.',
 'primary',
 $PROMPT$You are a software engineer working inside an isolated, ephemeral sandbox through the coder tools. You write, build, test, and (when asked) ship code.

Operating principles:
- Ground truth is the build and the tests. A change is done when the build+test command exits 0 — that is a fact, not a judgment call. Never report success you have not observed.
- Read before you change. Inspect the existing files and match the project's conventions, language, and build tooling before writing.
- Own the code within the stated task. Keep it sound — fix the obvious adjacent breakage you cause — but do not expand scope beyond what was asked.
- Iterate honestly. When a build or test fails, read the real output, fix the cause, and run again. Do not stop at "should work."
- The sandbox is disposable; the live system is not. You only touch the sandbox. Commits are local; pushing and opening a PR happen through the coder tools (the credential never enters your sandbox). A human reviews and merges — that merge is the Hinge.
- If you cannot make it pass, say so plainly with the real failing output. An honest "blocked, here is why" beats a false green.$PROMPT$,
 0.2, 30, 'code')
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description,
       mode        = EXCLUDED.mode,
       prompt      = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature,
       steps       = EXCLUDED.steps,
       kind        = EXCLUDED.kind,
       active      = true;


-- =====================================================================
-- §2-§4 — coder MCP server + the code pipelines + research_codebase agent
-- + grants (live finals, genericized). See the dump below.
-- =====================================================================
-- pipelines (code-pr/code-write/code-deploy) — live finals
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, file_destination_template, file_content_jsonpath, maturity_ladder) VALUES ('code-deploy','',E'[{"name": "prepare", "next": "deploy", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": false, "input_template": "Deploy task: {{input.binding_question}}\\n\\nSandbox (build+test already passed): {{input.sandbox}}\\n\\nPrepare this code for deployment — do NOT deploy yet:\\n1. Inspect the sandbox (coder_glob / coder_read) to see what was built.\\n2. If a build step is needed (e.g. `go build -o app .`), run it via coder_shell, sandbox=\\"{{input.sandbox}}\\".\\n3. Determine how to run it as a service: the run_command (from /work), the TCP port it listens on, and an HTTP health_path.\\n\\nReport the DEPLOY PLAN clearly and explicitly: the exact run_command, the port, and the health_path. A human reviews and ratifies this plan before the deploy runs — this is the Hinge; the deploy never fires on its own.", "tools_disabled": false}, {"name": "deploy", "next": null, "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Deploy task: {{input.binding_question}}\\n\\nSandbox: {{input.sandbox}}\\n\\nThe deploy plan (ratified by a human):\\n{{stage_results.prepare.output}}\\n\\nExecute the deploy now: call coder_deploy with sandbox=\\"{{input.sandbox}}\\" and the run_command, port, and health_path from the ratified plan. Report whether the service came up healthy, the healthcheck result, and the service log tail.", "tools_disabled": false}]'::jsonb,'f','t',NULL,NULL,'["raw", "planned", "verified"]'::jsonb) ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, description=EXCLUDED.description, sabbath_enabled=EXCLUDED.sabbath_enabled, atonement_enabled=EXCLUDED.atonement_enabled, file_destination_template=EXCLUDED.file_destination_template, file_content_jsonpath=EXCLUDED.file_content_jsonpath, maturity_ladder=EXCLUDED.maturity_ladder;
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, file_destination_template, file_content_jsonpath, maturity_ladder) VALUES ('code-pr','',E'[{"name": "clone", "next": "plan", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task on an existing repo: {{input.binding_question}}\\n\\nRepo: {{input.repo}}\\nYour sandbox id: {{input.sandbox}}\\n\\nClone the repo into your worktree and survey it — do NOT write code yet:\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\", repo=\\"{{input.repo}}\\", branch=\\"{{input.base_branch}}\\" (clone this base branch so your work builds on the prior chained items). The substrate clones the allow-listed repo at that base branch into your worktree and mounts it at /work; the GitHub token never enters your sandbox.\\n2. Survey it so the next stage can plan against the REAL code: coder_glob to see the layout, then coder_read the README / go.mod / package.json to identify the language, build tool, and conventions.\\n\\nReport a concise map: the stack, the key directories/files, the build+test command the repo uses, and where the task''s change most likely belongs.", "tools_disabled": false}, {"name": "plan", "next": "plan_review", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nRepo: {{input.repo}}\\n\\nRepo survey from the clone stage:\\n{{stage_results.clone.output}}\\n\\nProduce a concise implementation plan, NOT code:\\n  - The files to create or change (paths relative to the repo root /work).\\n  - The approach in a few sentences, consistent with the repo''s existing conventions.\\n  - The exact build + test command that proves it works — the one this repo uses (e.g. `go build ./... && go test ./...`, or `npm ci && npm test`). This command is the ground-truth gate.\\n\\nKeep it tight. The next stage implements against this plan in the cloned repo.\\n\\n## PLAN REVIEW FEEDBACK (address fully if present)\\nA plan reviewer checked a prior version of this plan. If the section below is non-empty, revise the plan to address EVERY point.\\\\n{{input.plan_feedback}}", "tools_disabled": true}, {"name": "plan_review", "next": "implement", "model": "glm-5.1", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "You are the PLAN REVIEWER (critic) — a fresh, strict architect reviewing an implementation plan BEFORE any code is written. A different model wrote the plan; judge it against the task, not the planner.\\n\\nTask (binding question): {{input.binding_question}}\\n\\nACCEPTANCE CRITERIA the final code must satisfy:\\n{{input.acceptance_criteria}}\\n\\nThe plan to review:\\n{{stage_results.plan.output}}\\n\\nJudge whether this plan, IF implemented faithfully, would satisfy every acceptance criterion and is sound, idiomatic, and right-sized (not over- or under-engineered). Look specifically for: scope the task implies but the plan omits (e.g. room-scoping), criteria with no corresponding plan element, a missing or vague test strategy, and unnecessary complexity.\\n\\nReturn EXACTLY one of:\\n  (a) First line \\"PLAN: approved\\" — only if the plan would meet every criterion and is sound — then one short line per criterion noting how the plan covers it.\\n  (b) First line \\"PLAN: revise\\" — if anything is missing, unsound, or wrong-sized — then a NUMBERED list of the specific changes the planner must make. The planner gets this verbatim and must address each point.", "tools_disabled": true}, {"name": "implement", "next": "verify", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nImplementation plan:\\n{{stage_results.plan.output}}\\n\\nYour sandbox id (the repo is already cloned + mounted at /work): {{input.sandbox}}\\n\\nImplement it in the cloned repo using the coder tools:\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\" — NO repo arg. This reuses your existing worktree with the clone. Do NOT pass repo= here; that would re-clone and wipe your work.\\n2. Read the relevant existing files (coder_read / coder_grep) before changing them — match the repo''s conventions.\\n3. Write/edit code with coder_write / coder_edit (paths relative to /work, the repo root).\\n4. Build + test with coder_shell, sandbox=\\"{{input.sandbox}}\\", running the build+test command from the plan.\\n5. ITERATE: if the build or tests fail, read the real output, fix the code, and run again. Do NOT stop until the build+test command exits 0 (green). The passing build+test is ground truth, not a judgment call.\\n\\nWhen green, report: what you changed, the files touched, and paste the final passing build+test output. Do NOT commit or push — the pr stage lands the work.\\n\\n## REVISION REQUESTED (address fully if present)\\nA reviewer checked a prior attempt against the plan and asked for these changes. If the section below is non-empty, you are on a revise cycle: address EVERY point before reporting green.\\\\n{{input.review_feedback}}", "tools_disabled": false}, {"name": "verify", "next": "review", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nThe implement stage reported:\\n{{stage_results.implement.output}}\\n\\nIndependently verify — do NOT trust the report above. In sandbox \\"{{input.sandbox}}\\" (your cloned repo at /work):\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\" (NO repo — reuse the worktree).\\n2. coder_shell, sandbox=\\"{{input.sandbox}}\\", run the build + test command yourself.\\n3. Inspect the REAL exit code and output.\\n\\nReturn EXACTLY one of:\\n  (a) A first line \\"REVIEW: passes\\" (only if the command exited 0), then the build/test output.\\n  (b) A first line \\"REVIEW: fail\\", then the failing output and a short note on what still needs fixing.", "tools_disabled": false}, {"name": "review", "next": "pr", "model": "glm-5.1", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "You are the REVIEWER (critic) for a code change — a fresh, strict set of eyes, a DIFFERENT model than the implementer. Judge the change against the plan, not the implementer''s self-report.\\n\\nTask (binding question): {{input.binding_question}}\\n\\nACCEPTANCE CRITERIA — the change must satisfy EVERY one:\\n{{input.acceptance_criteria}}\\n\\nThe change is implemented in sandbox \\"{{input.sandbox}}\\" (the cloned repo at /work) and built+tested green by verify. The implementer reported:\\n{{stage_results.implement.output}}\\n\\nInspect the ACTUAL change — do NOT trust the report:\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\" (reuse the worktree; no repo arg).\\n2. coder_shell, sandbox=\\"{{input.sandbox}}\\": run `git -c safe.directory=* diff {{input.base_branch}}...HEAD` and `git -c safe.directory=* log --oneline {{input.base_branch}}..HEAD` to see the real diff.\\n3. coder_read / coder_grep the changed files as needed; re-run the build+test command if a criterion needs it.\\n\\nJudge against EACH acceptance criterion AND the binding question. A criterion is met only if the actual code shows it — not because the report claims it. Watch specifically for: scope the plan implies but the code skipped (e.g. room-scoping), the actual handler/entrypoint being untested (a test that re-implements the logic inline does NOT count), and any criterion silently dropped.\\n\\nReturn EXACTLY one of:\\n  (a) First line \\"REVIEW: passes\\" — ONLY if every acceptance criterion is met — then one short line per criterion confirming how.\\n  (b) First line \\"REVIEW: revise\\" — if ANY criterion is unmet or the change diverges from the plan — then a NUMBERED list: each unmet criterion, what is wrong (cite the file/line), and the SPECIFIC fix the implementer must make. The implementer receives this verbatim and must fix exactly these points.", "tools_disabled": false}, {"name": "pr", "next": null, "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nRepo: {{input.repo}}\\nThe change is implemented + verified green in sandbox \\"{{input.sandbox}}\\" (your cloned repo worktree).\\n\\nImplement summary:\\n{{stage_results.implement.output}}\\n\\nLand the work as a reviewable DRAFT pull request. The substrate holds the GitHub token bridge-side — you commit LOCALLY (no token), and coder_push / coder_open_pr push + open the PR for you:\\n1. coder_commit with sandbox=\\"{{input.sandbox}}\\", a clear conventional-commit message describing the change, and branch=\\"agent/code-pr/{{input.sandbox}}\\".\\n2. coder_push with sandbox=\\"{{input.sandbox}}\\", branch=\\"agent/code-pr/{{input.sandbox}}\\".\\n3. coder_open_pr with sandbox=\\"{{input.sandbox}}\\", a descriptive title, a body that explains the change AND pastes the passing build+test output as evidence, base=\\"{{input.base_branch}}\\" (open the PR against the base branch, NOT main), and draft=true.\\n\\nReport the PR url. A human reviews and merges the PR — that merge is the Hinge. Open the draft and stop there; do NOT attempt to merge.", "max_tool_rounds_hard": 40, "tools_disabled": false}]'::jsonb,'f','t',NULL,NULL,'["raw", "researched", "planned", "executing", "verified"]'::jsonb) ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, description=EXCLUDED.description, sabbath_enabled=EXCLUDED.sabbath_enabled, atonement_enabled=EXCLUDED.atonement_enabled, file_destination_template=EXCLUDED.file_destination_template, file_content_jsonpath=EXCLUDED.file_content_jsonpath, maturity_ladder=EXCLUDED.maturity_ladder;
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, file_destination_template, file_content_jsonpath, maturity_ladder) VALUES ('code-write','',E'[{"name": "plan", "next": "implement", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task (binding question): {{input.binding_question}}\\n\\nProduce a concise implementation plan, NOT code:\\n  - The files to create or change (paths relative to the project root).\\n  - The approach in a few sentences.\\n  - The exact build + test command that will prove it works (e.g. `go build ./... && go test ./...`, or `npm ci && npm test`). This command is the ground-truth gate; choose it deliberately.\\n\\nKeep it tight. The next stage implements against this plan in a sandbox.", "tools_disabled": true}, {"name": "implement", "next": "verify", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nImplementation plan:\\n{{stage_results.plan.output}}\\n\\nYour sandbox id is: {{input.sandbox}}\\n\\nImplement it in the sandbox using the coder tools:\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\" (reuses the sandbox if it already exists).\\n2. Write the code with coder_write / coder_edit (paths are relative to /work, the project root).\\n3. Build and test with coder_shell, sandbox=\\"{{input.sandbox}}\\", running the build+test command from the plan.\\n4. ITERATE: if the build or tests fail, read the real output, fix the code, and run again. Do NOT stop until the build+test command exits 0 (green). The passing build+test is your done condition — it is ground truth, not a judgment call.\\n\\nWhen green, report: what you built, the files written, and paste the final passing build+test output.", "tools_disabled": false}, {"name": "verify", "next": null, "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nThe implement stage reported:\\n{{stage_results.implement.output}}\\n\\nIndependently verify — do NOT trust the report above. In sandbox \\"{{input.sandbox}}\\":\\n1. coder_shell, sandbox=\\"{{input.sandbox}}\\", run the build + test command yourself.\\n2. Inspect the REAL exit code and output.\\n\\nReturn EXACTLY one of:\\n  (a) A first line \\"REVIEW: passes\\" (only if the command exited 0), then the build/test output.\\n  (b) A first line \\"REVIEW: fail\\", then the failing output and a short note on what still needs fixing.", "tools_disabled": false}]'::jsonb,'f','t',NULL,NULL,'["raw", "planned", "executing", "verified"]'::jsonb) ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, description=EXCLUDED.description, sabbath_enabled=EXCLUDED.sabbath_enabled, atonement_enabled=EXCLUDED.atonement_enabled, file_destination_template=EXCLUDED.file_destination_template, file_content_jsonpath=EXCLUDED.file_content_jsonpath, maturity_ladder=EXCLUDED.maturity_ladder;

-- subagent-research-codebase pipeline
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, maturity_ladder, auto_materialize_on_verified, metadata) VALUES ('subagent-research-codebase','R10: single-stage agentic tool — deepseek-v4-flash researches a repo read-only and returns curated findings + citations.','[{"name": "research", "next": null, "model": "deepseek-v4-flash", "provider": "opencode_go", "agent_family": "subagent-research-codebase", "auto_advance": true, "input_template": "{{input.binding_question}}", "tools_disabled": false}]'::jsonb,'f','f','["raw", "verified"]'::jsonb,'f','{"shape": "agentic-tool", "wrapper": "research_codebase", "read_only": true}'::jsonb) ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, description=EXCLUDED.description, metadata=EXCLUDED.metadata;

-- stage_models

-- pipeline_stage_maturity

-- subagent-research-codebase agent (genericize cpuchip below)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps) VALUES ('subagent-research-codebase','*','Subagent for research_codebase. Explores a repo in a read-only coder sandbox and returns curated findings + file:line citations.','primary','You are a code-research subagent. Given a REPOSITORY and a QUESTION, explore the repository''s source and answer the question with curated findings and exact file:line citations. You are READ-ONLY — you never modify, run, commit, or deploy anything.

Your tools (use ONLY these):
- coder_sandbox_start  — clones + mounts the repo into a fresh sandbox FOR you. Pass repo as the EXACT repository reference given in the task — it will be a full clone URL such as https://github.com/your-org/your-repo. Pass it verbatim; do not shorten it to a bare name and do not change the org. The sandbox does the clone; you never run git yourself. Capture the returned sandbox id and pass it to every later tool call.
- coder_grep / coder_glob — find files and matches inside that sandbox (start here to locate the relevant code).
- coder_read — read the specific files/regions the grep surfaced.
- coder_lsp — optional: symbol/definition lookup for navigation.
- coder_sandbox_stop — stop the sandbox when you are done.

Method (be efficient — you have a bounded number of steps):
1. Call coder_sandbox_start with repo = the exact repository reference from the task (a full clone URL, e.g. https://github.com/your-org/your-repo). Use the returned sandbox id in every later call. If it reports the repo is not allow-listed, say so and stop — do NOT fall back to git clone.
2. grep/glob to locate the code that answers the question; read the precise regions.
3. Stop when you can answer with evidence — do NOT read the whole repo. Curate.
4. Stop the sandbox.

Output format (markdown ONLY — no preamble):
## Summary
A 2-4 sentence direct answer to the question.

## Findings
- Bulleted findings, each a concrete claim about how the code works.

## Citations
- `path/to/file.go:LINE` — what this location shows. One line per cited claim above.

## Confidence
high | medium | low — and one clause on why.

## Caveats
What you did NOT verify, or where the answer is incomplete.

Rules:
- EVERY claim in Findings must have a file:line citation. If you cannot cite it, do not claim it.
- If the repo or the answer cannot be found, say so plainly in Summary + set Confidence: low. Never invent file paths, line numbers, or behavior.
- Read-only: if you are ever tempted to write/edit/run, stop — that is out of scope.','0.2','16') ON CONFLICT (family, model_match) DO UPDATE SET description=EXCLUDED.description, mode=EXCLUDED.mode, prompt=EXCLUDED.prompt, temperature=EXCLUDED.temperature, steps=EXCLUDED.steps, active=true;


-- coder mcp_server (cc2+cv2-2; $env:GITHUB_TOKEN ref, no secret)
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled) VALUES ('coder','Substrate coding capability — write, build, test, and run code in an isolated, hardened, ephemeral sandbox (Go + Node/TS + Python + LSP). Tools: coder_sandbox_start / coder_sandbox_stop (lifecycle), coder_write / coder_read / coder_edit / coder_apply_patch (files), coder_shell (build/test/run — the ground-truth gate), coder_glob / coder_grep (search). Each tool takes a `sandbox` id (the work_item id). The coder never touches the live workspace.','stdio','/usr/local/bin/coder-mcp','{}'::text[],NULL,'{"GITHUB_TOKEN": "$$env:GITHUB_TOKEN"}'::jsonb,'t') ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, command=EXCLUDED.command, args=EXCLUDED.args, env=EXCLUDED.env, enabled=EXCLUDED.enabled;

-- dev coder_* grants + research-codebase read-only denies
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_apply_patch','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_commit','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_deploy','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_edit','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_glob','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_grep','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_lsp','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_open_pr','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_push','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_read','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_sandbox_list','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_sandbox_reap','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_sandbox_start','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_sandbox_stop','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_shell','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_write','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_apply_patch','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_commit','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_deploy','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_edit','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_open_pr','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_push','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_sandbox_list','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_sandbox_reap','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_shell','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_write','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','consult_subagent','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','deep_research','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','fetch_url','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','spawn_subagent','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','doc_*','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','web_search','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','work_item_*','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- =====================================================================
-- §5 — stage_models + pipeline_stage_maturity (the coder pipelines).
-- =====================================================================
INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('code-write',  'plan',        'kimi-k2.6',   'Implementation plan; tools off.'),
    ('code-write',  'implement',   'kimi-k2.6',   'Write + build/test loop in the sandbox; coder tools on.'),
    ('code-write',  'verify',      'kimi-k2.6',   'Independent build/test re-run; coder tools on.'),
    ('code-pr',     'clone',       'kimi-k2.6',   'Clone the allow-listed repo into the worktree + survey it.'),
    ('code-pr',     'plan',        'kimi-k2.6',   'Implementation plan grounded in the repo survey; tools off.'),
    ('code-pr',     'plan_review', 'glm-5.1',     'Plan critic (cv11): reviews the plan vs acceptance criteria before build; PLAN: approved -> implement, PLAN: revise -> loop back to plan (capped).'),
    ('code-pr',     'implement',   'kimi-k2.6',   'Write + build/test loop in the cloned repo; coder tools on. Escalate per-task for novel app code.'),
    ('code-pr',     'verify',      'kimi-k2.6',   'Independent build/test re-run in the cloned repo; coder tools on.'),
    ('code-pr',     'review',      'glm-5.1',     'Plan-conformance critic (cv6): a DIFFERENT strong model than the implementer. REVIEW: passes -> pr, REVIEW: revise -> loop back to implement (capped, then awaiting_review).'),
    ('code-pr',     'pr',          'kimi-k2.6',   'Commit-local + push + open DRAFT PR (coder_commit/push/open_pr).'),
    ('code-deploy', 'prepare',     'kimi-k2.6',   'Build artifact + propose run_command/port/health_path. THE HINGE: auto_advance=false.'),
    ('code-deploy', 'deploy',      'kimi-k2.6',   'Run the artifact in its sandbox sidecar + healthcheck (coder_deploy).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

-- plan_review + review are GATES — no maturity row (they must not change the high-water rung).
INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('code-write',  'plan',      'planned',    'Implementation plan ready.'),
    ('code-write',  'implement', 'executing',  'Code written + iterated to a green build/test in the sandbox.'),
    ('code-write',  'verify',    'verified',   'Build/test independently re-run green.'),
    ('code-pr',     'clone',     'researched', 'Repo cloned into the worktree + surveyed.'),
    ('code-pr',     'plan',      'planned',    'Implementation plan ready, grounded in the real repo.'),
    ('code-pr',     'implement', 'executing',  'Change written + iterated to a green build/test in the cloned repo.'),
    ('code-pr',     'verify',    'verified',   'Build/test independently re-run green.'),
    ('code-pr',     'pr',        'verified',   'Branch pushed + DRAFT PR opened; awaiting the human merge (the Hinge).'),
    ('code-deploy', 'prepare',   'planned',    'Deploy plan ready; awaiting human ratification (the Hinge).'),
    ('code-deploy', 'deploy',    'verified',   'Deployed to the sandbox sidecar + healthchecked.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;


-- =====================================================================
-- §6 — research_codebase tool_def (r10 original, clean; active per r12).
-- =====================================================================
-- The cataloged live row carries a "via <server>:" prefix the bridge adds at
-- refresh-tools; this is r10's authored definition. mcp_proxy → pg-ai-stewards
-- (the Go handler builds the binding_question + spawns subagent-research-codebase).
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('research_codebase',
 'Explore a code repository (read-only) and return curated findings + file:line citations. Delegates to a cheap deepseek-v4-flash sub-agent that greps/reads in a repo-mounted sandbox. EXPENSIVE agentic search — for an exact string match use grep; use this for "how does X work / where is Y handled" questions where curated, cited synthesis is worth the delegation.',
 '{"type":"object","required":["repo","question"],"additionalProperties":false,"properties":{"repo":{"type":"string","description":"The repository to research (must be on the coder repo allow-list, e.g. your-repo)."},"question":{"type":"string","description":"The code question to answer (e.g. how does the gateway authenticate a persona?)."}}}'::jsonb,
 jsonb_build_object('kind','mcp_proxy','server','pg-ai-stewards','tool','research_codebase'),
 true)
ON CONFLICT (name) DO UPDATE
   SET description    = EXCLUDED.description,
       args_schema    = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target,
       active         = EXCLUDED.active;


-- =====================================================================
-- §7 — stamp_code_write_sandbox FINAL (cv12): a stable per-work_item sandbox
-- id (one worktree across the revise loop) + default the code-pr critic-loop
-- feedback fields so the FIRST dispatch doesn't hit a NULL template path.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.stamp_code_write_sandbox()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    IF NEW.pipeline_family IN ('code-write', 'code-pr')
       AND (NEW.input IS NULL OR (NEW.input->>'sandbox') IS NULL)
    THEN
        NEW.input := COALESCE(NEW.input, '{}'::jsonb)
            || jsonb_build_object('sandbox', 'wi-' || substring(NEW.id::text FROM 1 FOR 8));
    END IF;

    -- cv12: seed the critic-loop feedback fields the code-pr templates reference,
    -- so the first dispatch (no bounce yet) doesn't resolve a NULL path.
    IF NEW.pipeline_family = 'code-pr' THEN
        IF (NEW.input->>'plan_feedback') IS NULL THEN
            NEW.input := COALESCE(NEW.input, '{}'::jsonb) || jsonb_build_object('plan_feedback', '');
        END IF;
        IF (NEW.input->>'review_feedback') IS NULL THEN
            NEW.input := COALESCE(NEW.input, '{}'::jsonb) || jsonb_build_object('review_feedback', '');
        END IF;
    END IF;

    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS trg_stamp_code_write_sandbox ON stewards.work_items;
CREATE TRIGGER trg_stamp_code_write_sandbox
    BEFORE INSERT ON stewards.work_items
    FOR EACH ROW EXECUTE FUNCTION stewards.stamp_code_write_sandbox();


-- =====================================================================
-- §8 — work_item_advance: the core (08) body + the code-pr critic loop-backs.
-- =====================================================================
-- GRAFT, not paste: this is 08-gates' clean-room body (with the maturity hook)
-- plus cv6's `review` loop-back and cv11's `plan_review` loop-back, both gated to
-- pipeline_family='code-pr'. Pasting the live cv11 body would revert the
-- clean-room consolidation; this preserves it and adds only the two branches.
CREATE OR REPLACE FUNCTION stewards.work_item_advance(
    p_work_item_id uuid,
    p_stage_output jsonb DEFAULT '{}'::jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_pipeline        stewards.pipelines%ROWTYPE;
    v_stage           jsonb;
    v_next_name       text;
    v_auto_advance    boolean;
    v_results         jsonb;
    v_completing      text;
    v_new_maturity    text;
    v_current_idx     int;
    v_new_idx         int;
    -- code-pr critic loop-back state (cv6 / cv11)
    v_verdict_text    text;
    v_revise_count    int;
    v_revise_cap      int;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;
    IF v_wi.status NOT IN ('in_progress', 'awaiting_review', 'pending') THEN
        RAISE EXCEPTION 'work_item %: cannot advance from status %',
            p_work_item_id, v_wi.status;
    END IF;

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    v_next_name    := v_stage->>'next';
    v_auto_advance := COALESCE((v_stage->>'auto_advance')::bool, true);
    v_completing   := v_wi.current_stage;

    v_results := v_wi.stage_results
              || jsonb_build_object(v_completing,
                     p_stage_output
                     || jsonb_build_object('completed_at', now()));

    -- ----- cv6: code-pr implement-critic (`review`) loop-back -----
    IF v_wi.pipeline_family = 'code-pr' AND v_completing = 'review' THEN
        v_verdict_text := COALESCE(p_stage_output->>'output', '');
        v_revise_count := COALESCE((v_wi.input->>'revise_count')::int, 0);
        v_revise_cap   := COALESCE((v_wi.input->>'revise_cap')::int, 2);
        -- Match the verdict LINE anywhere, not just at output start: models
        -- often preamble before the "REVIEW: passes" line (glm-5.1 does), so a
        -- start-anchored ^ misread a genuine pass as a revise and parked the
        -- item at awaiting_review.
        IF v_verdict_text !~* '(^|\n)\s*REVIEW:\s*passes' THEN
            IF v_revise_count < v_revise_cap THEN
                UPDATE stewards.work_items
                   SET stage_results = v_results,
                       current_stage = 'implement',
                       input         = input || jsonb_build_object(
                                          'review_feedback', v_verdict_text,
                                          'revise_count', v_revise_count + 1),
                       status        = 'pending',
                       updated_at    = now()
                 WHERE id = p_work_item_id;
                RETURN 'implement';
            ELSE
                UPDATE stewards.work_items
                   SET stage_results     = v_results,
                       status            = 'awaiting_review',
                       quarantine_reason = COALESCE(quarantine_reason,
                           format('critic: still deficient after %s revise cycle(s)', v_revise_cap)),
                       error             = COALESCE(error,
                           'critic review deficient after revise cap; needs a human'),
                       updated_at        = now()
                 WHERE id = p_work_item_id;
                RETURN NULL;
            END IF;
        END IF;
        -- passes: fall through to the normal advance below (next = pr).
    END IF;

    -- ----- cv11: code-pr plan-critic (`plan_review`) loop-back -----
    IF v_wi.pipeline_family = 'code-pr' AND v_completing = 'plan_review' THEN
        v_verdict_text := COALESCE(p_stage_output->>'output', '');
        v_revise_count := COALESCE((v_wi.input->>'plan_revise_count')::int, 0);
        v_revise_cap   := COALESCE((v_wi.input->>'plan_revise_cap')::int, 2);
        -- Line-anchored (see cv6): tolerate preamble before "PLAN: approved".
        IF v_verdict_text !~* '(^|\n)\s*PLAN:\s*approved' THEN
            IF v_revise_count < v_revise_cap THEN
                UPDATE stewards.work_items
                   SET stage_results = v_results,
                       current_stage = 'plan',
                       input         = input || jsonb_build_object(
                                          'plan_feedback', v_verdict_text,
                                          'plan_revise_count', v_revise_count + 1),
                       status        = 'pending',
                       updated_at    = now()
                 WHERE id = p_work_item_id;
                RETURN 'plan';
            ELSE
                -- Cap reached: proceed to implement with the best plan (don't deadlock).
                UPDATE stewards.work_items
                   SET stage_results = v_results,
                       current_stage = 'implement',
                       status        = 'pending',
                       updated_at    = now()
                 WHERE id = p_work_item_id;
                RETURN 'implement';
            END IF;
        END IF;
        -- approved: fall through to the normal advance (next = implement).
    END IF;

    -- ----- maturity advance hook (forward-only) -----
    SELECT produces_maturity INTO v_new_maturity
      FROM stewards.pipeline_stage_maturity
     WHERE pipeline_family = v_wi.pipeline_family
       AND stage_name      = v_completing;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    IF v_new_maturity IS NOT NULL AND v_pipeline.maturity_ladder IS NOT NULL THEN
        SELECT pos - 1 INTO v_current_idx
          FROM jsonb_array_elements_text(v_pipeline.maturity_ladder)
          WITH ORDINALITY AS t(rung, pos)
         WHERE rung = COALESCE(v_wi.maturity, 'raw');

        SELECT pos - 1 INTO v_new_idx
          FROM jsonb_array_elements_text(v_pipeline.maturity_ladder)
          WITH ORDINALITY AS t(rung, pos)
         WHERE rung = v_new_maturity;

        IF v_current_idx IS NOT NULL AND v_new_idx IS NOT NULL AND v_new_idx > v_current_idx THEN
            NULL;
        ELSE
            v_new_maturity := NULL;
        END IF;
    END IF;

    IF v_next_name IS NULL OR v_next_name = '' THEN
        UPDATE stewards.work_items
           SET stage_results = v_results,
               status        = 'completed',
               completed_at  = now(),
               maturity      = COALESCE(v_new_maturity, maturity),
               updated_at    = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    IF stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_next_name) IS NULL THEN
        RAISE EXCEPTION
            'work_item %: stage %s `next` references missing stage %',
            p_work_item_id, v_completing, v_next_name;
    END IF;

    UPDATE stewards.work_items
       SET stage_results = v_results,
           current_stage = v_next_name,
           status        = CASE WHEN v_auto_advance THEN 'pending'
                                ELSE 'awaiting_review' END,
           maturity      = COALESCE(v_new_maturity, maturity),
           updated_at    = now()
     WHERE id = p_work_item_id;

    RETURN v_next_name;
END;
$func$;


-- =====================================================================
-- §9 — work_item_dispatch_stage: the 19 dispatch FINAL + the code-pr
-- critic model-immunity branch (cv7/cv10).
-- =====================================================================
-- GRAFT onto the 19 (r3) dispatch-final: the code-pr `review` critic ignores
-- the work_item's model_override (which is the DEV model during a bake-off) and
-- uses input.review_model if set, else its stage.model (the pinned constant
-- critic). Every other stage/pipeline is unchanged. The rest is the 19 body
-- verbatim (4-layer resolution + capability substitution + spend-cap + max_tokens).
CREATE OR REPLACE FUNCTION stewards.work_item_dispatch_stage(
    p_work_item_id           uuid,
    p_user_input             text DEFAULT NULL,
    p_allow_failed_status    boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $function$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_stage          jsonb;
    v_pipeline_meta  jsonb;
    v_agent          text;
    v_model          text;
    v_provider       text;
    v_session_id     text;
    v_user_input     text;
    v_body           jsonb;
    v_payload        jsonb;
    v_work_id        bigint;
    v_was_failed     boolean := false;
    v_resolved_model text;
    v_sub_model      text;
    v_cap_detail     text;
    v_max_tokens     text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    IF v_wi.status NOT IN ('pending', 'awaiting_review')
       AND NOT (p_allow_failed_status AND v_wi.status = 'failed')
    THEN
        RAISE EXCEPTION 'work_item %: cannot dispatch from status %',
            p_work_item_id, v_wi.status;
    END IF;

    v_was_failed := (v_wi.status = 'failed');

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    SELECT metadata INTO v_pipeline_meta
      FROM stewards.pipelines
     WHERE family = v_wi.pipeline_family;

    v_agent := v_stage->>'agent_family';

    -- J.8.a: 4-layer resolution (input -> stages -> pipeline -> catalog).
    v_provider := COALESCE(
        v_wi.provider_override,
        v_stage->>'provider',
        v_pipeline_meta->>'default_provider',
        stewards.catalog_default_provider()
    );

    v_model := COALESCE(
        v_wi.model_override,
        v_stage->>'model',
        v_pipeline_meta->>'default_model',
        stewards.catalog_default_model(v_provider)
    );

    -- cv7 + cv10: the code-pr `review` critic ignores model_override. The critic
    -- model is input.review_model if set (per-task experiments), else stage.model
    -- (the pinned constant critic). Never the dev model_override — so a bake-off
    -- that sets the dev model never turns the critic into the model judging itself.
    IF v_wi.pipeline_family = 'code-pr' AND v_wi.current_stage = 'review' THEN
        v_model := COALESCE(v_wi.input->>'review_model', v_stage->>'model', v_model);
    END IF;

    IF v_agent IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % missing agent_family',
            p_work_item_id, v_wi.current_stage;
    END IF;
    IF v_model IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % could not resolve model — checked work_items.model_override, stages.model, pipelines.metadata.default_model, catalog_default_model(%) — all NULL',
            p_work_item_id, v_wi.current_stage, v_provider;
    END IF;
    IF v_provider IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % could not resolve provider',
            p_work_item_id, v_wi.current_stage;
    END IF;

    -- M.2: capability gate. If the resolved model is marked unusable, substitute
    -- a usable one for the same provider and remember the swap (logged at enqueue).
    v_resolved_model := v_model;
    IF NOT stewards.model_usable(v_provider, v_model) THEN
        v_sub_model := stewards.pick_usable_model(v_provider, v_model);
        IF v_sub_model IS NULL THEN
            RAISE EXCEPTION 'work_item %: resolved model %/% is marked unusable and the provider has no usable substitute — dispatch refused. Inspect stewards.model_capability.',
                p_work_item_id, v_provider, v_model;
        END IF;
        SELECT probe_detail INTO v_cap_detail
          FROM stewards.model_capability
         WHERE provider = v_provider AND model = v_resolved_model;
        v_model := v_sub_model;
    END IF;

    -- J.11: enforced prepaid spend-cap gate (provider-level).
    IF stewards.provider_cap_exceeded(v_provider) THEN
        RAISE EXCEPTION 'work_item %: provider % spend cap reached ($% spent since refill / $% cap) — dispatch refused. Top up + reset with: SELECT stewards.provider_cap_refill(''%'');',
            p_work_item_id, v_provider,
            round(stewards.provider_spend_since(v_provider) / 1000000.0, 4),
            round((SELECT cap_micro FROM stewards.provider_spend_caps WHERE provider = v_provider) / 1000000.0, 2),
            v_provider;
    END IF;

    v_session_id := substring(
        'wi--' || substring(p_work_item_id::text FROM 1 FOR 8)
        || '--' || v_wi.current_stage
        FROM 1 FOR 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('work_item %s stage %s', v_wi.id, v_wi.current_stage),
            'agent')
    ON CONFLICT (id) DO NOTHING;

    IF p_user_input IS NOT NULL THEN
        v_user_input := p_user_input;
    ELSE
        v_user_input := stewards.render_stage_input(p_work_item_id);
        IF v_user_input IS NULL THEN
            v_user_input := coalesce(
                v_wi.input->>'user_input',
                v_wi.input::text
            );
        END IF;
    END IF;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_user_input, v_model);

    v_body := stewards.dry_run_chat(v_agent, v_model, v_session_id, NULL);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_agent,
        'requested_model',    v_model,
        'meta',               v_body->'_meta',
        'body',               (v_body - '_meta')
                              || jsonb_build_object('user', v_session_id),
        '_work_item_id',      p_work_item_id::text,
        '_stage_name',        v_wi.current_stage,
        '_pipeline_family',   v_wi.pipeline_family
    );

    -- R.3 (1): per-call output ceiling. input override wins; else stage default.
    v_max_tokens := COALESCE(v_wi.input->>'max_tokens', v_stage->>'max_tokens');
    IF v_max_tokens IS NOT NULL AND v_max_tokens ~ '^[0-9]+$' THEN
        v_payload := jsonb_set(v_payload, '{body,max_tokens}', to_jsonb(v_max_tokens::int));
    END IF;

    -- R.3 (2): input-scoped tools-off.
    IF (v_wi.input->>'tools_disabled')::boolean IS TRUE THEN
        v_payload := v_payload || jsonb_build_object('tools_disabled', true);
    END IF;

    -- M.2: attach the substitution marker so the l29 trigger logs the swap.
    IF v_model IS DISTINCT FROM v_resolved_model THEN
        v_payload := v_payload || jsonb_build_object(
            '_capability_substitution', jsonb_build_object(
                'from',   v_resolved_model,
                'to',     v_model,
                'reason', COALESCE(v_cap_detail, 'model marked unusable')
            )
        );
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_provider, v_payload)
    RETURNING id INTO v_work_id;

    UPDATE stewards.work_items
       SET status      = 'in_progress',
           session_ids = session_ids || v_session_id,
           updated_at  = now()
     WHERE id = p_work_item_id;

    RETURN v_work_id;
END;
$function$;


-- =====================================================================
-- End of 20-coder.sql
-- =====================================================================
