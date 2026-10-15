# Hortlog v28: roles, invitations and spray alerts. Setup in order

Do these in order. Until step 2 is done, the app keeps working exactly as it does now
(one person per account), so nobody is locked out while you set this up.

## 1. Back up (2 minutes)
Supabase dashboard > Database > Backups, or Table Editor > entries / blocks > Export as CSV.

## 2. Run the database migration
SQL Editor > New query > paste all of `hortlog-roles.sql` > Run.
- Every existing account becomes the Owner of its own orchard. Records and blocks are attached to it, not changed.
- Old app versions on people's phones keep working.
- A copy of your old security rules is saved in the table `_hortlog_policy_backup`.
- Safe to run twice.

## 3. Invitation emails (Edge Function)
Edge Functions > Deploy a new function > name it `invite-member` > paste `functions/invite-member/index.ts`.
Leave "Verify JWT" ON.
Edge Functions > Secrets: add `SITE_URL` = the web address where Hortlog is hosted.
Authentication > URL Configuration: set Site URL to the same address and add it under Redirect URLs.
Keep "Confirm email" switched ON (invitations only work for confirmed emails).
Note: Supabase's built-in email sender has a low hourly limit. For a bigger team, add your own SMTP under Authentication > Emails.

## 4. Spraying alerts (Edge Function + webhook)
Deploy a function named `orchard-alert` from `functions/orchard-alert/index.ts` with "Verify JWT" OFF.
Secrets to add: `ALERT_WEBHOOK_SECRET` (any long random text), and `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
`VAPID_SUBJECT` (e.g. mailto:you@example.com). Use the SAME VAPID keys your reminder notifications already use.
Database > Webhooks > Create: table `orchard_alerts`, event Insert, type Supabase Edge Function > `orchard-alert`,
add HTTP header `x-webhook-secret` with the same secret text.

## 5. Upload the new app
Replace `index.html` with the v28 file (keep your current `sw.js`).

## 6. Check it works
- Log in. Settings now shows "Your orchard" and you are Owner.
- Invite a spare email as Worker. Open the email, set a name and password, and check they see the orchard.
- Log a spray for today from the Owner account. The worker's Home shows the red alert (and a notification if the
  webhook is set up).
