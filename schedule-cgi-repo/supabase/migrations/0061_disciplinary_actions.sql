-- Disciplinary tracker. Deliberately narrower than Evaluations (any
-- team_lead can submit one of those, any admin/supervisor can see every
-- one of them) -- this content is more sensitive, so only an admin or a
-- supervisor can create an entry, and only that staff member's own
-- supervisor chain (their direct supervisor, or anyone above it via
-- supervisors.reports_to_id) plus admins can ever see or write one.
-- Acknowledgment is captured in the same sitting the entry is created
-- (on the supervisor's own device), so a row is only ever inserted once
-- fully resolved -- there is no public/TDIS-based lookup or async
-- self-service path for this table at all, and no update/delete policy
-- since nothing today needs to revise an issued entry.
create table disciplinary_actions (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff(id),
  created_by uuid not null references accounts(id),
  witness_supervisor_id uuid references supervisors(id),
  step text not null check (step in ('verbal', 'written', 'final_written', 'termination')),
  category text not null check (category in ('attendance', 'conduct', 'policy_violation', 'safety', 'other')),
  incident_date date not null,
  description text not null,
  corrective_action text not null,
  -- 'unacknowledged' covers "left blank for now" -- the employee neither
  -- acknowledged nor actively declined; distinct from 'declined' so the
  -- two don't get conflated in the history view.
  ack_status text not null check (ack_status in ('acknowledged', 'declined', 'unacknowledged')),
  acknowledged_at timestamptz,
  created_at timestamptz not null default now()
);

create index disciplinary_actions_staff_id_idx on disciplinary_actions(staff_id);

alter table disciplinary_actions enable row level security;

-- Walks up a staff member's supervisor chain (their direct supervisor,
-- then supervisors.reports_to_id repeatedly) and says whether
-- p_supervisor_id is anywhere in it -- the "own chain" visibility rule
-- both policies below share.
create or replace function staff_in_supervisor_chain(p_staff_id uuid, p_supervisor_id uuid)
returns boolean
language sql
stable
set search_path = public
as $$
  with recursive chain as (
    select s.supervisor_id as sup_id from staff s where s.id = p_staff_id
    union all
    select sv.reports_to_id from supervisors sv join chain c on sv.id = c.sup_id where sv.reports_to_id is not null
  )
  select exists (select 1 from chain where sup_id = p_supervisor_id);
$$;

create policy disc_select on disciplinary_actions for select
  using (
    (select role from accounts where user_id = (select auth.uid())) = 'admin'
    or exists (
      select 1 from accounts a
      where a.user_id = (select auth.uid())
        and a.role = 'supervisor'
        and a.linked_supervisor_id is not null
        and staff_in_supervisor_chain(disciplinary_actions.staff_id, a.linked_supervisor_id)
    )
  );

create policy disc_insert on disciplinary_actions for insert
  with check (
    created_by = (select id from accounts where user_id = (select auth.uid()))
    and (
      (select role from accounts where user_id = (select auth.uid())) = 'admin'
      or exists (
        select 1 from accounts a
        where a.user_id = (select auth.uid())
          and a.role = 'supervisor'
          and a.linked_supervisor_id is not null
          and staff_in_supervisor_chain(disciplinary_actions.staff_id, a.linked_supervisor_id)
      )
    )
  );
