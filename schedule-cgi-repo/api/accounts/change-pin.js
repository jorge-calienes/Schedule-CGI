// POST /api/accounts/change-pin   { currentPin: "1234", newPin: "5678" }
//
// Self-service PIN change for the signed-in account — any active role
// (team lead, supervisor, admin), not just an admin resetting someone
// else's PIN via /api/accounts/grant. The account being changed is always
// the CALLER's own, resolved server-side from their bearer token — the
// request body never names an accountId, so this endpoint can't be used
// to change anyone else's PIN no matter what a client sends.
//
// Requires proving the current PIN first (via the same verify_pin() RPC
// pin-login.js uses, including its existing 5-attempt lockout) before
// set_pin() is allowed to run, so a device left signed in isn't enough on
// its own to hijack the PIN.

import { createClient } from '@supabase/supabase-js';

export default async function handler(req, res) {
  try {
    if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

    if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
      console.error('accounts/change-pin: missing SUPABASE_URL and/or SUPABASE_SERVICE_ROLE_KEY env vars');
      return res.status(500).json({ error: 'Server is misconfigured (missing Supabase credentials). Contact an admin.' });
    }

    const { currentPin, newPin } = req.body || {};
    if (!currentPin || !/^\d{4}$/.test(currentPin) || !newPin || !/^\d{4}$/.test(newPin)) {
      return res.status(400).json({ error: 'Current and new PIN must each be exactly 4 digits.' });
    }

    const supabaseAdmin = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY,
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const authHeader = req.headers.authorization || '';
    const token = authHeader.replace('Bearer ', '');
    if (!token) return res.status(401).json({ error: 'Not signed in.' });

    const { data: userData, error: userErr } = await supabaseAdmin.auth.getUser(token);
    if (userErr || !userData?.user) return res.status(401).json({ error: 'Not signed in.' });

    const { data: caller, error: callerErr } = await supabaseAdmin
      .from('accounts')
      .select('id, name, status')
      .eq('user_id', userData.user.id)
      .single();
    if (callerErr || !caller || caller.status !== 'active') {
      return res.status(401).json({ error: 'Not signed in.' });
    }

    const { data: verifiedId, error: verifyErr } = await supabaseAdmin.rpc('verify_pin', {
      p_name: caller.name,
      p_pin: currentPin,
    });
    if (verifyErr || verifiedId !== caller.id) {
      return res.status(401).json({ error: 'Current PIN is incorrect.' });
    }

    const { error: setErr } = await supabaseAdmin.rpc('set_pin', { p_account_id: caller.id, p_pin: newPin });
    if (setErr) return res.status(500).json({ error: 'Could not update your PIN — try again.' });

    await supabaseAdmin.from('audit_log').insert({
      actor_id: caller.id,
      action: 'account_grant',
      description: `${caller.name} changed their own PIN`,
      metadata: { accountId: caller.id, selfService: true },
    });

    return res.status(200).json({ message: 'Your PIN has been updated.' });
  } catch (e) {
    console.error('accounts/change-pin: unexpected error:', e);
    return res.status(500).json({ error: `Unexpected server error: ${e && e.message || e}` });
  }
}
