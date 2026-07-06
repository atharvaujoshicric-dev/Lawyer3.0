-- LexDesk Full Migration — paste entire file in Supabase SQL Editor → Run

create or replace function is_admin() returns boolean
language sql security definer stable as $$
  select exists(select 1 from profiles where id=auth.uid() and role='admin' and approved=true);
$$;

create or replace function is_approved() returns boolean
language sql security definer stable as $$
  select exists(select 1 from profiles where id=auth.uid() and approved=true);
$$;

create or replace function user_has_note_share(p_note_id uuid, p_user_id uuid)
returns boolean language sql security definer stable as $$
  select exists(select 1 from note_shares where note_id=p_note_id and shared_with=p_user_id);
$$;

create or replace function user_has_note_editor_share(p_note_id uuid, p_user_id uuid)
returns boolean language sql security definer stable as $$
  select exists(select 1 from note_shares where note_id=p_note_id and shared_with=p_user_id and permission='editor');
$$;

create or replace function user_owns_note(p_note_id uuid, p_user_id uuid)
returns boolean language sql security definer stable as $$
  select exists(select 1 from notes where id=p_note_id and owner_id=p_user_id);
$$;

create or replace function user_in_group(p_group_id uuid, p_user_id uuid)
returns boolean language sql security definer stable as $$
  select exists(select 1 from group_members where group_id=p_group_id and user_id=p_user_id);
$$;

create or replace function user_is_group_admin(p_group_id uuid, p_user_id uuid)
returns boolean language sql security definer stable as $$
  select exists(select 1 from group_members where group_id=p_group_id and user_id=p_user_id and is_admin=true);
$$;

-- v3.1
drop policy if exists "profiles_select_own_or_admin" on profiles;
drop policy if exists "profiles_select_approved_or_self" on profiles;
create policy "profiles_select_approved_or_self" on profiles for select
  using (id=auth.uid() or is_admin() or (approved=true and is_approved()));

alter table tasks drop constraint if exists tasks_status_check;
alter table tasks add constraint tasks_status_check
  check (status in ('open','in_progress','in_review','done','cancelled'));

alter table messages add column if not exists edited_at timestamptz;
alter table messages add column if not exists deleted boolean default false;
drop policy if exists "messages_update" on messages;
create policy "messages_update" on messages for update
  using (sender_id=auth.uid() and created_at>(now()-interval '5 minutes'));

-- v3.2
alter table clients add column if not exists contact_id text references clients(client_id);

create table if not exists payments (
  id           uuid primary key default gen_random_uuid(),
  client_id    text references clients(client_id) on delete cascade,
  amount       numeric not null check (amount>0),
  payment_date date not null default current_date,
  method text, note text,
  recorded_by uuid references profiles(id),
  created_at timestamptz default now()
);
alter table payments enable row level security;
drop policy if exists "payments_select" on payments;
create policy "payments_select" on payments for select
  using (is_admin() or exists(select 1 from clients c where c.client_id=payments.client_id and c.assigned_to=auth.uid()));
drop policy if exists "payments_insert" on payments;
create policy "payments_insert" on payments for insert
  with check (is_admin() or exists(select 1 from clients c where c.client_id=payments.client_id and c.assigned_to=auth.uid()));
drop policy if exists "payments_update" on payments;
create policy "payments_update" on payments for update using (is_admin() or recorded_by=auth.uid());
drop policy if exists "payments_delete" on payments;
create policy "payments_delete" on payments for delete using (is_admin() or recorded_by=auth.uid());

create table if not exists planner_notes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references profiles(id) not null,
  note_date date not null default current_date,
  time text, content text not null, done boolean default false,
  created_at timestamptz default now()
);
alter table planner_notes enable row level security;
drop policy if exists "planner_select" on planner_notes;
create policy "planner_select" on planner_notes for select using (owner_id=auth.uid());
drop policy if exists "planner_insert" on planner_notes;
create policy "planner_insert" on planner_notes for insert with check (owner_id=auth.uid());
drop policy if exists "planner_update" on planner_notes;
create policy "planner_update" on planner_notes for update using (owner_id=auth.uid());
drop policy if exists "planner_delete" on planner_notes;
create policy "planner_delete" on planner_notes for delete using (owner_id=auth.uid());

create table if not exists onedrive_tokens (
  user_id uuid primary key references profiles(id) on delete cascade,
  access_token text, refresh_token text, expires_at timestamptz,
  root_folder_id text, updated_at timestamptz default now()
);
alter table onedrive_tokens enable row level security;
drop policy if exists "onedrive_tokens_all" on onedrive_tokens;
create policy "onedrive_tokens_all" on onedrive_tokens for all
  using (user_id=auth.uid()) with check (user_id=auth.uid());

-- v3.3
create table if not exists message_reads (
  message_id uuid references messages(id) on delete cascade,
  user_id uuid references profiles(id) on delete cascade,
  read_at timestamptz default now(),
  primary key (message_id, user_id)
);
alter table message_reads enable row level security;
drop policy if exists "mreads_select" on message_reads;
create policy "mreads_select" on message_reads for select using (user_id=auth.uid());
drop policy if exists "mreads_insert" on message_reads;
create policy "mreads_insert" on message_reads for insert with check (user_id=auth.uid());
drop policy if exists "mreads_delete" on message_reads;
create policy "mreads_delete" on message_reads for delete using (user_id=auth.uid());

create table if not exists note_shares (
  id uuid primary key default gen_random_uuid(),
  note_id uuid,
  shared_with uuid references profiles(id) on delete cascade,
  permission text not null check (permission in ('viewer','editor')),
  shared_by uuid references profiles(id),
  shared_at timestamptz default now(),
  unique (note_id, shared_with)
);
alter table note_shares enable row level security;
drop policy if exists "nshares_select" on note_shares;
create policy "nshares_select" on note_shares for select
  using (shared_with=auth.uid() or user_owns_note(note_id,auth.uid()));
drop policy if exists "nshares_insert" on note_shares;
create policy "nshares_insert" on note_shares for insert
  with check (user_owns_note(note_id,auth.uid()));
drop policy if exists "nshares_update" on note_shares;
create policy "nshares_update" on note_shares for update
  using (user_owns_note(note_id,auth.uid()));
drop policy if exists "nshares_delete" on note_shares;
create policy "nshares_delete" on note_shares for delete
  using (user_owns_note(note_id,auth.uid()));

create table if not exists notes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references profiles(id) not null,
  title text not null, content text not null default '',
  created_at timestamptz default now(), updated_at timestamptz default now()
);
alter table notes enable row level security;

do $$ begin
  if not exists (
    select 1 from information_schema.table_constraints
    where constraint_name='note_shares_note_id_fkey' and table_name='note_shares'
  ) then
    alter table note_shares add constraint note_shares_note_id_fkey
      foreign key (note_id) references notes(id) on delete cascade;
  end if;
end $$;

drop policy if exists "notes_select" on notes;
create policy "notes_select" on notes for select
  using (owner_id=auth.uid() or user_has_note_share(id,auth.uid()));
drop policy if exists "notes_insert" on notes;
create policy "notes_insert" on notes for insert with check (owner_id=auth.uid());
drop policy if exists "notes_update" on notes;
create policy "notes_update" on notes for update
  using (owner_id=auth.uid() or user_has_note_editor_share(id,auth.uid()));
drop policy if exists "notes_delete" on notes;
create policy "notes_delete" on notes for delete using (owner_id=auth.uid());

create table if not exists note_history (
  id uuid primary key default gen_random_uuid(),
  note_id uuid references notes(id) on delete cascade,
  changed_by uuid references profiles(id),
  snapshot text not null, changed_at timestamptz default now()
);
alter table note_history enable row level security;
drop policy if exists "nhist_select" on note_history;
create policy "nhist_select" on note_history for select
  using (user_owns_note(note_id,auth.uid()));
drop policy if exists "nhist_insert" on note_history;
create policy "nhist_insert" on note_history for insert with check (is_approved());

create table if not exists activity_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references profiles(id),
  action text not null, entity_type text not null, entity_id text not null,
  detail jsonb, created_at timestamptz default now()
);
alter table activity_log enable row level security;
drop policy if exists "actlog_select" on activity_log;
create policy "actlog_select" on activity_log for select
  using ((entity_type='client' and is_admin())
    or (entity_type='note' and user_owns_note(entity_id::uuid,auth.uid())));
drop policy if exists "actlog_insert" on activity_log;
create policy "actlog_insert" on activity_log for insert with check (is_approved());

alter table messages add column if not exists note_id uuid references notes(id) on delete set null;

insert into storage.buckets (id,name,public) values ('lexdesk-files','lexdesk-files',false) on conflict (id) do nothing;
drop policy if exists "storage_select" on storage.objects;
create policy "storage_select" on storage.objects for select using (bucket_id='lexdesk-files' and auth.role()='authenticated');
drop policy if exists "storage_insert" on storage.objects;
create policy "storage_insert" on storage.objects for insert with check (bucket_id='lexdesk-files' and auth.role()='authenticated');
drop policy if exists "storage_delete" on storage.objects;
create policy "storage_delete" on storage.objects for delete using (bucket_id='lexdesk-files' and auth.role()='authenticated');

-- v3.4
alter table profiles add column if not exists dob date;

-- v3.5
create table if not exists portal_tokens (
  id uuid primary key default gen_random_uuid(),
  client_id text references clients(client_id) on delete cascade,
  token text unique not null default gen_random_uuid()::text,
  pin_hash text not null,
  expires_at timestamptz not null default (now()+interval '90 days'),
  created_by uuid references profiles(id),
  created_at timestamptz default now()
);
alter table portal_tokens enable row level security;
drop policy if exists "portal_tokens_select" on portal_tokens;
create policy "portal_tokens_select" on portal_tokens for select using (true);
drop policy if exists "portal_tokens_insert" on portal_tokens;
create policy "portal_tokens_insert" on portal_tokens for insert with check (is_approved());
drop policy if exists "portal_tokens_delete" on portal_tokens;
create policy "portal_tokens_delete" on portal_tokens for delete using (is_admin() or created_by=auth.uid());

create table if not exists invoice_settings (
  id uuid primary key default gen_random_uuid(),
  firm_name text not null default 'Law Firm',
  firm_address text, firm_phone text, firm_email text, bar_number text,
  footer_text text default 'Thank you for your trust.',
  invoice_prefix text default 'INV', next_number int default 1,
  created_by uuid references profiles(id),
  updated_at timestamptz default now()
);
alter table invoice_settings enable row level security;
drop policy if exists "invoice_settings_select" on invoice_settings;
create policy "invoice_settings_select" on invoice_settings for select using (is_approved());
drop policy if exists "invoice_settings_insert" on invoice_settings;
create policy "invoice_settings_insert" on invoice_settings for insert with check (is_admin());
drop policy if exists "invoice_settings_update" on invoice_settings;
create policy "invoice_settings_update" on invoice_settings for update using (is_admin());

alter table templates add column if not exists variables jsonb default '[]'::jsonb;

create table if not exists deadline_rules (
  id uuid primary key default gen_random_uuid(),
  category_id text references categories(id) on delete set null,
  rule_name text not null, statute text, trigger_field text,
  offset_days int not null default 30,
  offset_direction text not null default 'after' check (offset_direction in ('after','before')),
  description text, is_active boolean default true,
  created_by uuid references profiles(id),
  created_at timestamptz default now(), updated_at timestamptz default now()
);
alter table deadline_rules enable row level security;
drop policy if exists "drules_select" on deadline_rules;
create policy "drules_select" on deadline_rules for select using (is_approved());
drop policy if exists "drules_insert" on deadline_rules;
create policy "drules_insert" on deadline_rules for insert with check (is_admin());
drop policy if exists "drules_update" on deadline_rules;
create policy "drules_update" on deadline_rules for update using (is_admin());
drop policy if exists "drules_delete" on deadline_rules;
create policy "drules_delete" on deadline_rules for delete using (is_admin());

insert into deadline_rules (rule_name,statute,category_id,trigger_field,offset_days,offset_direction,description) values
  ('Written Statement','CPC Order VIII Rule 1','general','created_at',30,'after','File written statement within 30 days of service'),
  ('Written Statement (Extended)','CPC Order VIII Rule 1 proviso','general','created_at',90,'after','Court may extend to 90 days'),
  ('First Appeal','CPC Section 96','general','nextHearing',90,'after','90 days from decree for first appeal'),
  ('Second Appeal','CPC Section 100','general','nextHearing',90,'after','90 days from first appellate decree'),
  ('Revision Petition','CPC Section 115','general','nextHearing',90,'after','90 days from order for civil revision'),
  ('Bail Application','CrPC Section 437','general','created_at',1,'after','Bail should be heard within 24 hours'),
  ('Charge Sheet','CrPC Section 167(2)','general','created_at',60,'after','Police must file charge sheet within 60 days'),
  ('Charge Sheet (Serious)','CrPC Section 167(2) proviso','general','created_at',90,'after','90 days for death/life sentence offences'),
  ('Criminal Appeal','CrPC Section 374','general','nextHearing',90,'after','90 days from conviction for appeal'),
  ('Limitation Contract','Limitation Act Article 55','general','created_at',1095,'after','3 years from breach of contract'),
  ('Limitation Tort','Limitation Act Article 72','general','created_at',1095,'after','3 years from cause of action in tort'),
  ('Limitation Land','Limitation Act Article 65','general','created_at',4380,'after','12 years for recovery of land'),
  ('CERT-In Incident','IT Act Section 70B','cyber','incidentDate',6,'after','6 hours from detection to report to CERT-In'),
  ('CERT-In Root Cause','CERT-In Directions 2022','cyber','incidentDate',30,'after','30 days for root cause analysis'),
  ('DPDP Data Breach','DPDP Act Section 8','cyber','incidentDate',72,'after','72 hours from discovery of personal data breach'),
  ('RBI Cyber Fraud','RBI Circular','cyber','incidentDate',1,'after','2-6 hours from cyber fraud detection'),
  ('Rent Renewal Notice','Transfer of Property Act','rental','agreementExpiry',30,'before','30 days notice before lease expiry'),
  ('Eviction Notice','TPA Section 106','rental','agreementExpiry',15,'before','15 days notice for month-to-month tenancy')
on conflict do nothing;

insert into invoice_settings (firm_name,invoice_prefix)
  select 'Law Firm','INV' where not exists (select 1 from invoice_settings);

-- v3.6
alter table profiles add column if not exists is_founder boolean default false;
alter table profiles add column if not exists custom_role_id uuid;
alter table profiles add column if not exists archived boolean default false;
alter table profiles add column if not exists chatbot_enabled boolean default true;
alter table profiles add column if not exists theme text default 'dark' check (theme in ('dark','light'));

update profiles set is_founder=true
  where id=(select id from profiles where role='admin' order by created_at limit 1)
  and is_founder is not true;

create table if not exists custom_roles (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  permissions jsonb not null default '{}',
  sort_order int default 99,
  created_by uuid references profiles(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table custom_roles enable row level security;
alter table custom_roles add column if not exists updated_at timestamptz default now();
drop policy if exists "croles_select" on custom_roles;
create policy "croles_select" on custom_roles for select using (is_approved());
drop policy if exists "croles_write" on custom_roles;
create policy "croles_write" on custom_roles for all using (is_admin()) with check (is_admin());

do $$ begin
  if not exists (
    select 1 from information_schema.table_constraints
    where constraint_name='profiles_custom_role_id_fkey'
  ) then
    alter table profiles add constraint profiles_custom_role_id_fkey
      foreign key (custom_role_id) references custom_roles(id) on delete set null;
  end if;
end $$;

insert into custom_roles (name,permissions,sort_order) values
  ('Senior Advocate','{"can_view_all_clients":true,"can_add_clients":true,"can_delete_clients":true,"can_assign_tasks":true,"can_create_tasks":true,"can_view_finances":true,"can_manage_users":true,"can_view_documents":true,"can_export":true}',1),
  ('Junior Advocate','{"can_view_all_clients":false,"can_add_clients":true,"can_delete_clients":false,"can_assign_tasks":true,"can_create_tasks":true,"can_view_finances":false,"can_manage_users":false,"can_view_documents":true,"can_export":true}',2),
  ('Senior Assistant','{"can_view_all_clients":false,"can_add_clients":true,"can_delete_clients":false,"can_assign_tasks":false,"can_create_tasks":false,"can_view_finances":false,"can_manage_users":false,"can_view_documents":true,"can_export":false}',3),
  ('Junior Assistant','{"can_view_all_clients":false,"can_add_clients":false,"can_delete_clients":false,"can_assign_tasks":false,"can_create_tasks":false,"can_view_finances":false,"can_manage_users":false,"can_view_documents":true,"can_export":false}',4)
on conflict (name) do nothing;

-- Group chat: create group_members FIRST (deferred FK), then chat_groups
create table if not exists group_members (
  group_id  uuid,
  user_id   uuid references profiles(id) on delete cascade,
  is_admin  boolean default false,
  joined_at timestamptz default now(),
  primary key (group_id, user_id)
);
alter table group_members enable row level security;

create table if not exists chat_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid references profiles(id),
  created_at timestamptz default now()
);
alter table chat_groups enable row level security;

do $$ begin
  if not exists (
    select 1 from information_schema.table_constraints
    where constraint_name='group_members_group_id_fkey'
  ) then
    alter table group_members add constraint group_members_group_id_fkey
      foreign key (group_id) references chat_groups(id) on delete cascade;
  end if;
end $$;

drop policy if exists "cgroups_select" on chat_groups;
create policy "cgroups_select" on chat_groups for select
  using (user_in_group(id, auth.uid()));

drop policy if exists "cgroups_insert" on chat_groups;
create policy "cgroups_insert" on chat_groups for insert
  with check (auth.uid() is not null);

drop policy if exists "cgroups_update" on chat_groups;
create policy "cgroups_update" on chat_groups for update
  using (user_is_group_admin(id, auth.uid()));

drop policy if exists "cgroups_delete" on chat_groups;
create policy "cgroups_delete" on chat_groups for delete
  using (created_by=auth.uid() or is_admin());

drop policy if exists "gmembers_select" on group_members;
create policy "gmembers_select" on group_members for select
  using (user_id=auth.uid() or user_in_group(group_id, auth.uid()));

drop policy if exists "gmembers_insert" on group_members;
create policy "gmembers_insert" on group_members for insert
  with check (auth.uid() is not null);

drop policy if exists "gmembers_delete" on group_members;
create policy "gmembers_delete" on group_members for delete
  using (user_id=auth.uid() or user_is_group_admin(group_id, auth.uid()) or is_admin());

drop policy if exists "gmembers_update" on group_members;
create policy "gmembers_update" on group_members for update
  using (user_is_group_admin(group_id, auth.uid()) or is_admin());

alter table messages add column if not exists group_id uuid references chat_groups(id) on delete cascade;

drop policy if exists "messages_select" on messages;
create policy "messages_select" on messages for select
  using (
    sender_id=auth.uid() or
    recipient_id=auth.uid() or
    recipient_id is null or
    (group_id is not null and user_in_group(group_id, auth.uid()))
  );

drop policy if exists "messages_insert" on messages;
create policy "messages_insert" on messages for insert
  with check (
    auth.uid() is not null and (
      group_id is null or user_in_group(group_id, auth.uid())
    )
  );

-- Sanity check
select table_name from information_schema.tables
where table_schema='public'
  and table_name in (
    'profiles','categories','form_schemas','clients','documents','templates',
    'tasks','task_comments','messages','signup_codes','payments','planner_notes',
    'onedrive_tokens','message_reads','notes','note_shares','note_history',
    'activity_log','portal_tokens','invoice_settings','deadline_rules',
    'custom_roles','chat_groups','group_members'
  )
order by table_name;

select conname from pg_constraint where conname='tasks_status_check';

select column_name from information_schema.columns
where table_name='profiles'
  and column_name in ('dob','is_founder','custom_role_id','archived','chatbot_enabled','theme')
order by column_name;

select routine_name from information_schema.routines
where routine_schema='public'
  and routine_name in (
    'is_admin','is_approved','user_has_note_share','user_has_note_editor_share',
    'user_owns_note','user_in_group','user_is_group_admin'
  )
order by routine_name;

-- ── Per-user theme config (jsonb: mode, accent, background, contrast) ──
alter table profiles add column if not exists theme_config jsonb default '{"mode":"dark","accent":"gold","background":"midnight","contrast":"standard"}'::jsonb;
