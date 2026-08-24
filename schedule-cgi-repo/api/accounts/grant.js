// POST /api/accounts/grant
//   { accountId, role: "team_lead" | "supervisor" | "admin",
//     assignedAreaIds: ["<uuid>", ...] | [], pin: "1234" }
//
// Called from the "Manage accounts" screen. Requires the CALLER to already
// be signed in as an admin — we re-check that server-side against their
// bearer token rather than trusting the client, since this endpoint has
// elevated privileges (service role key).

import { createClient } from '@supabase/supabase-js';

async function requireAdmin(supabaseAdmin, req) {
  const authHeader = req.headers.authorization || '';
  const token = authHeader.replace('Bearer ', '');
  if (!token) return null;

  const { data: userData, error } = await supabaseAdmin.auth.getUser(token);
  if (error || !userData?.user) return null;

  const { data: account } = await supabaseAdmin
    .from('accounts')
    .select('id, name, role, status')
    .eq('user_id', userData.user.id)
    .single();

  if (!account || account.role !== 'admin' || account.status !== 'active') return null;
  return account;
}

export default async function handler(req, res) {
  // See pin-login.js for why this is all wrapped: an uncaught throw here
  // crashes the function and Vercel's non-JSON error page then fails to
  // parse client-side with a confusing, unrelated-looking error.
  try {
    if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

    if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
      console.error('accounts/grant: missing SUPABASE_URL and/or SUPABASE_SERVICE_ROLE_KEY env vars');
      return res.status(500).json({ error: 'Server is misconfigured (missing Supabase credentials). Contact an admin.' });
    }

    const supabaseAdmin = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY,
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const caller = await requireAdmin(supabaseAdmin, req);
    if (!caller) return res.status(403).json({ error: 'Admin access required.' });

    const { accountId, role, assignedAreaIds, pin } = req.body || {};
    if (!accountId || !role) {
      return res.status(400).json({ error: 'accountId and role are required.' });
    }
    if (pin && !/^\d{4}$/.test(pin)) {
      return res.status(400).json({ error: 'PIN must be exactly 4 digits.' });
    }
    if (role === 'team_lead' && !(Array.isArray(assignedAreaIds) && assignedAreaIds.length > 0)) {
      return res.status(400).json({ error: 'Team leads need at least one assigned area.' });
    }

    const { data: pending, error: fetchErr } = await supabaseAdmin
      .from('accounts').select('id, name, user_id, status').eq('id', accountId).single();
    if (fetchErr || !pending) return res.status(404).json({ error: 'Account not found.' });

    // Editing an already-active account (role/area change, or resetting the
    // PIN) can skip the PIN — only a pending/revoked → active transition
    // needs one, since that's the only way this account could ever sign in.
    const wasActive = pending.status === 'active';
    if (!wasActive && !pin) {
      return res.status(400).json({ error: 'A 4-digit PIN is required to activate this account.' });
    }

    // Create the backing Supabase Auth user if this account doesn't have one yet
    // (internal, unguessable email — nobody logs in with it directly, only via PIN).
    let userId = pending.user_id;
    if (!userId) {
      const internalEmail = `${accountId}@rotation.internal`;
      const { data: created, error: createErr } = await supabaseAdmin.auth.admin.createUser({
        email: internalEmail,
        email_confirm: true,
      });
      if (createErr) return res.status(500).json({ error: 'Could not create login for this account.' });
      userId = created.user.id;
    }

    const { error: updateErr } = await supabaseAdmin
      .from('accounts')
      .update({
        user_id: userId,
        role,
        status: 'active',
        assigned_area_ids: role === 'team_lead' ? assignedAreaIds : [],
        approved_at: new Date().toISOString(),
        approved_by: caller.id,
      })
      .eq('id', accountId);
    if (updateErr) return res.status(500).json({ error: 'Could not activate account.' });

    if (pin) {
      const { error: pinErr } = await supabaseAdmin.rpc('set_pin', { p_account_id: accountId, p_pin: pin });
      if (pinErr) return res.status(500).json({ error: 'Account saved but the PIN could not be set — try again.' });
    }

    await supabaseAdmin.from('audit_log').insert({
      actor_id: caller.id,
      action: 'account_grant',
      description: `${caller.name} ${wasActive ? 'updated' : 'granted'} ${role} access for ${pending.name}${pin ? ' (PIN reset)' : ''}`,
      metadata: { accountId, role, assignedAreaIds, pinReset: !!pin },
    });

    return res.status(200).json({
      message: wasActive ? `${pending.name}'s account was updated.` : `${pending.name} can now sign in.`,
      pinReset: !!pin,
    });
  } catch (e) {
    console.error('accounts/grant: unexpected error:', e);
    return res.status(500).json({ error: `Unexpected server error: ${e && e.message || e}` });
  }
}
