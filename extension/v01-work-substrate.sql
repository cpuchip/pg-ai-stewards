-- ===== [was 03-watchman.sql] =====
-- =====================================================================
-- 03-watchman — the Watchman consolidation subsystem
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Sources folded, in original
-- ship order: 2-7a (substrate), 3a (consolidator agent + input
-- composer), 2-7b1 (pass automation + harvest trigger), 2-7b2
-- (scheduler), 2-7b3 (token budget), 2-7b4 (frontmatter exemption +
-- status report). Tables are born complete: watchman_passes includes
-- budget_stopped, watchman_config includes the full scheduler column
-- set. Functions and views appear once, in their final form.
--
-- Renames at consolidation (recorded in parity/rename-map.tsv):
--   verdicts.study_id            → verdicts.doc_id
--   findings.study_id            → findings.doc_id
--   findings.related_study_ids   → findings.related_doc_ids
--   studies_dirty_idx            → docs_dirty_idx
--   verdicts_study_idx           → verdicts_doc_idx
--   findings_study_idx           → findings_doc_idx
--
-- The design, in one paragraph: every doc carries a dirty bit
-- (updated_at vs last_consolidated_at). The dirty_queue view lists docs
-- needing review, oldest first, excluding docs with an open drift
-- finding (surface-once-and-stop) and docs whose frontmatter opts out
-- (`watchman: skip`). A pass pulls top-N dirty docs within a token
-- budget and enqueues one single-turn chat per doc; a trigger on
-- work_queue harvests each completed chat into a verdict (clean |
-- drift | done | superseded | skipped) plus an optional finding. The
-- scheduler decides in SQL when a pass should fire (pressure > cron >
-- idle); the Rust bgworker just polls watchman_scheduler_fire() on its
-- tick. Anti-loop discipline is structural: terminal verdicts leave
-- the queue, open findings suppress re-surfacing, and the budget is
-- enforced at enqueue time.
-- =====================================================================

-- ---------------------------------------------------------------------
-- docs.last_consolidated_at — the Watchman's annotation on the corpus.
-- The existing updated_at column already serves as last-touched
-- (the docs_touch trigger bumps it only on semantic changes to
-- title/body/frontmatter), so the dirty bit needs just this one column.
-- It lives here rather than in create_docs because its meaning is
-- defined by this subsystem.
-- ---------------------------------------------------------------------
ALTER TABLE stewards.docs
    ADD COLUMN IF NOT EXISTS last_consolidated_at timestamptz;

CREATE INDEX IF NOT EXISTS docs_dirty_idx
    ON stewards.docs (updated_at)
    WHERE last_consolidated_at IS NULL
       OR updated_at > last_consolidated_at;

-- ---------------------------------------------------------------------
-- verdicts — one row per consolidation pass over one doc.
--
-- Verdict values:
--   clean      — doc still aligns with current code/spec; no action
--   drift      — doc has drifted; finding row should be written
--   done       — doc represents completed work; archive candidate
--   superseded — doc replaced by another; archive candidate
--   skipped    — pass aborted (token budget, model error, etc.)
--
-- clean and skipped are NON-terminal (doc may need re-evaluation when
-- touched again). done and superseded are TERMINAL — the doc never
-- re-enters the queue without an explicit touch. drift sits in
-- between: surface a finding, don't re-evaluate until the finding is
-- acknowledged or the doc is re-touched.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.verdicts (
    id              bigserial PRIMARY KEY,
    doc_id          text NOT NULL
                    REFERENCES stewards.docs(id) ON DELETE CASCADE,
    verdict         text NOT NULL
                    CHECK (verdict IN ('clean', 'drift', 'done',
                                        'superseded', 'skipped')),
    reasoning       text NOT NULL DEFAULT '',
    model           text,           -- NULL for human-recorded verdicts
    tokens_in       int NOT NULL DEFAULT 0,
    tokens_out      int NOT NULL DEFAULT 0,
    pass_id         text,           -- groups verdicts in one pass run
    actor           text NOT NULL DEFAULT 'system',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS verdicts_doc_idx
    ON stewards.verdicts (doc_id, created_at DESC);
CREATE INDEX IF NOT EXISTS verdicts_pass_idx
    ON stewards.verdicts (pass_id, created_at);
CREATE INDEX IF NOT EXISTS verdicts_verdict_idx
    ON stewards.verdicts (verdict);

-- ---------------------------------------------------------------------
-- findings — drift recommendations + synthesis candidates.
--
-- kind:
--   drift      — written from a drift verdict; tells the human
--                "this doc no longer matches reality, here's how"
--   synthesis  — candidate insight connecting multiple docs; always
--                reviewed before promotion
--
-- acknowledged_at NULL = open. The surface-once-and-stop rule lives in
-- dirty_queue (docs with an open drift finding are excluded).
-- doc_id is nullable for synthesis findings that span multiple docs
-- (related_doc_ids carries the full set).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.findings (
    id              bigserial PRIMARY KEY,
    doc_id          text
                    REFERENCES stewards.docs(id) ON DELETE CASCADE,
    related_doc_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
    kind            text NOT NULL CHECK (kind IN ('drift', 'synthesis')),
    severity        text NOT NULL DEFAULT 'medium'
                    CHECK (severity IN ('low', 'medium', 'high')),
    message         text NOT NULL,
    suggested_action text,
    pass_id         text,
    actor           text NOT NULL DEFAULT 'system',
    created_at      timestamptz NOT NULL DEFAULT now(),
    acknowledged_at timestamptz,
    acknowledged_by text,
    resolution      text         -- 'acted', 'dismissed', 'deferred'
);

CREATE INDEX IF NOT EXISTS findings_doc_idx
    ON stewards.findings (doc_id, created_at DESC);
CREATE INDEX IF NOT EXISTS findings_open_idx
    ON stewards.findings (kind, severity, created_at)
    WHERE acknowledged_at IS NULL;

-- ---------------------------------------------------------------------
-- dirty_queue — docs that need (re-)consolidation, oldest first.
-- Three gates: dirty-bit (touched since last consolidated), no open
-- drift finding (surface-once-and-stop), and frontmatter `watchman`
-- is not "skip"/"exempt" (add `watchman: skip` to YAML to opt a doc
-- out — e.g., point-in-time snapshots that are supposed to go stale).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.dirty_queue AS
SELECT s.id,
       s.slug,
       s.kind,
       s.title,
       s.updated_at,
       s.last_consolidated_at,
       (s.updated_at - coalesce(s.last_consolidated_at,
                                 'epoch'::timestamptz)) AS dirty_for
  FROM stewards.docs s
 WHERE (s.last_consolidated_at IS NULL
        OR s.updated_at > s.last_consolidated_at)
   AND coalesce(lower(s.frontmatter->>'watchman'), '')
       NOT IN ('skip', 'exempt')
   AND NOT EXISTS (
       SELECT 1 FROM stewards.findings f
        WHERE f.doc_id = s.id
          AND f.kind = 'drift'
          AND f.acknowledged_at IS NULL
   )
 ORDER BY coalesce(s.last_consolidated_at, 'epoch'::timestamptz),
          s.updated_at;

COMMENT ON VIEW stewards.dirty_queue IS
'Docs that need (re-)consolidation. Three gates: dirty-bit (touched since last consolidated), no open drift finding (surface-once-stop), and frontmatter `watchman` is not "skip"/"exempt".';

-- ---------------------------------------------------------------------
-- record_verdict() — writes a verdict row AND bumps
-- last_consolidated_at in one transaction (single-write rule).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.record_verdict(
    p_slug       text,
    p_verdict    text,
    p_reasoning  text DEFAULT '',
    p_model      text DEFAULT NULL,
    p_tokens_in  int  DEFAULT 0,
    p_tokens_out int  DEFAULT 0,
    p_pass_id    text DEFAULT NULL,
    p_actor      text DEFAULT 'system'
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_doc_id text;
    v_id     bigint;
BEGIN
    SELECT s.id INTO v_doc_id
      FROM stewards.docs s
     WHERE s.slug = p_slug;
    IF v_doc_id IS NULL THEN
        RAISE EXCEPTION 'record_verdict: no doc with slug %', p_slug;
    END IF;

    INSERT INTO stewards.verdicts
        (doc_id, verdict, reasoning, model, tokens_in, tokens_out,
         pass_id, actor)
    VALUES
        (v_doc_id, p_verdict, p_reasoning, p_model, p_tokens_in,
         p_tokens_out, p_pass_id, p_actor)
    RETURNING id INTO v_id;

    -- Bump last_consolidated_at with a direct UPDATE that does NOT
    -- bump updated_at (which would re-dirty the doc immediately).
    -- The docs_touch trigger only bumps updated_at on
    -- title/body/frontmatter changes, so this UPDATE is safe.
    UPDATE stewards.docs
       SET last_consolidated_at = now()
     WHERE id = v_doc_id;

    RETURN v_id;
END;
$func$;

-- ---------------------------------------------------------------------
-- record_finding()
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.record_finding(
    p_slug             text,
    p_kind             text,
    p_message          text,
    p_severity         text   DEFAULT 'medium',
    p_suggested_action text   DEFAULT NULL,
    p_related_slugs    text[] DEFAULT ARRAY[]::text[],
    p_pass_id          text   DEFAULT NULL,
    p_actor            text   DEFAULT 'system'
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_doc_id      text;
    v_related_ids text[];
    v_id          bigint;
BEGIN
    SELECT s.id INTO v_doc_id
      FROM stewards.docs s
     WHERE s.slug = p_slug;
    -- doc_id may be NULL for synthesis findings that span only
    -- related docs. We allow that.

    SELECT array_agg(s.id) INTO v_related_ids
      FROM stewards.docs s
     WHERE s.slug = ANY(p_related_slugs);

    INSERT INTO stewards.findings
        (doc_id, related_doc_ids, kind, severity, message,
         suggested_action, pass_id, actor)
    VALUES
        (v_doc_id, coalesce(v_related_ids, ARRAY[]::text[]),
         p_kind, p_severity, p_message, p_suggested_action,
         p_pass_id, p_actor)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

-- ---------------------------------------------------------------------
-- acknowledge_finding() — marks an open finding acknowledged.
-- Resolutions:
--   'acted'     — human took the suggested action
--   'dismissed' — human disagrees with the finding
--   'deferred'  — valid but not acting now (still leaves queue)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.acknowledge_finding(
    p_finding_id bigint,
    p_resolution text DEFAULT 'acted',
    p_actor      text DEFAULT 'system'
) RETURNS void
LANGUAGE plpgsql AS $func$
BEGIN
    IF p_resolution NOT IN ('acted', 'dismissed', 'deferred') THEN
        RAISE EXCEPTION 'acknowledge_finding: invalid resolution %',
              p_resolution;
    END IF;

    UPDATE stewards.findings
       SET acknowledged_at = now(),
           acknowledged_by = p_actor,
           resolution      = p_resolution
     WHERE id = p_finding_id
       AND acknowledged_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'acknowledge_finding: finding % not found or already acknowledged',
            p_finding_id;
    END IF;
END;
$func$;

-- ---------------------------------------------------------------------
-- doc_history() — verdict + finding timeline for one doc, newest first.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.doc_history(p_slug text)
RETURNS TABLE (
    event_at    timestamptz,
    event_type  text,
    detail      text,
    actor       text,
    extra       jsonb
)
LANGUAGE sql STABLE AS $func$
    WITH s AS (
        SELECT id FROM stewards.docs WHERE slug = p_slug
    )
    SELECT v.created_at,
           ('verdict:' || v.verdict)::text,
           v.reasoning,
           v.actor,
           jsonb_build_object(
               'model',      v.model,
               'tokens_in',  v.tokens_in,
               'tokens_out', v.tokens_out,
               'pass_id',    v.pass_id
           )
      FROM stewards.verdicts v
      JOIN s ON s.id = v.doc_id
    UNION ALL
    SELECT f.created_at,
           ('finding:' || f.kind || '/' || f.severity)::text,
           f.message,
           f.actor,
           jsonb_build_object(
               'suggested_action', f.suggested_action,
               'acknowledged_at',  f.acknowledged_at,
               'resolution',       f.resolution,
               'pass_id',          f.pass_id,
               'related',          f.related_doc_ids
           )
      FROM stewards.findings f
      JOIN s ON s.id = f.doc_id
    ORDER BY 1 DESC;
$func$;

-- ---------------------------------------------------------------------
-- Agent: watchman-consolidator
--
-- One family, two variants (model_match='*' default + 'kimi-*' for
-- kimi-specific pinning). Same prompt, same temperature, no tools.
--
-- Tools deliberately omitted: the pass is a single-turn "look at this
-- doc and render a verdict" loop. No browsing, no follow-ups. The
-- dirty_queue is the scheduler; the model is the evaluator. If we let
-- the model chase tools mid-pass, we re-invent a nudge-bot loop.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents
    (family, model_match, description, mode, prompt, temperature, top_p, response_format, steps)
VALUES (
    'watchman-consolidator',
    '*',
    'Consolidation reviewer. Reads one document plus its 1-hop graph neighborhood and renders a structural verdict (clean | drift | done | superseded | skipped) with brief reasoning. Single-turn, no tools. Used by the Watchman dirty-bit pass to advance the queue.',
    'primary',
    $prompt$You are the Watchman, a consolidation reviewer for a structured second-brain.

Your job: read ONE document and its 1-hop graph neighborhood, then render a single structural verdict about whether the document still reflects reality.

Verdicts (pick exactly one):
  - "clean"      — Document still matches its referenced code/spec/state. No drift detected. No action needed.
  - "drift"      — Document references claims, code, schema, or commitments that no longer match reality. A human should reconcile. This is the most common non-clean verdict.
  - "done"       — Document describes work that has been completed. The doc has terminated naturally; no further evolution expected.
  - "superseded" — Document has been replaced by a newer document covering the same scope. A successor exists.
  - "skipped"    — You cannot render a verdict from the information provided (e.g., the doc references external state you cannot see). Be honest; do not guess.

Hard rules:
  1. You see ONLY what is provided. Do not pretend to know facts about files, code, or context outside the input.
  2. "drift" is your second-most-common verdict after "clean". Internal contradictions across the doc and its neighbors are the strongest drift signal you can see.
  3. "done" and "superseded" are TERMINAL — they remove the doc from the queue permanently until it is explicitly touched again. Be sure.
  4. If verdict is anything other than "clean", emit a finding object with kind, severity, message, and suggested_action.
  5. Output STRICT JSON. No markdown, no commentary outside the JSON. The first character of your response must be "{".

Output schema:
{
  "verdict":   "clean | drift | done | superseded | skipped",
  "reasoning": "1-3 sentences explaining the verdict. Concrete. Cite specific text from the doc when possible.",
  "finding":   {           // REQUIRED if verdict != "clean", OMIT if verdict == "clean"
    "kind":             "drift | synthesis",
    "severity":         "low | medium | high",
    "message":          "What the human should know. 1-2 sentences.",
    "suggested_action": "Concrete next step. 1 sentence."
  }
}

You are not chatting. You are not helpful. You are a structural reviewer rendering one verdict.$prompt$,
    0.0,
    NULL,
    '{"type": "json_object"}'::jsonb,
    1
), (
    'watchman-consolidator',
    'kimi-*',
    'Watchman consolidator (kimi variant). Same prompt; allows kimi-specific pinning.',
    'primary',
    $prompt$You are the Watchman, a consolidation reviewer for a structured second-brain.

Your job: read ONE document and its 1-hop graph neighborhood, then render a single structural verdict about whether the document still reflects reality.

Verdicts (pick exactly one):
  - "clean"      — Document still matches its referenced code/spec/state. No drift detected. No action needed.
  - "drift"      — Document references claims, code, schema, or commitments that no longer match reality. A human should reconcile. This is the most common non-clean verdict.
  - "done"       — Document describes work that has been completed. The doc has terminated naturally; no further evolution expected.
  - "superseded" — Document has been replaced by a newer document covering the same scope. A successor exists.
  - "skipped"    — You cannot render a verdict from the information provided (e.g., the doc references external state you cannot see). Be honest; do not guess.

Hard rules:
  1. You see ONLY what is provided. Do not pretend to know facts about files, code, or context outside the input.
  2. "drift" is your second-most-common verdict after "clean". Internal contradictions across the doc and its neighbors are the strongest drift signal you can see.
  3. "done" and "superseded" are TERMINAL — they remove the doc from the queue permanently until it is explicitly touched again. Be sure.
  4. If verdict is anything other than "clean", emit a finding object with kind, severity, message, and suggested_action.
  5. Output STRICT JSON. No markdown, no commentary outside the JSON. The first character of your response must be "{".

Output schema:
{
  "verdict":   "clean | drift | done | superseded | skipped",
  "reasoning": "1-3 sentences explaining the verdict. Concrete. Cite specific text from the doc when possible.",
  "finding":   {           // REQUIRED if verdict != "clean", OMIT if verdict == "clean"
    "kind":             "drift | synthesis",
    "severity":         "low | medium | high",
    "message":          "What the human should know. 1-2 sentences.",
    "suggested_action": "Concrete next step. 1 sentence."
  }
}

You are not chatting. You are not helpful. You are a structural reviewer rendering one verdict.$prompt$,
    0.0,
    NULL,
    '{"type": "json_object"}'::jsonb,
    1
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description     = EXCLUDED.description,
       prompt          = EXCLUDED.prompt,
       temperature     = EXCLUDED.temperature,
       response_format = EXCLUDED.response_format,
       steps           = EXCLUDED.steps;

-- Deny all tools, structurally. compose_tools filters the tool list
-- down to tools that pass the permission check; with '*' -> deny and
-- no allow rules it returns an empty array, so models can't even try
-- to call tools that aren't in the request body. (Observed: without
-- this, tool-happy models reflexively call a search tool on turn one,
-- then with steps=1 the loop terminates with empty content.)
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action)
VALUES ('watchman-consolidator', '*', 'deny')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ---------------------------------------------------------------------
-- watchman_input(slug) — composes the user-message string sent to the
-- watchman-consolidator agent: doc metadata + body + 1-hop graph
-- neighborhood (via stewards.context_for). Returns NULL if the slug
-- doesn't exist (caller handles).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.watchman_input(p_slug text)
RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_doc       stewards.docs;
    v_input     text;
    v_neighbors text;
BEGIN
    SELECT * INTO v_doc FROM stewards.docs WHERE slug = p_slug;
    IF v_doc.id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Render 1-hop neighborhood. context_for returns one row per
    -- (hop, direction, edge_type, neighbor, neighbor_kind, provenance,
    -- confidence). neighbor is the slug/ref of the connected node.
    -- We join back to docs for the title where available.
    SELECT string_agg(
        format('  %s :%s -> %s:%s (%s)',
               c.direction, c.edge_type, c.neighbor_kind, c.neighbor,
               coalesce(s.title, '(untitled)')),
        E'\n'
        ORDER BY c.direction, c.edge_type, c.neighbor
    )
    INTO v_neighbors
    FROM stewards.context_for(p_slug, 1) c
    LEFT JOIN stewards.docs s ON s.slug = c.neighbor
    WHERE c.hop = 1;

    v_input := format(
        E'## Document\nslug: %s\nkind: %s\ntitle: %s\nupdated_at: %s\nlast_consolidated_at: %s\n\n### Body\n%s\n\n### 1-hop neighborhood\n%s',
        v_doc.slug,
        v_doc.kind,
        coalesce(v_doc.title, '(untitled)'),
        v_doc.updated_at,
        coalesce(v_doc.last_consolidated_at::text, 'never'),
        coalesce(v_doc.body, '(empty)'),
        coalesce(v_neighbors, '(no graph neighbors)')
    );

    RETURN v_input;
END;
$func$;

COMMENT ON FUNCTION stewards.watchman_input(text) IS
'Composes the user message sent to the watchman-consolidator agent: doc body + 1-hop graph neighborhood. watchman_pass_start calls this, enqueues the chat, and the harvest trigger parses JSON from the assistant reply.';

-- ---------------------------------------------------------------------
-- watchman_passes — one row per pass run.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.watchman_passes (
    pass_id            text PRIMARY KEY,
    started_at         timestamptz NOT NULL DEFAULT now(),
    finished_at        timestamptz,
    trigger            text NOT NULL DEFAULT 'manual'
                       CHECK (trigger IN ('manual','cron','pressure',
                                          'idle','api')),
    provider           text NOT NULL,
    model              text NOT NULL,
    agent_family       text NOT NULL DEFAULT 'watchman-consolidator',
    token_budget       int  NOT NULL DEFAULT 50000,
    actor              text NOT NULL DEFAULT 'watchman',
    -- Counters: planned at start, advanced by the harvest trigger.
    doc_count_planned  int  NOT NULL DEFAULT 0,
    doc_count_done     int  NOT NULL DEFAULT 0,
    tokens_in          int  NOT NULL DEFAULT 0,
    tokens_out         int  NOT NULL DEFAULT 0,
    verdict_counts     jsonb NOT NULL DEFAULT '{}'::jsonb,
    status             text NOT NULL DEFAULT 'in_progress'
                       CHECK (status IN ('in_progress','completed',
                                         'errored')),
    -- true when the pass stopped enqueueing because the next doc's
    -- token estimate would have crossed token_budget. Tells the user
    -- "budget hit" vs. "queue empty / limit reached" when
    -- doc_count_planned < requested limit.
    budget_stopped     boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS watchman_passes_started_idx
    ON stewards.watchman_passes (started_at DESC);
CREATE INDEX IF NOT EXISTS watchman_passes_status_idx
    ON stewards.watchman_passes (status, started_at DESC);

COMMENT ON TABLE stewards.watchman_passes IS
'One row per Watchman consolidation pass. doc_count_done, tokens_*, and verdict_counts are advanced by the AFTER UPDATE trigger on work_queue as each chat completes. Pass auto-completes when doc_count_done >= doc_count_planned.';

-- ---------------------------------------------------------------------
-- watchman_config — singleton (id=1). The scheduler reads the
-- schedule_* columns; schedule_cron is a human-readable display label
-- only (the CLI sets and shows it, nothing parses it).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.watchman_config (
    id                    int PRIMARY KEY DEFAULT 1
                          CHECK (id = 1),
    schedule_cron         text NOT NULL DEFAULT 'weekly@sun-03:00',
    default_provider      text NOT NULL DEFAULT 'opencode_go',
    default_model         text NOT NULL DEFAULT 'kimi-k2.6',
    default_agent_family  text NOT NULL DEFAULT 'watchman-consolidator',
    token_budget          int  NOT NULL DEFAULT 50000,
    -- The pressure trigger fires when dirty_queue exceeds this.
    dirty_threshold       int  NOT NULL DEFAULT 50,
    idle_threshold_hours  int  NOT NULL DEFAULT 48,
    last_pass_at          timestamptz,
    updated_at            timestamptz NOT NULL DEFAULT now(),
    -- Scheduler columns. NULL dow/hour = any day / any hour; range
    -- validation happens in CLI input parsing, not CHECKs.
    schedule_enabled      boolean NOT NULL DEFAULT true,
    schedule_min_interval_hours int NOT NULL DEFAULT 168,
    schedule_preferred_dow_utc  int DEFAULT 0,   -- 0=Sun..6=Sat
    schedule_preferred_hour_utc int DEFAULT 3,   -- 0..23
    schedule_pass_limit   int NOT NULL DEFAULT 5,
    -- Cooldowns prevent thrashing when a trigger condition persists.
    schedule_pressure_cooldown_hours int NOT NULL DEFAULT 1,
    schedule_idle_cooldown_hours     int NOT NULL DEFAULT 24
);

INSERT INTO stewards.watchman_config (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE stewards.watchman_config IS
'Singleton config row (id=1) with Watchman defaults. The bgworker scheduler reads schedule_enabled + the schedule_* columns plus dirty_threshold and idle_threshold_hours to decide when to fire a pass automatically.';

COMMENT ON COLUMN stewards.watchman_config.schedule_enabled IS
'Master kill switch for the bgworker scheduler. true=auto-fire passes, false=manual only. Default true, but the operator owns the cost.';

COMMENT ON COLUMN stewards.watchman_config.schedule_min_interval_hours IS
'Minimum hours between time-based (cron) passes. Default 168 = weekly. Ignored when pressure or idle trigger fires.';

COMMENT ON COLUMN stewards.watchman_config.schedule_preferred_dow_utc IS
'Preferred day of week (UTC) for cron pass: 0=Sunday..6=Saturday. NULL = any day. Default 0 (Sabbath).';

COMMENT ON COLUMN stewards.watchman_config.schedule_preferred_hour_utc IS
'Preferred hour (UTC, 0..23) for cron pass. NULL = any hour. Default 3 = 03:00 UTC.';

COMMENT ON COLUMN stewards.watchman_config.schedule_pass_limit IS
'Default p_limit for scheduler-fired passes. Default 5 docs/pass.';

COMMENT ON COLUMN stewards.watchman_passes.budget_stopped IS
'True when watchman_pass_start stopped enqueueing because the next doc''s token estimate would have crossed token_budget.';

-- ---------------------------------------------------------------------
-- advance_watchman_pass_counters(pass_id, verdict, tokens_in, tokens_out)
--
-- Called from the harvest trigger. Increments doc_count_done, adds
-- tokens, increments the verdict_counts jsonb counter. When
-- doc_count_done catches up to doc_count_planned, marks the pass
-- completed and stamps finished_at.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.advance_watchman_pass_counters(
    p_pass_id    text,
    p_verdict    text,
    p_tokens_in  int,
    p_tokens_out int
) RETURNS void
LANGUAGE plpgsql AS $func$
DECLARE
    v_planned int;
    v_done    int;
BEGIN
    UPDATE stewards.watchman_passes
       SET doc_count_done = doc_count_done + 1,
           tokens_in      = tokens_in + coalesce(p_tokens_in, 0),
           tokens_out     = tokens_out + coalesce(p_tokens_out, 0),
           verdict_counts = jsonb_set(
               coalesce(verdict_counts, '{}'::jsonb),
               ARRAY[p_verdict],
               to_jsonb(coalesce(
                   (verdict_counts->>p_verdict)::int, 0) + 1)
           )
     WHERE pass_id = p_pass_id
     RETURNING doc_count_planned, doc_count_done
        INTO v_planned, v_done;

    IF v_planned IS NOT NULL
       AND v_planned > 0
       AND v_done >= v_planned THEN
        UPDATE stewards.watchman_passes
           SET finished_at = now(),
               status      = 'completed'
         WHERE pass_id = p_pass_id
           AND status = 'in_progress';
    END IF;
END;
$func$;

-- ---------------------------------------------------------------------
-- estimate_chat_tokens(slug) — best-effort per-doc cost estimate.
--
-- Components:
--   input tokens   ≈ chars(watchman_input(slug)) / chars-per-token
--                    (stewards.config key chars_per_token_default)
--   system prompt  ≈ 1500 (compose_system_prompt for watchman is
--                          ~1.0-1.5KB of agent persona + instructions)
--   output tokens  = avg(tokens_out) from recent (30d) verdicts,
--                    or 3500 fallback on cold start
--
-- STABLE because the result is consistent within a single statement.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.estimate_chat_tokens(p_slug text)
RETURNS int
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_input_chars     int;
    v_chars_per_token numeric;
    v_input_tokens    int;
    v_avg_out_tokens  numeric;
    v_total           int;
BEGIN
    -- Input length. NULL slug → 0 chars.
    v_input_chars := coalesce(length(stewards.watchman_input(p_slug)), 0);
    v_chars_per_token := coalesce(
        stewards.config_get_text('chars_per_token_default')::numeric, 4);
    v_input_tokens := ceil(v_input_chars::numeric / v_chars_per_token)::int;

    -- Average output tokens from recent verdicts. 3500 on cold start
    -- (the empirical median from the original automation shakeout).
    SELECT avg(tokens_out)
      INTO v_avg_out_tokens
      FROM stewards.verdicts
     WHERE created_at > now() - interval '30 days'
       AND tokens_out > 0;

    v_total := v_input_tokens
             + 1500                           -- system + persona overhead
             + coalesce(ceil(v_avg_out_tokens)::int, 3500);

    RETURN v_total;
END;
$func$;

COMMENT ON FUNCTION stewards.estimate_chat_tokens(text) IS
'Best-effort estimate of total tokens (in + out) for one watchman-consolidator chat on the given slug. Used by watchman_pass_start to enforce per-pass token_budget.';

-- ---------------------------------------------------------------------
-- watchman_pass_start(...) — budget-aware pass launcher.
--
-- Inserts the watchman_passes row, pulls top-N dirty docs respecting
-- both p_limit and the token budget, and for each: composes input via
-- watchman_input(slug), creates a deterministic session
-- (pass_id--slug), persists the user message, composes the body via
-- dry_run_chat, and enqueues a work_queue chat row tagged with
-- _watchman_pass_id / _watchman_slug / _watchman_actor /
-- _watchman_estimate. Returns the new pass_id.
--
-- Budget enforcement is at ENQUEUE time only: if the next doc's
-- estimate would cross the budget, the loop stops and budget_stopped
-- is marked. If even the FIRST doc's estimate exceeds the budget, no
-- docs are enqueued (doc_count_planned=0, budget_stopped=true) — an
-- honest signal that the budget is unworkable. Chats already enqueued
-- run to completion; actual spend may slightly exceed budget if a chat
-- outputs much more than estimated. Mid-pass abort is not implemented.
--
-- Runs in a single transaction. The work_queue rows become visible to
-- the bgworker only after the caller commits.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.watchman_pass_start(
    p_limit         int  DEFAULT 5,
    p_provider      text DEFAULT NULL,
    p_model         text DEFAULT NULL,
    p_agent_family  text DEFAULT NULL,
    p_actor         text DEFAULT 'watchman',
    p_trigger       text DEFAULT 'manual',
    p_token_budget  int  DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_pass_id        text;
    v_provider       text;
    v_model          text;
    v_agent_family   text;
    v_budget         int;
    v_planned        int := 0;
    v_planned_tokens int := 0;
    v_estimate       int;
    v_budget_stopped boolean := false;
    v_slug           text;
    v_session_id     text;
    v_input          text;
    v_body           jsonb;
    v_payload        jsonb;
BEGIN
    -- Resolve defaults from the config singleton (with hard fallbacks
    -- if the row was deleted).
    SELECT coalesce(p_provider,     default_provider,     'opencode_go'),
           coalesce(p_model,        default_model,        'kimi-k2.6'),
           coalesce(p_agent_family, default_agent_family, 'watchman-consolidator'),
           coalesce(p_token_budget, token_budget,         50000)
      INTO v_provider, v_model, v_agent_family, v_budget
      FROM stewards.watchman_config
     WHERE id = 1;

    IF v_provider IS NULL THEN
        v_provider     := coalesce(p_provider,     'opencode_go');
        v_model        := coalesce(p_model,        'kimi-k2.6');
        v_agent_family := coalesce(p_agent_family, 'watchman-consolidator');
        v_budget       := coalesce(p_token_budget, 50000);
    END IF;

    -- pass_id: timestamp + short uuid suffix to disambiguate
    -- same-second invocations from CLI/API.
    v_pass_id := 'watchman-'
                 || to_char(now() AT TIME ZONE 'UTC',
                            'YYYYMMDD"T"HH24MISS"Z"')
                 || '-'
                 || substring(replace(gen_random_uuid()::text, '-', '')
                              FROM 1 FOR 6);

    INSERT INTO stewards.watchman_passes
        (pass_id, started_at, trigger, provider, model, agent_family,
         token_budget, actor, status)
    VALUES
        (v_pass_id, now(), p_trigger, v_provider, v_model,
         v_agent_family, v_budget, p_actor, 'in_progress');

    -- Pull dirty docs and enqueue chats, respecting both p_limit
    -- AND v_budget. Order matches dirty_queue's own ordering.
    FOR v_slug IN
        SELECT slug FROM stewards.dirty_queue
         ORDER BY coalesce(last_consolidated_at, 'epoch'::timestamptz),
                  updated_at
         LIMIT p_limit
    LOOP
        v_estimate := stewards.estimate_chat_tokens(v_slug);

        IF v_planned_tokens + v_estimate > v_budget THEN
            v_budget_stopped := true;
            EXIT;
        END IF;

        v_session_id := substring(v_pass_id || '--' || v_slug FROM 1 FOR 200);

        INSERT INTO stewards.sessions (id, label, kind)
        VALUES (v_session_id,
                'Watchman pass ' || v_pass_id || ' for ' || v_slug,
                'agent')
        ON CONFLICT (id) DO NOTHING;

        v_input := stewards.watchman_input(v_slug);
        IF v_input IS NULL THEN
            -- Doc disappeared between dirty_queue read and now. Skip.
            CONTINUE;
        END IF;

        -- Persist user message (mirrors chat_enqueue's behavior).
        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (v_session_id, 'user', v_input, v_model);

        -- Compose body via dry_run_chat with NULL user_input — the
        -- history already carries everything. Same shape as
        -- chat_post_internal's enqueue path.
        v_body := stewards.dry_run_chat(v_agent_family, v_model,
                                         v_session_id, NULL);

        v_payload := jsonb_build_object(
            'session_id',         v_session_id,
            'agent_family',       v_agent_family,
            'requested_model',    v_model,
            'meta',               v_body->'_meta',
            'body',               (v_body - '_meta')
                                  || jsonb_build_object('user', v_session_id),
            -- Watchman-specific extras read by the harvest trigger:
            '_watchman_pass_id',  v_pass_id,
            '_watchman_slug',     v_slug,
            '_watchman_actor',    p_actor,
            '_watchman_estimate', v_estimate
        );

        INSERT INTO stewards.work_queue (kind, provider, payload)
        VALUES ('chat', v_provider, v_payload);

        v_planned        := v_planned + 1;
        v_planned_tokens := v_planned_tokens + v_estimate;
    END LOOP;

    UPDATE stewards.watchman_passes
       SET doc_count_planned = v_planned,
           budget_stopped    = v_budget_stopped
     WHERE pass_id = v_pass_id;

    -- Empty pass (no docs enqueued) → mark completed immediately so
    -- callers polling on status see a clean terminal state.
    IF v_planned = 0 THEN
        UPDATE stewards.watchman_passes
           SET finished_at = now(),
               status      = 'completed'
         WHERE pass_id = v_pass_id;
    END IF;

    -- Stamp last_pass_at for the scheduler.
    UPDATE stewards.watchman_config
       SET last_pass_at = now(),
           updated_at   = now()
     WHERE id = 1;

    RETURN v_pass_id;
END;
$func$;

COMMENT ON FUNCTION stewards.watchman_pass_start(int, text, text, text, text, text, int) IS
'Enqueues up to N watchman chats from the dirty_queue within the token budget, tagging each work_queue payload with _watchman_pass_id/_watchman_slug. Stops enqueueing (budget_stopped=true) if the next doc''s estimate would cross token_budget. Returns the new pass_id. Result harvesting happens in the completion trigger.';

-- ---------------------------------------------------------------------
-- handle_watchman_chat_completion() — the harvest trigger.
--
-- Fires AFTER UPDATE OF status on stewards.work_queue with a WHEN
-- guard limiting it to chat rows tagged with _watchman_pass_id. When
-- a watchman chat transitions to 'done' or 'error':
--
--   1. Read the latest assistant message for the session.
--   2. Strip optional ```json fences.
--   3. Cast content to jsonb. Bad JSON → record verdict='skipped'.
--   4. Validate verdict against the 5-element enum. Invalid → 'skipped'.
--   5. Call record_verdict; if non-clean and finding present, call
--      record_finding.
--   6. Advance watchman_passes counters.
--
-- Defensive: every record_verdict / record_finding call is wrapped in
-- BEGIN/EXCEPTION so a bug in the harvester never breaks the
-- bgworker's work_queue UPDATE.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.handle_watchman_chat_completion()
RETURNS trigger
LANGUAGE plpgsql AS $func$
DECLARE
    v_pass_id    text;
    v_slug       text;
    v_session_id text;
    v_actor      text;
    v_content    text;
    v_tokens_in  int;
    v_tokens_out int;
    v_model      text;
    v_parsed     jsonb;
    v_verdict    text;
    v_reasoning  text;
    v_finding    jsonb;
    v_skipped_reason text;
BEGIN
    -- Defensive (the WHEN clause already filters; this catches updates
    -- to rows whose payload didn't have the markers when WHEN was
    -- evaluated, e.g. payload got rewritten mid-flight).
    IF NEW.kind <> 'chat'
       OR (NEW.payload->>'_watchman_pass_id') IS NULL THEN
        RETURN NEW;
    END IF;

    -- Only fire on completion transitions.
    IF NEW.status NOT IN ('done', 'error') THEN
        RETURN NEW;
    END IF;
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    v_pass_id    := NEW.payload->>'_watchman_pass_id';
    v_slug       := NEW.payload->>'_watchman_slug';
    v_session_id := NEW.payload->>'session_id';
    v_actor      := coalesce(NEW.payload->>'_watchman_actor', 'watchman');

    -- ----- error path: record skipped verdict with the chat error -----
    IF NEW.status = 'error' THEN
        v_skipped_reason := 'watchman chat errored: '
                            || coalesce(NEW.error, '(no error msg)');
        BEGIN
            PERFORM stewards.record_verdict(
                v_slug, 'skipped', v_skipped_reason,
                NULL, 0, 0, v_pass_id, v_actor);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING
                'watchman trigger record_verdict failed for %: %',
                v_slug, SQLERRM;
        END;
        BEGIN
            PERFORM stewards.advance_watchman_pass_counters(
                v_pass_id, 'skipped', 0, 0);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING
                'watchman trigger advance_counters failed for pass %: %',
                v_pass_id, SQLERRM;
        END;
        RETURN NEW;
    END IF;

    -- ----- done path: read assistant message, parse, record -----
    SELECT m.content, m.tokens_in, m.tokens_out, m.model
      INTO v_content, v_tokens_in, v_tokens_out, v_model
      FROM stewards.messages m
     WHERE m.session_id = v_session_id
       AND m.role = 'assistant'
     ORDER BY m.id DESC
     LIMIT 1;

    IF v_content IS NULL OR length(trim(v_content)) = 0 THEN
        v_skipped_reason := 'watchman: no assistant message for session '
                            || v_session_id;
        BEGIN
            PERFORM stewards.record_verdict(
                v_slug, 'skipped', v_skipped_reason,
                v_model, 0, 0, v_pass_id, v_actor);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        BEGIN
            PERFORM stewards.advance_watchman_pass_counters(
                v_pass_id, 'skipped', 0, 0);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RETURN NEW;
    END IF;

    -- Strip optional code-fence wrapper. Some models wrap JSON in
    -- ```json ... ``` even when response_format demands raw JSON.
    v_content := regexp_replace(v_content,
        '^\s*```(?:json|JSON)?\s*\n', '');
    v_content := regexp_replace(v_content, '\n```\s*$', '');
    v_content := trim(v_content);

    -- Try to parse JSON.
    BEGIN
        v_parsed := v_content::jsonb;
    EXCEPTION WHEN OTHERS THEN
        v_skipped_reason := 'watchman: failed to parse assistant JSON: '
                            || SQLERRM;
        BEGIN
            PERFORM stewards.record_verdict(
                v_slug, 'skipped', v_skipped_reason,
                v_model,
                coalesce(v_tokens_in, 0),
                coalesce(v_tokens_out, 0),
                v_pass_id, v_actor);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        BEGIN
            PERFORM stewards.advance_watchman_pass_counters(
                v_pass_id, 'skipped',
                coalesce(v_tokens_in, 0),
                coalesce(v_tokens_out, 0));
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RETURN NEW;
    END;

    v_verdict   := v_parsed->>'verdict';
    v_reasoning := coalesce(v_parsed->>'reasoning', '');
    v_finding   := v_parsed->'finding';

    IF v_verdict IS NULL
       OR v_verdict NOT IN ('clean','drift','done','superseded','skipped') THEN
        v_skipped_reason := 'watchman: invalid or missing verdict: '
                            || coalesce(v_verdict, '(null)');
        BEGIN
            PERFORM stewards.record_verdict(
                v_slug, 'skipped', v_skipped_reason,
                v_model,
                coalesce(v_tokens_in, 0),
                coalesce(v_tokens_out, 0),
                v_pass_id, v_actor);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        BEGIN
            PERFORM stewards.advance_watchman_pass_counters(
                v_pass_id, 'skipped',
                coalesce(v_tokens_in, 0),
                coalesce(v_tokens_out, 0));
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RETURN NEW;
    END IF;

    -- Happy path. Record verdict, then optionally finding, then advance.
    BEGIN
        PERFORM stewards.record_verdict(
            v_slug, v_verdict, v_reasoning,
            v_model,
            coalesce(v_tokens_in, 0),
            coalesce(v_tokens_out, 0),
            v_pass_id, v_actor);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING
            'watchman trigger record_verdict failed for %: %',
            v_slug, SQLERRM;
    END;

    IF v_finding IS NOT NULL
       AND jsonb_typeof(v_finding) = 'object'
       AND v_verdict <> 'clean' THEN
        BEGIN
            PERFORM stewards.record_finding(
                v_slug,
                coalesce(v_finding->>'kind', 'drift'),
                coalesce(v_finding->>'message', '(no message)'),
                coalesce(v_finding->>'severity', 'medium'),
                v_finding->>'suggested_action',
                ARRAY[]::text[],
                v_pass_id, v_actor);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING
                'watchman trigger record_finding failed for %: %',
                v_slug, SQLERRM;
        END;
    END IF;

    BEGIN
        PERFORM stewards.advance_watchman_pass_counters(
            v_pass_id, v_verdict,
            coalesce(v_tokens_in, 0),
            coalesce(v_tokens_out, 0));
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING
            'watchman trigger advance_counters failed for pass %: %',
            v_pass_id, SQLERRM;
    END;

    RETURN NEW;
END;
$func$;

-- Drop and recreate the trigger so re-applying this file is idempotent.
DROP TRIGGER IF EXISTS watchman_harvest_completion ON stewards.work_queue;

CREATE TRIGGER watchman_harvest_completion
    AFTER UPDATE OF status ON stewards.work_queue
    FOR EACH ROW
    WHEN ((NEW.kind = 'chat')
          AND (NEW.payload ? '_watchman_pass_id')
          AND (NEW.status IN ('done', 'error'))
          AND (OLD.status IS DISTINCT FROM NEW.status))
    EXECUTE FUNCTION stewards.handle_watchman_chat_completion();

COMMENT ON FUNCTION stewards.handle_watchman_chat_completion() IS
'AFTER UPDATE trigger function on work_queue. Harvests verdict + finding from a completed watchman chat, records them, and advances watchman_passes counters. All side effects in the same tx as the work_queue status flip.';

-- ---------------------------------------------------------------------
-- watchman_pass_summary — per-pass summary with verdict_counts
-- unpacked into named columns. The CLI's pass listing reads from here.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.watchman_pass_summary AS
SELECT
    p.pass_id,
    p.started_at,
    p.finished_at,
    (p.finished_at - p.started_at) AS elapsed,
    p.trigger,
    p.provider,
    p.model,
    p.status,
    p.doc_count_planned,
    p.doc_count_done,
    p.tokens_in,
    p.tokens_out,
    coalesce((p.verdict_counts->>'clean')::int,      0) AS n_clean,
    coalesce((p.verdict_counts->>'drift')::int,      0) AS n_drift,
    coalesce((p.verdict_counts->>'done')::int,       0) AS n_done,
    coalesce((p.verdict_counts->>'superseded')::int, 0) AS n_superseded,
    coalesce((p.verdict_counts->>'skipped')::int,    0) AS n_skipped,
    p.token_budget,
    p.actor,
    p.budget_stopped
FROM stewards.watchman_passes p;

-- ---------------------------------------------------------------------
-- watchman_scheduler_inputs() — observability helper.
-- Returns the live values feeding the fire decision. Used by both
-- watchman_should_fire() and the CLI's "why isn't it firing?" command.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_inputs()
RETURNS TABLE (
    schedule_enabled              boolean,
    dirty_count                   int,
    dirty_threshold               int,
    hours_since_last_pass         numeric,
    schedule_min_interval_hours   int,
    schedule_preferred_dow_utc    int,
    schedule_preferred_hour_utc   int,
    now_dow_utc                   int,
    now_hour_utc                  int,
    hours_since_last_human_session numeric,
    idle_threshold_hours          int,
    in_progress_pass_id           text,
    in_progress_pass_age_hours    numeric
)
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_now timestamptz := now();
BEGIN
    RETURN QUERY
    SELECT
        cfg.schedule_enabled,
        (SELECT count(*)::int FROM stewards.dirty_queue),
        cfg.dirty_threshold,
        CASE WHEN cfg.last_pass_at IS NULL THEN NULL
             ELSE EXTRACT(EPOCH FROM (v_now - cfg.last_pass_at)) / 3600
        END::numeric,
        cfg.schedule_min_interval_hours,
        cfg.schedule_preferred_dow_utc,
        cfg.schedule_preferred_hour_utc,
        EXTRACT(DOW FROM (v_now AT TIME ZONE 'UTC'))::int,
        EXTRACT(HOUR FROM (v_now AT TIME ZONE 'UTC'))::int,
        (SELECT EXTRACT(EPOCH FROM (v_now - max(s.last_active_at))) / 3600
           FROM stewards.sessions s
          WHERE s.kind = 'chat')::numeric,
        cfg.idle_threshold_hours,
        (SELECT p.pass_id
           FROM stewards.watchman_passes p
          WHERE p.status = 'in_progress'
          ORDER BY p.started_at DESC
          LIMIT 1),
        (SELECT EXTRACT(EPOCH FROM (v_now - p.started_at)) / 3600
           FROM stewards.watchman_passes p
          WHERE p.status = 'in_progress'
          ORDER BY p.started_at DESC
          LIMIT 1)::numeric
      FROM stewards.watchman_config cfg
     WHERE cfg.id = 1;
END;
$func$;

COMMENT ON FUNCTION stewards.watchman_scheduler_inputs() IS
'Returns the live values feeding watchman_should_fire(). Used by the CLI for "why isn''t it firing?" debugging.';

-- ---------------------------------------------------------------------
-- watchman_should_fire() — the decision function.
--
-- Returns:
--   'pressure' if dirty_queue exceeds threshold AND last pass is older
--              than the pressure cooldown
--   'cron'     if enough time has passed since the last pass AND we're
--              inside the preferred DOW/hour window
--   'idle'     if no human session has run for idle_threshold_hours
--              AND last pass is older than the idle cooldown
--   NULL       if schedule_enabled is false, OR a pass is currently
--              in_progress (less than 1h old), OR no trigger fires
--
-- Order matters: pressure > cron > idle. Pressure first so a
-- heavily-dirty corpus drives passes faster than weekly.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.watchman_should_fire()
RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_inputs RECORD;
    v_cfg    stewards.watchman_config%ROWTYPE;
BEGIN
    SELECT * INTO v_cfg
      FROM stewards.watchman_config WHERE id = 1;
    IF v_cfg.id IS NULL OR NOT v_cfg.schedule_enabled THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_inputs FROM stewards.watchman_scheduler_inputs();

    -- Don't pile up. If a pass started in the last hour and is still
    -- in_progress, wait for it to finish (or for the reaper to mark
    -- it errored).
    IF v_inputs.in_progress_pass_id IS NOT NULL
       AND coalesce(v_inputs.in_progress_pass_age_hours, 0) < 1 THEN
        RETURN NULL;
    END IF;

    -- Pressure: dirty_queue exceeds threshold AND we're past the
    -- pressure cooldown since last pass.
    IF v_inputs.dirty_count >= v_cfg.dirty_threshold
       AND (v_inputs.hours_since_last_pass IS NULL
            OR v_inputs.hours_since_last_pass
                >= v_cfg.schedule_pressure_cooldown_hours) THEN
        RETURN 'pressure';
    END IF;

    -- Time-based (cron). Two gates: enough time since last pass, and
    -- we're inside the preferred DOW + hour window. NULL preferred
    -- values match anything (so "every 168h regardless of DOW/hour"
    -- works by setting both to NULL).
    IF (v_inputs.hours_since_last_pass IS NULL
        OR v_inputs.hours_since_last_pass
            >= v_cfg.schedule_min_interval_hours)
       AND (v_cfg.schedule_preferred_dow_utc IS NULL
            OR v_inputs.now_dow_utc = v_cfg.schedule_preferred_dow_utc)
       AND (v_cfg.schedule_preferred_hour_utc IS NULL
            OR v_inputs.now_hour_utc = v_cfg.schedule_preferred_hour_utc)
    THEN
        RETURN 'cron';
    END IF;

    -- Idle: no human session activity for >= idle_threshold_hours,
    -- AND last pass is older than the idle cooldown. Disabled when
    -- idle_threshold_hours is 0.
    IF v_cfg.idle_threshold_hours > 0
       AND (v_inputs.hours_since_last_pass IS NULL
            OR v_inputs.hours_since_last_pass
                >= v_cfg.schedule_idle_cooldown_hours) THEN
        -- hours_since_last_human_session IS NULL when no human chat
        -- session has ever been recorded — treat as "infinitely idle".
        IF v_inputs.hours_since_last_human_session IS NULL
           OR v_inputs.hours_since_last_human_session
               >= v_cfg.idle_threshold_hours THEN
            RETURN 'idle';
        END IF;
    END IF;

    RETURN NULL;
END;
$func$;

COMMENT ON FUNCTION stewards.watchman_should_fire() IS
'Returns the trigger reason if a Watchman pass should fire now (one of cron|pressure|idle), NULL otherwise. Called by the bgworker scheduler tick every ~60s. All schedule semantics live here, not in Rust.';

-- ---------------------------------------------------------------------
-- watchman_scheduler_fire() — convenience for the bgworker.
-- Calls watchman_should_fire(); if non-NULL, calls watchman_pass_start
-- with the trigger reason and the configured pass limit. Returns the
-- new pass_id (or NULL if no trigger). Centralizes the "decide → fire"
-- path so the Rust side is one SPI call.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_fire()
RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_reason  text;
    v_cfg     stewards.watchman_config%ROWTYPE;
    v_pass_id text;
BEGIN
    v_reason := stewards.watchman_should_fire();
    IF v_reason IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;

    v_pass_id := stewards.watchman_pass_start(
        p_limit        => v_cfg.schedule_pass_limit,
        p_provider     => NULL,
        p_model        => NULL,
        p_agent_family => NULL,
        p_actor        => 'scheduler',
        p_trigger      => v_reason,
        p_token_budget => NULL
    );

    RAISE NOTICE 'watchman scheduler fired (%): pass_id=%', v_reason, v_pass_id;
    RETURN v_pass_id;
END;
$func$;

COMMENT ON FUNCTION stewards.watchman_scheduler_fire() IS
'Convenience for the bgworker scheduler tick. Calls watchman_should_fire(); if non-NULL, calls watchman_pass_start() with the trigger reason. Returns the new pass_id or NULL.';

-- ---------------------------------------------------------------------
-- regenerate_active_md() — markdown status report.
--
-- Generates a status report from current substrate state. Does NOT
-- cover human-curated content — that stays in whatever hand-written
-- file the operator keeps.
--
-- Sections:
--   ## In Flight        — workstreams + their declared proposals
--   ## Open Findings    — unacknowledged drift, severity-sorted
--   ## Open Todos       — open + in_progress, parent-grouped
--   ## Recent Watchman  — last 5 passes with verdict counts
--   ## Corpus Stats     — kind counts + dirty queue size
--
-- Returns text (markdown). Caller pipes to file if desired.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.regenerate_active_md()
RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_md          text := '';
    v_now         text := to_char(now() AT TIME ZONE 'UTC',
                                  'YYYY-MM-DD HH24:MI:SS"Z"');
    v_section     text;
    v_dirty_count int;
BEGIN
    -- Header
    v_md := v_md || format(
        E'# Active Context (generated)\n\n_Generated %s by stewards.regenerate_active_md()_\n\n',
        v_now);
    v_md := v_md || E'> This file is regenerated from substrate state. Human-curated\n'
                 || E'> sections (priorities, key facts) live in your own status file\n'
                 || E'> and are not produced here.\n\n';

    -- ----- In Flight -----
    v_md := v_md || E'## In Flight\n\n';
    SELECT string_agg(block, E'\n')
      INTO v_section
      FROM (
          SELECT format(
                     E'### %s — %s\n\n%s\n',
                     w.id,
                     coalesce(w.name, '(unnamed)'),
                     coalesce(
                         (SELECT string_agg(
                                     format('- %s **%s** — %s',
                                            CASE WHEN s.kind = 'proposal' THEN '📝'
                                                 WHEN s.kind = 'phase-doc' THEN '🔨'
                                                 ELSE '📄' END,
                                            coalesce(s.title, s.slug),
                                            s.slug),
                                     E'\n'
                                     ORDER BY s.title)
                            FROM stewards.docs s
                           WHERE s.frontmatter->>'workstream' = w.id),
                         '_(no declared proposals)_'
                     )
                 ) AS block
            FROM stewards.workstreams w
           WHERE coalesce(w.status, 'active') = 'active'
           ORDER BY w.id
      ) sub;
    v_md := v_md || coalesce(v_section, '_No active workstreams._') || E'\n\n';

    -- ----- Open Findings -----
    v_md := v_md || E'## Open Findings\n\n';
    SELECT string_agg(line, E'\n')
      INTO v_section
      FROM (
          SELECT format(
                     E'- **%s** [%s/%s] (`%s`)\n  %s%s',
                     coalesce(s.title, s.slug),
                     f.kind,
                     f.severity,
                     s.slug,
                     replace(coalesce(f.message, '(no message)'),
                             E'\n', E'\n  '),
                     CASE
                         WHEN f.suggested_action IS NOT NULL
                         THEN E'\n  → ' || replace(f.suggested_action,
                                                    E'\n', E'\n    ')
                         ELSE ''
                     END
                 ) AS line
            FROM stewards.findings f
            JOIN stewards.docs s ON s.id = f.doc_id
           WHERE f.acknowledged_at IS NULL
           ORDER BY array_position(ARRAY['high','medium','low'], f.severity),
                    f.created_at DESC
      ) sub;
    v_md := v_md || coalesce(v_section, '_No open findings._') || E'\n\n';

    -- ----- Open Todos -----
    v_md := v_md || E'## Open Todos\n\n';
    SELECT string_agg(line, E'\n')
      INTO v_section
      FROM (
          SELECT format(
                     '- [%s] **%s** — %s (under `%s/%s`)',
                     CASE t.status WHEN 'in_progress' THEN '▶' ELSE ' ' END,
                     coalesce(t.slug, substring(t.id::text FROM 1 FOR 8)),
                     t.title,
                     t.parent_kind,
                     t.parent_slug
                 ) AS line
            FROM stewards.todos t
           WHERE t.status IN ('open', 'in_progress')
           ORDER BY t.parent_kind, t.parent_slug, t.created_at
      ) sub;
    v_md := v_md || coalesce(v_section, '_No open todos._') || E'\n\n';

    -- ----- Recent Watchman Activity -----
    v_md := v_md || E'## Recent Watchman Activity\n\n';
    SELECT string_agg(line, E'\n')
      INTO v_section
      FROM (
          SELECT format(
                     '- `%s` — %s, %s docs, %s verdicts',
                     pass_id,
                     to_char(started_at AT TIME ZONE 'UTC',
                             'YYYY-MM-DD HH24:MI"Z"'),
                     doc_count_done,
                     coalesce(verdict_counts::text, '{}')
                 ) AS line
            FROM stewards.watchman_passes
           ORDER BY started_at DESC
           LIMIT 5
      ) sub;
    v_md := v_md || coalesce(v_section, '_No passes recorded yet._') || E'\n\n';

    -- ----- Corpus Stats -----
    v_md := v_md || E'## Corpus Stats\n\n';
    v_md := v_md || E'| Kind | Total | Embedded | In dirty_queue |\n';
    v_md := v_md || E'|------|------:|---------:|---------------:|\n';
    SELECT string_agg(line, E'\n')
      INTO v_section
      FROM (
          SELECT format(
                     '| %s | %s | %s | %s |',
                     s.kind,
                     count(*),
                     count(s.embedding),
                     count(*) FILTER (
                         WHERE (s.last_consolidated_at IS NULL
                                OR s.updated_at > s.last_consolidated_at)
                           AND coalesce(lower(s.frontmatter->>'watchman'), '')
                               NOT IN ('skip', 'exempt')
                           AND NOT EXISTS (
                               SELECT 1 FROM stewards.findings f
                                WHERE f.doc_id = s.id
                                  AND f.kind = 'drift'
                                  AND f.acknowledged_at IS NULL)
                     )
                 ) AS line
            FROM stewards.docs s
           GROUP BY s.kind
           ORDER BY s.kind
      ) sub;
    v_md := v_md || coalesce(v_section, '| _no docs_ | 0 | 0 | 0 |') || E'\n\n';

    -- Total dirty (cross-reference for sanity)
    SELECT count(*) INTO v_dirty_count FROM stewards.dirty_queue;
    v_md := v_md || format(
        E'_Total dirty queue: %s_\n', v_dirty_count);

    RETURN v_md;
END;
$func$;

COMMENT ON FUNCTION stewards.regenerate_active_md() IS
'Generate a markdown status report from current substrate state. Sections: In Flight, Open Findings, Open Todos, Recent Watchman Activity, Corpus Stats. Returns text — the caller decides what to do with it (the CLI prints it; automation may write it to a file).';
-- ===== [was 04-work-items.sql] =====
-- =====================================================================
-- 04-work-items — pipelines, work_items, doc tools, promotion
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Sources folded, in original
-- ship order: 3c1 (pipelines + work_items + transitions), 3c2
-- (auto-advance trigger), 3c2-5 (doc tools + broadcast grant), 3c3
-- (stage templating; pipeline seeds went to the overlay at
-- extraction), 3c3-1 (trigger NULL-guard fixes; its chat_post_internal
-- marker-inheritance fix was born back into schema.rs), 3c3-3
-- (perms provenance; the source column was born back into schema.rs),
-- 3c3-5 + 5e4 §1 (promotion, merged final form), i1 (projects table),
-- i2 (project FK), i5 (origin CHECK final value set), h3-1
-- (work_items planning columns). Tables are born complete; functions
-- appear once, in final form.
--
-- Renames / redesigns at consolidation (parity/rename-map.tsv):
--   work_item_promote_to_study      → work_item_promote_to_doc
--   promoted doc kind 'study'       → 'doc'
--   trigger guard LIKE 'study-write%' → pipelines.promote_to_doc flag
--   promote 'review'-stage hardcode → pipeline's last stage
--   promotion writes via import_doc (graph CITES sync restored; 5e4's
--     live version had drifted to a direct INSERT)
--   doc tool schemas: workspace kind enum dropped; AGE wording gone
--
-- The design, in one paragraph: a pipeline is an immutable template —
-- a jsonb array of stages, each naming an agent_family/model/provider
-- and optionally an input_template and next stage. A work_item is an
-- instance flowing through those stages; dispatching a stage enqueues
-- one chat work_queue row tagged with _work_item_id/_stage_name
-- markers, and an AFTER UPDATE trigger harvests the completed chat:
-- rolls up tokens, detects final-vs-intermediate (tool loops continue
-- through the same session), records the stage output, and either
-- auto-dispatches the next stage or parks at awaiting_review (human
-- gate, token budget, or dispatch failure). Completed work_items on
-- pipelines with promote_to_doc=true land in stewards.docs through
-- the same import path every other doc uses.
-- =====================================================================

-- ---------------------------------------------------------------------
-- projects — formalizes work_items.project_association into an entity.
-- Slug regex enforced at the application layer (same shape as
-- work_items.slug): ^[a-z0-9-]+$. Not a CHECK so it can be relaxed
-- without surgery.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.projects (
    slug             text PRIMARY KEY,
    name             text NOT NULL,
    description      text,
    root_directory   text,        -- nullable; workspace-mount hook
    archived         boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.projects IS
'Project entities referenced by work_items.project_association. Archive via the UI; hard delete is restricted while work_items reference the project.';

CREATE INDEX IF NOT EXISTS projects_archived_idx
    ON stewards.projects(archived) WHERE NOT archived;

-- ---------------------------------------------------------------------
-- pipelines — immutable templates.
--
-- stages: jsonb array. Each element is an object with:
--   name           text  required, unique within the pipeline
--   agent_family   text  required, refs stewards.agents
--   model          text  required (the requested model)
--   provider       text  required (e.g., 'opencode_go', 'lm_studio')
--   input_template text  optional; {{input.x}} / {{stage_results.y}}
--                        placeholders rendered at dispatch
--   next           text  next stage name; NULL/missing for terminal
--   auto_advance   bool  default true; false = stop at awaiting_review
--
-- promote_to_doc: completed work_items on this pipeline are upserted
-- into stewards.docs by work_item_promote_to_doc (replaces the old
-- hardcoded LIKE 'study-write%' trigger guard — pipeline families are
-- operator data; behavior flags belong on the row).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.pipelines (
    family       text PRIMARY KEY
                 CHECK (family ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    description  text NOT NULL DEFAULT '',
    stages       jsonb NOT NULL
                 CHECK (jsonb_typeof(stages) = 'array'
                        AND jsonb_array_length(stages) >= 1),
    metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
    promote_to_doc boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.pipelines IS
'Pipeline definitions. Each row is an immutable template describing the stages of a multi-step agent flow. work_items are instances that traverse a pipeline''s stages.';

COMMENT ON COLUMN stewards.pipelines.promote_to_doc IS
'When true, work_items that complete on this pipeline are upserted into stewards.docs via work_item_promote_to_doc (the last stage''s output is the publishable body).';

-- ---------------------------------------------------------------------
-- work_items — instances flowing through pipeline stages.
--
-- Status lifecycle:
--   pending          — created, current_stage not yet dispatched
--   in_progress      — current_stage's chat dispatched
--   awaiting_review  — stage completed; human ack needed (auto_advance
--                      off, token budget hit, or dispatch failure)
--   completed        — all stages done; terminal
--   failed           — error encountered; recoverable via human
--   cancelled        — terminal, intentional stop
--
-- origin: who created this work_item. 'agent_planning' rows are
-- proposals from a planning run; 'agent_proposal' from the
-- agent-proposal pipeline. parent_work_item_id points proposed items
-- back at the run that proposed them (ON DELETE SET NULL).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.work_items (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug            text UNIQUE,
    pipeline_family text NOT NULL
                    REFERENCES stewards.pipelines(family) ON DELETE RESTRICT,
    current_stage   text NOT NULL,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'in_progress',
                                       'awaiting_review', 'completed',
                                       'failed', 'cancelled')),
    -- Opening inputs — the user-supplied data the first stage works on.
    input           jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Per-stage outputs accumulate here keyed by stage name:
    --   {"outline": {"output": "...", "completed_at": "...",
    --                "tokens_in": N, "tokens_out": N}, ...}
    stage_results   jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- All chat session ids spawned by this work_item (one per stage).
    session_ids     text[] NOT NULL DEFAULT ARRAY[]::text[],
    -- Cost guards (06-cost maintains the micro-dollar columns via the
    -- cost_events trigger; born here so the table is complete)
    token_budget    int,
    tokens_in       int NOT NULL DEFAULT 0,
    tokens_out      int NOT NULL DEFAULT 0,
    cost_micro_dollars  bigint NOT NULL DEFAULT 0,
    cost_cap_micro      bigint,
    cost_capped_at      timestamptz,
    -- Model/provider pins + human-mediated escalation queue (06-cost +
    -- 07-steward machinery)
    model_override  text,
    provider_override text,
    -- Steward failure tracking (07-steward maintains these)
    failure_count           int NOT NULL DEFAULT 0,
    last_failure_reason     text,
    last_failure_diagnosis  text,
    quarantined_at          timestamptz,
    quarantine_reason       text,
    escalation_state    text NOT NULL DEFAULT 'normal'
                    CONSTRAINT work_items_escalation_state_check
                    CHECK (escalation_state IN ('normal','queued',
                                                 'in_progress','failed',
                                                 'resolved')),
    escalation_claimed_by   text,
    escalation_claimed_at   timestamptz,
    escalation_completed_at timestamptz,
    escalation_attempts     int NOT NULL DEFAULT 0,
    -- Provenance + planning (h3-1, born here)
    origin          text NOT NULL DEFAULT 'human'
                    CONSTRAINT work_items_origin_check
                    CHECK (origin = ANY (ARRAY[
                        'human', 'scheduled', 'watchman', 'steward',
                        'council', 'agent_planning', 'agent_proposal'
                    ])),
    project_association text
                    CONSTRAINT work_items_project_association_fkey
                    REFERENCES stewards.projects(slug)
                    ON UPDATE CASCADE
                    ON DELETE RESTRICT,
    parent_work_item_id uuid
                    CONSTRAINT work_items_parent_work_item_fk
                    REFERENCES stewards.work_items(id)
                    ON DELETE SET NULL,
    -- Audit
    actor           text NOT NULL DEFAULT 'human',
    error           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz
);

CREATE INDEX IF NOT EXISTS work_items_status_idx
    ON stewards.work_items (status, created_at DESC);
CREATE INDEX IF NOT EXISTS work_items_pipeline_idx
    ON stewards.work_items (pipeline_family);
CREATE INDEX IF NOT EXISTS work_items_active_idx
    ON stewards.work_items (created_at DESC)
    WHERE status NOT IN ('completed', 'cancelled');
CREATE INDEX IF NOT EXISTS work_items_origin_idx
    ON stewards.work_items(origin);
CREATE INDEX IF NOT EXISTS work_items_project_association_idx
    ON stewards.work_items(project_association)
    WHERE project_association IS NOT NULL;
CREATE INDEX IF NOT EXISTS work_items_parent_work_item_idx
    ON stewards.work_items(parent_work_item_id)
    WHERE parent_work_item_id IS NOT NULL;

COMMENT ON TABLE stewards.work_items IS
'Instances flowing through a pipeline''s stages. Each stage''s output is recorded in stage_results keyed by stage name. session_ids carries the chat session id per dispatched stage so the full message history is reachable via `SELECT * FROM messages WHERE session_id = ANY(work_item.session_ids)`.';

COMMENT ON COLUMN stewards.work_items.project_association IS
'Optional project this work belongs to. FK to stewards.projects: ON UPDATE CASCADE propagates slug renames; ON DELETE RESTRICT prevents deleting a project with work_items (archive instead).';

-- ---------------------------------------------------------------------
-- Stage helpers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.pipeline_stage_lookup(
    p_family     text,
    p_stage_name text
) RETURNS jsonb
LANGUAGE sql STABLE AS $func$
    SELECT s
      FROM stewards.pipelines p,
           jsonb_array_elements(p.stages) AS s
     WHERE p.family = p_family
       AND s->>'name' = p_stage_name
     LIMIT 1;
$func$;

CREATE OR REPLACE FUNCTION stewards.pipeline_first_stage_name(p_family text)
RETURNS text
LANGUAGE sql STABLE AS $func$
    SELECT (stages->0)->>'name'
      FROM stewards.pipelines
     WHERE family = p_family;
$func$;

CREATE OR REPLACE FUNCTION stewards.pipeline_last_stage_name(p_family text)
RETURNS text
LANGUAGE sql STABLE AS $func$
    SELECT (stages->(jsonb_array_length(stages) - 1))->>'name'
      FROM stewards.pipelines
     WHERE family = p_family;
$func$;

COMMENT ON FUNCTION stewards.pipeline_last_stage_name(text) IS
'Name of the pipeline''s terminal stage. work_item_promote_to_doc reads the publishable body from this stage''s output (replaces the old hardcoded ''review'' stage name).';

-- ---------------------------------------------------------------------
-- work_item_create(pipeline, input, slug?, actor?, token_budget?)
--
-- Creates a new work_item with status='pending', current_stage =
-- pipeline's first stage. Does NOT auto-dispatch; caller decides when
-- via work_item_dispatch_stage() (or the auto-advance trigger).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_create(
    p_pipeline_family text,
    p_input           jsonb DEFAULT '{}'::jsonb,
    p_slug            text  DEFAULT NULL,
    p_actor           text  DEFAULT 'human',
    p_token_budget    int   DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_first_stage text;
    v_id          uuid;
BEGIN
    SELECT stewards.pipeline_first_stage_name(p_pipeline_family)
      INTO v_first_stage;
    IF v_first_stage IS NULL THEN
        RAISE EXCEPTION
            'work_item_create: pipeline % not found or has no stages',
            p_pipeline_family;
    END IF;

    -- Expose today's date to stage templates ({{input.today}}); the resolver
    -- hard-fails on a missing field. (See the 6-arg overload in 09.)
    IF NOT (p_input ? 'today') THEN
        p_input := p_input || jsonb_build_object('today', to_char(current_date, 'YYYY-MM-DD'));
    END IF;

    INSERT INTO stewards.work_items
        (pipeline_family, current_stage, slug, input, actor, token_budget)
    VALUES
        (p_pipeline_family, v_first_stage, p_slug, p_input, p_actor, p_token_budget)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_create(text, jsonb, text, text, int) IS
'Create a new work_item bound to a pipeline. Status starts ''pending'' with current_stage = first stage in the pipeline definition. Caller dispatches with work_item_dispatch_stage().';

-- ---------------------------------------------------------------------
-- Stage input templating.
--
-- resolve_template_path walks a {{root.a.b.c}} path against
-- work_item.input or work_item.stage_results, erroring loudly on
-- missing paths so template bugs surface at dispatch, not in agent
-- output. render_stage_input renders the current stage's
-- input_template; NULL when the stage has no template (caller falls
-- back).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.resolve_template_path(
    p_input         jsonb,
    p_stage_results jsonb,
    p_path          text
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_parts text[];
    v_root  text;
    v_value jsonb;
    i       int;
BEGIN
    v_parts := string_to_array(trim(p_path), '.');
    IF cardinality(v_parts) < 1 OR v_parts[1] IS NULL OR v_parts[1] = '' THEN
        RAISE EXCEPTION
            'resolve_template_path: empty path';
    END IF;

    v_root := v_parts[1];
    IF v_root = 'input' THEN
        v_value := p_input;
    ELSIF v_root = 'stage_results' THEN
        v_value := p_stage_results;
    ELSE
        RAISE EXCEPTION
            'resolve_template_path: unknown root % in path %; expected "input" or "stage_results"',
            v_root, p_path;
    END IF;

    -- Walk the rest of the path through nested jsonb objects.
    FOR i IN 2..cardinality(v_parts) LOOP
        IF v_value IS NULL OR jsonb_typeof(v_value) <> 'object' THEN
            RAISE EXCEPTION
                'resolve_template_path: path % not resolvable; stopped at %',
                p_path, v_parts[i-1];
        END IF;
        v_value := v_value -> v_parts[i];
    END LOOP;

    IF v_value IS NULL THEN
        RAISE EXCEPTION
            'resolve_template_path: path % resolved to NULL', p_path;
    END IF;

    -- Strings unwrap (no quotes); other types stringify.
    IF jsonb_typeof(v_value) = 'string' THEN
        RETURN v_value #>> '{}';
    ELSE
        RETURN v_value::text;
    END IF;
END;
$func$;

COMMENT ON FUNCTION stewards.resolve_template_path(jsonb, jsonb, text) IS
'Walk a {{root.a.b.c}} template path against work_item.input or work_item.stage_results. Errors loudly on missing paths so template bugs surface at dispatch, not in agent output.';

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
        -- whitespace tolerance via a regex_replace).
        v_rendered := regexp_replace(
            v_rendered,
            '\{\{\s*' || regexp_replace(v_path, '([\\.()|*+?\[\]{}^$])', '\\\1', 'g') || '\s*\}\}',
            v_value,
            'g'
        );
    END LOOP;

    RETURN v_rendered;
END;
$func$;

COMMENT ON FUNCTION stewards.render_stage_input(uuid) IS
'Render the current stage''s input_template against work_item state. Returns NULL if the stage has no template (caller falls back).';

-- ---------------------------------------------------------------------
-- work_item_dispatch_stage(work_item_id, user_input?, allow_failed?)
--
-- Composes input + payload + enqueues a chat work_queue row for the
-- work_item's current_stage. Sets status='in_progress'. Builds the
-- payload directly (not via chat_enqueue) so it can inject the
-- _work_item_id / _stage_name markers the auto-advance trigger reads.
--
-- Honors work_items.model_override + provider_override (the steward's
-- one-shot pins). p_allow_failed_status=true unlocks re-dispatch from
-- status='failed' (steward retries pass true; other call sites stay
-- safe by passing nothing). failure_count is NOT reset on dispatch —
-- it tracks consecutive failures and resets only when a stage
-- genuinely advances.
--
-- Input resolution priority:
--   1. Explicit p_user_input override (CLI --user-input, or the
--      steward's retry guidance).
--   2. Stage's input_template rendered against work_item state.
--   3. work_item.input.user_input field (legacy fallback).
--   4. Stringified work_item.input (last-resort fallback).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_dispatch_stage(
    p_work_item_id           uuid,
    p_user_input             text DEFAULT NULL,
    p_allow_failed_status    boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_stage       jsonb;
    v_agent       text;
    v_model       text;
    v_provider    text;
    v_session_id  text;
    v_user_input  text;
    v_body        jsonb;
    v_payload     jsonb;
    v_work_id     bigint;
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

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    v_agent    := v_stage->>'agent_family';
    -- Model + provider honor the work_item's one-shot overrides.
    v_model    := COALESCE(v_wi.model_override,    v_stage->>'model');
    v_provider := COALESCE(v_wi.provider_override, v_stage->>'provider');
    IF v_agent IS NULL OR v_model IS NULL OR v_provider IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % missing agent_family/model/provider',
            p_work_item_id, v_wi.current_stage;
    END IF;

    -- Session id pattern: wi--<short-uuid>--<stage>, capped at 200.
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
        -- Markers read by the auto-advance trigger:
        '_work_item_id',      p_work_item_id::text,
        '_stage_name',        v_wi.current_stage,
        '_pipeline_family',   v_wi.pipeline_family
    );

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
$func$;

COMMENT ON FUNCTION stewards.work_item_dispatch_stage(uuid, text, boolean) IS
'Dispatch the current stage. Honors work_items.model_override + provider_override; p_allow_failed_status=true unlocks steward re-dispatch from status=failed. Composes the chat body via dry_run_chat, enqueues a kind=chat work_queue row with _work_item_id/_stage_name markers, and sets status=in_progress.';

-- ---------------------------------------------------------------------
-- work_item_advance(work_item_id, stage_output)
--
-- Records the current stage's output, finds the next stage, and either
-- advances current_stage (status pending | awaiting_review per the
-- completing stage's auto_advance) or marks the work_item completed.
-- Returns the next stage name, or NULL if completed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_advance(
    p_work_item_id uuid,
    p_stage_output jsonb DEFAULT '{}'::jsonb
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_stage       jsonb;
    v_next_name   text;
    v_auto_advance bool;
    v_results     jsonb;
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

    v_next_name := v_stage->>'next';
    -- coalesce missing/null auto_advance to true
    v_auto_advance := coalesce((v_stage->>'auto_advance')::bool, true);

    -- Record this stage's output keyed by stage name.
    v_results := v_wi.stage_results
              || jsonb_build_object(v_wi.current_stage,
                     p_stage_output
                     || jsonb_build_object('completed_at', now()));

    IF v_next_name IS NULL OR v_next_name = '' THEN
        -- Terminal: no next stage.
        UPDATE stewards.work_items
           SET stage_results = v_results,
               status        = 'completed',
               completed_at  = now(),
               updated_at    = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    -- Validate next stage exists in the pipeline.
    IF stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_next_name) IS NULL THEN
        RAISE EXCEPTION
            'work_item %: stage %s `next` references missing stage %',
            p_work_item_id, v_wi.current_stage, v_next_name;
    END IF;

    UPDATE stewards.work_items
       SET stage_results = v_results,
           current_stage = v_next_name,
           status        = CASE WHEN v_auto_advance THEN 'pending'
                                ELSE 'awaiting_review' END,
           updated_at    = now()
     WHERE id = p_work_item_id;

    RETURN v_next_name;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_advance(uuid, jsonb) IS
'Record the current stage''s output and transition to the next stage (or mark completed if terminal). Returns next stage name or NULL.';

-- ---------------------------------------------------------------------
-- work_item_fail / work_item_cancel
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_fail(
    p_work_item_id uuid,
    p_error        text
) RETURNS void
LANGUAGE plpgsql AS $func$
BEGIN
    UPDATE stewards.work_items
       SET status     = 'failed',
           error      = p_error,
           -- #326 root (2026-07-05): steward_tick/diagnose_failure read
           -- last_failure_reason, but this path only wrote `error` — so every
           -- chat-dispatch failure (e.g. a provider-wrapped upstream 400) was
           -- INVISIBLE to the whole failover/retry machinery: diagnosis ran on
           -- NULL → 'unknown' → no transient retry, ever. Record both.
           last_failure_reason = p_error,
           updated_at = now()
     WHERE id = p_work_item_id
       AND status NOT IN ('completed', 'cancelled');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'work_item_fail: % not found or already in terminal status',
            p_work_item_id;
    END IF;
END;
$func$;

CREATE OR REPLACE FUNCTION stewards.work_item_cancel(
    p_work_item_id uuid,
    p_reason       text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $func$
BEGIN
    UPDATE stewards.work_items
       SET status       = 'cancelled',
           error        = coalesce(p_reason, error),
           updated_at   = now(),
           completed_at = now()
     WHERE id = p_work_item_id
       AND status NOT IN ('completed', 'cancelled');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'work_item_cancel: % not found or already in terminal status',
            p_work_item_id;
    END IF;
END;
$func$;

-- ---------------------------------------------------------------------
-- handle_work_item_chat_completion — the auto-advance trigger.
--
-- When a chat dispatched by work_item_dispatch_stage lands done/error:
--   1. Rolls up tokens into the parent work_item (always — including
--      intermediate tool-loop iterations; continuation chats inherit
--      the _* markers via chat_post_internal).
--   2. Detects final (clean stop / loop stop) vs intermediate (chat
--      handler enqueued a tool_dispatch continuation).
--   3. On final: work_item_advance with structured stage_output, then
--      auto-dispatch the next stage subject to auto_advance + token
--      budget gates; failures park at awaiting_review.
--   4. On error: work_item_fail.
--
-- Every clause of the final-detection is NULL-guarded (the original
-- version let `NULL IN (...)` poison the boolean and advanced on
-- intermediate chats). Defensive everywhere: a bug in the harvester
-- never breaks the bgworker's status flip.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.handle_work_item_chat_completion()
RETURNS trigger
LANGUAGE plpgsql AS $func$
DECLARE
    v_work_item_id    uuid;
    v_stage_name      text;
    v_session_id      text;
    v_assistant       stewards.messages%ROWTYPE;
    v_finish_reason   text;
    v_loop_stop       text;
    v_has_tool_calls  boolean;
    v_is_final        boolean;
    v_stage_output    jsonb;
    v_next_stage      text;
    v_wi_after        stewards.work_items%ROWTYPE;
    v_msg_tokens_in   int;
    v_msg_tokens_out  int;
BEGIN
    -- WHEN clause prefilters; this is belt-and-suspenders.
    IF NEW.kind <> 'chat'
       OR (NEW.payload->>'_work_item_id') IS NULL THEN
        RETURN NEW;
    END IF;
    IF NEW.status NOT IN ('done', 'error') THEN
        RETURN NEW;
    END IF;
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    v_work_item_id := (NEW.payload->>'_work_item_id')::uuid;
    v_stage_name   := NEW.payload->>'_stage_name';
    v_session_id   := NEW.payload->>'session_id';

    -- Error path: fail the work_item.
    IF NEW.status = 'error' THEN
        BEGIN
            PERFORM stewards.work_item_fail(
                v_work_item_id,
                format('chat dispatch failed at stage %s: %s',
                       v_stage_name,
                       coalesce(NEW.error, '(no error msg)')));
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING
                'work_item trigger work_item_fail() failed for %: %',
                v_work_item_id, SQLERRM;
        END;
        RETURN NEW;
    END IF;

    -- Done path: read the latest assistant message.
    SELECT * INTO v_assistant
      FROM stewards.messages
     WHERE session_id = v_session_id AND role = 'assistant'
     ORDER BY id DESC LIMIT 1;

    IF v_assistant.id IS NULL THEN
        BEGIN
            PERFORM stewards.work_item_fail(
                v_work_item_id,
                format('no assistant message for stage %s session %s',
                       v_stage_name, v_session_id));
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RETURN NEW;
    END IF;

    -- Token rollup — applies to BOTH intermediate and final chats.
    v_msg_tokens_in  := coalesce(v_assistant.tokens_in,  0);
    v_msg_tokens_out := coalesce(v_assistant.tokens_out, 0)
                      + coalesce(v_assistant.reasoning_tokens, 0);

    UPDATE stewards.work_items
       SET tokens_in  = tokens_in  + v_msg_tokens_in,
           tokens_out = tokens_out + v_msg_tokens_out,
           updated_at = now()
     WHERE id = v_work_item_id;

    -- Final-vs-intermediate detection. Every clause NULL-guarded so
    -- the whole expression collapses to a true boolean (never NULL).
    v_finish_reason  := v_assistant.finish_reason;
    v_loop_stop      := NEW.result->>'loop_stop_reason';
    v_has_tool_calls := v_assistant.tool_calls IS NOT NULL
                        AND jsonb_typeof(v_assistant.tool_calls) = 'array'
                        AND jsonb_array_length(v_assistant.tool_calls) > 0;

    v_is_final := coalesce(
        (NOT v_has_tool_calls
         AND v_finish_reason IS NOT NULL
         AND v_finish_reason IN ('stop', 'length', 'content_filter'))
        OR (v_loop_stop IS NOT NULL
            AND v_loop_stop IN ('steps_exhausted', 'truncated_tool_calls')),
        false
    );

    IF NOT v_is_final THEN
        RETURN NEW;
    END IF;

    -- Build stage output. Includes loop_stop_reason when present so
    -- downstream stages can see "the prior stage hit step budget."
    v_stage_output := jsonb_build_object(
        'output',           v_assistant.content,
        'model',            v_assistant.model,
        'tokens_in',        v_msg_tokens_in,
        'tokens_out',       v_msg_tokens_out,
        'finish_reason',    v_finish_reason
    );
    IF v_loop_stop IS NOT NULL THEN
        v_stage_output := v_stage_output
            || jsonb_build_object('loop_stop_reason', v_loop_stop);
    END IF;

    BEGIN
        v_next_stage := stewards.work_item_advance(v_work_item_id, v_stage_output);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING
            'work_item trigger work_item_advance() failed for %: %',
            v_work_item_id, SQLERRM;
        BEGIN
            PERFORM stewards.work_item_fail(v_work_item_id,
                'auto-advance failed: ' || SQLERRM);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RETURN NEW;
    END;

    -- Terminal stage → work_item is now status=completed. Done.
    IF v_next_stage IS NULL THEN
        RETURN NEW;
    END IF;

    -- Re-fetch to check status. Only auto-dispatch when 'pending'
    -- (auto_advance=false on the completing stage parks at
    -- awaiting_review).
    SELECT * INTO v_wi_after FROM stewards.work_items WHERE id = v_work_item_id;
    IF v_wi_after.status <> 'pending' THEN
        RETURN NEW;
    END IF;

    -- Token budget gate (cost guard).
    IF v_wi_after.token_budget IS NOT NULL
       AND (v_wi_after.tokens_in + v_wi_after.tokens_out)
            >= v_wi_after.token_budget THEN
        UPDATE stewards.work_items
           SET status     = 'awaiting_review',
               error      = format(
                   'token budget exhausted at stage %s (%s/%s); '
                   || 'next stage %s not auto-dispatched',
                   v_stage_name,
                   v_wi_after.tokens_in + v_wi_after.tokens_out,
                   v_wi_after.token_budget,
                   v_next_stage),
               updated_at = now()
         WHERE id = v_work_item_id;
        RETURN NEW;
    END IF;

    -- Auto-dispatch next stage. If dispatch fails, mark awaiting_review
    -- (the prior stage's results are valid; the human decides).
    BEGIN
        PERFORM stewards.work_item_dispatch_stage(v_work_item_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING
            'work_item trigger dispatch_stage() failed for %: %',
            v_work_item_id, SQLERRM;
        UPDATE stewards.work_items
           SET status     = 'awaiting_review',
               error      = format('auto-dispatch of stage %s failed: %s',
                                   v_next_stage, SQLERRM),
               updated_at = now()
         WHERE id = v_work_item_id;
    END;

    RETURN NEW;
END;
$func$;

COMMENT ON FUNCTION stewards.handle_work_item_chat_completion() IS
'AFTER UPDATE trigger function on work_queue. When a chat row dispatched by work_item_dispatch_stage() lands done/error, advances the parent work_item: rolls up tokens, detects intermediate-vs-final, calls work_item_advance, and auto-dispatches the next stage (subject to token_budget + auto_advance gates). All side effects in the same tx as the work_queue status flip.';

-- Drop and recreate the trigger so re-applying this file is idempotent.
DROP TRIGGER IF EXISTS work_item_advance_completion ON stewards.work_queue;

CREATE TRIGGER work_item_advance_completion
    AFTER UPDATE OF status ON stewards.work_queue
    FOR EACH ROW
    WHEN ((NEW.kind = 'chat')
          AND (NEW.payload ? '_work_item_id')
          AND (NEW.status IN ('done', 'error'))
          AND (OLD.status IS DISTINCT FROM NEW.status))
    EXECUTE FUNCTION stewards.handle_work_item_chat_completion();

-- ---------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.work_items_active AS
SELECT id, slug, pipeline_family, current_stage, status,
       jsonb_object_keys(stage_results) AS completed_stage,
       cardinality(session_ids) AS sessions_dispatched,
       tokens_in, tokens_out, token_budget, actor,
       created_at, updated_at
  FROM stewards.work_items
 WHERE status NOT IN ('completed', 'cancelled');

CREATE OR REPLACE VIEW stewards.work_items_summary AS
SELECT wi.id,
       wi.slug,
       wi.pipeline_family,
       wi.current_stage,
       wi.status,
       wi.created_at,
       wi.updated_at,
       wi.completed_at,
       (wi.completed_at - wi.created_at) AS elapsed,
       wi.tokens_in,
       wi.tokens_out,
       wi.token_budget,
       cardinality(wi.session_ids)            AS stages_dispatched,
       (SELECT count(*) FROM jsonb_object_keys(wi.stage_results)) AS stages_completed,
       (SELECT jsonb_array_length(p.stages) FROM stewards.pipelines p
         WHERE p.family = wi.pipeline_family) AS stages_total,
       wi.actor,
       wi.error
  FROM stewards.work_items wi;

-- ---------------------------------------------------------------------
-- Doc tools: doc_search + doc_get (the corpus surface agents use).
-- The other three tool wrappers below front functions owned by other
-- subsystems (doc_similar, doc_citations, context_for).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.doc_search(
    p_query text,
    p_kinds text[] DEFAULT ARRAY[]::text[],
    p_limit int DEFAULT 10
) RETURNS TABLE (
    slug    text,
    kind    text,
    title   text,
    snippet text,
    rank    real
)
LANGUAGE sql STABLE AS $func$
    SELECT s.slug,
           s.kind,
           s.title,
           ts_headline('english', coalesce(s.body, ''), q,
                       'MaxWords=20, MinWords=10, ShortWord=3') AS snippet,
           ts_rank(s.body_tsv, q) AS rank
      FROM stewards.docs s,
           websearch_to_tsquery('english', p_query) q
     WHERE s.body_tsv @@ q
       AND (cardinality(p_kinds) = 0 OR s.kind = ANY(p_kinds))
     ORDER BY rank DESC
     LIMIT greatest(p_limit, 1);
$func$;

COMMENT ON FUNCTION stewards.doc_search(text, text[], int) IS
'FTS over stewards.docs.body_tsv. Multi-kind filter via array (empty = all). Ordered by ts_rank.';

CREATE OR REPLACE FUNCTION stewards.doc_get(
    p_slug          text,
    p_include_body  boolean DEFAULT true,
    p_line_offset   int     DEFAULT 0,
    p_line_count    int     DEFAULT 200,
    p_max_chars     int     DEFAULT 20000
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_doc             stewards.docs%ROWTYPE;
    v_lines           text[];
    v_total_lines     int;
    v_actual_count    int;
    v_body_slice      text;
    v_truncated       bool := false;
    v_citation_count  int;
    v_result          jsonb;
BEGIN
    SELECT * INTO v_doc FROM stewards.docs WHERE slug = p_slug;
    IF v_doc.id IS NULL THEN
        RETURN jsonb_build_object(
            'error', format('doc not found: %s', p_slug));
    END IF;

    SELECT count(*)::int INTO v_citation_count
      FROM stewards.doc_citations(p_slug);

    v_result := jsonb_build_object(
        'slug',           v_doc.slug,
        'kind',           v_doc.kind,
        'title',          v_doc.title,
        'frontmatter',    coalesce(v_doc.frontmatter, '{}'::jsonb),
        'citation_count', v_citation_count
    );

    IF p_include_body THEN
        v_lines := string_to_array(coalesce(v_doc.body, ''), E'\n');
        v_total_lines := cardinality(v_lines);

        IF p_line_offset < 0 THEN p_line_offset := 0; END IF;
        IF p_line_count < 1  THEN p_line_count  := 200; END IF;

        v_actual_count := least(
            p_line_count,
            greatest(0, v_total_lines - p_line_offset)
        );

        IF v_actual_count > 0 THEN
            v_body_slice := array_to_string(
                v_lines[p_line_offset + 1 : p_line_offset + v_actual_count],
                E'\n'
            );
        ELSE
            v_body_slice := '';
        END IF;

        IF p_max_chars > 0 AND length(v_body_slice) > p_max_chars THEN
            v_body_slice := substring(v_body_slice FROM 1 FOR p_max_chars);
            v_truncated  := true;
        END IF;

        v_result := v_result
            || jsonb_build_object(
                'body',                    v_body_slice,
                'body_line_offset',        p_line_offset,
                'body_lines_returned',     v_actual_count,
                'body_total_lines',        v_total_lines,
                'body_truncated_by_chars', v_truncated
            );
    ELSE
        -- Surface the line count even when body is omitted, so the
        -- agent can decide whether to fetch and at what offset.
        v_lines := string_to_array(coalesce(v_doc.body, ''), E'\n');
        v_result := v_result
            || jsonb_build_object(
                'body_total_lines', cardinality(v_lines)
            );
    END IF;

    RETURN v_result;
END;
$func$;

COMMENT ON FUNCTION stewards.doc_get(text, boolean, int, int, int) IS
'Read a doc + frontmatter + citation count + (optional) body with line-based pagination. Mirrors the Read tool''s offset/limit semantics. Returns jsonb.';

-- ---------------------------------------------------------------------
-- Tool wrappers (jsonb → jsonb). All decode args from the model's
-- tool_call.arguments jsonb, apply defaults, and call the underlying
-- typed function.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.doc_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.doc_search(
        p_args->>'query',
        coalesce(
            (SELECT array_agg(value::text)
               FROM jsonb_array_elements_text(coalesce(p_args->'kinds', '[]'::jsonb)) AS value),
            ARRAY[]::text[]
        ),
        coalesce((p_args->>'limit')::int, 10)
    ) t;
$func$;

CREATE OR REPLACE FUNCTION stewards.doc_get_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT stewards.doc_get(
        p_args->>'slug',
        coalesce((p_args->>'include_body')::boolean, true),
        coalesce((p_args->>'body_line_offset')::int, 0),
        coalesce((p_args->>'body_line_count')::int, 200),
        coalesce((p_args->>'max_body_chars')::int, 20000)
    );
$func$;

CREATE OR REPLACE FUNCTION stewards.doc_similar_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.doc_similar(
        p_args->>'slug',
        coalesce((p_args->>'limit')::int, 5)
    ) t
    WHERE coalesce((p_args->>'min_score')::float, 0.0) <= t.score;
$func$;

CREATE OR REPLACE FUNCTION stewards.doc_citations_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.doc_citations(p_args->>'slug') t;
$func$;

CREATE OR REPLACE FUNCTION stewards.doc_context_for_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.context_for(
        p_args->>'slug',
        coalesce((p_args->>'depth')::int, 2)
    ) t;
$func$;

-- ---------------------------------------------------------------------
-- tool_defs registrations
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target)
VALUES
(
    'doc_search',
    'Full-text search over the substrate''s document corpus. Returns ranked matches with slug, kind, title, snippet, and ts_rank score. Use this to find docs by topic before reading them with doc_get. Filter to specific kinds via the `kinds` array (kinds are operator-defined; empty = all). Backed by Postgres FTS over body_tsv.',
    '{
        "type": "object",
        "required": ["query"],
        "properties": {
            "query":  {"type": "string", "minLength": 1, "maxLength": 200,
                       "description": "Natural-language search terms. Phrases in quotes are matched verbatim."},
            "kinds":  {"type": "array",
                       "items": {"type": "string"},
                       "description": "Filter to one or more doc kinds (e.g. doc, proposal, journal). Empty/omitted = search all kinds."},
            "limit":  {"type": "integer", "minimum": 1, "maximum": 20,
                       "description": "Max results (default 10)."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_search_tool"}'::jsonb
),
(
    'doc_get',
    'Read a doc by slug. Returns title, frontmatter, citation count, and body with line-based pagination. The body slice is bounded by `body_line_count` (line-aligned, no mid-word splits) AND `max_body_chars` (hard cap that wins if the slice is dense). For long docs, paginate via `body_line_offset = previous_offset + body_lines_returned` until `body_total_lines` is reached. Set `include_body=false` to fetch only metadata + total line count.',
    '{
        "type": "object",
        "required": ["slug"],
        "properties": {
            "slug":             {"type": "string", "description": "Doc slug (e.g. \"charity\", \"proposal-token-efficiency\")."},
            "include_body":     {"type": "boolean", "description": "Default true. Set false for metadata only."},
            "body_line_offset": {"type": "integer", "minimum": 0, "description": "Lines to skip before the slice (default 0)."},
            "body_line_count":  {"type": "integer", "minimum": 1, "maximum": 1000, "description": "Max lines per call (default 200)."},
            "max_body_chars":   {"type": "integer", "minimum": 100, "maximum": 50000, "description": "Hard char cap on the returned slice (default 20000)."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_get_tool"}'::jsonb
),
(
    'doc_similar',
    'Return docs semantically similar to the given slug, using precomputed pgvector cosine similarity edges. No on-the-fly embedding; cheap. Each result has a score (0..1, higher = more similar) and direction (outgoing | incoming | mutual). Use after doc_search to expand a topic''s neighborhood.',
    '{
        "type": "object",
        "required": ["slug"],
        "properties": {
            "slug":      {"type": "string"},
            "limit":     {"type": "integer", "minimum": 1, "maximum": 10, "description": "Max neighbors (default 5)."},
            "min_score": {"type": "number",  "minimum": 0,  "maximum": 1, "description": "Filter results below this score."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_similar_tool"}'::jsonb
),
(
    'doc_citations',
    'Return the canonical sources cited by a doc. Backed by CITES edges in the relational graph, parsed from markdown links during import. Returns cited_uri, cited_kind (external | doc), anchor_text (the link text the doc used), and citation_count (how many times that uri appears).',
    '{
        "type": "object",
        "required": ["slug"],
        "properties": {
            "slug": {"type": "string"}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_citations_tool"}'::jsonb
),
(
    'doc_context_for',
    'Walk the relational graph outward from a doc, returning typed-edge neighbors up to `depth` hops. Surfaces structural connections (workstream, doc, todo nodes via HAS_PROPOSAL, FEEDS, SUPERSEDES, IMPLEMENTS, HAS_TODO, HAS_PHASE edges) and semantic ones (CITES, SIMILAR_TO). Use this when "what''s connected to X?" is the question; use doc_similar when only semantic similarity is needed.',
    '{
        "type": "object",
        "required": ["slug"],
        "properties": {
            "slug":  {"type": "string"},
            "depth": {"type": "integer", "minimum": 1, "maximum": 4, "description": "Hops to walk (default 2). Capped at 4."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_context_for_tool"}'::jsonb
)
ON CONFLICT (name) DO UPDATE
SET description    = EXCLUDED.description,
    args_schema    = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target;

-- ---------------------------------------------------------------------
-- Broadcast: allow doc_* across all non-watchman agents.
--
-- The tools are read-only over substrate state; there's no destructive
-- risk in granting broad access. Watchman's deny-everything pattern is
-- preserved (it ships with its own tools=none design). glob_match:
-- `doc_*` beats `*: deny` via the longest-match-wins resolver.
--
-- Tagged source='broadcast' so the importer's reimport-DELETE
-- (filtered to source='frontmatter') doesn't wipe it. ON CONFLICT
-- updates only `action` to avoid downgrading a row the agent's
-- frontmatter has since declared explicitly.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
SELECT DISTINCT a.family, 'doc_*', 'allow', 'broadcast'
  FROM stewards.agents a
 WHERE a.family NOT LIKE 'watchman%'
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
SET action = EXCLUDED.action;

-- Provenance observability (3c.3.3).
CREATE OR REPLACE VIEW stewards.agent_tool_perms_by_source AS
SELECT source, count(*) AS row_count, count(DISTINCT agent_family) AS family_count
  FROM stewards.agent_tool_perms
 GROUP BY source;

-- ---------------------------------------------------------------------
-- Step budget for tool-using agents (3c.3.1 fix 3).
--
-- Real tool-using research routinely needs 20+ iterations; the agent
-- stops early on finish_reason='stop', so 50 is generous but safe.
-- Watchman agents stay at steps=1 (single-shot, no tools by design).
-- (B5 bakes steps=50 into seed_harness directly; this UPDATE then
-- covers only operator-imported agents.)
-- ---------------------------------------------------------------------
UPDATE stewards.agents
   SET steps = 50
 WHERE family NOT LIKE 'watchman%'
   AND steps < 50;

-- ---------------------------------------------------------------------
-- work_item_promote_to_doc — completed work_items land in the corpus.
--
-- Merged final form of 3c3-5 + 5e4 §1: flag-driven via
-- pipelines.promote_to_doc (was LIKE 'study-write%'), sabbath-gated
-- (refuses when the pipeline opts into sabbath and no reflection was
-- recorded — columns land later in the chain; the bundle installs
-- atomically so they exist before anything calls this), publishable
-- body read from the pipeline's LAST stage (was hardcoded 'review'),
-- title from input.binding_question, and the write goes through
-- import_doc so the doc node + CITES edges land in the graph (5e4's
-- live version had drifted to a direct INSERT that lost that sync).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_promote_to_doc(p_work_item_id uuid)
RETURNS text  -- the resulting slug, or NULL if not promotable
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_pipeline    stewards.pipelines%ROWTYPE;
    v_last_stage  text;
    v_body_text   text;
    v_slug        text;
    v_title       text;
    v_frontmatter jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF NOT FOUND THEN
        RAISE NOTICE 'work_item_promote_to_doc: % not found', p_work_item_id;
        RETURN NULL;
    END IF;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    -- Only promote completed work_items on pipelines that opt in.
    IF v_wi.status <> 'completed'
       OR v_pipeline.family IS NULL
       OR NOT v_pipeline.promote_to_doc THEN
        RETURN NULL;
    END IF;

    -- Sabbath gate (5e/D.5): if the pipeline opts into sabbath but the
    -- work_item never had a Sabbath reflection recorded, refuse
    -- promotion with a clear hint. The discipline is endings recorded.
    IF v_pipeline.sabbath_enabled AND v_wi.sabbath_completed_at IS NULL THEN
        RAISE EXCEPTION 'work_item_promote_to_doc: sabbath required before promotion for sabbath-enabled pipeline. Call stewards.sabbath_dispatch(%) first.', p_work_item_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- The last stage's `output` is the publishable body. If it's empty
    -- or trivially short, skip — early failures shouldn't pollute docs.
    v_last_stage := stewards.pipeline_last_stage_name(v_wi.pipeline_family);
    v_body_text  := v_wi.stage_results -> v_last_stage ->> 'output';
    IF v_body_text IS NULL OR length(v_body_text) < 100 THEN
        RETURN NULL;
    END IF;

    v_slug := coalesce(v_wi.slug, p_work_item_id::text);

    v_title := v_wi.input ->> 'binding_question';
    IF v_title IS NULL OR length(v_title) = 0 THEN
        v_title := v_slug;
    END IF;

    -- Frontmatter records provenance + cost so readers can distinguish
    -- substrate-produced docs from imported ones.
    v_frontmatter := jsonb_build_object(
        'pipeline',             v_wi.pipeline_family,
        'work_item_id',         v_wi.id::text,
        'completed_at',         v_wi.completed_at,
        'sabbath_completed_at', v_wi.sabbath_completed_at,
        'tokens_in',            v_wi.tokens_in,
        'tokens_out',           v_wi.tokens_out
    );

    PERFORM stewards.import_doc(
        v_slug,
        NULL,           -- no file on disk; substrate-produced
        v_title,
        v_body_text,
        v_frontmatter,
        'doc'
    );

    RETURN v_slug;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_promote_to_doc(uuid) IS
'Upserts a completed work_item into stewards.docs via the standard import_doc() path (doc node + CITES edges included). Promotable iff the pipeline has promote_to_doc=true, the work_item is completed, the sabbath gate passes, and the last stage''s output is non-trivial. Returns the resulting slug or NULL. Idempotent.';

-- Trigger — fires on the status→completed transition. The pipeline
-- flag lives on another table, so the WHEN clause only narrows to the
-- transition; the function itself checks promote_to_doc.
CREATE OR REPLACE FUNCTION stewards.work_item_promote_trigger()
RETURNS trigger LANGUAGE plpgsql AS $func$
BEGIN
    IF NEW.status = 'completed' AND coalesce(OLD.status, '') <> 'completed' THEN
        -- Promotion is a SIDE-EFFECT of completion, not part of it. Wrap it so a
        -- promote_to_doc failure logs loud but never aborts the completion — an
        -- unattended sabbath that completes many items must not be rolled back by
        -- one item's promotion hiccup. Matches the wrapped-side-effect pattern in
        -- reflect_drain_approved (22) + watchman_scheduler_fire (23). A systemic
        -- promotion failure still surfaces (the WARNING + the guard's consecutive-
        -- failure signal); it just can't take the primary state transition with it.
        BEGIN
            PERFORM stewards.work_item_promote_to_doc(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'work_item_promote_trigger: promote_to_doc failed for % (completion kept): %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS work_item_promote_trg ON stewards.work_items;
CREATE TRIGGER work_item_promote_trg
    AFTER UPDATE OF status ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.status = 'completed')
    EXECUTE FUNCTION stewards.work_item_promote_trigger();

-- ---------------------------------------------------------------------
-- Seed: echo-test pipeline (1 stage, smoke-test wiring). The agent
-- family / model / provider it names are operator data — the seed pack
-- ships matching example agents.
-- ---------------------------------------------------------------------
INSERT INTO stewards.pipelines (family, description, stages)
VALUES (
    'echo-test',
    'Single-stage smoke test. Dispatches one chat to verify the pipeline → work_item → chat → completion wiring.',
    jsonb_build_array(
        jsonb_build_object(
            'name',         'echo',
            'agent_family', 'research',
            'model',        'kimi-k2.6',
            'provider',     'opencode_go',
            'next',         null,
            'auto_advance', true
        )
    )
)
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description,
       stages      = EXCLUDED.stages,
       updated_at  = now();
-- ===== [was 05-mcp-bridge.sql] =====
-- =====================================================================
-- 05-mcp-bridge — the substrate's window to the external MCP world
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Sources folded, in original
-- ship order: 3e2-1 (server registry + tool cache), 3e2-2 (mcp_proxy
-- dispatch; its work_queue status-CHECK expansion was born back into
-- schema.rs), 3e2-3 (cache→tool_defs auto-promote), h1-5a
-- (mcp_proxy_enqueue soft-fail — the final form authored here), h1-7a
-- (fs-read + pg-ai-stewards self-surface seeds — these two binaries
-- ship WITH the substrate, so their registrations are core, not
-- overlay; external server seeds live in the operator's overlay).
--
-- The design, in one paragraph: the Rust bgworker stays reqwest-only;
-- a Go bridge daemon holds the MCP client sessions. stewards.mcp_servers
-- is the registry (stdio command or http url; secrets in env jsonb,
-- read only by the bridge). The bridge populates mcp_tool_cache via
-- tools/list, and a sync trigger auto-promotes active cache rows into
-- stewards.tool_defs with execute_target kind='mcp_proxy' —
-- deny-by-default, explicit agent grants required. At call time the
-- bgworker enqueues child work_queue rows of kind='mcp_proxy' (async
-- fan-out; the parent tool_dispatch parks at 'waiting_for_tools'), the
-- bridge claims children via LISTEN/NOTIFY, and
-- tool_dispatch_complete_waiting() promotes parents whose children all
-- resolved: insert role='tool' messages, enqueue the continuation chat.
-- =====================================================================

-- ---------------------------------------------------------------------
-- mcp_servers — registry of external MCP servers the bridge connects to.
-- Single source of truth for both the substrate (knows which tools are
-- routable) and the bridge (knows what to spawn/connect). Secrets
-- (bearer tokens, API keys) live in the env jsonb and are read only by
-- the bridge process — keep stewards role permissions tight.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.mcp_servers (
    name        text PRIMARY KEY
                CHECK (name ~ '^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$'),
    description text NOT NULL DEFAULT '',
    transport   text NOT NULL CHECK (transport IN ('stdio', 'http')),
    -- transport='stdio': command + args + env. Bridge spawns this
    -- binary and pipes JSON-RPC over stdin/stdout. command is an
    -- absolute path on the bridge's host (in-container for the
    -- shipped compose).
    command     text,
    args        text[] NOT NULL DEFAULT ARRAY[]::text[],
    -- transport='http': remote URL. Bridge speaks Streamable HTTP.
    url         text,
    -- Common: env vars passed to the spawned process (stdio) or as
    -- request headers (http).
    env         jsonb NOT NULL DEFAULT '{}'::jsonb,
    enabled     boolean NOT NULL DEFAULT false,
    -- Operational telemetry — bridge updates these on refresh / call.
    last_health_check_at  timestamptz,
    last_tools_refresh_at timestamptz,
    last_error            text,
    notes       text NOT NULL DEFAULT '',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    -- Transport-specific field validation:
    --   stdio MUST have command; http MUST have url.
    CONSTRAINT mcp_servers_transport_fields CHECK (
        (transport = 'stdio' AND command IS NOT NULL AND command <> '')
        OR
        (transport = 'http'  AND url IS NOT NULL AND url <> '')
    )
);

CREATE INDEX IF NOT EXISTS mcp_servers_enabled_idx
    ON stewards.mcp_servers (enabled) WHERE enabled;

COMMENT ON TABLE stewards.mcp_servers IS
  'Registry of external MCP servers the bridge daemon connects to. '
  'Single source of truth for both the substrate (knows which tools '
  'are routable) and the bridge (knows what to spawn/connect). Secrets '
  '(bearer tokens, API keys) live in the env jsonb and are read only '
  'by the bridge process.';

-- ---------------------------------------------------------------------
-- mcp_tool_cache — per-server tool catalog from tools/list. Populated
-- by the bridge at startup and on tools/list_changed notifications.
-- active=false hides a tool from agents without losing its schema
-- (e.g., during incident response when a server's tool misbehaves).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.mcp_tool_cache (
    server_name      text NOT NULL
                     REFERENCES stewards.mcp_servers(name) ON DELETE CASCADE,
    tool_name        text NOT NULL,
    description      text NOT NULL DEFAULT '',
    title            text,
    -- The MCP server's own JSON Schema for inputs; becomes
    -- tool_defs.args_schema at promotion.
    input_schema     jsonb NOT NULL,
    output_schema    jsonb,
    last_refreshed_at timestamptz NOT NULL DEFAULT now(),
    active           boolean NOT NULL DEFAULT true,
    PRIMARY KEY (server_name, tool_name)
);

CREATE INDEX IF NOT EXISTS mcp_tool_cache_active_idx
    ON stewards.mcp_tool_cache (active) WHERE active;

COMMENT ON TABLE stewards.mcp_tool_cache IS
  'Discovered tools from each MCP server, populated by the bridge daemon '
  'via tools/list at startup and on tools/list_changed notifications. '
  'The sync trigger auto-creates stewards.tool_defs rows from this cache, '
  'but agent_tool_perms defaults to deny — explicit grant required before '
  'agents can call any cached tool.';

-- ---------------------------------------------------------------------
-- mcp_bridge_state — at-a-glance bridge connectivity. After bridge
-- refresh-tools runs, active_tools should be > 0 for every enabled
-- server; last_error NULL means the most recent health check passed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.mcp_bridge_state AS
SELECT s.name AS server,
       s.transport,
       s.enabled,
       s.last_health_check_at,
       s.last_tools_refresh_at,
       coalesce((SELECT count(*) FROM stewards.mcp_tool_cache c
                  WHERE c.server_name = s.name AND c.active), 0) AS active_tools,
       s.last_error
  FROM stewards.mcp_servers s
 ORDER BY s.name;

-- ---------------------------------------------------------------------
-- mcp_proxy_enqueue — substrate-internal API (soft-fail final form).
--
-- Inserts a child work_queue row of kind='mcp_proxy' describing which
-- MCP server + tool to call and the tool's args. The provider column
-- carries the server name so operators can grep the queue. NOTIFY
-- wakes the bridge immediately. Returns the new row's id; the Rust
-- caller records it in the parent tool_dispatch's result jsonb so the
-- completion pass knows which child belongs to which tool_call_id.
--
-- Disabled/unregistered server → RAISE NOTICE + RETURN NULL (h1-5a).
-- A RAISE EXCEPTION here crashes the bgworker dispatcher via pgrx SPI
-- longjmp; NULL lets the Rust caller emit a structured tool-failure
-- reply the model can read and route around.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.mcp_proxy_enqueue(
    p_server   text,
    p_tool     text,
    p_args     jsonb,
    p_parent_tool_dispatch_id bigint  -- nullable; for synthetic tests
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    new_id bigint;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM stewards.mcp_servers
        WHERE name = p_server AND enabled
    ) THEN
        RAISE NOTICE 'mcp_proxy_enqueue: server % is not registered or not enabled — returning NULL', p_server;
        RETURN NULL;
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES (
        'mcp_proxy',
        p_server,
        jsonb_build_object(
            'server',                  p_server,
            'tool',                    p_tool,
            'args',                    p_args,
            'parent_tool_dispatch_id', p_parent_tool_dispatch_id
        )
    )
    RETURNING id INTO new_id;

    -- NOTIFY payload is the row id as text. Bridge LISTENs and uses it
    -- as a hint to immediately try claiming (it claims the OLDEST
    -- pending mcp_proxy regardless, so race-safe under concurrent
    -- producers).
    PERFORM pg_notify('stewards_mcp_proxy', new_id::text);

    RETURN new_id;
END;
$func$;

COMMENT ON FUNCTION stewards.mcp_proxy_enqueue(text, text, jsonb, bigint) IS
'Enqueue a child work_queue row of kind=mcp_proxy and notify the bridge daemon. Soft-fails (NOTICE + NULL) on a disabled/unregistered server — an EXCEPTION here would crash the bgworker via pgrx SPI longjmp. Synthetic callers (tests) can pass NULL for p_parent_tool_dispatch_id.';

-- ---------------------------------------------------------------------
-- tool_dispatch_complete_waiting — completion pass for async fan-out.
--
-- Scans tool_dispatch rows in 'waiting_for_tools', checks whether all
-- their mcp_proxy children are done/errored, and if so collects the
-- children's results, inserts role='tool' messages, enqueues the
-- continuation chat (chat_post_internal — markers inherit), and
-- transitions the parent to 'done'. The Rust tick loop calls this on
-- each tick. Implemented in SQL because the per-row logic is SPI-heavy
-- and already exists as SQL call sites.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.tool_dispatch_complete_waiting()
RETURNS integer
LANGUAGE plpgsql AS $func$
DECLARE
    parent_row    record;
    child_row     record;
    resolved_arr  jsonb;
    pending_arr   jsonb;
    pending_elem  jsonb;
    all_done      boolean;
    final_msgs    jsonb := '[]'::jsonb;
    completed_n   integer := 0;
    chat_work_id  bigint;
    parent_chat_id bigint;
    parent_session text;
    parent_family  text;
    parent_model   text;
    parent_provider text;
BEGIN
    -- SKIP LOCKED so concurrent workers running this same function
    -- don't block each other.
    FOR parent_row IN
        SELECT id, payload, result, provider
          FROM stewards.work_queue
         WHERE kind = 'tool_dispatch'
           AND status = 'waiting_for_tools'
         ORDER BY created_at
         FOR UPDATE SKIP LOCKED
    LOOP
        resolved_arr := coalesce(parent_row.result -> 'resolved', '[]'::jsonb);
        pending_arr  := coalesce(parent_row.result -> 'pending',  '[]'::jsonb);
        all_done := true;
        final_msgs := '[]'::jsonb;

        -- Re-merge resolved (sync) replies first.
        final_msgs := resolved_arr;

        -- For each pending entry, look up the child's status.
        FOR pending_elem IN SELECT * FROM jsonb_array_elements(pending_arr)
        LOOP
            SELECT id, status, result, error
              INTO child_row
              FROM stewards.work_queue
             WHERE id = (pending_elem ->> 'child_work_id')::bigint;

            IF child_row.status NOT IN ('done', 'error') THEN
                all_done := false;
                EXIT;
            END IF;

            -- Pull the tool reply content. Bridge stores result.content
            -- (string) on success, error column on failure. The model
            -- gets whichever surfaced.
            DECLARE
                content_text text;
            BEGIN
                IF child_row.status = 'done' THEN
                    content_text := child_row.result ->> 'content';
                    IF content_text IS NULL THEN
                        content_text := child_row.result::text;
                    END IF;
                ELSE
                    content_text := jsonb_build_object(
                        'error', child_row.error
                    )::text;
                END IF;

                final_msgs := final_msgs || jsonb_build_array(
                    jsonb_build_object(
                        'tc_id',   pending_elem ->> 'tc_id',
                        'name',    pending_elem ->> 'name',
                        'content', content_text
                    )
                );
            END;
        END LOOP;

        IF NOT all_done THEN
            CONTINUE;
        END IF;

        -- All children resolved; promote to done. Insert tool messages,
        -- enqueue the continuation chat.
        parent_chat_id  := (parent_row.payload ->> 'parent_work_id')::bigint;
        parent_session  := parent_row.payload ->> 'session_id';
        parent_family   := parent_row.payload ->> 'agent_family';
        parent_model    := parent_row.payload ->> 'model';
        parent_provider := parent_row.provider;

        FOR pending_elem IN SELECT * FROM jsonb_array_elements(final_msgs)
        LOOP
            INSERT INTO stewards.messages
                (session_id, role, content, tool_call_id, parent_work_id)
            VALUES (
                parent_session,
                'tool',
                pending_elem ->> 'content',
                pending_elem ->> 'tc_id',
                parent_row.id
            );
        END LOOP;

        SELECT stewards.chat_post_internal(
            parent_family, parent_model, parent_session, parent_provider
        ) INTO chat_work_id;

        UPDATE stewards.work_queue
           SET status = 'done',
               result = parent_row.result || jsonb_build_object(
                   'completed_at',     now()::text,
                   'next_chat_work_id', chat_work_id,
                   'final_tool_count',  jsonb_array_length(final_msgs)
               ),
               done_at = now()
         WHERE id = parent_row.id;

        completed_n := completed_n + 1;
    END LOOP;

    RETURN completed_n;
END;
$func$;

COMMENT ON FUNCTION stewards.tool_dispatch_complete_waiting IS
  'Completion pass for async-fan-out tool_dispatch. Bgworker calls '
  'this on each tick; rows whose mcp_proxy children have all '
  'resolved are promoted from waiting_for_tools to done with the '
  'usual side effects (insert tool messages + enqueue continuation '
  'chat).';

-- ---------------------------------------------------------------------
-- promote_mcp_tool_cache_to_tool_defs — bulk sync.
--
-- Upserts one tool_def per active cache row (description prefixed
-- "via <server>: ..."), soft-deactivates orphaned mcp_proxy tool_defs.
-- Idempotent. Bridge calls this at the end of refresh-tools; the
-- row-level trigger below keeps live consistency between refreshes.
--
-- Naming: bare tool_name (model-friendly, no slashes). Cross-server
-- collisions on tool_name would silently overwrite via ON CONFLICT —
-- a future correctness concern if two servers ship a same-named tool.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.promote_mcp_tool_cache_to_tool_defs()
RETURNS integer
LANGUAGE plpgsql AS $func$
DECLARE
    n_touched integer := 0;
    cache_row record;
BEGIN
    FOR cache_row IN
        SELECT server_name, tool_name, description, title, input_schema, active
          FROM stewards.mcp_tool_cache
         WHERE active
    LOOP
        INSERT INTO stewards.tool_defs
            (name, description, args_schema, execute_target, active)
        VALUES (
            cache_row.tool_name,
            format('via %s: %s', cache_row.server_name,
                   coalesce(cache_row.description, cache_row.title, cache_row.tool_name)),
            coalesce(cache_row.input_schema, '{"type":"object"}'::jsonb),
            jsonb_build_object(
                'kind',   'mcp_proxy',
                'server', cache_row.server_name,
                'tool',   cache_row.tool_name
            ),
            true
        )
        ON CONFLICT (name) DO UPDATE
           SET description    = EXCLUDED.description,
               args_schema    = EXCLUDED.args_schema,
               execute_target = EXCLUDED.execute_target,
               active         = true;
        n_touched := n_touched + 1;
    END LOOP;

    -- Soft-deactivate tool_defs that point at mcp_proxy but no longer
    -- have a corresponding active cache row. Keeps history without
    -- leaving stale tool_defs visible to agents.
    UPDATE stewards.tool_defs td
       SET active = false
     WHERE (execute_target ->> 'kind') = 'mcp_proxy'
       AND active = true
       AND NOT EXISTS (
            SELECT 1 FROM stewards.mcp_tool_cache c
             WHERE c.server_name = (td.execute_target ->> 'server')
               AND c.tool_name   = (td.execute_target ->> 'tool')
               AND c.active
        );

    RETURN n_touched;
END;
$func$;

COMMENT ON FUNCTION stewards.promote_mcp_tool_cache_to_tool_defs IS
  'Bulk sync: upsert one tool_defs row per active mcp_tool_cache row, '
  'soft-deactivate orphaned mcp_proxy tool_defs. Idempotent. Bridge '
  'calls this at the end of refresh-tools; the trigger keeps row-level '
  'consistency between refreshes.';

-- ---------------------------------------------------------------------
-- Row-level trigger — keep tool_defs in lockstep with the cache.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.mcp_tool_cache_sync_trigger()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        -- Cache row removed entirely — deactivate matching tool_def.
        UPDATE stewards.tool_defs
           SET active = false
         WHERE (execute_target ->> 'kind') = 'mcp_proxy'
           AND (execute_target ->> 'server') = OLD.server_name
           AND (execute_target ->> 'tool')   = OLD.tool_name;
        RETURN OLD;
    END IF;

    -- INSERT / UPDATE: mirror the row.
    IF NEW.active THEN
        INSERT INTO stewards.tool_defs
            (name, description, args_schema, execute_target, active)
        VALUES (
            NEW.tool_name,
            format('via %s: %s', NEW.server_name,
                   coalesce(NEW.description, NEW.title, NEW.tool_name)),
            coalesce(NEW.input_schema, '{"type":"object"}'::jsonb),
            jsonb_build_object(
                'kind',   'mcp_proxy',
                'server', NEW.server_name,
                'tool',   NEW.tool_name
            ),
            true
        )
        ON CONFLICT (name) DO UPDATE
           SET description    = EXCLUDED.description,
               args_schema    = EXCLUDED.args_schema,
               execute_target = EXCLUDED.execute_target,
               active         = true;
    ELSE
        -- Cache row marked inactive — hide the tool_def too.
        UPDATE stewards.tool_defs
           SET active = false
         WHERE (execute_target ->> 'kind') = 'mcp_proxy'
           AND (execute_target ->> 'server') = NEW.server_name
           AND (execute_target ->> 'tool')   = NEW.tool_name;
    END IF;
    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS mcp_tool_cache_sync ON stewards.mcp_tool_cache;
CREATE TRIGGER mcp_tool_cache_sync
    AFTER INSERT OR UPDATE OR DELETE ON stewards.mcp_tool_cache
    FOR EACH ROW
    EXECUTE FUNCTION stewards.mcp_tool_cache_sync_trigger();

-- ---------------------------------------------------------------------
-- Self-surface seeds (h1-7a). These two servers ship WITH the
-- substrate (cmd/fs-read-mcp, cmd/stewards-mcp in this repo; the
-- compose mounts them at the paths below), so they're core machinery,
-- not overlay data. External servers are operator data — seed them in
-- the overlay. ON CONFLICT DO NOTHING: operators own these rows after
-- install (paths, scopes, enabled state).
--
-- agent_tool_perms intentionally NOT granted here. Bridged tools are
-- deny-by-default; operators allow them per-agent explicitly.
-- ---------------------------------------------------------------------
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'fs-read',
  'Path-scoped filesystem read for substrate-internal agents. Tools: '
    || 'fs_list, fs_read, fs_search. Scope is enforced at the MCP tool '
    || 'layer via the --allowed-paths flag — even if the bridge container '
    || 'mounts more of the workspace, the agent only sees what is in '
    || 'scope. Adjust -allowed-paths to your workspace layout.',
  'stdio',
  '/usr/local/bin/fs-read-mcp',
  ARRAY[
    '-repo-root', '/workspace',
    '-allowed-paths', '.spec/journal/*,.spec/proposals/*,.mind/*,docs/**'
  ],
  NULL,
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;

-- pg-ai-stewards MCP — the substrate's own tool surface exposed to
-- internal agents through the bridge proxy. The stewards-mcp binary
-- defaults to inbound stdio mode with no subcommand args; STEWARDS_DSN
-- propagates from the bridge container's env so the substrate connects
-- to itself. Read tools (doc_search/doc_get/doc_similar/doc_citations,
-- work_item_list/show, watchman_pass_show/passes_list) are the
-- intended grant surface; escalation write tools exist on the same MCP
-- but belong to the operator review surface.
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'pg-ai-stewards',
  'Substrate self-surface — exposes the substrate''s own docs/work_items/'
    || 'watchman read tools to internal agents through the bridge proxy. '
    || 'Agents call doc_search/work_item_show to consult prior work before '
    || 'doing external research. Escalation write tools (work_item_escalation_*) '
    || 'exist on the same MCP but are excluded from research-agent grants — '
    || 'they belong to the operator review surface.',
  'stdio',
  '/usr/local/bin/stewards-mcp',
  ARRAY[]::text[],
  NULL,
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;

-- fetch-md — fetch a URL and return readable markdown (fetch_url, fetch_urls,
-- extract_links, fetch_url_raw). A generic utility the research pipelines lean
-- on. Static fetch needs no key; the js:true rendering path needs a `chromium`
-- binary in the bridge image (omitted by default — see bridge.Dockerfile).
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'fetch-md',
  'Fetch a web page and return it as readable markdown. Tools: fetch_url '
    || '(one URL -> markdown via readability), fetch_urls (batch), extract_links '
    || '(list a page''s links), fetch_url_raw (unprocessed HTML). The default '
    || 'path is a plain HTTP client; a js:true param renders with headless '
    || 'chromium when available.',
  'stdio',
  '/usr/local/bin/fetch-md-mcp',
  ARRAY[]::text[],
  NULL,
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;

-- git — general git/gh operations over a configured workdir, distinct from
-- coder-mcp's sandbox-scoped git. Branch ops are namespaced to agent/* and
-- main/master/release/* are protected (the tool refuses them). GITHUB_TOKEN is
-- read from the bridge env at exec time (rotation without restart); deny-by-
-- default like every bridged server — grant per-agent in an overlay.
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'git',
  'General git + GitHub ops over a configured workdir. Tools: git_clone, '
    || 'git_status, git_branch_create, git_add, git_commit, git_push, '
    || 'gh_pr_create, gh_issue_create. Agent branches are namespaced (agent/*) '
    || 'and protected branches (main/master/release/*) are refused.',
  'stdio',
  '/usr/local/bin/git-mcp',
  ARRAY[]::text[],
  NULL,
  '{"GITHUB_TOKEN": "$$env:GITHUB_TOKEN"}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;

-- exa-search — the default web search (Exa's hosted MCP, remote/http). The
-- substrate ships with web search working OUT OF THE BOX: Exa's endpoint
-- serves web_search_exa on a keyless free/anonymous tier (rate-limited). For
-- production volume, add your own key by appending &exaApiKey=<KEY> to the url
-- (operators own this row after install). Deny-by-default like every bridged
-- server — grant web_search_exa per-agent in an overlay.
--
-- Be a good citizen: the free tier is for trying it out; register your own Exa
-- account + key for anything beyond light use.
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'exa-search',
  'Web search via Exa''s hosted MCP. Tool: web_search_exa (neural web search '
    || '-> titles, URLs, and content highlights). Works on Exa''s keyless free '
    || 'tier out of the box; append &exaApiKey=<KEY> to the url for production '
    || 'rate limits.',
  'http',
  NULL,
  ARRAY[]::text[],
  'https://mcp.exa.ai/mcp?tools=web_search_exa',
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;
-- ===== [was 06-cost.sql] =====
-- =====================================================================
-- 06-cost — pricing, the cost ledger, buckets, caps, escalation
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Sources folded, in original
-- ship order: 4a-cost-tracking (pricing/ledger/buckets machinery), 4a-
-- escalation-chain (stage_models + escalation matrix + pick_model), 4g
-- (nullable work_item_id + session_id on the ledger; record_cost_event
-- re-signature), es11 (upstream_micro_dollars + the final 11-arg
-- record_cost_event), j11 §1-4 (provider_spend_caps machinery; its
-- work_item_dispatch_stage gate rides with j8a's catalog at the
-- fanout consolidation), j12 §1-2 (classify_error + failures view; its
-- start_brainstorm pre-flight rides with the fanout consolidation).
--
-- SEED ROWS MOVED TO THE OVERLAY: model pricing rates, bucket caps,
-- stage_models defaults, the escalation matrix, provider cap rows, and
-- model_capability registrations (4a seeds, j10, an4, cv4, j11 §6) are
-- operator data — which providers you pay, what they charge, and how
-- your model chain escalates. The machinery here ships empty; the seed
-- pack provides generic examples. compute_cost on an unpriced model
-- returns 0 and flags 'no_pricing_row' in notes — visible, not silent.
--
-- All money in micro-dollars (1 USD = 1_000_000) for integer
-- arithmetic. All rates per million tokens.
--
-- The work_items cost/escalation columns (cost_micro_dollars,
-- cost_cap_micro, cost_capped_at, model_override, escalation_*) are
-- born in 04-work-items' CREATE TABLE.
-- =====================================================================

-- ---------------------------------------------------------------------
-- model_pricing: one row per (provider, model, effective_at).
-- Most-recent row whose effective_at <= now() wins. NULL cache rates
-- mean the provider does not expose that distinction.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.model_pricing (
    provider                    text  NOT NULL,
    model                       text  NOT NULL,
    input_micro_per_mtok        bigint NOT NULL CHECK (input_micro_per_mtok >= 0),
    output_micro_per_mtok       bigint NOT NULL CHECK (output_micro_per_mtok >= 0),
    cache_write_micro_per_mtok  bigint CHECK (cache_write_micro_per_mtok IS NULL OR cache_write_micro_per_mtok >= 0),
    cache_read_micro_per_mtok   bigint CHECK (cache_read_micro_per_mtok IS NULL OR cache_read_micro_per_mtok >= 0),
    effective_at                timestamptz NOT NULL DEFAULT now(),
    notes                       text,
    PRIMARY KEY (provider, model, effective_at)
);

COMMENT ON TABLE stewards.model_pricing IS
'Per-model pricing in micro-dollars per 1M tokens. NULL cache_*_micro_per_mtok means provider does not expose that distinction. Most-recent effective_at wins. Rows are operator data — seed yours (do not invent 0 rates for paid models; 0 silently under-tracks real spend).';

-- ---------------------------------------------------------------------
-- cost_events: append-only per-dispatch cost audit ledger.
-- work_item_id nullable: NULL = an ad-hoc chat not tied to a work_item
-- (e.g., a watchman pass) — session_id identifies the owner.
-- micro_dollars is the substrate's rate×token estimate;
-- upstream_micro_dollars is the gateway-reported real cost when the
-- provider exposes it (estimate-vs-actual stays visible).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.cost_events (
    id                          bigserial PRIMARY KEY,
    work_item_id                uuid REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    session_id                  text,
    attempt_seq                 int NOT NULL,
    at                          timestamptz NOT NULL DEFAULT now(),
    provider                    text NOT NULL,
    model                       text NOT NULL,
    input_tokens                int NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
    output_tokens               int NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
    cache_write_tokens          int NOT NULL DEFAULT 0 CHECK (cache_write_tokens >= 0),
    cache_read_tokens           int NOT NULL DEFAULT 0 CHECK (cache_read_tokens >= 0),
    micro_dollars               bigint NOT NULL,
    upstream_micro_dollars      bigint,
    pricing_effective_at        timestamptz NOT NULL,
    notes                       text
);
CREATE INDEX IF NOT EXISTS cost_events_work_item ON stewards.cost_events(work_item_id);
CREATE INDEX IF NOT EXISTS cost_events_session ON stewards.cost_events(session_id);
CREATE INDEX IF NOT EXISTS cost_events_at ON stewards.cost_events(at);
CREATE INDEX IF NOT EXISTS cost_events_provider_model ON stewards.cost_events(provider, model);

COMMENT ON TABLE stewards.cost_events IS
'Append-only audit of every LLM dispatch cost. micro_dollars is computed at insert from compute_cost(provider, model, tokens) and locked to pricing_effective_at; upstream_micro_dollars carries the gateway-reported real cost when available.';

-- ---------------------------------------------------------------------
-- cost_buckets: rolling consumption buckets per provider/kind
-- (session_5h / daily / weekly / monthly). bucket_limit_micro is
-- INFORMATIONAL — for enforced caps see provider_spend_caps below.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.cost_buckets (
    id                  bigserial PRIMARY KEY,
    provider            text NOT NULL,
    bucket_kind         text NOT NULL CHECK (bucket_kind IN ('session_5h','daily','weekly','monthly')),
    period_start        timestamptz NOT NULL,
    period_end          timestamptz NOT NULL,
    micro_dollars       bigint NOT NULL DEFAULT 0,
    bucket_limit_micro  bigint,  -- NULL = informational only
    notes               text,
    UNIQUE (provider, bucket_kind, period_start)
);
CREATE INDEX IF NOT EXISTS cost_buckets_period ON stewards.cost_buckets(provider, bucket_kind, period_end);

COMMENT ON TABLE stewards.cost_buckets IS
'Rolling consumption buckets per provider/kind. Closes at period_end; bucket_current() opens the next period lazily. bucket_limit_micro NULL means informational only (no enforcement).';

-- ---------------------------------------------------------------------
-- compute_cost(provider, model, tokens...) -> (micro_dollars,
-- pricing_effective_at). Picks the most-recent pricing row whose
-- effective_at <= now(). Returns (0, '-infinity') if no pricing row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compute_cost(
    p_provider           text,
    p_model              text,
    p_input_tokens       int,
    p_output_tokens      int,
    p_cache_write_tokens int DEFAULT 0,
    p_cache_read_tokens  int DEFAULT 0
) RETURNS TABLE (micro_dollars bigint, pricing_effective_at timestamptz)
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_pricing record;
    v_micro bigint;
BEGIN
    SELECT * INTO v_pricing
      FROM stewards.model_pricing
     WHERE provider = p_provider
       AND model = p_model
       AND effective_at <= now()
     ORDER BY effective_at DESC
     LIMIT 1;

    IF v_pricing IS NULL THEN
        -- No pricing row; zero cost and a sentinel timestamp.
        RETURN QUERY SELECT 0::bigint, '-infinity'::timestamptz;
        RETURN;
    END IF;

    -- Integer math throughout. tokens * micro_per_mtok / 1_000_000
    -- = micro_dollars contribution from that token category.
    v_micro := (p_input_tokens::bigint  * v_pricing.input_micro_per_mtok  / 1000000)
             + (p_output_tokens::bigint * v_pricing.output_micro_per_mtok / 1000000);

    IF v_pricing.cache_write_micro_per_mtok IS NOT NULL AND p_cache_write_tokens > 0 THEN
        v_micro := v_micro + (p_cache_write_tokens::bigint
                              * v_pricing.cache_write_micro_per_mtok / 1000000);
    END IF;

    IF v_pricing.cache_read_micro_per_mtok IS NOT NULL AND p_cache_read_tokens > 0 THEN
        v_micro := v_micro + (p_cache_read_tokens::bigint
                              * v_pricing.cache_read_micro_per_mtok / 1000000);
    END IF;

    RETURN QUERY SELECT v_micro, v_pricing.effective_at;
END;
$func$;

COMMENT ON FUNCTION stewards.compute_cost(text, text, int, int, int, int) IS
'Compute cost in micro-dollars from token usage. Picks most-recent pricing whose effective_at <= now().';

-- ---------------------------------------------------------------------
-- record_cost_event — the final 11-arg form (4g session plumbing +
-- es11 upstream cost). Inserts a cost_events row with computed
-- micro_dollars; the trigger updates work_items (when work_item_id is
-- non-NULL) + buckets. Pass p_session_id for chats not tied to a
-- work_item; p_upstream_micro carries the gateway-reported real cost.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.record_cost_event(
    p_work_item_id      uuid,
    p_attempt_seq       integer,
    p_provider          text,
    p_model             text,
    p_input_tokens      integer,
    p_output_tokens     integer,
    p_cache_write_tokens integer DEFAULT 0,
    p_cache_read_tokens  integer DEFAULT 0,
    p_session_id        text DEFAULT NULL,
    p_notes             text DEFAULT NULL,
    p_upstream_micro    bigint DEFAULT NULL
) RETURNS bigint LANGUAGE plpgsql AS $func$
DECLARE
    v_micro      bigint;
    v_pricing_at timestamptz;
    v_id         bigint;
    v_notes      text;
BEGIN
    SELECT micro_dollars, pricing_effective_at
      INTO v_micro, v_pricing_at
      FROM stewards.compute_cost(p_provider, p_model,
                                  p_input_tokens, p_output_tokens,
                                  p_cache_write_tokens, p_cache_read_tokens);

    -- If no pricing row exists, flag in notes so the gap is visible.
    v_notes := p_notes;
    IF v_pricing_at = '-infinity'::timestamptz THEN
        v_notes := coalesce(v_notes || ' | ', '')
                 || 'no_pricing_row(' || p_provider || '/' || p_model || ')';
    END IF;

    INSERT INTO stewards.cost_events
        (work_item_id, session_id, attempt_seq, provider, model,
         input_tokens, output_tokens, cache_write_tokens, cache_read_tokens,
         micro_dollars, pricing_effective_at, notes, upstream_micro_dollars)
    VALUES
        (p_work_item_id, p_session_id, p_attempt_seq, p_provider, p_model,
         p_input_tokens, p_output_tokens, p_cache_write_tokens, p_cache_read_tokens,
         v_micro, v_pricing_at, v_notes, p_upstream_micro)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

COMMENT ON FUNCTION stewards.record_cost_event(uuid, integer, text, text, integer, integer, integer, integer, text, text, bigint) IS
'Records a cost_event. micro_dollars is computed (compute_cost: rate x tokens); p_upstream_micro carries the gateway-reported real cost into upstream_micro_dollars. Trigger updates work_items + buckets.';

-- ---------------------------------------------------------------------
-- cost_cap_exceeded(work_item) — true if the work_item has
-- cost_cap_micro set and cost_micro_dollars has reached it. Checked by
-- steward_tick before retry dispatch.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.cost_cap_exceeded(p_work_item_id uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $func$
    SELECT cost_cap_micro IS NOT NULL
           AND cost_micro_dollars >= cost_cap_micro
      FROM stewards.work_items
     WHERE id = p_work_item_id;
$func$;

-- ---------------------------------------------------------------------
-- Bucket helpers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.bucket_period_for(
    p_kind text,
    p_ts   timestamptz DEFAULT now()
) RETURNS TABLE (period_start timestamptz, period_end timestamptz)
LANGUAGE plpgsql IMMUTABLE AS $func$
BEGIN
    -- session_5h: 5-hour windows aligned to UTC midnight
    -- (00:00, 05:00, 10:00, 15:00, 20:00 UTC)
    IF p_kind = 'session_5h' THEN
        period_start := date_trunc('hour', p_ts)
                      - (extract(hour FROM p_ts)::int % 5) * interval '1 hour';
        period_end   := period_start + interval '5 hours';
    ELSIF p_kind = 'daily' THEN
        period_start := date_trunc('day', p_ts);
        period_end   := period_start + interval '1 day';
    ELSIF p_kind = 'weekly' THEN
        -- ISO week (Monday start).
        period_start := date_trunc('week', p_ts);
        period_end   := period_start + interval '1 week';
    ELSIF p_kind = 'monthly' THEN
        period_start := date_trunc('month', p_ts);
        period_end   := period_start + interval '1 month';
    ELSE
        RAISE EXCEPTION 'unknown bucket_kind: %', p_kind;
    END IF;
    RETURN NEXT;
END;
$func$;

-- bucket_current: the active bucket row for the current period, created
-- lazily. New periods inherit the most recent configured limit for the
-- (provider, kind).
CREATE OR REPLACE FUNCTION stewards.bucket_current(
    p_provider text,
    p_kind     text
) RETURNS stewards.cost_buckets
LANGUAGE plpgsql AS $func$
DECLARE
    v_period record;
    v_bucket stewards.cost_buckets;
    v_default_limit bigint;
BEGIN
    SELECT * INTO v_period
      FROM stewards.bucket_period_for(p_kind, now());

    SELECT * INTO v_bucket
      FROM stewards.cost_buckets
     WHERE provider = p_provider
       AND bucket_kind = p_kind
       AND period_start = v_period.period_start;

    IF v_bucket IS NOT NULL THEN
        RETURN v_bucket;
    END IF;

    SELECT bucket_limit_micro INTO v_default_limit
      FROM stewards.cost_buckets
     WHERE provider = p_provider
       AND bucket_kind = p_kind
       AND bucket_limit_micro IS NOT NULL
     ORDER BY period_start DESC
     LIMIT 1;

    INSERT INTO stewards.cost_buckets
        (provider, bucket_kind, period_start, period_end,
         micro_dollars, bucket_limit_micro)
    VALUES
        (p_provider, p_kind, v_period.period_start, v_period.period_end,
         0, v_default_limit)
    ON CONFLICT (provider, bucket_kind, period_start) DO NOTHING
    RETURNING * INTO v_bucket;

    -- If ON CONFLICT skipped (race), refetch.
    IF v_bucket IS NULL THEN
        SELECT * INTO v_bucket
          FROM stewards.cost_buckets
         WHERE provider = p_provider
           AND bucket_kind = p_kind
           AND period_start = v_period.period_start;
    END IF;

    RETURN v_bucket;
END;
$func$;

CREATE OR REPLACE FUNCTION stewards.bucket_record(
    p_provider     text,
    p_kind         text,
    p_micro_dollars bigint
) RETURNS void
LANGUAGE plpgsql AS $func$
DECLARE
    v_bucket stewards.cost_buckets;
BEGIN
    v_bucket := stewards.bucket_current(p_provider, p_kind);
    UPDATE stewards.cost_buckets
       SET micro_dollars = micro_dollars + p_micro_dollars
     WHERE id = v_bucket.id;
END;
$func$;

-- ---------------------------------------------------------------------
-- Trigger: maintain work_items.cost_micro_dollars + buckets on insert.
-- No-ops on the work_items UPDATE when work_item_id is NULL.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.cost_events_after_insert()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    UPDATE stewards.work_items
       SET cost_micro_dollars = cost_micro_dollars + NEW.micro_dollars,
           cost_capped_at = CASE
               WHEN cost_capped_at IS NOT NULL THEN cost_capped_at
               WHEN cost_cap_micro IS NOT NULL
                    AND (cost_micro_dollars + NEW.micro_dollars) >= cost_cap_micro
                    THEN now()
               ELSE NULL
           END
     WHERE id = NEW.work_item_id;

    -- Roll into all four bucket kinds for this provider.
    PERFORM stewards.bucket_record(NEW.provider, 'session_5h', NEW.micro_dollars);
    PERFORM stewards.bucket_record(NEW.provider, 'daily',      NEW.micro_dollars);
    PERFORM stewards.bucket_record(NEW.provider, 'weekly',     NEW.micro_dollars);
    PERFORM stewards.bucket_record(NEW.provider, 'monthly',    NEW.micro_dollars);

    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS cost_events_after_insert ON stewards.cost_events;
CREATE TRIGGER cost_events_after_insert
AFTER INSERT ON stewards.cost_events
FOR EACH ROW EXECUTE FUNCTION stewards.cost_events_after_insert();

-- ---------------------------------------------------------------------
-- Escalation: stage_models (per-(pipeline, stage) defaults) +
-- model_escalation ((current_model, diagnosis) -> next_model matrix) +
-- pick_model. The sentinel '__queue_for_opus__' returned by pick_model
-- means "transition to escalation_state='queued' instead of
-- dispatching" — the human-mediated escalation queue. Rows in both
-- tables are operator policy (your model chain); seed via the overlay.
-- RENAMED 2026-07-07 (feat/lightening, model-agnostic audit §F): the
-- sentinel is __queue_for_strongest__ as of 107-lifeless-core.sql's
-- re-authored pick_model (a deployer's top rung isn't always Opus —
-- 84-tool-effect-gate.sql's own "a Fable hinge is now possible"). This
-- file's __queue_for_opus__ below is the historical record; port from
-- 107, not from here.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.stage_models (
    pipeline_family   text NOT NULL,
    stage_name        text NOT NULL,
    default_model     text NOT NULL,
    notes             text,
    PRIMARY KEY (pipeline_family, stage_name)
);

COMMENT ON TABLE stewards.stage_models IS
'Per-(pipeline_family, stage) initial model for stage dispatch. pick_model() consults this for attempt=1. Operator policy — seed via the overlay.';

CREATE TABLE IF NOT EXISTS stewards.model_escalation (
    current_model     text NOT NULL,
    diagnosis         text NOT NULL CHECK (diagnosis IN
        ('transient','timeout','model_limit','tool_error','unknown')),
    attempt_threshold int NOT NULL DEFAULT 1 CHECK (attempt_threshold >= 1),
    next_model        text,  -- NULL = stay; '__queue_for_opus__' = sentinel
    notes             text,
    PRIMARY KEY (current_model, diagnosis),
    -- Prevent direct self-loops (multi-hop cycles still terminate via
    -- pick_model's attempt-bounded loop).
    CHECK (next_model IS NULL OR next_model != current_model)
);

COMMENT ON TABLE stewards.model_escalation IS
'Escalation matrix: given current_model + diagnosis, what model to retry on after attempt_threshold attempts. NULL next_model = stay; sentinel __queue_for_opus__ = enter the human-mediated escalation queue. Operator policy — seed via the overlay.';

CREATE OR REPLACE FUNCTION stewards.pick_model(
    p_pipeline_family text,
    p_stage_name      text,
    p_attempt         int,
    p_diagnosis       text DEFAULT 'initial'
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_current_model text;
    v_escalation    record;
    i               int;
BEGIN
    SELECT default_model INTO v_current_model
      FROM stewards.stage_models
     WHERE pipeline_family = p_pipeline_family
       AND stage_name = p_stage_name;

    IF v_current_model IS NULL THEN
        RAISE EXCEPTION 'no stage_models row for %/%',
            p_pipeline_family, p_stage_name;
    END IF;

    -- First attempt or sentinel diagnosis = no escalation.
    IF p_attempt <= 1 OR p_diagnosis = 'initial' OR p_diagnosis IS NULL THEN
        RETURN v_current_model;
    END IF;

    -- Walk the chain. For each attempt past 1, look up an escalation
    -- rule for (current_model, diagnosis) whose attempt_threshold is
    -- met. The queue sentinel returns immediately.
    FOR i IN 2..p_attempt LOOP
        SELECT * INTO v_escalation
          FROM stewards.model_escalation
         WHERE current_model = v_current_model
           AND diagnosis = p_diagnosis
           AND attempt_threshold <= i;

        IF v_escalation IS NULL OR v_escalation.next_model IS NULL THEN
            RETURN v_current_model;
        END IF;

        IF v_escalation.next_model = '__queue_for_opus__' THEN
            RETURN '__queue_for_opus__';
        END IF;

        v_current_model := v_escalation.next_model;
    END LOOP;

    RETURN v_current_model;
END;
$func$;

COMMENT ON FUNCTION stewards.pick_model(text, text, int, text) IS
'Picks the model for the next dispatch. Walks model_escalation per (attempt, diagnosis). Returns __queue_for_opus__ sentinel when the chain exhausts.';

-- ---------------------------------------------------------------------
-- provider_spend_caps — ENFORCED prepaid-balance caps (j11).
--
-- Distinct from cost_buckets (rolling + informational): a prepaid
-- balance only resets when the human refills. The dispatch gate
-- refuses a provider whose cost_events sum since `since` has reached
-- cap_micro AND enforced=true. Providers without a cap row (or
-- enforced=false) are never gated. Cap rows are operator data — seed
-- via the overlay.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.provider_spend_caps (
    provider    text PRIMARY KEY,
    cap_micro   bigint NOT NULL CHECK (cap_micro >= 0),
    since       timestamptz NOT NULL DEFAULT now(),
    enforced    boolean NOT NULL DEFAULT false,
    notes       text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.provider_spend_caps IS
'Enforced prepaid-balance spend caps per provider. The dispatch gate refuses a provider whose cost_events sum since `since` >= cap_micro AND enforced=true. Refill via provider_cap_refill(). Distinct from cost_buckets (rolling + informational).';

COMMENT ON COLUMN stewards.provider_spend_caps.since IS
'Refill epoch. Spend is summed from cost_events.at >= since. provider_cap_refill() moves this to now().';

CREATE OR REPLACE FUNCTION stewards.provider_spend_since(p_provider text)
RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT coalesce(sum(ce.micro_dollars), 0)::bigint
      FROM stewards.cost_events ce
      JOIN stewards.provider_spend_caps c ON c.provider = ce.provider
     WHERE ce.provider = p_provider
       AND ce.at >= c.since;
$$;

COMMENT ON FUNCTION stewards.provider_spend_since(text) IS
'Micro-dollars spent on a provider since its cap row''s refill epoch. 0 if no cap row.';

CREATE OR REPLACE FUNCTION stewards.provider_cap_exceeded(p_provider text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
          FROM stewards.provider_spend_caps c
         WHERE c.provider = p_provider
           AND c.enforced
           AND (SELECT coalesce(sum(ce.micro_dollars), 0)
                  FROM stewards.cost_events ce
                 WHERE ce.provider = p_provider
                   AND ce.at >= c.since) >= c.cap_micro
    );
$$;

COMMENT ON FUNCTION stewards.provider_cap_exceeded(text) IS
'True if the provider has an enforced cap and spend-since-refill has reached it. Checked by the dispatch gate before enqueuing a chat.';

CREATE OR REPLACE FUNCTION stewards.provider_cap_refill(
    p_provider      text,
    p_new_cap_micro bigint DEFAULT NULL
) RETURNS stewards.provider_spend_caps
LANGUAGE plpgsql AS $$
DECLARE
    v_row stewards.provider_spend_caps;
BEGIN
    UPDATE stewards.provider_spend_caps
       SET since      = now(),
           cap_micro  = COALESCE(p_new_cap_micro, cap_micro),
           updated_at = now()
     WHERE provider = p_provider
    RETURNING * INTO v_row;

    IF v_row.provider IS NULL THEN
        RAISE EXCEPTION 'provider_cap_refill: no cap row for provider %', p_provider;
    END IF;

    -- plpgsql RAISE supports only % substitution; pre-round the dollars.
    RAISE NOTICE 'provider_cap_refill: % refilled — since=now(), cap=% micro ($%)',
        p_provider, v_row.cap_micro, round(v_row.cap_micro / 1000000.0, 2);
    RETURN v_row;
END;
$$;

COMMENT ON FUNCTION stewards.provider_cap_refill(text, bigint) IS
'Top up a provider cap. Resets the spend-since-refill clock (since=now()) and optionally sets a new cap_micro. Run after refilling the real prepaid balance.';

-- ---------------------------------------------------------------------
-- classify_error(error_text) — read-time category for any stored error
-- string (work_items.error, work_queue.error). Most-specific first.
-- Note: some providers return HTTP 429 for BOTH rate limits and quota
-- exhaustion; the quota/RESOURCE_EXHAUSTED wording is checked first so
-- true budget exhaustion classifies as provider_budget.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.classify_error(p_error text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_error IS NULL OR btrim(p_error) = '' THEN 'none'
        WHEN p_error ILIKE '%spend cap reached%'
          OR p_error ILIKE '%provider_cap%'
          OR p_error ILIKE '%provider_cap_refill%'                 THEN 'spend_cap_reached'
        WHEN p_error ILIKE '%RESOURCE_EXHAUSTED%'
          OR p_error ILIKE '%exceeded your current quota%'
          OR p_error ILIKE '%billing%'
          OR p_error ILIKE '%out of credit%'
          OR p_error ILIKE '%insufficient%balance%'
          OR p_error ILIKE '%insufficient%credit%'
          OR p_error ILIKE '%quota%exceeded%'
          OR p_error ILIKE '%FAILED_PRECONDITION%'                 THEN 'provider_budget'
        WHEN p_error ILIKE '%rate limit%'
          OR p_error ILIKE '%rate_limit%'
          OR p_error ILIKE '%too many requests%'
          OR p_error ILIKE '%HTTP 429%'                            THEN 'rate_limited'
        WHEN p_error ILIKE '%HTTP 401%'
          OR p_error ILIKE '%HTTP 403%'
          OR p_error ILIKE '%PERMISSION_DENIED%'
          OR p_error ILIKE '%UNAUTHENTICATED%'
          OR p_error ILIKE '%API key%'
          OR p_error ILIKE '%invalid%key%'                         THEN 'auth'
        WHEN p_error ILIKE '%timeout%'
          OR p_error ILIKE '%timed out%'
          OR p_error ILIKE '%deadline%'                            THEN 'timeout'
        ELSE 'other'
    END
$$;

COMMENT ON FUNCTION stewards.classify_error(text) IS
'Classify a stored error string into a category (spend_cap_reached | provider_budget | rate_limited | auth | timeout | other | none). Read-time labeling for the work_items API + UI.';

CREATE OR REPLACE VIEW stewards.work_item_failures AS
SELECT wi.id,
       wi.slug,
       wi.pipeline_family,
       wi.status,
       stewards.classify_error(wi.error) AS error_category,
       wi.error,
       wi.updated_at
  FROM stewards.work_items wi
 WHERE wi.status = 'failed'
   AND wi.error IS NOT NULL
 ORDER BY wi.updated_at DESC;

COMMENT ON VIEW stewards.work_item_failures IS
'Failed work_items with a classified error_category. Quick triage: SELECT * FROM stewards.work_item_failures WHERE error_category = ''provider_budget'';';
-- ===== [was 07-steward.sql] =====
-- =====================================================================
-- 07-steward — Watch → Diagnose → Act → Account
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Sources folded, in original
-- ship order: 4a-steward (failure tracking, diagnosis, retry guidance,
-- circuit breaker, the original tick), 4b (override-aware dispatch —
-- born into 04-work-items' work_item_dispatch_stage; its live-data
-- provider rename died with the fresh rebuild), 4c (tick actually
-- dispatches), 4d (per-item exception isolation + provider derived
-- from model_pricing; its stage_models seeds moved to the overlay),
-- 6b (retry guidance pulls ratified lessons), 6c (quarantine fires
-- atonement — pulled forward from the sabbath batch; the whole file
-- was just the tick redefinition). steward_tick appears once, in the
-- 6c final form. The work_items failure/quarantine/override columns
-- are born in 04-work-items' CREATE TABLE.
--
-- The design, in one paragraph: when a dispatch fails, the bridge
-- sets status='failed' and records the reason; the steward's tick
-- (called by the bgworker) walks failed work_items oldest-first and,
-- per item: quarantines on cost-cap (firing atonement when the
-- pipeline opts in), defers when the circuit breaker for the
-- (pipeline, stage) is open, classifies the failure (diagnose_failure,
-- a 5-type classifier), picks the next model by walking the
-- escalation matrix (06-cost), and either queues for human-mediated
-- escalation (the __queue_for_opus__ sentinel) or re-dispatches with
-- per-diagnosis retry guidance plus the last ratified lessons for the
-- stage. Every decision lands in steward_actions — the Account step.
-- Per-item exception isolation: one bad item logs a tick_error and
-- the loop continues.
--
-- SUPERSEDED 2026-07-07 (feat/lightening): steward_tick's true FINAL body
-- is 32-alias-failover.sql's (later-file-wins), itself re-authored once
-- more by 107-lifeless-core.sql (sentinel renamed __queue_for_strongest__,
-- all 3 dispatch calls swapped to work_item_dispatch_stage_safe so an
-- unconfigured model breaks the retry loop into awaiting_review instead
-- of looping the same failed item forever). This file's copy below is the
-- historical record — port from 107, not from here.
--
-- (steward_tick's body references retry_guidance_with_lessons and
-- maybe_enqueue_atonement, which are created later in the chain —
-- safe because the bundle installs atomically and plpgsql bodies are
-- not validated at CREATE time.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- steward_actions — append-only audit ledger of every steward decision.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.steward_actions (
    id            bigserial PRIMARY KEY,
    work_item_id  uuid REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    at            timestamptz NOT NULL DEFAULT now(),
    observation   text NOT NULL,
    diagnosis     text,
    action        text NOT NULL,
    details       jsonb NOT NULL DEFAULT '{}'::jsonb,
    model_used    text,
    cost_micro    bigint
);
CREATE INDEX IF NOT EXISTS steward_actions_work_item ON stewards.steward_actions(work_item_id);
CREATE INDEX IF NOT EXISTS steward_actions_at        ON stewards.steward_actions(at);
CREATE INDEX IF NOT EXISTS steward_actions_action    ON stewards.steward_actions(action);

COMMENT ON TABLE stewards.steward_actions IS
'Append-only audit of every steward decision. The "Account" step of Watch→Diagnose→Act→Account.';

-- ---------------------------------------------------------------------
-- diagnose_failure — classify a failure reason into one of
-- (transient | timeout | model_limit | tool_error | unknown).
-- IMMUTABLE so it can be inlined in views and indexed if needed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.diagnose_failure(
    p_reason         text,
    p_failure_count  int DEFAULT 0
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_lower text;
BEGIN
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        -- No reason text. Use failure_count as proxy: a few failures
        -- with no reason string reads as model_limit so escalation
        -- kicks in.
        IF p_failure_count >= 2 THEN
            RETURN 'model_limit';
        END IF;
        RETURN 'unknown';
    END IF;

    v_lower := lower(p_reason);

    -- Order matters: timeout is most specific (overrides "rate limit"
    -- false-positives like "request timeout: rate limit hit").
    IF v_lower ~ '(timeout|timed out|context deadline exceeded|inactivity|deadline)' THEN
        RETURN 'timeout';
    END IF;

    -- Transient: rate limits, 5xx, network blips. Provider issue, not
    -- a model-capability issue.
    IF v_lower ~ '(429|rate.?limit|5(00|01|02|03|04)|network|connection refused|temporarily unavailable|service unavailable)' THEN
        RETURN 'transient';
    END IF;

    -- Tool error: model called a tool wrong, or the tool rejected the
    -- call. Distinct from model_limit because re-prompting with
    -- feedback usually fixes it.
    IF v_lower ~ '(tool.{0,30}(error|not found|missing|invalid)|function.{0,20}(error|not found|missing|invalid)|schema.{0,20}(error|invalid|mismatch)|validation.{0,20}(failed|error))' THEN
        RETURN 'tool_error';
    END IF;

    -- After 2+ failures without a recognized pattern, treat as
    -- model_limit. The model genuinely can't handle this.
    IF p_failure_count >= 2 THEN
        RETURN 'model_limit';
    END IF;

    RETURN 'unknown';
END;
$func$;

COMMENT ON FUNCTION stewards.diagnose_failure(text, int) IS
'Classify a failure reason into one of (transient | timeout | model_limit | tool_error | unknown).';

-- ---------------------------------------------------------------------
-- retry_guidance_text — per-diagnosis retry-context templates.
-- {attempt} is substituted by retry_guidance(). These defaults are
-- machinery (generic discipline text), not operator data.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.retry_guidance_text (
    diagnosis   text PRIMARY KEY CHECK (diagnosis IN
        ('transient','timeout','model_limit','tool_error','unknown')),
    template    text NOT NULL,
    notes       text
);

COMMENT ON TABLE stewards.retry_guidance_text IS
'Per-diagnosis retry-context templates. {attempt} is replaced with the current attempt number by retry_guidance().';

INSERT INTO stewards.retry_guidance_text (diagnosis, template, notes) VALUES
    ('transient',
     '**Steward retry context (attempt {attempt}):** Previous attempt failed with a transient provider issue (rate limit, 5xx, or network blip). The underlying issue has likely resolved. Proceed with the same approach.',
     'Same model, no strategy change'),
    ('timeout',
     '**Steward retry context (attempt {attempt}):** Previous attempt timed out. Break the work into smaller steps. Read files in targeted ranges rather than full files. Avoid loops that touch many tools in sequence. If you need to plan, plan tightly.',
     'Reduce per-step work to fit inside the timeout window'),
    ('tool_error',
     '**Steward retry context (attempt {attempt}):** Previous attempt failed with a tool error — the tool may not exist, the arguments may be wrong, or a schema check failed. Check the tool name against your available tools. Verify argument names and types. If the schema rejected your output, re-read the schema constraints carefully.',
     'Help the model self-correct on tool usage'),
    ('model_limit',
     '**Steward retry context (attempt {attempt}):** Previous attempts failed despite reasonable strategies, suggesting this task may be at the edge of what the current model can handle. Simplify the task. Re-read the plan/spec carefully. Identify the single most important next step and do only that. The next attempt will use a more capable model.',
     'Acknowledge the cliff; sets up the escalation'),
    ('unknown',
     '**Steward retry context (attempt {attempt}):** Previous attempt failed but the failure reason did not match a known pattern. Re-examine the input, the spec, and any error output from the last attempt. Be deliberate.',
     'Generic fallback')
ON CONFLICT (diagnosis) DO UPDATE
SET template = EXCLUDED.template,
    notes    = EXCLUDED.notes;

-- Compose retry guidance for a diagnosis + attempt. NULL if no
-- template exists (caller skips prepending guidance).
CREATE OR REPLACE FUNCTION stewards.retry_guidance(
    p_diagnosis text,
    p_attempt   int
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_template text;
BEGIN
    SELECT template INTO v_template
      FROM stewards.retry_guidance_text
     WHERE diagnosis = p_diagnosis;

    IF v_template IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN replace(v_template, '{attempt}', p_attempt::text);
END;
$func$;

COMMENT ON FUNCTION stewards.retry_guidance(text, int) IS
'Compose the per-diagnosis retry-context message with attempt number substituted.';

-- ---------------------------------------------------------------------
-- pipeline_breakers — per-(pipeline, stage) circuit breaker. Three
-- states: closed (normal) | open (cooling down) | half_open (probe).
-- failure_threshold trips it; cooldown elapses to half_open; success
-- on half-open closes; failure on half-open re-opens.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.pipeline_breakers (
    pipeline_family   text NOT NULL,
    stage_name        text NOT NULL,
    state             text NOT NULL DEFAULT 'closed' CHECK (state IN ('closed','open','half_open')),
    failure_count     int NOT NULL DEFAULT 0,
    opened_at         timestamptz,
    half_open_at      timestamptz,
    cooldown_minutes  int NOT NULL DEFAULT 10,
    failure_threshold int NOT NULL DEFAULT 5,
    last_state_change timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (pipeline_family, stage_name)
);

COMMENT ON TABLE stewards.pipeline_breakers IS
'Per-(pipeline_family, stage) circuit breaker. closed (normal) | open (cooling down) | half_open (probe). failure_threshold failures trip it; cooldown_minutes later one probe is allowed.';

-- Returns true if the breaker permits a dispatch. Lazy-creates the
-- breaker row; transitions open → half_open when cooldown elapses.
CREATE OR REPLACE FUNCTION stewards.breaker_check(
    p_pipeline text,
    p_stage    text
) RETURNS boolean
LANGUAGE plpgsql AS $func$
DECLARE
    v_breaker stewards.pipeline_breakers;
BEGIN
    INSERT INTO stewards.pipeline_breakers (pipeline_family, stage_name)
    VALUES (p_pipeline, p_stage)
    ON CONFLICT DO NOTHING;

    SELECT * INTO v_breaker
      FROM stewards.pipeline_breakers
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage
     FOR UPDATE;

    IF v_breaker.state = 'closed' THEN
        RETURN true;
    END IF;

    -- Half-open: one probe permitted; record_success/record_failure
    -- will close or re-open.
    IF v_breaker.state = 'half_open' THEN
        RETURN true;
    END IF;

    -- Open: transition to half_open when cooldown elapses.
    IF v_breaker.opened_at IS NOT NULL
       AND v_breaker.opened_at + (v_breaker.cooldown_minutes * interval '1 minute') <= now()
    THEN
        UPDATE stewards.pipeline_breakers
           SET state = 'half_open',
               half_open_at = now(),
               last_state_change = now()
         WHERE pipeline_family = p_pipeline AND stage_name = p_stage;
        RETURN true;
    END IF;

    RETURN false;
END;
$func$;

COMMENT ON FUNCTION stewards.breaker_check(text, text) IS
'Returns true if the breaker permits a dispatch. Lazy-creates breaker row; transitions open → half_open on cooldown.';

CREATE OR REPLACE FUNCTION stewards.breaker_record_failure(
    p_pipeline text,
    p_stage    text
) RETURNS void
LANGUAGE plpgsql AS $func$
DECLARE
    v_breaker stewards.pipeline_breakers;
BEGIN
    INSERT INTO stewards.pipeline_breakers (pipeline_family, stage_name)
    VALUES (p_pipeline, p_stage)
    ON CONFLICT DO NOTHING;

    SELECT * INTO v_breaker
      FROM stewards.pipeline_breakers
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage
     FOR UPDATE;

    IF v_breaker.state = 'half_open' THEN
        -- Probe failed. Re-open with fresh cooldown.
        UPDATE stewards.pipeline_breakers
           SET state = 'open',
               opened_at = now(),
               half_open_at = NULL,
               last_state_change = now(),
               failure_count = failure_count + 1
         WHERE pipeline_family = p_pipeline AND stage_name = p_stage;
        RETURN;
    END IF;

    UPDATE stewards.pipeline_breakers
       SET failure_count = failure_count + 1
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage;

    SELECT * INTO v_breaker
      FROM stewards.pipeline_breakers
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage;

    IF v_breaker.state = 'closed'
       AND v_breaker.failure_count >= v_breaker.failure_threshold
    THEN
        UPDATE stewards.pipeline_breakers
           SET state = 'open',
               opened_at = now(),
               last_state_change = now()
         WHERE pipeline_family = p_pipeline AND stage_name = p_stage;
    END IF;
END;
$func$;

CREATE OR REPLACE FUNCTION stewards.breaker_record_success(
    p_pipeline text,
    p_stage    text
) RETURNS void
LANGUAGE plpgsql AS $func$
BEGIN
    UPDATE stewards.pipeline_breakers
       SET state = 'closed',
           failure_count = 0,
           opened_at = NULL,
           half_open_at = NULL,
           last_state_change = now()
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage
       AND (state != 'closed' OR failure_count > 0);
END;
$func$;

COMMENT ON FUNCTION stewards.breaker_record_failure(text, text) IS
'Increment breaker failure_count; trip if threshold reached.';
COMMENT ON FUNCTION stewards.breaker_record_success(text, text) IS
'Reset breaker to closed state with failure_count=0.';

-- ---------------------------------------------------------------------
-- steward_tick — the orchestration, in its final form (4d isolation +
-- 6b lessons-aware retry guidance + 6c atonement-on-quarantine).
-- Returns count of actions taken; the bgworker calls it on tick and
-- logs the count.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.steward_tick()
RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_count               int := 0;
    v_item                record;
    v_diagnosis           text;
    v_next_model          text;
    v_breaker_ok          boolean;
    v_attempt             int;
    v_retry_text          text;
    v_dispatched_work_id  bigint;
    v_provider            text;
BEGIN
    FOR v_item IN
        SELECT id, pipeline_family, current_stage, failure_count,
               last_failure_reason, escalation_state
          FROM stewards.work_items
         WHERE status = 'failed'
           AND failure_count < 3
           AND quarantined_at IS NULL
           AND escalation_state = 'normal'
         ORDER BY updated_at ASC  -- oldest failures first
         LIMIT 10
         FOR UPDATE SKIP LOCKED
    LOOP
        -- Per-item exception isolation. Any error inside this block
        -- logs to steward_actions and the loop continues; one bad item
        -- never poisons the tick batch.
        BEGIN
            v_attempt := v_item.failure_count + 1;

            -- 1. Cost cap check
            IF stewards.cost_cap_exceeded(v_item.id) THEN
                UPDATE stewards.work_items
                   SET quarantined_at = now(),
                       quarantine_reason = 'cost_cap_exceeded'
                 WHERE id = v_item.id;

                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action, details)
                VALUES
                    (v_item.id,
                     'cumulative cost exceeded cap; quarantining',
                     'cost_limit',
                     'quarantine',
                     jsonb_build_object('quarantine_reason','cost_cap_exceeded'));

                -- Fire atonement on quarantine. No-op when the
                -- pipeline's atonement_enabled is false.
                PERFORM stewards.maybe_enqueue_atonement(v_item.id);

                v_count := v_count + 1;
                CONTINUE;
            END IF;

            -- 2. Diagnose (cached on the work_item for visibility)
            v_diagnosis := stewards.diagnose_failure(
                v_item.last_failure_reason, v_item.failure_count);
            UPDATE stewards.work_items
               SET last_failure_diagnosis = v_diagnosis
             WHERE id = v_item.id;

            -- 3. Breaker check
            v_breaker_ok := stewards.breaker_check(
                v_item.pipeline_family, v_item.current_stage);
            IF NOT v_breaker_ok THEN
                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action)
                VALUES
                    (v_item.id,
                     format('breaker open for %s/%s; deferring',
                            v_item.pipeline_family, v_item.current_stage),
                     v_diagnosis,
                     'defer_breaker_open');
                v_count := v_count + 1;
                CONTINUE;
            END IF;

            -- 4. Pick model (raises if no stage_models row exists;
            -- caught by the per-item EXCEPTION below)
            v_next_model := stewards.pick_model(
                v_item.pipeline_family, v_item.current_stage,
                v_attempt, v_diagnosis);

            -- 5. Queue sentinel → human-mediated escalation
            IF v_next_model = '__queue_for_opus__' THEN
                UPDATE stewards.work_items
                   SET escalation_state = 'queued',
                       escalation_attempts = escalation_attempts + 1
                 WHERE id = v_item.id;

                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action, model_used,
                     details)
                VALUES
                    (v_item.id,
                     'escalation chain exhausted; queued for human-mediated boost',
                     v_diagnosis,
                     'queue_for_opus',
                     '__queue_for_opus__',
                     jsonb_build_object(
                         'attempt', v_attempt,
                         'escalation_attempts',
                             (SELECT escalation_attempts FROM stewards.work_items
                               WHERE id = v_item.id)));
                v_count := v_count + 1;
                CONTINUE;
            END IF;

            -- 6. Resolve provider from model_pricing (each model knows
            -- its provider; that's the canonical mapping). NULL when
            -- the model has no pricing row — then no provider override
            -- is set and the stage's own provider applies at dispatch.
            SELECT provider INTO v_provider
              FROM stewards.model_pricing
             WHERE model = v_next_model
             ORDER BY effective_at DESC
             LIMIT 1;

            -- 7. Retry path: lessons-aware guidance, set overrides,
            -- dispatch, account.
            v_retry_text := stewards.retry_guidance_with_lessons(
                v_diagnosis, v_attempt,
                v_item.pipeline_family, v_item.current_stage);

            UPDATE stewards.work_items
               SET model_override     = v_next_model,
                   provider_override  = v_provider,
                   failure_count      = failure_count + 1
             WHERE id = v_item.id;

            v_dispatched_work_id := stewards.work_item_dispatch_stage(
                v_item.id, v_retry_text, true);

            INSERT INTO stewards.steward_actions
                (work_item_id, observation, diagnosis, action, model_used,
                 details)
            VALUES
                (v_item.id,
                 format('attempt #%s after %s; dispatched as work_id %s',
                        v_attempt, v_diagnosis, v_dispatched_work_id),
                 v_diagnosis,
                 'retry_dispatched',
                 v_next_model,
                 jsonb_build_object(
                     'attempt', v_attempt,
                     'retry_guidance', v_retry_text,
                     'dispatched_work_id', v_dispatched_work_id,
                     'provider_override', v_provider));

            v_count := v_count + 1;
        EXCEPTION WHEN OTHERS THEN
            -- Per-item failure isolation. The BEGIN block's
            -- sub-transaction rolled back this item's partial work;
            -- log in a fresh sub-transaction and move on.
            BEGIN
                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action, details)
                VALUES
                    (v_item.id,
                     'tick error: ' || SQLERRM,
                     COALESCE(v_diagnosis, 'unknown'),
                     'tick_error',
                     jsonb_build_object(
                         'sqlerrm', SQLERRM,
                         'sqlstate', SQLSTATE,
                         'pipeline_family', v_item.pipeline_family,
                         'current_stage', v_item.current_stage));
            EXCEPTION WHEN OTHERS THEN
                NULL;  -- if even logging fails, keep the loop alive
            END;
            v_count := v_count + 1;
        END;
    END LOOP;

    RETURN v_count;
END;
$func$;

COMMENT ON FUNCTION stewards.steward_tick() IS
'Watch→Diagnose→Act→Account orchestration, final form: per-item exception isolation, lessons-aware retry guidance (retry_guidance_with_lessons), provider derived from model_pricing (NULL = stage provider applies), cost-cap quarantine fires maybe_enqueue_atonement (no-op when the pipeline opts out). Returns count of actions taken. Called by the bgworker on tick.';

-- ---------------------------------------------------------------------
-- work_items_steward_status — latest steward_action per work_item,
-- joined with the work_item. For status panels.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.work_items_steward_status AS
SELECT
    wi.id                       AS work_item_id,
    wi.slug,
    wi.pipeline_family,
    wi.current_stage,
    wi.status,
    wi.failure_count,
    wi.last_failure_diagnosis,
    wi.escalation_state,
    wi.quarantined_at,
    wi.quarantine_reason,
    wi.cost_micro_dollars,
    wi.cost_cap_micro,
    wi.cost_capped_at,
    sa.at                       AS last_action_at,
    sa.observation              AS last_observation,
    sa.action                   AS last_action,
    sa.model_used               AS last_model_used,
    sa.diagnosis                AS last_action_diagnosis
  FROM stewards.work_items wi
  LEFT JOIN LATERAL (
      SELECT * FROM stewards.steward_actions
       WHERE work_item_id = wi.id
       ORDER BY at DESC
       LIMIT 1
  ) sa ON true;

COMMENT ON VIEW stewards.work_items_steward_status IS
'Per-work_item status with the most recent steward_action surfaced. For status panels.';
