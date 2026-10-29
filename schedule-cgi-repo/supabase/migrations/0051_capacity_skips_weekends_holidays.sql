-- The capacity rule was checking every calendar day in a request's range,
-- including weekends and company holidays -- days nobody is scheduled to
-- work at all. That meant a request could get blocked over a Saturday or
-- Sunday "filling up", even though nobody can be scheduled off a day they
-- never work in the first place -- there's no real capacity concept on a
-- closed day. business_days_between() already treats weekends/holidays as
-- not counting for the hours math; the capacity check now uses the same
-- definition so blocking is consistent with what the form already tells
-- people ("weekends & holidays don't count").
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
  where extract(isodow from d) < 6
    and d::date not in (select holiday_date from company_holidays)
    and (
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
