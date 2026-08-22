-- Same reasoning as 0010_enable_realtime.sql, extended to the new
-- break_times catalog table.
alter publication supabase_realtime add table break_times;
