# The Unsent Universe

## Run the demo
Open `index.html` in a browser. It is a single self-contained file in **demo mode**:
letters, reactions, reports and moderation are stored only in your browser (localStorage).
Nothing is sent to a server.

## Go live with Supabase
1. Create a Supabase project and run `supabase/schema.sql` in the SQL editor.
2. Deploy `supabase/functions/submit-letter` and set secrets: `IP_SALT` (any long random string),
   optionally `TURNSTILE_SECRET`. The service-role key stays server-side only.
3. Sign up a moderator account in Supabase Auth, then run the `insert into admins ...` line at the end of schema.sql.
4. Schedule `select purge_old();` daily (pg_cron).
5. Replace the localStorage layer in `index.html` (the "storage" section) with calls to Supabase:
   reads from `letters`, `categories`, `daily_prompts`; writes via the Edge Function and the
   `toggle_reaction`, `report_letter`, `request_removal` functions. Keep the anon key in the frontend, never the service-role key.
6. Replace the demo moderation page with a Supabase Auth sign-in; the RLS policies enforce admin access.
7. Add a real contact address to the Contact page and review the Privacy page before launch.
