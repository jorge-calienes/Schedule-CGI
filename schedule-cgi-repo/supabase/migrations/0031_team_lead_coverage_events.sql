-- state.teamLeadCoverage (auto-logged whenever a team lead is quick-marked
-- out and no other team lead in the same department is free to cover their
-- area) was local-only — same bug class state.coverage was in before
-- 0007_coverage_sync.sql fixed it: an event logged on one device/kiosk
-- never showed up in the printed report's "Team lead coverage events"
-- table pulled up on another device.
--
-- One row per area, not an append-only log — the app's own write site
-- (index.html, the quick-out chip handler) only ever creates an entry the
-- FIRST time an area has no team lead to cover it (`if(!state.teamLeadCoverage[areaId])`)
-- and never updates it afterward, so `area_id` as the primary key mirrors
-- that exactly. No approve/review workflow exists for this today (status
-- is always 'pending', nothing ever changes it) — this isn't a request
-- queue like reassignment/position requests, just an informational record
-- that currently only surfaces in a printed report.

create table team_lead_coverage_events (
  area_id       uuid primary key references areas(id) on delete cascade,
  out_lead_id   uuid not null references staff(id) on delete cascade,
  cover_lead_id uuid references staff(id) on delete set null,
  event_date    date not null default current_date,
  status        text not null default 'pending',
  created_by    uuid references accounts(id),
  created_at    timestamptz not null default now()
);

alter table team_lead_coverage_events enable row level security;

-- Same "any signed-in user can read, only a manager can write" shape as
-- positions/coverage_waivers/temp_moves/position_requests/proficiency_ratings
-- — marking a team lead out (the only trigger for this table) is already a
-- manager-only board action, team leads have no write path to it at all.
create policy team_lead_coverage_events_select on team_lead_coverage_events for select
  using ((select auth.uid()) is not null);
create policy team_lead_coverage_events_write on team_lead_coverage_events for all
  using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table team_lead_coverage_events;
