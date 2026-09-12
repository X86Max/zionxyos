-- Zionxyos v0.1
-- Execute this entire migration in the Supabase SQL Editor on a NEW project.
-- It intentionally creates NO sample articles.

create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type public.user_role as enum ('user', 'sysadmin');
  end if;

  if not exists (select 1 from pg_type where typname = 'article_status') then
    create type public.article_status as enum ('draft', 'pending_review', 'published');
  end if;
end
$$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,24}$'),
  display_name text check (char_length(display_name) <= 80),
  bio text check (char_length(bio) <= 1000),
  role public.user_role not null default 'user',
  suspended boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.articles (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 160),
  slug text not null unique,
  summary text check (char_length(summary) <= 600),
  content text not null default '',
  category text check (char_length(category) <= 80),
  tags text[] not null default '{}',
  cover_image_url text,
  video_url text,
  author_id uuid not null references public.profiles(id) on delete restrict,
  status public.article_status not null default 'draft',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz
);

create table if not exists public.article_versions (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null references public.articles(id) on delete cascade,
  snapshot jsonb not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles(id) on delete set null,
  action text not null,
  target_type text not null,
  target_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists articles_status_published_idx
  on public.articles(status, published_at desc);

create index if not exists articles_author_updated_idx
  on public.articles(author_id, updated_at desc);

create index if not exists article_versions_article_idx
  on public.article_versions(article_id, created_at desc);

create index if not exists audit_logs_created_idx
  on public.audit_logs(created_at desc);

-- SECURITY-DEFINER helpers avoid recursive RLS lookups.
create or replace function public.is_sysadmin(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = uid
      and role = 'sysadmin'
      and suspended = false
  );
$$;

revoke all on function public.is_sysadmin(uuid) from public;
grant execute on function public.is_sysadmin(uuid) to anon, authenticated;

create or replace function public.is_active_user(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = uid
      and suspended = false
  );
$$;

revoke all on function public.is_active_user(uuid) from public;
grant execute on function public.is_active_user(uuid) to authenticated;

-- Create one profile automatically after Supabase Auth creates the account.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_username text;
begin
  requested_username := lower(coalesce(new.raw_user_meta_data ->> 'username', 'user_' || left(new.id::text, 8)));

  if requested_username !~ '^[a-z0-9_]{3,24}$' then
    requested_username := 'user_' || left(new.id::text, 8);
  end if;

  if exists (select 1 from public.profiles where username = requested_username) then
    requested_username := left(requested_username, 15) || '_' || left(new.id::text, 8);
  end if;

  insert into public.profiles (id, username)
  values (new.id, requested_username);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute procedure public.set_updated_at();

drop trigger if exists articles_set_updated_at on public.articles;
create trigger articles_set_updated_at
  before update on public.articles
  for each row execute procedure public.set_updated_at();

-- A normal user may edit public profile fields, but cannot promote/suspend themselves.
create or replace function public.protect_profile_privileged_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- SQL Editor/service operations have no end-user auth.uid().
  -- This also lets the project owner bootstrap the first sysadmin.
  if auth.uid() is null then
    return new;
  end if;

  if not public.is_sysadmin(auth.uid()) then
    if new.role is distinct from old.role or new.suspended is distinct from old.suspended then
      raise exception 'Only a sysadmin can change role or suspension status';
    end if;

    if new.username is distinct from old.username then
      raise exception 'Username changes are disabled in v0.1';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists protect_profile_privileged_fields on public.profiles;
create trigger protect_profile_privileged_fields
  before update on public.profiles
  for each row execute procedure public.protect_profile_privileged_fields();

-- Users can only write draft/review states. Only sysadmin can publish.
create or replace function public.enforce_article_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.is_sysadmin(auth.uid()) then
    return new;
  end if;

  if new.author_id is distinct from old.author_id then
    raise exception 'Author cannot be changed';
  end if;

  if new.status = 'published' then
    raise exception 'Only a sysadmin can publish an article';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_article_permissions on public.articles;
create trigger enforce_article_permissions
  before update on public.articles
  for each row execute procedure public.enforce_article_permissions();

-- Capture OLD article state before every meaningful update.
create or replace function public.capture_article_version()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if to_jsonb(old) is distinct from to_jsonb(new) then
    insert into public.article_versions (article_id, snapshot, created_by)
    values (old.id, to_jsonb(old), auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists capture_article_version on public.articles;
create trigger capture_article_version
  after update on public.articles
  for each row execute procedure public.capture_article_version();

create or replace function public.audit_article_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid;
  act text;
begin
  target := coalesce(new.id, old.id);

  if tg_op = 'INSERT' then
    act := 'article.created';
  elsif tg_op = 'UPDATE' then
    act := 'article.updated';
  else
    act := 'article.deleted';
  end if;

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (
    auth.uid(),
    act,
    'article',
    target,
    jsonb_build_object(
      'old_status', case when tg_op <> 'INSERT' then old.status::text else null end,
      'new_status', case when tg_op <> 'DELETE' then new.status::text else null end
    )
  );

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

drop trigger if exists audit_article_changes on public.articles;
create trigger audit_article_changes
  after insert or update or delete on public.articles
  for each row execute procedure public.audit_article_change();

create or replace function public.audit_profile_admin_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role is distinct from old.role or new.suspended is distinct from old.suspended then
    insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
    values (
      auth.uid(),
      'profile.admin_changed',
      'profile',
      new.id,
      jsonb_build_object(
        'old_role', old.role::text,
        'new_role', new.role::text,
        'old_suspended', old.suspended,
        'new_suspended', new.suspended
      )
    );
  end if;

  return new;
end;
$$;

drop trigger if exists audit_profile_admin_changes on public.profiles;
create trigger audit_profile_admin_changes
  after update on public.profiles
  for each row execute procedure public.audit_profile_admin_change();

alter table public.profiles enable row level security;
alter table public.articles enable row level security;
alter table public.article_versions enable row level security;
alter table public.audit_logs enable row level security;

-- PROFILES
drop policy if exists "profiles_public_read" on public.profiles;
create policy "profiles_public_read"
  on public.profiles for select
  using (true);

drop policy if exists "profiles_self_update" on public.profiles;
create policy "profiles_self_update"
  on public.profiles for update
  to authenticated
  using (
    (id = auth.uid() and public.is_active_user(auth.uid()))
    or public.is_sysadmin(auth.uid())
  )
  with check (
    (id = auth.uid() and public.is_active_user(auth.uid()))
    or public.is_sysadmin(auth.uid())
  );

-- ARTICLES
drop policy if exists "articles_public_or_author_or_admin_read" on public.articles;
create policy "articles_public_or_author_or_admin_read"
  on public.articles for select
  using (
    status = 'published'
    or author_id = auth.uid()
    or public.is_sysadmin(auth.uid())
  );

drop policy if exists "articles_author_insert" on public.articles;
create policy "articles_author_insert"
  on public.articles for insert
  to authenticated
  with check (
    author_id = auth.uid()
    and public.is_active_user(auth.uid())
    and status in ('draft', 'pending_review')
  );

drop policy if exists "articles_author_or_admin_update" on public.articles;
create policy "articles_author_or_admin_update"
  on public.articles for update
  to authenticated
  using (
    (author_id = auth.uid() and public.is_active_user(auth.uid()))
    or public.is_sysadmin(auth.uid())
  )
  with check (
    (author_id = auth.uid() and public.is_active_user(auth.uid()))
    or public.is_sysadmin(auth.uid())
  );

drop policy if exists "articles_draft_owner_or_admin_delete" on public.articles;
create policy "articles_draft_owner_or_admin_delete"
  on public.articles for delete
  to authenticated
  using (
    (author_id = auth.uid() and status = 'draft' and public.is_active_user(auth.uid()))
    or public.is_sysadmin(auth.uid())
  );

-- ARTICLE VERSIONS
drop policy if exists "versions_author_or_admin_read" on public.article_versions;
create policy "versions_author_or_admin_read"
  on public.article_versions for select
  to authenticated
  using (
    public.is_sysadmin(auth.uid())
    or exists (
      select 1
      from public.articles a
      where a.id = article_versions.article_id
        and a.author_id = auth.uid()
    )
  );

-- No direct insert/update/delete policy for versions: trigger-only writes.

-- AUDIT LOGS
drop policy if exists "audit_admin_read" on public.audit_logs;
create policy "audit_admin_read"
  on public.audit_logs for select
  to authenticated
  using (public.is_sysadmin(auth.uid()));

-- No direct insert/update/delete policy: security-definer triggers write logs.

grant usage on schema public to anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant update (display_name, bio) on public.profiles to authenticated;
grant update (role, suspended) on public.profiles to authenticated;

grant select on public.articles to anon, authenticated;
grant insert, update, delete on public.articles to authenticated;

grant select on public.article_versions to authenticated;
grant select on public.audit_logs to authenticated;

-- IMPORTANT:
-- After creating YOUR OWN account through /register, promote only your account:
--
-- update public.profiles
-- set role = 'sysadmin'
-- where id = (
--   select id from auth.users where email = 'YOUR_EMAIL_HERE'
-- );
--
-- Do not seed any article: the first article should be created inside Zionxyos.
