-- Reassignment requests: a team_lead can propose covering an out person's
-- area with a specific candidate, but has no write access to assignments/
-- coverage_assignments directly (see callout_write/coverage_write below,
-- both is_manager()-gated) — a supervisor or admin has to approve it
-- first. Mirrors the evaluation review workflow
-- (0006_evaluation_review_workflow.sql): a team_lead's row lands
-- 'pending', a manager updates it to 'approved'/'denied'. Approving
-- performs the actual coverage move in the same request (see
-- reviewReassignment() in supabaseClient.js) — same "the review action
-- and the resulting write are the same request" reasoning as
-- assignCoverage() doing its coverage_assignments + assignments writes
-- together.

create type reassignment_status as enum ('pending', 'approved', 'denied');

create table reassignment_requests (
  id                 uuid primary key default gen_random_uuid(),
  candidate_staff_id uuid not null references staff(id) on delete cascade,
  out_staff_id       uuid references staff(id) on delete set null,
  area_id            uuid not null references areas(id) on delete cascade,
  requested_by       uuid not null references accounts(id),
  status             reassignment_status not null default 'pending',
  reason             text,
  review_note        text,
  decided_by         uuid references accounts(id),
  decided_at         timestamptz,
  created_at         timestamptz not null default now()
);

create index reassignment_requests_status_idx       on reassignment_requests(status);
create index reassignment_requests_requested_by_idx on reassignment_requests(requested_by, created_at desc);

alter table reassignment_requests enable row level security;

-- A requester sees their own history; managers see everything (the "Review
-- reassignments" queue and the audit trail alike).
create policy reassignment_select on reassignment_requests for select
  using (
    requested_by = (select id from accounts where user_id = (select auth.uid()))
    or is_manager()
  );

-- A team_lead can only file as themselves and it must land 'pending'; a
-- manager filing one directly (not the expected UI path, but not
-- forbidden) must self-land as 'approved', same asymmetry as eval_insert.
create policy reassignment_insert on reassignment_requests for insert
  with check (
    requested_by = (select id from accounts where user_id = (select auth.uid()))
    and (
      (is_manager() and status = 'approved')
      or (not is_manager() and status = 'pending')
    )
  );

-- Only a manager can decide a pending request — the requester can't
-- self-approve by re-saving their own row.
create policy reassignment_update on reassignment_requests for update
  using (is_manager())
  with check (is_manager());

alter publication supabase_realtime add table reassignment_requests;
