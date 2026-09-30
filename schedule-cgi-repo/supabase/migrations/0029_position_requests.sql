-- Position-change requests were local-only (state.staff[].positionRequests,
-- keyed by submission date as a pseudo-id) — never synced to Supabase, so a
-- request (and its approved/denied outcome) only ever existed in whichever
-- browser logged it, and vanished on a cleared cache or a different
-- device/kiosk. Same bug class state.coverage was in before
-- 0007_coverage_sync.sql fixed it. There was also no aggregate review
-- queue the way evaluations and reassignment requests both have — a
-- pending request only surfaced by opening that one staff member's own
-- Stats tab one at a time.
--
-- Unlike reassignment_requests, submitting AND reviewing a position
-- request are both manager-only actions today (there's no staff
-- self-service login in this app) — a supervisor logs a request on a
-- staffer's behalf, and a supervisor/admin later approves or denies it.
-- No requester/reviewer asymmetry is needed in RLS the way
-- reassignment_requests has for team leads vs. managers.

create type position_request_status as enum ('pending', 'approved', 'denied');

create table position_requests (
  id           uuid primary key default gen_random_uuid(),
  staff_id     uuid not null references staff(id) on delete cascade,
  from_area_id uuid references areas(id) on delete set null,
  to_area_id   uuid not null references areas(id) on delete cascade,
  reason       text,
  status       position_request_status not null default 'pending',
  requested_by uuid references accounts(id),
  decided_by   uuid references accounts(id),
  decided_at   timestamptz,
  created_at   timestamptz not null default now()
);

create index position_requests_status_idx on position_requests(status);
create index position_requests_staff_idx  on position_requests(staff_id, created_at desc);

alter table position_requests enable row level security;

-- Same "any signed-in user can read, only a manager can write" shape as
-- positions/coverage_waivers/temp_moves/active_rotation.
create policy position_requests_select on position_requests for select
  using ((select auth.uid()) is not null);
create policy position_requests_write on position_requests for all
  using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table position_requests;

-- requestReassignment()/reviewReassignment() already insert an
-- 'reassignment_request' audit_log row that silently fails today, since
-- that value was never added to this enum in 0026 — not fixing that
-- pre-existing gap here, just not repeating it for this new feature.
alter type audit_action add value if not exists 'position_request';
