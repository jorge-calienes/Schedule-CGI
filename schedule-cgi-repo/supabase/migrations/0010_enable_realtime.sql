-- Every write in this app only ever updated the acting user's own
-- browser state — a second device or a different manager's tab had no
-- idea anything changed until they reloaded the page. Enabling Postgres
-- Changes (Supabase Realtime) on every table loadBoard() reads lets the
-- client subscribe and patch its local state live instead. RLS already
-- gates these correctly (every one of these tables' select policy is
-- "any signed-in user"), so realtime respects the same read access a
-- normal query would.

alter publication supabase_realtime add table
  areas, staff, assignments, departments, callouts, supervisors, shifts, languages,
  staff_language_certs, rotation_flows, rotation_flow_stages, time_off, blocked_pairs,
  coverage_assignments, lunch_times;
