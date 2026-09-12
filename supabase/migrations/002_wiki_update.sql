-- Zionxyos v0.2 — Wiki Update
-- Run AFTER 001_initial.sql on an existing v0.1 project.
-- This migration creates NO sample articles or users.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'revision_status') then
    create type public.revision_status as enum (
      'draft',
      'pending_review',
      'changes_requested',
      'approved',
      'rejected'
    );
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Canonical article metadata
-- ---------------------------------------------------------------------------
alter table public.articles
  add column if not exists article_type text not null default 'article',
  add column if not exists categories text[] not null default '{}',
  add column if not exists infobox jsonb not null default '{}'::jsonb,
  add column if not exists current_revision_id uuid,
  add column if not exists protection_level text not null default 'open',
  add column if not exists protection_reason text,
  add column if not exists protected_until timestamptz,
  add column if not exists featured boolean not null default false;

-- Carry the old single category into the new multi-category field.
update public.articles
set categories = array[category]
where category is not null
  and category <> ''
  and coalesce(array_length(categories, 1), 0) = 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'articles_protection_level_check'
      and conrelid = 'public.articles'::regclass
  ) then
    alter table public.articles
      add constraint articles_protection_level_check
      check (protection_level in ('open', 'registered', 'sysadmin'));
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Revisions: drafts/review submissions are separated from the public article.
-- ---------------------------------------------------------------------------
create table if not exists public.article_revisions (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null references public.articles(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete restrict,
  status public.revision_status not null default 'draft',
  revision_type text not null default 'edit' check (revision_type in ('creation', 'edit', 'rollback')),

  title text not null check (char_length(title) between 1 and 160),
  summary text check (char_length(summary) <= 600),
  content text not null default '',
  article_type text not null default 'article',
  category text check (char_length(category) <= 80),
  categories text[] not null default '{}',
  tags text[] not null default '{}',
  cover_image_url text,
  video_url text,
  infobox jsonb not null default '{}'::jsonb,
  edit_summary text check (char_length(edit_summary) <= 300),

  reviewer_id uuid references public.profiles(id) on delete set null,
  review_note text check (char_length(review_note) <= 4000),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists article_revisions_article_created_idx
  on public.article_revisions(article_id, created_at desc);
create index if not exists article_revisions_author_updated_idx
  on public.article_revisions(author_id, updated_at desc);
create index if not exists article_revisions_review_queue_idx
  on public.article_revisions(status, submitted_at asc)
  where status = 'pending_review';

-- Only one actively editable revision per article/author.
create unique index if not exists article_revisions_one_editable_idx
  on public.article_revisions(article_id, author_id)
  where status in ('draft', 'changes_requested');

-- Import every v0.1 article as an initial revision, without changing the article.
insert into public.article_revisions (
  article_id, author_id, status, revision_type,
  title, summary, content, article_type, category, categories, tags,
  cover_image_url, video_url, infobox, edit_summary,
  submitted_at, reviewed_at, created_at, updated_at
)
select
  a.id,
  a.author_id,
  case a.status
    when 'published' then 'approved'::public.revision_status
    when 'pending_review' then 'pending_review'::public.revision_status
    else 'draft'::public.revision_status
  end,
  'creation',
  a.title, a.summary, a.content, a.article_type, a.category, a.categories, a.tags,
  a.cover_image_url, a.video_url, a.infobox,
  'Importado da v0.1',
  case when a.status in ('pending_review', 'published') then a.updated_at else null end,
  case when a.status = 'published' then coalesce(a.published_at, a.updated_at) else null end,
  a.created_at, a.updated_at
from public.articles a
where not exists (
  select 1 from public.article_revisions r where r.article_id = a.id
);

update public.articles a
set current_revision_id = (
  select ar.id
  from public.article_revisions ar
  where ar.article_id = a.id and ar.status = 'approved'
  order by ar.reviewed_at desc nulls last, ar.created_at desc
  limit 1
)
where a.current_revision_id is null
  and exists (
    select 1 from public.article_revisions ar
    where ar.article_id = a.id and ar.status = 'approved'
  );

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'articles_current_revision_fk'
      and conrelid = 'public.articles'::regclass
  ) then
    alter table public.articles
      add constraint articles_current_revision_fk
      foreign key (current_revision_id)
      references public.article_revisions(id)
      on delete set null;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Moderation
-- ---------------------------------------------------------------------------
create table if not exists public.moderation_actions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('warning', 'mute', 'suspend', 'ban')),
  reason text not null check (char_length(reason) between 1 and 2000),
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid references public.profiles(id) on delete set null,
  revoke_reason text check (char_length(revoke_reason) <= 2000)
);

create index if not exists moderation_user_active_idx
  on public.moderation_actions(user_id, kind, expires_at)
  where revoked_at is null;

create table if not exists public.admin_user_notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 4000),
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Community features
-- ---------------------------------------------------------------------------
create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  title text not null check (char_length(title) <= 200),
  body text check (char_length(body) <= 2000),
  href text check (char_length(href) <= 1000),
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_created_idx
  on public.notifications(user_id, created_at desc);

create table if not exists public.watchlist (
  user_id uuid not null references public.profiles(id) on delete cascade,
  article_id uuid not null references public.articles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, article_id)
);

create table if not exists public.discussion_posts (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null references public.articles(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  parent_id uuid references public.discussion_posts(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 10000),
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  removed_at timestamptz,
  removed_by uuid references public.profiles(id) on delete set null
);
create index if not exists discussion_article_created_idx
  on public.discussion_posts(article_id, created_at asc);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_type text not null check (target_type in ('article', 'revision', 'user', 'discussion')),
  target_id uuid not null,
  reason text not null check (char_length(reason) between 1 and 500),
  details text check (char_length(details) <= 4000),
  status text not null default 'open' check (status in ('open', 'reviewing', 'resolved', 'dismissed')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  resolution_note text check (char_length(resolution_note) <= 4000),
  created_at timestamptz not null default now()
);
create index if not exists reports_status_created_idx
  on public.reports(status, created_at asc);

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------
create or replace function public.moderation_is_active(
  target_uid uuid,
  action_kind text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.moderation_actions m
    where m.user_id = target_uid
      and m.kind = action_kind
      and m.revoked_at is null
      and (m.expires_at is null or m.expires_at > now())
  );
$$;

revoke all on function public.moderation_is_active(uuid, text) from public;
grant execute on function public.moderation_is_active(uuid, text) to anon, authenticated;

create or replace function public.is_blocked(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.moderation_is_active(uid, 'suspend')
    or public.moderation_is_active(uid, 'ban');
$$;

revoke all on function public.is_blocked(uuid) from public;
grant execute on function public.is_blocked(uuid) to authenticated;

-- A suspended/banned sysadmin must also lose privileged database access.
create or replace function public.is_sysadmin(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = uid
      and p.role = 'sysadmin'
      and p.suspended = false
  ) and not public.is_blocked(uid);
$$;

revoke all on function public.is_sysadmin(uuid) from public;
grant execute on function public.is_sysadmin(uuid) to anon, authenticated;

create or replace function public.is_muted(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.moderation_is_active(uid, 'mute');
$$;

revoke all on function public.is_muted(uuid) from public;
grant execute on function public.is_muted(uuid) to authenticated;

-- Replace the v0.1 helper: suspended legacy flag + active moderation blocks.
create or replace function public.is_active_user(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = uid
      and p.suspended = false
  ) and not public.is_blocked(uid);
$$;

revoke all on function public.is_active_user(uuid) from public;
grant execute on function public.is_active_user(uuid) to authenticated;

create or replace function public.is_active_contributor(uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_active_user(uid) and not public.is_muted(uid);
$$;

revoke all on function public.is_active_contributor(uuid) from public;
grant execute on function public.is_active_contributor(uuid) to authenticated;

-- Revision updated_at.
drop trigger if exists article_revisions_set_updated_at on public.article_revisions;
create trigger article_revisions_set_updated_at
  before update on public.article_revisions
  for each row execute procedure public.set_updated_at();

-- Normal users can submit work, but cannot approve themselves or rewrite a submitted revision.
create or replace function public.enforce_revision_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.is_sysadmin(auth.uid()) then
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

drop trigger if exists enforce_revision_permissions on public.article_revisions;
create trigger enforce_revision_permissions
  before insert or update on public.article_revisions
  for each row execute procedure public.enforce_revision_permissions();

-- ---------------------------------------------------------------------------
-- Atomic sysadmin review workflow
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
  new_status public.revision_status;
begin
  if not public.is_sysadmin(auth.uid()) then
    raise exception 'Sysadmin required';
  end if;

  select * into r
  from public.article_revisions
  where id = revision_uuid
  for update;

  if not found then
    raise exception 'Revision not found';
  end if;

  if r.status <> 'pending_review' then
    raise exception 'Revision is not awaiting review';
  end if;

  select * into a
  from public.articles
  where id = r.article_id
  for update;

  if decision = 'approve' then
    new_status := 'approved';

    update public.article_revisions
    set status = new_status,
        reviewer_id = auth.uid(),
        review_note = nullif(trim(note), ''),
        reviewed_at = now()
    where id = r.id;

    update public.articles
    set title = r.title,
        summary = r.summary,
        content = r.content,
        article_type = r.article_type,
        category = r.category,
        categories = r.categories,
        tags = r.tags,
        cover_image_url = r.cover_image_url,
        video_url = r.video_url,
        infobox = r.infobox,
        status = 'published',
        current_revision_id = r.id,
        published_at = coalesce(a.published_at, now()),
        updated_at = now()
    where id = a.id;

    insert into public.notifications(user_id, kind, title, body, href)
    values (
      r.author_id,
      'revision.approved',
      'Sua revisão foi publicada',
      coalesce(nullif(trim(note), ''), 'A revisão foi aprovada pela administração.'),
      '/article/' || a.slug
    );

    insert into public.notifications(user_id, kind, title, body, href)
    select
      w.user_id,
      'watchlist.article_updated',
      'Uma página acompanhada foi atualizada',
      coalesce(nullif(trim(r.edit_summary), ''), 'Uma nova revisão foi incorporada à página.'),
      '/article/' || a.slug
    from public.watchlist w
    where w.article_id = a.id
      and w.user_id <> r.author_id;

  elsif decision = 'changes_requested' then
    new_status := 'changes_requested';

    update public.article_revisions
    set status = new_status,
        reviewer_id = auth.uid(),
        review_note = nullif(trim(note), ''),
        reviewed_at = now()
    where id = r.id;

    insert into public.notifications(user_id, kind, title, body, href)
    values (
      r.author_id,
      'revision.changes_requested',
      'Alterações foram solicitadas',
      coalesce(nullif(trim(note), ''), 'A administração pediu alterações antes da publicação.'),
      '/dashboard/articles/' || a.id || '/edit'
    );

  elsif decision = 'reject' then
    new_status := 'rejected';

    update public.article_revisions
    set status = new_status,
        reviewer_id = auth.uid(),
        review_note = nullif(trim(note), ''),
        reviewed_at = now()
    where id = r.id;

    insert into public.notifications(user_id, kind, title, body, href)
    values (
      r.author_id,
      'revision.rejected',
      'Sua revisão foi rejeitada',
      coalesce(nullif(trim(note), ''), 'A revisão não foi aprovada.'),
      '/dashboard/articles/' || a.id || '/history'
    );
  else
    raise exception 'Invalid review decision';
  end if;

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (
    auth.uid(),
    'revision.' || decision,
    'revision',
    r.id,
    jsonb_build_object('article_id', r.article_id, 'author_id', r.author_id, 'note', note)
  );
end;
$$;

revoke all on function public.admin_review_revision(uuid, text, text) from public;
grant execute on function public.admin_review_revision(uuid, text, text) to authenticated;

-- Atomic moderation action + user notification.
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
  notification_title text;
begin
  if not public.is_sysadmin(auth.uid()) then
    raise exception 'Sysadmin required';
  end if;

  if action_kind not in ('warning', 'mute', 'suspend', 'ban') then
    raise exception 'Invalid moderation action';
  end if;

  if target_uid = auth.uid() and action_kind in ('mute', 'suspend', 'ban') then
    raise exception 'You cannot block your own account';
  end if;

  if nullif(trim(action_reason), '') is null then
    raise exception 'Reason is required';
  end if;

  insert into public.moderation_actions(user_id, kind, reason, created_by, expires_at)
  values (target_uid, action_kind, trim(action_reason), auth.uid(), action_expires_at)
  returning id into action_id;

  notification_title := case action_kind
    when 'warning' then 'Aviso da administração'
    when 'mute' then 'Sua conta foi silenciada'
    when 'suspend' then 'Sua conta foi suspensa'
    when 'ban' then 'Sua conta foi banida'
  end;

  insert into public.notifications(user_id, kind, title, body, href)
  values (
    target_uid,
    'moderation.' || action_kind,
    notification_title,
    trim(action_reason),
    '/dashboard'
  );

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (
    auth.uid(),
    'moderation.' || action_kind,
    'profile',
    target_uid,
    jsonb_build_object('moderation_action_id', action_id, 'reason', action_reason, 'expires_at', action_expires_at)
  );

  return action_id;
end;
$$;

revoke all on function public.admin_apply_moderation(uuid, text, text, timestamptz) from public;
grant execute on function public.admin_apply_moderation(uuid, text, text, timestamptz) to authenticated;

create or replace function public.admin_revoke_moderation(
  action_uuid uuid,
  reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.moderation_actions%rowtype;
begin
  if not public.is_sysadmin(auth.uid()) then
    raise exception 'Sysadmin required';
  end if;

  select * into m
  from public.moderation_actions
  where id = action_uuid
  for update;

  if not found then raise exception 'Moderation action not found'; end if;

  update public.moderation_actions
  set revoked_at = now(),
      revoked_by = auth.uid(),
      revoke_reason = nullif(trim(reason), '')
  where id = action_uuid;

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (
    auth.uid(), 'moderation.revoked', 'profile', m.user_id,
    jsonb_build_object('moderation_action_id', m.id, 'kind', m.kind, 'reason', reason)
  );
end;
$$;

revoke all on function public.admin_revoke_moderation(uuid, text) from public;
grant execute on function public.admin_revoke_moderation(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Public wiki helpers
-- ---------------------------------------------------------------------------
create or replace function public.wiki_search(search_text text, max_results integer default 50)
returns table (
  id uuid,
  title text,
  slug text,
  summary text,
  article_type text,
  category text,
  categories text[],
  tags text[],
  updated_at timestamptz,
  snippet text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id,
    a.title,
    a.slug,
    a.summary,
    a.article_type,
    a.category,
    a.categories,
    a.tags,
    a.updated_at,
    left(coalesce(nullif(a.summary, ''), regexp_replace(a.content, '[#*_`>\[\]()]', '', 'g')), 320) as snippet
  from public.articles a
  where a.status = 'published'
    and nullif(trim(search_text), '') is not null
    and (
      a.title ilike '%' || search_text || '%'
      or coalesce(a.summary, '') ilike '%' || search_text || '%'
      or a.content ilike '%' || search_text || '%'
      or coalesce(a.category, '') ilike '%' || search_text || '%'
      or exists (select 1 from unnest(a.categories) c where c ilike '%' || search_text || '%')
      or exists (select 1 from unnest(a.tags) t where t ilike '%' || search_text || '%')
      or exists (
        select 1
        from public.profiles p
        where p.id = a.author_id
          and (
            p.username ilike '%' || search_text || '%'
            or coalesce(p.display_name, '') ilike '%' || search_text || '%'
          )
      )
    )
  order by
    case when lower(a.title) = lower(search_text) then 0
         when a.title ilike search_text || '%' then 1
         else 2 end,
    a.updated_at desc
  limit least(greatest(max_results, 1), 100);
$$;

revoke all on function public.wiki_search(text, integer) from public;
grant execute on function public.wiki_search(text, integer) to anon, authenticated;

create or replace function public.wiki_category_counts()
returns table (category_name text, article_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  select c, count(*)
  from (
    select distinct a.id, category_value as c
    from public.articles a
    cross join lateral unnest(a.categories) as category_value
    where a.status = 'published'
  ) x
  where c is not null and trim(c) <> ''
  group by c
  order by lower(c);
$$;

revoke all on function public.wiki_category_counts() from public;
grant execute on function public.wiki_category_counts() to anon, authenticated;

create or replace function public.wiki_resolve_links(targets text[])
returns table (title text, slug text)
language sql
stable
security definer
set search_path = public
as $$
  select a.title, a.slug
  from public.articles a
  where a.status = 'published'
    and exists (
      select 1
      from unnest(coalesce(targets, '{}'::text[])) as wanted(value)
      where lower(wanted.value) = lower(a.title)
    );
$$;

revoke all on function public.wiki_resolve_links(text[]) from public;
grant execute on function public.wiki_resolve_links(text[]) to anon, authenticated;

create or replace function public.random_published_article()
returns text
language sql
volatile
security definer
set search_path = public
as $$
  select slug from public.articles
  where status = 'published'
  order by random()
  limit 1;
$$;

revoke all on function public.random_published_article() from public;
grant execute on function public.random_published_article() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.article_revisions enable row level security;
alter table public.moderation_actions enable row level security;
alter table public.admin_user_notes enable row level security;
alter table public.notifications enable row level security;
alter table public.watchlist enable row level security;
alter table public.discussion_posts enable row level security;
alter table public.reports enable row level security;

-- Canonical articles: normal authors can only touch an unpublished stub.
drop policy if exists "articles_author_insert" on public.articles;
create policy "articles_author_insert"
  on public.articles for insert
  to authenticated
  with check (
    author_id = auth.uid()
    and public.is_active_contributor(auth.uid())
    and status = 'draft'
  );

drop policy if exists "articles_author_or_admin_update" on public.articles;
create policy "articles_author_or_admin_update"
  on public.articles for update
  to authenticated
  using (
    public.is_sysadmin(auth.uid())
    or (author_id = auth.uid() and status = 'draft' and public.is_active_contributor(auth.uid()))
  )
  with check (
    public.is_sysadmin(auth.uid())
    or (author_id = auth.uid() and status = 'draft' and public.is_active_contributor(auth.uid()))
  );

-- Revisions
drop policy if exists "revisions_public_author_admin_read" on public.article_revisions;
create policy "revisions_public_author_admin_read"
  on public.article_revisions for select
  using (
    status = 'approved'
    or author_id = auth.uid()
    or public.is_sysadmin(auth.uid())
  );

drop policy if exists "revisions_author_insert" on public.article_revisions;
create policy "revisions_author_insert"
  on public.article_revisions for insert
  to authenticated
  with check (
    author_id = auth.uid()
    and public.is_active_contributor(auth.uid())
    and status in ('draft', 'pending_review')
  );

drop policy if exists "revisions_author_admin_update" on public.article_revisions;
create policy "revisions_author_admin_update"
  on public.article_revisions for update
  to authenticated
  using (
    public.is_sysadmin(auth.uid())
    or (
      author_id = auth.uid()
      and status in ('draft', 'changes_requested')
      and public.is_active_contributor(auth.uid())
    )
  )
  with check (
    public.is_sysadmin(auth.uid())
    or (
      author_id = auth.uid()
      and status in ('draft', 'pending_review')
      and public.is_active_contributor(auth.uid())
    )
  );

drop policy if exists "revisions_draft_author_admin_delete" on public.article_revisions;
create policy "revisions_draft_author_admin_delete"
  on public.article_revisions for delete
  to authenticated
  using (
    public.is_sysadmin(auth.uid())
    or (author_id = auth.uid() and status = 'draft' and public.is_active_contributor(auth.uid()))
  );

-- Moderation history is visible to the affected user and admins.
drop policy if exists "moderation_own_admin_read" on public.moderation_actions;
create policy "moderation_own_admin_read"
  on public.moderation_actions for select
  to authenticated
  using (user_id = auth.uid() or public.is_sysadmin(auth.uid()));

drop policy if exists "moderation_admin_insert" on public.moderation_actions;
create policy "moderation_admin_insert"
  on public.moderation_actions for insert
  to authenticated
  with check (public.is_sysadmin(auth.uid()));

drop policy if exists "moderation_admin_update" on public.moderation_actions;
create policy "moderation_admin_update"
  on public.moderation_actions for update
  to authenticated
  using (public.is_sysadmin(auth.uid()))
  with check (public.is_sysadmin(auth.uid()));

-- Admin notes
drop policy if exists "admin_notes_admin_all" on public.admin_user_notes;
create policy "admin_notes_admin_all"
  on public.admin_user_notes for all
  to authenticated
  using (public.is_sysadmin(auth.uid()))
  with check (public.is_sysadmin(auth.uid()));

-- Notifications
drop policy if exists "notifications_own_read" on public.notifications;
create policy "notifications_own_read"
  on public.notifications for select
  to authenticated
  using (user_id = auth.uid() or public.is_sysadmin(auth.uid()));

drop policy if exists "notifications_own_update" on public.notifications;
create policy "notifications_own_update"
  on public.notifications for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "notifications_admin_insert" on public.notifications;
create policy "notifications_admin_insert"
  on public.notifications for insert
  to authenticated
  with check (public.is_sysadmin(auth.uid()));

-- Watchlist
drop policy if exists "watchlist_own_all" on public.watchlist;
create policy "watchlist_own_all"
  on public.watchlist for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.is_active_user(auth.uid()));

-- Discussions
drop policy if exists "discussion_public_read" on public.discussion_posts;
create policy "discussion_public_read"
  on public.discussion_posts for select
  using (removed_at is null or public.is_sysadmin(auth.uid()));

drop policy if exists "discussion_active_insert" on public.discussion_posts;
create policy "discussion_active_insert"
  on public.discussion_posts for insert
  to authenticated
  with check (user_id = auth.uid() and public.is_active_contributor(auth.uid()));

drop policy if exists "discussion_admin_update" on public.discussion_posts;
create policy "discussion_admin_update"
  on public.discussion_posts for update
  to authenticated
  using (public.is_sysadmin(auth.uid()))
  with check (public.is_sysadmin(auth.uid()));

-- Reports
drop policy if exists "reports_own_admin_read" on public.reports;
create policy "reports_own_admin_read"
  on public.reports for select
  to authenticated
  using (reporter_id = auth.uid() or public.is_sysadmin(auth.uid()));

drop policy if exists "reports_active_insert" on public.reports;
create policy "reports_active_insert"
  on public.reports for insert
  to authenticated
  with check (reporter_id = auth.uid() and public.is_active_user(auth.uid()));

drop policy if exists "reports_admin_update" on public.reports;
create policy "reports_admin_update"
  on public.reports for update
  to authenticated
  using (public.is_sysadmin(auth.uid()))
  with check (public.is_sysadmin(auth.uid()));

-- Grants
grant select, insert, update, delete on public.article_revisions to authenticated;
grant select on public.article_revisions to anon;
grant select, insert, update on public.moderation_actions to authenticated;
grant select, insert, update, delete on public.admin_user_notes to authenticated;
grant select, insert, update on public.notifications to authenticated;
grant usage, select on sequence public.notifications_id_seq to authenticated;
grant select, insert, delete on public.watchlist to authenticated;
grant select on public.watchlist to anon;
grant select on public.discussion_posts to anon, authenticated;
grant insert, update on public.discussion_posts to authenticated;
grant select, insert, update on public.reports to authenticated;

-- ---------------------------------------------------------------------------
-- Audit revision changes
-- ---------------------------------------------------------------------------
create or replace function public.audit_revision_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  act text;
begin
  if tg_op = 'INSERT' then
    act := 'revision.created';
  elsif new.status is distinct from old.status then
    act := 'revision.status_changed';
  else
    act := 'revision.updated';
  end if;

  insert into public.audit_logs(user_id, action, target_type, target_id, metadata)
  values (
    auth.uid(), act, 'revision', new.id,
    jsonb_build_object(
      'article_id', new.article_id,
      'old_status', case when tg_op = 'UPDATE' then old.status::text else null end,
      'new_status', new.status::text,
      'edit_summary', new.edit_summary
    )
  );

  return new;
end;
$$;

drop trigger if exists audit_revision_changes on public.article_revisions;
create trigger audit_revision_changes
  after insert or update on public.article_revisions
  for each row execute procedure public.audit_revision_change();

-- v0.2 does not seed content. The first real article still comes from the UI.
