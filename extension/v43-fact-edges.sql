-- =====================================================================
-- v43-fact-edges.sql — brain v5 P0: the schema.
--
-- THE RULING (brain-v5 map, 12/12 tickets, SPEC.md compiled 2026-07-31;
-- Michael's go 2026-08-01): brain v5 = pg-ai-stewards EVOLVED — substrate is
-- the system of record, files are the projected read surface, no resident
-- process. This migration is P0, the one genuinely new store plus the two
-- companion fixes ticket 003 ruled. It adds tables and columns ONLY; nothing
-- reads from fact_edges until P1 ships the importer.
--
-- WHY A NEW TABLE (tickets 003 + 004). stewards.edges carries
-- UNIQUE (src, dst, kind) (v00-foundations.sql:160) and graph_edge_upsert
-- resolves conflicts with DO UPDATE — an edge is a CURRENT-STATE SLOT that
-- gets overwritten. It therefore cannot express "X was true, then stopped
-- being true": the second assertion silently destroys the first and no row
-- survives to say the first was ever believed. fact_edges is an ASSERTION
-- WITH ITS OWN IDENTITY — many rows may stand between the same two nodes,
-- separated by their fact text and their validity window, and a contradiction
-- STAMPS the loser (invalid_at / expired_at) instead of replacing it.
-- stewards.edges is NOT changed, NOT migrated, and NOT deprecated: it keeps
-- being the current-state adjacency every existing caller expects.
--
-- BI-TEMPORAL, precisely (graphiti's model, ported):
--   created_at / expired_at  = INGEST time  — when WE learned it / stopped believing it
--   valid_at   / invalid_at  = EVENT time   — when the fact became / stopped being true
-- validity is a GENERATED tstzrange over event time with a GiST index, so
-- as-of queries are range containment; the partial index WHERE expired_at IS
-- NULL makes "the live graph" the cheap default. Postgres does this better
-- than the Cypher original, where the same filters are caller-supplied and an
-- unfiltered search silently returns expired edges.
--
-- WHAT WE ADD THAT GRAPHITI LACKS: invalidated_by (which episode refuted this
-- — graphiti has no such link at all, only an ambiguous reconstruction), the
-- junction role discriminator supports/invalidates (graphiti conflates both
-- into one array), and fidelity verbatim/paraphrase/inferred (lifted from
-- stewards.observations, v26-knowledge.sql:56-58, which keeps fidelity
-- deliberately orthogonal to confidence).
--
-- NODES GET NO VALIDITY. Graphiti nodes are not bi-temporal (only edges are);
-- building node-level validity would mean maintaining what nothing reads.
-- Nodes get identity/dedup columns only.
--
-- group_id -> project_association (SPEC recommendation, taken): the substrate
-- already partitions by project_association and world_id; a third key drifts.
--
-- DELIBERATELY NOT IN P0, so the boundary is legible:
--   * stewards.node_mentions (episode->entity MENTIONS junction) — designed in
--     research/004, but its only consumer is a count(*) for a deletion rule
--     that lands with the gardener. Not built until something reads it.
--   * Fuzzy dedup (MinHash/LSH or pg_trgm) — the substrate has refused a
--     trigram extension dependency twice on purpose (v02:4977, v22:79). Exact
--     dedup ships here via fact_norm; fuzzy is a live decision, not a free swap.
--   * Any backfill. fact_edges is born empty by design.
--
-- COMPANION FIXES (ticket 003 ruled both):
--   1. graph_recall gets a path guard — it was the only walk without one, so a
--      revisit could re-expand the same node every hop (multiplicative at an
--      inbound hub). Signature UNCHANGED and no new parameter: an extension
--      function can neither be dropped nor grown parameters, so the guard is
--      structural (a visited-path array), not configurable.
--   2. import_doc stops DELETEing CITES history — see its own note below.
--
-- Idempotent throughout (IF NOT EXISTS / CREATE OR REPLACE). Additive only:
-- no DROP, no data rewrite, no change to any existing row.
-- requires = create_v42_unmined_sources.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Entity-node columns (graphiti EntityNode -> existing stewards.nodes)
--    labels[] is not decoration: dedup promotes a generic canonical node when
--    a duplicate carries a more specific type, which a single-valued `kind`
--    cannot represent.
-- ---------------------------------------------------------------------
ALTER TABLE stewards.nodes
    ADD COLUMN IF NOT EXISTS labels          text[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS summary         text   NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS embedding       vector(768),
    ADD COLUMN IF NOT EXISTS embedded_at     timestamptz,
    ADD COLUMN IF NOT EXISTS embedded_model  text,
    ADD COLUMN IF NOT EXISTS embedding_error text;

-- Exact-dedup key: lowercase + whitespace-collapse, the same normalization the
-- upstream non-LLM dedup path uses. STORED so a btree index does the whole
-- exact path in-engine.
ALTER TABLE stewards.nodes
    ADD COLUMN IF NOT EXISTS name_norm text
    GENERATED ALWAYS AS (regexp_replace(lower(coalesce(label, '')), '\s+', ' ', 'g')) STORED;

CREATE INDEX IF NOT EXISTS nodes_kind_name_norm ON stewards.nodes (kind, name_norm);

-- ---------------------------------------------------------------------
-- 2. messages.source_valid_at — EVENT time of the episode.
--    messages.created_at is INGEST time; a document written last year and
--    imported today needs both, and only one exists.
-- ---------------------------------------------------------------------
ALTER TABLE stewards.messages
    ADD COLUMN IF NOT EXISTS source_valid_at timestamptz;

-- ---------------------------------------------------------------------
-- 3. fact_edges — the assertion store
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.fact_edges (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    src             uuid NOT NULL REFERENCES stewards.nodes(id) ON DELETE CASCADE,
    dst             uuid NOT NULL REFERENCES stewards.nodes(id) ON DELETE CASCADE,
    kind            text NOT NULL,            -- relation type
    fact            text NOT NULL,            -- the sentence asserted
    fact_norm       text GENERATED ALWAYS AS
                    (regexp_replace(lower(fact), '\s+', ' ', 'g')) STORED,
    fact_embedding  vector(768),
    embedded_at     timestamptz,
    embedded_model  text,
    embedding_error text,

    created_at      timestamptz NOT NULL DEFAULT now(),  -- ingest time, start
    expired_at      timestamptz,                         -- ingest time of invalidation
    valid_at        timestamptz,                         -- event time, became true
    invalid_at      timestamptz,                         -- event time, stopped being true
    reference_time  timestamptz,                         -- producing episode's event time
    validity        tstzrange GENERATED ALWAYS AS (tstzrange(valid_at, invalid_at)) STORED,

    invalidated_by  bigint REFERENCES stewards.messages(id) ON DELETE SET NULL,
    fidelity        text NOT NULL DEFAULT 'inferred'
                    CHECK (fidelity IN ('verbatim', 'paraphrase', 'inferred')),
    props           jsonb NOT NULL DEFAULT '{}'::jsonb,
    project_association text,

    -- Event time cannot run backwards. NOTE, measured not assumed: the
    -- GENERATED validity column already refuses this first — constructing
    -- tstzrange(later, earlier) raises data_exception before any CHECK is
    -- evaluated, so in practice this constraint never fires today. It is kept
    -- deliberately as the DECLARED invariant: it survives if validity is ever
    -- reshaped or dropped, and it states the rule where a reader looks for it
    -- rather than leaving it as a side effect of a range type.
    CONSTRAINT fact_edges_event_order CHECK (
        valid_at IS NULL OR invalid_at IS NULL OR invalid_at >= valid_at)
);

-- DELIBERATELY no unique on (src, dst, kind) — that constraint is the thing
-- being refuted. The live-dedup key omits kind, matching the upstream dedup
-- key (source, target, normalized fact).
CREATE UNIQUE INDEX IF NOT EXISTS fact_edges_live_uq
    ON stewards.fact_edges (src, dst, fact_norm) WHERE expired_at IS NULL;

CREATE INDEX IF NOT EXISTS fact_edges_live
    ON stewards.fact_edges (src, kind) WHERE expired_at IS NULL;
CREATE INDEX IF NOT EXISTS fact_edges_dst_live
    ON stewards.fact_edges (dst, kind) WHERE expired_at IS NULL;
CREATE INDEX IF NOT EXISTS fact_edges_validity
    ON stewards.fact_edges USING gist (validity);
CREATE INDEX IF NOT EXISTS fact_edges_project
    ON stewards.fact_edges (project_association) WHERE expired_at IS NULL;
CREATE INDEX IF NOT EXISTS fact_edges_invalidated_by
    ON stewards.fact_edges (invalidated_by) WHERE invalidated_by IS NOT NULL;

-- hnsw mirrors every other embedding column in the substrate (vector(768),
-- cosine). Built empty; it costs nothing until P1 embeds anything.
CREATE INDEX IF NOT EXISTS fact_edges_embedding
    ON stewards.fact_edges USING hnsw (fact_embedding vector_cosine_ops);

COMMENT ON TABLE stewards.fact_edges IS
    'Bi-temporal assertion store (brain v5 P0). Each row is a fact with its own identity, not a current-state slot: created_at/expired_at are ingest time, valid_at/invalid_at are event time, and a contradiction stamps the loser rather than replacing it. stewards.edges remains the current-state adjacency.';

-- ---------------------------------------------------------------------
-- 4. fact_edge_episodes — which episodes support or refute each fact.
--    One indexed relation replacing the upstream pair of parallel arrays,
--    plus the role discriminator the arrays could not express.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.fact_edge_episodes (
    fact_edge_id uuid   NOT NULL REFERENCES stewards.fact_edges(id) ON DELETE CASCADE,
    message_id   bigint NOT NULL REFERENCES stewards.messages(id)   ON DELETE CASCADE,
    role         text   NOT NULL CHECK (role IN ('supports', 'invalidates')),
    ordinal      int    NOT NULL,   -- 0 = the CREATING episode (first-episode delete rule)
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (fact_edge_id, message_id, role)
);

CREATE INDEX IF NOT EXISTS fact_edge_episodes_msg
    ON stewards.fact_edge_episodes (message_id, role);

COMMENT ON TABLE stewards.fact_edge_episodes IS
    'Junction: episodes (messages) that support or invalidate a fact_edge. ordinal 0 marks the creating episode. role is the discriminator graphiti conflates.';

-- ---------------------------------------------------------------------
-- 5. COMPANION FIX 1 — graph_recall path guard (ticket 003).
--
-- The walk had no cycle guard: it re-expanded any node it reached again, so a
-- node reachable by k distinct paths was expanded k times, and at an inbound
-- hub that compounds every hop. The guard carries the visited path and refuses
-- to re-enter a node already on it.
--
-- SIGNATURE IS UNCHANGED ON PURPOSE. An extension-declared function can
-- neither be dropped nor grown a parameter (an all-DEFAULT overload makes
-- dispatch ambiguous), so the guard is structural rather than a new argument.
-- Behaviour is otherwise identical: same scoring, same decay, same exclusions.
-- ---------------------------------------------------------------------
-- The DEFAULTS are part of the locked signature: CREATE OR REPLACE cannot
-- remove parameter defaults from an existing function (Postgres refuses,
-- caught on the scratch chain), so they are restated verbatim from core.
CREATE OR REPLACE FUNCTION stewards.graph_recall(
    p_seeds    jsonb,
    p_max_hops integer DEFAULT 3,
    p_limit    integer DEFAULT 15,
    p_decay    real    DEFAULT 0.5
) RETURNS TABLE (kind text, ref text, label text, score real, hops integer)
LANGUAGE sql STABLE AS $func$
    WITH RECURSIVE seed AS (
        SELECT n.id, 1.0::real AS w, 0 AS hop, ARRAY[n.id] AS path
          FROM stewards.nodes n
          JOIN jsonb_array_elements(p_seeds) s
            ON n.kind = s->>'kind' AND n.ref = s->>'ref'
    ),
    walk AS (
        SELECT id, w, hop, path FROM seed
        UNION ALL
        SELECT step.next_id,
               (walk.w * p_decay * step.weight)::real,
               walk.hop + 1,
               walk.path || step.next_id
          FROM walk
          JOIN LATERAL (
                SELECT CASE WHEN e.src = walk.id THEN e.dst ELSE e.src END AS next_id,
                       e.weight
                  FROM stewards.edges e
                 WHERE e.src = walk.id OR e.dst = walk.id
               ) step ON true
         WHERE walk.hop < p_max_hops
           AND walk.w > 0.01
           AND NOT (step.next_id = ANY (walk.path))   -- the path guard
    )
    SELECT n.kind, n.ref, n.label, sum(walk.w)::real AS score, min(walk.hop) AS hops
      FROM walk JOIN stewards.nodes n ON n.id = walk.id
     WHERE walk.hop > 0
       AND walk.id NOT IN (SELECT id FROM seed)
     GROUP BY n.id, n.kind, n.ref, n.label
     ORDER BY score DESC
     LIMIT p_limit;
$func$;

-- ---------------------------------------------------------------------
-- 6. COMPANION FIX 2 — import_doc stops DELETEing CITES history (ticket 003).
--
-- It opened with a blanket DELETE of every CITES edge from the doc, then
-- re-upserted them all. So a re-import destroyed created_at and props for
-- EVERY citation, including the ones that had not changed — history erased as
-- a side effect of bookkeeping. Now it deletes only the edges whose target is
-- no longer cited in the body; the loop below already updates the survivors in
-- place, so re-imports stay in sync exactly as before.
--
-- CORE ONLY — READ THIS BEFORE TRUSTING IT IN PRODUCTION. On the live DB this
-- function is RE-AUTHORED BY THE WORKSPACE OVERLAY
-- (overlays/held-live-finals/gospel-core-reauthors.sql — an allowlisted
-- exception in scripts/parity-check.sh), so this core fix ALONE would be
-- silently clobbered there. The same surgical change is applied to that overlay
-- file in this change. Retraction HISTORY for a citation genuinely removed from
-- a body belongs in fact_edges and lands with the P1 importer; this fix stops
-- the destruction that had no reason to happen at all.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.import_doc(
    p_slug        text,
    p_file_path   text,
    p_title       text,
    p_body        text,
    p_frontmatter jsonb DEFAULT '{}'::jsonb,
    p_kind        text  DEFAULT 'doc'
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_id      text;
    v_node    uuid;
    v_link    record;
BEGIN
    INSERT INTO stewards.docs (slug, file_path, title, body, frontmatter, kind)
    VALUES (p_slug, p_file_path, p_title, p_body, p_frontmatter, p_kind)
    ON CONFLICT (slug) DO UPDATE
        SET title       = EXCLUDED.title,
            file_path   = EXCLUDED.file_path,
            body        = EXCLUDED.body,
            frontmatter = EXCLUDED.frontmatter,
            kind        = EXCLUDED.kind
    RETURNING id INTO v_id;

    v_node := stewards.graph_node_upsert(
        'doc', p_slug, p_title,
        jsonb_build_object('id', v_id,
                           'file_path', p_file_path,
                           'doc_kind',  p_kind));

    -- v43: delete ONLY the CITES edges whose target is no longer cited in
    -- the body. The old blanket DELETE destroyed created_at/props for EVERY
    -- citation on EVERY re-import, including the ones that never changed —
    -- the destructive re-import ticket 003 names. Still-cited edges now
    -- survive untouched and the loop below updates them in place.
    DELETE FROM stewards.edges e
     USING stewards.nodes n
     WHERE e.src = v_node
       AND e.kind = 'CITES'
       AND n.id = e.dst
       AND NOT EXISTS (
           SELECT 1 FROM stewards.parse_doc_links(p_body) l
            WHERE l.kind = n.kind AND l.uri = n.ref);

    -- For each unique cited URI, upsert the cited node + CITES edge.
    FOR v_link IN
        SELECT uri,
               max(anchor_text) AS anchor_text,
               max(kind)        AS kind,
               count(*)::int    AS citation_count
          FROM stewards.parse_doc_links(p_body)
         GROUP BY uri
    LOOP
        PERFORM stewards.graph_edge_upsert(
            'doc', p_slug,
            v_link.kind, v_link.uri,
            'CITES',
            v_link.citation_count::real,
            jsonb_build_object(
                'anchor_text',    v_link.anchor_text,
                'citation_count', v_link.citation_count,
                'provenance',     'parsed',
                'source',         'import_doc'));
    END LOOP;

    RETURN v_id;
END;
$func$;
