-- =====================================================================
-- v44-fact-edges-dedup-hash.sql — the P0 dedup index could not hold real data.
--
-- FOUND BY P1, ON THE FIRST REAL CORPUS (2026-08-01, hours after v43 shipped):
--
--   ERROR: index row size 3216 exceeds btree version 4 maximum 2704
--          for index "fact_edges_live_uq"
--
-- v43 indexed the raw `fact_norm` text:
--     UNIQUE (src, dst, fact_norm) WHERE expired_at IS NULL
-- which is correct in meaning and impossible in practice — btree caps an index
-- row near 2704 bytes, and a real `fact` is a whole line of prose. The memory
-- corpus has lines well past that. Nothing was lost (the import transaction
-- aborted; fact_edges was empty), but every future importer would have hit it.
--
-- WHY THIS WASN'T CAUGHT IN P0: verify-43's dedup fixture used a short toy
-- string ('  The   Fact   With  Messy Spacing '). The check was semantically
-- right and dimensionally unreal. Fixtures must span the shape of the real
-- data — its SIZE as well as its meaning — or they bless a design the data
-- refuses. verify-44 below pins the size case permanently.
--
-- THE FIX: index a hash of the normalized fact instead of the fact itself.
-- Dedup semantics are unchanged (exact match on the normalized text); only the
-- index payload shrinks to 32 bytes. md5() is used because it is IMMUTABLE and
-- takes text directly; sha256() is IMMUTABLE but takes bytea, and the only way
-- there is convert_to(), which is merely STABLE and therefore not indexable.
-- A hash collision here would cause one spurious dedup, never corruption, and
-- at corpus scale that probability is not worth an extension dependency the
-- substrate has twice refused.
--
-- ⚠ CALLER CHANGE: ON CONFLICT must now name the SAME expression as the index.
--     ON CONFLICT (src, dst, md5(fact_norm)) WHERE expired_at IS NULL
-- The old (src, dst, fact_norm) form no longer infers an index and fails.
--
-- Idempotent. No data change: the table is empty at time of writing and the
-- index is rebuilt either way.
-- requires = create_v43_fact_edges.
-- =====================================================================

DROP INDEX IF EXISTS stewards.fact_edges_live_uq;

CREATE UNIQUE INDEX IF NOT EXISTS fact_edges_live_uq
    ON stewards.fact_edges (src, dst, md5(fact_norm))
    WHERE expired_at IS NULL;

COMMENT ON INDEX stewards.fact_edges_live_uq IS
    'Live exact-dedup key: (src, dst, hash of normalized fact). Hashed because a real fact is a line of prose and btree caps index rows near 2704 bytes (found by the P1 memory import, 2026-08-01). Dedup semantics are unchanged; ON CONFLICT must name md5(fact_norm).';
