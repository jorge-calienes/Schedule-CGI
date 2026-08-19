-- Evaluation review workflow: a team_lead's evaluation is not the final
-- word — it needs a supervisor (or admin) to accept it. Evaluations
-- submitted directly by a manager (admin/supervisor) are their own final
-- call and don't need anyone else's sign-off, so they land as 'approved'
-- immediately; a team_lead's submission lands as 'pending' and only counts
-- toward the staff performance profile / team dashboard once approved.
-- 'needs_revision' is the supervisor sending it back with a note — the
-- team lead edits and resubmits, which returns it to 'pending'.

create type eval_status as enum ('pending', 'approved', 'needs_revision');

alter table evaluations
  add column status       eval_status not null default 'pending',
  add column review_note  text,
  add column reviewed_by  uuid references accounts(id),
  add column reviewed_at  timestamptz;

-- Evaluations that already existed before this migration predate the
-- review workflow entirely — grandfather them in as already-final rather
-- than surfacing years of history as "pending".
update evaluations set status = 'approved';

-- Insert: a manager's own evaluation must self-land as 'approved' (no one
-- reviews a manager); a team_lead's must land as 'pending' — enforced here
-- rather than trusted from the client, same as the existing area-scoping
-- check below it.
drop policy if exists eval_insert on evaluations;
create policy eval_insert on evaluations for insert
  with check (
    evaluator_id = (select id from accounts where user_id = auth.uid())
    and (
      (is_manager() and status = 'approved')
      or (
        not is_manager()
        and status = 'pending'
        and exists (
          select 1 from accounts a
          join assignments asg on asg.area_id = a.assigned_area_id
          where a.user_id = auth.uid()
            and a.role = 'team_lead'
            and asg.staff_id = evaluations.staff_id
        )
      )
    )
  );

-- Update: a manager can do anything to any row (including the actual
-- approve/send-back review action). The original evaluator editing their
-- own row (a team_lead revising after 'needs_revision') can only ever
-- land back at 'pending' — they can't self-approve by re-saving.
drop policy if exists eval_update_own on evaluations;
create policy eval_update_own on evaluations for update
  using (evaluator_id = (select id from accounts where user_id = auth.uid()) or is_manager())
  with check (
    is_manager()
    or (evaluator_id = (select id from accounts where user_id = auth.uid()) and status = 'pending')
  );

-- "My evaluation queue" now also surfaces the existing evaluation's status,
-- the supervisor's review note (if sent back), and the scores/note/
-- recommendation already on file, so the eval form can pre-fill instead of
-- forcing a from-scratch resubmission.
create or replace view my_evaluation_queue as
select
  s.id as staff_id,
  s.name,
  s.tdis_number,
  a.area_id,
  ar.name as area_name,
  rp.id as current_period_id,
  rp.period_label,
  ev.id as existing_evaluation_id,
  ev.status as existing_evaluation_status,
  ev.review_note as existing_evaluation_review_note,
  ev.productivity as existing_productivity,
  ev.performance as existing_performance,
  ev.reliability as existing_reliability,
  ev.recommendation as existing_recommendation,
  ev.note as existing_note
from staff s
join assignments a on a.staff_id = s.id
join areas ar on ar.id = a.area_id
left join lateral (
  select * from rotation_periods order by created_at desc limit 1
) rp on true
left join lateral (
  select * from evaluations e
  where e.staff_id = s.id
    and e.evaluator_id = (select id from accounts where user_id = auth.uid())
    and e.period_id is not distinct from rp.id
  limit 1
) ev on true
where a.area_id = (
  select assigned_area_id from accounts where user_id = auth.uid() and role = 'team_lead'
)
and s.active = true;

comment on view my_evaluation_queue is
  'For the frontend: select * from my_evaluation_queue while signed in as a team lead.';
