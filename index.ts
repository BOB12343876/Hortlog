// Supabase Edge Function: invite-member
// Called by the app when an Owner or Manager invites someone.
// 1. Saves the invitation using the caller's own login, so the database rules decide
//    whether they are allowed (only Owner or Manager of that orchard).
// 2. Sends the invitation email with Supabase's built-in invite.
//    If the person already has an account, sends a sign-in link instead. They join the
//    orchard automatically the next time they sign in with that email.
//
// Secrets to set (Project Settings, Edge Functions, Secrets):
//   SITE_URL   the address where Hortlog is hosted, e.g. https://yourname.github.io/hortlog/
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.)
import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const auth = req.headers.get('Authorization') ?? ''
    const url = Deno.env.get('SUPABASE_URL')!
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const site = Deno.env.get('SITE_URL') || undefined

    const { orchard_id, email, role, blocks } = await req.json()
    if (!orchard_id || !email || !role) return json({ error: 'Missing details' }, 400)

    // Step 1: save the invite as the signed-in person. The database enforces who may do this.
    const asCaller = createClient(url, anon, { global: { headers: { Authorization: auth } } })
    const saved = await asCaller.rpc('create_invite', {
      o: orchard_id, p_email: email, p_role: role, p_blocks: blocks ?? null,
    })
    if (saved.error) return json({ error: saved.error.message }, 400)

    // Step 2: send the email
    const em = String(email).trim().toLowerCase()
    const admin = createClient(url, service)
    const invited = await admin.auth.admin.inviteUserByEmail(em, { redirectTo: site })
    if (!invited.error) return json({ status: 'invited', id: saved.data })

    if (/already|registered|exists/i.test(invited.error.message)) {
      const plain = createClient(url, anon)
      const link = await plain.auth.signInWithOtp({
        email: em, options: { emailRedirectTo: site, shouldCreateUser: false },
      })
      return json({ status: link.error ? 'saved_no_email' : 'existing_user_emailed', id: saved.data, note: link.error?.message })
    }
    return json({ status: 'saved_no_email', id: saved.data, note: invited.error.message })
  } catch (e) {
    return json({ error: String(e) }, 500)
  }
})
