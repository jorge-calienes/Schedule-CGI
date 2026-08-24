-- Team leads were locked to exactly one assigned_area_id, but some team
-- leads actually cover more than one area. Replace the single FK column
-- with an array so an account can be designated over several areas at
-- once; every place that read assigned_area_id (RLS policies, the "my
-- evaluation queue" view, the client) moves to an "is this area one of
-- mine" (= any(...)) check instead of straight equality.

alter table accounts add column assigned_area_ids uuid[] not null default '{}';

update accounts
  set assigned_area_ids = array[assigned_area_id]
  where assigned_area_id is not null;

-- ── evaluations: team lead may submit for staff currently in ANY of
--    their designated areas, not just a single one. Rewritten against
--    the NEW column first, since the old column can't be dropped while
--    this policy still references it. ──
alter policy eval_insert on evaluations
  with check (
    evaluator_id = (select accounts.id from accounts where accounts.user_id = (select auth.uid()))
    and (
      (is_manager() and status = 'approved')
      or (
        not is_manager() and status = 'pending'
        and exists (
          select 1 from accounts a join assignments asg on asg.area_id = any(a.assigned_area_ids)
          where a.user_id = (select auth.uid()) and a.role = 'team_lead' and asg.staff_id = evaluations.staff_id
        )
      )
    )
  );

-- ── staff (team-lead-scoped break/lunch-time-only write): same "any of
--    my areas" scoping ──
alter policy staff_write_team_lead_break_time on staff
  using (
    exists (
      select 1 from accounts a join assignments asg on asg.area_id = any(a.assigned_area_ids)
      where a.user_id = (select auth.uid()) and a.role = 'team_lead' and asg.staff_id = staff.id
    )
  )
  with check (
    exists (
      select 1 from accounts a join assignments asg on asg.area_id = any(a.assigned_area_ids)
      where a.user_id = (select auth.uid()) and a.role = 'team_lead' and asg.staff_id = staff.id
    )
  );

-- ── "my evaluation queue" now pools staff across every one of the
--    signed-in team lead's designated areas ──
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
and s.active = true;

comment on view my_evaluation_queue is
  'For the frontend: select * from my_evaluation_queue while signed in as a team lead.';

-- Now safe to drop the old single-area column.
alter table accounts drop constraint if exists accounts_assigned_area_fk;
alter table accounts drop column if exists assigned_area_id;

alter table accounts add constraint accounts_team_lead_needs_area
  check (role <> 'team_lead' or array_length(assigned_area_ids, 1) > 0);
