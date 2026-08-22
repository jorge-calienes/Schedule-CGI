-- Break time (the first half of a staff member's combined
-- "break_times_label" string, e.g. "10:00 / 12:00 PM") has always been
-- free text edited through the full staff editor — unlike lunch time,
-- which got its own manageable catalog in 0008. Staggering everyone's
-- 15-minute break across a handful of fixed slots (10:00, 10:15, 10:30,
-- 10:45, ...) needs the same kind of catalog lunch times already has.
-- Mirrors lunch_times exactly — same shape, same RLS split.

create table break_times (
  id         uuid primary key default gen_random_uuid(),
  label      text not null,
  sort_order int  not null default 0
);

alter table break_times enable row level security;
create policy break_time_select on break_times for select using (auth.uid() is not null);
create policy break_time_write  on break_times for all using (is_manager()) with check (is_manager());

insert into break_times (label, sort_order) values
  ('10:00 AM', 0), ('10:15 AM', 1), ('10:30 AM', 2), ('10:45 AM', 3);
