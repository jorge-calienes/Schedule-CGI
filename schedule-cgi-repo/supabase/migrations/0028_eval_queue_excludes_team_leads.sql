-- "My evaluations" was pulling in every staff member assigned to one of a
-- team lead's designated areas, including OTHER team leads who happen to
-- be placed there — evaluations are meant for the team members a team
-- lead oversees, not their peers. Exclude staff.is_team_lead = true from
-- both the queue view the frontend reads and the RLS policy that actually
-- gates the insert, so a team lead can't submit one for a fellow team
-- lead even via a direct request that bypasses the queue's own list.

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
    and e.evaluator_id = (select id from accounts where user_id = (select auth.uid()))
    and e.period_id is not distinct from rp.id
  limit 1
) ev on true
where a.area_id = any((
  select unnest(assigned_area_ids) from accounts where user_id = (select auth.uid()) and role = 'team_lead'
))
and s.active = true
and s.is_team_lead = false;

comment on view my_evaluation_queue is
  'For the frontend: select * from my_evaluation_queue while signed in as a team lead. Excludes other team leads — this is the team-lead-evaluates-team-members queue, not peer review.';

alter policy eval_insert on evaluations
  with check (
    evaluator_id = (select accounts.id from accounts where accounts.user_id = (select auth.uid()))
    and (
      (is_manager() and status = 'approved')
      or (
        not is_manager() and status = 'pending'
        and exists (
          select 1 from accounts a
          join assignments asg on asg.area_id = any(a.assigned_area_ids)
          join staff st on st.id = asg.staff_id
          where a.user_id = (select auth.uid()) and a.role = 'team_lead'
            and asg.staff_id = evaluations.staff_id
            and st.is_team_lead = false
        )
      )
    )
  );
