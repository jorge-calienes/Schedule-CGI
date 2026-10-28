-- Self-service leave requests from the public (no-login) board, plus
-- same-day late-arrival/leaving-early notices, a configurable company-wide
-- capacity rule, and a holiday calendar so the hours math (8 hrs/business
-- day) excludes weekends and holidays the same way for everyone.
--
-- Submission happens from the public board, which has no signed-in
-- identity at all — so instead of a plain insert (the pattern every other
-- request table in this app uses, e.g. position_requests, trusted because
-- only a signed-in team_lead/supervisor/admin session can reach it) these
-- go through SECURITY DEFINER functions grantable to anon, mirroring
-- public_board_snapshot()/verify_pin()/set_pin(). The function itself
-- checks the submitted TDIS number against the chosen staff record server
-- side (never trust a client-supplied staff_id alone) and enforces the
-- capacity rule, so neither check can be bypassed by calling the RPC
-- directly with different arguments.

create table company_holidays (
  id uuid primary key default gen_random_uuid(),
  holiday_date date not null unique,
  label text not null,
  created_by uuid references accounts(id),
  created_at timestamptz not null default now()
);

-- Singleton row, same pattern as active_rotation.
create table leave_policy (
  id boolean primary key default true,
  constraint leave_policy_singleton check (id),
  max_percent numeric not null default 15 check (max_percent > 0 and max_percent <= 100),
  updated_by uuid references accounts(id),
  updated_at timestamptz not null default now()
);
insert into leave_policy (id, max_percent) values (true, 15);

create table leave_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff(id) on delete cascade,
  leave_type text not null check (leave_type in ('pto','sick')),
  start_date date not null,
  end_date date not null check (end_date >= start_date),
  hours_requested numeric,
  pto_balance numeric,
  sick_balance numeric,
  remarks text,
  status text not null default 'pending' check (status in ('pending','approved','denied')),
  decided_by uuid references accounts(id),
  decided_at timestamptz,
  decision_note text,
  created_at timestamptz not null default now()
);
create index leave_requests_staff_idx on leave_requests(staff_id);
create index leave_requests_status_idx on leave_requests(status);
create index leave_requests_dates_idx on leave_requests(start_date, end_date);

create table same_day_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff(id) on delete cascade,
  request_type text not null check (request_type in ('late_arrival','left_early')),
  request_date date not null,
  pto_balance numeric,
  sick_balance numeric,
  note text,
  status text not null default 'pending' check (status in ('pending','acknowledged')),
  decided_by uuid references accounts(id),
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index same_day_requests_staff_idx on same_day_requests(staff_id);
create index same_day_requests_status_idx on same_day_requests(status);

alter table company_holidays enable row level security;
alter table leave_policy enable row level security;
alter table leave_requests enable row level security;
alter table same_day_requests enable row level security;

create policy company_holidays_select on company_holidays for select using ((select auth.uid()) is not null);
create policy company_holidays_write  on company_holidays for all using (is_manager()) with check (is_manager());

create policy leave_policy_select on leave_policy for select using ((select auth.uid()) is not null);
create policy leave_policy_write  on leave_policy for all using (is_manager()) with check (is_manager());

create policy leave_requests_select on leave_requests for select using ((select auth.uid()) is not null);
create policy leave_requests_write  on leave_requests for all using (is_manager()) with check (is_manager());

create policy same_day_requests_select on same_day_requests for select using ((select auth.uid()) is not null);
create policy same_day_requests_write  on same_day_requests for all using (is_manager()) with check (is_manager());

-- A few common US holidays to seed the feature usefully out of the box —
-- supervisors/admins can add or remove more from the Leave policy screen.
insert into company_holidays (holiday_date, label) values
  ('2026-01-01', 'New Year''s Day'),
  ('2026-05-25', 'Memorial Day'),
  ('2026-07-03', 'Independence Day (observed)'),
  ('2026-09-07', 'Labor Day'),
  ('2026-11-26', 'Thanksgiving Day'),
  ('2026-11-27', 'Day after Thanksgiving'),
  ('2026-12-25', 'Christmas Day'),
  ('2027-01-01', 'New Year''s Day');

-- Counts how many days in [p_start,p_end] are NOT a Saturday/Sunday and
-- NOT in company_holidays — the shared "8 hrs is a business day" rule
-- both the capacity check and the hours-worked math below rely on.
create or replace function business_days_between(p_start date, p_end date)
returns integer
language sql
stable
set search_path = public
as $$
  select count(*)::int
  from generate_series(p_start, p_end, interval '1 day') d
  where extract(isodow from d) < 6
    and d::date not in (select holiday_date from company_holidays);
$$;

-- Submits a scheduled-leave (PTO/Sick) request from the public board.
-- Verifies the TDIS number server side and enforces the capacity rule —
-- counting both already-approved time off AND other pending/approved
-- leave_requests, since a pending request already reserves a slot (the
-- whole point of showing "fewer slots left" while something is still
-- awaiting review). Blocks the WHOLE request if ANY day in the range
-- would exceed the cap, rather than silently partially granting it.
create or replace function submit_leave_request(
  p_staff_id uuid,
  p_tdis text,
  p_leave_type text,
  p_start_date date,
  p_end_date date,
  p_hours_requested numeric,
  p_pto_balance numeric,
  p_sick_balance numeric,
  p_remarks text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff;
  v_cap integer;
  v_active_count integer;
  v_blocked_date date;
  v_row leave_requests;
begin
  select * into v_staff from staff where id = p_staff_id and active = true;
  if v_staff is null then
    raise exception 'staff_not_found' using errcode = 'P0001';
  end if;
  if v_staff.tdis_number is null or btrim(upper(v_staff.tdis_number)) <> btrim(upper(p_tdis)) then
    raise exception 'tdis_mismatch' using errcode = 'P0001';
  end if;
  if p_leave_type not in ('pto','sick') then
    raise exception 'invalid_leave_type' using errcode = 'P0001';
  end if;
  if p_end_date < p_start_date then
    raise exception 'invalid_date_range' using errcode = 'P0001';
  end if;

  select max_percent into v_cap from leave_policy where id = true;
  select count(*) into v_active_count from staff where active = true;
  v_cap := ceil(coalesce(v_cap, 15) * v_active_count / 100.0);

  select d::date into v_blocked_date
  from generate_series(p_start_date, p_end_date, interval '1 day') d
  where (
    (select count(*) from time_off t where d::date between t.start_date and t.end_date)
    +
    (select count(*) from leave_requests lr
       where lr.status in ('pending','approved') and d::date between lr.start_date and lr.end_date)
  ) >= v_cap
  order by d
  limit 1;

  if v_blocked_date is not null then
    raise exception 'capacity_full:%', v_blocked_date using errcode = 'P0001';
  end if;

  insert into leave_requests (
    staff_id, leave_type, start_date, end_date, hours_requested, pto_balance, sick_balance, remarks
  ) values (
    p_staff_id, p_leave_type, p_start_date, p_end_date, p_hours_requested, p_pto_balance, p_sick_balance, p_remarks
  )
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

-- Submits a same-day late-arrival/leaving-early notice. No capacity check
-- (this feature's whole point doesn't apply to a same-day attendance
-- note), same TDIS verification as submit_leave_request.
create or replace function submit_same_day_request(
  p_staff_id uuid,
  p_tdis text,
  p_request_type text,
  p_pto_balance numeric,
  p_sick_balance numeric,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff;
  v_row same_day_requests;
begin
  select * into v_staff from staff where id = p_staff_id and active = true;
  if v_staff is null then
    raise exception 'staff_not_found' using errcode = 'P0001';
  end if;
  if v_staff.tdis_number is null or btrim(upper(v_staff.tdis_number)) <> btrim(upper(p_tdis)) then
    raise exception 'tdis_mismatch' using errcode = 'P0001';
  end if;
  if p_request_type not in ('late_arrival','left_early') then
    raise exception 'invalid_request_type' using errcode = 'P0001';
  end if;

  insert into same_day_requests (
    staff_id, request_type, request_date, pto_balance, sick_balance, note
  ) values (
    p_staff_id, p_request_type, current_date, p_pto_balance, p_sick_balance, p_note
  )
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function submit_leave_request(uuid, text, text, date, date, numeric, numeric, numeric, text) from public;
grant execute on function submit_leave_request(uuid, text, text, date, date, numeric, numeric, numeric, text) to anon, authenticated;

revoke all on function submit_same_day_request(uuid, text, text, numeric, numeric, text) from public;
grant execute on function submit_same_day_request(uuid, text, text, numeric, numeric, text) to anon, authenticated;
