-- The uploaded prototype's "confirm this day" flow asked two things this
-- screen never captured: how the supervisor actually verified an
-- incomplete/missing punch with the employee (email, chat, text, in
-- person, phone — or "accepted as is" when nothing really needed
-- checking), and an optional note on what was said. Recording "a
-- supervisor clicked accept" without recording how they confirmed it
-- defeats the point for anything that might later need to hold up as
-- documentation.
alter table time_review_decisions add column verify_how text not null default '';
alter table time_review_decisions add column verify_note text not null default '';
