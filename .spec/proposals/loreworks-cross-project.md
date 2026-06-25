# Loreworks — cross-project worlds (a world built over a SET of buckets)

**Status:** ratified design (Michael, 2026-06-25), building. Council via AskUserQuestion.
**Why:** a world should be able to reference other projects/buckets — to ground a new project in
existing knowledge and to surface cross-bucket connections. Examples Michael gave:
- Import D&D 5e rules; build a My Little Pony world that **references** the 5e rules bucket.
- Work: a new `yard-sensor` world that references the company's `market` + `cke` buckets to ground it.
- A Star Trek world built over `star-trek` + `tng` + `ds9` + `picard` buckets — separate buckets,
  one graph showing where they connect.

## The model
A **project** is a bucket of source (docs, `project_association`). A **world** is a graph built over
a **SET** of projects: a **primary** (`worlds.project`, where new uploads land + the world's home)
plus zero or more **referenced** projects (`worlds.metadata.reference_projects` — a jsonb array, no
migration). The build reads/extracts across all of them; the entity **dedup** (same world+kind+name →
one node, aliases + source_refs unioned) is what makes a shared entity bridge the buckets.

## Ratified choices
- **Both — merge now, cross-world links later.** ① MERGE (this arc): one graph over the project set;
  shared entities merge so cross-bucket links appear automatically. ② REFERENCE (follow-on): keep
  buckets as separate worlds and add typed edges *between* worlds. Build ① first.
- **Full referenced graphs** (not bridges-only): a referenced bucket is graphed in full…
- **…with a per-world settings toggle** to show/hide each referenced project's nodes (for performance
  / visual ease). "Turn the external graphs on/off."

## Build plan
- **X1 — engine (merge):** `worlds.metadata.reference_projects`; `POST /api/world/build` accepts
  `reference_projects`; the world-build agent is told the canon spans the project SET — doc_search each,
  build ONE graph, dedup shared entities, and ADD the cross-project edges (the point). Each entity's
  source_refs carry the doc → so its project(s) are derivable.
- **X2 — provenance + toggle (UI):** `/api/world/graph` enriches each node with its `projects` (distinct
  project_association of its source-ref docs). WorldGraphPanel badges nodes by project + a settings
  dialog lists the world's projects (primary + refs) with show/hide toggles that filter the view.
- **Follow-ons:** ② cross-world reference edges (link to another world's nodes without re-extract);
  reuse an existing built world instead of re-extracting a big referenced bucket (perf for e.g. a
  600MB CKE); cross-project link colour in the graph.

## Boundary / privacy
A world spanning `cke`/`market` (or purchased TTRPG buckets) stays `file_private`/local — referencing
does not change a bucket's privacy. Generic OSS: the mechanism (project-set worlds) is core; the
content stays local.
