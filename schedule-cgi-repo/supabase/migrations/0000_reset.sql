-- ============================================================================
-- Rotation Control — Phase 2 schema RESET
-- ============================================================================
-- Run this ONCE if 0001_init.sql (and/or 0002_pin_auth.sql) partially ran and
-- you're getting "already exists" errors. It drops everything those two
-- migrations create, so you can re-run them cleanly from scratch.
--
-- Safe to run even if some objects don't exist yet — every DROP uses
-- IF EXISTS. Safe for a fresh/empty project; if you've already put real
-- data into these tables, back it up first, since this deletes it.
-- ============================================================================

-- 0002_pin_auth.sql objects
drop function if exists verify_pin(text, text) cascade;
drop function if exists set_pin(uuid, text) cascade;
drop table if exists pin_lookup cascade;

-- 0001_init.sql objects — view, then tables (cascade handles FKs/policies),
-- then functions, then types.
drop view if exists my_evaluation_queue cascade;

drop table if exists audit_log cascade;
drop table if exists evaluations cascade;
drop table if exists rotation_period_assignments cascade;
drop table if exists rotation_periods cascade;
drop table if exists time_off cascade;
drop table if exists callouts cascade;
drop table if exists assignments cascade;
drop table if exists staff_language_certs cascade;
drop table if exists staff cascade;
drop table if exists rotation_flow_stages cascade;
drop table if exists rotation_flows cascade;
drop table if exists languages cascade;
drop table if exists shifts cascade;
drop table if exists supervisors cascade;
drop table if exists areas cascade;
drop table if exists departments cascade;
drop table if exists accounts cascade;

drop function if exists is_admin() cascade;
drop function if exists is_manager() cascade;
drop function if exists current_account() cascade;

drop type if exists eval_recommendation cascade;
drop type if exists audit_action cascade;
drop type if exists account_status cascade;
drop type if exists account_role cascade;

-- Note: this does NOT touch auth.users — any auth accounts already created
-- via createUser()/grant.js are untouched. If you want a fully clean slate
-- including those, remove them from Authentication → Users in the dashboard
-- separately (there's usually nothing there yet at this stage).
