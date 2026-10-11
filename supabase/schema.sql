-- The Unsent Universe: Supabase schema (run in the SQL editor)
create extension if not exists pgcrypto;

create type letter_status as enum ('pending','approved','rejected','removed');

create table categories (slug text primary key, label text not null, sort int not null default 0);
insert into categories (slug,label,sort) values
 ('love','Love',1),('friendship','Friendship',2),('family','Family',3),('regret','Regret',4),
 ('gratitude','Gratitude',5),('grief-and-change','Grief and change',6),('self-reflection','Self-reflection',7),
 ('letting-go','Letting go',8),('hope','Hope',9),('other','Other',10);

create table letters (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 3 and 90),
  body text not null check (char_length(body) between 40 and 3000),
  category text not null default 'other' references categories(slug),
  mood text check (mood in ('Tender','Heavy','Hopeful','Restless','Calm','Bittersweet')),
  status letter_status not null default 'pending',
  resonance int not null default 0,          -- used for sorting only, never shown publicly
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);
create index on letters (status, created_at desc);

create table reactions (
  letter_id uuid references letters(id) on delete cascade,
  visitor_token uuid not null,               -- random token kept in the browser, not an identity
  kind text not null check (kind in ('understand','stayed','alone','warmth','resonated')),
  created_at timestamptz not null default now(),
  primary key (letter_id, visitor_token, kind)
);

create table reports (
  id uuid primary key default gen_random_uuid(),
  letter_id uuid not null references letters(id) on delete cascade,
  reason text not null check (char_length(reason) <= 80),
  note text check (char_length(note) <= 300),
  handled boolean not null default false,
  created_at timestamptz not null default now()
);

create table removal_requests (
  id uuid primary key default gen_random_uuid(),
  reference text not null check (char_length(reference) between 3 and 300),
  details text check (char_length(details) <= 1000),
  handled boolean not null default false,
  created_at timestamptz not null default now()
);

create table daily_prompts (id serial primary key, body text not null, active boolean not null default true);
insert into daily_prompts (body) values
 ('What would you say if there were no consequences?'),
 ('Which memory do you return to when life gets difficult?'),
 ('What do you wish someone understood about you?'),
 ('What are you finally ready to let go of?'),
 ('Who taught you something they never knew they taught you?'),
 ('What did you almost say the last time you saw them?'),
 ('What would you tell the person you were five years ago?'),
 ('Which small kindness have you never forgotten?'),
 ('What are you still carrying that was never yours?'),
 ('What do you miss that you cannot quite name?'),
 ('What would you apologise for if you knew it would be heard?'),
 ('What do you hope is waiting for you a year from now?'),
 ('Who do you think of at odd hours, and why?'),
 ('What did you do well that nobody noticed?');

create table admins (user_id uuid primary key references auth.users(id) on delete cascade);
create table submission_log (ip_hash text not null, at timestamptz not null default now());
create index on submission_log (ip_hash, at);

create or replace function is_admin() returns boolean
language sql security definer set search_path = public stable
as $$ select exists (select 1 from admins where user_id = auth.uid()) $$;

-- Row level security
alter table categories enable row level security;
alter table letters enable row level security;
alter table reactions enable row level security;
alter table reports enable row level security;
alter table removal_requests enable row level security;
alter table daily_prompts enable row level security;
alter table admins enable row level security;
alter table submission_log enable row level security;

create policy "public reads categories" on categories for select using (true);
create policy "public reads active prompts" on daily_prompts for select using (active);
create policy "public reads approved letters" on letters for select using (status = 'approved');
create policy "admins read all letters" on letters for select using (is_admin());
create policy "admins moderate letters" on letters for update using (is_admin()) with check (is_admin());
create policy "admins delete letters" on letters for delete using (is_admin());
create policy "admins read reports" on reports for select using (is_admin());
create policy "admins update reports" on reports for update using (is_admin());
create policy "admins read removals" on removal_requests for select using (is_admin());
create policy "admins update removals" on removal_requests for update using (is_admin());
create policy "admins read own admin row" on admins for select using (user_id = auth.uid());
-- No insert policies: visitors write only through the functions below.

-- Submission: callable ONLY by the Edge Function (service role). Validates and rate-limits.
create or replace function submit_letter(p_title text, p_body text, p_category text, p_mood text, p_consent boolean, p_ip_hash text)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if not p_consent then raise exception 'consent required'; end if;
  if (select count(*) from submission_log where ip_hash = p_ip_hash and at > now() - interval '1 hour') >= 3
    then raise exception 'rate limited'; end if;
  if p_body ~* '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[a-z]{2,}' or p_body ~* '(https?://|www\.)' then
    raise exception 'identifying content'; end if;
  insert into letters (title, body, category, mood, status)
    values (trim(p_title), trim(p_body), coalesce(nullif(p_category,''),'other'), nullif(p_mood,''), 'pending')
    returning id into new_id;
  insert into submission_log (ip_hash) values (p_ip_hash);
  return new_id;
end $$;
revoke all on function submit_letter(text,text,text,text,boolean,text) from public, anon, authenticated;
grant execute on function submit_letter(text,text,text,text,boolean,text) to service_role;

-- Reactions: anonymous, one per type per visitor token, approved letters only.
create or replace function toggle_reaction(p_letter uuid, p_token uuid, p_kind text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from letters where id = p_letter and status = 'approved') then return false; end if;
  if exists (select 1 from reactions where letter_id=p_letter and visitor_token=p_token and kind=p_kind) then
    delete from reactions where letter_id=p_letter and visitor_token=p_token and kind=p_kind;
    update letters set resonance = greatest(resonance-1,0) where id=p_letter; return false;
  end if;
  insert into reactions (letter_id, visitor_token, kind) values (p_letter, p_token, p_kind);
  update letters set resonance = resonance+1 where id=p_letter; return true;
end $$;
grant execute on function toggle_reaction(uuid,uuid,text) to anon, authenticated;

create or replace function report_letter(p_letter uuid, p_reason text, p_note text)
returns void language sql security definer set search_path = public as $$
  insert into reports (letter_id, reason, note) select p_letter, left(p_reason,80), left(p_note,300)
  where exists (select 1 from letters where id = p_letter and status = 'approved') $$;
grant execute on function report_letter(uuid,text,text) to anon, authenticated;

create or replace function request_removal(p_ref text, p_details text)
returns void language sql security definer set search_path = public as $$
  insert into removal_requests (reference, details) values (left(p_ref,300), left(p_details,1000)) $$;
grant execute on function request_removal(text,text) to anon, authenticated;

-- Retention (schedule daily with pg_cron or a Supabase scheduled function)
create or replace function purge_old() returns void language sql security definer set search_path = public as $$
  delete from letters where (status='pending' and created_at < now()-interval '30 days')
                         or (status='rejected' and reviewed_at < now()-interval '14 days');
  delete from submission_log where at < now()-interval '1 day';
  delete from reports where handled and created_at < now()-interval '90 days';
$$;
revoke all on function purge_old() from public, anon, authenticated;

-- To make yourself a moderator: sign up via Supabase Auth, then run:
-- insert into admins (user_id) select id from auth.users where email = 'you@example.com';
