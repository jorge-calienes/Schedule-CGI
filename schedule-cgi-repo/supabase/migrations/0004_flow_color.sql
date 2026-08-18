-- rotation_flows.color was another UI field with no column — the flow
-- editor's color picker had nowhere to persist to, so every flow rendered
-- with whatever default the UI happened to fall back to once reloaded from
-- Supabase. Same category of gap as counter_cert/hire_date in migration 0003.

alter table rotation_flows
  add column color text not null default '#2F5FA8';
