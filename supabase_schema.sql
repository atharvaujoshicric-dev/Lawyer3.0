-- ════════════════════════════════════════════════════════
--  LexDesk — Supabase Schema
--  Run this entire file ONCE in Supabase SQL Editor
--  (Project → SQL Editor → New Query → paste → Run)
-- ════════════════════════════════════════════════════════

-- ── PROFILES (extends Supabase auth.users) ──
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  username text unique,
  role text not null default 'pending' check (role in ('admin','assistant','pending')),
  bar_number text,
  phone text,
  email text,
  court text,
  approved boolean not null default false,
  created_at timestamptz default now()
);

-- ── CATEGORIES (case types) ──
create table if not exists categories (
  id text primary key,
  label text not null,
  icon text default 'fas fa-folder',
  color text default 'blue',
  built_in boolean default false,
  created_by uuid references profiles(id),
  created_at timestamptz default now()
);

-- ── FORM SCHEMAS (dynamic fields per category) ──
create table if not exists form_schemas (
  category_id text primary key references categories(id) on delete cascade,
  fields jsonb not null default '[]'::jsonb,
  updated_at timestamptz default now()
);

-- ── CLIENTS ──
-- Each row here is really a "case" (a matter). A real-world client can have
-- multiple rows/cases — contact_id groups them. When contact_id is null,
-- the row is its own standalone contact (the common case). When a new case
-- is created "for an existing client," contact_id points at the client_id
-- of their first/original case row, so the UI can list all their matters
-- together and auto-fill contact info on new ones.
create table if not exists clients (
  client_id text primary key,
  contact_id text references clients(client_id),
  name text not null,
  case_type text references categories(id),
  status text default 'active' check (status in ('active','pending','closed')),
  phone text,
  email text,
  address text,
  fee numeric,
  notes text,
  case_data jsonb default '{}'::jsonb,
  assigned_to uuid references profiles(id),
  created_by uuid references profiles(id),
  history jsonb default '[]'::jsonb,
  onedrive_folder_link text,
  synced boolean default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- ── DOCUMENTS ──
create table if not exists documents (
  id uuid primary key default gen_random_uuid(),
  client_id text references clients(client_id) on delete cascade,
  name text not null,
  category text,
  size bigint,
  mime_type text,
  storage_path text,           -- Supabase Storage path (instant preview)
  onedrive_link text,          -- OneDrive link once synced (filled later)
  uploaded_by uuid references profiles(id),
  uploaded_at timestamptz default now()
);

-- ── TEMPLATES (drafts) ──
create table if not exists templates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text,
  content text not null,
  created_by uuid references profiles(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- ── TASKS ──
create table if not exists tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  client_id text references clients(client_id) on delete set null,
  assigned_by uuid references profiles(id),
  assigned_to uuid references profiles(id),
  status text default 'open' check (status in ('open','in_progress','in_review','done','cancelled')),
  priority text default 'medium' check (priority in ('low','medium','high')),
  due_date date,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- ── ONEDRIVE TOKENS (per-user OAuth tokens, kept private to each user) ──
create table if not exists onedrive_tokens (
  user_id uuid primary key references profiles(id) on delete cascade,
  access_token text,
  refresh_token text,
  expires_at timestamptz,
  root_folder_id text,
  updated_at timestamptz default now()
);

-- ── PAYMENTS (fee ledger — multiple dated entries per case) ──
create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  client_id text references clients(client_id) on delete cascade,
  amount numeric not null check (amount > 0),
  payment_date date not null default current_date,
  method text,                  -- e.g. Cash, Bank Transfer, UPI, Cheque
  note text,
  recorded_by uuid references profiles(id),
  created_at timestamptz default now()
);

-- ── DAILY PLANNER NOTES (manual entries; tasks/deadlines/hearings are
--    pulled in live by the app, not stored here) ──
create table if not exists planner_notes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references profiles(id) not null,
  note_date date not null default current_date,
  time text,                    -- free-text time label, e.g. "10:30 AM", optional
  content text not null,
  done boolean default false,
  created_at timestamptz default now()
);

-- ── TASK COMMENTS ──
create table if not exists task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references tasks(id) on delete cascade,
  author_id uuid references profiles(id),
  body text not null,
  created_at timestamptz default now()
);

-- ── CHAT MESSAGES ──
create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid references profiles(id),
  recipient_id uuid references profiles(id),   -- null = broadcast to all (team channel)
  body text,
  attachment_path text,         -- Supabase Storage path
  attachment_name text,
  created_at timestamptz default now(),
  edited_at timestamptz,        -- set when sender edits within the 5-min window
  deleted boolean default false,-- soft-delete; UI shows "This message was deleted"
  read boolean default false
);

-- ── SIGNUP CODES (admin shares this code with assistants for self-signup) ──
create table if not exists signup_codes (
  code text primary key,
  created_by uuid references profiles(id),
  created_at timestamptz default now(),
  active boolean default true
);

-- ════════════════════════════════════════════════════════
--  ROW LEVEL SECURITY
-- ════════════════════════════════════════════════════════
alter table profiles enable row level security;
alter table categories enable row level security;
alter table form_schemas enable row level security;
alter table clients enable row level security;
alter table payments enable row level security;
alter table planner_notes enable row level security;
alter table onedrive_tokens enable row level security;
alter table documents enable row level security;
alter table templates enable row level security;
alter table tasks enable row level security;
alter table task_comments enable row level security;
alter table messages enable row level security;
alter table signup_codes enable row level security;

-- Helper: is the current user an approved admin?
create or replace function is_admin() returns boolean as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin' and approved = true);
$$ language sql security definer stable;

create or replace function is_approved() returns boolean as $$
  select exists(select 1 from profiles where id = auth.uid() and approved = true);
$$ language sql security definer stable;

-- PROFILES policies
-- NOTE: any approved user can see all approved profiles (needed for the
-- team directory / chat contact list / task-assignee dropdowns to work).
-- You can always see your own row even before approval (so the pending
-- screen and self-service flows keep working).
create policy "profiles_select_approved_or_self" on profiles for select
  using (id = auth.uid() or is_admin() or (approved = true and is_approved()));
create policy "profiles_insert_self" on profiles for insert
  with check (id = auth.uid());
create policy "profiles_update_own_or_admin" on profiles for update
  using (id = auth.uid() or is_admin());

-- CATEGORIES — everyone approved can read, only admin writes
create policy "categories_select" on categories for select using (is_approved());
create policy "categories_insert" on categories for insert with check (is_admin());
create policy "categories_update" on categories for update using (is_admin());
create policy "categories_delete" on categories for delete using (is_admin());

-- FORM SCHEMAS — everyone approved can read, only admin writes
create policy "schemas_select" on form_schemas for select using (is_approved());
create policy "schemas_upsert" on form_schemas for insert with check (is_admin());
create policy "schemas_update" on form_schemas for update using (is_admin());

-- CLIENTS — admin sees all; assistant sees only assigned; only admin deletes
create policy "clients_select" on clients for select
  using (is_admin() or assigned_to = auth.uid());
create policy "clients_insert" on clients for insert
  with check (is_approved());
create policy "clients_update" on clients for update
  using (is_admin() or assigned_to = auth.uid());
create policy "clients_delete" on clients for delete
  using (is_admin());

-- PAYMENTS — visible if you can see the parent client (case); only admin
-- or the case's assigned lawyer can record/edit/delete entries
create policy "payments_select" on payments for select
  using (is_admin() or exists(select 1 from clients c where c.client_id = payments.client_id and c.assigned_to = auth.uid()));
create policy "payments_insert" on payments for insert
  with check (is_admin() or exists(select 1 from clients c where c.client_id = payments.client_id and c.assigned_to = auth.uid()));
create policy "payments_update" on payments for update
  using (is_admin() or recorded_by = auth.uid());
create policy "payments_delete" on payments for delete
  using (is_admin() or recorded_by = auth.uid());

-- PLANNER NOTES — strictly private to the owner (each lawyer's own agenda)
create policy "planner_select" on planner_notes for select
  using (owner_id = auth.uid());
create policy "planner_insert" on planner_notes for insert
  with check (owner_id = auth.uid());
create policy "planner_update" on planner_notes for update
  using (owner_id = auth.uid());
create policy "planner_delete" on planner_notes for delete
  using (owner_id = auth.uid());

-- ONEDRIVE TOKENS — strictly private; each user can only see/manage their own
create policy "onedrive_tokens_all" on onedrive_tokens for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- DOCUMENTS — visible if you can see the parent client
create policy "documents_select" on documents for select
  using (is_admin() or exists(select 1 from clients c where c.client_id = documents.client_id and c.assigned_to = auth.uid()));
create policy "documents_insert" on documents for insert
  with check (is_approved());
create policy "documents_delete" on documents for delete
  using (is_admin() or uploaded_by = auth.uid());

-- TEMPLATES — visible to all approved users; admin + creator can edit/delete
create policy "templates_select" on templates for select using (is_approved());
create policy "templates_insert" on templates for insert with check (is_approved());
create policy "templates_update" on templates for update using (is_admin() or created_by = auth.uid());
create policy "templates_delete" on templates for delete using (is_admin() or created_by = auth.uid());

-- TASKS — visible if you assigned it or it's assigned to you; admin sees all
create policy "tasks_select" on tasks for select
  using (is_admin() or assigned_to = auth.uid() or assigned_by = auth.uid());
create policy "tasks_insert" on tasks for insert with check (is_approved());
create policy "tasks_update" on tasks for update
  using (is_admin() or assigned_to = auth.uid() or assigned_by = auth.uid());
create policy "tasks_delete" on tasks for delete using (is_admin() or assigned_by = auth.uid());

-- TASK COMMENTS — visible if you can see the parent task
create policy "task_comments_select" on task_comments for select
  using (is_admin() or exists(select 1 from tasks t where t.id = task_comments.task_id and (t.assigned_to = auth.uid() or t.assigned_by = auth.uid())));
create policy "task_comments_insert" on task_comments for insert with check (is_approved());

-- MESSAGES — visible if you're sender, recipient, or it's a broadcast (recipient_id is null)
create policy "messages_select" on messages for select
  using (sender_id = auth.uid() or recipient_id = auth.uid() or recipient_id is null);
create policy "messages_insert" on messages for insert with check (is_approved());
-- Only the original sender can edit/delete their own message, and only
-- within 5 minutes of sending — enforced here, not just in the UI, since
-- client-side checks alone can be bypassed by calling the API directly.
create policy "messages_update" on messages for update
  using (sender_id = auth.uid() and created_at > (now() - interval '5 minutes'));

-- SIGNUP CODES — admin manages; anyone (even unauthenticated via anon key) can read to validate during signup
create policy "signup_codes_select" on signup_codes for select using (true);
create policy "signup_codes_insert" on signup_codes for insert with check (is_admin());
create policy "signup_codes_update" on signup_codes for update using (is_admin());

-- ════════════════════════════════════════════════════════
--  STORAGE BUCKET (run separately if not auto-created)
--  Go to Storage → New Bucket → name: "lexdesk-files" → Public: OFF
-- ════════════════════════════════════════════════════════
insert into storage.buckets (id, name, public) values ('lexdesk-files','lexdesk-files', false)
  on conflict (id) do nothing;

create policy "storage_select" on storage.objects for select
  using (bucket_id = 'lexdesk-files' and auth.role() = 'authenticated');
create policy "storage_insert" on storage.objects for insert
  with check (bucket_id = 'lexdesk-files' and auth.role() = 'authenticated');
create policy "storage_delete" on storage.objects for delete
  using (bucket_id = 'lexdesk-files' and auth.role() = 'authenticated');

-- ════════════════════════════════════════════════════════
--  SEED: default categories + form schemas
-- ════════════════════════════════════════════════════════
insert into categories (id,label,icon,color,built_in) values
  ('cyber','Cybersecurity','fas fa-shield-alt','blue',true),
  ('rental','Rental / Property','fas fa-home','green',true),
  ('general','General Practice','fas fa-gavel','purple',true)
on conflict (id) do nothing;

insert into form_schemas (category_id, fields) values
('cyber', '[
  {"id":"incidentDate","label":"Incident Date","type":"date","required":true},
  {"id":"breachType","label":"Breach Type","type":"select","required":true,"options":["Ransomware Attack","Data Exfiltration","Phishing / Social Engineering","Unauthorized Access","DDoS Attack","Insider Threat","Supply Chain Compromise","Zero-Day Exploit","Other"]},
  {"id":"affectedServers","label":"Affected Systems / Servers","type":"text","required":false},
  {"id":"recordsCompromised","label":"Records Compromised","type":"number","required":false},
  {"id":"regulatoryBody","label":"Regulatory Body","type":"select","required":false,"options":["CERT-In (India)","GDPR (EU)","HIPAA (US)","PDPB (India)","RBI Guidelines","SEBI Guidelines","Other"]},
  {"id":"regulatoryDeadline","label":"Regulatory Deadline","type":"date","required":false},
  {"id":"incidentSummary","label":"Incident Summary","type":"textarea","required":false},
  {"id":"forensicReport","label":"Forensic Report Filed","type":"select","required":false,"options":["No","Yes","In Progress"]},
  {"id":"priority","label":"Case Priority","type":"select","required":false,"options":["High","Medium","Low"]}
]'::jsonb),
('rental', '[
  {"id":"propertyAddress","label":"Property Address","type":"text","required":true},
  {"id":"monthlyRent","label":"Monthly Rent (₹)","type":"number","required":true},
  {"id":"securityDeposit","label":"Security Deposit (₹)","type":"number","required":false},
  {"id":"lockinPeriod","label":"Lock-in Period (months)","type":"number","required":false},
  {"id":"agreementStart","label":"Agreement Start Date","type":"date","required":false},
  {"id":"agreementExpiry","label":"Agreement Expiry Date","type":"date","required":true},
  {"id":"renewalDate","label":"Renewal Date","type":"date","required":false},
  {"id":"propertyType","label":"Property Type","type":"select","required":false,"options":["Residential Apartment","Commercial Office","Retail Shop","Industrial Unit","Agricultural Land","Villa / Bungalow","Other"]},
  {"id":"landlord","label":"Landlord Name","type":"text","required":false},
  {"id":"landlordContact","label":"Landlord Contact","type":"tel","required":false},
  {"id":"rentalNotes","label":"Dispute / Notes","type":"textarea","required":false}
]'::jsonb),
('general', '[
  {"id":"matterDescription","label":"Matter Description","type":"text","required":true},
  {"id":"practiceArea","label":"Practice Area","type":"select","required":false,"options":["Civil Law","Criminal Law","Corporate Law","Family Law","Labour Law","Constitutional Law","Consumer Law","Intellectual Property","Tax Law","Other"]},
  {"id":"court","label":"Court / Tribunal","type":"text","required":false},
  {"id":"caseNumber","label":"Case Number / FIR","type":"text","required":false},
  {"id":"oppositeParty","label":"Opposite Party","type":"text","required":false},
  {"id":"nextHearing","label":"Next Hearing Date","type":"date","required":false},
  {"id":"judge","label":"Judge / Bench","type":"text","required":false},
  {"id":"stage","label":"Stage of Proceedings","type":"select","required":false,"options":["Filing / Pleading Stage","Evidence Stage","Arguments Stage","Judgment Pending","Appeal Filed","Execution Proceedings","Settled / Disposed"]}
]'::jsonb)
on conflict (category_id) do nothing;

-- Done. Next: create your admin account by signing up in the app,
-- then run this once (replace the email) to make yourself admin:
--
-- update profiles set role = 'admin', approved = true where email = 'you@example.com';

-- ════════════════════════════════════════════════════════
--  MIGRATION (run this block if you already ran the schema
--  above on an earlier version of LexDesk — it's safe to run
--  multiple times)
-- ════════════════════════════════════════════════════════
alter table messages add column if not exists edited_at timestamptz;
alter table messages add column if not exists deleted boolean default false;

alter table tasks drop constraint if exists tasks_status_check;
alter table tasks add constraint tasks_status_check
  check (status in ('open','in_progress','in_review','done','cancelled'));

drop policy if exists "profiles_select_own_or_admin" on profiles;
drop policy if exists "profiles_select_approved_or_self" on profiles;
create policy "profiles_select_approved_or_self" on profiles for select
  using (id = auth.uid() or is_admin() or (approved = true and is_approved()));

drop policy if exists "messages_update" on messages;
create policy "messages_update" on messages for update
  using (sender_id = auth.uid() and created_at > (now() - interval '5 minutes'));

