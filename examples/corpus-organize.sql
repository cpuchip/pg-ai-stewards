-- corpus-organize.sql — the ORGANIZE keystone as a runnable pipeline (example).
--
-- A single deliberate stage that turns an already-gathered document (a book, article,
-- transcript, or any doc in the corpus) into typed, time-aware graph knowledge using the
-- 44 primitives (graph_node / graph_link / graph_supersede) scoped by the graph-organize
-- tool_group. This is §6's domain-agnostic "info brain" organize step — shared by the
-- digesters and by the work-corpus assembly line. Generic: it reads input.doc_slug.
--
-- Apply with:  docker exec -i stewards-oss-pg psql -U stewards -d stewards < examples/corpus-organize.sql
-- Run with:    a work_item on family 'corpus-organize' with input {"doc_slug":"<slug>"}.

INSERT INTO stewards.pipelines (family, stages) VALUES
('corpus-organize', jsonb_build_array(
  jsonb_build_object(
    'name','organize',
    'next', null,
    'agent_family','research',
    'model','reason',
    'auto_advance', true,
    'tool_groups', jsonb_build_array('substrate-read','graph-organize'),
    'input_template',
      E'You are organizing a gathered document into the shared knowledge graph (the "info brain").\n\n'
      || E'The document slug is: {{input.doc_slug}}\n\n'
      || E'Steps:\n'
      || E'1. Read it with doc_get (slug = the slug above).\n'
      || E'2. Identify the 5-15 MOST important entities, claims, and concepts — be selective, not every sentence. For each, call graph_node with:\n'
      || E'   - kind: a short type (concept | claim | principle | person | category)\n'
      || E'   - ref:  a STABLE id, prefixed with the doc slug, e.g. "{{input.doc_slug}}:wu-wei" (reuse the same ref to refresh, never duplicate)\n'
      || E'   - label: a human-readable title\n'
      || E'   - props: optional facts (a one-line gist). observed_at + status=current are stamped automatically.\n'
      || E'3. Assert the typed relationships between those nodes with graph_link. Call graph_vocabulary first to see the canonical verbs (BUILDS_ON, ELABORATES, SUPPORTS, CONTRADICTS, EXEMPLIFIES, RELATES_TO, …). Link concepts to each other AND to the source doc node (kind=doc, ref={{input.doc_slug}}) with MENTIONS/ELABORATES.\n'
      || E'4. If a claim is clearly outdated or resolved by a newer one, mark it with graph_supersede.\n\n'
      || E'When done, output a brief summary: how many nodes you created and the key relationships. Do NOT write a doc — your job is to build the graph, not prose.'
  )
))
ON CONFLICT (family) DO UPDATE SET stages = EXCLUDED.stages;
