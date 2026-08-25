-- Tracks the "in between" attendance events that are neither a full-day
-- callout nor a scheduled time-off record: arriving late, or leaving
-- before the end of a shift (feeling sick, etc.). Also doubles as the
-- durable history for callouts themselves — the `callouts` table is just
-- a "currently out" flag (its row is deleted the moment someone's marked
-- back in), so it can't answer "how many times was X out in March" on its
-- own. Every callout mark now also writes a row here that's never deleted,
-- giving the attendance report one table to count all three from.
--
-- Scheduled leave (the fourth report category) doesn't need a table here
-- at all — time_off already has durable start_date/end_date rows the
-- report reads directly.

create type attendance_event_type as enum ('callout', 'late_arrival', 'left_early');

create table attendance_events (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references staff(id) on delete cascade,
  event_type  attendance_event_type not null,
  event_date  date not null,
  note        text,
  created_by  uuid references accounts(id),
  created_at  timestamptz not null default now()
);
create index attendance_events_staff_idx on attendance_events(staff_id, event_date desc);
create index attendance_events_date_idx  on attendance_events(event_date);
create index attendance_events_type_date_idx on attendance_events(event_type, event_date);

alter table attendance_events enable row level security;
create policy attendance_events_select on attendance_events for select using ((select auth.uid()) is not null);
create policy attendance_events_write  on attendance_events for all using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table attendance_events;
