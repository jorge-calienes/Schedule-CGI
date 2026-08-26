-- A move or swap marked "just for today" — one row per person currently
-- displaced from their real rotation spot, remembering where to snap them
-- back to. Mirrors coverage_assignments' shape and revert mechanics
-- (see 0007_coverage_sync.sql) exactly, but isn't tied to covering a
-- callout/absence — any ad-hoc move or swap can be marked temporary.
create table temp_moves (
  staff_id          uuid primary key references staff(id) on delete cascade,
  return_to_area_id uuid references areas(id) on delete set null,
  started_date      date not null default current_date,
  created_by        uuid references accounts(id),
  created_at        timestamptz not null default now()
);

alter table temp_moves enable row level security;
create policy temp_moves_select on temp_moves for select using ((select auth.uid()) is not null);
create policy temp_moves_write  on temp_moves for all using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table temp_moves;
