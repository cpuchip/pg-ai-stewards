-- =====================================================================
-- 98-crawler.sql — the LLM-driven, guardrailed purpose-crawler.
-- =====================================================================
-- Ratified spec: .spec/proposals/ingestion-crawler-and-raw-to-wiki.md
-- Part 1. Michael, verbatim: "guardrail it, or make it drivable by llm!
-- so the substrate model can direct it. like crawling for a purpose, we
-- wouldnt want to digest gigabytes."
--
-- The shape: a crawl is a work item carrying a PURPOSE (an intent
-- string) plus a guardrail config; the frontier is rows
-- (crawl_frontier), so a crawl is resumable by construction — kill it,
-- it resumes from the frontier. The 'crawl' pipeline is ONE stage
-- ('step') looping back on itself via route_on (42's mechanism). Each
-- step the agent: pops one URL (crawl_next), fetches it (fetch_url with
-- enforce_robots=true — the politeness floor lives in cmd/fetch-md-mcp,
-- robots.txt + per-domain rate limit), judges it against the purpose
-- (crawl_save: extract the relevant part, or skip-with-reason), scores
-- outbound links (crawl_enqueue), and may declare "sufficient" early.
--
-- ★ THE GUARDRAILS ARE A STRUCTURAL FLOOR THE MODEL CAN ONLY STAY
-- UNDER, NEVER RAISE. The division of labor, everywhere in this file:
-- the model PROPOSES (which link matters, what content is relevant,
-- when the purpose is satisfied); SQL DISPOSES (crawl_next refuses to
-- pop past the page/byte budget; crawl_enqueue re-validates domain
-- boundary + depth + dedup + frontier cap regardless of the model's
-- priority score; crawl_save refuses a write that would cross the byte
-- budget). A prompt cannot loosen any of it. Config itself is clamped
-- against operator-owned hard ceilings (crawl_hard_max_* below), so
-- even crawl_start's caller can only stay under the wall.
--
-- Runaway protection is inherited, not reimplemented: a crawl is a
-- work item, so the watchman/ES machinery (03) pauses it like any
-- other runaway, and route_on's global hop cap (42, route_on_max_hops
-- default 50) backstops the step loop itself. Crawls are ROOT work
-- items (no parent), so 16's delegation-tree caps are not in play.
--
-- Politeness (the other half, cmd/fetch-md-mcp/politeness.go): robots
-- honored per RFC 9309 (fail-closed on unreachable robots.txt),
-- per-domain rate floor 500ms (default 2s). crawl_next hands the model
-- fetch_args with enforce_robots=true + the config's rate_ms baked in,
-- so the polite call is a copy-paste, and the crawler agent's prompt
-- makes it non-negotiable.
--
-- requires create_wiki_assets (96) — the tail of the chain at
-- authoring time (a parallel builder owns 97; the integrator
-- re-stitches this file's requires when both land).
-- =====================================================================

-- ---------------------------------------------------------------------
-- SECTION 0 — config: the operator-owned hard ceilings per-crawl config
-- is clamped against. ON CONFLICT DO NOTHING (00's convention —
-- operators own these rows after install).
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('crawl_hard_max_pages', '200',
   '98-crawler: absolute per-crawl page ceiling. crawl_start clamps config.max_pages (default 25) to at most this — no caller, human or agent, can start a crawl past it.'),
  ('crawl_hard_max_depth', '6',
   '98-crawler: absolute per-crawl depth ceiling. Clamps config.max_depth (default 3).'),
  ('crawl_hard_max_bytes', '100000000',
   '98-crawler: absolute per-crawl saved-bytes ceiling (100MB). Clamps config.max_total_bytes (default 20MB).'),
  ('crawl_frontier_max', '500',
   '98-crawler: default per-crawl frontier row cap (config.frontier_max, hard ceiling 2000). Stops a link-happy model from ballooning the queue table.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- SECTION 1 — the frontier. The queue as rows: resumable, inspectable,
-- and the substrate's memory of where a crawl has been.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.crawl_frontier (
    id              bigserial PRIMARY KEY,
    work_item_id    uuid NOT NULL
                    REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    url             text NOT NULL,
    url_normalized  text NOT NULL,
    depth           int  NOT NULL DEFAULT 0 CHECK (depth >= 0),
    -- The model's relevance-to-purpose score, clamped [0,1] at enqueue.
    priority        real NOT NULL DEFAULT 0.5,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','fetched','skipped',
                                      'blocked','error')),
    discovered_from text,
    reason          text,
    fetched_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    -- Dedup floor: one row per normalized URL per crawl, enforced by
    -- the table itself — never refetch within a crawl.
    UNIQUE (work_item_id, url_normalized)
);

COMMENT ON TABLE stewards.crawl_frontier IS
'98-crawler: the crawl queue as rows. status lifecycle: pending -> (crawl_next pops, marks fetched + fetched_at) -> crawl_save settles it (fetched=saved-a-doc, skipped/blocked/error per the model''s disposition, reason says why). fetched_at IS NOT NULL is the authoritative "this URL consumed page budget" marker regardless of the final status. UNIQUE(work_item_id, url_normalized) is the dedup floor.';

CREATE INDEX IF NOT EXISTS crawl_frontier_pop_idx
    ON stewards.crawl_frontier (work_item_id, status, priority DESC, depth ASC, id ASC);

-- ---------------------------------------------------------------------
-- SECTION 2 — URL hygiene + the domain wall.
-- ---------------------------------------------------------------------

-- ── crawl_url_normalize — the dedup key. Lowercases scheme+host, drops
-- the fragment and default ports, collapses trailing slashes; keeps the
-- query (many sites are ?page= driven). NULL for anything non-http(s) —
-- the floor rejects those outright.
CREATE OR REPLACE FUNCTION stewards.crawl_url_normalize(p_url text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
    v          text := btrim(coalesce(p_url, ''));
    v_m        text[];
    v_scheme   text;
    v_hostport text;
    v_rest     text;
    v_path     text;
    v_query    text;
BEGIN
    IF v = '' THEN RETURN NULL; END IF;
    v := regexp_replace(v, '#.*$', '');            -- fragments never matter
    v_m := regexp_match(v, '^(https?)://([^/?#]+)(.*)$', 'i');
    IF v_m IS NULL THEN RETURN NULL; END IF;       -- not http(s)
    v_scheme   := lower(v_m[1]);
    v_hostport := lower(v_m[2]);
    v_rest     := coalesce(v_m[3], '');
    IF v_scheme = 'http'  THEN v_hostport := regexp_replace(v_hostport, ':80$',  ''); END IF;
    IF v_scheme = 'https' THEN v_hostport := regexp_replace(v_hostport, ':443$', ''); END IF;
    v_path  := split_part(v_rest, '?', 1);
    v_query := CASE WHEN position('?' in v_rest) > 0
                    THEN substr(v_rest, position('?' in v_rest))
                    ELSE '' END;
    IF v_path = '' THEN v_path := '/'; END IF;
    IF length(v_path) > 1 THEN
        v_path := regexp_replace(v_path, '/+$', '');
        IF v_path = '' THEN v_path := '/'; END IF;
    END IF;
    RETURN v_scheme || '://' || v_hostport || v_path || v_query;
END;
$fn$;

COMMENT ON FUNCTION stewards.crawl_url_normalize(text) IS
'98-crawler: normalize a URL to its frontier dedup key (lowercase scheme+host, no fragment, no default port, no trailing slash; query kept). NULL = not http(s), rejected by the floor.';

-- ── crawl_url_host — bare lowercased hostname (no port, no path).
CREATE OR REPLACE FUNCTION stewards.crawl_url_host(p_url text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT (regexp_match(lower(btrim(coalesce(p_url,''))), '^https?://([^/:?#]+)'))[1];
$fn$;

-- ── crawl_domain_allowed — THE DOMAIN WALL. A candidate URL passes iff
-- its host is the root URL's host (www. normalized both ways) or
-- matches an allow_domains entry (exact host, or a subdomain of it).
-- Deliberately fail-closed: an empty allowlist means root-host-only,
-- and there is NO wide-open mode — the "port to work, crawl the whole
-- intranet" case is a bigger allowlist + budget, never a wildcard.
CREATE OR REPLACE FUNCTION stewards.crawl_domain_allowed(
    p_root_url      text,
    p_allow_domains jsonb,
    p_candidate     text
) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
    v_root text := stewards.crawl_url_host(p_root_url);
    v_host text := stewards.crawl_url_host(p_candidate);
    v_d    text;
BEGIN
    IF v_root IS NULL OR v_host IS NULL THEN RETURN false; END IF;
    IF regexp_replace(v_host, '^www\.', '') = regexp_replace(v_root, '^www\.', '') THEN
        RETURN true;
    END IF;
    IF p_allow_domains IS NOT NULL AND jsonb_typeof(p_allow_domains) = 'array' THEN
        FOR v_d IN SELECT lower(btrim(x #>> '{}'))
                     FROM jsonb_array_elements(p_allow_domains) x LOOP
            CONTINUE WHEN v_d IS NULL OR v_d = '' OR v_d = '*';
            IF v_host = v_d OR v_host LIKE '%.' || v_d THEN
                RETURN true;
            END IF;
        END LOOP;
    END IF;
    RETURN false;
END;
$fn$;

COMMENT ON FUNCTION stewards.crawl_domain_allowed(text, jsonb, text) IS
'98-crawler: the domain wall. true iff candidate''s host = root''s host (www-normalized) or matches allow_domains (exact or subdomain). Fail-closed; a literal "*" entry is IGNORED — no wide-open mode exists.';

-- ---------------------------------------------------------------------
-- SECTION 3 — config merge + counters + status.
-- ---------------------------------------------------------------------

-- ── crawl_config — merge a work item's input.config with defaults and
-- clamp EVERYTHING against the operator-owned hard ceilings. Called at
-- crawl_start (so the stored config is already clamped) and again at
-- every runtime read (so a hand-edited row can't sneak past the wall).
CREATE OR REPLACE FUNCTION stewards.crawl_config(p_input jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    c               jsonb := coalesce(p_input->'config', '{}'::jsonb);
    v_hard_pages    int    := coalesce(stewards.config_get_text('crawl_hard_max_pages')::int, 200);
    v_hard_depth    int    := coalesce(stewards.config_get_text('crawl_hard_max_depth')::int, 6);
    v_hard_bytes    bigint := coalesce(stewards.config_get_text('crawl_hard_max_bytes')::bigint, 100000000);
    v_frontier_dflt int    := coalesce(stewards.config_get_text('crawl_frontier_max')::int, 500);
BEGIN
    RETURN jsonb_build_object(
        'max_pages',       LEAST(GREATEST(coalesce((c->>'max_pages')::int, 25), 1), v_hard_pages),
        'max_depth',       LEAST(GREATEST(coalesce((c->>'max_depth')::int, 3), 0), v_hard_depth),
        'max_total_bytes', LEAST(GREATEST(coalesce((c->>'max_total_bytes')::bigint, 20000000), 1), v_hard_bytes),
        'same_domain',     coalesce((c->>'same_domain')::boolean, true),
        'allow_domains',   CASE WHEN jsonb_typeof(c->'allow_domains') = 'array'
                                THEN c->'allow_domains' ELSE '[]'::jsonb END,
        'js',              coalesce(c->'js', 'false'::jsonb),   -- false | true | "auto"
        'rate_ms',         GREATEST(coalesce((c->>'rate_ms')::int, 2000), 500),
        'frontier_max',    LEAST(GREATEST(coalesce((c->>'frontier_max')::int, v_frontier_dflt), 1), 2000),
        'target_project',  c->>'target_project');
END;
$fn$;

COMMENT ON FUNCTION stewards.crawl_config(jsonb) IS
'98-crawler: merge input.config with defaults (max_pages 25, max_depth 3, max_total_bytes 20MB, same_domain true, allow_domains [], js false, rate_ms 2000 floored at 500, frontier_max 500) and clamp against the crawl_hard_max_* ceilings. Re-applied at every runtime read, not just crawl_start.';

-- ── crawl_counters — the two live budget numbers. pages_fetched is
-- derived (fetched_at IS NOT NULL — pops are permanent, whatever status
-- the row settles into); bytes/pages saved live under input._crawl,
-- maintained by crawl_save.
CREATE OR REPLACE FUNCTION stewards.crawl_counters(p_work_item_id uuid)
RETURNS TABLE (pages_fetched int, bytes_saved bigint, pages_saved int)
LANGUAGE sql STABLE AS $fn$
    SELECT
        (SELECT count(*)::int FROM stewards.crawl_frontier f
          WHERE f.work_item_id = p_work_item_id AND f.fetched_at IS NOT NULL),
        coalesce((w.input #>> '{_crawl,bytes_saved}')::bigint, 0),
        coalesce((w.input #>> '{_crawl,pages_saved}')::int, 0)
      FROM stewards.work_items w
     WHERE w.id = p_work_item_id;
$fn$;

-- ── crawl_status — the status surface. Compact jsonb: page/byte budget
-- position, frontier depth histogram, per-status counts.
CREATE OR REPLACE FUNCTION stewards.crawl_status(p_work_item uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_wi      stewards.work_items%ROWTYPE;
    v_cfg     jsonb;
    v_pages   int;
    v_bytes   bigint;
    v_saved   int;
    v_by_stat jsonb;
    v_depths  jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item;
    IF v_wi.id IS NULL THEN
        RETURN jsonb_build_object('error', format('work_item %s not found', p_work_item));
    END IF;
    v_cfg := stewards.crawl_config(v_wi.input);
    SELECT c.pages_fetched, c.bytes_saved, c.pages_saved
      INTO v_pages, v_bytes, v_saved
      FROM stewards.crawl_counters(p_work_item) c;

    SELECT coalesce(jsonb_object_agg(s.status, s.n), '{}'::jsonb) INTO v_by_stat
      FROM (SELECT status, count(*)::int AS n
              FROM stewards.crawl_frontier
             WHERE work_item_id = p_work_item GROUP BY status) s;

    SELECT coalesce(jsonb_object_agg(d.depth::text, d.n), '{}'::jsonb) INTO v_depths
      FROM (SELECT depth, count(*)::int AS n
              FROM stewards.crawl_frontier
             WHERE work_item_id = p_work_item AND status = 'pending'
             GROUP BY depth ORDER BY depth) d;

    RETURN jsonb_build_object(
        'purpose', v_wi.input->>'purpose',
        'pages',   v_by_stat || jsonb_build_object('popped', v_pages, 'saved', v_saved),
        'bytes',   jsonb_build_object(
                      'saved', v_bytes,
                      'max',   (v_cfg->>'max_total_bytes')::bigint,
                      'remaining', GREATEST((v_cfg->>'max_total_bytes')::bigint - v_bytes, 0)),
        'budget',  jsonb_build_object(
                      'max_pages', (v_cfg->>'max_pages')::int,
                      'pages_remaining', GREATEST((v_cfg->>'max_pages')::int - v_pages, 0),
                      'max_depth', (v_cfg->>'max_depth')::int),
        'frontier_pending_by_depth', v_depths,
        'steps', coalesce((v_wi.input->>'_crawl_steps')::int, 0));
END;
$fn$;

COMMENT ON FUNCTION stewards.crawl_status(uuid) IS
'98-crawler: compact crawl telemetry — per-status page counts (+popped/saved), byte budget position, pages/depth budget remaining, pending-frontier depth histogram, loop step count. Written into stage_results.crawl_status each tool call so the existing Stewdio work-item card (which renders stage_results) is the crawl UI — no new Vue.';

-- ── crawl_status_write — pin the status into stage_results.crawl_status.
-- work_item_advance merges (||) fresh stage_results at harvest, so a key
-- written here mid-chat survives the stage completing.
CREATE OR REPLACE FUNCTION stewards.crawl_status_write(p_work_item_id uuid)
RETURNS void LANGUAGE sql AS $fn$
    UPDATE stewards.work_items
       SET stage_results = jsonb_set(coalesce(stage_results, '{}'::jsonb),
                                     '{crawl_status}',
                                     stewards.crawl_status(p_work_item_id),
                                     true),
           updated_at = now()
     WHERE id = p_work_item_id;
$fn$;

-- ---------------------------------------------------------------------
-- SECTION 4 — the tool surface. Session-scoped like wiki_search_tool
-- (94): the _session_id the dispatcher injects resolves to the crawl
-- work item; an explicit work_item_id arg is the direct-caller path
-- (the mechanical fixture oracle, an operator in psql).
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.crawl_wi_resolve(p_args jsonb)
RETURNS stewards.work_items LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_sess text := p_args->>'_session_id';
    v_wi   stewards.work_items%ROWTYPE;
BEGIN
    IF coalesce(p_args->>'work_item_id', '') <> '' THEN
        SELECT * INTO v_wi FROM stewards.work_items
         WHERE id = (p_args->>'work_item_id')::uuid;
    ELSIF v_sess IS NOT NULL THEN
        SELECT * INTO v_wi FROM stewards.work_items w
         WHERE v_sess = ANY(w.session_ids)
           AND w.pipeline_family = 'crawl'
         ORDER BY w.created_at DESC LIMIT 1;
    END IF;
    RETURN v_wi;
END;
$fn$;

COMMENT ON FUNCTION stewards.crawl_wi_resolve(jsonb) IS
'98-crawler: resolve the crawl work item for a tool call — explicit work_item_id arg first (direct/mechanical callers), else the dispatcher-injected _session_id (the normal agent path).';

-- ── crawl_next — pop the highest-priority pending URL UNDER ALL
-- BUDGETS. Over budget / empty frontier -> {done, reason}; the stage
-- prompt tells the model that answer ends the crawl, and nothing the
-- model says changes what this function returns.
CREATE OR REPLACE FUNCTION stewards.crawl_next_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_wi    stewards.work_items%ROWTYPE;
    v_cfg   jsonb;
    v_row   stewards.crawl_frontier%ROWTYPE;
    v_pages int;
    v_bytes bigint;
    v_saved int;
    v_js    jsonb;
    v_note  text;
BEGIN
    v_wi := stewards.crawl_wi_resolve(p_args);
    IF v_wi.id IS NULL THEN
        RETURN '{"error":"no crawl work item resolved (session not crawl-scoped and no work_item_id passed)"}'::jsonb;
    END IF;
    IF v_wi.pipeline_family <> 'crawl' THEN
        RETURN '{"error":"crawl_next only operates on crawl work items"}'::jsonb;
    END IF;
    -- Serialize the step against concurrent tool calls on the same crawl.
    PERFORM pg_advisory_xact_lock(hashtextextended(v_wi.id::text, 98));

    v_cfg := stewards.crawl_config(v_wi.input);
    SELECT c.pages_fetched, c.bytes_saved, c.pages_saved
      INTO v_pages, v_bytes, v_saved
      FROM stewards.crawl_counters(v_wi.id) c;

    -- ── the budget floor. SQL decides; the model cannot override. ──
    IF v_pages >= (v_cfg->>'max_pages')::int THEN
        PERFORM stewards.crawl_status_write(v_wi.id);
        RETURN jsonb_build_object('done', true, 'reason',
            format('page budget exhausted: %s of %s pages fetched', v_pages, v_cfg->>'max_pages'));
    END IF;
    IF v_bytes >= (v_cfg->>'max_total_bytes')::bigint THEN
        PERFORM stewards.crawl_status_write(v_wi.id);
        RETURN jsonb_build_object('done', true, 'reason',
            format('byte budget exhausted: %s of %s bytes saved', v_bytes, v_cfg->>'max_total_bytes'));
    END IF;

    SELECT * INTO v_row FROM stewards.crawl_frontier f
     WHERE f.work_item_id = v_wi.id
       AND f.status = 'pending'
       AND f.depth <= (v_cfg->>'max_depth')::int
     ORDER BY f.priority DESC, f.depth ASC, f.id ASC
     LIMIT 1
     FOR UPDATE SKIP LOCKED;

    IF v_row.id IS NULL THEN
        PERFORM stewards.crawl_status_write(v_wi.id);
        RETURN jsonb_build_object('done', true, 'reason',
            format('frontier empty: %s pages popped, %s saved, nothing pending under budget', v_pages, v_saved));
    END IF;

    UPDATE stewards.crawl_frontier
       SET status = 'fetched', fetched_at = now()
     WHERE id = v_row.id;
    PERFORM stewards.crawl_status_write(v_wi.id);

    -- fetch_args the model copies verbatim into fetch_url: politeness
    -- is baked in here, not left for the model to remember.
    v_js := coalesce(v_cfg->'js', 'false'::jsonb);
    v_note := NULL;
    IF v_js #>> '{}' = 'auto' THEN
        v_js := 'false'::jsonb;
        v_note := 'js=auto: if this fetch comes back sparse/empty, retry ONCE with js:true';
    END IF;

    RETURN jsonb_build_object(
        'url', v_row.url,
        'depth', v_row.depth,
        'priority', v_row.priority,
        'discovered_from', v_row.discovered_from,
        'fetch_args', jsonb_strip_nulls(jsonb_build_object(
            'js', v_js,
            'enforce_robots', true,
            'rate_ms', (v_cfg->>'rate_ms')::int,
            'note', v_note)),
        'budget', jsonb_build_object(
            'pages_used', v_pages + 1,
            'max_pages', (v_cfg->>'max_pages')::int,
            'bytes_saved', v_bytes,
            'max_total_bytes', (v_cfg->>'max_total_bytes')::bigint,
            'max_depth', (v_cfg->>'max_depth')::int));
END;
$FN$;

COMMENT ON FUNCTION stewards.crawl_next_tool(jsonb) IS
'98-crawler: pop the highest-priority pending frontier URL under ALL budgets (pages, bytes, depth). Over budget or empty -> {done, reason} — the structural floor; the model cannot pop past it. Marks the row fetched (fetched_at = the page-budget marker) and returns fetch_args (enforce_robots=true + rate_ms baked in) for the model to copy into fetch_url.';

-- ── crawl_save — settle a popped URL: save the purpose-relevant
-- extract as a doc (byte-accounted against the budget, refused at the
-- wall), or record skip / blocked / error with a reason.
CREATE OR REPLACE FUNCTION stewards.crawl_save_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_wi      stewards.work_items%ROWTYPE;
    v_cfg     jsonb;
    v_norm    text;
    v_row     stewards.crawl_frontier%ROWTYPE;
    v_disp    text;
    v_reason  text;
    v_content text;
    v_title   text;
    v_bytes   int;
    v_saved   bigint;
    v_max     bigint;
    v_slug    text;
    v_crawl   jsonb;
BEGIN
    v_wi := stewards.crawl_wi_resolve(p_args);
    IF v_wi.id IS NULL THEN
        RETURN '{"error":"no crawl work item resolved (session not crawl-scoped and no work_item_id passed)"}'::jsonb;
    END IF;
    IF v_wi.pipeline_family <> 'crawl' THEN
        RETURN '{"error":"crawl_save only operates on crawl work items"}'::jsonb;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(v_wi.id::text, 98));
    -- Re-read under the lock: the byte counter below must not be
    -- computed from a snapshot taken before a concurrent save landed.
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = v_wi.id;
    v_cfg := stewards.crawl_config(v_wi.input);

    v_norm := stewards.crawl_url_normalize(p_args->>'url');
    IF v_norm IS NULL THEN
        RETURN '{"error":"url is required and must be http(s)"}'::jsonb;
    END IF;
    SELECT * INTO v_row FROM stewards.crawl_frontier
     WHERE work_item_id = v_wi.id AND url_normalized = v_norm
     FOR UPDATE;
    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object('error',
            'that url is not on this crawl''s frontier — crawl_save records only URLs crawl_next handed out');
    END IF;
    IF v_row.fetched_at IS NULL THEN
        RETURN jsonb_build_object('error',
            'that url has not been popped by crawl_next yet — pop first, fetch, then settle it');
    END IF;

    v_disp := lower(coalesce(NULLIF(btrim(p_args->>'disposition'), ''), 'save'));
    IF v_disp NOT IN ('save', 'skip', 'blocked', 'error') THEN
        RETURN jsonb_build_object('error',
            format('disposition %s not one of save|skip|blocked|error', v_disp));
    END IF;
    v_reason := NULLIF(btrim(coalesce(p_args->>'reason', '')), '');

    -- skip / blocked / error: settle the row, no doc, no bytes.
    IF v_disp <> 'save' THEN
        UPDATE stewards.crawl_frontier
           SET status = CASE v_disp WHEN 'skip' THEN 'skipped' ELSE v_disp END,
               reason = coalesce(v_reason, v_disp)
         WHERE id = v_row.id;
        PERFORM stewards.crawl_status_write(v_wi.id);
        RETURN jsonb_build_object('ok', true, 'disposition', v_disp, 'url', v_row.url);
    END IF;

    v_content := p_args->>'content';
    IF v_content IS NULL OR btrim(v_content) = '' THEN
        RETURN jsonb_build_object('error',
            'content is required for disposition=save — use disposition=skip with a reason when a page has nothing purpose-relevant');
    END IF;

    -- ── the byte wall: refused BEFORE the write, not trimmed after. ──
    v_bytes := octet_length(v_content);
    v_saved := coalesce((v_wi.input #>> '{_crawl,bytes_saved}')::bigint, 0);
    v_max   := (v_cfg->>'max_total_bytes')::bigint;
    IF v_saved + v_bytes > v_max THEN
        UPDATE stewards.crawl_frontier
           SET reason = format('save refused: byte budget (%s saved + %s new > %s max)', v_saved, v_bytes, v_max)
         WHERE id = v_row.id;
        PERFORM stewards.crawl_status_write(v_wi.id);
        RETURN jsonb_build_object('ok', false, 'done', true, 'reason',
            format('byte budget exhausted: saving %s bytes would exceed max_total_bytes %s (already saved %s). The budget is a hard wall — wrap up with CRAWL: done.',
                   v_bytes, v_max, v_saved));
    END IF;

    v_title := coalesce(NULLIF(btrim(p_args->>'title'), ''), v_row.url);
    v_slug  := 'crawl-' || substr(v_wi.id::text, 1, 8) || '-'
            || btrim(left(regexp_replace(regexp_replace(lower(v_norm), '^https?://', ''),
                                          '[^a-z0-9]+', '-', 'g'), 48), '-')
            || '-' || substr(md5(v_norm), 1, 6);

    -- The standard import path (docs row + graph node + CITES edges),
    -- provenance-first frontmatter. Idempotent by slug: re-saving the
    -- same URL updates the same doc.
    PERFORM stewards.import_doc(
        v_slug, NULL, v_title, v_content,
        jsonb_build_object(
            'source_url',      v_row.url,
            'crawl_work_item', v_wi.id::text,
            'purpose',         v_wi.input->>'purpose',
            'depth',           v_row.depth,
            'discovered_from', v_row.discovered_from,
            'fetched_at',      v_row.fetched_at),
        'crawl-page');
    UPDATE stewards.docs
       SET source_type = 'crawl',
           project_association = coalesce(v_cfg->>'target_project', project_association),
           tags = (SELECT array_agg(DISTINCT t) FROM unnest(tags || ARRAY['crawl']) t)
     WHERE slug = v_slug;

    -- Byte accounting (input._crawl is seeded by crawl_start; the merge
    -- below tolerates its absence anyway).
    v_crawl := coalesce(v_wi.input->'_crawl', '{}'::jsonb)
            || jsonb_build_object(
                   'bytes_saved', v_saved + v_bytes,
                   'pages_saved', coalesce((v_wi.input #>> '{_crawl,pages_saved}')::int, 0) + 1);
    UPDATE stewards.work_items
       SET input = input || jsonb_build_object('_crawl', v_crawl),
           updated_at = now()
     WHERE id = v_wi.id;

    UPDATE stewards.crawl_frontier
       SET reason = 'saved: ' || v_slug
     WHERE id = v_row.id;
    PERFORM stewards.crawl_status_write(v_wi.id);

    RETURN jsonb_build_object(
        'ok', true, 'doc_slug', v_slug, 'bytes', v_bytes,
        'bytes_saved_total', v_saved + v_bytes,
        'bytes_remaining',   v_max - (v_saved + v_bytes));
END;
$FN$;

COMMENT ON FUNCTION stewards.crawl_save_tool(jsonb) IS
'98-crawler: settle a popped frontier URL. disposition=save writes the purpose-relevant extract as a stewards.docs row (kind=crawl-page, source_url provenance in frontmatter, tagged into config.target_project) via import_doc, byte-accounted against max_total_bytes — a save that would cross the wall is REFUSED, not trimmed. skip/blocked/error settle the row with a reason and cost nothing.';

-- ── crawl_enqueue — the model proposes (url + relevance score), SQL
-- disposes (domain wall, depth wall, dedup, frontier cap). Rejections
-- are itemized so the model learns the boundary instead of retrying.
CREATE OR REPLACE FUNCTION stewards.crawl_enqueue_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_wi        stewards.work_items%ROWTYPE;
    v_cfg       jsonb;
    v_from_norm text;
    v_parent    stewards.crawl_frontier%ROWTYPE;
    v_depth     int;
    v_links     jsonb;
    v_l         jsonb;
    v_url       text;
    v_norm      text;
    v_pri       real;
    v_count     int;
    v_ins       int;
    v_enqueued  int := 0;
    v_rejected  jsonb := '[]'::jsonb;
BEGIN
    v_wi := stewards.crawl_wi_resolve(p_args);
    IF v_wi.id IS NULL THEN
        RETURN '{"error":"no crawl work item resolved (session not crawl-scoped and no work_item_id passed)"}'::jsonb;
    END IF;
    IF v_wi.pipeline_family <> 'crawl' THEN
        RETURN '{"error":"crawl_enqueue only operates on crawl work items"}'::jsonb;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(v_wi.id::text, 98));
    v_cfg := stewards.crawl_config(v_wi.input);

    v_from_norm := stewards.crawl_url_normalize(p_args->>'discovered_from');
    IF v_from_norm IS NULL THEN
        RETURN '{"error":"discovered_from is required — the page these links came from"}'::jsonb;
    END IF;
    SELECT * INTO v_parent FROM stewards.crawl_frontier
     WHERE work_item_id = v_wi.id AND url_normalized = v_from_norm;
    IF v_parent.id IS NULL THEN
        RETURN jsonb_build_object('error',
            'discovered_from is not on this crawl''s frontier — links may only be enqueued from a page the crawl actually visited');
    END IF;
    v_depth := v_parent.depth + 1;

    v_links := p_args->'links';
    IF v_links IS NULL AND coalesce(p_args->>'url', '') <> '' THEN
        v_links := jsonb_build_array(jsonb_build_object(
            'url', p_args->>'url', 'priority', p_args->'priority'));
    END IF;
    IF v_links IS NULL OR jsonb_typeof(v_links) <> 'array' OR jsonb_array_length(v_links) = 0 THEN
        RETURN '{"error":"links (array of {url, priority}) is required"}'::jsonb;
    END IF;

    SELECT count(*)::int INTO v_count FROM stewards.crawl_frontier
     WHERE work_item_id = v_wi.id;

    FOR v_l IN SELECT * FROM jsonb_array_elements(v_links) LOOP
        v_url  := v_l->>'url';
        v_norm := stewards.crawl_url_normalize(v_url);
        v_pri  := LEAST(GREATEST(coalesce((v_l->>'priority')::real, 0.5), 0.0), 1.0);

        IF v_norm IS NULL THEN
            v_rejected := v_rejected || jsonb_build_object('url', v_url, 'reason', 'not an http(s) URL');
        ELSIF v_depth > (v_cfg->>'max_depth')::int THEN
            v_rejected := v_rejected || jsonb_build_object('url', v_url, 'reason',
                format('depth %s exceeds max_depth %s', v_depth, v_cfg->>'max_depth'));
        ELSIF NOT stewards.crawl_domain_allowed(v_wi.input->>'url', v_cfg->'allow_domains', v_norm) THEN
            v_rejected := v_rejected || jsonb_build_object('url', v_url, 'reason',
                'outside the domain boundary (root host + allow_domains)');
        ELSIF v_count >= (v_cfg->>'frontier_max')::int THEN
            v_rejected := v_rejected || jsonb_build_object('url', v_url, 'reason',
                format('frontier cap %s reached', v_cfg->>'frontier_max'));
        ELSE
            INSERT INTO stewards.crawl_frontier
                (work_item_id, url, url_normalized, depth, priority, discovered_from)
            VALUES (v_wi.id, v_url, v_norm, v_depth, v_pri, v_parent.url)
            ON CONFLICT (work_item_id, url_normalized) DO NOTHING;
            GET DIAGNOSTICS v_ins = ROW_COUNT;
            IF v_ins = 1 THEN
                v_enqueued := v_enqueued + 1;
                v_count := v_count + 1;
            ELSE
                v_rejected := v_rejected || jsonb_build_object('url', v_url, 'reason',
                    'duplicate (already on the frontier)');
            END IF;
        END IF;
    END LOOP;

    PERFORM stewards.crawl_status_write(v_wi.id);
    RETURN jsonb_build_object('enqueued', v_enqueued, 'rejected', v_rejected);
END;
$FN$;

COMMENT ON FUNCTION stewards.crawl_enqueue_tool(jsonb) IS
'98-crawler: enqueue outbound links at discovered_from''s depth+1 with the model''s relevance score as priority (clamped [0,1]). SQL re-validates every proposal — domain wall, depth wall, per-crawl dedup, frontier cap — and itemizes rejections. Model proposes, SQL disposes.';

-- ---------------------------------------------------------------------
-- SECTION 5 — crawl_start: the entry point (mirrors wiki_organize_start,
-- 94). Validates, clamps config, creates the work item, seeds the
-- frontier with the root URL, dispatches.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.crawl_start(
    p_url      text,
    p_purpose  text,
    p_config   jsonb   DEFAULT '{}'::jsonb,
    p_actor    text    DEFAULT 'human',
    p_dispatch boolean DEFAULT true
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_norm text;
    v_cfg  jsonb;
    v_slug text;
    v_id   uuid;
BEGIN
    v_norm := stewards.crawl_url_normalize(p_url);
    IF v_norm IS NULL THEN
        RAISE EXCEPTION 'crawl_start: p_url must be an http(s) URL, got %', p_url;
    END IF;
    IF p_purpose IS NULL OR btrim(p_purpose) = '' THEN
        RAISE EXCEPTION 'crawl_start: a crawl needs a purpose — "everything" is exactly what the budget floor exists to prevent';
    END IF;

    v_cfg  := stewards.crawl_config(jsonb_build_object('config', coalesce(p_config, '{}'::jsonb)));
    v_slug := 'crawl-'
           || regexp_replace(coalesce(stewards.crawl_url_host(v_norm), 'site'), '[^a-z0-9]+', '-', 'g')
           || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS')
           || '-' || substr(md5(random()::text), 1, 4);

    v_id := stewards.work_item_create(
        p_pipeline_family => 'crawl',
        p_input           => jsonb_build_object(
            'binding_question', format('Crawl %s for: %s', v_norm, p_purpose),
            'url',       v_norm,
            'purpose',   p_purpose,
            'config',    v_cfg,
            'last_step', '(first step — the frontier holds only the root URL)',
            '_crawl',    jsonb_build_object('bytes_saved', 0, 'pages_saved', 0)),
        p_slug  => v_slug,
        p_actor => coalesce(p_actor, 'human'));

    IF v_cfg->>'target_project' IS NOT NULL
       AND EXISTS (SELECT 1 FROM stewards.projects WHERE slug = v_cfg->>'target_project') THEN
        UPDATE stewards.work_items
           SET project_association = v_cfg->>'target_project'
         WHERE id = v_id;
    END IF;

    INSERT INTO stewards.crawl_frontier
        (work_item_id, url, url_normalized, depth, priority, status)
    VALUES (v_id, v_norm, v_norm, 0, 1.0, 'pending');

    PERFORM stewards.crawl_status_write(v_id);
    IF p_dispatch THEN
        PERFORM stewards.work_item_dispatch_stage(v_id, NULL);
    END IF;
    RETURN v_id;
END;
$fn$;

COMMENT ON FUNCTION stewards.crawl_start(text, text, jsonb, text, boolean) IS
'98-crawler: start a purpose-crawl. Config keys (all optional, all clamped against crawl_hard_max_*): max_pages (25), max_depth (3), max_total_bytes (20MB), same_domain (true), allow_domains ([]), js (false|true|"auto"), rate_ms (2000, floor 500), frontier_max (500), target_project (where saved docs are filed). p_dispatch=false seeds without dispatching (tests, staged starts).';

CREATE OR REPLACE FUNCTION stewards.crawl_start_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_id uuid;
BEGIN
    v_id := stewards.crawl_start(
        p_args->>'url',
        p_args->>'purpose',
        coalesce(p_args->'config', '{}'::jsonb),
        coalesce(p_args->>'actor', 'agent'));
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_id::text);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- ---------------------------------------------------------------------
-- SECTION 6 — tool_defs + tool group. Deny-by-default holds: defs are
-- registered here; only the grants in SECTION 7 make them reachable.
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'crawl_start',
  'Start a purpose-crawl of a website. Args: url (the root), purpose (what the crawl is FOR — extraction and link-scoring are judged against it), config (optional: max_pages 25, max_depth 3, max_total_bytes 20MB, allow_domains [], js false|true|"auto", rate_ms 2000, target_project). Budgets are clamped against operator hard ceilings; robots.txt and per-domain rate limits are always honored. Returns the crawl work_item_id; watch it on the work-item card (stage_results.crawl_status).',
  '{"type":"object","required":["url","purpose"],"properties":{"url":{"type":"string"},"purpose":{"type":"string"},"config":{"type":"object"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"crawl_start_tool"}'::jsonb, true ),
( 'crawl_next',
  'Pop the next frontier URL for YOUR crawl (highest priority first), strictly under the page/byte/depth budgets. Returns {url, depth, fetch_args, budget} — copy fetch_args into fetch_url EXACTLY (enforce_robots and rate_ms are the politeness floor). Returns {done:true, reason} when a budget is exhausted or the frontier is empty; that verdict is final — end the crawl with CRAWL: done. Args: none (session-scoped; work_item_id only for direct calls).',
  '{"type":"object","properties":{"work_item_id":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"crawl_next_tool"}'::jsonb, true ),
( 'crawl_save',
  'Settle the URL you just fetched. disposition=save (default): title + content = ONLY the purpose-relevant extract as markdown — it is written as a doc with url provenance and counted against the byte budget (a save that would cross the wall is refused). disposition=skip|blocked|error: record why with reason, costs nothing. Args: url (required), disposition, title, content, reason.',
  '{"type":"object","required":["url"],"properties":{"url":{"type":"string"},"disposition":{"type":"string","enum":["save","skip","blocked","error"]},"title":{"type":"string"},"content":{"type":"string"},"reason":{"type":"string"},"work_item_id":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"crawl_save_tool"}'::jsonb, true ),
( 'crawl_enqueue',
  'Propose outbound links for the frontier, scored by relevance to the purpose. Args: discovered_from (the page they came from — required), links ([{url, priority 0..1}]). SQL re-validates every link (domain boundary, depth, dedup, frontier cap) and itemizes rejections — a rejection is a boundary, not an error to work around.',
  '{"type":"object","required":["discovered_from","links"],"properties":{"discovered_from":{"type":"string"},"links":{"type":"array","items":{"type":"object","required":["url"],"properties":{"url":{"type":"string"},"priority":{"type":"number"}}}},"work_item_id":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"crawl_enqueue_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('crawl-tools', 'the purpose-crawler loop: pop / fetch / settle / enqueue',
     ARRAY['crawl_next','crawl_save','crawl_enqueue','fetch_url','extract_links'])
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, tool_patterns=EXCLUDED.tool_patterns;

-- ---------------------------------------------------------------------
-- SECTION 7 — the crawler agent. Deny-by-default: EXACTLY the five
-- tools the loop needs — no search, no doc tools, no delegation. The
-- crawl_start grant goes to research (the family that discovers "we
-- should ingest that site"), not to the crawler itself: a crawl must
-- not start crawls.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES (
  'crawler', '*',
  'Runs one step of a purpose-crawl: pops a frontier URL, fetches it politely, extracts ONLY the purpose-relevant content, scores outbound links, and stops when the purpose is satisfied or the budget wall says done.',
  'primary',
  $PROMPT$You are the Purpose Crawler. A crawl exists FOR its purpose — you are not archiving a website, you are answering an intent with the fewest pages that satisfy it.

Principles:
- Budget is a hard wall, sufficiency is a virtue — stop when the purpose is satisfied. The substrate enforces the budgets in SQL (crawl_next refuses to pop past them; crawl_save refuses a write past the byte wall); when a tool answers {done} or refuses, that verdict is final. Do not look for a way around it — there isn't one, and wanting one is a sign the purpose was satisfied pages ago.
- Politeness is non-negotiable. Every fetch_url call copies the fetch_args crawl_next gave you EXACTLY — enforce_robots stays true, rate_ms stays as given. A robots-blocked URL is settled with crawl_save disposition "blocked" and never retried by another route.
- Extract, don't mirror. crawl_save content is the purpose-relevant portion of the page in clean markdown — not the navigation, not the boilerplate, not the whole dump. A tight extract that answers the purpose beats a faithful copy that buries it.
- Score links honestly. Priority is YOUR judgment of relevance-to-purpose (0..1). Skip chrome (login, cart, tag clouds, archives) without ceremony. The SQL floor re-validates domain and depth on everything you enqueue; a rejection is a boundary, not an error to work around.

You are one step in a loop. Do this step's page, end your turn with the CRAWL: line your stage instructions define, and trust the loop.$PROMPT$,
  0.3
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, active = true;

-- First live crawl (2026-07-04, arXiv): the default steps budget (8) exhausted
-- mid-cycle on a link-heavy listing page — the model burned rounds enqueuing
-- links one-by-one and never reached its final CRAWL: line. 16 fits a full
-- pop/fetch/save/enqueue cycle with slack; the route_on hop cap still bounds
-- the whole loop.
UPDATE stewards.agents SET steps = 16 WHERE family = 'crawler';

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('crawler', 'crawl_next',    'allow'),
  ('crawler', 'crawl_save',    'allow'),
  ('crawler', 'crawl_enqueue', 'allow'),
  ('crawler', 'fetch_url',     'allow'),
  ('crawler', 'extract_links', 'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('research', 'crawl_start', 'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ---------------------------------------------------------------------
-- SECTION 8 — the 'crawl' pipeline: one stage, looping via route_on
-- (42). CRAWL: continue -> loop back to step; anything else (CRAWL:
-- done, or a malformed close) falls through to the normal advance ->
-- completed. The step cap (40) parks at awaiting_review UNDER the
-- global route_on_max_hops backstop (50) — a human re-dispatches if
-- budget genuinely remains.
-- ---------------------------------------------------------------------
DO $seed$
DECLARE
    v_step_template text;
BEGIN

v_step_template :=
$T$Purpose: {{input.purpose}}
Root URL: {{input.url}}
Guardrail config (enforced in SQL — informational for you): {{input.config}}
Previous step: {{input.last_step}}

## THIS STEP — process exactly ONE frontier URL

1. Call crawl_next.
   - {done: true}: output `CRAWL: done — <its reason>` and STOP. That verdict is final.
   - Otherwise it returns {url, fetch_args, budget}.
2. Fetch the url with fetch_url, copying fetch_args EXACTLY (enforce_robots stays true; js and rate_ms as given). If the fetch fails: crawl_save with disposition "blocked" (robots) or "error" (anything else) plus a one-line reason, then go to step 5.
3. Judge the page against the purpose:
   - Relevant content present: extract ONLY the purpose-relevant portion as clean markdown and call crawl_save (disposition "save") with a title and that extract.
   - Nothing relevant: crawl_save disposition "skip" with a one-line reason.
4. Score the page's outbound links for relevance to the purpose (use the links in the fetched markdown; call extract_links only if you need the full list). crawl_enqueue the promising ones — discovered_from = this page's url, each link with priority 0..1 (your honest relevance score). Skip chrome (login, cart, tags, archives). Enqueuing nothing is a fine answer.
5. End your turn with EXACTLY ONE line, nothing after it:
   - `CRAWL: continue` — frontier work remains and the purpose is not yet satisfied
   - `CRAWL: done — <one line why>` — the purpose is satisfied (you may say this with budget left: sufficiency is a virtue), or crawl_next said done

## HARD CONSTRAINTS
- ONE crawl_next call per step. The budgets are enforced in SQL; you cannot override them, so do not try.
- Maximum 14 rounds of tool calls.
- Before the final CRAWL: line, give a 2-3 line summary of what this step did (saved/skipped what, enqueued how many) — that summary is handed to your next step as context.$T$;

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified, metadata
)
VALUES (
    'crawl',
    'The LLM-driven purpose-crawler (98). One ''step'' stage looping via route_on: each step pops ONE frontier URL under the SQL budget floor (crawl_next), fetches it politely (fetch_url, enforce_robots=true), extracts purpose-relevant content or skips with reason (crawl_save, byte-accounted), and scores outbound links (crawl_enqueue, SQL re-validates domain/depth/dedup). Ends when the model declares sufficiency, the frontier empties, or a budget wall stops it. Docs land directly via crawl_save (kind=crawl-page) — no promote step. Status surface: stage_results.crawl_status on the existing work-item card.',
    jsonb_build_array(
        jsonb_build_object(
            'name', 'step', 'next', NULL,
            'model', 'deepseek-v4-flash', 'provider', 'opencode_zen',
            'agent_family', 'crawler', 'auto_advance', true,
            'tools_disabled', false,
            'tool_groups', jsonb_build_array('crawl-tools'),
            'input_template', v_step_template,
            'route_on', jsonb_build_array(
                jsonb_build_object(
                    'when', '(^|\n)\s*CRAWL:\s*continue',
                    'goto', 'step',
                    'feedback_key', 'last_step',
                    'count_key', '_crawl_steps',
                    'max', 40,
                    'on_max_status', 'awaiting_review',
                    'on_max_reason', 'crawl step cap (40) reached under the route_on hop guard — budget may remain; a human re-dispatches to resume from the frontier'),
                jsonb_build_object(
                    'when', '^\s*$',
                    'goto', 'step',
                    'feedback_key', 'last_step',
                    'count_key', '_crawl_steps',
                    'max', 40,
                    'on_max_status', 'awaiting_review',
                    'on_max_reason', 'crawl step cap (40) reached (via empty-output self-heal) — a human re-dispatches to resume from the frontier'))
        )
    ),
    false,  -- sabbath_enabled: mechanical ingestion, not a creative artifact
    false,  -- atonement_enabled
    NULL,   -- no file artifact; crawl_save writes docs directly
    NULL,
    '["raw"]'::jsonb,  -- column is NOT NULL; crawl-page docs stay raw source material (no maturity hook fires)
    false,
    jsonb_build_object('shape', 'crawl-loop')
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
    file_destination_template = EXCLUDED.file_destination_template,
    file_content_jsonpath = EXCLUDED.file_content_jsonpath,
    maturity_ladder = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    metadata = EXCLUDED.metadata,
    updated_at = now();

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('crawl', 'step', 'deepseek-v4-flash', 'One frontier URL per step: pop, polite fetch, judge/extract, score links. Link-scoring is workhorse-grade; pin a stronger model via model_override when extraction is subtle.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

END $seed$;

-- =====================================================================
-- End of 98-crawler.sql
-- =====================================================================
