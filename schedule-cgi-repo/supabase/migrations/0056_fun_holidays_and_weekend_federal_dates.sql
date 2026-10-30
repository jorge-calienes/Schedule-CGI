-- Two additions to company_holidays, both purely for the "Who's off"
-- calendar's icon display (pbHolidayEmoji in index.html) -- neither
-- changes capacity/leave-policy behavior, since weekend dates are already
-- excluded from blocked-date checks (see 0051) regardless of whether
-- they're also tagged as a holiday here.
--
-- 1) Fun/observance days that already have a matching emoji in
--    pbHolidayEmoji() but were never seeded: Halloween 🎃, Valentine's
--    Day 💘, Easter 🐣. Only future-dated ones are added (today is
--    2026-10-30), same "from today forward" convention used for the
--    federal holiday sets in #176/#177/#180. Easter computed via the
--    standard Gregorian algorithm, not by hand.
--
-- 2) For federal holidays that land on a weekend, only their *observed*
--    weekday was seeded (0052/0053/0055) -- the real calendar date itself
--    was never recorded, so a weekend cell on the actual holiday showed
--    as a plain closed weekend instead of its icon. This adds the actual
--    date too, labeled without "(observed)" since that suffix already
--    belongs to the shifted weekday entry.
insert into company_holidays (holiday_date, label) values
  -- fun/observance days
  ('2026-10-31', 'Halloween'),
  ('2027-02-14', 'Valentine''s Day'),
  ('2027-03-28', 'Easter'),
  ('2027-10-31', 'Halloween'),
  ('2028-02-14', 'Valentine''s Day'),
  ('2028-04-16', 'Easter'),
  ('2028-10-31', 'Halloween'),
  -- actual (weekend) dates for federal holidays already seeded by their observed weekday
  ('2026-07-04', 'Independence Day'),
  ('2027-06-19', 'Juneteenth National Independence Day'),
  ('2027-07-04', 'Independence Day'),
  ('2027-12-25', 'Christmas Day'),
  ('2028-01-01', 'New Year''s Day'),
  ('2028-11-11', 'Veterans Day')
on conflict (holiday_date) do nothing;
