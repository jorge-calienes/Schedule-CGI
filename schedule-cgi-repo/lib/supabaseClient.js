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

// Pinned to an exact version (matching the server-side dependency in
// package.json) rather than floating on `@2`, so behavior is reproducible.
//
// Served from jsDelivr, not esm.sh: esm.sh's browser bundle injects a
// CommonJS-interop `require` shim that tricks @supabase/realtime-js's
// environment detection into thinking it's running under Node.js instead
// of a browser — it then goes looking for Node's native WebSocket support
// (Node 22+) and throws "Node.js 20 detected without native WebSocket
// support..." the moment auth.setSession() touches the realtime subsystem,
// even though the browser has WebSocket natively. jsDelivr's `+esm` build
// doesn't have that shim.
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.0/+esm';

const SUPABASE_URL = 'https://glnbvbgvgijmpeyagnge.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_EfRzoLu4cNiCodR85M_o9g_6syxQeu8';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

export async function signInWithPin(name, pin) {
  // Each step below is wrapped separately and re-thrown with a phase label —
  // an unexpected failure here (e.g. a "The string did not match the
  // expected pattern" SyntaxError seen on iOS Safari, not something this
  // app's own code throws) needs the phase to know whether it's the network
  // call, the response parsing, or the local Supabase session creation.
  let res;
  try {
    res = await fetch('/api/auth/pin-login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, pin }),
    });
  } catch (e) {
    throw new Error(`[fetch] ${e && e.message || e}`);
  }

  let body;
  try {
    body = await res.json();
  } catch (e) {
    throw new Error(`[parse response, status ${res.status}] ${e && e.message || e}`);
  }

  if (!res.ok) throw new Error(body.error || 'Sign-in failed');

  // Hand the minted session to the Supabase client so subsequent calls
  // (and RLS's auth.uid()) are authenticated as this account.
  try {
    const { error } = await supabase.auth.setSession({
      access_token: body.session.access_token,
      refresh_token: body.session.refresh_token,
    });
    if (error) throw error;
  } catch (e) {
    throw new Error(`[setSession] ${e && e.message || e}`);
  }

  return body.account; // { id, name, role, assigned_area_ids }
}

export async function requestAccess(name) {
  const res = await fetch('/api/accounts/request', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name }),
  });
  return res.json();
}

// Admin-only — the server re-verifies admin status itself (see
// api/accounts/grant.js) rather than trusting the client, so this Bearer
// token is what actually gates the request, not anything in this file.
export async function grantAccess({ accountId, role, assignedAreaIds, pin }) {
  const { data: { session } } = await supabase.auth.getSession();
  const res = await fetch('/api/accounts/grant', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(session ? { Authorization: `Bearer ${session.access_token}` } : {}),
    },
    body: JSON.stringify({ accountId, role, assignedAreaIds, pin }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || 'Could not grant access.');
  return body;
}

export async function fetchAccounts() {
  const { data, error } = await supabase.from('accounts').select('*').order('requested_at', { ascending: false });
  if (error) throw error;
  return data;
}

// Unlike grantAccess() this doesn't need the service-role API route — RLS's
// accounts_admin_write policy already lets an authenticated admin update any
// account row directly. Revoking just flips status; pin-login.js's "not
// active yet" check already blocks sign-in for anything but 'active'.
export async function revokeAccess({ accountId, actingAccountId }) {
  const { data: account, error: fetchErr } = await supabase.from('accounts').select('name').eq('id', accountId).single();
  if (fetchErr) throw fetchErr;

  const { error } = await supabase.from('accounts').update({ status: 'revoked' }).eq('id', accountId);
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'account_revoke',
    description: `revoked ${account.name}'s access`,
    metadata: { accountId },
  });
}

export async function signOut() {
  // scope:'local' clears the locally-persisted session without a round trip
  // to revoke it server-side. Global (default) scope needs that server call
  // to succeed to clear anything — but the whole point of signing out here
  // is often to recover from a session that's already broken/expired
  // server-side, so a network call gated on that same session can hang or
  // fail and leave the user stuck unable to sign out at all. Nobody using
  // this app needs "revoke this session on every other device" semantics.
  await supabase.auth.signOut({ scope: 'local' });
}

// Restores "who's signed in" across page reloads: supabase-js persists the
// session itself (localStorage, under its own key), so this just resolves
// that session back to an `accounts` row.
export async function getCurrentAccount() {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) return null;

  const { data, error } = await supabase
    .from('accounts')
    .select('id, name, role, assigned_area_ids')
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
  const [
    { data: areas }, { data: staff }, { data: assignments }, { data: departments }, { data: callouts },
    { data: supervisors }, { data: shifts }, { data: languages }, { data: staffLanguageCerts },
    { data: rotationFlows }, { data: rotationFlowStages }, { data: timeOff }, { data: blockedPairs },
    { data: coverageAssignments }, { data: lunchTimes }, { data: breakTimes }, { data: priorExperience },
    { data: coverageWaivers },
  ] = await Promise.all([
    supabase.from('areas').select('*').order('sort_order'),
    supabase.from('staff').select('*').eq('active', true),
    supabase.from('assignments').select('*'),
    supabase.from('departments').select('*').order('sort_order'),
    supabase.from('callouts').select('*'),
    supabase.from('supervisors').select('*').order('name'),
    supabase.from('shifts').select('*'),
    supabase.from('languages').select('*').order('name'),
    supabase.from('staff_language_certs').select('*'),
    supabase.from('rotation_flows').select('*').order('created_at'),
    supabase.from('rotation_flow_stages').select('*').order('stage_order'),
    supabase.from('time_off').select('*').order('start_date'),
    supabase.from('blocked_pairs').select('*'),
    supabase.from('coverage_assignments').select('*'),
    supabase.from('lunch_times').select('*').order('sort_order'),
    supabase.from('break_times').select('*').order('sort_order'),
    supabase.from('staff_prior_experience').select('*'),
    supabase.from('coverage_waivers').select('*'),
  ]);
  return {
    areas, staff, assignments, departments, callouts,
    supervisors, shifts, languages, staffLanguageCerts, rotationFlows, rotationFlowStages,
    timeOff, blockedPairs, coverageAssignments, lunchTimes, breakTimes, priorExperience, coverageWaivers,
  };
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

// "No coverage needed" on the Coverage dashboard — same shape as callouts,
// one row per staff member. No audit_log entry: this is a lightweight UI
// convenience (skip a slot in the pending list), not a security-relevant
// action worth its own audit_action enum value.
export async function waiveCoverage({ staffId, actingAccountId }) {
  const { error } = await supabase.from('coverage_waivers').upsert({
    staff_id: staffId,
    waived_by: actingAccountId,
  });
  if (error) throw error;
}

export async function unwaiveCoverage({ staffId }) {
  const { error } = await supabase.from('coverage_waivers').delete().eq('staff_id', staffId);
  if (error) throw error;
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

function staffRow({ name, tdisNumber, departmentId, homeAreaId, isTeamLead, isSubcontractor, needsAccommodations, tags, shiftHoursLabel, breakTimesLabel, counterCert, hireDate, supervisorId, flowId, flowEnrolled }) {
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
    counter_cert: !!counterCert,
    hire_date: hireDate || null,
    supervisor_id: supervisorId || null,
    flow_id: flowId || null,
    flow_enrolled: !!flowEnrolled,
  };
}

// staff_language_certs is a many-to-many join table with no "which cert is
// which" identity worth preserving — replacing the whole set for this staff
// member on every save is simpler and just as correct as diffing.
export async function setStaffLanguageCerts({ staffId, languageIds }) {
  const { error: delErr } = await supabase.from('staff_language_certs').delete().eq('staff_id', staffId);
  if (delErr) throw delErr;
  if (languageIds && languageIds.length) {
    const { error: insErr } = await supabase
      .from('staff_language_certs')
      .insert(languageIds.map(language_id => ({ staff_id: staffId, language_id })));
    if (insErr) throw insErr;
  }
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

// Narrow write for team leads: sends ONLY break_times_label in the PATCH
// (unlike updateStaff() above, which resends the whole staffRow()) so the
// staff_team_lead_column_guard trigger sees every other column as
// genuinely unchanged, not just "resent with the same value". Managers
// can call this too — it's just a smaller version of updateStaff() — but
// the roster/staff editor keep using updateStaff() for their full-form
// saves; this exists for the team-lead lunch/break quick-editor.
export async function updateStaffBreakTime({ staffId, breakTimesLabel, actingAccountId, staffName }) {
  const { error } = await supabase.from('staff').update({ break_times_label: breakTimesLabel || null }).eq('id', staffId);
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'edit_staff',
    description: `updated ${staffName || staffId}'s lunch time`,
    staff_id: staffId,
  });
}

export async function archiveStaff({ staffId, staffName, actingAccountId }) {
  const { error } = await supabase.from('staff').update({ active: false }).eq('id', staffId);
  if (error) throw error;

  // loadBoard() only fetches active=true staff, so an archived person drops
  // out of state.staff on the next load — but a live callout or coverage
  // row for them doesn't clean itself up, and getStaffById() then can't
  // resolve it. That left a ghost "?" entry in the callout banner and
  // crashed the "Assign coverage" dashboard (it reads s.name on every
  // callout row unconditionally). Clear both here so archiving never
  // leaves a dangling reference behind.
  await supabase.from('callouts').delete().eq('staff_id', staffId);
  await supabase.from('coverage_assignments').delete().eq('staff_id', staffId);

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'archive_staff',
    description: `removed ${staffName || staffId}`,
    staff_id: staffId,
  });
}

function areaRow({ name, color, capacity, departmentId, fixed }) {
  return {
    name,
    color: color || '#2F5FA8',
    capacity: capacity || 4,
    department_id: departmentId || null,
    fixed: !!fixed,
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

// ---------------------------------------------------------------------------
// Catalog entities (supervisors, shifts, languages, rotation flows). These
// were tables that existed in the schema but nothing ever read from or wrote
// to them — loadBoard() didn't fetch them and every manager screen mutated
// state.supervisors/shifts/languages/rotationFlows locally only, so none of
// it synced across devices. No audit_log entries here (unlike staff/area
// CRUD) — the audit_action enum has no catalog-edit values yet, and adding
// four just for this felt like more schema churn than the win was worth;
// worth revisiting if these turn out to need an audit trail too.
// ---------------------------------------------------------------------------

export async function createSupervisor({ name, color }) {
  const { data, error } = await supabase.from('supervisors').insert({ name, color: color || '#2F5FA8' }).select().single();
  if (error) throw error;
  return data;
}
export async function updateSupervisor({ supervisorId, name, color }) {
  const { error } = await supabase.from('supervisors').update({ name, color: color || '#2F5FA8' }).eq('id', supervisorId);
  if (error) throw error;
}
export async function deleteSupervisor({ supervisorId }) {
  const { error } = await supabase.from('supervisors').delete().eq('id', supervisorId);
  if (error) throw error;
}

export async function createShift({ label, start, end }) {
  const { data, error } = await supabase.from('shifts').insert({ label, start_time: start, end_time: end }).select().single();
  if (error) throw error;
  return data;
}
export async function updateShift({ shiftId, label, start, end }) {
  const { error } = await supabase.from('shifts').update({ label, start_time: start, end_time: end }).eq('id', shiftId);
  if (error) throw error;
}
export async function deleteShift({ shiftId }) {
  const { error } = await supabase.from('shifts').delete().eq('id', shiftId);
  if (error) throw error;
}

export async function createLunchTime({ label, sortOrder }) {
  const { data, error } = await supabase.from('lunch_times').insert({ label, sort_order: sortOrder || 0 }).select().single();
  if (error) throw error;
  return data;
}
export async function updateLunchTime({ lunchTimeId, label, sortOrder }) {
  const { error } = await supabase.from('lunch_times').update({ label, sort_order: sortOrder || 0 }).eq('id', lunchTimeId);
  if (error) throw error;
}
export async function deleteLunchTime({ lunchTimeId }) {
  const { error } = await supabase.from('lunch_times').delete().eq('id', lunchTimeId);
  if (error) throw error;
}

export async function createBreakTime({ label, sortOrder }) {
  const { data, error } = await supabase.from('break_times').insert({ label, sort_order: sortOrder || 0 }).select().single();
  if (error) throw error;
  return data;
}
export async function updateBreakTime({ breakTimeId, label, sortOrder }) {
  const { error } = await supabase.from('break_times').update({ label, sort_order: sortOrder || 0 }).eq('id', breakTimeId);
  if (error) throw error;
}
export async function deleteBreakTime({ breakTimeId }) {
  const { error } = await supabase.from('break_times').delete().eq('id', breakTimeId);
  if (error) throw error;
}

// Manual "worked this area before this system tracked rotations" flag —
// one row per (staff, area), upserted so re-checking an unchecked box
// (or editing the note) never creates a duplicate.
export async function setPriorExperience({ staffId, areaId, note, actingAccountId }) {
  const { data, error } = await supabase
    .from('staff_prior_experience')
    .upsert({ staff_id: staffId, area_id: areaId, note: note || null, added_by: actingAccountId }, { onConflict: 'staff_id,area_id' })
    .select()
    .single();
  if (error) throw error;
  return data;
}
export async function clearPriorExperience({ staffId, areaId }) {
  const { error } = await supabase.from('staff_prior_experience').delete().eq('staff_id', staffId).eq('area_id', areaId);
  if (error) throw error;
}

export async function createLanguage({ name }) {
  const { data, error } = await supabase.from('languages').insert({ name }).select().single();
  if (error) throw error;
  return data;
}
export async function updateLanguage({ languageId, name }) {
  const { error } = await supabase.from('languages').update({ name }).eq('id', languageId);
  if (error) throw error;
}
export async function deleteLanguage({ languageId }) {
  const { error } = await supabase.from('languages').delete().eq('id', languageId);
  if (error) throw error;
}

// Stages have no independent identity worth diffing — delete-and-reinsert on
// every save, same reasoning as setStaffLanguageCerts().
async function replaceFlowStages(flowId, stages) {
  const { error: delErr } = await supabase.from('rotation_flow_stages').delete().eq('flow_id', flowId);
  if (delErr) throw delErr;
  if (stages && stages.length) {
    const { error: insErr } = await supabase.from('rotation_flow_stages').insert(
      stages.map((s, i) => ({ flow_id: flowId, area_id: s.areaId, stage_order: i, min_periods: s.requiredRotations, label: s.label || null }))
    );
    if (insErr) throw insErr;
  }
}
export async function createRotationFlow({ name, color, stages }) {
  const { data: flow, error } = await supabase.from('rotation_flows').insert({ name, color: color || '#2F5FA8' }).select().single();
  if (error) throw error;
  await replaceFlowStages(flow.id, stages);
  return flow;
}
export async function updateRotationFlow({ flowId, name, color, stages }) {
  const { error } = await supabase.from('rotation_flows').update({ name, color: color || '#2F5FA8' }).eq('id', flowId);
  if (error) throw error;
  await replaceFlowStages(flowId, stages);
}
export async function deleteRotationFlow({ flowId }) {
  const { error } = await supabase.from('rotation_flows').delete().eq('id', flowId);
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Admin reset utilities — wipe rotation flows, or areas + departments, to
// start over from scratch. Deliberately admin-only client-side (see the
// nav gating in index.html) since these affect the whole team's board, not
// one record. Every FK from staff/assignments/evaluations/accounts/etc.
// into areas/departments/rotation_flows is ON DELETE SET NULL
// (rotation_flow_stages -> rotation_flows is CASCADE), so Postgres itself
// keeps everything consistent — staff just become unassigned/un-enrolled
// rather than the delete failing or leaving orphaned rows.
// ---------------------------------------------------------------------------

export async function resetRotationFlows({ actingAccountId }) {
  const { error } = await supabase.from('rotation_flows').delete().not('id', 'is', null);
  if (error) throw error;
  // flow_id is already nulled by the FK, but flow_enrolled is a plain
  // boolean with no FK to clean it up — clear it explicitly so no one is
  // left "enrolled" in a flow that no longer exists.
  await supabase.from('staff').update({ flow_enrolled: false }).eq('flow_enrolled', true);

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'edit_area',
    description: 'reset all rotation flows',
    metadata: { reset: 'rotation_flows' },
  });
}

export async function resetAreasAndDepartments({ actingAccountId }) {
  const { error: areaErr } = await supabase.from('areas').delete().not('id', 'is', null);
  if (areaErr) throw areaErr;
  const { error: deptErr } = await supabase.from('departments').delete().not('id', 'is', null);
  if (deptErr) throw deptErr;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'edit_area',
    description: 'reset all areas and departments',
    metadata: { reset: 'areas_and_departments' },
  });
}

// ---------------------------------------------------------------------------
// Time off entries and blocked pairs.
// ---------------------------------------------------------------------------

export async function createTimeOff({ staffId, startDate, endDate, label, actingAccountId }) {
  const { data, error } = await supabase.from('time_off').insert({
    staff_id: staffId, start_date: startDate, end_date: endDate, label: label || null, created_by: actingAccountId,
  }).select().single();
  if (error) throw error;
  return data;
}
export async function updateTimeOff({ timeOffId, startDate, endDate, label }) {
  const { error } = await supabase.from('time_off')
    .update({ start_date: startDate, end_date: endDate, label: label || null })
    .eq('id', timeOffId);
  if (error) throw error;
}
export async function deleteTimeOff({ timeOffId }) {
  const { error } = await supabase.from('time_off').delete().eq('id', timeOffId);
  if (error) throw error;
}

export async function createBlockedPair({ staffAId, staffBId }) {
  const { data, error } = await supabase.from('blocked_pairs')
    .insert({ staff_a_id: staffAId, staff_b_id: staffBId }).select().single();
  if (error) throw error;
  return data;
}
export async function deleteBlockedPair({ blockedPairId }) {
  const { error } = await supabase.from('blocked_pairs').delete().eq('id', blockedPairId);
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Coverage — who is currently covering someone else's area (from a manual
// callout or a scheduled time off) and where they return to. Was local-only
// before this (see 0007_coverage_sync.sql for the schema and
// PHASE2_ROADMAP.md for the bugs that caused). assignCoverage()/
// returnFromCoverage() do both the coverage-tracking write AND the actual
// board-position move (the assignments table) together, since from the
// caller's perspective starting/ending coverage IS one action — same
// reasoning as submitEvaluation()'s two sequential writes.
// ---------------------------------------------------------------------------

export async function assignCoverage({ staffId, coverAreaId, returnToAreaId, actingAccountId, staffName, coverAreaName }) {
  const now = new Date().toISOString();
  const { error: covErr } = await supabase.from('coverage_assignments').upsert({
    staff_id: staffId, return_to_area_id: returnToAreaId,
    started_date: now.slice(0, 10), created_by: actingAccountId,
  });
  if (covErr) throw covErr;

  const { error: moveErr } = await supabase.from('assignments').upsert({
    staff_id: staffId, area_id: coverAreaId, updated_by: actingAccountId, updated_at: now,
  });
  if (moveErr) throw moveErr;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'move',
    description: `${staffName || staffId} started covering ${coverAreaName || 'an area'}`,
    staff_id: staffId,
    metadata: { coverAreaId, returnToAreaId },
  });
}

export async function returnFromCoverage({ staffId, returnToAreaId, actingAccountId, staffName }) {
  const { error: delErr } = await supabase.from('coverage_assignments').delete().eq('staff_id', staffId);
  if (delErr) throw delErr;

  const { error: moveErr } = await supabase.from('assignments').upsert({
    staff_id: staffId, area_id: returnToAreaId, updated_by: actingAccountId, updated_at: new Date().toISOString(),
  });
  if (moveErr) throw moveErr;

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'move',
    description: `${staffName || staffId} returned from covering`,
    staff_id: staffId,
    metadata: { returnToAreaId },
  });
}

export async function setTimeOffCoverage({ timeOffId, coveringStaffId }) {
  const { error } = await supabase.from('time_off').update({ covering_staff_id: coveringStaffId }).eq('id', timeOffId);
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Rotate Now (Step 4). Snapshots the CLOSING period's assignments into
// rotation_periods + rotation_period_assignments, mirroring the local
// state.history.push() the app already does. This is deliberate/infrequent
// like staff & area CRUD, so it's awaited by the caller for a definitive
// "did this persist?" answer rather than fired-and-forgotten.
// ---------------------------------------------------------------------------

export async function createRotationPeriod({ periodLabel, startDate, endDate, weeks, notes, actingAccountId, assignments }) {
  const { data: period, error: periodErr } = await supabase
    .from('rotation_periods')
    .insert({
      period_label: periodLabel,
      start_date: startDate,
      end_date: endDate,
      weeks,
      notes: notes || null,
      started_by: actingAccountId,
    })
    .select()
    .single();
  if (periodErr) throw periodErr;

  const rows = Object.entries(assignments || {}).map(([staffId, areaId]) => ({
    period_id: period.id,
    staff_id: staffId,
    area_id: areaId || null,
  }));
  if (rows.length) {
    const { error: rowsErr } = await supabase.from('rotation_period_assignments').insert(rows);
    if (rowsErr) throw rowsErr;
  }

  await supabase.from('audit_log').insert({
    actor_id: actingAccountId,
    action: 'rotate_period',
    description: `started period "${periodLabel}" (${weeks}wk rotation)`,
    metadata: { periodId: period.id, weeks },
  });

  return period;
}

// Reads rotation_periods + their assignment snapshots back into the shape
// state.history already uses locally: [{period, assignments, startDate,
// endDate, weeks}], oldest..newest.
export async function fetchRotationHistory({ limit = 24 } = {}) {
  const { data: periods, error: periodsErr } = await supabase
    .from('rotation_periods')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(limit);
  if (periodsErr) throw periodsErr;
  if (!periods || !periods.length) return [];

  const periodIds = periods.map((p) => p.id);
  const { data: assignmentRows, error: assignErr } = await supabase
    .from('rotation_period_assignments')
    .select('period_id, staff_id, area_id')
    .in('period_id', periodIds);
  if (assignErr) throw assignErr;

  const byPeriod = {};
  (assignmentRows || []).forEach((row) => {
    if (!byPeriod[row.period_id]) byPeriod[row.period_id] = {};
    byPeriod[row.period_id][row.staff_id] = row.area_id;
  });

  return periods
    .slice()
    .reverse() // oldest..newest, matching state.history's existing order
    .map((p) => ({
      period: p.period_label,
      assignments: byPeriod[p.id] || {},
      startDate: p.start_date,
      endDate: p.end_date,
      weeks: p.weeks,
    }));
}

// `isManager` decides the row's landing status — a manager's own
// evaluation is final immediately ('approved'), a team_lead's needs a
// supervisor to accept it ('pending'). This mirrors the eval_insert/
// eval_update_own RLS check in 0006_evaluation_review_workflow.sql, which
// enforces the same rule server-side — the client value is what the RLS
// check validates against, not what grants the access.
export async function submitEvaluation({ staffId, periodId, areaId, evaluatorId, productivity, performance, reliability, note, recommendation, isManager }) {
  const { error } = await supabase.from('evaluations').upsert({
    staff_id: staffId,
    period_id: periodId,
    area_id: areaId,
    evaluator_id: evaluatorId,
    productivity, performance, reliability, note, recommendation,
    status: isManager ? 'approved' : 'pending',
    review_note: null, reviewed_by: null, reviewed_at: null,
  }, { onConflict: 'staff_id,evaluator_id,period_id' });
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: evaluatorId,
    action: 'evaluation',
    description: isManager
      ? `submitted an evaluation — recommended "${recommendation}"`
      : `submitted an evaluation for review — recommended "${recommendation}"`,
    staff_id: staffId,
    metadata: { productivity, performance, reliability, recommendation, status: isManager ? 'approved' : 'pending' },
  });
}

// The supervisor/admin review action on a team_lead's pending evaluation —
// approve it as-is, or send it back with a note for the team lead to
// revise and resubmit (which returns it to 'pending', see submitEvaluation).
export async function reviewEvaluation({ evaluationId, staffId, status, reviewNote, reviewerId }) {
  const { error } = await supabase.from('evaluations').update({
    status, review_note: reviewNote || null, reviewed_by: reviewerId, reviewed_at: new Date().toISOString(),
  }).eq('id', evaluationId);
  if (error) throw error;

  await supabase.from('audit_log').insert({
    actor_id: reviewerId,
    action: 'evaluation',
    description: status === 'approved' ? 'approved an evaluation' : 'sent an evaluation back for revision',
    staff_id: staffId,
    metadata: { evaluationId, status, reviewNote: reviewNote || null },
  });
}

export async function fetchPendingEvaluations() {
  const { data, error } = await supabase
    .from('evaluations')
    .select('*, staff:staff_id(name), evaluator:evaluator_id(name), area:area_id(name), period:period_id(period_label)')
    .eq('status', 'pending')
    .order('created_at', { ascending: true });
  if (error) throw error;
  return data;
}

export async function myEvaluationQueue() {
  const { data, error } = await supabase.from('my_evaluation_queue').select('*');
  if (error) throw error;
  return data;
}

// ---------------------------------------------------------------------------
// Staff performance profile (Phase 2 mockup screen 4) and Team dashboard
// (screen 5) — read-only aggregations over `evaluations`. RLS already scopes
// visibility (eval_select: managers see everyone, team leads only their own
// authored evaluations), so these just select and let the database enforce
// it rather than re-implementing that check client-side.
// ---------------------------------------------------------------------------

export async function fetchStaffEvaluationHistory(staffId) {
  const { data, error } = await supabase
    .from('evaluations')
    .select('*, evaluator:evaluator_id(name), area:area_id(name), period:period_id(period_label)')
    .eq('staff_id', staffId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data;
}

export async function fetchTeamPerformanceOverview() {
  const { data, error } = await supabase
    .from('evaluations')
    .select('staff_id, productivity, performance, reliability, recommendation, status, created_at, staff:staff_id(name)')
    .order('created_at', { ascending: false });
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
// Live sync (Supabase Realtime / Postgres Changes) — one shared channel
// subscribed to every table loadBoard() reads (see migration 0010 for the
// publication setup). onChange fires on every insert/update/delete on any
// of them; the caller decides what to do (index.html just re-runs
// loadBoard() and re-applies it — see scheduleRealtimeRefresh there).
// Deliberately dumb on this end: no diffing or per-table logic here, just
// "something changed, go refetch" — keeps this file from needing to know
// index.html's state shape.
// ---------------------------------------------------------------------------

const REALTIME_TABLES = [
  'areas', 'staff', 'assignments', 'departments', 'callouts', 'supervisors',
  'shifts', 'languages', 'staff_language_certs', 'rotation_flows',
  'rotation_flow_stages', 'time_off', 'blocked_pairs', 'coverage_assignments',
  'lunch_times', 'break_times', 'staff_prior_experience', 'coverage_waivers',
];

let realtimeChannel = null;

export function subscribeToBoardChanges(onChange) {
  if (realtimeChannel) return; // already subscribed — no-op, not an error
  let channel = supabase.channel('board-changes');
  for (const table of REALTIME_TABLES) {
    channel = channel.on('postgres_changes', { event: '*', schema: 'public', table }, onChange);
  }
  channel.subscribe();
  realtimeChannel = channel;
}

export function unsubscribeFromBoardChanges() {
  if (!realtimeChannel) return;
  supabase.removeChannel(realtimeChannel);
  realtimeChannel = null;
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
  waiveCoverage,
  unwaiveCoverage,
  ensureDepartment,
  createStaff,
  updateStaff,
  updateStaffBreakTime,
  archiveStaff,
  createArea,
  updateArea,
  deleteArea,
  createRotationPeriod,
  fetchRotationHistory,
  submitEvaluation,
  reviewEvaluation,
  fetchPendingEvaluations,
  myEvaluationQueue,
  fetchAuditLog,
  subscribeToBoardChanges,
  unsubscribeFromBoardChanges,
  grantAccess,
  fetchAccounts,
  revokeAccess,
  setStaffLanguageCerts,
  createSupervisor,
  updateSupervisor,
  deleteSupervisor,
  createShift,
  updateShift,
  deleteShift,
  createLunchTime,
  updateLunchTime,
  deleteLunchTime,
  createBreakTime,
  updateBreakTime,
  deleteBreakTime,
  setPriorExperience,
  clearPriorExperience,
  createLanguage,
  updateLanguage,
  deleteLanguage,
  createRotationFlow,
  updateRotationFlow,
  deleteRotationFlow,
  resetRotationFlows,
  resetAreasAndDepartments,
  createTimeOff,
  updateTimeOff,
  deleteTimeOff,
  createBlockedPair,
  deleteBlockedPair,
  assignCoverage,
  returnFromCoverage,
  setTimeOffCoverage,
  fetchStaffEvaluationHistory,
  fetchTeamPerformanceOverview,
};
window.dispatchEvent(new CustomEvent('rc:ready'));
