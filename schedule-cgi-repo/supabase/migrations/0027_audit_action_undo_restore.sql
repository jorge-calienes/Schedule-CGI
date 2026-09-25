-- audit_log.action's enum never included the two values the client actually
-- writes for undoing/restoring a rotation (see createRotationPeriod's
-- 'undo_rotate_period' insert and restoreBoardState's 'restore_rotation'
-- insert in lib/supabaseClient.js). Neither insert checks the audit_log
-- write's error, so every Undo-banner click and "Restore to here" click has
-- been silently failing to leave an audit trail — the actual rotation
-- period deletion / board restore still succeeds, only the log entry is
-- lost. Postgres requires ADD VALUE to run outside a transaction block.
alter type audit_action add value if not exists 'undo_rotate_period';
alter type audit_action add value if not exists 'restore_rotation';
