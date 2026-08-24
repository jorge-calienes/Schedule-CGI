-- The "Coverage" (call-out reassignment) dashboard forces every out person
-- into either "assigned a coverer" or "still pending" — there was no way
-- to say "this one doesn't actually need covering" (a quiet area, a short
-- gap, etc.), so people stayed stuck in the pending list forever. This is
-- a same-day flag like callouts: one row per staff member, cleared when
-- they're marked back in (see the app-side reconcile logic).

create table coverage_waivers (
  id         uuid primary key default gen_random_uuid(),
  staff_id   uuid not null unique references staff(id) on delete cascade,
  waived_by  uuid references accounts(id),
  created_at timestamptz not null default now()
);

alter table coverage_waivers enable row level security;
create policy coverage_waiver_select on coverage_waivers for select using ((select auth.uid()) is not null);
create policy coverage_waiver_write  on coverage_waivers for all using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table coverage_waivers;
