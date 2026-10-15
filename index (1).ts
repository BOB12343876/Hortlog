// Supabase Edge Function: orchard-alert
// Sends a push notification to everyone in an orchard when spraying, fertiliser or
// compost spreading is planned or done today. Called by a Database Webhook that fires
// when a row is added to the table "orchard_alerts" (the database adds one row per
// block per day, so nobody is spammed).
//
// Secrets to set (Project Settings, Edge Functions, Secrets):
//   ALERT_WEBHOOK_SECRET   any long random text. Use the same text in the webhook header.
//   VAPID_PUBLIC_KEY       the SAME keys your existing reminder notifications use
//   VAPID_PRIVATE_KEY
//   VAPID_SUBJECT          e.g. mailto:you@example.com
// Deploy with "Verify JWT" switched OFF (the webhook secret protects it instead).
import { createClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3'

Deno.serve(async (req) => {
  const secret = Deno.env.get('ALERT_WEBHOOK_SECRET')
  if (!secret || req.headers.get('x-webhook-secret') !== secret) return new Response('forbidden', { status: 403 })

  const payload = await req.json().catch(() => null)
  const a = payload?.record
  if (!a?.orchard_id) return new Response('no record', { status: 200 })

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  webpush.setVapidDetails(
    Deno.env.get('VAPID_SUBJECT') ?? 'mailto:admin@example.com',
    Deno.env.get('VAPID_PUBLIC_KEY')!,
    Deno.env.get('VAPID_PRIVATE_KEY')!,
  )

  // everyone in the orchard except the person who logged it
  const { data: members } = await admin.from('orchard_members').select('user_id').eq('orchard_id', a.orchard_id)
  const ids = (members ?? []).map((m) => m.user_id).filter((u) => u !== a.created_by)
  if (!ids.length) return new Response('nobody to tell', { status: 200 })

  // use the block's own name if it has one
  let where = 'the orchard'
  if (a.block) {
    const { data: b } = await admin.from('blocks').select('data').eq('orchard_id', a.orchard_id).eq('block', a.block).maybeSingle()
    where = b?.data?.name || `Block ${a.block}`
  }
  const spread = a.kind === 'spread'
  const title = spread ? 'Spreading today' : 'Spraying today'
  const body = `${spread ? 'Fertiliser or compost spreading' : 'Spraying'} in ${where} today. Take care in that area.`

  const { data: subs } = await admin.from('push_subs').select('endpoint,p256dh,auth,prefs').in('user_id', ids)
  let sent = 0
  await Promise.all((subs ?? []).filter((s) => s.prefs?.alerts !== false).map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify({ title, body, tag: `spray-${a.id}`, url: './' }),
        { TTL: 6 * 3600, urgency: 'high' },
      )
      sent++
    } catch (e) {
      if (e?.statusCode === 404 || e?.statusCode === 410) await admin.from('push_subs').delete().eq('endpoint', s.endpoint)
    }
  }))
  return new Response(JSON.stringify({ sent }), { status: 200, headers: { 'Content-Type': 'application/json' } })
})
