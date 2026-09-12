-- Zionxyos v0.3 — Production Release
-- Run AFTER 001_initial.sql and 002_wiki_update.sql.
-- No sample articles, categories, tags, article types, or fictional content are created.
-- This migration adds production taxonomy, media, legal consent, roles, settings,
-- moderation capabilities, system/update metadata, and deployment foundations.

begin;

-- Refuse an out-of-order upgrade before v0.3 mutates anything. These columns and
-- tables are introduced by 001_initial.sql and 002_wiki_update.sql respectively.
do $$
begin
  if to_regclass('public.profiles') is null or to_regclass('public.articles') is null then
    raise exception 'Zionxyos v0.3 requires 001_initial.sql before 003_production_release.sql';
  end if;
  if to_regclass('public.article_revisions') is null or to_regclass('public.discussion_posts') is null then
    raise exception 'Zionxyos v0.3 requires 002_wiki_update.sql before 003_production_release.sql';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='articles' and column_name='current_revision_id') then
    raise exception 'Zionxyos v0.3 prerequisite check failed: 002_wiki_update.sql is incomplete';
  end if;
end
$$;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Roles: move profiles.role from the original enum to text so future roles can
-- evolve without enum migration traps. Valid roles are user/admin/sysadmin.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles' and column_name = 'role'
      and udt_name = 'user_role'
  ) then
    alter table public.profiles alter column role drop default;
    alter table public.profiles alter column role type text using role::text;
    alter table public.profiles alter column role set default 'user';
  end if;
end
$$;

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check check (role in ('user', 'admin', 'sysadmin'));

-- Legal consent + account security metadata.
alter table public.profiles
  add column if not exists terms_version text,
  add column if not exists privacy_version text,
  add column if not exists guidelines_version text,
  add column if not exists legal_accepted_at timestamptz,
  add column if not exists mfa_required boolean not null default false;

-- Admins and sysadmins require MFA in the application. Existing sysadmins are
-- deliberately flagged and will be sent through enrollment on their next admin visit.
update public.profiles
set mfa_required = true
where role in ('admin', 'sysadmin');

create table if not exists public.legal_acceptances (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  terms_version text not null,
  privacy_version text not null,
  guidelines_version text not null,
  accepted_at timestamptz not null default now(),
  source text not null default 'web' check (source in ('signup', 'reconsent', 'web')),
  user_agent text,
  metadata jsonb not null default '{}'::jsonb
);
create index if not exists legal_acceptances_user_idx
  on public.legal_acceptances(user_id, accepted_at desc);

-- ---------------------------------------------------------------------------
-- Taxonomy: article types, hierarchical categories, and controlled tags.
-- All are intentionally empty after migration; the sysadmin defines the universe.
-- ---------------------------------------------------------------------------
create table if not exists public.article_types (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  description text check (char_length(description) <= 1000),
  infobox_schema jsonb not null default '[]'::jsonb,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 100),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  description text check (char_length(description) <= 2000),
  parent_id uuid references public.categories(id) on delete restrict,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint categories_not_self_parent check (parent_id is null or parent_id <> id)
);
create index if not exists categories_parent_sort_idx on public.categories(parent_id, sort_order, name);

create table if not exists public.controlled_tags (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  description text check (char_length(description) <= 1000),
  active boolean not null default true,
  sort_order integer not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.articles
  add column if not exists article_type_id uuid references public.article_types(id) on delete set null,
  add column if not exists original_creator text,
  add column if not exists original_creator_user_id uuid references public.profiles(id) on delete set null,
  add column if not exists cover_media_id uuid,
  add column if not exists video_media_id uuid,
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references public.profiles(id) on delete set null;

alter table public.article_revisions
  add column if not exists article_type_id uuid references public.article_types(id) on delete set null,
  add column if not exists original_creator text,
  add column if not exists original_creator_user_id uuid references public.profiles(id) on delete set null,
  add column if not exists cover_media_id uuid,
  add column if not exists video_media_id uuid;

create table if not exists public.article_categories (
  article_id uuid not null references public.articles(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (article_id, category_id)
);
create index if not exists article_categories_category_idx on public.article_categories(category_id, article_id);

create table if not exists public.revision_categories (
  revision_id uuid not null references public.article_revisions(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (revision_id, category_id)
);
create index if not exists revision_categories_category_idx on public.revision_categories(category_id, revision_id);

create table if not exists public.article_tags (
  article_id uuid not null references public.articles(id) on delete cascade,
  tag_id uuid not null references public.controlled_tags(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (article_id, tag_id)
);

create table if not exists public.revision_tags (
  revision_id uuid not null references public.article_revisions(id) on delete cascade,
  tag_id uuid not null references public.controlled_tags(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (revision_id, tag_id)
);

-- Prevent category cycles at the database layer.
create or replace function public.prevent_category_cycle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cursor_id uuid;
begin
  if new.parent_id is null then
    return new;
  end if;
  if new.parent_id = new.id then
    raise exception 'A category cannot be its own parent';
  end if;

  cursor_id := new.parent_id;
  while cursor_id is not null loop
    if cursor_id = new.id then
      raise exception 'Category cycle detected';
    end if;
    select parent_id into cursor_id from public.categories where id = cursor_id;
  end loop;
  return new;
end;
$$;

drop trigger if exists categories_prevent_cycle on public.categories;
create trigger categories_prevent_cycle
  before insert or update of parent_id on public.categories
  for each row execute procedure public.prevent_category_cycle();

-- ---------------------------------------------------------------------------
-- Media + Supabase Storage.
-- ---------------------------------------------------------------------------
create table if not exists public.media_assets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  bucket text not null default 'zionxyos-media',
  object_path text not null unique,
  public_url text not null,
  original_name text not null check (char_length(original_name) <= 255),
  media_kind text not null check (media_kind in ('image', 'video')),
  mime_type text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  alt_text text check (char_length(alt_text) <= 500),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete set null
);
create index if not exists media_assets_owner_created_idx on public.media_assets(owner_id, created_at desc);
create index if not exists media_assets_kind_created_idx on public.media_assets(media_kind, created_at desc);

-- Add media FKs only after the media table exists.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'articles_cover_media_fk') then
    alter table public.articles add constraint articles_cover_media_fk
      foreign key (cover_media_id) references public.media_assets(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'articles_video_media_fk') then
    alter table public.articles add constraint articles_video_media_fk
      foreign key (video_media_id) references public.media_assets(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'revisions_cover_media_fk') then
    alter table public.article_revisions add constraint revisions_cover_media_fk
      foreign key (cover_media_id) references public.media_assets(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'revisions_video_media_fk') then
    alter table public.article_revisions add constraint revisions_video_media_fk
      foreign key (video_media_id) references public.media_assets(id) on delete set null;
  end if;
end
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'zionxyos-media',
  'zionxyos-media',
  true,
  52428800,
  array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/ogg']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- Site configuration, announcements, editorial notices, and system state.
-- ---------------------------------------------------------------------------
create table if not exists public.site_settings (
  key text primary key check (key ~ '^[a-z0-9_]+$'),
  value jsonb not null,
  description text,
  is_public boolean not null default true,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Configuration defaults are platform settings, not universe content.
insert into public.site_settings(key, value, description, is_public) values
  ('site_name', '"Zionxyos"'::jsonb, 'Public site name', true),
  ('tagline', '"The collaborative encyclopedia"'::jsonb, 'Public site tagline', true),
  ('logo_url', '""'::jsonb, 'Optional public logo image URL', true),
  ('favicon_url', '""'::jsonb, 'Optional public favicon URL', true),
  ('default_language', '"en"'::jsonb, 'Public interface language', true),
  ('registration_enabled', 'true'::jsonb, 'Allow new account registration', true),
  ('article_creation_enabled', 'true'::jsonb, 'Allow contributors to create and submit articles', true),
  ('discussion_enabled', 'true'::jsonb, 'Allow article discussions', true),
  ('media_uploads_enabled', 'true'::jsonb, 'Master switch for uploads', true),
  ('image_uploads_enabled', 'true'::jsonb, 'Allow image uploads', true),
  ('video_uploads_enabled', 'true'::jsonb, 'Allow video uploads', true),
  ('max_image_bytes', '10485760'::jsonb, 'Maximum image size: 10 MiB', true),
  ('max_video_bytes', '52428800'::jsonb, 'Maximum video size: 50 MiB', true),
  ('maintenance_mode', 'false'::jsonb, 'Show maintenance page to non-admin visitors', true),
  ('legal_contact_email', '""'::jsonb, 'Contact address displayed in legal pages', true),
  ('release_channel', '"stable"'::jsonb, 'System update channel', false),
  ('release_manifest_url', '""'::jsonb, 'Optional trusted release manifest URL', false)
on conflict (key) do nothing;

create table if not exists public.site_announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 160),
  body text not null check (char_length(body) between 1 and 2000),
  kind text not null default 'info' check (kind in ('info', 'warning', 'maintenance')),
  audience text not null default 'all' check (audience in ('all', 'authenticated', 'staff')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  active boolean not null default true,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notice_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 100),
  body text not null check (char_length(body) between 1 and 1000),
  kind text not null default 'info' check (kind in ('info', 'warning', 'maintenance', 'quality')),
  active boolean not null default true,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.article_notices (
  article_id uuid not null references public.articles(id) on delete cascade,
  notice_id uuid not null references public.notice_templates(id) on delete restrict,
  assigned_by uuid not null references public.profiles(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  primary key (article_id, notice_id)
);

create table if not exists public.system_migrations (
  migration_id text primary key,
  version text not null,
  name text not null,
  checksum text,
  applied_at timestamptz not null default now(),
  applied_by uuid references public.profiles(id) on delete set null,
  status text not null default 'applied' check (status in ('applied', 'failed', 'rolled_back'))
);

insert into public.system_migrations(migration_id, version, name) values
  ('001_initial', '0.1.0', 'Initial schema'),
  ('002_wiki_update', '0.2.0', 'Wiki update')
on conflict (migration_id) do nothing;

create table if not exists public.system_update_history (
  id uuid primary key default gen_random_uuid(),
  requested_by uuid not null references public.profiles(id) on delete restrict,
  action text not null check (action in ('check', 'deploy_hook', 'note')),
  from_version text,
  target_version text,
  status text not null check (status in ('requested', 'success', 'failed', 'informational')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Lightweight DB-backed throttling. Subject values are hashed by the app when
-- they represent an IP address. This is supplemental to Supabase/Vercel limits.
create table if not exists public.rate_limit_events (
  id bigint generated always as identity primary key,
  action text not null,
  subject text not null,
  created_at timestamptz not null default now()
);
create index if not exists rate_limit_lookup_idx on public.rate_limit_events(action, subject, created_at desc);

-- ---------------------------------------------------------------------------
-- Role/capability helpers.
-- ---------------------------------------------------------------------------
create or replace function public.is_sysadmin(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = uid and p.role = 'sysadmin' and p.suspended = false
      and not public.is_blocked(uid)
  );
$$;

create or replace function public.is_admin(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = uid and p.role in ('admin', 'sysadmin') and p.suspended = false
      and not public.is_blocked(uid)
  );
$$;

revoke all on function public.is_admin(uuid) from public;
grant execute on function public.is_admin(uuid) to anon, authenticated;
revoke all on function public.is_sysadmin(uuid) from public;
grant execute on function public.is_sysadmin(uuid) to anon, authenticated;

-- Current legal versions are intentionally explicit. Bump these when the legal
-- text materially changes and users will be asked to re-consent.
create or replace function public.current_legal_versions()
returns table(terms_version text, privacy_version text, guidelines_version text)
language sql
immutable
security definer
set search_path = public
as $$
  select '2026-09-09-v1'::text, '2026-09-09-v1'::text, '2026-09-09-v1'::text;
$$;
grant execute on function public.current_legal_versions() to anon, authenticated;

create or replace function public.has_current_legal_acceptance(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p, public.current_legal_versions() v
    where p.id = uid
      and p.legal_accepted_at is not null
      and p.terms_version = v.terms_version
      and p.privacy_version = v.privacy_version
      and p.guidelines_version = v.guidelines_version
  );
$$;
grant execute on function public.has_current_legal_acceptance(uuid) to authenticated;

create or replace function public.accept_current_legal(source_name text default 'reconsent')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v record;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v from public.current_legal_versions();
  update public.profiles
  set terms_version = v.terms_version,
      privacy_version = v.privacy_version,
      guidelines_version = v.guidelines_version,
      legal_accepted_at = now()
  where id = auth.uid();

  insert into public.legal_acceptances(user_id, terms_version, privacy_version, guidelines_version, source)
  values (auth.uid(), v.terms_version, v.privacy_version, v.guidelines_version,
          case when source_name in ('signup','reconsent','web') then source_name else 'web' end);
end;
$$;
revoke all on function public.accept_current_legal(text) from public;
grant execute on function public.accept_current_legal(text) to authenticated;

-- Rework user creation: reserved names + legal metadata captured from the signup UI.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_username text;
  accepted boolean := false;
  v record;
begin
  select * into v from public.current_legal_versions();
  requested_username := lower(coalesce(new.raw_user_meta_data ->> 'username', 'user_' || left(new.id::text, 8)));

  if requested_username !~ '^[a-z0-9_]{3,24}$'
     or requested_username in ('admin','administrator','root','sysadmin','system','support','moderator','staff','zionxyos','api','security','help') then
    requested_username := 'user_' || left(new.id::text, 8);
  end if;

  if exists (select 1 from public.profiles where username = requested_username) then
    requested_username := left(requested_username, 15) || '_' || left(new.id::text, 8);
  end if;

  accepted := coalesce(new.raw_user_meta_data ->> 'legal_acceptance', '') = 'true'
    and new.raw_user_meta_data ->> 'terms_version' = v.terms_version
    and new.raw_user_meta_data ->> 'privacy_version' = v.privacy_version
    and new.raw_user_meta_data ->> 'guidelines_version' = v.guidelines_version;

  insert into public.profiles (
    id, username, terms_version, privacy_version, guidelines_version, legal_accepted_at
  ) values (
    new.id,
    requested_username,
    case when accepted then v.terms_version else null end,
    case when accepted then v.privacy_version else null end,
    case when accepted then v.guidelines_version else null end,
    case when accepted then now() else null end
  );

  if accepted then
    insert into public.legal_acceptances(user_id, terms_version, privacy_version, guidelines_version, source)
    values (new.id, v.terms_version, v.privacy_version, v.guidelines_version, 'signup');
  end if;
  return new;
end;
$$;

-- Existing accounts are not falsely marked as having accepted new legal text.
-- They will be redirected to /legal/accept after login until they consent.

-- Protect role changes and the singular sysadmin model from normal UI calls.
create or replace function public.protect_profile_privileged_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return new; end if;

  if old.role = 'sysadmin' and new.role is distinct from old.role then
    raise exception 'The protected sysadmin role can only be changed out-of-band';
  end if;

  if new.role = 'sysadmin' and old.role <> 'sysadmin' then
    raise exception 'The sysadmin role cannot be assigned through application sessions';
  end if;

  if not public.is_sysadmin(auth.uid()) then
    if new.role is distinct from old.role or new.suspended is distinct from old.suspended or new.mfa_required is distinct from old.mfa_required then
      raise exception 'Only the sysadmin can change privileged account fields';
    end if;
    if new.username is distinct from old.username then
      raise exception 'Username changes are disabled';
    end if;
  end if;
  return new;
end;
$$;

-- Auto-require MFA whenever a user becomes admin.
create or replace function public.require_mfa_for_privileged_role()
returns trigger
language plpgsql
as $$
begin
  if new.role in ('admin','sysadmin') then new.mfa_required := true; end if;
  return new;
end;
$$;
drop trigger if exists require_mfa_for_privileged_role on public.profiles;
create trigger require_mfa_for_privileged_role
  before insert or update of role on public.profiles
  for each row execute procedure public.require_mfa_for_privileged_role();

-- Active users must be legally accepted for contribution. Reading remains public.
create or replace function public.is_active_user(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = uid and p.suspended = false
      and not public.is_blocked(uid)
  );
$$;

create or replace function public.is_active_contributor(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_active_user(uid)
     and public.has_current_legal_acceptance(uid)
     and not public.is_muted(uid)
     and coalesce((select (value #>> '{}')::boolean from public.site_settings where key = 'article_creation_enabled'), true);
$$;

-- ---------------------------------------------------------------------------
-- Settings/taxonomy/admin RPCs.
-- ---------------------------------------------------------------------------
create or replace function public.sysadmin_set_setting(setting_key text, setting_value jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_sysadmin(auth.uid()) then raise exception 'Sysadmin required'; end if;
  update public.site_settings
  set value = setting_value, updated_by = auth.uid(), updated_at = now()
  where key = setting_key;
  if not found then raise exception 'Unknown setting'; end if;
  insert into public.audit_logs(user_id, action, target_type, metadata)
  values (auth.uid(), 'system.setting_update', 'site_setting', jsonb_build_object('key', setting_key));
end;
$$;
revoke all on function public.sysadmin_set_setting(text, jsonb) from public;
grant execute on function public.sysadmin_set_setting(text, jsonb) to authenticated;

create or replace function public.consume_rate_limit(
  action_name text,
  subject_key text,
  max_events integer,
  window_seconds integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  event_count integer;
begin
  if action_name not in ('register','article_write','report','discussion','media_upload','login') then
    raise exception 'Unsupported rate-limit action';
  end if;
  max_events := greatest(1, least(max_events, 100));
  window_seconds := greatest(60, least(window_seconds, 86400));

  delete from public.rate_limit_events where created_at < now() - interval '2 days';
  select count(*) into event_count
  from public.rate_limit_events
  where action = action_name and subject = subject_key
    and created_at >= now() - make_interval(secs => window_seconds);

  if event_count >= max_events then return false; end if;
  insert into public.rate_limit_events(action, subject) values (action_name, subject_key);
  return true;
end;
$$;
revoke all on function public.consume_rate_limit(text,text,integer,integer) from public;
grant execute on function public.consume_rate_limit(text,text,integer,integer) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Review/moderation RPCs upgraded for admins and normalized taxonomy.
-- ---------------------------------------------------------------------------
create or replace function public.admin_review_revision(
  revision_uuid uuid,
  decision text,
  note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.article_revisions%rowtype;
  a public.articles%rowtype;
  reviewer_role text;
begin
  if not public.is_admin(auth.uid()) then raise exception 'Admin required'; end if;
  select role into reviewer_role from public.profiles where id = auth.uid();

  select * into r from public.article_revisions where id = revision_uuid for update;
  if not found then raise exception 'Revision not found'; end if;
  if r.status <> 'pending_review' then raise exception 'Revision is not awaiting review'; end if;
  if reviewer_role = 'admin' and r.author_id = auth.uid() then raise exception 'Admins cannot review their own revisions'; end if;

  select * into a from public.articles where id = r.article_id for update;

  if decision = 'approve' then
    update public.article_revisions
    set status = 'approved', reviewer_id = auth.uid(), review_note = nullif(trim(note), ''), reviewed_at = now()
    where id = r.id;

    update public.articles
    set title = r.title, summary = r.summary, content = r.content,
        article_type = r.article_type, article_type_id = r.article_type_id,
        category = r.category, categories = r.categories, tags = r.tags,
        cover_image_url = r.cover_image_url, video_url = r.video_url,
        cover_media_id = r.cover_media_id, video_media_id = r.video_media_id,
        infobox = r.infobox,
        original_creator = r.original_creator,
        original_creator_user_id = r.original_creator_user_id,
        status = 'published', current_revision_id = r.id,
        published_at = coalesce(a.published_at, now()), updated_at = now(), deleted_at = null, deleted_by = null
    where id = a.id;

    delete from public.article_categories where article_id = a.id;
    insert into public.article_categories(article_id, category_id)
      select a.id, rc.category_id from public.revision_categories rc where rc.revision_id = r.id
      on conflict do nothing;

    delete from public.article_tags where article_id = a.id;
    insert into public.article_tags(article_id, tag_id)
      select a.id, rt.tag_id from public.revision_tags rt where rt.revision_id = r.id
      on conflict do nothing;

    insert into public.notifications(user_id, kind, title, body, href)
    values (r.author_id, 'revision.approved', 'Your revision was published',
      coalesce(nullif(trim(note), ''), 'The revision was approved by the editorial team.'), '/article/' || a.slug);

    insert into public.notifications(user_id, kind, title, body, href)
    select w.user_id, 'watchlist.article_updated', 'A watched page was updated',
      coalesce(nullif(trim(r.edit_summary), ''), 'A new revision was published.'), '/article/' || a.slug
    from public.watchlist w where w.article_id = a.id and w.user_id <> r.author_id;

  elsif decision = 'changes_requested' then
    update public.article_revisions
    set status = 'changes_requested', reviewer_id = auth.uid(), review_note = nullif(trim(note), ''), reviewed_at = now()
    where id = r.id;
    insert into public.notifications(user_id, kind, title, body, href)
    values (r.author_id, 'revision.changes_requested', 'Changes were requested',
      coalesce(nullif(trim(note), ''), 'An editor requested changes before publication.'),
      '/dashboard/articles/' || a.id || '/edit');

  elsif decision = 'reject' then
    update public.article_revisions
    set status = 'rejected', reviewer_id = auth.uid(), review_note = nullif(trim(note), ''), reviewed_at = now()
    where id = r.id;
    insert into public.notifications(user_id, kind, title, body, href)
    values (r.author_id, 'revision.rejected', 'Your revision was rejected',
      coalesce(nullif(trim(note), ''), 'The revision was not approved.'),
      '/dashboard/articles/' || a.id || '/history');
  else
    raise exception 'Invalid review decision';
  end if;

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (auth.uid(), 'revision.' || decision, 'revision', r.id,
    jsonb_build_object('article_id', r.article_id, 'author_id', r.author_id, 'note', note));
end;
$$;
revoke all on function public.admin_review_revision(uuid, text, text) from public;
grant execute on function public.admin_review_revision(uuid, text, text) to authenticated;

create or replace function public.admin_apply_moderation(
  target_uid uuid,
  action_kind text,
  action_reason text,
  action_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  action_id uuid;
  caller_role text;
  target_role text;
  notification_title text;
begin
  if not public.is_admin(auth.uid()) then raise exception 'Admin required'; end if;
  if target_uid = auth.uid() then raise exception 'You cannot moderate your own account'; end if;
  if action_kind not in ('warning','mute','suspend','ban') then raise exception 'Invalid moderation action'; end if;
  if nullif(trim(action_reason), '') is null then raise exception 'Reason required'; end if;

  select role into caller_role from public.profiles where id = auth.uid();
  select role into target_role from public.profiles where id = target_uid;
  if target_role is null then raise exception 'Target user not found'; end if;
  if target_role = 'sysadmin' then raise exception 'The sysadmin account is protected'; end if;
  if caller_role = 'admin' and target_role <> 'user' then raise exception 'Admins can only moderate regular users'; end if;
  if caller_role = 'admin' and action_kind = 'ban' then raise exception 'Permanent bans require the sysadmin'; end if;

  insert into public.moderation_actions(user_id, kind, reason, created_by, expires_at)
  values (target_uid, action_kind, trim(action_reason), auth.uid(), action_expires_at)
  returning id into action_id;

  notification_title := case action_kind
    when 'warning' then 'Administrative warning'
    when 'mute' then 'Contribution access restricted'
    when 'suspend' then 'Account suspended'
    else 'Account banned' end;
  insert into public.notifications(user_id, kind, title, body, href)
  values (target_uid, 'moderation.' || action_kind, notification_title, trim(action_reason), '/dashboard');
  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (auth.uid(), 'moderation.' || action_kind, 'user', target_uid,
    jsonb_build_object('moderation_action_id', action_id, 'expires_at', action_expires_at, 'reason', action_reason));
  return action_id;
end;
$$;
revoke all on function public.admin_apply_moderation(uuid, text, text, timestamptz) from public;
grant execute on function public.admin_apply_moderation(uuid, text, text, timestamptz) to authenticated;

create or replace function public.admin_revoke_moderation(action_uuid uuid, reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  row_action public.moderation_actions%rowtype;
  caller_role text;
  target_role text;
begin
  if not public.is_admin(auth.uid()) then raise exception 'Admin required'; end if;
  select * into row_action from public.moderation_actions where id = action_uuid for update;
  if not found then raise exception 'Moderation action not found'; end if;
  select role into caller_role from public.profiles where id = auth.uid();
  select role into target_role from public.profiles where id = row_action.user_id;
  if caller_role = 'admin' and target_role <> 'user' then raise exception 'Admins can only moderate regular users'; end if;

  update public.moderation_actions
  set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = nullif(trim(reason), '')
  where id = action_uuid;

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (auth.uid(), 'moderation.revoked', 'user', row_action.user_id,
    jsonb_build_object('moderation_action_id', action_uuid, 'reason', reason));
end;
$$;
revoke all on function public.admin_revoke_moderation(uuid, text) from public;
grant execute on function public.admin_revoke_moderation(uuid, text) to authenticated;

-- Search normalized taxonomy and exclude soft-deleted pages.
-- PostgreSQL cannot change a function's OUT/RETURNS TABLE row type with
-- CREATE OR REPLACE FUNCTION. 002_wiki_update.sql ships earlier versions of
-- these RPCs, so remove those exact signatures before installing the v0.3
-- return shapes. This is safe inside the migration transaction: on any later
-- failure the drops and recreations are rolled back together.
drop function if exists public.wiki_search(text, integer);
drop function if exists public.wiki_category_counts();

create or replace function public.wiki_search(search_text text, max_results integer default 50)
returns table(
  id uuid, title text, slug text, summary text, article_type text, categories text[], tags text[], updated_at timestamptz, rank real
)
language sql
stable
security definer
set search_path = public
as $$
  with q as (select nullif(trim(search_text), '') as term),
  source as (
    select a.*,
      coalesce(array_agg(distinct c.name) filter (where c.id is not null), '{}')::text[] as normalized_categories,
      coalesce(array_agg(distinct t.name) filter (where t.id is not null), '{}')::text[] as normalized_tags
    from public.articles a
    left join public.article_categories ac on ac.article_id = a.id
    left join public.categories c on c.id = ac.category_id and c.active
    left join public.article_tags atg on atg.article_id = a.id
    left join public.controlled_tags t on t.id = atg.tag_id and t.active
    where a.status = 'published' and a.deleted_at is null
    group by a.id
  )
  select s.id, s.title, s.slug, s.summary, s.article_type,
    case when cardinality(s.normalized_categories) > 0 then s.normalized_categories else s.categories end,
    case when cardinality(s.normalized_tags) > 0 then s.normalized_tags else s.tags end,
    s.updated_at,
    (case when lower(s.title) = lower(q.term) then 10 else 0 end
      + case when lower(s.title) like '%' || lower(q.term) || '%' then 5 else 0 end
      + case when coalesce(lower(s.summary),'') like '%' || lower(q.term) || '%' then 2 else 0 end
      + case when lower(s.content) like '%' || lower(q.term) || '%' then 1 else 0 end)::real as rank
  from source s cross join q
  where q.term is not null and (
    lower(s.title) like '%' || lower(q.term) || '%'
    or coalesce(lower(s.summary),'') like '%' || lower(q.term) || '%'
    or lower(s.content) like '%' || lower(q.term) || '%'
    or exists (select 1 from unnest(s.normalized_categories || s.categories) x where lower(x) like '%' || lower(q.term) || '%')
    or exists (select 1 from unnest(s.normalized_tags || s.tags) x where lower(x) like '%' || lower(q.term) || '%')
  )
  order by rank desc, s.title asc
  limit least(greatest(max_results, 1), 100);
$$;
revoke all on function public.wiki_search(text, integer) from public;
grant execute on function public.wiki_search(text, integer) to anon, authenticated;

create or replace function public.wiki_category_counts()
returns table(category_id uuid, category_name text, category_slug text, parent_id uuid, article_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  select c.id, c.name, c.slug, c.parent_id, count(distinct ac.article_id)
  from public.categories c
  left join public.article_categories ac on ac.category_id = c.id
  left join public.articles a on a.id = ac.article_id and a.status = 'published' and a.deleted_at is null
  where c.active
  group by c.id, c.name, c.slug, c.parent_id
  order by c.sort_order, c.name;
$$;
revoke all on function public.wiki_category_counts() from public;
grant execute on function public.wiki_category_counts() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- RLS: taxonomy/media/settings/legal/admin permissions.
-- ---------------------------------------------------------------------------
alter table public.legal_acceptances enable row level security;
alter table public.article_types enable row level security;
alter table public.categories enable row level security;
alter table public.controlled_tags enable row level security;
alter table public.article_categories enable row level security;
alter table public.revision_categories enable row level security;
alter table public.article_tags enable row level security;
alter table public.revision_tags enable row level security;
alter table public.media_assets enable row level security;
alter table public.site_settings enable row level security;
alter table public.site_announcements enable row level security;
alter table public.notice_templates enable row level security;
alter table public.article_notices enable row level security;
alter table public.system_migrations enable row level security;
alter table public.system_update_history enable row level security;
alter table public.rate_limit_events enable row level security;

-- Make the policy portion safe to re-run during development/recovery.
-- (The migration is still intended to be recorded/applied once in production.)
drop policy if exists "legal_acceptance_read" on public.legal_acceptances;
drop policy if exists "article_types_read" on public.article_types;
drop policy if exists "article_types_sysadmin_write" on public.article_types;
drop policy if exists "categories_read" on public.categories;
drop policy if exists "categories_sysadmin_write" on public.categories;
drop policy if exists "controlled_tags_read" on public.controlled_tags;
drop policy if exists "controlled_tags_sysadmin_write" on public.controlled_tags;
drop policy if exists "article_categories_read" on public.article_categories;
drop policy if exists "article_categories_admin_write" on public.article_categories;
drop policy if exists "article_tags_read" on public.article_tags;
drop policy if exists "article_tags_admin_write" on public.article_tags;
drop policy if exists "revision_categories_read" on public.revision_categories;
drop policy if exists "revision_categories_write" on public.revision_categories;
drop policy if exists "revision_tags_read" on public.revision_tags;
drop policy if exists "revision_tags_write" on public.revision_tags;
drop policy if exists "media_read" on public.media_assets;
drop policy if exists "media_insert" on public.media_assets;
drop policy if exists "media_update" on public.media_assets;
drop policy if exists "settings_read" on public.site_settings;
drop policy if exists "settings_sysadmin_write" on public.site_settings;
drop policy if exists "announcements_read" on public.site_announcements;
drop policy if exists "announcements_sysadmin_write" on public.site_announcements;
drop policy if exists "notice_templates_read" on public.notice_templates;
drop policy if exists "notice_templates_sysadmin_write" on public.notice_templates;
drop policy if exists "article_notices_read" on public.article_notices;
drop policy if exists "article_notices_admin_write" on public.article_notices;
drop policy if exists "system_migrations_sysadmin_read" on public.system_migrations;
drop policy if exists "update_history_sysadmin_read" on public.system_update_history;
drop policy if exists "update_history_sysadmin_insert" on public.system_update_history;
drop policy if exists "zionxyos_media_insert" on storage.objects;
drop policy if exists "zionxyos_media_update" on storage.objects;
drop policy if exists "zionxyos_media_delete" on storage.objects;

-- Existing core policies upgraded from sysadmin-only to admin where appropriate.
drop policy if exists "articles_public_or_author_or_admin_read" on public.articles;
create policy "articles_public_or_author_or_admin_read" on public.articles for select
using (
  (status = 'published' and deleted_at is null)
  or author_id = auth.uid()
  or public.is_admin(auth.uid())
);

drop policy if exists "articles_author_or_admin_update" on public.articles;
create policy "articles_author_or_admin_update" on public.articles for update to authenticated
using (
  public.is_admin(auth.uid())
  or (author_id = auth.uid() and status = 'draft' and deleted_at is null and public.is_active_contributor(auth.uid()))
)
with check (
  public.is_admin(auth.uid())
  or (author_id = auth.uid() and status = 'draft' and public.is_active_contributor(auth.uid()))
);

drop policy if exists "articles_draft_owner_or_admin_delete" on public.articles;
create policy "articles_draft_owner_or_admin_delete" on public.articles for delete to authenticated
using (public.is_sysadmin(auth.uid()) or (author_id = auth.uid() and status = 'draft' and public.is_active_contributor(auth.uid())));

drop policy if exists "revisions_public_author_admin_read" on public.article_revisions;
create policy "revisions_public_author_admin_read" on public.article_revisions for select
using (status = 'approved' or author_id = auth.uid() or public.is_admin(auth.uid()));

drop policy if exists "revisions_author_admin_update" on public.article_revisions;
create policy "revisions_author_admin_update" on public.article_revisions for update to authenticated
using (
  public.is_admin(auth.uid())
  or (author_id = auth.uid() and status in ('draft','changes_requested') and public.is_active_contributor(auth.uid()))
)
with check (
  public.is_admin(auth.uid())
  or (author_id = auth.uid() and status in ('draft','pending_review') and public.is_active_contributor(auth.uid()))
);

drop policy if exists "revisions_draft_author_admin_delete" on public.article_revisions;
create policy "revisions_draft_author_admin_delete" on public.article_revisions for delete to authenticated
using (public.is_admin(auth.uid()) or (author_id = auth.uid() and status = 'draft' and public.is_active_contributor(auth.uid())));

drop policy if exists "moderation_own_admin_read" on public.moderation_actions;
create policy "moderation_own_admin_read" on public.moderation_actions for select to authenticated
using (user_id = auth.uid() or public.is_admin(auth.uid()));

drop policy if exists "moderation_admin_insert" on public.moderation_actions;
create policy "moderation_admin_insert" on public.moderation_actions for insert to authenticated
with check (public.is_admin(auth.uid()));

drop policy if exists "moderation_admin_update" on public.moderation_actions;
create policy "moderation_admin_update" on public.moderation_actions for update to authenticated
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

drop policy if exists "admin_notes_admin_all" on public.admin_user_notes;
create policy "admin_notes_admin_all" on public.admin_user_notes for all to authenticated
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

drop policy if exists "notifications_admin_insert" on public.notifications;
create policy "notifications_admin_insert" on public.notifications for insert to authenticated
with check (public.is_admin(auth.uid()));

drop policy if exists "discussion_public_read" on public.discussion_posts;
create policy "discussion_public_read" on public.discussion_posts for select
using (removed_at is null or public.is_admin(auth.uid()));

drop policy if exists "discussion_admin_update" on public.discussion_posts;
create policy "discussion_admin_update" on public.discussion_posts for update to authenticated
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

drop policy if exists "reports_own_admin_read" on public.reports;
create policy "reports_own_admin_read" on public.reports for select to authenticated
using (reporter_id = auth.uid() or public.is_admin(auth.uid()));

drop policy if exists "reports_admin_update" on public.reports;
create policy "reports_admin_update" on public.reports for update to authenticated
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

drop policy if exists "audit_admin_read" on public.audit_logs;
create policy "audit_admin_read" on public.audit_logs for select to authenticated
using (public.is_admin(auth.uid()));

-- Legal history: users can read their own records; admins can audit.
create policy "legal_acceptance_read" on public.legal_acceptances for select to authenticated
using (user_id = auth.uid() or public.is_admin(auth.uid()));

-- Taxonomy: public can read active entries; admins can inspect inactive; only sysadmin mutates.
create policy "article_types_read" on public.article_types for select
using (active or public.is_admin(auth.uid()));
create policy "article_types_sysadmin_write" on public.article_types for all to authenticated
using (public.is_sysadmin(auth.uid())) with check (public.is_sysadmin(auth.uid()));

create policy "categories_read" on public.categories for select
using (active or public.is_admin(auth.uid()));
create policy "categories_sysadmin_write" on public.categories for all to authenticated
using (public.is_sysadmin(auth.uid())) with check (public.is_sysadmin(auth.uid()));

create policy "controlled_tags_read" on public.controlled_tags for select
using (active or public.is_admin(auth.uid()));
create policy "controlled_tags_sysadmin_write" on public.controlled_tags for all to authenticated
using (public.is_sysadmin(auth.uid())) with check (public.is_sysadmin(auth.uid()));

-- Canonical category/tag links are publicly readable only when the article is public.
create policy "article_categories_read" on public.article_categories for select
using (exists (select 1 from public.articles a where a.id = article_id and (a.status = 'published' or a.author_id = auth.uid() or public.is_admin(auth.uid()))));
create policy "article_categories_admin_write" on public.article_categories for all to authenticated
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

create policy "article_tags_read" on public.article_tags for select
using (exists (select 1 from public.articles a where a.id = article_id and (a.status = 'published' or a.author_id = auth.uid() or public.is_admin(auth.uid()))));
create policy "article_tags_admin_write" on public.article_tags for all to authenticated
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- Revision taxonomy follows revision ownership/editorial access.
create policy "revision_categories_read" on public.revision_categories for select
using (exists (select 1 from public.article_revisions r where r.id = revision_id and (r.status = 'approved' or r.author_id = auth.uid() or public.is_admin(auth.uid()))));
create policy "revision_categories_write" on public.revision_categories for all to authenticated
using (exists (select 1 from public.article_revisions r where r.id = revision_id and (public.is_admin(auth.uid()) or (r.author_id = auth.uid() and r.status in ('draft','changes_requested') and public.is_active_contributor(auth.uid())))))
with check (exists (select 1 from public.article_revisions r where r.id = revision_id and (public.is_admin(auth.uid()) or (r.author_id = auth.uid() and r.status in ('draft','changes_requested','pending_review') and public.is_active_contributor(auth.uid())))));

create policy "revision_tags_read" on public.revision_tags for select
using (exists (select 1 from public.article_revisions r where r.id = revision_id and (r.status = 'approved' or r.author_id = auth.uid() or public.is_admin(auth.uid()))));
create policy "revision_tags_write" on public.revision_tags for all to authenticated
using (exists (select 1 from public.article_revisions r where r.id = revision_id and (public.is_admin(auth.uid()) or (r.author_id = auth.uid() and r.status in ('draft','changes_requested') and public.is_active_contributor(auth.uid())))))
with check (exists (select 1 from public.article_revisions r where r.id = revision_id and (public.is_admin(auth.uid()) or (r.author_id = auth.uid() and r.status in ('draft','changes_requested','pending_review') and public.is_active_contributor(auth.uid())))));

-- Media metadata: public can read active assets, owner/admin can inspect own/deleted; users insert own.
create policy "media_read" on public.media_assets for select
using (deleted_at is null or owner_id = auth.uid() or public.is_admin(auth.uid()));
create policy "media_insert" on public.media_assets for insert to authenticated
with check (owner_id = auth.uid() and public.is_active_contributor(auth.uid()));
create policy "media_update" on public.media_assets for update to authenticated
using (owner_id = auth.uid() or public.is_admin(auth.uid()))
with check (owner_id = auth.uid() or public.is_admin(auth.uid()));

-- Settings/announcements.
create policy "settings_read" on public.site_settings for select
using (is_public or public.is_sysadmin(auth.uid()));
create policy "settings_sysadmin_write" on public.site_settings for all to authenticated
using (public.is_sysadmin(auth.uid())) with check (public.is_sysadmin(auth.uid()));

create policy "announcements_read" on public.site_announcements for select
using (
  public.is_sysadmin(auth.uid())
  or (active and starts_at <= now() and (ends_at is null or ends_at > now()) and (audience = 'all' or auth.uid() is not null))
);
create policy "announcements_sysadmin_write" on public.site_announcements for all to authenticated
using (public.is_sysadmin(auth.uid())) with check (public.is_sysadmin(auth.uid()));

create policy "notice_templates_read" on public.notice_templates for select
using (active or public.is_admin(auth.uid()));
create policy "notice_templates_sysadmin_write" on public.notice_templates for all to authenticated
using (public.is_sysadmin(auth.uid())) with check (public.is_sysadmin(auth.uid()));
create policy "article_notices_read" on public.article_notices for select
using (exists (select 1 from public.articles a where a.id = article_id and (a.status='published' or public.is_admin(auth.uid()))));
create policy "article_notices_admin_write" on public.article_notices for all to authenticated
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

create policy "system_migrations_sysadmin_read" on public.system_migrations for select to authenticated
using (public.is_sysadmin(auth.uid()));
create policy "update_history_sysadmin_read" on public.system_update_history for select to authenticated
using (public.is_sysadmin(auth.uid()));
create policy "update_history_sysadmin_insert" on public.system_update_history for insert to authenticated
with check (public.is_sysadmin(auth.uid()) and requested_by = auth.uid());
-- rate_limit_events intentionally has no direct policies; only the definer RPC uses it.

-- Supabase Storage policies. Public bucket bypasses read authorization; writes remain protected.
drop policy if exists "zionxyos_media_insert" on storage.objects;
create policy "zionxyos_media_insert" on storage.objects for insert to authenticated
with check (
  bucket_id = 'zionxyos-media'
  and public.is_active_contributor(auth.uid())
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "zionxyos_media_update" on storage.objects;
create policy "zionxyos_media_update" on storage.objects for update to authenticated
using (
  bucket_id = 'zionxyos-media'
  and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin(auth.uid()))
)
with check (
  bucket_id = 'zionxyos-media'
  and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin(auth.uid()))
);

drop policy if exists "zionxyos_media_delete" on storage.objects;
create policy "zionxyos_media_delete" on storage.objects for delete to authenticated
using (
  bucket_id = 'zionxyos-media'
  and ((storage.foldername(name))[1] = auth.uid()::text or public.is_sysadmin(auth.uid()))
);

-- Grants.
grant select on public.article_types, public.categories, public.controlled_tags to anon, authenticated;
grant insert, update, delete on public.article_types, public.categories, public.controlled_tags to authenticated;
grant select on public.article_categories, public.article_tags to anon, authenticated;
grant insert, update, delete on public.article_categories, public.article_tags to authenticated;
grant select, insert, update, delete on public.revision_categories, public.revision_tags to authenticated;
grant select on public.revision_categories, public.revision_tags to anon;
grant select on public.media_assets to anon, authenticated;
grant insert, update on public.media_assets to authenticated;
grant select on public.site_settings, public.site_announcements, public.notice_templates, public.article_notices to anon, authenticated;
grant insert, update, delete on public.site_settings, public.site_announcements, public.notice_templates, public.article_notices to authenticated;
grant select on public.legal_acceptances, public.system_migrations, public.system_update_history to authenticated;
grant insert on public.system_update_history to authenticated;
grant usage, select on sequence public.legal_acceptances_id_seq to authenticated;

-- Updated-at triggers for new mutable tables.
drop trigger if exists article_types_set_updated_at on public.article_types;
create trigger article_types_set_updated_at before update on public.article_types
  for each row execute procedure public.set_updated_at();
drop trigger if exists categories_set_updated_at on public.categories;
create trigger categories_set_updated_at before update on public.categories
  for each row execute procedure public.set_updated_at();
drop trigger if exists controlled_tags_set_updated_at on public.controlled_tags;
create trigger controlled_tags_set_updated_at before update on public.controlled_tags
  for each row execute procedure public.set_updated_at();
drop trigger if exists announcements_set_updated_at on public.site_announcements;
create trigger announcements_set_updated_at before update on public.site_announcements
  for each row execute procedure public.set_updated_at();
drop trigger if exists notice_templates_set_updated_at on public.notice_templates;
create trigger notice_templates_set_updated_at before update on public.notice_templates
  for each row execute procedure public.set_updated_at();

-- Translate exact v0.2 system-generated strings where they may already exist.
update public.article_revisions set edit_summary = 'Imported from v0.1' where edit_summary = 'Importado da v0.1';

-- Final safety: the migration creates no universe taxonomy/content rows.

-- ---------------------------------------------------------------------------
-- v0.2 mirrored moderation suspensions into profiles.suspended. That boolean has no
-- expiration clock, so a timed suspension could otherwise outlive its moderation
-- action. In v0.3, moderation_actions is the source of truth for timed/permanent
-- moderation and profiles.suspended is reserved for legacy/manual out-of-band
-- account disabling. Clear the mirrored flag only for accounts that have a
-- suspension/ban moderation record; active actions still block through is_blocked().
update public.profiles p
set suspended = false
where p.suspended = true
  and exists (
    select 1 from public.moderation_actions m
    where m.user_id = p.id and m.kind in ('suspend','ban')
  );

-- Production security hardening: privileged writes require an AAL2 (MFA)
-- session at the database layer as well as in the Next.js application.
-- ---------------------------------------------------------------------------
create or replace function public.has_aal2()
returns boolean
language sql
stable
as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;
revoke all on function public.has_aal2() from public;
grant execute on function public.has_aal2() to authenticated;

create or replace function public.is_admin_mfa(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select uid = auth.uid() and public.is_admin(uid) and public.has_aal2();
$$;
revoke all on function public.is_admin_mfa(uuid) from public;
grant execute on function public.is_admin_mfa(uuid) to authenticated;

create or replace function public.is_sysadmin_mfa(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select uid = auth.uid() and public.is_sysadmin(uid) and public.has_aal2();
$$;
revoke all on function public.is_sysadmin_mfa(uuid) from public;
grant execute on function public.is_sysadmin_mfa(uuid) to authenticated;

-- The original v0.1 article trigger predates the admin role. Keep normal-user
-- restrictions, but allow an MFA-authenticated admin/sysadmin to perform
-- canonical editorial maintenance. Publication still happens through the
-- security-definer review RPC for normal workflow.
create or replace function public.enforce_article_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.is_admin_mfa(auth.uid()) then
    return new;
  end if;

  if new.author_id is distinct from old.author_id then
    raise exception 'Article author cannot be changed';
  end if;

  if new.status = 'published' then
    raise exception 'Only the editorial workflow can publish an article';
  end if;

  return new;
end;
$$;

-- Likewise, editors need to be able to adjust/review a submitted revision,
-- but an AAL1 privileged session must not get that power through direct API use.
create or replace function public.enforce_revision_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.is_admin_mfa(auth.uid()) then
    return new;
  end if;

  if not public.is_active_contributor(auth.uid()) then
    raise exception 'Your account cannot contribute right now';
  end if;

  if tg_op = 'INSERT' then
    if new.author_id <> auth.uid() then
      raise exception 'Revision author must be the signed-in user';
    end if;
    if new.status not in ('draft', 'pending_review') then
      raise exception 'Invalid revision status';
    end if;
    if new.reviewer_id is not null or new.reviewed_at is not null then
      raise exception 'Review fields are restricted';
    end if;
    return new;
  end if;

  if old.author_id <> auth.uid() then
    raise exception 'Only the revision author can edit it';
  end if;
  if old.status not in ('draft', 'changes_requested') then
    raise exception 'This revision is no longer editable';
  end if;
  if new.article_id is distinct from old.article_id
     or new.author_id is distinct from old.author_id
     or new.reviewer_id is distinct from old.reviewer_id
     or new.reviewed_at is distinct from old.reviewed_at then
    raise exception 'Restricted revision fields cannot be changed';
  end if;
  if new.status not in ('draft', 'pending_review') then
    raise exception 'Only draft or review submission is allowed';
  end if;
  return new;
end;
$$;

-- Require AAL2 inside privileged RPCs too. This prevents bypassing the server
-- route guards by calling Supabase directly with a privileged AAL1 session.
create or replace function public.sysadmin_set_setting(setting_key text, setting_value jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;
  update public.site_settings
  set value = setting_value, updated_by = auth.uid(), updated_at = now()
  where key = setting_key;
  if not found then raise exception 'Unknown setting'; end if;
  insert into public.audit_logs(user_id, action, target_type, metadata)
  values (auth.uid(), 'system.setting_update', 'site_setting', jsonb_build_object('key', setting_key));
end;
$$;

create or replace function public.admin_review_revision(
  revision_uuid uuid,
  decision text,
  note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.article_revisions%rowtype;
  a public.articles%rowtype;
  reviewer_role text;
begin
  if not public.is_admin_mfa(auth.uid()) then raise exception 'Admin MFA session required'; end if;
  select role into reviewer_role from public.profiles where id = auth.uid();

  select * into r from public.article_revisions where id = revision_uuid for update;
  if not found then raise exception 'Revision not found'; end if;
  if r.status <> 'pending_review' then raise exception 'Revision is not awaiting review'; end if;
  if reviewer_role = 'admin' and r.author_id = auth.uid() then raise exception 'Admins cannot review their own revisions'; end if;
  if decision in ('changes_requested','reject') and nullif(trim(note), '') is null then
    raise exception 'A review note is required for this decision';
  end if;

  select * into a from public.articles where id = r.article_id for update;
  if not found then raise exception 'Canonical article not found'; end if;

  -- Allow this RPC, and only this controlled path, to update canonical/review state
  -- through the table permission triggers.
  perform set_config('zionxyos.review_publish', '1', true);

  if decision = 'approve' then
    update public.article_revisions
    set status = 'approved', reviewer_id = auth.uid(), review_note = nullif(trim(note), ''), reviewed_at = now()
    where id = r.id;

    update public.articles
    set title = r.title, summary = r.summary, content = r.content,
        article_type = r.article_type, article_type_id = r.article_type_id,
        category = r.category, categories = r.categories, tags = r.tags,
        cover_image_url = r.cover_image_url, video_url = r.video_url,
        cover_media_id = r.cover_media_id, video_media_id = r.video_media_id,
        infobox = r.infobox,
        original_creator = r.original_creator,
        original_creator_user_id = r.original_creator_user_id,
        status = 'published', current_revision_id = r.id,
        published_at = coalesce(a.published_at, now()), updated_at = now(),
        deleted_at = null, deleted_by = null
    where id = a.id;

    delete from public.article_categories where article_id = a.id;
    insert into public.article_categories(article_id, category_id)
      select a.id, rc.category_id from public.revision_categories rc where rc.revision_id = r.id
      on conflict do nothing;

    delete from public.article_tags where article_id = a.id;
    insert into public.article_tags(article_id, tag_id)
      select a.id, rt.tag_id from public.revision_tags rt where rt.revision_id = r.id
      on conflict do nothing;

    insert into public.notifications(user_id, kind, title, body, href)
    values (r.author_id, 'revision.approved', 'Your revision was published',
      coalesce(nullif(trim(note), ''), 'The revision was approved by the editorial team.'), '/article/' || a.slug);

    insert into public.notifications(user_id, kind, title, body, href)
    select w.user_id, 'watchlist.article_updated', 'A watched page was updated',
      coalesce(nullif(trim(r.edit_summary), ''), 'A new revision was published.'), '/article/' || a.slug
    from public.watchlist w where w.article_id = a.id and w.user_id <> r.author_id;

  elsif decision = 'changes_requested' then
    update public.article_revisions
    set status = 'changes_requested', reviewer_id = auth.uid(), review_note = trim(note), reviewed_at = now()
    where id = r.id;
    insert into public.notifications(user_id, kind, title, body, href)
    values (r.author_id, 'revision.changes_requested', 'Changes were requested', trim(note),
      '/dashboard/articles/' || a.id || '/edit');

  elsif decision = 'reject' then
    update public.article_revisions
    set status = 'rejected', reviewer_id = auth.uid(), review_note = trim(note), reviewed_at = now()
    where id = r.id;
    insert into public.notifications(user_id, kind, title, body, href)
    values (r.author_id, 'revision.rejected', 'Your revision was rejected', trim(note),
      '/dashboard/articles/' || a.id || '/history');
  else
    raise exception 'Invalid review decision';
  end if;

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (auth.uid(), 'revision.' || decision, 'revision', r.id,
    jsonb_build_object('article_id', r.article_id, 'author_id', r.author_id, 'note', note));
end;
$$;

create or replace function public.admin_apply_moderation(
  target_uid uuid,
  action_kind text,
  action_reason text,
  action_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  action_id uuid;
  caller_role text;
  target_role text;
  notification_title text;
begin
  if not public.is_admin_mfa(auth.uid()) then raise exception 'Admin MFA session required'; end if;
  if target_uid = auth.uid() then raise exception 'You cannot moderate your own account'; end if;
  if action_kind not in ('warning','mute','suspend','ban') then raise exception 'Invalid moderation action'; end if;
  if nullif(trim(action_reason), '') is null then raise exception 'Reason is required'; end if;

  select role into caller_role from public.profiles where id = auth.uid();
  select role into target_role from public.profiles where id = target_uid;
  if target_role is null then raise exception 'Target account not found'; end if;
  if target_role = 'sysadmin' then raise exception 'The sysadmin account is protected'; end if;
  if caller_role = 'admin' and target_role <> 'user' then raise exception 'Admins can only moderate regular users'; end if;
  if caller_role = 'admin' and action_kind = 'ban' then raise exception 'Permanent bans require the sysadmin'; end if;

  insert into public.moderation_actions(user_id, kind, reason, created_by, expires_at)
  values (target_uid, action_kind, trim(action_reason), auth.uid(), action_expires_at)
  returning id into action_id;

  notification_title := case action_kind
    when 'warning' then 'Administrative warning'
    when 'mute' then 'Contribution access restricted'
    when 'suspend' then 'Account suspended'
    else 'Account banned' end;
  insert into public.notifications(user_id, kind, title, body, href)
  values (target_uid, 'moderation.' || action_kind, notification_title, trim(action_reason), '/dashboard');
  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (auth.uid(), 'moderation.' || action_kind, 'user', target_uid,
    jsonb_build_object('moderation_action_id', action_id, 'expires_at', action_expires_at, 'reason', action_reason));
  return action_id;
end;
$$;

create or replace function public.admin_revoke_moderation(action_uuid uuid, reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  row_action public.moderation_actions%rowtype;
  caller_role text;
  target_role text;
begin
  if not public.is_admin_mfa(auth.uid()) then raise exception 'Admin MFA session required'; end if;
  select * into row_action from public.moderation_actions where id = action_uuid for update;
  if not found then raise exception 'Moderation action not found'; end if;
  select role into caller_role from public.profiles where id = auth.uid();
  select role into target_role from public.profiles where id = row_action.user_id;
  if target_role = 'sysadmin' then raise exception 'The sysadmin account is protected'; end if;
  if caller_role = 'admin' and target_role <> 'user' then raise exception 'Admins can only moderate regular users'; end if;

  update public.moderation_actions
  set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = nullif(trim(reason), '')
  where id = action_uuid;

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (auth.uid(), 'moderation.revoked', 'user', row_action.user_id,
    jsonb_build_object('moderation_action_id', action_uuid, 'reason', reason));
end;
$$;

-- Privileged direct table access also requires AAL2. Public/self access remains unchanged.
drop policy if exists "profiles_self_update" on public.profiles;
create policy "profiles_self_update" on public.profiles for update to authenticated
using (
  (id = auth.uid() and public.is_active_user(auth.uid()))
  or public.is_sysadmin_mfa(auth.uid())
)
with check (
  (id = auth.uid() and public.is_active_user(auth.uid()))
  or public.is_sysadmin_mfa(auth.uid())
);

drop policy if exists "articles_public_or_author_or_admin_read" on public.articles;
create policy "articles_public_or_author_or_admin_read" on public.articles for select
using ((status = 'published' and deleted_at is null) or author_id = auth.uid() or public.is_admin_mfa(auth.uid()));

drop policy if exists "articles_author_or_admin_update" on public.articles;
create policy "articles_author_or_admin_update" on public.articles for update to authenticated
using (
  public.is_admin_mfa(auth.uid())
  or (author_id = auth.uid() and status = 'draft' and deleted_at is null and public.is_active_contributor(auth.uid()))
)
with check (
  public.is_admin_mfa(auth.uid())
  or (author_id = auth.uid() and status = 'draft' and public.is_active_contributor(auth.uid()))
);

drop policy if exists "articles_draft_owner_or_admin_delete" on public.articles;
create policy "articles_draft_owner_or_admin_delete" on public.articles for delete to authenticated
using (public.is_sysadmin_mfa(auth.uid()) or (author_id = auth.uid() and status = 'draft' and public.is_active_contributor(auth.uid())));

drop policy if exists "revisions_public_author_admin_read" on public.article_revisions;
create policy "revisions_public_author_admin_read" on public.article_revisions for select
using (status = 'approved' or author_id = auth.uid() or public.is_admin_mfa(auth.uid()));

drop policy if exists "revisions_author_admin_update" on public.article_revisions;
create policy "revisions_author_admin_update" on public.article_revisions for update to authenticated
using (
  public.is_admin_mfa(auth.uid())
  or (author_id = auth.uid() and status in ('draft','changes_requested') and public.is_active_contributor(auth.uid()))
)
with check (
  public.is_admin_mfa(auth.uid())
  or (author_id = auth.uid() and status in ('draft','pending_review') and public.is_active_contributor(auth.uid()))
);

drop policy if exists "revisions_draft_author_admin_delete" on public.article_revisions;
create policy "revisions_draft_author_admin_delete" on public.article_revisions for delete to authenticated
using (public.is_admin_mfa(auth.uid()) or (author_id = auth.uid() and status = 'draft' and public.is_active_contributor(auth.uid())));

drop policy if exists "moderation_own_admin_read" on public.moderation_actions;
create policy "moderation_own_admin_read" on public.moderation_actions for select to authenticated
using (user_id = auth.uid() or public.is_admin_mfa(auth.uid()));
drop policy if exists "moderation_admin_insert" on public.moderation_actions;
create policy "moderation_admin_insert" on public.moderation_actions for insert to authenticated with check (public.is_admin_mfa(auth.uid()));
drop policy if exists "moderation_admin_update" on public.moderation_actions;
create policy "moderation_admin_update" on public.moderation_actions for update to authenticated using (public.is_admin_mfa(auth.uid())) with check (public.is_admin_mfa(auth.uid()));

drop policy if exists "admin_notes_admin_all" on public.admin_user_notes;
create policy "admin_notes_admin_all" on public.admin_user_notes for all to authenticated
using (public.is_admin_mfa(auth.uid())) with check (public.is_admin_mfa(auth.uid()));

drop policy if exists "notifications_admin_insert" on public.notifications;
create policy "notifications_admin_insert" on public.notifications for insert to authenticated with check (public.is_admin_mfa(auth.uid()));

drop policy if exists "discussion_public_read" on public.discussion_posts;
create policy "discussion_public_read" on public.discussion_posts for select
using (removed_at is null or public.is_admin_mfa(auth.uid()));
drop policy if exists "discussion_admin_update" on public.discussion_posts;
create policy "discussion_admin_update" on public.discussion_posts for update to authenticated
using (public.is_admin_mfa(auth.uid())) with check (public.is_admin_mfa(auth.uid()));

drop policy if exists "reports_own_admin_read" on public.reports;
create policy "reports_own_admin_read" on public.reports for select to authenticated
using (reporter_id = auth.uid() or public.is_admin_mfa(auth.uid()));
drop policy if exists "reports_admin_update" on public.reports;
create policy "reports_admin_update" on public.reports for update to authenticated
using (public.is_admin_mfa(auth.uid())) with check (public.is_admin_mfa(auth.uid()));

drop policy if exists "audit_admin_read" on public.audit_logs;
create policy "audit_admin_read" on public.audit_logs for select to authenticated using (public.is_admin_mfa(auth.uid()));

drop policy if exists "legal_acceptance_read" on public.legal_acceptances;
create policy "legal_acceptance_read" on public.legal_acceptances for select to authenticated
using (user_id = auth.uid() or public.is_admin_mfa(auth.uid()));

drop policy if exists "article_types_read" on public.article_types;
create policy "article_types_read" on public.article_types for select using (active or public.is_admin_mfa(auth.uid()));
drop policy if exists "article_types_sysadmin_write" on public.article_types;
create policy "article_types_sysadmin_write" on public.article_types for all to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "categories_read" on public.categories;
create policy "categories_read" on public.categories for select using (active or public.is_admin_mfa(auth.uid()));
drop policy if exists "categories_sysadmin_write" on public.categories;
create policy "categories_sysadmin_write" on public.categories for all to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "controlled_tags_read" on public.controlled_tags;
create policy "controlled_tags_read" on public.controlled_tags for select using (active or public.is_admin_mfa(auth.uid()));
drop policy if exists "controlled_tags_sysadmin_write" on public.controlled_tags;
create policy "controlled_tags_sysadmin_write" on public.controlled_tags for all to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "article_categories_read" on public.article_categories;
create policy "article_categories_read" on public.article_categories for select
using (exists (select 1 from public.articles a where a.id = article_id and (a.status = 'published' or a.author_id = auth.uid() or public.is_admin_mfa(auth.uid()))));
drop policy if exists "article_categories_admin_write" on public.article_categories;
create policy "article_categories_admin_write" on public.article_categories for all to authenticated
using (public.is_admin_mfa(auth.uid())) with check (public.is_admin_mfa(auth.uid()));

drop policy if exists "article_tags_read" on public.article_tags;
create policy "article_tags_read" on public.article_tags for select
using (exists (select 1 from public.articles a where a.id = article_id and (a.status = 'published' or a.author_id = auth.uid() or public.is_admin_mfa(auth.uid()))));
drop policy if exists "article_tags_admin_write" on public.article_tags;
create policy "article_tags_admin_write" on public.article_tags for all to authenticated
using (public.is_admin_mfa(auth.uid())) with check (public.is_admin_mfa(auth.uid()));

drop policy if exists "revision_categories_read" on public.revision_categories;
create policy "revision_categories_read" on public.revision_categories for select
using (exists (select 1 from public.article_revisions r where r.id = revision_id and (r.status = 'approved' or r.author_id = auth.uid() or public.is_admin_mfa(auth.uid()))));
drop policy if exists "revision_categories_write" on public.revision_categories;
create policy "revision_categories_write" on public.revision_categories for all to authenticated
using (exists (select 1 from public.article_revisions r where r.id = revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id = auth.uid() and r.status in ('draft','changes_requested') and public.is_active_contributor(auth.uid())))))
with check (exists (select 1 from public.article_revisions r where r.id = revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id = auth.uid() and r.status in ('draft','changes_requested','pending_review') and public.is_active_contributor(auth.uid())))));

drop policy if exists "revision_tags_read" on public.revision_tags;
create policy "revision_tags_read" on public.revision_tags for select
using (exists (select 1 from public.article_revisions r where r.id = revision_id and (r.status = 'approved' or r.author_id = auth.uid() or public.is_admin_mfa(auth.uid()))));
drop policy if exists "revision_tags_write" on public.revision_tags;
create policy "revision_tags_write" on public.revision_tags for all to authenticated
using (exists (select 1 from public.article_revisions r where r.id = revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id = auth.uid() and r.status in ('draft','changes_requested') and public.is_active_contributor(auth.uid())))))
with check (exists (select 1 from public.article_revisions r where r.id = revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id = auth.uid() and r.status in ('draft','changes_requested','pending_review') and public.is_active_contributor(auth.uid())))));

drop policy if exists "media_read" on public.media_assets;
create policy "media_read" on public.media_assets for select
using (deleted_at is null or owner_id = auth.uid() or public.is_admin_mfa(auth.uid()));
drop policy if exists "media_update" on public.media_assets;
create policy "media_update" on public.media_assets for update to authenticated
using (owner_id = auth.uid() or public.is_sysadmin_mfa(auth.uid()))
with check (owner_id = auth.uid() or public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "settings_read" on public.site_settings;
create policy "settings_read" on public.site_settings for select
using (is_public or public.is_sysadmin_mfa(auth.uid()));
drop policy if exists "settings_sysadmin_write" on public.site_settings;
create policy "settings_sysadmin_write" on public.site_settings for all to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "announcements_read" on public.site_announcements;
create policy "announcements_read" on public.site_announcements for select
using (
  public.is_sysadmin_mfa(auth.uid())
  or (
    active and starts_at <= now() and (ends_at is null or ends_at > now())
    and (
      audience = 'all'
      or (audience = 'authenticated' and auth.uid() is not null)
      or (audience = 'staff' and public.is_admin_mfa(auth.uid()))
    )
  )
);
drop policy if exists "announcements_sysadmin_write" on public.site_announcements;
create policy "announcements_sysadmin_write" on public.site_announcements for all to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "notice_templates_read" on public.notice_templates;
create policy "notice_templates_read" on public.notice_templates for select
using (active or public.is_admin_mfa(auth.uid()));
drop policy if exists "notice_templates_sysadmin_write" on public.notice_templates;
create policy "notice_templates_sysadmin_write" on public.notice_templates for all to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));
drop policy if exists "article_notices_read" on public.article_notices;
create policy "article_notices_read" on public.article_notices for select
using (exists (select 1 from public.articles a where a.id = article_id and (a.status='published' or public.is_admin_mfa(auth.uid()))));
drop policy if exists "article_notices_admin_write" on public.article_notices;
create policy "article_notices_admin_write" on public.article_notices for all to authenticated
using (public.is_admin_mfa(auth.uid())) with check (public.is_admin_mfa(auth.uid()));

drop policy if exists "system_migrations_sysadmin_read" on public.system_migrations;
create policy "system_migrations_sysadmin_read" on public.system_migrations for select to authenticated using (public.is_sysadmin_mfa(auth.uid()));
drop policy if exists "update_history_sysadmin_read" on public.system_update_history;
create policy "update_history_sysadmin_read" on public.system_update_history for select to authenticated using (public.is_sysadmin_mfa(auth.uid()));
drop policy if exists "update_history_sysadmin_insert" on public.system_update_history;
create policy "update_history_sysadmin_insert" on public.system_update_history for insert to authenticated
with check (public.is_sysadmin_mfa(auth.uid()) and requested_by = auth.uid());

-- Storage writes by staff require MFA. Contributors may still manage only their own folder.
drop policy if exists "zionxyos_media_update" on storage.objects;
create policy "zionxyos_media_update" on storage.objects for update to authenticated
using (
  bucket_id = 'zionxyos-media'
  and ((storage.foldername(name))[1] = auth.uid()::text or public.is_sysadmin_mfa(auth.uid()))
)
with check (
  bucket_id = 'zionxyos-media'
  and ((storage.foldername(name))[1] = auth.uid()::text or public.is_sysadmin_mfa(auth.uid()))
);
drop policy if exists "zionxyos_media_delete" on storage.objects;
create policy "zionxyos_media_delete" on storage.objects for delete to authenticated
using (
  bucket_id = 'zionxyos-media'
  and ((storage.foldername(name))[1] = auth.uid()::text or public.is_sysadmin_mfa(auth.uid()))
);

-- Bound authenticated contribution limits to the authenticated account rather
-- than trusting a caller-supplied subject key. Anonymous login/register limits
-- remain keyed by the application's hashed network subject.
create or replace function public.consume_rate_limit(
  action_name text,
  subject_key text,
  max_events integer,
  window_seconds integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  event_count integer;
  effective_subject text;
begin
  if action_name not in ('register','article_write','report','discussion','media_upload','login') then
    raise exception 'Unsupported rate-limit action';
  end if;
  max_events := greatest(1, least(max_events, 100));
  window_seconds := greatest(60, least(window_seconds, 86400));
  effective_subject := subject_key;
  if auth.uid() is not null and action_name in ('article_write','report','discussion','media_upload') then
    effective_subject := auth.uid()::text;
  end if;

  delete from public.rate_limit_events where created_at < now() - interval '2 days';
  select count(*) into event_count
  from public.rate_limit_events
  where action = action_name and subject = effective_subject
    and created_at >= now() - make_interval(secs => window_seconds);

  if event_count >= max_events then return false; end if;
  insert into public.rate_limit_events(action, subject) values (action_name, effective_subject);
  return true;
end;
$$;

-- Restrict direct admin table writes to the capabilities the UI exposes.
-- Publishing/review transitions are permitted only while admin_review_revision()
-- has set the transaction-local zionxyos.review_publish marker.
create or replace function public.enforce_article_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  review_publish boolean := coalesce(current_setting('zionxyos.review_publish', true), '') = '1';
begin
  if auth.uid() is null then return new; end if;
  if public.is_sysadmin_mfa(auth.uid()) then return new; end if;
  if review_publish and public.is_admin_mfa(auth.uid()) then return new; end if;

  if public.is_admin_mfa(auth.uid()) then
    if (to_jsonb(new) - array['featured','protection_level','protection_reason','protected_until','updated_at']::text[])
       is distinct from
       (to_jsonb(old) - array['featured','protection_level','protection_reason','protected_until','updated_at']::text[]) then
      raise exception 'Admins may only change page protection and featured status outside the review workflow';
    end if;
    return new;
  end if;

  if new.author_id is distinct from old.author_id then raise exception 'Article author cannot be changed'; end if;
  if new.status = 'published' then raise exception 'Only the editorial workflow can publish an article'; end if;
  return new;
end;
$$;

create or replace function public.enforce_revision_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  review_publish boolean := coalesce(current_setting('zionxyos.review_publish', true), '') = '1';
begin
  if auth.uid() is null then return new; end if;
  if public.is_sysadmin_mfa(auth.uid()) then return new; end if;
  if review_publish and public.is_admin_mfa(auth.uid()) then return new; end if;

  if not public.is_active_contributor(auth.uid()) then
    raise exception 'Your account cannot contribute right now';
  end if;

  if tg_op = 'INSERT' then
    if new.author_id <> auth.uid() then raise exception 'Revision author must be the signed-in user'; end if;
    if new.status not in ('draft', 'pending_review') then raise exception 'Invalid revision status'; end if;
    if new.reviewer_id is not null or new.reviewed_at is not null then raise exception 'Review fields are restricted'; end if;
    return new;
  end if;

  -- An editor may correct the content of somebody else's pending revision before
  -- making a decision, but cannot alter ownership or review state directly.
  if public.is_admin_mfa(auth.uid()) and old.status = 'pending_review' then
    if new.article_id is distinct from old.article_id
       or new.author_id is distinct from old.author_id
       or new.status is distinct from old.status
       or new.reviewer_id is distinct from old.reviewer_id
       or new.review_note is distinct from old.review_note
       or new.submitted_at is distinct from old.submitted_at
       or new.reviewed_at is distinct from old.reviewed_at then
      raise exception 'Pending revision ownership and review state are restricted';
    end if;
    return new;
  end if;

  if old.author_id <> auth.uid() then raise exception 'Only the revision author can edit it'; end if;
  if old.status not in ('draft', 'changes_requested') then raise exception 'This revision is no longer editable'; end if;
  if new.article_id is distinct from old.article_id
     or new.author_id is distinct from old.author_id
     or new.reviewer_id is distinct from old.reviewer_id
     or new.reviewed_at is distinct from old.reviewed_at then
    raise exception 'Restricted revision fields cannot be changed';
  end if;
  if new.status not in ('draft', 'pending_review') then raise exception 'Only draft or review submission is allowed'; end if;
  return new;
end;
$$;

-- Keep administrative resolution/removal operations from rewriting the original
-- community record through direct PostgREST calls.
create or replace function public.enforce_report_admin_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return new; end if;
  if not public.is_admin_mfa(auth.uid()) then raise exception 'Admin MFA session required'; end if;
  if (to_jsonb(new) - array['status','reviewed_by','reviewed_at','resolution_note']::text[])
     is distinct from
     (to_jsonb(old) - array['status','reviewed_by','reviewed_at','resolution_note']::text[]) then
    raise exception 'Report identity and submitted content are immutable';
  end if;
  if new.reviewed_by is distinct from auth.uid() then raise exception 'reviewed_by must be the current administrator'; end if;
  return new;
end;
$$;
drop trigger if exists reports_enforce_admin_update on public.reports;
create trigger reports_enforce_admin_update before update on public.reports
for each row execute procedure public.enforce_report_admin_update();

create or replace function public.enforce_discussion_admin_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return new; end if;
  if not public.is_admin_mfa(auth.uid()) then raise exception 'Admin MFA session required'; end if;
  if (to_jsonb(new) - array['removed_at','removed_by']::text[])
     is distinct from
     (to_jsonb(old) - array['removed_at','removed_by']::text[]) then
    raise exception 'Discussion content and authorship are immutable';
  end if;
  if new.removed_at is not null and new.removed_by is distinct from auth.uid() then
    raise exception 'removed_by must be the current administrator';
  end if;
  return new;
end;
$$;
drop trigger if exists discussion_enforce_admin_update on public.discussion_posts;
create trigger discussion_enforce_admin_update before update on public.discussion_posts
for each row execute procedure public.enforce_discussion_admin_update();

-- Moderation writes must pass through the RPCs above; direct table writes could
-- otherwise bypass target-role and permanent-ban rules.
drop policy if exists "moderation_admin_insert" on public.moderation_actions;
drop policy if exists "moderation_admin_update" on public.moderation_actions;

-- Internal notes are append-only from the administration UI.
drop policy if exists "admin_notes_admin_all" on public.admin_user_notes;
drop policy if exists "admin_notes_admin_read" on public.admin_user_notes;
drop policy if exists "admin_notes_admin_insert" on public.admin_user_notes;
create policy "admin_notes_admin_read" on public.admin_user_notes for select to authenticated
using (public.is_admin_mfa(auth.uid()));
create policy "admin_notes_admin_insert" on public.admin_user_notes for insert to authenticated
with check (public.is_admin_mfa(auth.uid()) and created_by = auth.uid());

-- Media metadata and Storage objects are immutable to contributors after upload.
-- Only the sysadmin can retire/remove an asset, which prevents direct Storage API
-- calls from orphaning article media metadata.
drop policy if exists "media_update" on public.media_assets;
create policy "media_update" on public.media_assets for update to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "zionxyos_media_update" on storage.objects;
drop policy if exists "zionxyos_media_delete" on storage.objects;
create policy "zionxyos_media_delete" on storage.objects for delete to authenticated
using (bucket_id = 'zionxyos-media' and public.is_sysadmin_mfa(auth.uid()));

-- Keep exact system-generated legacy messages English after upgrading an
-- existing v0.2 database. User-authored text is never rewritten.
update public.notifications set title = 'Your revision was published' where title = 'Sua revisão foi publicada';
update public.notifications set body = 'The revision was approved by the editorial team.' where body = 'A revisão foi aprovada pela administração.';
update public.notifications set title = 'A watched page was updated' where title = 'Uma página acompanhada foi atualizada';
update public.notifications set body = 'A new revision was published.' where body = 'Uma nova revisão foi incorporada à página.';
update public.notifications set title = 'Changes were requested' where title = 'Alterações foram solicitadas';
update public.notifications set body = 'An editor requested changes before publication.' where body = 'A administração pediu alterações antes da publicação.';
update public.notifications set title = 'Your revision was rejected' where title = 'Sua revisão foi rejeitada';
update public.notifications set body = 'The revision was not approved.' where body = 'A revisão não foi aprovada.';
update public.notifications set title = 'Administrative warning' where title = 'Aviso da administração';
update public.notifications set title = 'Contribution access restricted' where title = 'Sua conta foi silenciada';
update public.notifications set title = 'Account suspended' where title = 'Sua conta foi suspensa';
update public.notifications set title = 'Account banned' where title = 'Sua conta foi banida';


-- ---------------------------------------------------------------------------
-- FINAL v0.3 PRODUCTION HARDENING
-- This block intentionally comes last so it replaces permissive compatibility
-- policies from v0.1/v0.2 while preserving their data.
-- ---------------------------------------------------------------------------

-- Zionxyos has exactly one protected sysadmin account. The migration fails
-- loudly if a legacy database violates this invariant instead of choosing one.
create unique index if not exists profiles_single_sysadmin_idx
  on public.profiles ((role)) where role = 'sysadmin';

-- Upload limits are operational information, not secrets, and the browser editor
-- needs the live values in order to provide accurate pre-upload validation.
update public.site_settings set is_public = true
where key in ('max_image_bytes', 'max_video_bytes');

-- Public profile surface: only directory/attribution fields are exposed. The
-- underlying profiles table is no longer anonymously selectable.
drop view if exists public.public_profiles;
create view public.public_profiles
with (security_barrier = true)
as
select id, username, display_name, bio, created_at, updated_at
from public.profiles;
revoke all on public.public_profiles from public, anon, authenticated;
grant select on public.public_profiles to anon, authenticated;

revoke select on public.profiles from anon;
drop policy if exists "profiles_public_read" on public.profiles;
drop policy if exists "profiles_self_or_admin_read" on public.profiles;
create policy "profiles_self_or_admin_read" on public.profiles for select to authenticated
using (id = auth.uid() or public.is_admin_mfa(auth.uid()));

-- Base contribution eligibility is independent from individual feature switches.
create or replace function public.is_active_contributor(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select uid = auth.uid()
     and public.is_active_user(uid)
     and public.has_current_legal_acceptance(uid)
     and not public.is_muted(uid);
$$;
revoke all on function public.is_active_contributor(uuid) from public, anon, authenticated;
grant execute on function public.is_active_contributor(uuid) to authenticated;

create or replace function public.can_write_articles(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_active_contributor(uid)
     and coalesce((select (value #>> '{}')::boolean from public.site_settings where key = 'article_creation_enabled'), true);
$$;
revoke all on function public.can_write_articles(uuid) from public, anon, authenticated;
grant execute on function public.can_write_articles(uuid) to authenticated;

-- Strict setting validation. Browser clients cannot invent keys, exceed the
-- Storage hard cap, change JSON types, or configure non-HTTPS release URLs.
create or replace function public.sysadmin_set_setting(setting_key text, setting_value jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  text_value text;
  number_value numeric;
begin
  if not public.is_sysadmin_mfa(auth.uid()) then
    raise exception 'Sysadmin MFA session required';
  end if;

  if setting_key not in (
    'site_name','tagline','logo_url','favicon_url','default_language',
    'registration_enabled','article_creation_enabled','discussion_enabled',
    'media_uploads_enabled','image_uploads_enabled','video_uploads_enabled',
    'max_image_bytes','max_video_bytes','maintenance_mode','legal_contact_email',
    'release_channel','release_manifest_url'
  ) then
    raise exception 'Unknown or immutable system setting';
  end if;

  if setting_key in ('registration_enabled','article_creation_enabled','discussion_enabled','media_uploads_enabled','image_uploads_enabled','video_uploads_enabled','maintenance_mode') then
    if jsonb_typeof(setting_value) <> 'boolean' then raise exception 'Boolean setting required'; end if;
  elsif setting_key in ('max_image_bytes','max_video_bytes') then
    if jsonb_typeof(setting_value) <> 'number' then raise exception 'Numeric setting required'; end if;
    number_value := (setting_value #>> '{}')::numeric;
    if number_value <> trunc(number_value) or number_value < 1048576 or number_value > 52428800 then
      raise exception 'Media limit must be an integer between 1 MiB and 50 MiB';
    end if;
  else
    if jsonb_typeof(setting_value) <> 'string' then raise exception 'Text setting required'; end if;
    text_value := setting_value #>> '{}';
    if setting_key = 'site_name' and char_length(text_value) not between 1 and 100 then raise exception 'Invalid site name'; end if;
    if setting_key = 'tagline' and char_length(text_value) > 200 then raise exception 'Tagline is too long'; end if;
    if setting_key = 'default_language' and text_value <> 'en' then raise exception 'v0.3 supports English UI only'; end if;
    if setting_key = 'release_channel' and text_value not in ('stable','beta','development') then raise exception 'Invalid release channel'; end if;
    if setting_key in ('logo_url','favicon_url','release_manifest_url') and text_value <> '' and text_value !~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' then raise exception 'URL must be a non-empty HTTPS URL'; end if;
    if setting_key = 'legal_contact_email' and (char_length(text_value) > 320 or (text_value <> '' and text_value !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')) then raise exception 'Invalid legal contact email'; end if;
  end if;

  update public.site_settings
  set value = setting_value, updated_by = auth.uid(), updated_at = now()
  where key = setting_key;
  if not found then raise exception 'Setting does not exist'; end if;

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (auth.uid(), 'system_setting_update', 'site_setting', null, jsonb_build_object('key', setting_key));
end;
$$;
revoke all on function public.sysadmin_set_setting(text, jsonb) from public, anon, authenticated;
grant execute on function public.sysadmin_set_setting(text, jsonb) to authenticated;

-- Rate-limit RPC hardening: anonymous callers may only use login/register with
-- the server-generated SHA-256 network subject. Signed-in contribution limits
-- always bind to auth.uid() regardless of a caller-supplied subject.
create or replace function public.consume_rate_limit(
  action_name text,
  subject_key text,
  max_events integer,
  window_seconds integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  event_count integer;
  effective_subject text;
begin
  if action_name not in ('register','login','password_reset','article_write','report','discussion','media_upload') then
    raise exception 'Unsupported rate-limit action';
  end if;
  max_events := greatest(1, least(max_events, 100));
  window_seconds := greatest(60, least(window_seconds, 86400));

  if auth.uid() is null then
    if action_name not in ('register','login','password_reset') then raise exception 'Authentication required'; end if;
    if subject_key !~ '^[a-f0-9]{64}$' then raise exception 'Invalid anonymous rate-limit subject'; end if;
    effective_subject := subject_key;
  else
    if action_name in ('register','login','password_reset') then raise exception 'Anonymous rate-limit action expected'; end if;
    effective_subject := auth.uid()::text;
  end if;

  delete from public.rate_limit_events where created_at < now() - interval '2 days';
  select count(*) into event_count from public.rate_limit_events
  where action = action_name and subject = effective_subject
    and created_at >= now() - make_interval(secs => window_seconds);
  if event_count >= max_events then return false; end if;
  insert into public.rate_limit_events(action, subject) values (action_name, effective_subject);
  return true;
end;
$$;
revoke all on function public.consume_rate_limit(text,text,integer,integer) from public, anon, authenticated;
grant execute on function public.consume_rate_limit(text,text,integer,integer) to anon, authenticated;

-- Public helper functions respect v0.3 soft deletion.
create or replace function public.wiki_resolve_links(targets text[])
returns table(title text, slug text)
language sql stable security definer set search_path = public
as $$
  select a.title, a.slug from public.articles a
  where a.status = 'published' and a.deleted_at is null
    and exists (
      select 1
      from unnest((coalesce(targets, '{}'::text[]))[1:200]) wanted(value)
      where lower(left(trim(wanted.value),160)) = lower(a.title)
    );
$$;
revoke all on function public.wiki_resolve_links(text[]) from public, anon, authenticated;
grant execute on function public.wiki_resolve_links(text[]) to anon, authenticated;

create or replace function public.random_published_article()
returns text
language sql volatile security definer set search_path = public
as $$
  select a.slug from public.articles a
  where a.status = 'published' and a.deleted_at is null
  order by random() limit 1;
$$;
revoke all on function public.random_published_article() from public, anon, authenticated;
grant execute on function public.random_published_article() to anon, authenticated;

create or replace function public.wiki_search(search_text text, max_results integer default 50)
returns table(id uuid,title text,slug text,summary text,article_type text,categories text[],tags text[],updated_at timestamptz,rank real)
language sql stable security definer set search_path = public
as $$
  with q as (select nullif(left(trim(search_text),200),'') term), source as (
    select a.*, p.username author_username, p.display_name author_display_name,
      coalesce(array_agg(distinct c.name) filter (where c.id is not null), '{}')::text[] normalized_categories,
      coalesce(array_agg(distinct t.name) filter (where t.id is not null), '{}')::text[] normalized_tags
    from public.articles a
    left join public.profiles p on p.id = a.author_id
    left join public.article_categories ac on ac.article_id = a.id
    left join public.categories c on c.id = ac.category_id and c.active
    left join public.article_tags atg on atg.article_id = a.id
    left join public.controlled_tags t on t.id = atg.tag_id and t.active
    where a.status = 'published' and a.deleted_at is null
    group by a.id,p.username,p.display_name
  )
  select s.id,s.title,s.slug,s.summary,s.article_type,
    case when cardinality(s.normalized_categories)>0 then s.normalized_categories else s.categories end,
    case when cardinality(s.normalized_tags)>0 then s.normalized_tags else s.tags end,
    s.updated_at,
    (case when lower(s.title)=lower(q.term) then 10 else 0 end
     + case when lower(s.title) like '%'||lower(q.term)||'%' then 5 else 0 end
     + case when coalesce(lower(s.summary),'') like '%'||lower(q.term)||'%' then 2 else 0 end
     + case when lower(s.content) like '%'||lower(q.term)||'%' then 1 else 0 end
     + case when coalesce(lower(s.author_username),'') like '%'||lower(q.term)||'%' then 2 else 0 end
     + case when coalesce(lower(s.author_display_name),'') like '%'||lower(q.term)||'%' then 2 else 0 end)::real as rank
  from source s cross join q
  where q.term is not null and (
    lower(s.title) like '%'||lower(q.term)||'%' or coalesce(lower(s.summary),'') like '%'||lower(q.term)||'%'
    or lower(s.content) like '%'||lower(q.term)||'%' or coalesce(lower(s.author_username),'') like '%'||lower(q.term)||'%'
    or coalesce(lower(s.author_display_name),'') like '%'||lower(q.term)||'%'
    or exists (select 1 from unnest(s.normalized_categories || s.categories) x where lower(x) like '%'||lower(q.term)||'%')
    or exists (select 1 from unnest(s.normalized_tags || s.tags) x where lower(x) like '%'||lower(q.term)||'%')
  ) order by rank desc,s.title asc limit least(greatest(max_results,1),100);
$$;
revoke all on function public.wiki_search(text,integer) from public, anon, authenticated;
grant execute on function public.wiki_search(text,integer) to anon, authenticated;

create or replace function public.wiki_category_counts()
returns table(category_id uuid,category_name text,category_slug text,parent_id uuid,article_count bigint)
language sql stable security definer set search_path = public
as $$
  select c.id,c.name,c.slug,c.parent_id,count(distinct a.id)
  from public.categories c
  left join public.article_categories ac on ac.category_id=c.id
  left join public.articles a on a.id=ac.article_id and a.status='published' and a.deleted_at is null
  where c.active group by c.id,c.name,c.slug,c.parent_id,c.sort_order order by c.sort_order,c.name;
$$;
revoke all on function public.wiki_category_counts() from public, anon, authenticated;
grant execute on function public.wiki_category_counts() to anon, authenticated;

-- Separate anonymous read rules from authenticated/staff rules so public browsing
-- never depends on privileged helper EXECUTE rights.
drop policy if exists "articles_public_or_author_or_admin_read" on public.articles;
drop policy if exists "articles_public_read_v03" on public.articles;
drop policy if exists "articles_authenticated_read_v03" on public.articles;
create policy "articles_public_read_v03" on public.articles for select to anon using (status='published' and deleted_at is null);
create policy "articles_authenticated_read_v03" on public.articles for select to authenticated using ((status='published' and deleted_at is null) or author_id=auth.uid() or public.is_admin_mfa(auth.uid()));

drop policy if exists "revisions_public_author_admin_read" on public.article_revisions;
drop policy if exists "revisions_public_read_v03" on public.article_revisions;
drop policy if exists "revisions_authenticated_read_v03" on public.article_revisions;
create policy "revisions_public_read_v03" on public.article_revisions for select to anon using (status='approved' and exists(select 1 from public.articles a where a.id=article_id and a.status='published' and a.deleted_at is null));
create policy "revisions_authenticated_read_v03" on public.article_revisions for select to authenticated using ((status='approved' and exists(select 1 from public.articles a where a.id=article_id and a.status='published' and a.deleted_at is null)) or author_id=auth.uid() or public.is_admin_mfa(auth.uid()));

drop policy if exists "discussion_public_read" on public.discussion_posts;
drop policy if exists "discussion_public_read_v03" on public.discussion_posts;
drop policy if exists "discussion_authenticated_read_v03" on public.discussion_posts;
create policy "discussion_public_read_v03" on public.discussion_posts for select to anon using (removed_at is null);
create policy "discussion_authenticated_read_v03" on public.discussion_posts for select to authenticated using (removed_at is null or public.is_admin_mfa(auth.uid()));

drop policy if exists "article_types_read" on public.article_types;
drop policy if exists "article_types_public_read_v03" on public.article_types;
drop policy if exists "article_types_authenticated_read_v03" on public.article_types;
create policy "article_types_public_read_v03" on public.article_types for select to anon using (active);
create policy "article_types_authenticated_read_v03" on public.article_types for select to authenticated using (active or public.is_admin_mfa(auth.uid()));

drop policy if exists "categories_read" on public.categories;
drop policy if exists "categories_public_read_v03" on public.categories;
drop policy if exists "categories_authenticated_read_v03" on public.categories;
create policy "categories_public_read_v03" on public.categories for select to anon using (active);
create policy "categories_authenticated_read_v03" on public.categories for select to authenticated using (active or public.is_admin_mfa(auth.uid()));

drop policy if exists "controlled_tags_read" on public.controlled_tags;
drop policy if exists "controlled_tags_public_read_v03" on public.controlled_tags;
drop policy if exists "controlled_tags_authenticated_read_v03" on public.controlled_tags;
create policy "controlled_tags_public_read_v03" on public.controlled_tags for select to anon using (active);
create policy "controlled_tags_authenticated_read_v03" on public.controlled_tags for select to authenticated using (active or public.is_admin_mfa(auth.uid()));

drop policy if exists "article_categories_read" on public.article_categories;
drop policy if exists "article_categories_public_read_v03" on public.article_categories;
drop policy if exists "article_categories_authenticated_read_v03" on public.article_categories;
create policy "article_categories_public_read_v03" on public.article_categories for select to anon using (exists(select 1 from public.articles a where a.id=article_id and a.status='published' and a.deleted_at is null));
create policy "article_categories_authenticated_read_v03" on public.article_categories for select to authenticated using (exists(select 1 from public.articles a where a.id=article_id and ((a.status='published' and a.deleted_at is null) or a.author_id=auth.uid() or public.is_admin_mfa(auth.uid()))));

drop policy if exists "article_tags_read" on public.article_tags;
drop policy if exists "article_tags_public_read_v03" on public.article_tags;
drop policy if exists "article_tags_authenticated_read_v03" on public.article_tags;
create policy "article_tags_public_read_v03" on public.article_tags for select to anon using (exists(select 1 from public.articles a where a.id=article_id and a.status='published' and a.deleted_at is null));
create policy "article_tags_authenticated_read_v03" on public.article_tags for select to authenticated using (exists(select 1 from public.articles a where a.id=article_id and ((a.status='published' and a.deleted_at is null) or a.author_id=auth.uid() or public.is_admin_mfa(auth.uid()))));

drop policy if exists "revision_categories_read" on public.revision_categories;
drop policy if exists "revision_categories_public_read_v03" on public.revision_categories;
drop policy if exists "revision_categories_authenticated_read_v03" on public.revision_categories;
create policy "revision_categories_public_read_v03" on public.revision_categories for select to anon using (exists(select 1 from public.article_revisions r join public.articles a on a.id=r.article_id where r.id=revision_id and r.status='approved' and a.status='published' and a.deleted_at is null));
create policy "revision_categories_authenticated_read_v03" on public.revision_categories for select to authenticated using (exists(select 1 from public.article_revisions r join public.articles a on a.id=r.article_id where r.id=revision_id and ((r.status='approved' and a.status='published' and a.deleted_at is null) or r.author_id=auth.uid() or public.is_admin_mfa(auth.uid()))));

drop policy if exists "revision_tags_read" on public.revision_tags;
drop policy if exists "revision_tags_public_read_v03" on public.revision_tags;
drop policy if exists "revision_tags_authenticated_read_v03" on public.revision_tags;
create policy "revision_tags_public_read_v03" on public.revision_tags for select to anon using (exists(select 1 from public.article_revisions r join public.articles a on a.id=r.article_id where r.id=revision_id and r.status='approved' and a.status='published' and a.deleted_at is null));
create policy "revision_tags_authenticated_read_v03" on public.revision_tags for select to authenticated using (exists(select 1 from public.article_revisions r join public.articles a on a.id=r.article_id where r.id=revision_id and ((r.status='approved' and a.status='published' and a.deleted_at is null) or r.author_id=auth.uid() or public.is_admin_mfa(auth.uid()))));

-- Article writes use the article-specific emergency switch.
drop policy if exists "articles_author_insert" on public.articles;
create policy "articles_author_insert" on public.articles for insert to authenticated with check (author_id=auth.uid() and status='draft' and public.can_write_articles(auth.uid()));
drop policy if exists "articles_author_or_admin_update" on public.articles;
create policy "articles_author_or_admin_update" on public.articles for update to authenticated using (public.is_admin_mfa(auth.uid()) or (author_id=auth.uid() and status='draft' and deleted_at is null and public.can_write_articles(auth.uid()))) with check (public.is_admin_mfa(auth.uid()) or (author_id=auth.uid() and status='draft' and public.can_write_articles(auth.uid())));
drop policy if exists "articles_draft_owner_or_admin_delete" on public.articles;
create policy "articles_draft_owner_or_admin_delete" on public.articles for delete to authenticated using (public.is_sysadmin_mfa(auth.uid()) or (author_id=auth.uid() and status='draft' and public.can_write_articles(auth.uid())));

drop policy if exists "revisions_author_insert" on public.article_revisions;
create policy "revisions_author_insert" on public.article_revisions for insert to authenticated with check (author_id=auth.uid() and status in ('draft','pending_review') and public.can_write_articles(auth.uid()));
drop policy if exists "revisions_author_admin_update" on public.article_revisions;
create policy "revisions_author_admin_update" on public.article_revisions for update to authenticated using (public.is_admin_mfa(auth.uid()) or (author_id=auth.uid() and status in ('draft','changes_requested') and public.can_write_articles(auth.uid()))) with check (public.is_admin_mfa(auth.uid()) or (author_id=auth.uid() and status in ('draft','pending_review') and public.can_write_articles(auth.uid())));
drop policy if exists "revisions_draft_author_admin_delete" on public.article_revisions;
create policy "revisions_draft_author_admin_delete" on public.article_revisions for delete to authenticated using (public.is_admin_mfa(auth.uid()) or (author_id=auth.uid() and status='draft' and public.can_write_articles(auth.uid())));

-- Normalized taxonomy follows the editable revision/page permissions.
drop policy if exists "revision_categories_write" on public.revision_categories;
create policy "revision_categories_write" on public.revision_categories for all to authenticated
using (exists(select 1 from public.article_revisions r where r.id=revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid())))))
with check (exists(select 1 from public.article_revisions r where r.id=revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id=auth.uid() and r.status in ('draft','changes_requested','pending_review') and public.can_write_articles(auth.uid())))));
drop policy if exists "revision_tags_write" on public.revision_tags;
create policy "revision_tags_write" on public.revision_tags for all to authenticated
using (exists(select 1 from public.article_revisions r where r.id=revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid())))))
with check (exists(select 1 from public.article_revisions r where r.id=revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id=auth.uid() and r.status in ('draft','changes_requested','pending_review') and public.can_write_articles(auth.uid())))));

-- Discussion feature switch is independent from article writing.
drop policy if exists "discussion_active_insert" on public.discussion_posts;
create policy "discussion_active_insert" on public.discussion_posts for insert to authenticated with check (user_id=auth.uid() and public.is_active_contributor(auth.uid()) and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='discussion_enabled'),true));

-- Public media metadata is visible only when referenced by a public article;
-- owners and MFA-verified staff may inspect private/unpublished assets.
drop policy if exists "media_read" on public.media_assets;
drop policy if exists "media_public_read_v03" on public.media_assets;
drop policy if exists "media_authenticated_read_v03" on public.media_assets;
create policy "media_public_read_v03" on public.media_assets for select to anon using (
  deleted_at is null and (
    exists(select 1 from public.articles a where a.status='published' and a.deleted_at is null and (a.cover_media_id=media_assets.id or a.video_media_id=media_assets.id))
    or exists(select 1 from public.article_revisions r join public.articles a on a.id=r.article_id where r.status='approved' and a.status='published' and a.deleted_at is null and (r.cover_media_id=media_assets.id or r.video_media_id=media_assets.id))
  )
);
create policy "media_authenticated_read_v03" on public.media_assets for select to authenticated using (
  owner_id=auth.uid() or public.is_admin_mfa(auth.uid()) or (deleted_at is null and (
    exists(select 1 from public.articles a where a.status='published' and a.deleted_at is null and (a.cover_media_id=media_assets.id or a.video_media_id=media_assets.id))
    or exists(select 1 from public.article_revisions r join public.articles a on a.id=r.article_id where r.status='approved' and a.status='published' and a.deleted_at is null and (r.cover_media_id=media_assets.id or r.video_media_id=media_assets.id))
  ))
);
drop policy if exists "media_insert" on public.media_assets;
create policy "media_insert" on public.media_assets for insert to authenticated with check (
  owner_id=auth.uid() and bucket='zionxyos-media' and public.is_active_contributor(auth.uid())
  and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='media_uploads_enabled'),true)
  and ((media_kind='image' and mime_type in ('image/jpeg','image/png','image/webp','image/gif') and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='image_uploads_enabled'),true) and size_bytes between 1 and least(52428800,coalesce((select (value#>>'{}')::bigint from public.site_settings where key='max_image_bytes'),10485760)))
    or (media_kind='video' and mime_type in ('video/mp4','video/webm','video/ogg') and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='video_uploads_enabled'),true) and size_bytes between 1 and least(52428800,coalesce((select (value#>>'{}')::bigint from public.site_settings where key='max_video_bytes'),52428800)))));
drop policy if exists "media_update" on public.media_assets;
create policy "media_update" on public.media_assets for update to authenticated using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));

-- Site settings/announcement/template public reads do not call staff helpers.
drop policy if exists "settings_read" on public.site_settings;
drop policy if exists "settings_public_read_v03" on public.site_settings;
drop policy if exists "settings_authenticated_read_v03" on public.site_settings;
create policy "settings_public_read_v03" on public.site_settings for select to anon using (is_public);
create policy "settings_authenticated_read_v03" on public.site_settings for select to authenticated using (is_public or public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "announcements_read" on public.site_announcements;
drop policy if exists "announcements_public_read_v03" on public.site_announcements;
drop policy if exists "announcements_authenticated_read_v03" on public.site_announcements;
create policy "announcements_public_read_v03" on public.site_announcements for select to anon using (active and starts_at<=now() and (ends_at is null or ends_at>now()) and audience='all');
create policy "announcements_authenticated_read_v03" on public.site_announcements for select to authenticated using (public.is_sysadmin_mfa(auth.uid()) or (active and starts_at<=now() and (ends_at is null or ends_at>now()) and (audience in ('all','authenticated') or (audience='staff' and public.is_admin_mfa(auth.uid())))));

drop policy if exists "notice_templates_read" on public.notice_templates;
drop policy if exists "notice_templates_public_read_v03" on public.notice_templates;
drop policy if exists "notice_templates_authenticated_read_v03" on public.notice_templates;
create policy "notice_templates_public_read_v03" on public.notice_templates for select to anon using (active);
create policy "notice_templates_authenticated_read_v03" on public.notice_templates for select to authenticated using (active or public.is_admin_mfa(auth.uid()));

drop policy if exists "article_notices_read" on public.article_notices;
drop policy if exists "article_notices_public_read_v03" on public.article_notices;
drop policy if exists "article_notices_authenticated_read_v03" on public.article_notices;
create policy "article_notices_public_read_v03" on public.article_notices for select to anon using (exists(select 1 from public.articles a where a.id=article_id and a.status='published' and a.deleted_at is null));
create policy "article_notices_authenticated_read_v03" on public.article_notices for select to authenticated using (exists(select 1 from public.articles a where a.id=article_id and ((a.status='published' and a.deleted_at is null) or public.is_admin_mfa(auth.uid()))));

-- Canonical taxonomy is publication state. Browser sessions never write it
-- directly; the protected review RPC is the only publication path that copies
-- normalized revision taxonomy into article_categories/article_tags.
drop policy if exists "article_categories_admin_write" on public.article_categories;
drop policy if exists "article_tags_admin_write" on public.article_tags;
revoke insert, update, delete on public.article_categories from anon, authenticated;
revoke insert, update, delete on public.article_tags from anon, authenticated;

-- Page-edit capability must exist before RLS policies reference it. PostgreSQL
-- resolves policy function calls at CREATE POLICY time, so dependency order is
-- part of the migration contract (not only runtime behavior).
create or replace function public.can_edit_article(article_uuid uuid, uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select uid is not null
    and uid = auth.uid()
    and public.is_active_contributor(uid)
    and exists (
      select 1 from public.articles a
      where a.id = article_uuid
        and a.deleted_at is null
        and (
          a.protection_level = 'open'
          or (a.protected_until is not null and a.protected_until <= now())
          or (a.protection_level = 'admin' and public.is_admin_mfa(uid))
          or (a.protection_level = 'sysadmin' and public.is_sysadmin_mfa(uid))
        )
    );
$$;
revoke all on function public.can_edit_article(uuid,uuid) from public, anon, authenticated;
grant execute on function public.can_edit_article(uuid,uuid) to authenticated;

-- Editorial notice templates belong to the sysadmin; staff may only attach an
-- active template to a page their MFA-backed role is actually allowed to edit.
drop policy if exists "notice_templates_sysadmin_write" on public.notice_templates;
create policy "notice_templates_sysadmin_write" on public.notice_templates for all to authenticated
using (public.is_sysadmin_mfa(auth.uid()))
with check (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "article_notices_admin_write" on public.article_notices;
drop policy if exists "article_notices_admin_insert_v03" on public.article_notices;
drop policy if exists "article_notices_admin_delete_v03" on public.article_notices;
create policy "article_notices_admin_insert_v03" on public.article_notices for insert to authenticated
with check (
  assigned_by = auth.uid()
  and public.is_admin_mfa(auth.uid())
  and public.can_edit_article(article_id, auth.uid())
  and exists (select 1 from public.notice_templates n where n.id=notice_id and n.active)
);
create policy "article_notices_admin_delete_v03" on public.article_notices for delete to authenticated
using (
  public.is_admin_mfa(auth.uid())
  and public.can_edit_article(article_id, auth.uid())
);
revoke update on public.article_notices from anon, authenticated;

-- Immutable object paths for contributors. Storage validates owner folder, MIME,
-- feature switches, and live configured size limits. Upsert/update is staff-only.
drop policy if exists "zionxyos_media_insert" on storage.objects;
create policy "zionxyos_media_insert" on storage.objects for insert to authenticated with check (
  bucket_id='zionxyos-media' and (storage.foldername(name))[1]=auth.uid()::text and public.is_active_contributor(auth.uid())
  and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='media_uploads_enabled'),true)
  and coalesce(metadata->>'size','') ~ '^[0-9]+$'
  and (((lower(coalesce(metadata->>'mimetype',''))='image/jpeg' and lower(storage.extension(name)) in ('jpg','jpeg'))
      or (lower(coalesce(metadata->>'mimetype',''))='image/png' and lower(storage.extension(name))='png')
      or (lower(coalesce(metadata->>'mimetype',''))='image/webp' and lower(storage.extension(name))='webp')
      or (lower(coalesce(metadata->>'mimetype',''))='image/gif' and lower(storage.extension(name))='gif'))
      and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='image_uploads_enabled'),true)
      and (metadata->>'size')::bigint between 1 and least(52428800,coalesce((select (value#>>'{}')::bigint from public.site_settings where key='max_image_bytes'),10485760))
    or (((lower(coalesce(metadata->>'mimetype',''))='video/mp4' and lower(storage.extension(name))='mp4')
      or (lower(coalesce(metadata->>'mimetype',''))='video/webm' and lower(storage.extension(name))='webm')
      or (lower(coalesce(metadata->>'mimetype',''))='video/ogg' and lower(storage.extension(name))='ogg'))
      and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='video_uploads_enabled'),true)
      and (metadata->>'size')::bigint between 1 and least(52428800,coalesce((select (value#>>'{}')::bigint from public.site_settings where key='max_video_bytes'),52428800)))));
drop policy if exists "zionxyos_media_update" on storage.objects;
create policy "zionxyos_media_update" on storage.objects for update to authenticated using (bucket_id='zionxyos-media' and public.is_sysadmin_mfa(auth.uid())) with check (bucket_id='zionxyos-media' and public.is_sysadmin_mfa(auth.uid()));
drop policy if exists "zionxyos_media_delete" on storage.objects;
create policy "zionxyos_media_delete" on storage.objects for delete to authenticated using (bucket_id='zionxyos-media' and (public.is_sysadmin_mfa(auth.uid()) or ((storage.foldername(name))[1]=auth.uid()::text and not exists(select 1 from public.media_assets m where m.bucket=bucket_id and m.object_path=name))));
drop policy if exists "zionxyos_media_owner_select" on storage.objects;
create policy "zionxyos_media_owner_select" on storage.objects for select to authenticated using (bucket_id='zionxyos-media' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_sysadmin_mfa(auth.uid())));

-- Raw role probes and trigger-only implementation helpers are not browser RPCs.
revoke all on function public.is_admin(uuid) from public, anon, authenticated;
revoke all on function public.is_sysadmin(uuid) from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.capture_article_version() from public, anon, authenticated;
revoke all on function public.audit_article_change() from public, anon, authenticated;
revoke all on function public.audit_profile_admin_change() from public, anon, authenticated;
revoke all on function public.audit_revision_change() from public, anon, authenticated;
revoke all on function public.prevent_category_cycle() from public, anon, authenticated;
revoke all on function public.protect_profile_privileged_fields() from public, anon, authenticated;
revoke all on function public.require_mfa_for_privileged_role() from public, anon, authenticated;
revoke all on function public.enforce_article_permissions() from public, anon, authenticated;
revoke all on function public.enforce_revision_permissions() from public, anon, authenticated;
revoke all on function public.enforce_report_admin_update() from public, anon, authenticated;
revoke all on function public.enforce_discussion_admin_update() from public, anon, authenticated;

-- Explicitly preserve only client-facing capability/RPC entry points.
revoke all on function public.has_aal2() from public, anon, authenticated;
grant execute on function public.has_aal2() to authenticated;
revoke all on function public.is_admin_mfa(uuid) from public, anon, authenticated;
grant execute on function public.is_admin_mfa(uuid) to authenticated;
revoke all on function public.is_sysadmin_mfa(uuid) from public, anon, authenticated;
grant execute on function public.is_sysadmin_mfa(uuid) to authenticated;
revoke all on function public.has_current_legal_acceptance(uuid) from public, anon, authenticated;
grant execute on function public.has_current_legal_acceptance(uuid) to authenticated;
revoke all on function public.current_legal_versions() from public, anon, authenticated;
grant execute on function public.current_legal_versions() to anon, authenticated;
revoke all on function public.accept_current_legal(text) from public, anon, authenticated;
grant execute on function public.accept_current_legal(text) to authenticated;
revoke all on function public.admin_review_revision(uuid,text,text) from public, anon, authenticated;
grant execute on function public.admin_review_revision(uuid,text,text) to authenticated;
revoke all on function public.admin_apply_moderation(uuid,text,text,timestamptz) from public, anon, authenticated;
grant execute on function public.admin_apply_moderation(uuid,text,text,timestamptz) to authenticated;
revoke all on function public.admin_revoke_moderation(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_revoke_moderation(uuid,text) to authenticated;


-- ---------------------------------------------------------------------------
-- Media upload limits are public configuration because contributor-side file
-- validation needs the live limits; release source configuration remains private.
update public.site_settings set is_public=true where key in ('max_image_bytes','max_video_bytes');

-- Release-candidate hardening: trust boundaries for taxonomy, media and helper RPCs.
-- ---------------------------------------------------------------------------

-- Canonical taxonomy is publication state. Browser sessions never write it
-- directly; the protected review RPC is the only publication path that copies
-- normalized revision taxonomy into article_categories/article_tags.
drop policy if exists "article_categories_admin_write" on public.article_categories;
drop policy if exists "article_tags_admin_write" on public.article_tags;
revoke insert, update, delete on public.article_categories from anon, authenticated;
revoke insert, update, delete on public.article_tags from anon, authenticated;

-- Public readers only need templates that are actually attached to a live article.
-- This avoids exposing unused/future editorial template text through PostgREST.
drop policy if exists "notice_templates_public_read_v03" on public.notice_templates;
drop policy if exists "notice_templates_authenticated_read_v03" on public.notice_templates;
create policy "notice_templates_public_read_v03" on public.notice_templates for select to anon
using (
  active and exists (
    select 1 from public.article_notices an
    join public.articles a on a.id=an.article_id
    where an.notice_id=notice_templates.id and a.status='published' and a.deleted_at is null
  )
);
create policy "notice_templates_authenticated_read_v03" on public.notice_templates for select to authenticated
using (
  public.is_admin_mfa(auth.uid())
  or (
    active and exists (
      select 1 from public.article_notices an
      join public.articles a on a.id=an.article_id
      where an.notice_id=notice_templates.id and a.status='published' and a.deleted_at is null
    )
  )
);

-- Editorial notice templates belong to the sysadmin; staff may only attach an
-- active template to a page their MFA-backed role is actually allowed to edit.
drop policy if exists "notice_templates_sysadmin_write" on public.notice_templates;
create policy "notice_templates_sysadmin_write" on public.notice_templates for all to authenticated
using (public.is_sysadmin_mfa(auth.uid()))
with check (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "article_notices_admin_write" on public.article_notices;
drop policy if exists "article_notices_admin_insert_v03" on public.article_notices;
drop policy if exists "article_notices_admin_delete_v03" on public.article_notices;
create policy "article_notices_admin_insert_v03" on public.article_notices for insert to authenticated
with check (
  assigned_by = auth.uid()
  and public.is_admin_mfa(auth.uid())
  and public.can_edit_article(article_id, auth.uid())
  and exists (select 1 from public.notice_templates n where n.id=notice_id and n.active)
);
create policy "article_notices_admin_delete_v03" on public.article_notices for delete to authenticated
using (
  public.is_admin_mfa(auth.uid())
  and public.can_edit_article(article_id, auth.uid())
);
revoke update on public.article_notices from anon, authenticated;

-- Client-facing account-state helpers may answer questions about the caller only.
-- Internal SECURITY DEFINER helpers can still call the lower-level moderation
-- function as the database owner, but browsers cannot probe other accounts.
create or replace function public.has_current_legal_acceptance(uid uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public
as $$
  select uid is not null and uid = auth.uid() and exists (
    select 1 from public.profiles p, public.current_legal_versions() v
    where p.id = uid and p.legal_accepted_at is not null
      and p.terms_version = v.terms_version
      and p.privacy_version = v.privacy_version
      and p.guidelines_version = v.guidelines_version
  );
$$;

create or replace function public.is_blocked(uid uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public
as $$
  select uid is not null and uid = auth.uid() and (
    public.moderation_is_active(uid, 'suspend') or public.moderation_is_active(uid, 'ban')
  );
$$;

create or replace function public.is_muted(uid uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public
as $$
  select uid is not null and uid = auth.uid() and public.moderation_is_active(uid, 'mute');
$$;

create or replace function public.is_active_user(uid uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public
as $$
  select uid is not null and uid = auth.uid() and exists (
    select 1 from public.profiles p where p.id = uid and p.suspended = false
  ) and not public.is_blocked(uid);
$$;

create or replace function public.is_active_contributor(uid uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public
as $$
  select uid is not null and uid = auth.uid()
     and public.is_active_user(uid)
     and public.has_current_legal_acceptance(uid)
     and not public.is_muted(uid);
$$;

create or replace function public.can_write_articles(uid uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public
as $$
  select uid is not null and uid = auth.uid()
     and public.is_active_contributor(uid)
     and coalesce((select (value #>> '{}')::boolean from public.site_settings where key='article_creation_enabled'), true);
$$;

revoke all on function public.moderation_is_active(uuid,text) from public, anon, authenticated;
revoke all on function public.is_blocked(uuid) from public, anon, authenticated;
revoke all on function public.is_muted(uuid) from public, anon, authenticated;
revoke all on function public.is_active_user(uuid) from public, anon, authenticated;
grant execute on function public.is_active_user(uuid) to authenticated;
revoke all on function public.is_active_contributor(uuid) from public, anon, authenticated;
grant execute on function public.is_active_contributor(uuid) to authenticated;
revoke all on function public.can_write_articles(uuid) from public, anon, authenticated;
grant execute on function public.can_write_articles(uuid) to authenticated;
revoke all on function public.has_current_legal_acceptance(uuid) from public, anon, authenticated;
grant execute on function public.has_current_legal_acceptance(uuid) to authenticated;

-- A deactivated article type remains readable if a published article still uses it.
-- This preserves infobox labels/history without allowing contributors to select it
-- for new revisions.
drop policy if exists "article_types_public_read_v03" on public.article_types;
drop policy if exists "article_types_authenticated_read_v03" on public.article_types;
create policy "article_types_public_read_v03" on public.article_types for select to anon
using (
  active
  or exists(select 1 from public.articles a where a.article_type_id=article_types.id and a.status='published' and a.deleted_at is null)
  or exists(select 1 from public.article_revisions r join public.articles a on a.id=r.article_id where r.article_type_id=article_types.id and r.status='approved' and a.status='published' and a.deleted_at is null)
);
create policy "article_types_authenticated_read_v03" on public.article_types for select to authenticated
using (
  active or public.is_admin_mfa(auth.uid())
  or exists(select 1 from public.articles a where a.article_type_id=article_types.id and a.status='published' and a.deleted_at is null)
  or exists(select 1 from public.article_revisions r join public.articles a on a.id=r.article_id where r.article_type_id=article_types.id and r.status='approved' and a.status='published' and a.deleted_at is null)
);

-- Pending submissions are immutable to their contributor. The application inserts
-- taxonomy while the revision is editable and only then changes it to pending.
drop policy if exists "revision_categories_write" on public.revision_categories;
create policy "revision_categories_write" on public.revision_categories for all to authenticated
using (exists(select 1 from public.article_revisions r where r.id=revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid())))))
with check (exists(select 1 from public.article_revisions r where r.id=revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid())))));

drop policy if exists "revision_tags_write" on public.revision_tags;
create policy "revision_tags_write" on public.revision_tags for all to authenticated
using (exists(select 1 from public.article_revisions r where r.id=revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid())))))
with check (exists(select 1 from public.article_revisions r where r.id=revision_id and (public.is_admin_mfa(auth.uid()) or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid())))));

-- Media metadata must describe an object in the caller's own fixed bucket folder.
-- The URL column is retained for backwards compatibility, but application code
-- reconstructs the canonical public URL from bucket + object_path before use.
drop policy if exists "media_insert" on public.media_assets;
create policy "media_insert" on public.media_assets for insert to authenticated with check (
  owner_id=auth.uid() and bucket='zionxyos-media'
  and object_path like auth.uid()::text || '/%'
  and position('..' in object_path)=0
  and public.is_active_contributor(auth.uid())
  and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='media_uploads_enabled'),true)
  and ((media_kind='image' and mime_type in ('image/jpeg','image/png','image/webp','image/gif') and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='image_uploads_enabled'),true) and size_bytes between 1 and least(52428800,coalesce((select (value#>>'{}')::bigint from public.site_settings where key='max_image_bytes'),10485760)))
    or (media_kind='video' and mime_type in ('video/mp4','video/webm','video/ogg') and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='video_uploads_enabled'),true) and size_bytes between 1 and least(52428800,coalesce((select (value#>>'{}')::bigint from public.site_settings where key='max_video_bytes'),52428800)))));

-- Final contributor-side revision guard. Drafts may be incomplete in body text,
-- but every selectable structural/media field is validated in the database too.
create or replace function public.enforce_revision_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  review_publish boolean := coalesce(current_setting('zionxyos.review_publish', true), '') = '1';
  type_slug text;
begin
  if auth.uid() is null then return new; end if;
  if public.is_sysadmin_mfa(auth.uid()) then return new; end if;
  if review_publish and public.is_admin_mfa(auth.uid()) then return new; end if;

  -- Admins may correct somebody else's pending content, but cannot alter ownership
  -- or review-state fields outside the controlled review RPC.
  if public.is_admin_mfa(auth.uid()) and tg_op='UPDATE' and old.status='pending_review' then
    if new.article_id is distinct from old.article_id
       or new.author_id is distinct from old.author_id
       or new.status is distinct from old.status
       or new.reviewer_id is distinct from old.reviewer_id
       or new.review_note is distinct from old.review_note
       or new.submitted_at is distinct from old.submitted_at
       or new.reviewed_at is distinct from old.reviewed_at then
      raise exception 'Pending revision ownership and review state are restricted';
    end if;
    return new;
  end if;

  if not public.can_write_articles(auth.uid()) then raise exception 'Article writing is not available for this account right now'; end if;
  if nullif(trim(new.title),'') is null then raise exception 'Revision title is required'; end if;
  select t.slug into type_slug from public.article_types t where t.id=new.article_type_id and t.active;
  if type_slug is null then raise exception 'Revision article type must be active'; end if;
  new.article_type := type_slug;

  if new.cover_image_url is not null and new.cover_image_url !~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' then raise exception 'Image URL must use HTTPS'; end if;
  if new.video_url is not null and new.video_url !~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' then raise exception 'Video URL must use HTTPS'; end if;
  if new.cover_media_id is not null and not exists(select 1 from public.media_assets m where m.id=new.cover_media_id and m.owner_id=auth.uid() and m.media_kind='image' and m.deleted_at is null) then
    raise exception 'Cover media must be an active image owned by the revision author';
  end if;
  if new.video_media_id is not null and not exists(select 1 from public.media_assets m where m.id=new.video_media_id and m.owner_id=auth.uid() and m.media_kind='video' and m.deleted_at is null) then
    raise exception 'Video media must be an active video owned by the revision author';
  end if;
  if new.status='pending_review' and nullif(trim(new.content),'') is null then raise exception 'Content is required before review submission'; end if;

  if tg_op='INSERT' then
    if new.author_id<>auth.uid() then raise exception 'Revision author must be the signed-in user'; end if;
    if new.status not in ('draft','pending_review') then raise exception 'Invalid revision status'; end if;
    if new.reviewer_id is not null or new.reviewed_at is not null then raise exception 'Review fields are restricted'; end if;
    return new;
  end if;

  if old.author_id<>auth.uid() then raise exception 'Only the revision author can edit it'; end if;
  if old.status not in ('draft','changes_requested') then raise exception 'This revision is no longer editable'; end if;
  if new.article_id is distinct from old.article_id or new.author_id is distinct from old.author_id
     or new.reviewer_id is distinct from old.reviewer_id or new.reviewed_at is distinct from old.reviewed_at then
    raise exception 'Restricted revision fields cannot be changed';
  end if;
  if new.status not in ('draft','pending_review') then raise exception 'Only draft or review submission is allowed'; end if;
  return new;
end;
$$;
revoke all on function public.enforce_revision_permissions() from public, anon, authenticated;

-- Define the page-edit capability before the review RPC that consumes it. It is
-- repeated in the final hardening block below so the release's last definition stays
-- next to the policies it governs.


-- Required-infobox validation is defined before the review routine that invokes it.
-- This keeps function dependency order explicit for clean installs and future
-- migration tooling that validates routine bodies eagerly.
create or replace function public.required_infobox_complete(type_uuid uuid, box jsonb)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.article_types t where t.id=type_uuid and t.active)
     and not exists (
       select 1
       from public.article_types t
       cross join lateral jsonb_array_elements(
         case when jsonb_typeof(t.infobox_schema)='array' then t.infobox_schema else '[]'::jsonb end
       ) as field
       where t.id=type_uuid
         and coalesce((field->>'required')::boolean,false)
         and nullif(btrim(
           (case when jsonb_typeof(box)='object' then box else '{}'::jsonb end)
           ->> coalesce(field->>'key','')
         ),'') is null
     );
$$;
revoke all on function public.required_infobox_complete(uuid,jsonb) from public, anon, authenticated;

-- Approval revalidates the revision and derives legacy taxonomy arrays exclusively
-- from normalized controlled taxonomy. This makes direct PostgREST tampering unable
-- to smuggle arbitrary categories/tags into a published canonical row.
create or replace function public.admin_review_revision(revision_uuid uuid, decision text, note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.article_revisions%rowtype;
  a public.articles%rowtype;
  reviewer_role text;
  canonical_type text;
  canonical_category text;
  canonical_categories text[] := '{}'::text[];
  canonical_tags text[] := '{}'::text[];
  selected_category_count integer := 0;
  active_category_count integer := 0;
  selected_tag_count integer := 0;
  active_tag_count integer := 0;
begin
  if not public.is_admin_mfa(auth.uid()) then raise exception 'Admin MFA session required'; end if;
  select role into reviewer_role from public.profiles where id=auth.uid();
  select * into r from public.article_revisions where id=revision_uuid for update;
  if not found then raise exception 'Revision not found'; end if;
  if r.status<>'pending_review' then raise exception 'Revision is not awaiting review'; end if;
  if reviewer_role='admin' and r.author_id=auth.uid() then raise exception 'Admins cannot review their own revisions'; end if;
  if decision in ('changes_requested','reject') and nullif(trim(note),'') is null then raise exception 'A review note is required for this decision'; end if;
  select * into a from public.articles where id=r.article_id for update;
  if not found then raise exception 'Canonical article not found'; end if;
  if not public.can_edit_article(a.id,auth.uid()) then
    raise exception 'Page protection does not permit this reviewer to act on the revision';
  end if;

  if decision='approve' then
    if nullif(trim(r.title),'') is null or nullif(trim(r.content),'') is null then raise exception 'A published revision requires a title and content'; end if;
    select t.slug into canonical_type from public.article_types t where t.id=r.article_type_id and t.active;
    if canonical_type is null then raise exception 'The revision article type is inactive or missing'; end if;
    if not public.required_infobox_complete(r.article_type_id,r.infobox) then
      raise exception 'A required infobox field is missing';
    end if;

    select count(*) into selected_category_count from public.revision_categories rc where rc.revision_id=r.id;
    if selected_category_count > 100 then raise exception 'A revision cannot publish more than 100 categories'; end if;
    select count(*) into active_category_count from public.revision_categories rc join public.categories c on c.id=rc.category_id and c.active where rc.revision_id=r.id;
    if selected_category_count<>active_category_count then raise exception 'The revision contains an inactive or missing category'; end if;
    select coalesce(array_agg(c.name order by c.sort_order,c.name),'{}'::text[]) into canonical_categories
      from public.revision_categories rc join public.categories c on c.id=rc.category_id and c.active where rc.revision_id=r.id;
    select c.name into canonical_category from public.revision_categories rc join public.categories c on c.id=rc.category_id and c.active
      where rc.revision_id=r.id order by c.sort_order,c.name limit 1;

    select count(*) into selected_tag_count from public.revision_tags rt where rt.revision_id=r.id;
    if selected_tag_count > 100 then raise exception 'A revision cannot publish more than 100 controlled tags'; end if;
    select count(*) into active_tag_count from public.revision_tags rt join public.controlled_tags t on t.id=rt.tag_id and t.active where rt.revision_id=r.id;
    if selected_tag_count<>active_tag_count then raise exception 'The revision contains an inactive or missing tag'; end if;
    select coalesce(array_agg(t.name order by t.sort_order,t.name),'{}'::text[]) into canonical_tags
      from public.revision_tags rt join public.controlled_tags t on t.id=rt.tag_id and t.active where rt.revision_id=r.id;

    if r.cover_media_id is not null and not exists(select 1 from public.media_assets m where m.id=r.cover_media_id and m.media_kind='image' and m.deleted_at is null) then raise exception 'The selected cover media is unavailable'; end if;
    if r.video_media_id is not null and not exists(select 1 from public.media_assets m where m.id=r.video_media_id and m.media_kind='video' and m.deleted_at is null) then raise exception 'The selected video media is unavailable'; end if;
    if r.cover_image_url is not null and r.cover_image_url !~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' then raise exception 'Published image URLs must use HTTPS'; end if;
    if r.video_url is not null and r.video_url !~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' then raise exception 'Published video URLs must use HTTPS'; end if;

    perform set_config('zionxyos.review_publish','1',true);
    update public.article_revisions set
      status='approved', reviewer_id=auth.uid(), review_note=nullif(trim(note),''), reviewed_at=now(),
      article_type=canonical_type, category=canonical_category, categories=canonical_categories, tags=canonical_tags,
      cover_image_url=case when r.cover_media_id is null then r.cover_image_url else null end,
      video_url=case when r.video_media_id is null then r.video_url else null end
    where id=r.id;

    update public.articles set
      title=r.title, summary=r.summary, content=r.content,
      article_type=canonical_type, article_type_id=r.article_type_id,
      category=canonical_category, categories=canonical_categories, tags=canonical_tags,
      cover_image_url=case when r.cover_media_id is null then r.cover_image_url else null end,
      video_url=case when r.video_media_id is null then r.video_url else null end,
      cover_media_id=r.cover_media_id, video_media_id=r.video_media_id,
      infobox=r.infobox, original_creator=r.original_creator, original_creator_user_id=r.original_creator_user_id,
      status='published', current_revision_id=r.id, published_at=coalesce(a.published_at,now()), updated_at=now(),
      deleted_at=null, deleted_by=null
    where id=a.id;

    delete from public.article_categories where article_id=a.id;
    insert into public.article_categories(article_id,category_id)
      select a.id,rc.category_id from public.revision_categories rc where rc.revision_id=r.id on conflict do nothing;
    delete from public.article_tags where article_id=a.id;
    insert into public.article_tags(article_id,tag_id)
      select a.id,rt.tag_id from public.revision_tags rt where rt.revision_id=r.id on conflict do nothing;

    insert into public.notifications(user_id,kind,title,body,href)
      values(r.author_id,'revision.approved','Your revision was published',coalesce(nullif(trim(note),''),'The revision was approved by the editorial team.'),'/article/'||a.slug);
    insert into public.notifications(user_id,kind,title,body,href)
      select w.user_id,'watchlist.article_updated','A watched page was updated',coalesce(nullif(trim(r.edit_summary),''),'A new revision was published.'),'/article/'||a.slug
      from public.watchlist w where w.article_id=a.id and w.user_id<>r.author_id;

  elsif decision='changes_requested' then
    perform set_config('zionxyos.review_publish','1',true);
    update public.article_revisions set status='changes_requested',reviewer_id=auth.uid(),review_note=trim(note),reviewed_at=now() where id=r.id;
    insert into public.notifications(user_id,kind,title,body,href) values(r.author_id,'revision.changes_requested','Changes were requested',trim(note),'/dashboard/articles/'||a.id||'/edit');
  elsif decision='reject' then
    perform set_config('zionxyos.review_publish','1',true);
    update public.article_revisions set status='rejected',reviewer_id=auth.uid(),review_note=trim(note),reviewed_at=now() where id=r.id;
    insert into public.notifications(user_id,kind,title,body,href) values(r.author_id,'revision.rejected','Your revision was rejected',trim(note),'/dashboard/articles/'||a.id||'/history');
  else
    raise exception 'Invalid review decision';
  end if;

  insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
    values(auth.uid(),'revision.'||decision,'revision',r.id,jsonb_build_object('article_id',r.article_id,'author_id',r.author_id,'note',note));
end;
$$;
revoke all on function public.admin_review_revision(uuid,text,text) from public, anon, authenticated;
grant execute on function public.admin_review_revision(uuid,text,text) to authenticated;


-- Reports created through the direct Supabase client must still point at a real,
-- currently public target. This keeps invalid UUIDs and removed/private objects out
-- of the moderation queue even if somebody bypasses the Next.js form action.
create or replace function public.is_valid_report_target(target_kind text, target_uuid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case target_kind
    when 'article' then exists (
      select 1 from public.articles a where a.id=target_uuid and a.status='published' and a.deleted_at is null
    )
    when 'revision' then exists (
      select 1 from public.article_revisions r join public.articles a on a.id=r.article_id
      where r.id=target_uuid and r.status='approved' and a.status='published' and a.deleted_at is null
    )
    when 'user' then exists (
      select 1 from public.profiles p where p.id=target_uuid
    )
    when 'discussion' then exists (
      select 1 from public.discussion_posts d join public.articles a on a.id=d.article_id
      where d.id=target_uuid and d.removed_at is null and a.status='published' and a.deleted_at is null
    )
    else false
  end;
$$;
revoke all on function public.is_valid_report_target(text,uuid) from public, anon, authenticated;
grant execute on function public.is_valid_report_target(text,uuid) to authenticated;

drop policy if exists "reports_active_insert" on public.reports;
create policy "reports_active_insert" on public.reports for insert to authenticated
with check (
  reporter_id=auth.uid()
  and public.is_active_user(auth.uid())
  and target_type in ('article','revision','user','discussion')
  and public.is_valid_report_target(target_type,target_id)
);

-- Media Library usage is calculated server-side so the sysadmin can safely decide
-- whether an asset can be retired without fetching every article/revision row.
create or replace function public.sysadmin_media_usage_counts()
returns table(media_asset_id uuid, article_uses bigint, revision_uses bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;
  return query
  with article_usage as (
    select media_id, count(*)::bigint as uses
    from (
      select cover_media_id as media_id from public.articles where cover_media_id is not null
      union all
      select video_media_id as media_id from public.articles where video_media_id is not null
    ) q group by media_id
  ), revision_usage as (
    select media_id, count(*)::bigint as uses
    from (
      select cover_media_id as media_id from public.article_revisions where cover_media_id is not null
      union all
      select video_media_id as media_id from public.article_revisions where video_media_id is not null
    ) q group by media_id
  )
  select m.id, coalesce(a.uses,0), coalesce(r.uses,0)
  from public.media_assets m
  left join article_usage a on a.media_id=m.id
  left join revision_usage r on r.media_id=m.id;
end;
$$;
revoke all on function public.sysadmin_media_usage_counts() from public, anon, authenticated;
grant execute on function public.sysadmin_media_usage_counts() to authenticated;

-- Atomically merge one sysadmin-managed category into another. Links are deduplicated,
-- direct children are reparented, and legacy category arrays are refreshed so archived
-- revision rendering and older compatibility surfaces stay coherent.
create or replace function public.sysadmin_merge_category(source_category_id uuid, target_category_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  source_row public.categories%rowtype;
  target_row public.categories%rowtype;
  affected_articles uuid[] := '{}'::uuid[];
  affected_revisions uuid[] := '{}'::uuid[];
begin
  if not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;
  if source_category_id is null or target_category_id is null or source_category_id = target_category_id then
    raise exception 'Choose two different categories';
  end if;

  select * into source_row from public.categories where id=source_category_id for update;
  if not found then raise exception 'Source category not found'; end if;
  select * into target_row from public.categories where id=target_category_id for update;
  if not found then raise exception 'Target category not found'; end if;
  if not target_row.active then raise exception 'Target category must be active'; end if;

  if exists (
    with recursive descendants as (
      select c.id from public.categories c where c.parent_id=source_category_id
      union all
      select c.id from public.categories c join descendants d on c.parent_id=d.id
    )
    select 1 from descendants where id=target_category_id
  ) then
    raise exception 'A category cannot be merged into one of its descendants';
  end if;

  select coalesce(array_agg(distinct article_id),'{}'::uuid[]) into affected_articles
    from public.article_categories where category_id=source_category_id;
  select coalesce(array_agg(distinct revision_id),'{}'::uuid[]) into affected_revisions
    from public.revision_categories where category_id=source_category_id;

  insert into public.article_categories(article_id,category_id)
    select article_id,target_category_id from public.article_categories where category_id=source_category_id
    on conflict do nothing;
  delete from public.article_categories where category_id=source_category_id;

  insert into public.revision_categories(revision_id,category_id)
    select revision_id,target_category_id from public.revision_categories where category_id=source_category_id
    on conflict do nothing;
  delete from public.revision_categories where category_id=source_category_id;

  update public.categories set parent_id=target_category_id, updated_at=now()
    where parent_id=source_category_id;
  delete from public.categories where id=source_category_id;

  if cardinality(affected_articles)>0 then
    update public.articles a set
      categories=coalesce((select array_agg(c.name order by c.sort_order,c.name) from public.article_categories ac join public.categories c on c.id=ac.category_id where ac.article_id=a.id),'{}'::text[]),
      category=(select c.name from public.article_categories ac join public.categories c on c.id=ac.category_id where ac.article_id=a.id order by c.sort_order,c.name limit 1),
      updated_at=now()
    where a.id=any(affected_articles);
  end if;

  if cardinality(affected_revisions)>0 then
    update public.article_revisions r set
      categories=coalesce((select array_agg(c.name order by c.sort_order,c.name) from public.revision_categories rc join public.categories c on c.id=rc.category_id where rc.revision_id=r.id),'{}'::text[]),
      category=(select c.name from public.revision_categories rc join public.categories c on c.id=rc.category_id where rc.revision_id=r.id order by c.sort_order,c.name limit 1),
      updated_at=now()
    where r.id=any(affected_revisions);
  end if;

  insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
  values(auth.uid(),'taxonomy.category_merged','category',target_category_id,
    jsonb_build_object('source_category_id',source_category_id,'source_name',source_row.name,'target_category_id',target_category_id,'target_name',target_row.name,
      'affected_articles',cardinality(affected_articles),'affected_revisions',cardinality(affected_revisions)));
end;
$$;
revoke all on function public.sysadmin_merge_category(uuid,uuid) from public, anon, authenticated;
grant execute on function public.sysadmin_merge_category(uuid,uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Page-protection authorization hardening.
-- ---------------------------------------------------------------------------
-- v0.2 used `registered`, which was redundant because all contributors are
-- authenticated. v0.3 gives protection explicit staff semantics instead.
update public.articles set protection_level='open' where protection_level='registered';
update public.articles
set protection_level='open', protection_reason=null, protected_until=null
where protected_until is not null and protected_until <= now();
update public.articles
set protection_reason='Migrated page protection'
where protection_level in ('admin','sysadmin') and nullif(trim(protection_reason),'') is null;
alter table public.articles drop constraint if exists articles_protection_level_check;
alter table public.articles add constraint articles_protection_level_check
  check (protection_level in ('open','admin','sysadmin'));

-- One database capability is the source of truth for page-edit authorization.
-- The optional uid is intentionally bound to auth.uid() so this cannot be used
-- to probe another user's capabilities through RPC.
create or replace function public.can_edit_article(article_uuid uuid, uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select uid is not null
    and uid = auth.uid()
    and public.is_active_contributor(uid)
    and exists (
      select 1 from public.articles a
      where a.id = article_uuid
        and a.deleted_at is null
        and (
          a.protection_level = 'open'
          or (a.protected_until is not null and a.protected_until <= now())
          or (a.protection_level = 'admin' and public.is_admin_mfa(uid))
          or (a.protection_level = 'sysadmin' and public.is_sysadmin_mfa(uid))
        )
    );
$$;
revoke all on function public.can_edit_article(uuid,uuid) from public, anon, authenticated;
grant execute on function public.can_edit_article(uuid,uuid) to authenticated;

-- RLS enforces page protection even when a client bypasses the Next.js UI.
-- New contributor drafts must start with non-privileged canonical metadata. This
-- prevents a direct PostgREST insert from pre-setting featured/protection/delete
-- state and having those values survive a later editorial approval.
drop policy if exists "articles_author_insert" on public.articles;
create policy "articles_author_insert" on public.articles for insert to authenticated
with check (
  author_id=auth.uid()
  and status='draft'
  and public.can_write_articles(auth.uid())
  and featured=false
  and protection_level='open'
  and protection_reason is null
  and protected_until is null
  and current_revision_id is null
  and published_at is null
  and deleted_at is null
  and deleted_by is null
);

drop policy if exists "articles_author_or_admin_update" on public.articles;
create policy "articles_author_or_admin_update" on public.articles for update to authenticated
using (
  (public.is_admin_mfa(auth.uid()) and public.can_edit_article(id,auth.uid()))
  or (author_id=auth.uid() and status='draft' and deleted_at is null
      and public.can_write_articles(auth.uid()) and public.can_edit_article(id,auth.uid()))
)
with check (
  (public.is_admin_mfa(auth.uid()) and public.can_edit_article(id,auth.uid()))
  or (author_id=auth.uid() and status='draft'
      and public.can_write_articles(auth.uid()) and public.can_edit_article(id,auth.uid()))
);

drop policy if exists "articles_draft_owner_or_admin_delete" on public.articles;
create policy "articles_draft_owner_or_admin_delete" on public.articles for delete to authenticated
using (
  public.is_sysadmin_mfa(auth.uid())
  or (author_id=auth.uid() and status='draft'
      and public.can_write_articles(auth.uid()) and public.can_edit_article(id,auth.uid()))
);

drop policy if exists "revisions_author_insert" on public.article_revisions;
create policy "revisions_author_insert" on public.article_revisions for insert to authenticated
with check (
  author_id=auth.uid() and status in ('draft','pending_review')
  and public.can_write_articles(auth.uid())
  and public.can_edit_article(article_id,auth.uid())
);

drop policy if exists "revisions_author_admin_update" on public.article_revisions;
create policy "revisions_author_admin_update" on public.article_revisions for update to authenticated
using (
  (public.is_admin_mfa(auth.uid()) and public.can_edit_article(article_id,auth.uid()))
  or (author_id=auth.uid() and status in ('draft','changes_requested')
      and public.can_write_articles(auth.uid()) and public.can_edit_article(article_id,auth.uid()))
)
with check (
  (public.is_admin_mfa(auth.uid()) and public.can_edit_article(article_id,auth.uid()))
  or (author_id=auth.uid() and status in ('draft','pending_review')
      and public.can_write_articles(auth.uid()) and public.can_edit_article(article_id,auth.uid()))
);

drop policy if exists "revisions_draft_author_admin_delete" on public.article_revisions;
create policy "revisions_draft_author_admin_delete" on public.article_revisions for delete to authenticated
using (
  (public.is_admin_mfa(auth.uid()) and public.can_edit_article(article_id,auth.uid()))
  or (author_id=auth.uid() and status='draft'
      and public.can_write_articles(auth.uid()) and public.can_edit_article(article_id,auth.uid()))
);

drop policy if exists "revision_categories_write" on public.revision_categories;
create policy "revision_categories_write" on public.revision_categories for all to authenticated
using (exists(
  select 1 from public.article_revisions r
  where r.id=revision_id and (
    (public.is_admin_mfa(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    or (r.author_id=auth.uid() and r.status in ('draft','changes_requested')
        and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
  )
))
with check (exists(
  select 1 from public.article_revisions r
  where r.id=revision_id and (
    (public.is_admin_mfa(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    or (r.author_id=auth.uid() and r.status in ('draft','changes_requested')
        and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
  )
));

drop policy if exists "revision_tags_write" on public.revision_tags;
create policy "revision_tags_write" on public.revision_tags for all to authenticated
using (exists(
  select 1 from public.article_revisions r
  where r.id=revision_id and (
    (public.is_admin_mfa(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    or (r.author_id=auth.uid() and r.status in ('draft','changes_requested')
        and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
  )
))
with check (exists(
  select 1 from public.article_revisions r
  where r.id=revision_id and (
    (public.is_admin_mfa(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    or (r.author_id=auth.uid() and r.status in ('draft','changes_requested')
        and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
  )
));

-- The article trigger also protects the privileged protection fields themselves.
create or replace function public.enforce_article_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  review_publish boolean := coalesce(current_setting('zionxyos.review_publish', true), '') = '1';
begin
  if auth.uid() is null then return new; end if;

  if new.protection_level not in ('open','admin','sysadmin') then
    raise exception 'Invalid page protection level';
  end if;
  if new.protection_level <> 'open' and nullif(trim(new.protection_reason),'') is null then
    raise exception 'A protection reason is required';
  end if;
  if new.protected_until is not null and new.protected_until <= now() then
    raise exception 'Protection expiry must be in the future';
  end if;

  if review_publish and public.is_admin_mfa(auth.uid()) then
    if not public.can_edit_article(old.id,auth.uid()) then
      raise exception 'Page protection does not permit this reviewer to modify the article';
    end if;
    return new;
  end if;

  if public.is_sysadmin_mfa(auth.uid()) then return new; end if;

  if public.is_admin_mfa(auth.uid()) then
    if old.protection_level='sysadmin' or new.protection_level='sysadmin' then
      raise exception 'Only the sysadmin may manage sysadmin-only page protection';
    end if;
    if not public.can_edit_article(old.id,auth.uid()) then
      raise exception 'Page protection does not permit this administrator to edit the article';
    end if;
    if (to_jsonb(new) - array['featured','protection_level','protection_reason','protected_until','updated_at']::text[])
       is distinct from
       (to_jsonb(old) - array['featured','protection_level','protection_reason','protected_until','updated_at']::text[]) then
      raise exception 'Admins may only change page protection and featured status outside the review workflow';
    end if;
    return new;
  end if;

  if not public.can_write_articles(auth.uid()) or not public.can_edit_article(old.id,auth.uid()) then
    raise exception 'This account is not allowed to edit the article';
  end if;
  if new.author_id is distinct from old.author_id then raise exception 'Article author cannot be changed'; end if;
  if new.status='published' then raise exception 'Only the editorial workflow can publish an article'; end if;
  if (to_jsonb(new) - array[
        'title','summary','content','article_type','article_type_id','category','categories','tags',
        'cover_image_url','video_url','cover_media_id','video_media_id','infobox',
        'original_creator','original_creator_user_id','updated_at'
      ]::text[])
     is distinct from
     (to_jsonb(old) - array[
        'title','summary','content','article_type','article_type_id','category','categories','tags',
        'cover_image_url','video_url','cover_media_id','video_media_id','infobox',
        'original_creator','original_creator_user_id','updated_at'
      ]::text[]) then
    raise exception 'Contributors cannot change privileged article metadata';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_article_permissions() from public, anon, authenticated;

-- Revision trigger mirrors the same page-protection capability. Staff may edit a
-- pending revision only when their protection level permits the canonical page.
-- Article Type required infobox fields are part of the publication contract. The
-- browser provides immediate required-field feedback, while this helper makes the
-- invariant authoritative for direct PostgREST submissions and editorial approval.


create or replace function public.enforce_revision_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  review_publish boolean := coalesce(current_setting('zionxyos.review_publish', true), '') = '1';
  type_slug text;
  target_article_id uuid;
begin
  target_article_id := case when tg_op='INSERT' then new.article_id else old.article_id end;
  if auth.uid() is null then return new; end if;

  if review_publish and public.is_admin_mfa(auth.uid()) then
    if not public.can_edit_article(target_article_id,auth.uid()) then
      raise exception 'Page protection does not permit this reviewer to modify the revision';
    end if;
    return new;
  end if;
  if public.is_sysadmin_mfa(auth.uid()) then return new; end if;

  if public.is_admin_mfa(auth.uid()) and tg_op='UPDATE' and old.status='pending_review' then
    if not public.can_edit_article(old.article_id,auth.uid()) then
      raise exception 'Page protection does not permit this administrator to edit the revision';
    end if;
    if new.article_id is distinct from old.article_id
       or new.author_id is distinct from old.author_id
       or new.status is distinct from old.status
       or new.reviewer_id is distinct from old.reviewer_id
       or new.review_note is distinct from old.review_note
       or new.submitted_at is distinct from old.submitted_at
       or new.reviewed_at is distinct from old.reviewed_at then
      raise exception 'Pending revision ownership and review state are restricted';
    end if;
    return new;
  end if;

  if not public.can_write_articles(auth.uid()) or not public.can_edit_article(target_article_id,auth.uid()) then
    raise exception 'Article writing or page protection does not permit this revision change';
  end if;
  if nullif(trim(new.title),'') is null then raise exception 'Revision title is required'; end if;
  select t.slug into type_slug from public.article_types t where t.id=new.article_type_id and t.active;
  if type_slug is null then raise exception 'Revision article type must be active'; end if;
  new.article_type := type_slug;
  if new.cover_image_url is not null and new.cover_image_url !~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' then raise exception 'Image URL must use HTTPS'; end if;
  if new.video_url is not null and new.video_url !~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' then raise exception 'Video URL must use HTTPS'; end if;
  if new.cover_media_id is not null and not exists(select 1 from public.media_assets m where m.id=new.cover_media_id and m.owner_id=auth.uid() and m.media_kind='image' and m.deleted_at is null) then
    raise exception 'Cover media must be an active image owned by the revision author';
  end if;
  if new.video_media_id is not null and not exists(select 1 from public.media_assets m where m.id=new.video_media_id and m.owner_id=auth.uid() and m.media_kind='video' and m.deleted_at is null) then
    raise exception 'Video media must be an active video owned by the revision author';
  end if;
  if new.status='pending_review' and nullif(trim(new.content),'') is null then raise exception 'Content is required before review submission'; end if;
  if new.status='pending_review' and not public.required_infobox_complete(new.article_type_id,new.infobox) then
    raise exception 'Complete all required infobox fields before review submission';
  end if;

  if tg_op='INSERT' then
    if new.author_id<>auth.uid() then raise exception 'Revision author must be the signed-in user'; end if;
    if new.status not in ('draft','pending_review') then raise exception 'Invalid revision status'; end if;
    if new.reviewer_id is not null or new.reviewed_at is not null then raise exception 'Review fields are restricted'; end if;
    return new;
  end if;

  if old.author_id<>auth.uid() then raise exception 'Only the revision author can edit it'; end if;
  if old.status not in ('draft','changes_requested') then raise exception 'This revision is no longer editable'; end if;
  if new.article_id is distinct from old.article_id or new.author_id is distinct from old.author_id
     or new.reviewer_id is distinct from old.reviewer_id or new.reviewed_at is distinct from old.reviewed_at then
    raise exception 'Restricted revision fields cannot be changed';
  end if;
  if new.status not in ('draft','pending_review') then raise exception 'Only draft or review submission is allowed'; end if;
  return new;
end;
$$;
revoke all on function public.enforce_revision_permissions() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Legal-consent integrity hardening.
-- ---------------------------------------------------------------------------
-- The append-only legal_acceptances history, not client-editable profile metadata,
-- is the authoritative proof that the current policy versions were accepted.
create or replace function public.has_current_legal_acceptance(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select uid is not null
    and uid = auth.uid()
    and exists (
      select 1
      from public.legal_acceptances la
      cross join public.current_legal_versions() v
      where la.user_id = uid
        and la.terms_version = v.terms_version
        and la.privacy_version = v.privacy_version
        and la.guidelines_version = v.guidelines_version
    );
$$;
revoke all on function public.has_current_legal_acceptance(uuid) from public, anon, authenticated;
grant execute on function public.has_current_legal_acceptance(uuid) to authenticated;

-- Self-service profile changes use a strict allowlist. The controlled legal flow
-- receives a transaction-local flag and may update only the legal consent columns.
create or replace function public.protect_profile_privileged_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  legal_flow boolean := coalesce(current_setting('zionxyos.legal_accept', true), '') = '1';
begin
  if auth.uid() is null then return new; end if;

  if old.role = 'sysadmin' and new.role is distinct from old.role then
    raise exception 'The protected sysadmin role can only be changed out-of-band';
  end if;
  if new.role = 'sysadmin' and old.role <> 'sysadmin' then
    raise exception 'The sysadmin role cannot be assigned through application sessions';
  end if;

  if public.is_sysadmin_mfa(auth.uid()) then return new; end if;

  if legal_flow and new.id = auth.uid() then
    if (to_jsonb(new) - array['terms_version','privacy_version','guidelines_version','legal_accepted_at','updated_at']::text[])
       is distinct from
       (to_jsonb(old) - array['terms_version','privacy_version','guidelines_version','legal_accepted_at','updated_at']::text[]) then
      raise exception 'Legal-consent flow may only change legal acceptance fields';
    end if;
    return new;
  end if;

  if new.id <> auth.uid() then raise exception 'Users may only update their own profile'; end if;
  if (to_jsonb(new) - array['display_name','bio','updated_at']::text[])
     is distinct from
     (to_jsonb(old) - array['display_name','bio','updated_at']::text[]) then
    raise exception 'Users may only change display name and biography';
  end if;
  return new;
end;
$$;
revoke all on function public.protect_profile_privileged_fields() from public, anon, authenticated;

create or replace function public.accept_current_legal(source_name text default 'web')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v record;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v from public.current_legal_versions();
  perform set_config('zionxyos.legal_accept','1',true);

  update public.profiles
  set terms_version=v.terms_version,
      privacy_version=v.privacy_version,
      guidelines_version=v.guidelines_version,
      legal_accepted_at=now()
  where id=auth.uid();

  insert into public.legal_acceptances(user_id,terms_version,privacy_version,guidelines_version,source)
  values(auth.uid(),v.terms_version,v.privacy_version,v.guidelines_version,
    case when source_name in ('signup','reconsent','web') then source_name else 'web' end);
end;
$$;
revoke all on function public.accept_current_legal(text) from public, anon, authenticated;
grant execute on function public.accept_current_legal(text) to authenticated;

-- Browser roles can read their authorized history but cannot forge, rewrite, or
-- erase consent records directly; only the trusted signup/re-consent functions append.
revoke insert, update, delete on public.legal_acceptances from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Notification integrity hardening.
-- ---------------------------------------------------------------------------
-- Users may acknowledge their own notifications but cannot rewrite notification
-- title/body/link metadata through direct PostgREST updates.
create or replace function public.mark_notification_read(notification_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  update public.notifications
  set read_at=coalesce(read_at,now())
  where id=notification_id and user_id=auth.uid();
end;
$$;
revoke all on function public.mark_notification_read(bigint) from public, anon, authenticated;
grant execute on function public.mark_notification_read(bigint) to authenticated;

drop policy if exists "notifications_own_update" on public.notifications;
drop policy if exists "notifications_admin_insert" on public.notifications;
revoke insert, update on public.notifications from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Moderation privilege hardening.
-- ---------------------------------------------------------------------------
-- A normal Admin may warn users and apply temporary mute/suspend actions, but an
-- indefinite blocking action is reserved for the Sysadmin just like a formal ban.
create or replace function public.admin_apply_moderation(
  target_uid uuid,
  action_kind text,
  action_reason text,
  action_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  action_id uuid;
  caller_role text;
  target_role text;
  notification_title text;
begin
  if not public.is_admin_mfa(auth.uid()) then raise exception 'Admin MFA session required'; end if;
  if target_uid = auth.uid() then raise exception 'You cannot moderate your own account'; end if;
  if action_kind not in ('warning','mute','suspend','ban') then raise exception 'Invalid moderation action'; end if;
  if nullif(trim(action_reason),'') is null then raise exception 'Reason is required'; end if;
  if action_expires_at is not null and action_expires_at <= now() then raise exception 'Moderation expiry must be in the future'; end if;

  select role into caller_role from public.profiles where id=auth.uid();
  select role into target_role from public.profiles where id=target_uid;
  if target_role is null then raise exception 'Target account not found'; end if;
  if target_role='sysadmin' then raise exception 'The sysadmin account is protected'; end if;
  if caller_role='admin' and target_role<>'user' then raise exception 'Admins can only moderate regular users'; end if;
  if caller_role='admin' and action_kind='ban' then raise exception 'Permanent bans require the sysadmin'; end if;
  if caller_role='admin' and action_kind in ('mute','suspend') and action_expires_at is null then
    raise exception 'Admins must use a finite expiry for mutes and suspensions';
  end if;

  insert into public.moderation_actions(user_id,kind,reason,created_by,expires_at)
  values(target_uid,action_kind,trim(action_reason),auth.uid(),case when action_kind='warning' then null else action_expires_at end)
  returning id into action_id;

  notification_title := case action_kind
    when 'warning' then 'Administrative warning'
    when 'mute' then 'Contribution access restricted'
    when 'suspend' then 'Account suspended'
    else 'Account banned' end;
  insert into public.notifications(user_id,kind,title,body,href)
  values(target_uid,'moderation.'||action_kind,notification_title,trim(action_reason),'/dashboard');
  insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
  values(auth.uid(),'moderation.'||action_kind,'user',target_uid,
    jsonb_build_object('moderation_action_id',action_id,'expires_at',action_expires_at,'reason',action_reason));
  return action_id;
end;
$$;
revoke all on function public.admin_apply_moderation(uuid,text,text,timestamptz) from public, anon, authenticated;
grant execute on function public.admin_apply_moderation(uuid,text,text,timestamptz) to authenticated;

-- Direct moderation table writes remain disabled; role/target rules live in the RPC.
drop policy if exists "moderation_admin_insert" on public.moderation_actions;
drop policy if exists "moderation_admin_update" on public.moderation_actions;

-- ---------------------------------------------------------------------------
-- Canonical article retention hardening.
-- ---------------------------------------------------------------------------
-- Published/canonical records are soft-deleted. Application sessions may hard-delete
-- only their own unpublished drafts; even the Sysadmin uses deleted_at for canonical
-- pages so revision history and auditability are preserved.
drop policy if exists "articles_author_or_admin_update" on public.articles;
create policy "articles_author_or_admin_update" on public.articles for update to authenticated
using (
  public.is_sysadmin_mfa(auth.uid())
  or (public.is_admin_mfa(auth.uid()) and public.can_edit_article(id,auth.uid()))
  or (author_id=auth.uid() and status='draft' and deleted_at is null
      and public.can_write_articles(auth.uid()) and public.can_edit_article(id,auth.uid()))
)
with check (
  public.is_sysadmin_mfa(auth.uid())
  or (public.is_admin_mfa(auth.uid()) and public.can_edit_article(id,auth.uid()))
  or (author_id=auth.uid() and status='draft'
      and public.can_write_articles(auth.uid()) and public.can_edit_article(id,auth.uid()))
);

drop policy if exists "articles_draft_owner_or_admin_delete" on public.articles;
create policy "articles_draft_owner_or_admin_delete" on public.articles for delete to authenticated
using (
  author_id=auth.uid()
  and status='draft'
  and deleted_at is null
  and public.can_write_articles(auth.uid())
  and public.can_edit_article(id,auth.uid())
);

-- Canonical retirement is atomic with its explicit audit reason.
create or replace function public.sysadmin_set_article_retired(article_uuid uuid, retire boolean, reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.articles%rowtype;
begin
  if not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;
  if nullif(trim(reason),'') is null then raise exception 'A retirement/restore reason is required'; end if;
  select * into a from public.articles where id=article_uuid for update;
  if not found then raise exception 'Article not found'; end if;

  if retire then
    if a.deleted_at is not null then raise exception 'Article is already retired'; end if;
    update public.articles set deleted_at=now(),deleted_by=auth.uid() where id=a.id;
    insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
    values(auth.uid(),'article.retired','article',a.id,jsonb_build_object('reason',trim(reason),'slug',a.slug));
  else
    if a.deleted_at is null then raise exception 'Article is not retired'; end if;
    update public.articles set deleted_at=null,deleted_by=null where id=a.id;
    insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
    values(auth.uid(),'article.restored','article',a.id,jsonb_build_object('reason',trim(reason),'slug',a.slug));
  end if;
  return a.slug;
end;
$$;
revoke all on function public.sysadmin_set_article_retired(uuid,boolean,text) from public, anon, authenticated;
grant execute on function public.sysadmin_set_article_retired(uuid,boolean,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Database-authoritative contribution throttling.
-- ---------------------------------------------------------------------------
-- The publishable Supabase key is intentionally present in the browser, so a user
-- can bypass a Next.js form action and call PostgREST directly. These triggers make
-- the important write limits apply at the database boundary as well.
create or replace function public.enforce_contribution_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  allowed boolean;
begin
  if auth.uid() is null or public.is_admin_mfa(auth.uid()) then return new; end if;

  if tg_table_name in ('articles','article_revisions') then
    allowed := public.consume_rate_limit('article_write','database',120,3600);
    if not allowed then raise exception 'Article write rate limit reached. Try again later.'; end if;
  elsif tg_table_name='discussion_posts' then
    allowed := public.consume_rate_limit('discussion','database',40,3600);
    if not allowed then raise exception 'Discussion rate limit reached. Try again later.'; end if;
  elsif tg_table_name='reports' then
    allowed := public.consume_rate_limit('report','database',20,3600);
    if not allowed then raise exception 'Report rate limit reached. Try again later.'; end if;
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_contribution_rate_limit() from public, anon, authenticated;

drop trigger if exists article_write_rate_limit on public.articles;
create trigger article_write_rate_limit before insert or update on public.articles
for each row execute procedure public.enforce_contribution_rate_limit();

drop trigger if exists revision_write_rate_limit on public.article_revisions;
create trigger revision_write_rate_limit before insert or update on public.article_revisions
for each row execute procedure public.enforce_contribution_rate_limit();

drop trigger if exists discussion_write_rate_limit on public.discussion_posts;
create trigger discussion_write_rate_limit before insert on public.discussion_posts
for each row execute procedure public.enforce_contribution_rate_limit();

drop trigger if exists report_write_rate_limit on public.reports;
create trigger report_write_rate_limit before insert on public.reports
for each row execute procedure public.enforce_contribution_rate_limit();


-- ---------------------------------------------------------------------------
-- Discussion / watchlist integrity hardening.
-- ---------------------------------------------------------------------------
-- Direct PostgREST clients must obey the same discussion-target rules as the
-- Next.js action: only live public articles may receive posts, and a reply must
-- point to a live post on that same article.
create or replace function public.can_post_discussion(
  article_uuid uuid,
  parent_uuid uuid default null,
  uid uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select uid is not null
     and uid = auth.uid()
     and public.is_active_contributor(uid)
     and coalesce((select (value #>> '{}')::boolean from public.site_settings where key='discussion_enabled'), true)
     and exists (
       select 1 from public.articles a
       where a.id=article_uuid and a.status='published' and a.deleted_at is null
     )
     and (
       parent_uuid is null
       or exists (
         select 1 from public.discussion_posts p
         where p.id=parent_uuid
           and p.article_id=article_uuid
           and p.removed_at is null
       )
     );
$$;
revoke all on function public.can_post_discussion(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.can_post_discussion(uuid,uuid,uuid) to authenticated;

drop policy if exists "discussion_active_insert" on public.discussion_posts;
create policy "discussion_active_insert" on public.discussion_posts for insert to authenticated
with check (
  user_id=auth.uid()
  and public.can_post_discussion(article_id,parent_id,auth.uid())
  and removed_at is null
  and removed_by is null
  and edited_at is null
);

-- Administrative discussion edits are removal/restoration metadata only. Once a
-- post is removed, its remover/timestamp cannot be silently rewritten; restoring
-- requires both fields to be cleared together.
create or replace function public.enforce_discussion_admin_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return new; end if;
  if not public.is_admin_mfa(auth.uid()) then raise exception 'Admin MFA session required'; end if;
  if (to_jsonb(new) - array['removed_at','removed_by']::text[])
     is distinct from
     (to_jsonb(old) - array['removed_at','removed_by']::text[]) then
    raise exception 'Discussion content and authorship are immutable';
  end if;

  if new.removed_at is null then
    if new.removed_by is not null then raise exception 'removed_by must be null when a post is visible'; end if;
  else
    if new.removed_by is distinct from auth.uid() then raise exception 'removed_by must be the current administrator'; end if;
    if old.removed_at is not null and (
      new.removed_at is distinct from old.removed_at
      or new.removed_by is distinct from old.removed_by
    ) then
      raise exception 'Existing removal metadata is immutable; restore the post before removing it again';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_discussion_admin_update() from public, anon, authenticated;

-- Watchlist membership has no UPDATE path. Users can read/delete only their own
-- rows, and can insert only a currently public canonical page. This prevents
-- guessed UUIDs from creating private/draft watchlist entries through PostgREST.
drop policy if exists "watchlist_own_all" on public.watchlist;
drop policy if exists "watchlist_own_read_v03" on public.watchlist;
drop policy if exists "watchlist_own_insert_v03" on public.watchlist;
drop policy if exists "watchlist_own_delete_v03" on public.watchlist;
create policy "watchlist_own_read_v03" on public.watchlist for select to authenticated
using (user_id=auth.uid());
create policy "watchlist_own_insert_v03" on public.watchlist for insert to authenticated
with check (
  user_id=auth.uid()
  and public.is_active_user(auth.uid())
  and exists (
    select 1 from public.articles a
    where a.id=article_id and a.status='published' and a.deleted_at is null
  )
);
create policy "watchlist_own_delete_v03" on public.watchlist for delete to authenticated
using (user_id=auth.uid());

-- Report resolution timestamps are server-controlled. Administrative updates may
-- change workflow metadata only; report identity and submitted content stay fixed.
create or replace function public.enforce_report_admin_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return new; end if;
  if not public.is_admin_mfa(auth.uid()) then raise exception 'Admin MFA session required'; end if;
  if (to_jsonb(new) - array['status','reviewed_by','reviewed_at','resolution_note']::text[])
     is distinct from
     (to_jsonb(old) - array['status','reviewed_by','reviewed_at','resolution_note']::text[]) then
    raise exception 'Report identity and submitted content are immutable';
  end if;
  if new.status not in ('reviewing','resolved','dismissed') then
    raise exception 'Invalid administrative report state';
  end if;
  new.reviewed_by := auth.uid();
  if new.status='reviewing' then
    new.reviewed_at := null;
  else
    new.reviewed_at := now();
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_report_admin_update() from public, anon, authenticated;

-- Bound large contributor-controlled article payloads at the database boundary as
-- well as in the Server Actions. NOT VALID avoids breaking an upgrade because of a
-- legacy row; PostgreSQL still enforces each constraint for new/changed rows.
alter table public.articles drop constraint if exists articles_content_size_v03;
alter table public.articles add constraint articles_content_size_v03
  check (char_length(content) <= 500000) not valid;
alter table public.articles drop constraint if exists articles_infobox_shape_v03;
alter table public.articles add constraint articles_infobox_shape_v03
  check (jsonb_typeof(infobox) = 'object' and pg_column_size(infobox) <= 65536) not valid;
alter table public.articles drop constraint if exists articles_creator_media_length_v03;
alter table public.articles add constraint articles_creator_media_length_v03
  check ((original_creator is null or char_length(original_creator) <= 200)
    and (cover_image_url is null or char_length(cover_image_url) <= 2000)
    and (video_url is null or char_length(video_url) <= 2000)) not valid;

alter table public.article_revisions drop constraint if exists revisions_content_size_v03;
alter table public.article_revisions add constraint revisions_content_size_v03
  check (char_length(content) <= 500000) not valid;
alter table public.article_revisions drop constraint if exists revisions_infobox_shape_v03;
alter table public.article_revisions add constraint revisions_infobox_shape_v03
  check (jsonb_typeof(infobox) = 'object' and pg_column_size(infobox) <= 65536) not valid;
alter table public.article_revisions drop constraint if exists revisions_creator_media_length_v03;
alter table public.article_revisions add constraint revisions_creator_media_length_v03
  check ((original_creator is null or char_length(original_creator) <= 200)
    and (cover_image_url is null or char_length(cover_image_url) <= 2000)
    and (video_url is null or char_length(video_url) <= 2000)) not valid;

-- A malicious PostgREST client cannot attach unbounded normalized taxonomy rows to
-- one draft. Serialize per revision so concurrent inserts cannot race the 100-item cap.
create or replace function public.enforce_revision_taxonomy_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  item_count integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('revision-taxonomy:' || new.revision_id::text, 0));
  if tg_table_name = 'revision_categories' then
    if exists (
      select 1 from public.revision_categories
      where revision_id = new.revision_id
        and category_id = ((to_jsonb(new)->>'category_id')::uuid)
    ) then return new; end if;
    select count(*) into item_count from public.revision_categories where revision_id = new.revision_id;
  elsif tg_table_name = 'revision_tags' then
    if exists (
      select 1 from public.revision_tags
      where revision_id = new.revision_id
        and tag_id = ((to_jsonb(new)->>'tag_id')::uuid)
    ) then return new; end if;
    select count(*) into item_count from public.revision_tags where revision_id = new.revision_id;
  else
    raise exception 'Unexpected taxonomy trigger table';
  end if;
  if item_count >= 100 then raise exception 'A revision cannot contain more than 100 categories or tags of one kind'; end if;
  return new;
end;
$$;
revoke all on function public.enforce_revision_taxonomy_limit() from public, anon, authenticated;

drop trigger if exists revision_categories_limit_v03 on public.revision_categories;
create trigger revision_categories_limit_v03 before insert on public.revision_categories
  for each row execute procedure public.enforce_revision_taxonomy_limit();
drop trigger if exists revision_tags_limit_v03 on public.revision_tags;
create trigger revision_tags_limit_v03 before insert on public.revision_tags
  for each row execute procedure public.enforce_revision_taxonomy_limit();

-- Final privacy boundary cleanup for legacy read policies. The old v0.1/v0.2
-- policies let the raw sysadmin role bypass notification/version privacy without
-- proving MFA. Notifications are strictly personal; legacy article versions remain
-- visible to the article author and to an AAL2 sysadmin only.
drop policy if exists "notifications_own_read" on public.notifications;
create policy "notifications_own_read" on public.notifications for select to authenticated
using (user_id = auth.uid());

drop policy if exists "versions_author_or_admin_read" on public.article_versions;
create policy "versions_author_or_admin_read" on public.article_versions for select to authenticated
using (
  public.is_sysadmin_mfa(auth.uid())
  or exists (
    select 1 from public.articles a
    where a.id = article_versions.article_id and a.author_id = auth.uid()
  )
);

-- Signup race hardening. The application checks username availability for good UX,
-- while the Auth trigger still handles a simultaneous duplicate safely so a race
-- cannot abort account creation with a profile unique-constraint error.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_username text;
  fallback_username text := 'user_' || left(replace(new.id::text,'-',''), 18);
  accepted boolean := false;
  v record;
begin
  if coalesce((select (value #>> '{}')::boolean from public.site_settings where key='registration_enabled'), true) = false then
    raise exception 'Registration is currently disabled';
  end if;
  select * into v from public.current_legal_versions();
  requested_username := lower(coalesce(new.raw_user_meta_data ->> 'username', fallback_username));

  if requested_username !~ '^[a-z0-9_]{3,24}$'
     or requested_username in ('admin','administrator','root','sysadmin','system','support','moderator','staff','zionxyos','api','security','help') then
    requested_username := fallback_username;
  end if;

  accepted := coalesce(new.raw_user_meta_data ->> 'legal_acceptance', '') = 'true'
    and new.raw_user_meta_data ->> 'terms_version' = v.terms_version
    and new.raw_user_meta_data ->> 'privacy_version' = v.privacy_version
    and new.raw_user_meta_data ->> 'guidelines_version' = v.guidelines_version;

  begin
    insert into public.profiles (
      id, username, terms_version, privacy_version, guidelines_version, legal_accepted_at
    ) values (
      new.id,
      requested_username,
      case when accepted then v.terms_version else null end,
      case when accepted then v.privacy_version else null end,
      case when accepted then v.guidelines_version else null end,
      case when accepted then now() else null end
    );
  exception when unique_violation then
    -- A concurrent signup may win the requested username after the UI availability
    -- check. Fall back to a UUID-derived valid username instead of breaking Auth.
    insert into public.profiles (
      id, username, terms_version, privacy_version, guidelines_version, legal_accepted_at
    ) values (
      new.id,
      fallback_username,
      case when accepted then v.terms_version else null end,
      case when accepted then v.privacy_version else null end,
      case when accepted then v.guidelines_version else null end,
      case when accepted then now() else null end
    );
  end;

  if accepted then
    insert into public.legal_acceptances(user_id, terms_version, privacy_version, guidelines_version, source)
    values (new.id, v.terms_version, v.privacy_version, v.guidelines_version, 'signup');
  end if;
  return new;
end;
$$;
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- Serialize each rate-limit bucket before counting/inserting. Without this lock,
-- simultaneous requests for the same user/action could race between COUNT and INSERT
-- and temporarily exceed the configured threshold.
create or replace function public.consume_rate_limit(
  action_name text,
  subject_key text,
  max_events integer,
  window_seconds integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  event_count integer;
  effective_subject text;
begin
  if action_name not in ('register','login','password_reset','article_write','report','discussion','media_upload') then
    raise exception 'Unsupported rate-limit action';
  end if;
  max_events := greatest(1, least(max_events, 100));
  window_seconds := greatest(60, least(window_seconds, 86400));

  if auth.uid() is null then
    if action_name not in ('register','login','password_reset') then raise exception 'Authentication required'; end if;
    if subject_key !~ '^[a-f0-9]{64}$' then raise exception 'Invalid anonymous rate-limit subject'; end if;
    effective_subject := subject_key;
  else
    if action_name in ('register','login','password_reset') then raise exception 'Anonymous rate-limit action expected'; end if;
    effective_subject := auth.uid()::text;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(action_name || ':' || effective_subject, 0));
  delete from public.rate_limit_events where created_at < now() - interval '2 days';
  select count(*) into event_count from public.rate_limit_events
  where action = action_name and subject = effective_subject
    and created_at >= now() - make_interval(secs => window_seconds);
  if event_count >= max_events then return false; end if;
  insert into public.rate_limit_events(action, subject) values (action_name, effective_subject);
  return true;
end;
$$;
revoke all on function public.consume_rate_limit(text,text,integer,integer) from public, anon, authenticated;
grant execute on function public.consume_rate_limit(text,text,integer,integer) to anon, authenticated;

-- Public community metadata follows the lifecycle of the public canonical page.
-- Retiring a page must also make its discussion and notice assignments disappear
-- from anonymous/direct PostgREST reads while preserving them for MFA staff.
drop policy if exists "discussion_public_read_v03" on public.discussion_posts;
drop policy if exists "discussion_authenticated_read_v03" on public.discussion_posts;
create policy "discussion_public_read_v03" on public.discussion_posts for select to anon
using (
  removed_at is null
  and exists(select 1 from public.articles a where a.id=article_id and a.status='published' and a.deleted_at is null)
);
create policy "discussion_authenticated_read_v03" on public.discussion_posts for select to authenticated
using (
  (removed_at is null and exists(select 1 from public.articles a where a.id=article_id and a.status='published' and a.deleted_at is null))
  or public.is_admin_mfa(auth.uid())
);

drop policy if exists "article_notices_read" on public.article_notices;
drop policy if exists "article_notices_public_read_v03" on public.article_notices;
drop policy if exists "article_notices_authenticated_read_v03" on public.article_notices;
create policy "article_notices_public_read_v03" on public.article_notices for select to anon
using (exists(select 1 from public.articles a where a.id=article_id and a.status='published' and a.deleted_at is null));
create policy "article_notices_authenticated_read_v03" on public.article_notices for select to authenticated
using (
  exists(select 1 from public.articles a where a.id=article_id and a.status='published' and a.deleted_at is null)
  or public.is_admin_mfa(auth.uid())
);

-- Privileged capability helpers must reflect the same account-state and legal gates
-- as the Next.js Administration entry point. A suspended/banned or legally stale
-- staff session keeps its role claim but cannot use that role through direct RPC/RLS.
create or replace function public.is_admin_mfa(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select uid is not null
     and uid = auth.uid()
     and public.is_admin(uid)
     and public.has_aal2()
     and public.is_active_user(uid)
     and public.has_current_legal_acceptance(uid);
$$;
revoke all on function public.is_admin_mfa(uuid) from public, anon, authenticated;
grant execute on function public.is_admin_mfa(uuid) to authenticated;

create or replace function public.is_sysadmin_mfa(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select uid is not null
     and uid = auth.uid()
     and public.is_sysadmin(uid)
     and public.has_aal2()
     and public.is_active_user(uid)
     and public.has_current_legal_acceptance(uid);
$$;
revoke all on function public.is_sysadmin_mfa(uuid) from public, anon, authenticated;
grant execute on function public.is_sysadmin_mfa(uuid) to authenticated;

-- System Settings are saved as one transaction. Calling the single-setting helper
-- inside this SECURITY DEFINER routine preserves the same validation/audit rules,
-- while any invalid value rolls the entire form submission back atomically.
create or replace function public.sysadmin_set_settings(settings_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  setting_key text;
  setting_value jsonb;
  setting_count integer;
begin
  if not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;
  if jsonb_typeof(settings_payload) <> 'object' then raise exception 'Settings payload must be an object'; end if;
  setting_count := (select count(*) from jsonb_object_keys(settings_payload));
  if setting_count < 1 or setting_count > 25 then raise exception 'Invalid settings payload size'; end if;
  for setting_key, setting_value in select key, value from jsonb_each(settings_payload) loop
    perform public.sysadmin_set_setting(setting_key, setting_value);
  end loop;
end;
$$;
revoke all on function public.sysadmin_set_settings(jsonb) from public, anon, authenticated;
grant execute on function public.sysadmin_set_settings(jsonb) to authenticated;
-- The single-setting helper is now internal to the atomic bulk RPC. Browser callers
-- cannot intentionally create partial configuration updates one key at a time.
revoke all on function public.sysadmin_set_setting(text,jsonb) from public, anon, authenticated;

-- Editorial notice changes are administrative publication metadata and are audited
-- just like moderation, review, taxonomy merge, settings, and article retirement.
create or replace function public.audit_notice_template_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_id uuid := case when tg_op='DELETE' then old.id else new.id end;
  row_name text := case when tg_op='DELETE' then old.name else new.name end;
  row_kind text := case when tg_op='DELETE' then old.kind else new.kind end;
  row_active boolean := case when tg_op='DELETE' then old.active else new.active end;
begin
  insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
  values(auth.uid(),'notice_template.'||lower(tg_op),'notice_template',row_id,
    jsonb_build_object('name',row_name,'kind',row_kind,'active',row_active));
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.audit_notice_template_change() from public, anon, authenticated;
drop trigger if exists notice_templates_audit_v03 on public.notice_templates;
create trigger notice_templates_audit_v03 after insert or update or delete on public.notice_templates
for each row execute procedure public.audit_notice_template_change();

create or replace function public.audit_article_notice_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  article_uuid uuid := case when tg_op='DELETE' then old.article_id else new.article_id end;
  notice_uuid uuid := case when tg_op='DELETE' then old.notice_id else new.notice_id end;
begin
  insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
  values(auth.uid(),'article_notice.'||lower(tg_op),'article',article_uuid,
    jsonb_build_object('notice_id',notice_uuid));
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.audit_article_notice_change() from public, anon, authenticated;
drop trigger if exists article_notices_audit_v03 on public.article_notices;
create trigger article_notices_audit_v03 after insert or delete on public.article_notices
for each row execute procedure public.audit_article_notice_change();

-- Direct administrative report/discussion mutations also feed the audit trail.
create or replace function public.audit_report_workflow_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status
     or new.reviewed_by is distinct from old.reviewed_by
     or new.reviewed_at is distinct from old.reviewed_at
     or new.resolution_note is distinct from old.resolution_note then
    insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
    values(auth.uid(),'report.workflow_update','report',new.id,
      jsonb_build_object('old_status',old.status,'new_status',new.status,'reviewed_by',new.reviewed_by));
  end if;
  return new;
end;
$$;
revoke all on function public.audit_report_workflow_change() from public, anon, authenticated;
drop trigger if exists reports_audit_workflow_v03 on public.reports;
create trigger reports_audit_workflow_v03 after update on public.reports
for each row execute procedure public.audit_report_workflow_change();

create or replace function public.audit_discussion_moderation_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.removed_at is distinct from old.removed_at or new.removed_by is distinct from old.removed_by then
    insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
    values(auth.uid(),case when new.removed_at is null then 'discussion.restored' else 'discussion.removed' end,
      'discussion',new.id,jsonb_build_object('article_id',new.article_id,'removed_by',new.removed_by));
  end if;
  return new;
end;
$$;
revoke all on function public.audit_discussion_moderation_change() from public, anon, authenticated;
drop trigger if exists discussion_posts_audit_moderation_v03 on public.discussion_posts;
create trigger discussion_posts_audit_moderation_v03 after update on public.discussion_posts
for each row execute procedure public.audit_discussion_moderation_change();

-- ---------------------------------------------------------------------------
-- Controlled profile-role mutation hardening.
-- ---------------------------------------------------------------------------
-- v0.1 granted browser roles UPDATE(role,suspended) and relied on RLS/trigger
-- checks. v0.3 removes that direct grant entirely: application role changes pass
-- through one MFA-backed Sysadmin RPC, while suspension remains a moderation RPC
-- concern (or an explicit out-of-band emergency database operation).
create or replace function public.sysadmin_set_user_role(target_uid uuid, requested_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_role text;
begin
  if not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;
  if target_uid is null then raise exception 'Target account is required'; end if;
  if target_uid = auth.uid() then raise exception 'The protected sysadmin cannot change its own role here'; end if;
  if requested_role not in ('user','admin') then raise exception 'Only user or admin may be assigned'; end if;

  select role into target_role from public.profiles where id=target_uid for update;
  if target_role is null then raise exception 'Target account not found'; end if;
  if target_role='sysadmin' then raise exception 'The protected sysadmin role cannot be changed'; end if;
  if target_role=requested_role then return; end if;

  update public.profiles set role=requested_role where id=target_uid;
  -- The existing profile audit trigger records the old/new role and authenticated actor.
end;
$$;
revoke all on function public.sysadmin_set_user_role(uuid,text) from public, anon, authenticated;
grant execute on function public.sysadmin_set_user_role(uuid,text) to authenticated;

-- Browser sessions no longer receive direct column privileges for role/suspension.
revoke update (role, suspended) on public.profiles from authenticated;

-- Profile UPDATE RLS is self-service only. SECURITY DEFINER legal/role workflows
-- bypass table grants/RLS in their tightly scoped routines instead of exposing a
-- broad privileged direct-update path to a browser session.
drop policy if exists "profiles_self_update" on public.profiles;
create policy "profiles_self_update" on public.profiles for update to authenticated
using (id=auth.uid() and public.is_active_user(auth.uid()))
with check (id=auth.uid() and public.is_active_user(auth.uid()));

-- ---------------------------------------------------------------------------
-- Announcement integrity and audit hardening.
-- ---------------------------------------------------------------------------
-- Announcements are public-facing operational content. Even the Sysadmin browser
-- session cannot forge their creator/creation timestamp or persist an invalid time
-- window through direct PostgREST writes.
create or replace function public.enforce_announcement_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_sysadmin_mfa(auth.uid()) then
    raise exception 'Sysadmin MFA session required';
  end if;
  if nullif(btrim(new.title),'') is null or char_length(new.title)>160 then raise exception 'Invalid announcement title'; end if;
  if nullif(btrim(new.body),'') is null or char_length(new.body)>2000 then raise exception 'Invalid announcement body'; end if;
  if new.kind not in ('info','warning','maintenance') then raise exception 'Invalid announcement kind'; end if;
  if new.audience not in ('all','authenticated','staff') then raise exception 'Invalid announcement audience'; end if;
  if new.ends_at is not null and new.ends_at<=new.starts_at then raise exception 'Announcement expiry must be after its start time'; end if;

  if tg_op='INSERT' then
    new.created_by := auth.uid();
    new.created_at := now();
    return new;
  end if;
  if new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'Announcement creator metadata is immutable';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_announcement_integrity() from public, anon, authenticated;
drop trigger if exists announcements_integrity_v03 on public.site_announcements;
create trigger announcements_integrity_v03 before insert or update on public.site_announcements
for each row execute procedure public.enforce_announcement_integrity();

create or replace function public.audit_announcement_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_id uuid := case when tg_op='DELETE' then old.id else new.id end;
  row_title text := case when tg_op='DELETE' then old.title else new.title end;
  row_audience text := case when tg_op='DELETE' then old.audience else new.audience end;
  row_active boolean := case when tg_op='DELETE' then old.active else new.active end;
begin
  insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
  values(auth.uid(),'announcement.'||lower(tg_op),'announcement',row_id,
    jsonb_build_object('title',row_title,'audience',row_audience,'active',row_active));
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.audit_announcement_change() from public, anon, authenticated;
drop trigger if exists announcements_audit_v03 on public.site_announcements;
create trigger announcements_audit_v03 after insert or update or delete on public.site_announcements
for each row execute procedure public.audit_announcement_change();

-- Bind INSERT ownership at the policy layer too; trigger enforcement is defense in depth.
drop policy if exists "announcements_sysadmin_write" on public.site_announcements;
drop policy if exists "announcements_sysadmin_insert_v03" on public.site_announcements;
drop policy if exists "announcements_sysadmin_update_v03" on public.site_announcements;
drop policy if exists "announcements_sysadmin_delete_v03" on public.site_announcements;
create policy "announcements_sysadmin_insert_v03" on public.site_announcements for insert to authenticated
with check (public.is_sysadmin_mfa(auth.uid()) and created_by=auth.uid());
create policy "announcements_sysadmin_update_v03" on public.site_announcements for update to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));
create policy "announcements_sysadmin_delete_v03" on public.site_announcements for delete to authenticated
using (public.is_sysadmin_mfa(auth.uid()));

-- ---------------------------------------------------------------------------
-- Editorial notice-template creator integrity.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_notice_template_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;
  if nullif(btrim(new.name),'') is null or char_length(new.name)>100 then raise exception 'Invalid notice template name'; end if;
  if nullif(btrim(new.body),'') is null or char_length(new.body)>1000 then raise exception 'Invalid notice template body'; end if;
  if new.kind not in ('info','warning','maintenance','quality') then raise exception 'Invalid notice template kind'; end if;
  if tg_op='INSERT' then
    new.created_by := auth.uid();
    new.created_at := now();
    return new;
  end if;
  if new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'Notice template creator metadata is immutable';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_notice_template_integrity() from public, anon, authenticated;
drop trigger if exists notice_templates_integrity_v03 on public.notice_templates;
create trigger notice_templates_integrity_v03 before insert or update on public.notice_templates
for each row execute procedure public.enforce_notice_template_integrity();

-- Split template writes so INSERT also binds the actor at RLS level.
drop policy if exists "notice_templates_sysadmin_write" on public.notice_templates;
drop policy if exists "notice_templates_sysadmin_insert_v03" on public.notice_templates;
drop policy if exists "notice_templates_sysadmin_update_v03" on public.notice_templates;
drop policy if exists "notice_templates_sysadmin_delete_v03" on public.notice_templates;
create policy "notice_templates_sysadmin_insert_v03" on public.notice_templates for insert to authenticated
with check (public.is_sysadmin_mfa(auth.uid()) and created_by=auth.uid());
create policy "notice_templates_sysadmin_update_v03" on public.notice_templates for update to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));
create policy "notice_templates_sysadmin_delete_v03" on public.notice_templates for delete to authenticated
using (public.is_sysadmin_mfa(auth.uid()));

-- Internal-note targeting follows the same staff hierarchy as moderation: a normal
-- Admin may annotate regular-user cases, while only the Sysadmin may annotate staff.
drop policy if exists "admin_notes_admin_insert" on public.admin_user_notes;
create policy "admin_notes_admin_insert" on public.admin_user_notes for insert to authenticated
with check (
  created_by=auth.uid()
  and public.is_admin_mfa(auth.uid())
  and exists (
    select 1 from public.profiles target
    where target.id=user_id
      and (public.is_sysadmin_mfa(auth.uid()) or target.role='user')
  )
);

-- System settings are browser-read / RPC-write. Direct PostgREST mutation would
-- bypass the strict per-key validator and the all-or-nothing batch transaction.
drop policy if exists "settings_sysadmin_write" on public.site_settings;
revoke insert, update, delete on public.site_settings from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Article-Type infobox schema contract at the database boundary.
-- ---------------------------------------------------------------------------
create or replace function public.is_valid_infobox_schema(schema_value jsonb)
returns boolean
language sql
immutable
set search_path = public
as $$
  select jsonb_typeof(schema_value)='array'
    and jsonb_array_length(schema_value)<=40
    and not exists (
      select 1 from jsonb_array_elements(schema_value) field
      where jsonb_typeof(field)<>'object'
         or nullif(btrim(field->>'key'),'') is null
         or char_length(field->>'key')>80
         or (field->>'key') !~ '^[A-Za-z0-9_-]+$'
         or nullif(btrim(field->>'label'),'') is null
         or char_length(field->>'label')>80
         or (field ? 'required' and jsonb_typeof(field->'required')<>'boolean')
         or (field ? 'placeholder' and (jsonb_typeof(field->'placeholder')<>'string' or char_length(field->>'placeholder')>160))
    )
    and (
      select count(*)=count(distinct lower(field->>'key'))
        and count(*)=count(distinct lower(field->>'label'))
      from jsonb_array_elements(schema_value) field
    );
$$;
revoke all on function public.is_valid_infobox_schema(jsonb) from public, anon, authenticated;
grant execute on function public.is_valid_infobox_schema(jsonb) to authenticated;

alter table public.article_types drop constraint if exists article_types_infobox_schema_valid_v03;
alter table public.article_types add constraint article_types_infobox_schema_valid_v03
check (public.is_valid_infobox_schema(infobox_schema));

-- ---------------------------------------------------------------------------
-- Revision-taxonomy least privilege.
-- ---------------------------------------------------------------------------
-- The editor only adds/removes normalized relations; UPDATE is unnecessary and
-- made it possible for a direct PostgREST client to retarget a relation in place.
-- New assignments must also reference active controlled taxonomy immediately,
-- not merely wait for approval-time validation.
drop policy if exists "revision_categories_write" on public.revision_categories;
drop policy if exists "revision_categories_insert_v03" on public.revision_categories;
drop policy if exists "revision_categories_delete_v03" on public.revision_categories;
create policy "revision_categories_insert_v03" on public.revision_categories for insert to authenticated
with check (
  exists (
    select 1 from public.article_revisions r
    where r.id=revision_id and (
      (public.is_admin_mfa(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
      or (r.author_id=auth.uid() and r.status in ('draft','changes_requested')
          and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    )
  )
  and exists (select 1 from public.categories c where c.id=category_id and c.active)
);
create policy "revision_categories_delete_v03" on public.revision_categories for delete to authenticated
using (
  exists (
    select 1 from public.article_revisions r
    where r.id=revision_id and (
      (public.is_admin_mfa(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
      or (r.author_id=auth.uid() and r.status in ('draft','changes_requested')
          and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    )
  )
);

drop policy if exists "revision_tags_write" on public.revision_tags;
drop policy if exists "revision_tags_insert_v03" on public.revision_tags;
drop policy if exists "revision_tags_delete_v03" on public.revision_tags;
create policy "revision_tags_insert_v03" on public.revision_tags for insert to authenticated
with check (
  exists (
    select 1 from public.article_revisions r
    where r.id=revision_id and (
      (public.is_admin_mfa(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
      or (r.author_id=auth.uid() and r.status in ('draft','changes_requested')
          and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    )
  )
  and exists (select 1 from public.controlled_tags t where t.id=tag_id and t.active)
);
create policy "revision_tags_delete_v03" on public.revision_tags for delete to authenticated
using (
  exists (
    select 1 from public.article_revisions r
    where r.id=revision_id and (
      (public.is_admin_mfa(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
      or (r.author_id=auth.uid() and r.status in ('draft','changes_requested')
          and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    )
  )
);
revoke update on public.revision_categories, public.revision_tags from anon, authenticated;

-- ---------------------------------------------------------------------------
-- System-update history integrity.
-- ---------------------------------------------------------------------------
-- Update/deploy history is an audit surface. Browser sessions can read it through
-- RLS but cannot forge requested_by, timestamps, actions, or arbitrary details.
create or replace function public.sysadmin_record_update_history(
  action_name text,
  from_version_value text,
  target_version_value text,
  status_name text,
  details_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  history_id uuid;
begin
  if not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;
  if action_name not in ('check','deploy_hook','note') then raise exception 'Invalid update-history action'; end if;
  if status_name not in ('requested','success','failed','informational') then raise exception 'Invalid update-history status'; end if;
  if char_length(coalesce(from_version_value,'')) > 40 or char_length(coalesce(target_version_value,'')) > 40 then
    raise exception 'Update-history version value is too long';
  end if;
  if jsonb_typeof(coalesce(details_payload,'{}'::jsonb)) <> 'object' then raise exception 'Update-history details must be a JSON object'; end if;
  if octet_length(coalesce(details_payload,'{}'::jsonb)::text) > 16384 then raise exception 'Update-history details are too large'; end if;

  insert into public.system_update_history(requested_by,action,from_version,target_version,status,details)
  values(auth.uid(),action_name,nullif(trim(from_version_value),''),nullif(trim(target_version_value),''),status_name,coalesce(details_payload,'{}'::jsonb))
  returning id into history_id;
  return history_id;
end;
$$;
revoke all on function public.sysadmin_record_update_history(text,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.sysadmin_record_update_history(text,text,text,text,jsonb) to authenticated;
drop policy if exists "update_history_sysadmin_insert" on public.system_update_history;
revoke insert, update, delete on public.system_update_history from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Browser table-privilege minimization.
-- ---------------------------------------------------------------------------
-- Moderation lifecycle mutations are RPC-only; internal notes are append-only;
-- announcements are immutable after publishing (delete/recreate is the UI model).
revoke insert, update, delete on public.moderation_actions from anon, authenticated;
revoke update, delete on public.admin_user_notes from anon, authenticated;
drop policy if exists "announcements_sysadmin_update_v03" on public.site_announcements;
revoke update on public.site_announcements from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Revision-history retention.
-- ---------------------------------------------------------------------------
-- The application never hard-deletes an individual revision. Contributor draft
-- article deletion may cascade its private revisions through the FK, but browser
-- sessions cannot selectively erase editorial history (including approved rows).
drop policy if exists "revisions_draft_author_admin_delete" on public.article_revisions;
revoke delete on public.article_revisions from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Approved revision immutability.
-- ---------------------------------------------------------------------------
-- Staff may correct a pending revision before a decision, but approved/rejected
-- history is immutable to browser sessions. Publication-state transitions happen
-- only inside the protected review RPC through the transaction-local review flag.
drop policy if exists "revisions_author_admin_update" on public.article_revisions;
create policy "revisions_author_admin_update" on public.article_revisions for update to authenticated
using (
  (public.is_admin_mfa(auth.uid()) and status='pending_review' and public.can_edit_article(article_id,auth.uid()))
  or (author_id=auth.uid() and status in ('draft','changes_requested')
      and public.can_write_articles(auth.uid()) and public.can_edit_article(article_id,auth.uid()))
)
with check (
  (public.is_admin_mfa(auth.uid()) and status='pending_review' and public.can_edit_article(article_id,auth.uid()))
  or (author_id=auth.uid() and status in ('draft','pending_review')
      and public.can_write_articles(auth.uid()) and public.can_edit_article(article_id,auth.uid()))
);

create or replace function public.enforce_revision_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  review_publish boolean := coalesce(current_setting('zionxyos.review_publish', true), '') = '1';
  type_slug text;
  target_article_id uuid;
begin
  target_article_id := case when tg_op='INSERT' then new.article_id else old.article_id end;
  if auth.uid() is null then return new; end if;

  if review_publish and public.is_admin_mfa(auth.uid()) then
    if not public.can_edit_article(target_article_id,auth.uid()) then
      raise exception 'Page protection does not permit this reviewer to modify the revision';
    end if;
    return new;
  end if;

  if public.is_admin_mfa(auth.uid()) and tg_op='UPDATE' and old.status='pending_review' then
    if not public.can_edit_article(old.article_id,auth.uid()) then
      raise exception 'Page protection does not permit this administrator to edit the revision';
    end if;
    if new.article_id is distinct from old.article_id
       or new.author_id is distinct from old.author_id
       or new.status is distinct from old.status
       or new.reviewer_id is distinct from old.reviewer_id
       or new.review_note is distinct from old.review_note
       or new.submitted_at is distinct from old.submitted_at
       or new.reviewed_at is distinct from old.reviewed_at then
      raise exception 'Pending revision ownership and review state are restricted';
    end if;
    return new;
  end if;

  if not public.can_write_articles(auth.uid()) or not public.can_edit_article(target_article_id,auth.uid()) then
    raise exception 'Article writing or page protection does not permit this revision change';
  end if;
  if nullif(trim(new.title),'') is null then raise exception 'Revision title is required'; end if;
  select t.slug into type_slug from public.article_types t where t.id=new.article_type_id and t.active;
  if type_slug is null then raise exception 'Revision article type must be active'; end if;
  new.article_type := type_slug;
  if new.cover_image_url is not null and new.cover_image_url !~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' then raise exception 'Image URL must use HTTPS'; end if;
  if new.video_url is not null and new.video_url !~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' then raise exception 'Video URL must use HTTPS'; end if;
  if new.cover_media_id is not null and not exists(select 1 from public.media_assets m where m.id=new.cover_media_id and m.owner_id=auth.uid() and m.media_kind='image' and m.deleted_at is null) then
    raise exception 'Cover media must be an active image owned by the revision author';
  end if;
  if new.video_media_id is not null and not exists(select 1 from public.media_assets m where m.id=new.video_media_id and m.owner_id=auth.uid() and m.media_kind='video' and m.deleted_at is null) then
    raise exception 'Video media must be an active video owned by the revision author';
  end if;
  if new.status='pending_review' and nullif(trim(new.content),'') is null then raise exception 'Content is required before review submission'; end if;
  if new.status='pending_review' and not public.required_infobox_complete(new.article_type_id,new.infobox) then
    raise exception 'Complete all required infobox fields before review submission';
  end if;

  if tg_op='INSERT' then
    if new.author_id<>auth.uid() then raise exception 'Revision author must be the signed-in user'; end if;
    if new.status not in ('draft','pending_review') then raise exception 'Invalid revision status'; end if;
    if new.reviewer_id is not null or new.reviewed_at is not null then raise exception 'Review fields are restricted'; end if;
    return new;
  end if;

  if old.author_id<>auth.uid() then raise exception 'Only the revision author can edit it'; end if;
  if old.status not in ('draft','changes_requested') then raise exception 'This revision is no longer editable'; end if;
  if new.article_id is distinct from old.article_id or new.author_id is distinct from old.author_id
     or new.reviewer_id is distinct from old.reviewer_id or new.reviewed_at is distinct from old.reviewed_at then
    raise exception 'Restricted revision fields cannot be changed';
  end if;
  if new.status not in ('draft','pending_review') then raise exception 'Only draft or review submission is allowed'; end if;
  return new;
end;
$$;
revoke all on function public.enforce_revision_permissions() from public, anon, authenticated;

-- Normalized taxonomy attached to approved/rejected history is immutable too.
drop policy if exists "revision_categories_insert_v03" on public.revision_categories;
drop policy if exists "revision_categories_delete_v03" on public.revision_categories;
create policy "revision_categories_insert_v03" on public.revision_categories for insert to authenticated
with check (
  exists (
    select 1 from public.article_revisions r where r.id=revision_id and (
      (public.is_admin_mfa(auth.uid()) and r.status='pending_review' and public.can_edit_article(r.article_id,auth.uid()))
      or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    )
  ) and exists (select 1 from public.categories c where c.id=category_id and c.active)
);
create policy "revision_categories_delete_v03" on public.revision_categories for delete to authenticated
using (
  exists (
    select 1 from public.article_revisions r where r.id=revision_id and (
      (public.is_admin_mfa(auth.uid()) and r.status='pending_review' and public.can_edit_article(r.article_id,auth.uid()))
      or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    )
  )
);

drop policy if exists "revision_tags_insert_v03" on public.revision_tags;
drop policy if exists "revision_tags_delete_v03" on public.revision_tags;
create policy "revision_tags_insert_v03" on public.revision_tags for insert to authenticated
with check (
  exists (
    select 1 from public.article_revisions r where r.id=revision_id and (
      (public.is_admin_mfa(auth.uid()) and r.status='pending_review' and public.can_edit_article(r.article_id,auth.uid()))
      or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    )
  ) and exists (select 1 from public.controlled_tags t where t.id=tag_id and t.active)
);
create policy "revision_tags_delete_v03" on public.revision_tags for delete to authenticated
using (
  exists (
    select 1 from public.article_revisions r where r.id=revision_id and (
      (public.is_admin_mfa(auth.uid()) and r.status='pending_review' and public.can_edit_article(r.article_id,auth.uid()))
      or (r.author_id=auth.uid() and r.status in ('draft','changes_requested') and public.can_write_articles(auth.uid()) and public.can_edit_article(r.article_id,auth.uid()))
    )
  )
);

-- ---------------------------------------------------------------------------
-- Canonical article mutation integrity.
-- ---------------------------------------------------------------------------
-- Sysadmin authority does not imply permission to rewrite published content
-- outside the editorial workflow. Direct staff UPDATE is limited to page
-- protection/featured metadata; retirement uses a narrowly-scoped RPC flag.
create or replace function public.enforce_article_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  review_publish boolean := coalesce(current_setting('zionxyos.review_publish', true), '') = '1';
  retire_flow boolean := coalesce(current_setting('zionxyos.article_retire', true), '') = '1';
  protection_changed boolean := new.protection_level is distinct from old.protection_level
    or new.protection_reason is distinct from old.protection_reason
    or new.protected_until is distinct from old.protected_until;
begin
  if auth.uid() is null then return new; end if;

  if protection_changed then
    if new.protection_level not in ('open','admin','sysadmin') then raise exception 'Invalid page protection level'; end if;
    if new.protection_level <> 'open' and nullif(trim(new.protection_reason),'') is null then raise exception 'A protection reason is required'; end if;
    if new.protected_until is not null and new.protected_until <= now() then raise exception 'Protection expiry must be in the future'; end if;
  end if;

  if review_publish and public.is_admin_mfa(auth.uid()) then
    if not public.can_edit_article(old.id,auth.uid()) then raise exception 'Page protection does not permit this reviewer to modify the article'; end if;
    return new;
  end if;

  if retire_flow and public.is_sysadmin_mfa(auth.uid()) then
    if (to_jsonb(new) - array['deleted_at','deleted_by','updated_at']::text[])
       is distinct from (to_jsonb(old) - array['deleted_at','deleted_by','updated_at']::text[]) then
      raise exception 'Article retirement may only change retirement metadata';
    end if;
    if new.deleted_at is null then
      if new.deleted_by is not null then raise exception 'Restored article must clear deleted_by'; end if;
    else
      if new.deleted_by is distinct from auth.uid() then raise exception 'Retired article must record the current sysadmin'; end if;
    end if;
    return new;
  end if;

  if public.is_admin_mfa(auth.uid()) then
    if not public.is_sysadmin_mfa(auth.uid()) and (old.protection_level='sysadmin' or new.protection_level='sysadmin') then
      raise exception 'Only the sysadmin may manage sysadmin-only page protection';
    end if;
    if not public.can_edit_article(old.id,auth.uid()) then raise exception 'Page protection does not permit this administrator to edit the article'; end if;
    if (to_jsonb(new) - array['featured','protection_level','protection_reason','protected_until','updated_at']::text[])
       is distinct from (to_jsonb(old) - array['featured','protection_level','protection_reason','protected_until','updated_at']::text[]) then
      raise exception 'Staff may only change page protection and featured status outside protected workflows';
    end if;
    return new;
  end if;

  if not public.can_write_articles(auth.uid()) or not public.can_edit_article(old.id,auth.uid()) then raise exception 'This account is not allowed to edit the article'; end if;
  if new.author_id is distinct from old.author_id then raise exception 'Article author cannot be changed'; end if;
  if new.status='published' then raise exception 'Only the editorial workflow can publish an article'; end if;
  if (to_jsonb(new) - array[
        'title','summary','content','article_type','article_type_id','category','categories','tags',
        'cover_image_url','video_url','cover_media_id','video_media_id','infobox',
        'original_creator','original_creator_user_id','updated_at'
      ]::text[])
     is distinct from
     (to_jsonb(old) - array[
        'title','summary','content','article_type','article_type_id','category','categories','tags',
        'cover_image_url','video_url','cover_media_id','video_media_id','infobox',
        'original_creator','original_creator_user_id','updated_at'
      ]::text[]) then
    raise exception 'Contributors cannot change privileged article metadata';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_article_permissions() from public, anon, authenticated;

create or replace function public.sysadmin_set_article_retired(article_uuid uuid, retire boolean, reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.articles%rowtype;
begin
  if not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;
  if nullif(trim(reason),'') is null then raise exception 'A retirement/restore reason is required'; end if;
  if char_length(trim(reason)) > 2000 then raise exception 'Retirement/restore reason is too long'; end if;
  select * into a from public.articles where id=article_uuid for update;
  if not found then raise exception 'Article not found'; end if;
  perform set_config('zionxyos.article_retire','1',true);

  if retire then
    if a.deleted_at is not null then raise exception 'Article is already retired'; end if;
    update public.articles set deleted_at=now(),deleted_by=auth.uid() where id=a.id;
    insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
    values(auth.uid(),'article.retired','article',a.id,jsonb_build_object('reason',trim(reason),'slug',a.slug));
  else
    if a.deleted_at is null then raise exception 'Article is not retired'; end if;
    update public.articles set deleted_at=null,deleted_by=null where id=a.id;
    insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
    values(auth.uid(),'article.restored','article',a.id,jsonb_build_object('reason',trim(reason),'slug',a.slug));
  end if;
  return a.slug;
end;
$$;
revoke all on function public.sysadmin_set_article_retired(uuid,boolean,text) from public, anon, authenticated;
grant execute on function public.sysadmin_set_article_retired(uuid,boolean,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Media metadata immutability and retirement integrity.
-- ---------------------------------------------------------------------------
-- Uploaded object identity/ownership/type metadata never changes in place. The
-- only supported UPDATE is Sysadmin retirement/restore, and referenced assets
-- cannot be retired even through a direct PostgREST call.
create or replace function public.enforce_media_asset_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return new; end if;
  if not public.is_sysadmin_mfa(auth.uid()) then raise exception 'Sysadmin MFA session required'; end if;

  if (to_jsonb(new) - array['deleted_at','deleted_by']::text[])
     is distinct from (to_jsonb(old) - array['deleted_at','deleted_by']::text[]) then
    raise exception 'Media object identity and metadata are immutable after upload';
  end if;

  if old.deleted_at is null and new.deleted_at is not null then
    if new.deleted_by is distinct from auth.uid() then raise exception 'Media retirement must record the current sysadmin'; end if;
    if exists(select 1 from public.articles a where a.cover_media_id=old.id or a.video_media_id=old.id)
       or exists(select 1 from public.article_revisions r where r.cover_media_id=old.id or r.video_media_id=old.id) then
      raise exception 'Referenced media cannot be retired';
    end if;
    insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
    values(auth.uid(),'media.retired','media',old.id,jsonb_build_object('object_path',old.object_path,'media_kind',old.media_kind));
    return new;
  end if;

  if old.deleted_at is not null and new.deleted_at is null then
    if new.deleted_by is not null then raise exception 'Restored media must clear deleted_by'; end if;
    insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
    values(auth.uid(),'media.restored','media',old.id,jsonb_build_object('object_path',old.object_path,'media_kind',old.media_kind));
    return new;
  end if;

  if new.deleted_at is distinct from old.deleted_at or new.deleted_by is distinct from old.deleted_by then
    raise exception 'Existing media retirement metadata is immutable; restore before retiring again';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_media_asset_update() from public, anon, authenticated;
drop trigger if exists media_assets_update_guard on public.media_assets;
create trigger media_assets_update_guard before update on public.media_assets
for each row execute procedure public.enforce_media_asset_update();

-- ---------------------------------------------------------------------------
-- Taxonomy creator integrity and complete audit trail.
-- ---------------------------------------------------------------------------
-- Basic taxonomy CRUD is still performed by the Sysadmin UI, but the database owns
-- authorship/timestamps and records every create/update/delete operation. This keeps
-- audit history trustworthy even if a privileged browser calls PostgREST directly.
create or replace function public.enforce_taxonomy_creator_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_sysadmin_mfa(auth.uid()) then
    raise exception 'Sysadmin MFA session required';
  end if;
  if tg_op='INSERT' then
    new.created_by := auth.uid();
    new.created_at := now();
    return new;
  end if;
  if new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'Taxonomy creator metadata is immutable';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_taxonomy_creator_integrity() from public, anon, authenticated;

create or replace function public.audit_taxonomy_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_id uuid := case when tg_op='DELETE' then old.id else new.id end;
  row_name text := case when tg_op='DELETE' then old.name else new.name end;
  row_slug text := case when tg_op='DELETE' then old.slug else new.slug end;
  row_active boolean := case when tg_op='DELETE' then old.active else new.active end;
begin
  insert into public.audit_logs(user_id,action,target_type,target_id,metadata)
  values(
    auth.uid(),
    'taxonomy.'||tg_table_name||'.'||lower(tg_op),
    tg_table_name,
    row_id,
    jsonb_build_object('name',row_name,'slug',row_slug,'active',row_active)
  );
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.audit_taxonomy_change() from public, anon, authenticated;

-- One integrity + one audit trigger on each controlled taxonomy table.
drop trigger if exists article_types_creator_integrity_v03 on public.article_types;
create trigger article_types_creator_integrity_v03 before insert or update on public.article_types
for each row execute procedure public.enforce_taxonomy_creator_integrity();
drop trigger if exists article_types_audit_v03 on public.article_types;
create trigger article_types_audit_v03 after insert or update or delete on public.article_types
for each row execute procedure public.audit_taxonomy_change();

drop trigger if exists categories_creator_integrity_v03 on public.categories;
create trigger categories_creator_integrity_v03 before insert or update on public.categories
for each row execute procedure public.enforce_taxonomy_creator_integrity();
drop trigger if exists categories_audit_v03 on public.categories;
create trigger categories_audit_v03 after insert or update or delete on public.categories
for each row execute procedure public.audit_taxonomy_change();

drop trigger if exists controlled_tags_creator_integrity_v03 on public.controlled_tags;
create trigger controlled_tags_creator_integrity_v03 before insert or update on public.controlled_tags
for each row execute procedure public.enforce_taxonomy_creator_integrity();
drop trigger if exists controlled_tags_audit_v03 on public.controlled_tags;
create trigger controlled_tags_audit_v03 after insert or update or delete on public.controlled_tags
for each row execute procedure public.audit_taxonomy_change();

-- Operation-specific RLS binds INSERT authorship and avoids a broad FOR ALL policy.
drop policy if exists "article_types_sysadmin_write" on public.article_types;
drop policy if exists "article_types_sysadmin_insert_v03" on public.article_types;
drop policy if exists "article_types_sysadmin_update_v03" on public.article_types;
drop policy if exists "article_types_sysadmin_delete_v03" on public.article_types;
create policy "article_types_sysadmin_insert_v03" on public.article_types for insert to authenticated
with check (public.is_sysadmin_mfa(auth.uid()) and created_by=auth.uid());
create policy "article_types_sysadmin_update_v03" on public.article_types for update to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));
create policy "article_types_sysadmin_delete_v03" on public.article_types for delete to authenticated
using (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "categories_sysadmin_write" on public.categories;
drop policy if exists "categories_sysadmin_insert_v03" on public.categories;
drop policy if exists "categories_sysadmin_update_v03" on public.categories;
drop policy if exists "categories_sysadmin_delete_v03" on public.categories;
create policy "categories_sysadmin_insert_v03" on public.categories for insert to authenticated
with check (public.is_sysadmin_mfa(auth.uid()) and created_by=auth.uid());
create policy "categories_sysadmin_update_v03" on public.categories for update to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));
create policy "categories_sysadmin_delete_v03" on public.categories for delete to authenticated
using (public.is_sysadmin_mfa(auth.uid()));

drop policy if exists "controlled_tags_sysadmin_write" on public.controlled_tags;
drop policy if exists "controlled_tags_sysadmin_insert_v03" on public.controlled_tags;
drop policy if exists "controlled_tags_sysadmin_update_v03" on public.controlled_tags;
drop policy if exists "controlled_tags_sysadmin_delete_v03" on public.controlled_tags;
create policy "controlled_tags_sysadmin_insert_v03" on public.controlled_tags for insert to authenticated
with check (public.is_sysadmin_mfa(auth.uid()) and created_by=auth.uid());
create policy "controlled_tags_sysadmin_update_v03" on public.controlled_tags for update to authenticated
using (public.is_sysadmin_mfa(auth.uid())) with check (public.is_sysadmin_mfa(auth.uid()));
create policy "controlled_tags_sysadmin_delete_v03" on public.controlled_tags for delete to authenticated
using (public.is_sysadmin_mfa(auth.uid()));

-- Article Types are historical/publication schema. Although the original FK uses
-- ON DELETE SET NULL for upgrade compatibility, v0.3 does not allow an in-use type
-- to disappear: deactivate it instead and preserve article/revision semantics.
create or replace function public.prevent_used_article_type_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_sysadmin_mfa(auth.uid()) then
    raise exception 'Sysadmin MFA session required';
  end if;
  if exists(select 1 from public.articles a where a.article_type_id=old.id)
     or exists(select 1 from public.article_revisions r where r.article_type_id=old.id) then
    raise exception 'This Article Type is in use; deactivate it instead';
  end if;
  return old;
end;
$$;
revoke all on function public.prevent_used_article_type_delete() from public, anon, authenticated;
drop trigger if exists article_types_prevent_used_delete_v03 on public.article_types;
create trigger article_types_prevent_used_delete_v03 before delete on public.article_types
for each row execute procedure public.prevent_used_article_type_delete();

-- ---------------------------------------------------------------------------
-- Database-side internal-link analysis for public utility pages.
-- ---------------------------------------------------------------------------
-- Avoid transferring every published article body into the Next.js process just to
-- compute backlinks/orphans/broken links. Inputs/results are bounded; source content
-- itself is already bounded by the v0.3 article content constraint.
create or replace function public.wiki_backlinks(target_title text, max_results integer default 500)
returns table(id uuid, title text, slug text, summary text)
language sql
stable
security definer
set search_path = public
as $$
  with wanted as (
    select nullif(left(btrim(target_title),160),'') as title,
           greatest(1,least(coalesce(max_results,500),1000)) as result_limit
  )
  select distinct a.id,a.title,a.slug,a.summary
  from public.articles a
  cross join wanted w
  cross join lateral regexp_matches(a.content, '\[\[([^\]|]+)(\|[^\]]+)?\]\]', 'g') m
  where w.title is not null
    and a.status='published' and a.deleted_at is null
    and lower(btrim(m[1]))=lower(w.title)
  order by a.title
  limit (select result_limit from wanted);
$$;
revoke all on function public.wiki_backlinks(text,integer) from public, anon, authenticated;
grant execute on function public.wiki_backlinks(text,integer) to anon, authenticated;

create or replace function public.wiki_broken_links(max_results integer default 1000)
returns table(source_title text, source_slug text, target text)
language sql
stable
security definer
set search_path = public
as $$
  with config as (
    select greatest(1,least(coalesce(max_results,1000),2000)) as result_limit
  ), links as (
    select a.title as source_title,a.slug as source_slug,left(btrim(m[1]),160) as target
    from public.articles a
    cross join lateral regexp_matches(a.content, '\[\[([^\]|]+)(\|[^\]]+)?\]\]', 'g') m
    where a.status='published' and a.deleted_at is null
      and nullif(btrim(m[1]),'') is not null
  )
  select distinct l.source_title,l.source_slug,l.target
  from links l
  where not exists (
    select 1 from public.articles target_article
    where target_article.status='published' and target_article.deleted_at is null
      and lower(target_article.title)=lower(l.target)
  )
  order by l.source_title,l.target
  limit (select result_limit from config);
$$;
revoke all on function public.wiki_broken_links(integer) from public, anon, authenticated;
grant execute on function public.wiki_broken_links(integer) to anon, authenticated;

create or replace function public.wiki_orphaned_pages(max_results integer default 1000)
returns table(id uuid, title text, slug text)
language sql
stable
security definer
set search_path = public
as $$
  with config as (
    select greatest(1,least(coalesce(max_results,1000),2000)) as result_limit
  ), linked_targets as (
    select distinct lower(left(btrim(m[1]),160)) as target
    from public.articles source_article
    cross join lateral regexp_matches(source_article.content, '\[\[([^\]|]+)(\|[^\]]+)?\]\]', 'g') m
    where source_article.status='published' and source_article.deleted_at is null
      and nullif(btrim(m[1]),'') is not null
  )
  select a.id,a.title,a.slug
  from public.articles a
  where a.status='published' and a.deleted_at is null
    and not exists (select 1 from linked_targets l where l.target=lower(a.title))
  order by a.title
  limit (select result_limit from config);
$$;
revoke all on function public.wiki_orphaned_pages(integer) from public, anon, authenticated;
grant execute on function public.wiki_orphaned_pages(integer) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Normalized internal-link index for cheap backlinks/broken-link/orphan queries.
-- ---------------------------------------------------------------------------
-- Public utility pages must not regex-scan every article on every request. Keep a
-- bounded derived index in sync with the canonical published article instead.
create table if not exists public.article_internal_links (
  source_article_id uuid not null references public.articles(id) on delete cascade,
  target_title text not null check (char_length(target_title) between 1 and 160),
  target_key text not null check (char_length(target_key) between 1 and 160 and target_key=lower(btrim(target_title))),
  primary key (source_article_id,target_key)
);
create index if not exists article_internal_links_target_idx on public.article_internal_links(target_key,source_article_id);
alter table public.article_internal_links enable row level security;

drop policy if exists "article_internal_links_public_read_v03" on public.article_internal_links;
create policy "article_internal_links_public_read_v03" on public.article_internal_links for select to anon, authenticated
using (exists (
  select 1 from public.articles source
  where source.id=source_article_id and source.status='published' and source.deleted_at is null
));
revoke all on public.article_internal_links from anon, authenticated;
grant select on public.article_internal_links to anon, authenticated;

create or replace function public.sync_article_internal_links()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.article_internal_links where source_article_id=new.id;
  if new.status='published' and new.deleted_at is null then
    insert into public.article_internal_links(source_article_id,target_title,target_key)
    select new.id, candidate.target_title, candidate.target_key
    from (
      select distinct
        left(btrim(m[1]),160) as target_title,
        lower(left(btrim(m[1]),160)) as target_key
      from regexp_matches(coalesce(new.content,''), '\[\[([^\]|]+)(\|[^\]]+)?\]\]', 'g') m
      where nullif(btrim(m[1]),'') is not null
      limit 200
    ) candidate
    on conflict (source_article_id,target_key) do nothing;
  end if;
  return new;
end;
$$;
revoke all on function public.sync_article_internal_links() from public, anon, authenticated;

drop trigger if exists articles_sync_internal_links_v03 on public.articles;
create trigger articles_sync_internal_links_v03
  after insert or update of content,status,deleted_at on public.articles
  for each row execute procedure public.sync_article_internal_links();

-- Backfill the derived index once for canonical pages that existed before v0.3.
insert into public.article_internal_links(source_article_id,target_title,target_key)
select source.id,candidate.target_title,candidate.target_key
from public.articles source
cross join lateral (
  select distinct
    left(btrim(m[1]),160) as target_title,
    lower(left(btrim(m[1]),160)) as target_key
  from regexp_matches(coalesce(source.content,''), '\[\[([^\]|]+)(\|[^\]]+)?\]\]', 'g') m
  where nullif(btrim(m[1]),'') is not null
  limit 200
) candidate
where source.status='published' and source.deleted_at is null
on conflict (source_article_id,target_key) do nothing;

create or replace function public.wiki_backlinks(target_title text, max_results integer default 500)
returns table(id uuid, title text, slug text, summary text)
language sql
stable
security definer
set search_path = public
as $$
  with wanted as (
    select nullif(lower(left(btrim(target_title),160)),'') as target_key,
           greatest(1,least(coalesce(max_results,500),1000)) as result_limit
  )
  select source.id,source.title,source.slug,source.summary
  from public.article_internal_links link
  join public.articles source on source.id=link.source_article_id
  cross join wanted w
  where w.target_key is not null
    and link.target_key=w.target_key
    and source.status='published' and source.deleted_at is null
  order by source.title
  limit (select result_limit from wanted);
$$;
revoke all on function public.wiki_backlinks(text,integer) from public, anon, authenticated;
grant execute on function public.wiki_backlinks(text,integer) to anon, authenticated;

create or replace function public.wiki_broken_links(max_results integer default 1000)
returns table(source_title text, source_slug text, target text)
language sql
stable
security definer
set search_path = public
as $$
  with config as (select greatest(1,least(coalesce(max_results,1000),2000)) as result_limit)
  select source.title,source.slug,link.target_title
  from public.article_internal_links link
  join public.articles source on source.id=link.source_article_id
  where source.status='published' and source.deleted_at is null
    and not exists (
      select 1 from public.articles target
      where target.status='published' and target.deleted_at is null
        and lower(target.title)=link.target_key
    )
  order by source.title,link.target_title
  limit (select result_limit from config);
$$;
revoke all on function public.wiki_broken_links(integer) from public, anon, authenticated;
grant execute on function public.wiki_broken_links(integer) to anon, authenticated;

create or replace function public.wiki_orphaned_pages(max_results integer default 1000)
returns table(id uuid, title text, slug text)
language sql
stable
security definer
set search_path = public
as $$
  with config as (select greatest(1,least(coalesce(max_results,1000),2000)) as result_limit)
  select target.id,target.title,target.slug
  from public.articles target
  where target.status='published' and target.deleted_at is null
    and not exists (
      select 1
      from public.article_internal_links link
      join public.articles source on source.id=link.source_article_id
      where link.target_key=lower(target.title)
        and source.status='published' and source.deleted_at is null
        and source.id<>target.id
    )
  order by target.title
  limit (select result_limit from config);
$$;
revoke all on function public.wiki_orphaned_pages(integer) from public, anon, authenticated;
grant execute on function public.wiki_orphaned_pages(integer) to anon, authenticated;

-- Bounded public listing helpers keep large category/utility/related-page joins in
-- PostgreSQL and return only the rows the current UI page needs.
create or replace function public.wiki_category_articles(category_uuid uuid, page_offset integer default 0, page_limit integer default 101)
returns table(id uuid,title text,slug text,summary text)
language sql stable security definer set search_path=public
as $$
  select a.id,a.title,a.slug,a.summary
  from public.article_categories ac
  join public.articles a on a.id=ac.article_id
  join public.categories c on c.id=ac.category_id
  where ac.category_id=category_uuid and c.active
    and a.status='published' and a.deleted_at is null
  order by a.title,a.id
  offset greatest(0,least(coalesce(page_offset,0),1000000))
  limit greatest(1,least(coalesce(page_limit,101),201));
$$;
revoke all on function public.wiki_category_articles(uuid,integer,integer) from public, anon, authenticated;
grant execute on function public.wiki_category_articles(uuid,integer,integer) to anon, authenticated;

create or replace function public.wiki_uncategorized_pages(page_offset integer default 0, page_limit integer default 201)
returns table(id uuid,title text,slug text)
language sql stable security definer set search_path=public
as $$
  select a.id,a.title,a.slug
  from public.articles a
  where a.status='published' and a.deleted_at is null
    and not exists (select 1 from public.article_categories ac where ac.article_id=a.id)
  order by a.title,a.id
  offset greatest(0,least(coalesce(page_offset,0),1000000))
  limit greatest(1,least(coalesce(page_limit,201),401));
$$;
revoke all on function public.wiki_uncategorized_pages(integer,integer) from public, anon, authenticated;
grant execute on function public.wiki_uncategorized_pages(integer,integer) to anon, authenticated;

create or replace function public.wiki_related_articles(article_uuid uuid, max_results integer default 6)
returns table(id uuid,title text,slug text,summary text,shared_categories bigint)
language sql stable security definer set search_path=public
as $$
  with source_ok as (
    select a.id from public.articles a where a.id=article_uuid and a.status='published' and a.deleted_at is null
  ), source_categories as (
    select ac.category_id from public.article_categories ac join source_ok s on s.id=ac.article_id
  )
  select a.id,a.title,a.slug,a.summary,count(*)::bigint as shared_categories
  from source_categories sc
  join public.article_categories related_link on related_link.category_id=sc.category_id and related_link.article_id<>article_uuid
  join public.articles a on a.id=related_link.article_id
  where a.status='published' and a.deleted_at is null
  group by a.id,a.title,a.slug,a.summary,a.updated_at
  order by count(*) desc,a.updated_at desc,a.title
  limit greatest(1,least(coalesce(max_results,6),20));
$$;
revoke all on function public.wiki_related_articles(uuid,integer) from public, anon, authenticated;
grant execute on function public.wiki_related_articles(uuid,integer) to anon, authenticated;

-- Bound the public category-tree/count result as a final defense against accidental
-- unbounded taxonomy growth in a single response.
create or replace function public.wiki_category_counts()
returns table(category_id uuid,category_name text,category_slug text,parent_id uuid,article_count bigint)
language sql stable security definer set search_path=public
as $$
  select c.id,c.name,c.slug,c.parent_id,count(distinct a.id)
  from public.categories c
  left join public.article_categories ac on ac.category_id=c.id
  left join public.articles a on a.id=ac.article_id and a.status='published' and a.deleted_at is null
  where c.active
  group by c.id,c.name,c.slug,c.parent_id,c.sort_order
  order by c.sort_order,c.name
  limit 5000;
$$;
revoke all on function public.wiki_category_counts() from public, anon, authenticated;
grant execute on function public.wiki_category_counts() to anon, authenticated;

-- Keep editorial banners useful rather than unbounded. Serialize per article so
-- concurrent staff inserts cannot race the cap; duplicate assignments remain harmless.
create or replace function public.enforce_article_notice_limit()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare notice_count integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('article-notices:'||new.article_id::text,0));
  if exists(select 1 from public.article_notices where article_id=new.article_id and notice_id=new.notice_id) then return new; end if;
  select count(*) into notice_count from public.article_notices where article_id=new.article_id;
  if notice_count>=20 then raise exception 'An article cannot have more than 20 editorial notices'; end if;
  return new;
end;
$$;
revoke all on function public.enforce_article_notice_limit() from public, anon, authenticated;
drop trigger if exists article_notices_limit_v03 on public.article_notices;
create trigger article_notices_limit_v03 before insert on public.article_notices
for each row execute procedure public.enforce_article_notice_limit();

-- Category hierarchy depth is bounded to keep recursive public/admin rendering safe
-- and to prevent pathological chains even when a Sysadmin uses PostgREST directly.
create or replace function public.prevent_category_cycle()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare cursor_id uuid; depth_count integer := 0;
begin
  if new.parent_id is null then return new; end if;
  if new.parent_id=new.id then raise exception 'A category cannot be its own parent'; end if;
  cursor_id:=new.parent_id;
  while cursor_id is not null loop
    depth_count:=depth_count+1;
    if depth_count>32 then raise exception 'Category hierarchy cannot exceed 32 ancestor levels'; end if;
    if cursor_id=new.id then raise exception 'Category cycle detected'; end if;
    select parent_id into cursor_id from public.categories where id=cursor_id;
  end loop;
  return new;
end;
$$;
revoke all on function public.prevent_category_cycle() from public, anon, authenticated;

create or replace function public.wiki_category_context(category_slug text)
returns table(relation_kind text,id uuid,name text,slug text,description text,parent_id uuid,sort_order integer,depth integer)
language sql
stable
security definer
set search_path=public
as $$
  with recursive target as (
    select c.id,c.name,c.slug,c.description,c.parent_id,c.sort_order
    from public.categories c
    where c.active and c.slug=left(lower(btrim(category_slug)),100)
    limit 1
  ), ancestors as (
    select p.id,p.name,p.slug,p.description,p.parent_id,p.sort_order,1 as depth
    from public.categories p join target t on p.id=t.parent_id
    where p.active
    union all
    select p.id,p.name,p.slug,p.description,p.parent_id,p.sort_order,a.depth+1
    from public.categories p join ancestors a on p.id=a.parent_id
    where p.active and a.depth<32
  ), children as (
    select c.id,c.name,c.slug,c.description,c.parent_id,c.sort_order,1 as depth
    from public.categories c join target t on c.parent_id=t.id
    where c.active
    order by c.sort_order,c.name
    limit 1000
  )
  select 'current'::text,t.id,t.name,t.slug,t.description,t.parent_id,t.sort_order,0 from target t
  union all
  select 'ancestor',a.id,a.name,a.slug,a.description,a.parent_id,a.sort_order,a.depth from ancestors a
  union all
  select 'child',c.id,c.name,c.slug,c.description,c.parent_id,c.sort_order,c.depth from children c;
$$;
revoke all on function public.wiki_category_context(text) from public, anon, authenticated;
grant execute on function public.wiki_category_context(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Bounded administrative reasons and audit payloads.
-- ---------------------------------------------------------------------------
-- UI limits are convenience only; privileged direct RPC/PostgREST calls must obey
-- the same bounds. NOT VALID preserves upgrade compatibility for any oversized
-- historical audit row while enforcing the constraint for all new/changed rows.
alter table public.articles drop constraint if exists articles_protection_reason_length_v03;
alter table public.articles add constraint articles_protection_reason_length_v03
  check (protection_reason is null or char_length(protection_reason) <= 2000) not valid;

alter table public.audit_logs drop constraint if exists audit_logs_metadata_size_v03;
alter table public.audit_logs add constraint audit_logs_metadata_size_v03
  check (pg_column_size(metadata) <= 65536) not valid;

-- ---------------------------------------------------------------------------
-- Direct Storage/media-metadata abuse hardening.
-- ---------------------------------------------------------------------------
-- Browser uploads remain direct-to-Supabase, but the Storage RLS itself consumes
-- the per-user upload budget so bypassing the React component cannot bypass rate
-- limiting. The subsequent media_assets INSERT must correspond to the object that
-- actually exists in Storage with the same declared MIME type and byte size.
drop policy if exists "zionxyos_media_insert" on storage.objects;
create policy "zionxyos_media_insert" on storage.objects for insert to authenticated with check (
  bucket_id='zionxyos-media'
  and (storage.foldername(name))[1]=auth.uid()::text
  and public.is_active_contributor(auth.uid())
  and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='media_uploads_enabled'),true)
  and coalesce(metadata->>'size','') ~ '^[0-9]+$'
  and (
    (
      ((lower(coalesce(metadata->>'mimetype',''))='image/jpeg' and lower(storage.extension(name)) in ('jpg','jpeg'))
       or (lower(coalesce(metadata->>'mimetype',''))='image/png' and lower(storage.extension(name))='png')
       or (lower(coalesce(metadata->>'mimetype',''))='image/webp' and lower(storage.extension(name))='webp')
       or (lower(coalesce(metadata->>'mimetype',''))='image/gif' and lower(storage.extension(name))='gif'))
      and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='image_uploads_enabled'),true)
      and (metadata->>'size')::bigint between 1 and least(52428800,coalesce((select (value#>>'{}')::bigint from public.site_settings where key='max_image_bytes'),10485760))
      and public.consume_rate_limit('media_upload',auth.uid()::text,30,3600)
    )
    or
    (
      ((lower(coalesce(metadata->>'mimetype',''))='video/mp4' and lower(storage.extension(name))='mp4')
       or (lower(coalesce(metadata->>'mimetype',''))='video/webm' and lower(storage.extension(name))='webm')
       or (lower(coalesce(metadata->>'mimetype',''))='video/ogg' and lower(storage.extension(name))='ogg'))
      and coalesce((select (value#>>'{}')::boolean from public.site_settings where key='video_uploads_enabled'),true)
      and (metadata->>'size')::bigint between 1 and least(52428800,coalesce((select (value#>>'{}')::bigint from public.site_settings where key='max_video_bytes'),52428800))
      and public.consume_rate_limit('media_upload',auth.uid()::text,10,3600)
    )
  )
);

create or replace function public.enforce_media_asset_object_match()
returns trigger
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  object_mime text;
  object_size bigint;
begin
  if auth.uid() is null then return new; end if;
  if new.owner_id is distinct from auth.uid() then raise exception 'Media owner must be the signed-in user'; end if;
  if new.bucket <> 'zionxyos-media' then raise exception 'Invalid media bucket'; end if;
  if new.object_path not like auth.uid()::text || '/%' or position('..' in new.object_path)>0 then
    raise exception 'Invalid media object path';
  end if;

  select lower(coalesce(o.metadata->>'mimetype','')),
         case when coalesce(o.metadata->>'size','') ~ '^[0-9]+$' then (o.metadata->>'size')::bigint else null end
    into object_mime, object_size
  from storage.objects o
  where o.bucket_id=new.bucket and o.name=new.object_path;

  if not found then raise exception 'The uploaded Storage object does not exist'; end if;
  if object_mime is distinct from lower(new.mime_type) then raise exception 'Media metadata MIME type does not match the Storage object'; end if;
  if object_size is distinct from new.size_bytes then raise exception 'Media metadata size does not match the Storage object'; end if;
  if (new.media_kind='image' and object_mime not in ('image/jpeg','image/png','image/webp','image/gif'))
     or (new.media_kind='video' and object_mime not in ('video/mp4','video/webm','video/ogg')) then
    raise exception 'Media kind does not match the Storage object MIME type';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_media_asset_object_match() from public, anon, authenticated;
drop trigger if exists media_assets_object_match_v03 on public.media_assets;
create trigger media_assets_object_match_v03 before insert on public.media_assets
for each row execute procedure public.enforce_media_asset_object_match();

-- Rate-limit cleanup now runs on upload/storage writes too; give the global expiry
-- delete an index that does not depend on action/subject prefixes.
create index if not exists rate_limit_events_created_idx on public.rate_limit_events(created_at);

-- Mark this migration as applied only after all schema/policy hardening succeeds.
insert into public.system_migrations(migration_id, version, name, status)
values ('003_production_release', '0.3.0', 'Production release', 'applied')
on conflict (migration_id) do update
set version = excluded.version, name = excluded.name, status = 'applied', applied_at = now();

commit;
