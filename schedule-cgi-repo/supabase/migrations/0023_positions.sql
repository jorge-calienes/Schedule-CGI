-- Job position/title codes (SA2, SA3, SA4, SA4FL "SA4 + foreign language",
-- AAA, OP2, ...) — an admin-editable catalog, same shape as languages and
-- rotation_flows, so titles can be added/renamed/removed from the app
-- (Manage positions) without a code change and rename centrally for
-- everyone holding that title. staff.position_id is set null on delete so
-- removing a title never blocks deleting it or orphans a staff record.

create table positions (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

alter table staff add column position_id uuid references positions(id) on delete set null;

alter table positions enable row level security;
create policy position_select on positions for select using ((select auth.uid()) is not null);
create policy position_write  on positions for all using (is_manager()) with check (is_manager());

insert into positions (name, sort_order) values
  ('SA2', 0), ('SA3', 1), ('SA4', 2), ('SA4FL', 3), ('AAA', 4), ('OP2', 5);

alter publication supabase_realtime add table positions;
