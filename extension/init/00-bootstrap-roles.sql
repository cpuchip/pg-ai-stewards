-- 00-bootstrap-roles.sql — operator bootstrap: the brain group roles.
--
-- pg_ai_stewards v49+ GRANTs to two cluster-global group roles. Roles are
-- cluster-global objects, and the ruling (sol-p0-release-batch, 2026-08-11)
-- is that the EXTENSION MUST NOT OWN THEM — an extension that creates
-- cluster-global roles on install and can't drop them on uninstall is a
-- landlord overreaching its lease. So the operator provisions them, once,
-- before CREATE EXTENSION:
--
--   brain_read   (NOLOGIN) — read the shared record: lane views, recall.
--   brain_absorb (NOLOGIN) — write through the guarded lane path
--                            (brain_add / brain_amend); includes brain_read.
--
-- Idempotent — safe to run repeatedly. Mirrors the role shape the private
-- enrollment tooling (brain-client roster.py GROUPS_SQL) has always used, so
-- a public install and the host install agree on what the names mean. The
-- broader table grants (SELECT on stewards.*, INSERT/UPDATE on nodes and
-- fact_edges) are the ENROLLMENT step's business, applied per box after the
-- extension exists — not this file's.
--
-- Placement: docker-entrypoint-initdb.d runs files in sorted order, and
-- "00-bootstrap-roles" sorts before "00-extensions", so a compose first-boot
-- provisions the roles and then installs the extension. Manual installs run:
--
--   psql -U <superuser> -d <db> -f extension/init/00-bootstrap-roles.sql
--
-- before CREATE EXTENSION pg_ai_stewards. (v49 preflights this and refuses
-- with a pointer here if the roles are missing.)

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'brain_read') THEN
        CREATE ROLE brain_read NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'brain_absorb') THEN
        CREATE ROLE brain_absorb NOLOGIN;
    END IF;
END $$;

GRANT brain_read TO brain_absorb;
