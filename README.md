# LexDesk — Legal Practice Management CRM

A complete, multi-user legal practice management system for a Cybersecurity + General Practice law firm. Built as a single-page app, backed by Supabase (Postgres + Auth + Storage), deployable to GitHub Pages.

## v3.2 update — fee tracking, multi-case clients, daily planner, task locking

**If you've already run a previous migration**, run `RUN_THIS_MIGRATION.sql` again — it's a complete superset of every fix so far (chat visibility, task review status, message edit/delete, plus everything below) and is safe to run repeatedly.

**New features:**
- **Fee ledger.** Each case now has a Payments tab showing Total Fee, Paid So Far, and Balance Due, with a full dated history of individual payments (advance, partial, installments — however your clients actually pay). Anyone who can see the case can record a payment against it; only the recorder or the Admin can delete an entry.
- **Multiple cases per client.** When adding a new case, there's now a "New Case for an Existing Client?" search box — pick an existing contact and their phone/email/address auto-fill, while the new case stays its own independent record. Each client's detail view shows an "Other Cases for [Name]" list so you can jump between their matters. This list only shows cases you're allowed to see — an Assistant won't see another lawyer's case for a shared contact, just that it might exist.
- **Daily Planner.** A new sidebar item that auto-builds each day's agenda from tasks due that day and any date-type field in a case (hearing dates, deadlines, etc.), plus a personal notes/to-do list you can check off. Each lawyer's planner is private to them.
- **Task field locking.** Once a task moves past "Open," its title, description, due date, assignee, and priority lock — only status changes and comments are possible from there. This stops a task's scope shifting after work has already started.
- **Migration Status checker.** Settings (Admin only) now actively tests your live database against the two most common failure points — team visibility and the task review status — and tells you in plain language if the migration still needs to be run, instead of you discovering it from a cryptic error mid-task.

**OneDrive is now fully built and waiting on one value from you.** The OAuth flow, file upload, and link-retrieval logic are complete (Microsoft Graph API, "consumers" endpoint for personal accounts, PKCE flow — no client secret ever touches the browser). All that's left is registering a free Azure app to get a Client ID:

1. Go to **portal.azure.com**, sign in with your personal Microsoft account.
2. Search **"App registrations"** → **+ New registration**.
3. Name it anything (e.g. `LexDesk`). Under **Supported account types**, choose **"Accounts in any organizational directory and personal Microsoft accounts."**
4. Under **Redirect URI**, choose platform **Single-page application (SPA)** and enter your app's exact URL (e.g. `https://yourusername.github.io/lexdesk/`).
5. Click **Register**, then copy the **Application (client) ID** from the Overview page.
6. Go to **API permissions** → **+ Add a permission** → **Microsoft Graph** → **Delegated permissions** → check `Files.ReadWrite.All` and `offline_access` → **Add permissions**.
7. No client secret is needed — paste the Client ID into LexDesk's Settings → OneDrive Sync, then click Connect OneDrive.

No cost at any step — this is a one-time, free setup regardless of which Microsoft 365 storage plan you're on.

## v3.1 update — bug fixes and new features

If you already set up LexDesk and ran the original `supabase_schema.sql`, you don't need to start over. Just run **`RUN_THIS_MIGRATION.sql`** in your Supabase SQL Editor — it's safe to run even if some of it doesn't apply yet, and it's a complete superset that also includes everything from the v3.2 update below, so you only need to run it once.

**How to confirm the migration actually ran** (this matters — if it silently didn't, you'll see "No other team members yet" in chat and a `tasks_status_check` error when sending a task for review):
1. Open LexDesk as the Admin and go to **Settings** — there's now a "Migration Status" row that tests this directly and tells you in plain language if it's missing.
2. Or, run this directly in the Supabase SQL Editor and confirm it returns a row:
   ```sql
   select conname, pg_get_constraintdef(oid) from pg_constraint where conname = 'tasks_status_check';
   ```
   The output should include `in_review` in the list of allowed values. If it still only shows `open, in_progress, done, cancelled`, the migration hasn't run yet — open `RUN_THIS_MIGRATION.sql` and run the whole file in the Supabase SQL Editor.
3. Also confirm with:
   ```sql
   select policyname from pg_policies where tablename = 'profiles';
   ```
   You should see `profiles_select_approved_or_self` in the list, not `profiles_select_own_or_admin`.

**Bugs fixed:**
- Assistants couldn't see each other (or the Admin) in Direct Messages — caused by a database security rule that only let people see their own profile. Fixed so any approved team member can see the whole team.
- A security gap let a message **recipient** edit or delete a message that wasn't theirs. Now only the original sender can edit/delete their own message, and only within 5 minutes — enforced at the database level, not just in the interface.
- Deleting a client left their uploaded files sitting in storage forever, slowly eating space. Files are now removed when the client is deleted.
- Documents had no delete option even though the permissions already supported it. Added.
- Regenerating the team signup code had a small window where, if something went wrong, you could be left with no working code at all. Fixed the order of operations.
- Two people creating a client at the exact same moment could get assigned the same Client ID, causing the second save to silently fail. The app now detects this and retries automatically.
- An Assistant could only send a task for review after first clicking "Start Work" — there was no direct path from a freshly-assigned task to "Send for Review." Fixed so Send for Review is available immediately.

**New features:**
- **Chat**: edit or delete your own messages within 5 minutes of sending. Edited messages show "(Edited)" next to the timestamp; deleted messages show "This message was deleted." The edit/delete options disappear automatically once the 5 minutes pass.
- **Tasks**: a full review workflow. An Assistant can send a task for review at any point once it's assigned to them; the Senior Advocate then sends it back for rework, reopens it, or approves and closes it. The task board now has a fifth column, "In Review."
- **Settings → Migration Status**: a built-in admin-only check that tells you directly whether the database migration has been applied, instead of you having to guess from app symptoms.

## v3 — original feature set

## What's included

- Multi-user accounts with Supabase Auth (email + password)
- Role-based access: **Admin** (full "god mode" — can delete clients, manage users, edit forms) vs **Assistant Lawyer** (sees only assigned clients, cannot delete)
- Self-signup flow: first person to sign up becomes Admin automatically; everyone else signs up with a code the Admin shares, then waits for approval
- Dynamic case categories and custom form fields — add new case types beyond Cyber/Rental/General, edit/reorder/require fields per category
- Multiple cases per client — link a new matter to an existing contact so their details auto-fill, and jump between all their cases from any one of them
- Fee ledger — track partial/advance payments per case with a running balance, not just a single fee number
- Real file upload + inline preview (images, PDFs, text files) via Supabase Storage
- Draft/template documents with placeholder fill-in ({{CLIENT_NAME}}, {{DATE}}, etc.), shared across the whole team
- Internal team chat with file attachments, message edit/delete within 5 minutes, and "Edited"/"deleted" indicators (polls every 15 seconds — no websocket complexity)
- Daily Planner — auto-built agenda from tasks and case deadlines/hearings, plus personal notes, private to each lawyer
- Task assignment respecting hierarchy: Assistants can only raise tasks to the Admin; Admin can assign to anyone. Includes a full review workflow (Open → In Progress → In Review → Rework/Reopen/Close) with task details locked once work has started
- Deadline tracking and dashboard alerts
- Excel export (one workbook, 5 tabs: Clients / Documents / Payments / Users / Tasks)
- Mobile-first responsive design throughout, including a rebuilt Settings page
- OneDrive sync — fully built (Microsoft Graph, personal account OAuth), just needs a free one-time Client ID — see the v3.2 section above
- Built-in Migration Status checker so you can always tell if your database is up to date

## One-time setup

### 1. Run the database schema

1. Go to your Supabase project → **SQL Editor** → **New Query**
2. Paste the entire contents of `supabase_schema.sql`
3. Click **Run**

This creates all tables, security policies, the storage bucket, and seeds the three default case categories (Cybersecurity, Rental, General).

### 2. Get your Supabase credentials

In your Supabase project: **Settings → API**. You'll need the **Project URL** and the **anon/public key** (NOT the service_role key).

### 3. Deploy the app

Upload `index.html` (and the included `.nojekyll` file) to a GitHub repository, then enable GitHub Pages in repo settings, or just open `index.html` directly in a browser / host it anywhere static.

### 4. First run

1. Open the app — it will ask for your Supabase URL and anon key (one-time, stored in your browser's localStorage)
2. Go to the **Sign Up** tab and create your account — you will automatically become the Admin
3. From **Users**, copy your signup code and share it with any assistant lawyers
4. When an assistant signs up with that code, approve them from the **Users** page and assign their role

## Notes

- File uploads are capped at 20MB and stored in Supabase Storage (private bucket, signed URLs for viewing/downloading)
- All data access is enforced server-side via Postgres Row Level Security — the RBAC rules aren't just UI conventions, they're enforced at the database level
- Chat and task lists refresh automatically every 15 seconds while those tabs are open
