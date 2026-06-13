-- 00-extensions.sql
-- First-boot init: load pgvector + pg_ai_stewards so a fresh
-- `docker compose up` lands on a database where everything is
-- already wired and we can immediately call stewards.version().
--
-- (Apache AGE was dropped at the 2026-06-12 consolidation — the graph
-- is relational now: stewards.nodes + stewards.edges, installed by the
-- extension itself. See extension/01-graph.sql.)

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_ai_stewards;

-- Sanity prints — visible in `docker compose logs pg`.
SELECT 'pgvector ' || extversion AS ok FROM pg_extension WHERE extname = 'vector';
SELECT 'pg_ai_stewards ' || extversion AS ok FROM pg_extension WHERE extname = 'pg_ai_stewards';
SELECT 'stewards.version() = ' || stewards.version() AS ok;
SELECT 'providers loaded:' AS ok, count(*) FROM stewards.providers_loaded();

-- Smoke-test the bgworker round-trip. We enqueue here at init time,
-- but the worker won't actually run until the postmaster takes over
-- after init finishes. The next docker logs check should show the
-- row processed within ~1 second of the database accepting connections.
SELECT stewards.enqueue('echo', 'echo', '{"hello": "world"}'::jsonb) AS enqueued_id;

-- Brain smoke test: insert a brain entry, confirm the embed-enqueue
-- trigger fired (work_queue should have a kind='embed' row), and
-- confirm full-text search finds it.
SELECT stewards.brain_upsert(
    'study',
    'Charity is the pure love of Christ',
    'Moroni 7:47 — pure love of Christ. The fruit of the tree of life. Connected to the great commandment.',
    '{"references": "Moroni 7:47; 1 Ne 11:21-25; Matt 22:37-40", "insight": "Charity is fruit, not effort."}'::jsonb,
    ARRAY['charity', 'love', 'moroni']
) AS new_brain_entry_id;

SELECT 'embed work queued: ' || count(*)::text AS ok
    FROM stewards.work_queue WHERE kind = 'embed';

SELECT 'fts hits for charity: ' || count(*)::text AS ok
    FROM stewards.brain_search_text('charity');

-- Graph smoke test: the relational graph ships inside the extension.
SELECT 'graph ready: ' || count(*)::text || ' tables' AS ok
    FROM information_schema.tables
   WHERE table_schema = 'stewards' AND table_name IN ('nodes', 'edges');
