-- proficiency_ratings_select (0030_proficiency_ratings.sql) let ANY
-- signed-in account read every staff member's ratings across every
-- department ("any signed-in user can read, only a manager can write") —
-- team leads never write this table (ratings are entered by a supervisor
-- during Rotate Now's confirm step or the flow-advancement feedback
-- modal), so there was no workflow reason for them to read it either.
--
-- In practice this let a team lead see any other team's proficiency
-- scores three different ways: tapping any staff chip's name (any
-- department, not just their own), the roster's "Stats" tab, and the
-- Print/Export report, which lists every active staff member's average
-- proficiency and top-area ratings regardless of department. None of
-- those code paths filter by staff/area themselves — they all just
-- display whatever the server hands back — so narrowing this one policy
-- closes all three at once, the same way the loading-screen nav item for
-- the report should have been gated like its admin/supervisor siblings
-- but wasn't (fixed alongside this in index.html).
--
-- The UI already renders "Not yet rated"/no badge when a rating is
-- missing (that's the normal state for any not-yet-rated staff/area
-- pair), so a team lead simply seeing nothing here is not a broken
-- experience — it's indistinguishable from "no one has rated this
-- person yet."

alter policy proficiency_ratings_select on proficiency_ratings
  using (is_manager());
