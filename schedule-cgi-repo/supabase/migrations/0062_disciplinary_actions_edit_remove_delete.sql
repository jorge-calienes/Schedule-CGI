-- Lets a supervisor fix or walk back a disciplinary entry after the fact:
-- edit its details, pull it out of the progressive-discipline count while
-- still keeping it visible in history (removed_from_count_at), undo that,
-- or permanently delete it outright. Same chain-scoped permission model
-- as insert/select (disc_update/disc_delete mirror disc_insert exactly) --
-- a supervisor trusted to create one of these is trusted to correct or
-- remove one for their own team.
alter table disciplinary_actions add column removed_from_count_at timestamptz;
alter table disciplinary_actions add column removed_by uuid references accounts(id);

create policy disc_update on disciplinary_actions for update
  using (
    (select role from accounts where user_id = (select auth.uid())) = 'admin'
    or exists (
      select 1 from accounts a
      where a.user_id = (select auth.uid())
        and a.role = 'supervisor'
        and a.linked_supervisor_id is not null
        and staff_in_supervisor_chain(disciplinary_actions.staff_id, a.linked_supervisor_id)
    )
  )
  with check (
    (select role from accounts where user_id = (select auth.uid())) = 'admin'
    or exists (
      select 1 from accounts a
      where a.user_id = (select auth.uid())
        and a.role = 'supervisor'
        and a.linked_supervisor_id is not null
        and staff_in_supervisor_chain(disciplinary_actions.staff_id, a.linked_supervisor_id)
    )
  );

create policy disc_delete on disciplinary_actions for delete
  using (
    (select role from accounts where user_id = (select auth.uid())) = 'admin'
    or exists (
      select 1 from accounts a
      where a.user_id = (select auth.uid())
        and a.role = 'supervisor'
        and a.linked_supervisor_id is not null
        and staff_in_supervisor_chain(disciplinary_actions.staff_id, a.linked_supervisor_id)
    )
  );
