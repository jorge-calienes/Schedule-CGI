// Frontend Supabase client. Uses the PUBLIC anon key only — safe to include
// in browser code. All row access is governed by the RLS policies in
// 0001_init.sql, not by anything in this file.
//
// Add to your HTML (or bundle if you move off a single-file app):
//   <script type="module" src="/lib/supabaseClient.js"></script>
//
// Env vars (Vercel → Project Settings → Environment Variables, exposed to
// the client because they're prefixed appropriately for your build tool —
// if you're staying on a plain static HTML file with no build step, bake
// these two values directly into this file at deploy time instead, since
// there's no bundler to inject them):
//   NEXT_PUBLIC_SUPABASE_URL / VITE_SUPABASE_URL / etc.
//   NEXT_PUBLIC_SUPABASE_ANON_KEY / VITE_SUPABASE_ANON_KEY / etc.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = 'https://glnbvbgvgijmpeyagnge.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_EfRzoLu4cNiCodR85M_o9g_6syxQeu8';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

export async function signInWithPin(name, pin) {
  const res = await fetch('/api/auth/pin-login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, pin }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || 'Sign-in failed');

  // Hand the minted session to the Supabase client so subsequent calls
  // (and RLS's auth.uid()) are authenticated as this account.
  const { error } = await supabase.auth.setSession({
    access_token: body.session.access_token,
    refresh_token: body.session.refresh_token,
  });
  if (error) throw error;

  return body.account; // { id, name, role, assigned_area_id }
}

export async function requestAccess(name) {
  const res = await fetch('/api/accounts/request', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name }),
  });
  return res.json();
}

export async function signOut() {
  await supabase.auth.signOut();
}

// Restores "who's signed in" across page reloads: supabase-js persists the
// session itself (localStorage, under its own key), so this just resolves
// that session back to an `accounts` row.
export async function getCurrentAccount() {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) return null;

  const { data, error } = await supabase
    .from('accounts')
    .select('id, name, role, assigned_area_id')
    .eq('user_id', session.user.id)
    .single();
  if (error || !data) return null;
  return data;
}

// ---------------------------------------------------------------------------
// Example queries — mirrors of the localStorage-era functions in the app.
// Swap these in one at a time rather than all at once; see SETUP_GUIDE.md
// "Migration order" for the recommended sequence.
// ---------------------------------------------------------------------------

export async function loadBoard() {
  const [{ data: areas }, { data: staff }, { data: assignments }, { data: departments }] = await Promise.all([
    supabase.from('areas').select('*').order('sort_order'),
    supabase.from('staff').select('*').eq('active', true),
    supabase.from('assignments').select('*'),
    supabase.from('departments').select('*').order('sort_order'),
  ]);
  return { areas, staff, assignments, departments };
}

export async function moveStaff({ staffId, areaId, actingAccountId, staffName, fromAreaName, toAreaName }) {
  const { error } = await supabase
    .from('assignments')
    .upsert({ staff_id: staffId, area_id: areaId, updated_by: actingAccountId, updated_at: new Date().toISOString() });
  if (error) throw error;

  const who = staffName || staffId;
  const description = toAreaName
    ? (fromAreaName ? `moved ${who} from ${fromAreaName} to ${toAreaName}` : `moved ${who} to ${toAreaName}`)
    : `unassigned ${who}`;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'move',
    description,
    staff_id: staffId,
    metadata: { areaId, fromAreaName, toAreaName },
  });
}

export async function swapStaff({ idA, idB, areaA, areaB, actingAccountId, nameA, nameB }) {
  const now = new Date().toISOString();
  const { error } = await supabase.from('assignments').upsert([
    { staff_id: idA, area_id: areaB, updated_by: actingAccountId, updated_at: now },
    { staff_id: idB, area_id: areaA, updated_by: actingAccountId, updated_at: now },
  ]);
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'swap',
    description: `swapped ${nameA || idA} ↔ ${nameB || idB}`,
    staff_id: idA,
    metadata: { idA, idB, areaA, areaB },
  });
}

export async function setCallout({ staffId, actingAccountId, staffName, reason }) {
  const { error } = await supabase.from('callouts').upsert({
    staff_id: staffId,
    reason: reason || null,
    marked_by: actingAccountId,
    marked_at: new Date().toISOString(),
  });
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'callout',
    description: `marked ${staffName || staffId} as out${reason ? ' — ' + reason : ''}`,
    staff_id: staffId,
  });
}

export async function clearCallout({ staffId, actingAccountId, staffName }) {
  const { error } = await supabase.from('callouts').delete().eq('staff_id', staffId);
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'clear_callout',
    description: `marked ${staffName || staffId} back in`,
    staff_id: staffId,
  });
}

// ---------------------------------------------------------------------------
// Staff / area CRUD (Step 3b). Department is stored as a free-text field in
// the app's UI but is a real FK in the schema — resolve-or-create it by name
// so typing a new department name in the staff/area editor still works.
// ---------------------------------------------------------------------------

export async function ensureDepartment(name) {
  if (!name) return null;
  const { data: existing } = await supabase.from('departments').select('id, name').ilike('name', name).maybeSingle();
  if (existing) return existing.id;

  const { data, error } = await supabase.from('departments').insert({ name }).select().single();
  if (error) throw error;
  return data.id;
}

function staffRow({ name, tdisNumber, departmentId, homeAreaId, isTeamLead, isSubcontractor, needsAccommodations, tags, shiftHoursLabel, breakTimesLabel }) {
  return {
    name,
    tdis_number: tdisNumber || null,
    department_id: departmentId || null,
    home_area_id: homeAreaId || null,
    is_team_lead: !!isTeamLead,
    is_subcontractor: !!isSubcontractor,
    needs_accommodations: !!needsAccommodations,
    tags: tags || null,
    shift_hours_label: shiftHoursLabel || null,
    break_times_label: breakTimesLabel || null,
  };
}

export async function createStaff(fields) {
  const { data, error } = await supabase.from('staff').insert(staffRow(fields)).select().single();
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: fields.actingAccountId,
    action: 'add_staff',
    description: `added ${fields.name}`,
    staff_id: data.id,
  });
  return data; // includes the Supabase-generated id
}

export async function updateStaff(fields) {
  const { error } = await supabase.from('staff').update(staffRow(fields)).eq('id', fields.staffId);
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: fields.actingAccountId,
    action: 'edit_staff',
    description: `updated ${fields.name}'s profile`,
    staff_id: fields.staffId,
  });
}

export async function archiveStaff({ staffId, staffName, actingAccountId }) {
  const { error } = await supabase.from('staff').update({ active: false }).eq('id', staffId);
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'archive_staff',
    description: `removed ${staffName || staffId}`,
    staff_id: staffId,
  });
}

function areaRow({ name, color, capacity, departmentId }) {
  return {
    name,
    color: color || '#2F5FA8',
    capacity: capacity || 4,
    department_id: departmentId || null,
  };
}

export async function createArea(fields) {
  const { data, error } = await supabase.from('areas').insert(areaRow(fields)).select().single();
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: fields.actingAccountId,
    action: 'add_area',
    description: `added work area "${fields.name}"`,
  });
  return data; // includes the Supabase-generated id
}

export async function updateArea(fields) {
  const { error } = await supabase.from('areas').update(areaRow(fields)).eq('id', fields.areaId);
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: fields.actingAccountId,
    action: 'edit_area',
    description: `updated "${fields.name}"`,
  });
}

export async function deleteArea({ areaId, areaName, actingAccountId }) {
  const { error } = await supabase.from('areas').delete().eq('id', areaId);
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'edit_area',
    description: `deleted work area "${areaName || areaId}"`,
  });
}

export async function submitEvaluation({ staffId, periodId, areaId, evaluatorId, productivity, performance, reliability, note, recommendation }) {
  const { error } = await supabase.from('evaluations').upsert({
    staff_id: staffId,
    period_id: periodId,
    area_id: areaId,
    evaluator_id: evaluatorId,
    productivity, performance, reliability, note, recommendation,
  }, { onConflict: 'staff_id,evaluator_id,period_id' });
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: evaluatorId,
    action: 'evaluation',
    description: `submitted an evaluation — recommended "${recommendation}"`,
    staff_id: staffId,
    metadata: { productivity, performance, reliability, recommendation },
  });
}

export async function myEvaluationQueue() {
  const { data, error } = await supabase.from('my_evaluation_queue').select('*');
  if (error) throw error;
  return data;
}

export async function fetchAuditLog({ limit = 50 } = {}) {
  const { data, error } = await supabase
    .from('audit_log')
    .select('*, accounts:actor_id(name)')
    .order('created_at', { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data;
}

// ---------------------------------------------------------------------------
// index.html is a classic (non-module) script, so it can't `import` this
// file directly. Bridge everything through window.RC instead, and fire
// 'rc:ready' once it's populated so the classic script knows it's safe to
// call in.
// ---------------------------------------------------------------------------
window.RC = {
  supabase,
  signInWithPin,
  requestAccess,
  signOut,
  getCurrentAccount,
  loadBoard,
  moveStaff,
  swapStaff,
  setCallout,
  clearCallout,
  ensureDepartment,
  createStaff,
  updateStaff,
  archiveStaff,
  createArea,
  updateArea,
  deleteArea,
  submitEvaluation,
  myEvaluationQueue,
  fetchAuditLog,
};
window.dispatchEvent(new CustomEvent('rc:ready'));
