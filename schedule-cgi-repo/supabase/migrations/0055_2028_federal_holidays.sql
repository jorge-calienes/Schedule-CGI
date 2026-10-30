-- Seeds the full 2028 US federal holiday set, same style/convention as
-- 0052/0053 (2027): dates that fall on a weekend are seeded on their
-- observed weekday -- standard OPM practice, Saturday shifts back to the
-- preceding Friday, Sunday shifts forward to the following Monday.
--   New Year's Day 2028 falls Sat Jan 1  -> observed Fri Dec 31, 2027
--     (the observance lands in the prior calendar year -- this is normal;
--     it's the same rule that already applies when New Year's Day itself
--     falls on a Saturday, just visible here because 2028 starts on one)
--   Veterans Day 2028  falls Sat Nov 11  -> observed Fri Nov 10
-- No DB changes needed for the calendar's holiday icons -- pbHolidayEmoji()
-- in index.html (from #173) already keyword-matches any label, so these
-- get 🕊️/🎩/🎖️/etc. automatically, the same as every other seeded holiday.
insert into company_holidays (holiday_date, label) values
  ('2027-12-31', 'New Year''s Day (observed)'),
  ('2028-01-17', 'Martin Luther King Jr. Day'),
  ('2028-02-21', 'Washington''s Birthday'),
  ('2028-05-29', 'Memorial Day'),
  ('2028-06-19', 'Juneteenth National Independence Day'),
  ('2028-07-04', 'Independence Day'),
  ('2028-09-04', 'Labor Day'),
  ('2028-10-09', 'Columbus Day'),
  ('2028-11-10', 'Veterans Day (observed)'),
  ('2028-11-23', 'Thanksgiving Day'),
  ('2028-12-25', 'Christmas Day')
on conflict (holiday_date) do nothing;
