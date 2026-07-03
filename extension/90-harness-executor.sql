-- =====================================================================
-- 90-harness-executor.sql — the harness executor (loom Phase 1, ratified 2026-07-03)
-- =====================================================================
-- The substrate becomes a metaharness: harness_run dispatches a stage's task
-- to a FULL Claude Code harness as a subprocess (`loom run --isolate`), the
-- tier above the native loop for hard, multi-file, corpus-grounded work. The
-- native loop stays fully capable — this is a tier, not a replacement. The Go
-- handler lives in the bridge (cmd/stewards-mcp/harness.go), the same way the
-- other agentic wrappers do; the loom Reply's session_id is the durable
-- resume handle, ledgered here on stewards.harness_runs.
--
-- Phase 1 scope (ratified plan .spec/proposals/loom-integration.md):
--   * PULL-only, read-mostly: the harness reads its mounted workdir with its
--     own tools and (where the operator wires the hinge) the substrate's
--     Arc C READ-ONLY HTTP surface. It cannot write to the substrate, submit
--     a2a work, or spawn anything — those tools are absent from the surface
--     it can reach, not merely un-prompted.
--   * NO default routing: only the harness-pilot family holds the grant, and
--     the harness-review pipeline is reached by EXPLICIT routing only.
--   * Write-back (Phase 2) and tier routing (Phase 3) are dominion_in_council
--     gates — deliberately NOT built here.
--
-- effect_class reasoning (84's taxonomy, read before classifying): harness_run
-- executes a whole agent in a sandbox. Judged against the dangerous three:
--   external_send — no: the dispatch sends nothing outward; the container's
--     only wired reach is the read-only substrate MCP surface.
--   irreversible  — no: the container is ephemeral (--rm); the workdir is the
--     only mutable surface and Phase-1 tooling is read-only (Read/Glob/Grep).
--   financial     — no: auth is a subscription credential; cost_usd is
--     accounting we ledger, not a transaction the tool performs.
-- Agentic execution is a genuinely new category none of the classes name, so
-- the honest tag is 'unclassified' — Michael ratified NOT gating unclassified
-- (84's gate_unclassified default false). An operator who flips
-- gate_unclassified gets a confirmation pause on every harness dispatch,
-- which is exactly the conservative behavior that switch promises.
--
-- requires create_sticky_agent_family (86) — installs at the tail of the
-- chain. (87–89 are sibling-build slots; the integrator re-stitches requires.)
-- =====================================================================

-- =====================================================================
-- §1 — the dispatch ledger. session_id on the ledger = the durable resume
-- handle (loom --resume <harness_session_id> + the same claude-home).
-- =====================================================================
CREATE TABLE IF NOT EXISTS stewards.harness_runs (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id         text,            -- the substrate session that dispatched (injected by the dispatcher)
    work_item_id       uuid,            -- best-effort via stewards.session_work_item(session_id)
    backend            text NOT NULL DEFAULT 'claude',
    workdir            text,            -- host dir mounted as the harness's /work (NULL = scratch)
    prompt             text NOT NULL,
    harness_session_id text,            -- loom Reply.session_id — THE durable resume handle
    cost_usd           numeric(12,6),
    turns              int,
    status             text NOT NULL DEFAULT 'done'
                       CHECK (status IN ('done','error')),
    error              text,
    created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS harness_runs_session_idx
    ON stewards.harness_runs (session_id, created_at DESC);

COMMENT ON TABLE stewards.harness_runs IS
'90: the harness-dispatch ledger — one row per harness_run (loom Phase 1). harness_session_id is the durable resume handle: a later dispatch resumes it with loom --resume + the same claude-home. cost_usd/turns come from loom''s --json Reply; work_item_id resolves best-effort from the dispatch session (84''s session_work_item). Failures ledger too (status=error) so cost and breakage share one surface.';

COMMENT ON COLUMN stewards.harness_runs.harness_session_id IS
'90: the Claude Code session id from loom''s Reply — the resume handle. Resume requires re-mounting the SAME claude-home (the session state lives there); without it an isolated --resume silently starts fresh.';

-- =====================================================================
-- §2 — tool_defs registration. mcp_proxy → the substrate''s own stdio
-- surface (the research_codebase shape); the Go handler execs loom.
-- effect_class seeds 'unclassified' (header reasoning) and the ON CONFLICT
-- deliberately does NOT touch it — an operator''s tag sticks (84 §2).
-- =====================================================================
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active)
VALUES
('harness_run',
 'Dispatch a task to a FULL Claude Code harness (via loom) running isolated in a docker sandbox — the tier above the native loop for hard, multi-file work grounded in a real directory. The harness reads the mounted workdir with its own tools and (where the hinge is wired) the substrate''s READ-ONLY doc/work-item surface. Phase 1 is read-mostly: it cannot write to the substrate, submit a2a work, or spawn anything. Returns the harness''s answer + session_id (the durable resume handle, ledgered on stewards.harness_runs) + cost. EXPENSIVE — one call is a whole agent run; use the native loop for cheap/bulk work.',
 '{"type":"object","required":["prompt"],"additionalProperties":false,"properties":{"prompt":{"type":"string","description":"The task for the harness — the full prompt Claude Code receives (the workdir is its corpus; the prompt is the task)."},"workdir":{"type":"string","description":"Optional HOST directory bind-mounted as the harness''s working dir (/work) — the code/context it reads. Default: an empty scratch dir."},"backend":{"type":"string","description":"loom backend (default claude)."},"timeout_seconds":{"type":"integer","description":"Wall-clock cap for the whole dispatch (default 600, max 3600)."}}}'::jsonb,
 jsonb_build_object('kind','mcp_proxy','server','pg-ai-stewards','tool','harness_run','inject_session',true),
 'unclassified',
 true)
ON CONFLICT (name) DO UPDATE
   SET description    = EXCLUDED.description,
       args_schema    = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target,
       active         = EXCLUDED.active;

-- ── keep inject_session sticky across refresh-tools rewrites ─────────
-- 52's trigger re-stamps the flag every time a tool_defs row is written
-- (refresh-tools rebuilds execute_target wholesale). Re-author it with
-- harness_run added: the ledger must record the DISPATCH session, and the
-- dispatcher — not the model — is the oracle for which session that is.
-- (coder_export_artifact stays excluded; see 52's header — it routes
-- cross-session on purpose.)
CREATE OR REPLACE FUNCTION stewards.tool_def_inject_session()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.name IN ('generate_image', 'harness_run') THEN
        NEW.execute_target :=
            coalesce(NEW.execute_target, '{}'::jsonb)
            || jsonb_build_object('inject_session', true);
    END IF;
    RETURN NEW;
END;
$fn$;

-- =====================================================================
-- §3 — the harness-pilot family: the ONE holder of the grant.
-- =====================================================================
-- Deny-by-default already keeps harness_run off every other family; the
-- explicit work-item-chat deny below turns the ratified wall ("no existing
-- family gets it") into a row a future session must consciously delete,
-- not merely an absence it might not notice.
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES ('harness-pilot', '*',
 'Pilot for harness_run (90). Dispatches a stage''s task to the full Claude Code harness (loom, isolated) and relays the answer verbatim. Holds harness_run and nothing else.',
 'primary',
 $PROMPT$You are the harness pilot. Your ONLY tool is harness_run — it hands the task to a FULL Claude Code harness running isolated in a docker sandbox, with read-only substrate access. You dispatch; the harness does the work.

Method:
1. Call harness_run exactly once: prompt = the task text you were given, verbatim — do not summarize, translate, or embellish it. Pass workdir only if the task names a host directory to work against.
2. When it returns, relay the harness's answer verbatim, keeping the [harness_run complete — …] metadata line (its session id is the durable resume handle).
3. If it errors, report the error plainly and stop. Do not retry on your own, do not fabricate an answer, and never claim the harness said something it did not.$PROMPT$,
 0.1, 4)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description,
       mode        = EXCLUDED.mode,
       prompt      = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature,
       steps       = EXCLUDED.steps,
       active      = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
VALUES ('harness-pilot', 'harness_run', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action,
       source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- The ratified wall, as a row: the cockpit chat must never grow this tool.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
VALUES ('work-item-chat', 'harness_run', 'deny', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action,
       source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- =====================================================================
-- §4 — the harness-review pipeline: EXPLICIT routing only.
-- =====================================================================
-- A single dispatch stage so a work item CAN route to the harness by naming
-- pipeline_family='harness-review' — and nothing routes here by default
-- (metadata.no_default_routing documents the council gate; Phase 3 tier
-- routing is where that decision would live, after council).
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES ('harness-review',
 '90: single-stage harness dispatch — harness-pilot hands the binding question to a full Claude Code harness (loom, isolated, read-mostly) and relays the answer. Explicit routing only; never a default route (Phase 3 tier routing is council-gated).',
 '[{"name": "dispatch", "next": null, "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "harness-pilot", "auto_advance": true, "input_template": "Dispatch this task to the full Claude Code harness via harness_run.\n\nTASK (pass to harness_run as prompt, verbatim):\n{{input.binding_question}}\n\nWorkdir (pass to harness_run as workdir if non-empty): {{input.workdir}}\n\nCall harness_run once, then relay its answer verbatim including the metadata line.", "tools_disabled": false}]'::jsonb,
 'f', 'f', '["raw", "verified"]'::jsonb, 'f',
 '{"shape": "harness-dispatch", "wrapper": "harness_run", "read_only": true, "no_default_routing": true, "phase": "loom-phase-1"}'::jsonb)
ON CONFLICT (family) DO UPDATE
   SET stages = EXCLUDED.stages, description = EXCLUDED.description, metadata = EXCLUDED.metadata;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('harness-review', 'dispatch', 'kimi-k2.6',
     'Thin pilot turn: call harness_run with the binding question, relay verbatim. The harness inside does the heavy lifting; this stage needs reliability, not brilliance.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('harness-review', 'dispatch', 'verified',
     'The harness answered; its session id + cost are on stewards.harness_runs.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

-- =====================================================================
-- End of 90-harness-executor.sql
-- =====================================================================
