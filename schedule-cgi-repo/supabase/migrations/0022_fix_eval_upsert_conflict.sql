-- submitEvaluation()'s upsert targets ON CONFLICT (staff_id, evaluator_id,
-- period_id) — a plain 3-column list, which is all PostgREST's `onConflict`
-- option can ever emit. But the table's only uniqueness guard was the
-- EXPRESSION index evaluations_unique_per_period, keyed on
-- (staff_id, evaluator_id, COALESCE(period_id, '00000000-...')) — and
-- Postgres will never match a plain-column ON CONFLICT target against an
-- expression index, even when no row would actually conflict. Every
-- evaluation submission (team lead or manager) has therefore always failed
-- with 42P10 "there is no unique or exclusion constraint matching the ON
-- CONFLICT specification" — confirmed live: the evaluations table has zero
-- rows despite the feature being in active use.
--
-- Postgres 15+'s UNIQUE NULLS NOT DISTINCT replaces the COALESCE-to-a-
-- sentinel trick with a real constraint on the plain columns — a valid ON
-- CONFLICT target — while still treating two NULL period_ids for the same
-- staff+evaluator as a conflict, same de-dup intent as the original index.
drop index if exists evaluations_unique_per_period;

alter table evaluations
  add constraint evaluations_unique_per_period unique nulls not distinct (staff_id, evaluator_id, period_id);
