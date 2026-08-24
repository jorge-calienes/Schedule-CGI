-- Fixes the "Auth RLS Initialization Plan" performance issue flagged by
-- Supabase's own advisor (26 policies + the is_admin()/is_manager()/
-- current_account() helpers they build on). Every one of these calls
-- auth.uid() directly inside its USING/WITH CHECK expression — Postgres
-- re-evaluates a bare auth.<fn>() call for EVERY ROW a query scans,
-- instead of once per query. Wrapping it as `(select auth.uid())` turns
-- it into a cached InitPlan the planner computes once.
--
-- This was almost certainly the real cause of the "can't add accounts /
-- board goes blank" incident: loadBoard() fires ~18 parallel queries
-- across nearly every table in this file, each paying a per-row auth.uid()
-- (or a per-row call into is_admin()/is_manager(), which internally does
-- the same thing) tax. Under concurrent usage that's enough to push
-- ordinarily-instant queries past the `authenticated` role's 8s
-- statement_timeout, and Postgres logs show exactly that: a burst of
-- "canceling statement due to statement timeout" (57014) errors.
--
-- Purely a performance fix — every USING/WITH CHECK expression below is
-- logically identical to what it replaces, just cacheable.

-- ── Shared helper functions ──────────────────────────────────────────
create or replace function public.is_admin()
returns boolean
language sql
stable
as $$
  select coalesce((select role = 'admin' from accounts
                    where user_id = (select auth.uid()) and status = 'active'), false);
$$;

create or replace function public.is_manager()
returns boolean
language sql
stable
as $$
  select coalesce((select role in ('admin','supervisor') from accounts
                    where user_id = (select auth.uid()) and status = 'active'), false);
$$;

create or replace function public.current_account()
returns accounts
language sql
stable
security definer
as $$
  select * from accounts where user_id = (select auth.uid()) and status = 'active' limit 1;
$$;

-- ── The ~19 identical "any signed-in user can read this catalog/board
--    table" policies ──────────────────────────────────────────────────
alter policy ref_select                     on areas                     using ((select auth.uid()) is not null);
alter policy assign_select                  on assignments                using ((select auth.uid()) is not null);
alter policy blocked_pairs_select           on blocked_pairs              using ((select auth.uid()) is not null);
alter policy break_time_select              on break_times                using ((select auth.uid()) is not null);
alter policy callout_select                 on callouts                   using ((select auth.uid()) is not null);
alter policy coverage_select                on coverage_assignments       using ((select auth.uid()) is not null);
alter policy dept_select                    on departments                using ((select auth.uid()) is not null);
alter policy lang_select                    on languages                  using ((select auth.uid()) is not null);
alter policy lunch_time_select              on lunch_times                using ((select auth.uid()) is not null);
alter policy flow_stage_select              on rotation_flow_stages       using ((select auth.uid()) is not null);
alter policy flow_select                    on rotation_flows             using ((select auth.uid()) is not null);
alter policy period_assign_select           on rotation_period_assignments using ((select auth.uid()) is not null);
alter policy period_select                  on rotation_periods           using ((select auth.uid()) is not null);
alter policy shift_select                   on shifts                     using ((select auth.uid()) is not null);
alter policy staff_select                   on staff                      using ((select auth.uid()) is not null);
alter policy staff_lang_select              on staff_language_certs       using ((select auth.uid()) is not null);
alter policy staff_prior_experience_select  on staff_prior_experience     using ((select auth.uid()) is not null);
alter policy sup_select                     on supervisors                using ((select auth.uid()) is not null);
alter policy timeoff_select                 on time_off                   using ((select auth.uid()) is not null);

-- ── accounts ──────────────────────────────────────────────────────────
alter policy accounts_select on accounts
  using (status = 'active' or user_id = (select auth.uid()) or is_admin());

alter policy accounts_insert_self on accounts
  with check (user_id = (select auth.uid()) and status = 'pending');

-- ── audit_log ─────────────────────────────────────────────────────────
alter policy audit_insert on audit_log
  with check ((select auth.uid()) is not null);

-- ── evaluations ───────────────────────────────────────────────────────
alter policy eval_select on evaluations
  using (
    is_manager()
    or evaluator_id = (select accounts.id from accounts where accounts.user_id = (select auth.uid()))
  );

alter policy eval_insert on evaluations
  with check (
    evaluator_id = (select accounts.id from accounts where accounts.user_id = (select auth.uid()))
    and (
      (is_manager() and status = 'approved')
      or (
        not is_manager() and status = 'pending'
        and exists (
          select 1 from accounts a join assignments asg on asg.area_id = a.assigned_area_id
          where a.user_id = (select auth.uid()) and a.role = 'team_lead' and asg.staff_id = evaluations.staff_id
        )
      )
    )
  );

alter policy eval_update_own on evaluations
  using (
    evaluator_id = (select accounts.id from accounts where accounts.user_id = (select auth.uid()))
    or is_manager()
  )
  with check (
    is_manager()
    or (
      evaluator_id = (select accounts.id from accounts where accounts.user_id = (select auth.uid()))
      and status = 'pending'
    )
  );

-- ── staff (team-lead-scoped break/lunch-time-only write) ────────────────
alter policy staff_write_team_lead_break_time on staff
  using (
    exists (
      select 1 from accounts a join assignments asg on asg.area_id = a.assigned_area_id
      where a.user_id = (select auth.uid()) and a.role = 'team_lead' and asg.staff_id = staff.id
    )
  )
  with check (
    exists (
      select 1 from accounts a join assignments asg on asg.area_id = a.assigned_area_id
      where a.user_id = (select auth.uid()) and a.role = 'team_lead' and asg.staff_id = staff.id
    )
  );
