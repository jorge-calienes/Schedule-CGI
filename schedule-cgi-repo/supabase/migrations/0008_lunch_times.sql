-- Lunch time was a hardcoded two-option <select> ('12:00' / '1:00') baked
-- directly into the staff editor markup, unlike shift hours and languages
-- which already had their own manageable catalog tables + a "Manage" screen.
-- An admin had no way to add a third lunch time without editing code.
-- Mirrors the shifts table exactly (see 0001_init.sql) — same shape, same
-- read-for-any-signed-in-user / write-for-managers-only policy split.

create table lunch_times (
  id         uuid primary key default gen_random_uuid(),
  label      text not null,
  sort_order int  not null default 0
);

alter table lunch_times enable row level security;
create policy lunch_time_select on lunch_times for select using (auth.uid() is not null);
create policy lunch_time_write  on lunch_times for all using (is_manager()) with check (is_manager());

-- Seed with the two options the hardcoded dropdown used to offer, so
-- existing staff records whose break_times_label ends in "12:00" or "1:00"
-- keep matching a real catalog entry after this migration lands.
insert into lunch_times (label, sort_order) values ('12:00 PM', 0), ('1:00 PM', 1);
