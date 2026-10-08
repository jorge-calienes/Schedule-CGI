-- 0034 missed one tolerance the uploaded prototype also exposed: how far
-- over the expected break/lunch length, combined with the day actually
-- running short, before it's worth flagging (its "Break / lunch over by
-- (min) AND day short, to flag" setting). index.html had it hardcoded to
-- 5 right next to the now-editable ones — folding it into the same
-- settings row instead of leaving one tolerance un-tunable beside the rest.
alter table time_review_settings add column tol integer not null default 5;
