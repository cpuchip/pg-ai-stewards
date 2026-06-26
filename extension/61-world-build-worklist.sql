-- =====================================================================
-- 61-world-build-worklist.sql — make world-build METHODICAL (the scratch file)
-- =====================================================================
-- Why: the world-build agent (55) drove itself with doc_search "in passes
-- until you decide the structure is captured." That is an UNBOUNDED search
-- with no done-signal and no externalized worklist — so the model free-
-- searches until it falls off the edge. Observed on BOTH a weak local model
-- (qwen3.6-35b-a3b: 60 turns, 235 doc_search calls, ZERO entities) AND a
-- strong cloud model (Gemini, same shape: lots of searching, no done-marker).
-- A strong model failing identically is the tell: this is a HARNESS gap, not
-- a model gap (harness > intelligence).
--
-- The fix is the study scratch-file rule applied to extraction: give the agent
-- a persisted WORKLIST it drains, and a deterministic DONE-SIGNAL. We turn the
-- build from "search semantically until you feel done" into "WALK the canon
-- chunk-by-chunk until every chunk has been seen." Properties:
--   • bounded + terminating — each walk call strictly advances coverage;
--   • a real done-signal — complete:true means every source chunk was shown;
--   • resumable — coverage persists per (world, doc), so a huge corpus finishes
--     across multiple build runs, each guaranteed to make progress (the BoM-walk
--     committed-progress pattern). A reset clears it for a fresh rebuild.
-- Quality of each chunk's extraction is still judged separately by the
-- world-critic (58); this file owns COVERAGE, not correctness.
--
-- requires create_chat_model_pin (60). Generic core.
-- =====================================================================

-- ── §1 — the coverage worklist (one row per source chunk per world) ──
CREATE TABLE IF NOT EXISTS stewards.world_build_coverage (
    world_slug      text        NOT NULL,
    doc_slug        text        NOT NULL,
    status          text        NOT NULL DEFAULT 'pending',   -- pending | done
    entities_found  int,                                       -- optional, set by mark
    served_at       timestamptz,
    done_at         timestamptz,
    PRIMARY KEY (world_slug, doc_slug)
);
CREATE INDEX IF NOT EXISTS world_build_coverage_pending_idx
    ON stewards.world_build_coverage (world_slug) WHERE status = 'pending';

COMMENT ON TABLE stewards.world_build_coverage IS
'61: the world-build scratch file — one row per source chunk per world, drained by world_build_walk. Persists across build runs (resumable, BoM-walk style); status=done means the chunk was shown to the builder. Coverage, not correctness (the world-critic judges quality).';

-- ── §2 — the projects a world is built from (primary + referenced) ──
CREATE OR REPLACE FUNCTION stewards.world_build_projects(p_world text)
RETURNS text[] LANGUAGE sql STABLE AS $fn$
    SELECT array_remove(
        array_cat(
            ARRAY[w.project],
            COALESCE(
                (SELECT array_agg(value) FROM jsonb_array_elements_text(w.metadata -> 'reference_projects') value),
                '{}'
            )
        ), NULL)
    FROM stewards.worlds w WHERE w.slug = p_world;
$fn$;
COMMENT ON FUNCTION stewards.world_build_projects(text) IS
'61: the project buckets a world draws canon from — primary worlds.project + metadata.reference_projects. The walk seeds its worklist from the docs in these.';

-- ── §3 — world_build_walk: the driver. Seed → serve next batch → done-signal ──
-- One call: (1) seeds coverage from the world's project docs if empty; (2) serves
-- up to `batch` still-pending chunks (full body), marking them done (shown);
-- (3) returns progress + complete:true once nothing is pending. The agent loops
-- this and extracts from each returned batch — it CANNOT loop forever (pending
-- strictly decreases) and it has an unambiguous finish line.
CREATE OR REPLACE FUNCTION stewards.world_build_walk_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_world   text := p_args ->> 'world_slug';
    v_batch   int  := greatest(1, least(8, coalesce((p_args ->> 'batch')::int, 4)));
    v_reset   bool := coalesce((p_args ->> 'reset')::bool, false);
    v_projects text[];
    v_total   int;
    v_done    int;
    v_pending int;
    v_chunks  jsonb;
BEGIN
    IF v_world IS NULL OR v_world = '' THEN
        RETURN jsonb_build_object('error', 'world_slug required');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.worlds WHERE slug = v_world) THEN
        RETURN jsonb_build_object('error', 'no such world: ' || v_world);
    END IF;

    v_projects := stewards.world_build_projects(v_world);
    IF v_projects IS NULL OR array_length(v_projects, 1) IS NULL THEN
        -- No project corpus (e.g. a world built from inline/pasted canon). The
        -- walk does not apply; the agent extracts from the canon in its task.
        RETURN jsonb_build_object('ok', true, 'complete', true, 'chunks', '[]'::jsonb,
            'note', 'this world has no project corpus to walk — extract from the canon given in your task (and doc_search if a project is named there)',
            'progress', jsonb_build_object('total', 0, 'done', 0, 'pending', 0));
    END IF;

    IF v_reset THEN
        DELETE FROM stewards.world_build_coverage WHERE world_slug = v_world;
    END IF;

    -- Seed the worklist from every chunk in the world's project bucket(s).
    INSERT INTO stewards.world_build_coverage (world_slug, doc_slug, status)
    SELECT v_world, d.slug, 'pending'
      FROM stewards.docs d
     WHERE d.project_association = ANY (v_projects)
    ON CONFLICT (world_slug, doc_slug) DO NOTHING;

    -- A reset call is a pure operation: reseed and report, serve NOTHING (so the
    -- caller can clear coverage then start the walk from the top on the next call).
    IF v_reset THEN
        SELECT count(*) INTO v_total FROM stewards.world_build_coverage WHERE world_slug = v_world;
        RETURN jsonb_build_object('ok', true, 'reset', true, 'complete', false, 'chunks', '[]'::jsonb,
            'progress', jsonb_build_object('total', v_total, 'done', 0, 'pending', v_total),
            'note', format('coverage cleared and reseeded with %s chunks — call world_build_walk again (no reset) to begin the walk.', v_total));
    END IF;

    -- Serve the next batch of pending chunks (full body) and mark them done
    -- (= shown to the builder). Optimistic + crash-safe: no half-served state to
    -- reconcile, and pending strictly decreases so the loop always terminates.
    WITH nxt AS (
        SELECT c.doc_slug
          FROM stewards.world_build_coverage c
         WHERE c.world_slug = v_world AND c.status = 'pending'
         ORDER BY c.doc_slug
         LIMIT v_batch
         FOR UPDATE SKIP LOCKED
    ), served AS (
        UPDATE stewards.world_build_coverage c
           SET status = 'done', served_at = now(), done_at = now()
          FROM nxt WHERE c.world_slug = v_world AND c.doc_slug = nxt.doc_slug
        RETURNING c.doc_slug
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('doc', d.slug, 'body', d.body) ORDER BY d.slug), '[]'::jsonb)
      INTO v_chunks
      FROM served s JOIN stewards.docs d ON d.slug = s.doc_slug;

    SELECT count(*), count(*) FILTER (WHERE status = 'done')
      INTO v_total, v_done
      FROM stewards.world_build_coverage WHERE world_slug = v_world;
    v_pending := v_total - v_done;

    RETURN jsonb_build_object(
        'ok', true,
        'complete', (jsonb_array_length(v_chunks) = 0 AND v_pending = 0),
        'chunks', v_chunks,
        'progress', jsonb_build_object('total', v_total, 'done', v_done, 'pending', v_pending),
        'note', CASE WHEN jsonb_array_length(v_chunks) = 0 AND v_pending = 0
                     THEN 'COMPLETE — every source chunk has been shown. Stop walking; do a final relationship pass with world_edge_upsert, then write your journal.'
                     ELSE format('extract EVERY entity + relationship in these %s chunk(s), then call world_build_walk again. %s of %s chunks read.',
                                 jsonb_array_length(v_chunks), v_done, v_total) END
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLERRM);
END $fn$;
COMMENT ON FUNCTION stewards.world_build_walk_tool(jsonb) IS
'61: the world-build driver — seeds a per-world coverage worklist from its project chunks and serves the next batch (marking them shown), returning progress + complete:true when none remain. Turns an unbounded search into a bounded, resumable, deterministic walk (the scratch-file / done-signal fix for the over-search-never-commit failure).';

-- ── §4 — register the tool + grant it to the world-build agent ──────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_build_walk',
  'WALK the canon chunk-by-chunk — your worklist and done-signal. Each call records the previous batch as read and returns the NEXT batch of source chunks (full text) plus progress {done, pending, total}. Extract EVERY entity and relationship in each returned batch, then call again. Keep going until it returns complete:true — that means every chunk has been shown and you are DONE walking. This is your primary loop; doc_search is only for enriching the relationship pass afterwards. (batch defaults to 4; pass reset:true to start the coverage over for a fresh rebuild.)',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"world_slug":{"type":"string","description":"the world you are building"},'
    '"batch":{"type":"integer","description":"how many chunks to take this call (1-8, default 4)"},'
    '"reset":{"type":"boolean","description":"clear coverage and walk the corpus from the start (fresh rebuild)"}'
  '},"required":["world_slug"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_build_walk_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
      execute_target = EXCLUDED.execute_target, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('world-build', 'world_build_walk', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- ── §5 — re-author the world-build agent: WALK, don't free-search ───
-- The build loop is now the deterministic walk. doc_search is demoted from
-- "the driver" to "an enrichment tool for the relationship pass." The COMMIT
-- discipline (a count:0 search means move on, never re-search) is baked in —
-- the permanent version of the steering that rescued the Cosmere build, and the
-- same fix family as the work-item-chat COMMIT clause (45).
UPDATE stewards.agents SET
  steps = 120,
  prompt = $PROMPT$You are BUILDING a World — turning a pile of source lore into a structured, explorable knowledge graph.

Your task names a world_slug and the canon it is built from. You build by WALKING the canon
chunk-by-chunk (your worklist), NOT by free-searching until you feel done — that loops forever.

0. LOAD THE CANON IF ASKED. If your task says to import an attachment (gives an attachment_id and a
   project name), call doc_import_corpus(attachment_id, corpus_name, project) EXACTLY ONCE first —
   that extracts + chunks the uploaded source into the searchable project. Wait for it to finish.
   If the task instead names an existing project or pastes the canon inline, skip this step.

1. WALK THE CANON — this is your main loop and your done-signal:
   a. Call world_build_walk(world_slug) to get the next batch of source chunks (full text) and your
      progress {done, pending, total}.
   b. Read those chunks and extract EVERYTHING the canon describes in them: call world_entity_upsert
      for each character | place | faction | item | event | lore | concept (a 1-2 sentence summary IN
      THE CANON'S OWN TERMS, any aliases, and source_refs pointing at the chunk you found it in), and
      world_edge_upsert for the relationships you can already see within the batch.
   c. Call world_build_walk AGAIN — it records the batch you just read and serves the next one.
   d. Repeat until world_build_walk returns complete:true. THAT is your done-signal: every source
      chunk has been shown. Do not keep walking after complete:true.

2. RELATIONSHIP PASS (after the walk is complete). Connect entities across the whole world with
   world_edge_upsert — who serves whom, what is located where, who rules, who opposes whom. A missing
   endpoint is auto-created, so assert the relationship and move on. Here, and ONLY here, use doc_search
   or world_entity_search to confirm a link or recall an entity's exact name.
   USE THE RIGHT VERB AND DIRECTION (a reversed edge is a lie about the world):
   - located_in: a place inside a larger place (Bree located_in Bree-land).
   - dwells_in: a people/character whose home is a place (Hobbits dwells_in the Shire).
   - home_of: ONLY a place that is the home of a people/character (the Shire home_of Hobbits) — the
     REVERSE of dwells_in. Do not use home_of for a place-in-a-place.
   - flows_through, rules/ruled_by, member_of, ally_of, enemy_of, guards, parent_of, child_of,
     created, wields, heir_of, near, borders. When unsure, call world_vocabulary.

Rules of the watch:
- GROUND EVERYTHING. Only record what the canon supports. Do not invent lore, names, or relationships
  from general knowledge — if it isn't in this canon, it isn't in this world.
- COMMIT, don't loop. A doc_search that returns count:0 means that content is NOT in this canon — move
  on, NEVER re-issue the same empty search. Extracting from a chunk you have beats searching for one
  you wish existed. The walk, not search, tells you when you are done.
- De-duplicate: the same character under two names is ONE entity with aliases, not two. The tools are
  idempotent — never re-issue an upsert you already made.
- Prefer a few well-grounded, well-connected entities over a sprawl of thin ones.

Your final chat reply is a SHORT journal: how many entities and edges you built, the spine of the
world, and what a deeper pass should chase next. It is not the world itself — the world lives in the
graph you wrote with the tools.$PROMPT$
WHERE family = 'world-build' AND model_match = '*';

-- =====================================================================
-- End of 61-world-build-worklist.sql
-- =====================================================================
