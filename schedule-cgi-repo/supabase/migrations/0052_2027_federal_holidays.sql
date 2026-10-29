-- Adds the rest of the 2027 US federal holidays (New Year's Day 2027 was
-- already seeded in 0048). Dates that fall on a weekend are seeded on
-- their observed weekday, the same convention 0048 already used for
-- Independence Day 2026 (July 4, a Saturday, seeded as the observed
-- Friday July 3) -- standard OPM practice: Saturday shifts back to
-- Friday, Sunday shifts forward to Monday.
--   Juneteenth 2027    falls Sat Jun 19 -> observed Fri Jun 18
--   Independence Day 2027 falls Sun Jul 4 -> observed Mon Jul 5
--   Christmas Day 2027 falls Sat Dec 25 -> observed Fri Dec 24
-- "Day after Thanksgiving" is left out here -- it's a common company
-- closure day, not one of the 11 official federal holidays, which is
-- what was asked for.
insert into company_holidays (holiday_date, label) values
  ('2027-01-18', 'Martin Luther King Jr. Day'),
  ('2027-02-15', 'Washington''s Birthday'),
  ('2027-05-31', 'Memorial Day'),
  ('2027-06-18', 'Juneteenth National Independence Day (observed)'),
  ('2027-07-05', 'Independence Day (observed)'),
  ('2027-09-06', 'Labor Day'),
  ('2027-10-11', 'Columbus Day'),
  ('2027-11-11', 'Veterans Day'),
  ('2027-11-25', 'Thanksgiving Day'),
  ('2027-12-24', 'Christmas Day (observed)')
on conflict (holiday_date) do nothing;
