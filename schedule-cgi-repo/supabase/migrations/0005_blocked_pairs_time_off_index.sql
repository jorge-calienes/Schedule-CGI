-- state.blocks (pairs of staff who can't be placed in the same area
-- together) never had a table — it was local-only from the very first
-- localStorage version of the app and stayed that way through every prior
-- migration step.

create table blocked_pairs (
  id          uuid primary key default gen_random_uuid(),
  staff_a_id  uuid not null references staff(id) on delete cascade,
  staff_b_id  uuid not null references staff(id) on delete cascade,
  created_at  timestamptz not null default now(),
  constraint blocked_pairs_no_self check (staff_a_id <> staff_b_id)
);

-- order-independent uniqueness: (A,B) and (B,A) are the same block.
create unique index blocked_pairs_unique_idx
  on blocked_pairs (least(staff_a_id, staff_b_id), greatest(staff_a_id, staff_b_id));

alter table blocked_pairs enable row level security;
create policy blocked_pairs_select on blocked_pairs for select using (auth.uid() is not null);
create policy blocked_pairs_write  on blocked_pairs for all using (is_manager()) with check (is_manager());

-- time_off already existed and was already RLS-covered (timeoff_write in
-- 0001_init.sql) but had zero read/write callers anywhere in the app —
-- loadBoard() never fetched it and the time-off manager screen mutated
-- state.timeOff locally only. Nothing schema-side needed for that piece,
-- just noting it here since this migration is the one that turns it on.
