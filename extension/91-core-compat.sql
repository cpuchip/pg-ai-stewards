-- =====================================================================
-- 91-core-compat.sql — the compatibility guard for downstream overlays
-- =====================================================================
-- From the audit (.spec/proposals/audit-synthesis-2026-07.md §IV, "the one
-- real correctness landmine"): overlay apply-order was enforced by no runtime
-- tool, so a stale overlay could silently revert a core final (the r6/pe5/
-- cut3 saga). Fixing the apply-order (Track 2's first step) closes HALF the
-- landmine — the other half is that native `requires` on a Postgres extension
-- carries no VERSION RANGE, so nothing stops an overlay authored against core
-- 0.3.x from applying cleanly (no SQL error) against a 0.5 core whose function
-- signature or behavior it assumed has since moved. This is the guard: a
-- downstream overlay states the core range it was written for in a header
-- comment (`-- requires-core: >=X.Y[.Z] <A.B[.C]`), and the runner calls this
-- BEFORE applying that file.
--
-- Grammar: `>=X.Y[.Z] <A.B[.C]`, space-separated, EITHER bound optional (a
-- one-sided range is legal: `>=0.3` alone, or `<0.4` alone). Version segments
-- compare numerically (not lexically — "0.10" beats "0.9"); a version string
-- with fewer than 3 segments is right-padded with 0 ("0.3" == "0.3.0").
-- =====================================================================

-- ── _core_compat_ver — "0.3.0" -> ARRAY[0,3,0], missing segments = 0 ──────
-- Private helper (underscore prefix, per convention — see 15b's _context_*).
-- Postgres compares int[] of equal length element-by-element, so once every
-- version is normalized to 3 segments, plain <, >=, etc. on the arrays give
-- correct numeric (not lexical) ordering.
CREATE OR REPLACE FUNCTION stewards._core_compat_ver(p_version text)
RETURNS int[] LANGUAGE sql IMMUTABLE AS $fn$
    SELECT ARRAY[
        coalesce((string_to_array(btrim(p_version), '.'))[1]::int, 0),
        coalesce((string_to_array(btrim(p_version), '.'))[2]::int, 0),
        coalesce((string_to_array(btrim(p_version), '.'))[3]::int, 0)
    ];
$fn$;
COMMENT ON FUNCTION stewards._core_compat_ver(text) IS
'91: normalize a dotted version string to a 3-element int[] (missing segments = 0)
so range comparisons are numeric, not lexical. Private helper for assert_core_compat.';

-- ── assert_core_compat — the guard itself ─────────────────────────────────
-- p_range: the overlay's `-- requires-core: <range>` header value, VERBATIM
-- (including the >=/< tokens). Reads the installed core version straight from
-- pg_catalog (SELECT extversion FROM pg_extension WHERE extname=
-- 'pg_ai_stewards') — the one place a running database cannot be lied to
-- about which core it has. RAISEs on any out-of-range or unparseable range
-- (the runner is expected to run this under ON_ERROR_STOP=1 so the raise
-- aborts the file, and the run); returns true when the installed core
-- satisfies the range.
CREATE OR REPLACE FUNCTION stewards.assert_core_compat(p_range text)
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
    v_installed   text;
    v_installed_v int[];
    v_min_tok     text;
    v_max_tok     text;
    v_range       text := btrim(coalesce(p_range, ''));
BEGIN
    SELECT extversion INTO v_installed
      FROM pg_extension WHERE extname = 'pg_ai_stewards';
    IF v_installed IS NULL THEN
        RAISE EXCEPTION 'assert_core_compat: pg_ai_stewards is not an installed extension (nothing to check against)';
    END IF;
    v_installed_v := stewards._core_compat_ver(v_installed);

    IF v_range = '' THEN
        RETURN true;  -- no constraint stated = unconstrained (headerless files never call this)
    END IF;

    v_min_tok := (regexp_match(v_range, '>=\s*([0-9]+(?:\.[0-9]+){0,2})'))[1];
    v_max_tok := (regexp_match(v_range, '<\s*([0-9]+(?:\.[0-9]+){0,2})'))[1];

    IF v_min_tok IS NULL AND v_max_tok IS NULL THEN
        RAISE EXCEPTION 'assert_core_compat: unparseable requires-core range % (expected ">=X.Y[.Z] <A.B[.C]", either bound optional)',
            quote_literal(p_range);
    END IF;

    IF v_min_tok IS NOT NULL AND v_installed_v < stewards._core_compat_ver(v_min_tok) THEN
        RAISE EXCEPTION 'assert_core_compat: installed core % is below the required minimum % (requires-core: %)',
            v_installed, v_min_tok, p_range;
    END IF;

    IF v_max_tok IS NOT NULL AND v_installed_v >= stewards._core_compat_ver(v_max_tok) THEN
        RAISE EXCEPTION 'assert_core_compat: installed core % is at/above the required ceiling % (requires-core: %)',
            v_installed, v_max_tok, p_range;
    END IF;

    RETURN true;
END;
$fn$;
COMMENT ON FUNCTION stewards.assert_core_compat(text) IS
'91: raise if the INSTALLED core version (pg_extension.extversion) falls outside
p_range (">=X.Y[.Z] <A.B[.C]", either bound optional); else return true. The
runtime half of the compat contract — a downstream overlay states its
"-- requires-core: <range>" header, and the migration runner calls this before
applying that file so a core bump that breaks an old overlay is a loud abort,
not a silent clobber.';
