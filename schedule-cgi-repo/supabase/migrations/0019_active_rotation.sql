-- Persists the in-progress rotation period (start date, length, label) so it
-- survives a page reload / new device instead of silently resetting to
-- "today" + a 2-week default every time the app boots. Singleton row,
-- enforced via a fixed primary key.
create table active_rotation (
  id          boolean primary key default true,
  period_label text not null,
  start_date  date not null,
  weeks       integer not null default 2,
  updated_by  uuid references accounts(id),
  updated_at  timestamptz not null default now(),
  constraint active_rotation_singleton check (id)
);

alter table active_rotation enable row level security;
create policy active_rotation_select on active_rotation for select using ((select auth.uid()) is not null);
create policy active_rotation_write  on active_rotation for all using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table active_rotation;
