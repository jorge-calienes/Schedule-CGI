-- Closes the remaining gap between today and the end of 2026: Veterans
-- Day (Nov 11, 2026, a Wednesday -- no weekend-observed shift needed).
-- The other federal holidays missing from 2026 (MLK Day, Washington's
-- Birthday, Juneteenth, Columbus Day) have already passed this year, so
-- adding them wouldn't affect anything going forward.
insert into company_holidays (holiday_date, label) values
  ('2026-11-11', 'Veterans Day')
on conflict (holiday_date) do nothing;
