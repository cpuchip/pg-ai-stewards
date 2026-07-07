-- ===== [was 00-config.sql] =====
-- =====================================================================
-- 00-config — the substrate's configuration surface
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg; NEW — rebuild lesson #4).
-- One key/value table for the dials that used to live as magic numbers
-- inside function bodies and Rust source: the default intent slug
-- (was hardcoded 'scripture-study' in yaml.rs/k4/j5/j8c/j9c/j12),
-- context pressure tiers, provider-specific chars-per-token estimators.
--
-- Convention: values are jsonb. Seeds here are defaults — operators own
-- the rows after install (ON CONFLICT DO NOTHING; upgrades never
-- overwrite an operator's setting).
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.config (
    key         text PRIMARY KEY,
    value       jsonb NOT NULL,
    description text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.config IS
  'Substrate configuration: one row per dial. Values are jsonb. '
  'Seeded with defaults at install; operator-owned afterward.';

CREATE OR REPLACE FUNCTION stewards.config_get(p_key text, p_default jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT value FROM stewards.config WHERE key = p_key), p_default);
$$;

CREATE OR REPLACE FUNCTION stewards.config_get_text(p_key text, p_default text DEFAULT NULL)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT value #>> '{}' FROM stewards.config WHERE key = p_key), p_default);
$$;

CREATE OR REPLACE FUNCTION stewards.config_set(p_key text, p_value jsonb, p_description text DEFAULT NULL)
RETURNS void
LANGUAGE sql AS $$
    INSERT INTO stewards.config (key, value, description, updated_at)
    VALUES (p_key, p_value, p_description, now())
    ON CONFLICT (key) DO UPDATE
       SET value = EXCLUDED.value,
           description = COALESCE(EXCLUDED.description, stewards.config.description),
           updated_at = now();
$$;

-- Defaults. Operators change these with config_set(); upgrades never
-- overwrite them.
INSERT INTO stewards.config (key, value, description) VALUES
  ('default_intent_slug', '"default"'::jsonb,
   'Intent slug bound to work created without an explicit intent. Seed an intent with this slug (the seed pack does) or change this key.'),
  ('context_pressure_tiers', '[0.50, 0.70, 0.85, 0.95]'::jsonb,
   'Context-engine pressure thresholds as fractions of the model window. Rendering degrades gracefully tier by tier.'),
  ('chars_per_token_default', '3.5'::jsonb,
   'Fallback token estimator. Provider-specific overrides live under chars_per_token.<provider> keys.'),
  ('chars_per_token.anthropic', '3.8'::jsonb,
   'Anthropic-family estimator (content multipliers may refine later).'),
  ('chars_per_token.openai', '4.0'::jsonb,
   'OpenAI-format estimator.')
ON CONFLICT (key) DO NOTHING;

-- =====================================================================
-- Migration ledger (relocated from h-ledger-1 at the B4 consolidation).
--
-- In the consolidated bundle the runtime manifest starts EMPTY — CREATE
-- EXTENSION installs the whole core atomically, so the original
-- chicken-and-egg ("the ledger file is itself one of the migrations")
-- is gone. The table must instead be born by the bundle so the runtime
-- runner (stewards-cli migrate) has somewhere to record overlay
-- migrations and going-forward core hotfixes. It is pure infrastructure
-- with no dependencies, so it lives here in the foundation file.
--
-- Columns:
--   name        — base filename minus .sql (e.g. 'seed-workstreams')
--   sha256      — hex of file contents at apply time (catches drift)
--   applied_at  — when the runner recorded it
--   notes       — 'backfilled', 'auto', 'manual', or freeform
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.schema_migrations (
    name        text PRIMARY KEY,
    sha256      text NOT NULL,
    applied_at  timestamp with time zone NOT NULL DEFAULT now(),
    notes       text
);

COMMENT ON TABLE stewards.schema_migrations IS
'Tracks which runtime-tier .sql files the migrator has applied. stewards-cli migrate reads files in lexical order, checks this table, applies unrecorded ones one tx each, records on success. sha256 tracks file content at apply time; if a recorded file changes later, the migrator warns + skips (catches the silent-overwrite regression class). In the consolidated OSS core this table is born by CREATE EXTENSION (the runtime manifest starts empty); the runner records the overlay tier into it.';

-- is_applied(name) → bool
CREATE OR REPLACE FUNCTION stewards.migration_is_applied(p_name text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM stewards.schema_migrations WHERE name = p_name);
$$;

-- mark_applied(name, sha, notes) — idempotent; returns true if newly recorded
CREATE OR REPLACE FUNCTION stewards.migration_mark_applied(
    p_name text, p_sha256 text, p_notes text DEFAULT 'auto'
) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_existed boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM stewards.schema_migrations WHERE name = p_name) INTO v_existed;
    INSERT INTO stewards.schema_migrations (name, sha256, notes)
    VALUES (p_name, p_sha256, p_notes)
    ON CONFLICT (name) DO NOTHING;
    RETURN NOT v_existed;
END;
$$;
-- ===== [was 01-graph.sql] =====
-- =====================================================================
-- 01-graph — the relational graph (nodes, edges, walks)
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg; NEW — replaces Apache AGE).
-- Ratified design: plain tables + recursive CTEs give the substrate
-- everything it used AGE for, with the full Postgres toolbox (indexes,
-- RLS, partitioning) and none of the install friction. Prior art:
-- adjacency-list edge tables; SQL:2023 PGQ; Facebook TAO.
--
-- Design inputs (ratified 2026-06-12):
--   - N-depth walks are a requirement: docs CHAIN (BUILDS_ON lineage).
--   - Cycles are SAFE in the data graph — walks terminate via visited-
--     path arrays. The WORK graph keeps its own depth caps (subagents);
--     that wall is governance, not storage.
--   - Edge kinds are open data: CITES, BUILDS_ON, DECLARED today;
--     a new kind is a new row, never a schema change.
--
-- Generic by design: doc-specific conveniences (doc_lineage,
-- doc_citations) live with the corpus subsystem, built on these walks.
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.nodes (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind       text NOT NULL,            -- 'doc' | 'workstream' | 'todo' | 'phase' | ...
    ref        text,                     -- stable external reference (doc slug, WS code)
    label      text,
    props      jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ref is the upsert identity when present; allow ref-less anonymous nodes.
CREATE UNIQUE INDEX IF NOT EXISTS nodes_kind_ref_uq
    ON stewards.nodes (kind, ref) WHERE ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS nodes_kind_idx ON stewards.nodes (kind);

CREATE TABLE IF NOT EXISTS stewards.edges (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    src        uuid NOT NULL REFERENCES stewards.nodes(id) ON DELETE CASCADE,
    dst        uuid NOT NULL REFERENCES stewards.nodes(id) ON DELETE CASCADE,
    kind       text NOT NULL,            -- 'CITES' | 'BUILDS_ON' | 'DECLARED' | ...
    weight     real NOT NULL DEFAULT 1.0,
    props      jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (src, dst, kind)
);

CREATE INDEX IF NOT EXISTS edges_src_kind_idx ON stewards.edges (src, kind);
CREATE INDEX IF NOT EXISTS edges_dst_kind_idx ON stewards.edges (dst, kind);

COMMENT ON TABLE stewards.nodes IS
  'Graph vertices. kind+ref is the stable identity for upserts; props is open jsonb.';
COMMENT ON TABLE stewards.edges IS
  'Typed, weighted, directed edges. Edge kinds are open data — adding a kind is a row, not a migration.';

-- ---------------------------------------------------------------------
-- Upsert helpers (ref-based, for importers and tools)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.graph_node_upsert(
    p_kind text, p_ref text, p_label text DEFAULT NULL, p_props jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO stewards.nodes (kind, ref, label, props)
    VALUES (p_kind, p_ref, p_label, COALESCE(p_props, '{}'::jsonb))
    ON CONFLICT (kind, ref) WHERE ref IS NOT NULL
    DO UPDATE SET label = COALESCE(EXCLUDED.label, stewards.nodes.label),
                  props = stewards.nodes.props || EXCLUDED.props,
                  updated_at = now()
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION stewards.graph_edge_upsert(
    p_src_kind text, p_src_ref text,
    p_dst_kind text, p_dst_ref text,
    p_edge_kind text,
    p_weight real DEFAULT 1.0,
    p_props jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_src uuid;
    v_dst uuid;
    v_id  uuid;
BEGIN
    v_src := stewards.graph_node_upsert(p_src_kind, p_src_ref);
    v_dst := stewards.graph_node_upsert(p_dst_kind, p_dst_ref);
    INSERT INTO stewards.edges (src, dst, kind, weight, props)
    VALUES (v_src, v_dst, p_edge_kind, p_weight, COALESCE(p_props, '{}'::jsonb))
    ON CONFLICT (src, dst, kind)
    DO UPDATE SET weight = EXCLUDED.weight,
                  props  = stewards.edges.props || EXCLUDED.props
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Walks
--
-- graph_walk: the workhorse. N-depth (p_max_depth is a parameter, not a
-- ceiling), direction 'out' | 'in' | 'both', optional edge-kind filter
-- (NULL = all kinds). Cycle-safe via the visited-path array; returns
-- the path so callers can render lineage chains.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.graph_walk(
    p_start uuid,
    p_edge_kinds text[] DEFAULT NULL,
    p_max_depth int DEFAULT 10,
    p_direction text DEFAULT 'out'
) RETURNS TABLE (node_id uuid, depth int, path uuid[])
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE walk(node_id, depth, path) AS (
        SELECT p_start, 0, ARRAY[p_start]
        UNION ALL
        SELECT CASE WHEN e.src = w.node_id THEN e.dst ELSE e.src END,
               w.depth + 1,
               w.path || CASE WHEN e.src = w.node_id THEN e.dst ELSE e.src END
          FROM walk w
          JOIN stewards.edges e
            ON (   (p_direction IN ('out','both') AND e.src = w.node_id)
                OR (p_direction IN ('in','both')  AND e.dst = w.node_id))
         WHERE w.depth < p_max_depth
           AND (p_edge_kinds IS NULL OR e.kind = ANY(p_edge_kinds))
           AND NOT (CASE WHEN e.src = w.node_id THEN e.dst ELSE e.src END) = ANY(w.path)
    )
    SELECT node_id, depth, path FROM walk;
$$;

-- Convenience over refs: walk from (kind, ref), join labels back on.
CREATE OR REPLACE FUNCTION stewards.graph_walk_ref(
    p_kind text, p_ref text,
    p_edge_kinds text[] DEFAULT NULL,
    p_max_depth int DEFAULT 10,
    p_direction text DEFAULT 'out'
) RETURNS TABLE (node_id uuid, node_kind text, node_ref text, label text, depth int)
LANGUAGE sql STABLE AS $$
    SELECT n.id, n.kind, n.ref, n.label, w.depth
      FROM stewards.graph_walk(
               (SELECT id FROM stewards.nodes WHERE kind = p_kind AND ref = p_ref),
               p_edge_kinds, p_max_depth, p_direction) w
      JOIN stewards.nodes n ON n.id = w.node_id;
$$;

-- Direct neighbors with edge metadata (1-hop, both directions labeled).
CREATE OR REPLACE FUNCTION stewards.graph_neighbors(
    p_node uuid, p_edge_kinds text[] DEFAULT NULL
) RETURNS TABLE (node_id uuid, edge_kind text, direction text, weight real, props jsonb)
LANGUAGE sql STABLE AS $$
    SELECT e.dst, e.kind, 'out', e.weight, e.props
      FROM stewards.edges e
     WHERE e.src = p_node AND (p_edge_kinds IS NULL OR e.kind = ANY(p_edge_kinds))
    UNION ALL
    SELECT e.src, e.kind, 'in', e.weight, e.props
      FROM stewards.edges e
     WHERE e.dst = p_node AND (p_edge_kinds IS NULL OR e.kind = ANY(p_edge_kinds));
$$;
-- ===== [was 02-workstreams.sql] =====
-- =====================================================================
-- 02-workstreams — workstreams, todos, phases, and the context walk
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Re-authors the historical
-- 2-6a / 2-6b / 2-6c migrations ON the relational graph (01-graph.sql):
-- every AGE cypher() call is gone; vertices live in stewards.nodes,
-- typed edges in stewards.edges, and the context walk is a recursive
-- CTE instead of an iterative temp-table loop.
--
-- Node kinds used here: 'workstream', 'doc', 'todo'.
-- Edge kinds: HAS_PROPOSAL, FEEDS, SUPERSEDES, IMPLEMENTS, HAS_TODO,
--             HAS_PHASE — plus CITES / SIMILAR_TO written by the docs
--             subsystem. Edge kinds are open data; adding one is a row.
-- Declared-provenance edges carry props:
--   {provenance:'declared', confidence:1.0, source:'<where it came from>'}
-- =====================================================================

-- ============================================================
-- Table: stewards.workstreams
-- ============================================================
CREATE TABLE IF NOT EXISTS stewards.workstreams (
    id          text PRIMARY KEY,
    name        text NOT NULL,
    description text NOT NULL DEFAULT '',
    status      text NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'paused', 'retired')),
    -- Free-form bag for things that haven't earned columns yet.
    frontmatter jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS workstreams_status_idx
    ON stewards.workstreams (status);

-- ============================================================
-- Function: import_workstream(id, name, description, status)
--
-- Upserts the workstreams row AND the 'workstream' graph node.
-- Returns the id. No seeds here — workstream taxonomies are
-- operator data and live in the downstream overlay tier.
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.import_workstream(
    p_id          text,
    p_name        text,
    p_description text DEFAULT '',
    p_status      text DEFAULT 'active'
) RETURNS text
LANGUAGE plpgsql AS $func$
BEGIN
    INSERT INTO stewards.workstreams (id, name, description, status)
    VALUES (p_id, p_name, p_description, p_status)
    ON CONFLICT (id) DO UPDATE
        SET name        = EXCLUDED.name,
            description = EXCLUDED.description,
            status      = EXCLUDED.status,
            updated_at  = now();

    PERFORM stewards.graph_node_upsert(
        'workstream', p_id, p_name,
        jsonb_build_object('status', p_status));

    RETURN p_id;
END;
$func$;

-- ============================================================
-- Function: link_declared_edges(slug, frontmatter)
--
-- Reads workstream/feeds/supersedes/implements from a doc's
-- frontmatter and writes declared-provenance edges:
--   workstream -[HAS_PROPOSAL]-> doc
--   doc        -[FEEDS]->        doc
--   doc        -[SUPERSEDES]->   doc
--   doc        -[IMPLEMENTS]->   doc
--
-- Drops existing declared-provenance edges from this doc first so
-- re-imports stay in sync. Parsed edges (CITES) and inferred edges
-- (SIMILAR_TO) are not touched.
--
-- Frontmatter shapes accepted:
--   workstream: WS5                       -- string
--   feeds: [other-slug]                   -- array
--   feeds: other-slug                     -- string (single)
--   supersedes: [a, b]
--   implements: [a]
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.link_declared_edges(
    p_slug        text,
    p_frontmatter jsonb
) RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_count    int := 0;
    v_doc      uuid;
    v_ws_id    text;
    v_target   text;
    v_targets  text[];
    v_relation text;
BEGIN
    -- Ensure the doc node exists (import_doc normally created it).
    v_doc := stewards.graph_node_upsert('doc', p_slug);

    -- 1. Drop existing declared-provenance edges FROM this doc
    --    (CITES excluded — that's parse provenance, owned by import_doc).
    DELETE FROM stewards.edges e
     WHERE e.src = v_doc
       AND e.kind <> 'CITES'
       AND e.props->>'provenance' = 'declared';

    -- 2. Drop incoming declared HAS_PROPOSAL edges (workstream membership).
    DELETE FROM stewards.edges e
     WHERE e.dst = v_doc
       AND e.kind = 'HAS_PROPOSAL'
       AND e.props->>'provenance' = 'declared';

    -- 3. Workstream membership. graph_edge_upsert creates a bare
    --    workstream node if the doc references one not yet seeded;
    --    import_workstream() fills in the name later.
    v_ws_id := p_frontmatter->>'workstream';
    IF v_ws_id IS NOT NULL AND v_ws_id <> '' THEN
        PERFORM stewards.graph_edge_upsert(
            'workstream', v_ws_id, 'doc', p_slug, 'HAS_PROPOSAL', 1.0,
            jsonb_build_object('provenance', 'declared',
                               'confidence', 1.0,
                               'source', 'frontmatter:workstream'));
        v_count := v_count + 1;
    END IF;

    -- 4. Typed semantic edges: feeds / supersedes / implements
    FOREACH v_relation IN ARRAY ARRAY['feeds', 'supersedes', 'implements']
    LOOP
        v_targets := NULL;

        IF jsonb_typeof(p_frontmatter->v_relation) = 'array' THEN
            SELECT array_agg(value) INTO v_targets
            FROM jsonb_array_elements_text(p_frontmatter->v_relation) AS value;
        ELSIF jsonb_typeof(p_frontmatter->v_relation) = 'string' THEN
            v_targets := ARRAY[p_frontmatter->>v_relation];
        END IF;

        IF v_targets IS NULL THEN CONTINUE; END IF;

        FOREACH v_target IN ARRAY v_targets
        LOOP
            IF v_target IS NULL OR v_target = '' THEN CONTINUE; END IF;

            PERFORM stewards.graph_edge_upsert(
                'doc', p_slug, 'doc', v_target, upper(v_relation), 1.0,
                jsonb_build_object('provenance', 'declared',
                                   'confidence', 1.0,
                                   'source', 'frontmatter:' || v_relation));
            v_count := v_count + 1;
        END LOOP;
    END LOOP;

    RETURN v_count;
END;
$func$;

-- ============================================================
-- Read function: workstream_proposals(ws_id) — list docs declared
-- as belonging to a workstream. LEFT JOIN because a declared edge
-- may point at a doc not yet imported as a row.
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.workstream_proposals(p_ws_id text)
RETURNS TABLE (slug text, kind text, title text, file_path text)
LANGUAGE sql STABLE AS $func$
    SELECT n.ref, d.kind, d.title, d.file_path
      FROM stewards.edges e
      JOIN stewards.nodes w ON w.id = e.src
                           AND w.kind = 'workstream' AND w.ref = p_ws_id
      JOIN stewards.nodes n ON n.id = e.dst
      LEFT JOIN stewards.docs d ON d.slug = n.ref
     WHERE e.kind = 'HAS_PROPOSAL'
     ORDER BY n.ref;
$func$;

-- ============================================================
-- Read function: declared_edges(slug) — list outbound declared
-- edges from a doc (CITES excluded).
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.declared_edges(p_slug text)
RETURNS TABLE (
    from_slug    text,
    edge_type    text,
    to_slug      text,
    provenance   text,
    confidence   float,
    source       text
)
LANGUAGE sql STABLE AS $func$
    SELECT s.ref,
           e.kind,
           t.ref,
           e.props->>'provenance',
           (e.props->>'confidence')::float,
           e.props->>'source'
      FROM stewards.edges e
      JOIN stewards.nodes s ON s.id = e.src
                           AND s.kind = 'doc' AND s.ref = p_slug
      JOIN stewards.nodes t ON t.id = e.dst
     WHERE e.kind <> 'CITES'
       AND e.props->>'provenance' IS NOT NULL
     ORDER BY e.kind, t.ref;
$func$;

-- ============================================================
-- Table: stewards.todos
--
-- Todos live in their own table (not stewards.docs) because their
-- lifecycle is different: rapid mutation (status changes) vs.
-- write-once+versioned (docs). The HAS_TODO edge connects parent
-- (workstream | doc | todo) to the todo node. Parent fields are
-- denormalized on the row for fast roll-up audits without a walk.
--
-- Single-write rule: stewards.create_todo() writes BOTH the row
-- AND the graph edge in one transaction. Never INSERT directly.
-- ============================================================
CREATE TABLE IF NOT EXISTS stewards.todos (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Optional human-friendly slug. NULL allowed because most todos
    -- are session-scoped and don't earn a slug; long-lived ones do.
    slug        text UNIQUE,
    title       text NOT NULL,
    body        text NOT NULL DEFAULT '',
    status      text NOT NULL DEFAULT 'open'
                CHECK (status IN ('open', 'in_progress', 'done', 'dropped')),

    -- Parent denormalization. parent_kind is the graph node kind
    -- ('workstream', 'doc', 'todo'). parent_slug is the node's ref
    -- (workstream id, doc slug, or todo uuid-as-text). Both nullable
    -- for free-floating todos but the create function rejects that.
    parent_kind text,
    parent_slug text,

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,

    created_by_session   text,
    completed_by_session text,

    frontmatter jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS todos_status_idx ON stewards.todos (status);
CREATE INDEX IF NOT EXISTS todos_parent_idx
    ON stewards.todos (parent_kind, parent_slug);
CREATE INDEX IF NOT EXISTS todos_created_idx
    ON stewards.todos (created_at DESC);

-- touch trigger
CREATE OR REPLACE FUNCTION stewards.touch_todo() RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        NEW.updated_at := now();
        -- Auto-stamp completed_at on transition into a terminal state.
        IF NEW.status IN ('done', 'dropped')
           AND OLD.status NOT IN ('done', 'dropped')
           AND NEW.completed_at IS NULL
        THEN
            NEW.completed_at := now();
        END IF;
    END IF;
    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS todos_touch ON stewards.todos;
CREATE TRIGGER todos_touch
    BEFORE UPDATE ON stewards.todos
    FOR EACH ROW EXECUTE FUNCTION stewards.touch_todo();

-- ============================================================
-- Function: create_todo(parent_kind, parent_slug, title, body, slug, session)
--
-- Single-write rule: row + todo node + HAS_TODO edge in one
-- transaction. Returns the new uuid.
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.create_todo(
    p_parent_kind text,
    p_parent_slug text,
    p_title       text,
    p_body        text DEFAULT '',
    p_slug        text DEFAULT NULL,
    p_session     text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_id uuid;
BEGIN
    IF p_parent_kind IS NULL OR p_parent_slug IS NULL THEN
        RAISE EXCEPTION 'create_todo: parent_kind and parent_slug required (free-floating todos not allowed)';
    END IF;
    IF p_parent_kind NOT IN ('workstream', 'doc', 'todo') THEN
        RAISE EXCEPTION 'create_todo: parent_kind must be one of workstream|doc|todo, got %', p_parent_kind;
    END IF;

    INSERT INTO stewards.todos (slug, title, body, parent_kind, parent_slug, created_by_session)
    VALUES (p_slug, p_title, p_body, p_parent_kind, p_parent_slug, p_session)
    RETURNING id INTO v_id;

    PERFORM stewards.graph_node_upsert(
        'todo', v_id::text, p_title,
        jsonb_build_object('status', 'open', 'slug', coalesce(p_slug, '')));

    PERFORM stewards.graph_edge_upsert(
        p_parent_kind, p_parent_slug, 'todo', v_id::text, 'HAS_TODO', 1.0,
        jsonb_build_object('provenance', 'declared',
                           'confidence', 1.0,
                           'source', 'create_todo'));

    RETURN v_id;
END;
$func$;

-- ============================================================
-- Function: complete_todo(id_or_slug, session, status)
--
-- Marks a todo done, syncs the todo node's status prop.
-- Accepts either uuid or slug for ergonomics from the CLI.
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.complete_todo(
    p_ref     text,           -- uuid string or slug
    p_session text DEFAULT NULL,
    p_status  text DEFAULT 'done'
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_id uuid;
BEGIN
    IF p_status NOT IN ('done', 'dropped', 'in_progress', 'open') THEN
        RAISE EXCEPTION 'complete_todo: invalid status %', p_status;
    END IF;

    -- Resolve ref to id. Try uuid cast first; fall back to slug lookup.
    BEGIN
        v_id := p_ref::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        SELECT id INTO v_id FROM stewards.todos WHERE slug = p_ref;
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'complete_todo: no todo with id-or-slug %', p_ref;
        END IF;
    END;

    UPDATE stewards.todos
       SET status = p_status,
           completed_by_session = CASE WHEN p_status IN ('done','dropped')
                                       THEN p_session ELSE completed_by_session END
     WHERE id = v_id;

    UPDATE stewards.nodes
       SET props = props || jsonb_build_object('status', p_status),
           updated_at = now()
     WHERE kind = 'todo' AND ref = v_id::text;

    RETURN v_id;
END;
$func$;

-- ============================================================
-- Function: todo_rollup_audit()
--
-- Returns rows where the parent/child status invariants are broken:
--   - parent is done but has open/in_progress children
--   - all children are done but parent is still open/in_progress
--
-- Watchman calls this periodically to find dangling state.
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.todo_rollup_audit()
RETURNS TABLE (
    finding      text,    -- 'parent_done_open_children' | 'all_done_parent_open'
    parent_kind  text,
    parent_slug  text,
    parent_title text,    -- best-effort label for human reading
    todo_count   int,
    open_count   int,
    done_count   int
)
LANGUAGE plpgsql STABLE AS $func$
BEGIN
    RETURN QUERY
    WITH child_counts AS (
        SELECT t.parent_kind,
               t.parent_slug,
               COUNT(*)::int                                          AS todo_count,
               COUNT(*) FILTER (WHERE t.status IN ('open','in_progress'))::int AS open_count,
               COUNT(*) FILTER (WHERE t.status = 'done')::int         AS done_count
          FROM stewards.todos t
         GROUP BY t.parent_kind, t.parent_slug
    ),
    -- Self-check on todo-as-parent. We treat a todo parent as "done"
    -- if its row.status is done.
    parents AS (
        SELECT cc.*,
               CASE
                   WHEN cc.parent_kind = 'todo'
                   THEN (SELECT pt.status FROM stewards.todos pt
                          WHERE pt.id::text = cc.parent_slug
                             OR pt.slug    = cc.parent_slug LIMIT 1)
                   -- For non-todo parents we can't generically know
                   -- "done" without per-kind status. Treat as 'open'
                   -- so we only flag the all-done-parent-open finding
                   -- via Watchman's later kind-specific query.
                   ELSE 'open'
               END AS parent_status,
               CASE
                   WHEN cc.parent_kind = 'workstream'
                   THEN (SELECT name FROM stewards.workstreams WHERE id = cc.parent_slug)
                   WHEN cc.parent_kind = 'doc'
                   THEN (SELECT title FROM stewards.docs WHERE slug = cc.parent_slug)
                   WHEN cc.parent_kind = 'todo'
                   THEN (SELECT title FROM stewards.todos
                          WHERE id::text = cc.parent_slug
                             OR slug    = cc.parent_slug LIMIT 1)
                   ELSE NULL
               END AS parent_title
          FROM child_counts cc
    )
    -- Finding 1: parent done, open children
    SELECT 'parent_done_open_children'::text,
           p.parent_kind, p.parent_slug, p.parent_title,
           p.todo_count, p.open_count, p.done_count
      FROM parents p
     WHERE p.parent_status IN ('done', 'dropped')
       AND p.open_count > 0
    UNION ALL
    -- Finding 2: all children done, parent still open (only meaningful
    -- for parent_kind='todo' until per-kind status is added).
    SELECT 'all_done_parent_open'::text,
           p.parent_kind, p.parent_slug, p.parent_title,
           p.todo_count, p.open_count, p.done_count
      FROM parents p
     WHERE p.parent_kind = 'todo'
       AND p.parent_status IN ('open', 'in_progress')
       AND p.open_count = 0
       AND p.done_count > 0
     ORDER BY 1, 2, 3;
END;
$func$;

-- ============================================================
-- Read function: list_todos(parent_kind, parent_slug, status)
--
-- All three filters optional. NULL = no filter on that dimension.
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.list_todos(
    p_parent_kind text DEFAULT NULL,
    p_parent_slug text DEFAULT NULL,
    p_status      text DEFAULT NULL
) RETURNS TABLE (
    id           uuid,
    slug         text,
    title        text,
    status       text,
    parent_kind  text,
    parent_slug  text,
    created_at   timestamptz,
    completed_at timestamptz
)
LANGUAGE sql STABLE AS $func$
    SELECT t.id, t.slug, t.title, t.status,
           t.parent_kind, t.parent_slug,
           t.created_at, t.completed_at
      FROM stewards.todos t
     WHERE (p_parent_kind IS NULL OR t.parent_kind = p_parent_kind)
       AND (p_parent_slug IS NULL OR t.parent_slug = p_parent_slug)
       AND (p_status      IS NULL OR t.status      = p_status)
     ORDER BY t.parent_kind, t.parent_slug, t.created_at DESC;
$func$;

-- ============================================================
-- Function: link_phase_to_doc(phase_slug, parent_doc_slug)
--
-- HAS_PHASE edge from the parent doc to the phase doc. Both are
-- 'doc' nodes; the discriminator is the docs row's kind column.
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.link_phase_to_doc(
    p_phase_slug      text,
    p_parent_doc_slug text
) RETURNS void
LANGUAGE plpgsql AS $func$
BEGIN
    PERFORM stewards.graph_edge_upsert(
        'doc', p_parent_doc_slug, 'doc', p_phase_slug, 'HAS_PHASE', 1.0,
        jsonb_build_object('provenance', 'declared',
                           'confidence', 1.0,
                           'source', 'phase_split'));
END;
$func$;

-- ============================================================
-- Function: context_for(slug, depth)
--
-- Walks the graph from any node whose ref matches the slug (doc
-- slug, workstream id, todo uuid), both directions, up to `depth`
-- hops (clamped 1..4 — this is the bounded context tool; use
-- graph_walk for arbitrary-depth walks). Returns one row per
-- distinct neighbor; the closest hop wins. Cycle-safe via the
-- per-path visited array.
-- ============================================================
CREATE OR REPLACE FUNCTION stewards.context_for(
    p_slug  text,
    p_depth int DEFAULT 2
) RETURNS TABLE (
    hop           int,
    direction     text,
    edge_type     text,
    neighbor      text,
    neighbor_kind text,
    provenance    text,
    confidence    float
)
LANGUAGE sql STABLE AS $func$
    WITH RECURSIVE walk(node_id, hop, path, direction, edge_kind, edge_props) AS (
        SELECT n.id, 0, ARRAY[n.id], NULL::text, NULL::text, NULL::jsonb
          FROM stewards.nodes n
         WHERE n.ref = p_slug
        UNION ALL
        SELECT v.next_id,
               w.hop + 1,
               w.path || v.next_id,
               v.dir,
               e.kind,
               e.props
          FROM walk w
          JOIN stewards.edges e
            ON (e.src = w.node_id OR e.dst = w.node_id)
          CROSS JOIN LATERAL (
              SELECT CASE WHEN e.src = w.node_id THEN e.dst ELSE e.src END AS next_id,
                     CASE WHEN e.src = w.node_id THEN 'out'  ELSE 'in'  END AS dir
          ) v
         WHERE w.hop < greatest(1, least(p_depth, 4))
           AND NOT v.next_id = ANY(w.path)
    ),
    closest AS (
        SELECT DISTINCT ON (w.node_id)
               w.hop, w.direction, w.edge_kind, w.edge_props, w.node_id
          FROM walk w
         WHERE w.hop > 0
         ORDER BY w.node_id, w.hop
    )
    SELECT c.hop,
           c.direction,
           c.edge_kind,
           coalesce(n.ref, n.id::text),
           n.kind,
           coalesce(c.edge_props->>'provenance', 'unknown'),
           coalesce((c.edge_props->>'confidence')::float, 0.0)
      FROM closest c
      JOIN stewards.nodes n ON n.id = c.node_id
     ORDER BY c.hop, c.direction DESC, c.edge_kind, coalesce(n.ref, n.id::text);
$func$;
