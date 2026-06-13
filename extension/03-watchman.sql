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
