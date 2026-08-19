-- state.coverage (who is currently covering someone else's area, and
-- where they return to) and the time-off screen's "who's covering this
-- absence" link were both fully local-only. That caused real bugs, not
-- just a missing sync: the coverage link on a time-off entry vanished on
-- every page reload (bootApp() overwrote state.timeOff wholesale from
-- Supabase, which had no column for it), the covering person's board
-- position never reached the assignments table so they snapped back to
-- their original spot on refresh while the app still thought they were
-- out covering, and scheduled-leave callouts never showed up for anyone
-- on a different device. See PHASE2_ROADMAP.md for the full writeup.

alter table time_off
  add column covering_staff_id uuid references staff(id) on delete set null;

-- One row per person currently covering — mirrors state.coverage's shape
-- exactly ({staffId: {returnToAreaId, date}}), so mapping back into local
-- state needs no reshaping. staff_id is the PK: a person can only be
-- covering one thing at a time, same invariant the local object already
-- enforced.
create table coverage_assignments (
  staff_id          uuid primary key references staff(id) on delete cascade,
  return_to_area_id uuid references areas(id) on delete set null,
  started_date      date not null default current_date,
  created_by        uuid references accounts(id),
  created_at        timestamptz not null default now()
);

alter table coverage_assignments enable row level security;
create policy coverage_select on coverage_assignments for select using (auth.uid() is not null);
create policy coverage_write  on coverage_assignments for all using (is_manager()) with check (is_manager());
