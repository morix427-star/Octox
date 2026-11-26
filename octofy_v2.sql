-- =====================================================================
-- Octofy 2.0: чистая установка схемы. Выполнить ЦЕЛИКОМ в Supabase SQL Editor.
--
-- ВНИМАНИЕ: скрипт удаляет все существующие чаты, сообщения и реакции
-- (таблицы conversations, conversation_members, messages, message_reactions).
-- Пользователи (auth.users) и профили (public.profiles) остаются.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- 0. очистка старого ----------
drop trigger if exists on_auth_user_created on auth.users;
drop table if exists public.message_reactions cascade;
drop table if exists public.messages cascade;
drop table if exists public.conversation_members cascade;
drop table if exists public.conversations cascade;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in (
        'create_direct_conversation','create_group_conversation','get_unread_counts',
        'is_member','add_group_members','remove_group_member','leave_conversation',
        'rename_group','edit_message','delete_message','toggle_reaction','mark_read',
        'touch_seen','touch_conversation','handle_new_user','chat_file_member')
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

-- ---------- 1. профили ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  display_name text,
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists last_seen_at timestamptz;

do $$ begin
  create unique index if not exists profiles_username_uq on public.profiles (username);
exception when others then
  raise notice 'индекс username пропущен: %', sqlerrm;
end $$;

create function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  base text;
  candidate text;
  n int := 0;
begin
  base := lower(regexp_replace(coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)), '[^a-zA-Z0-9_]', '', 'g'));
  if char_length(base) < 3 then base := base || 'user'; end if;
  base := left(base, 20);
  candidate := base;
  while exists (select 1 from public.profiles where username = candidate) loop
    n := n + 1;
    candidate := base || n::text;
  end loop;
  insert into public.profiles(id, username, display_name)
  values (new.id, candidate, coalesce(new.raw_user_meta_data->>'display_name', candidate))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- профили для тех, у кого их ещё нет
insert into public.profiles(id, username, display_name)
select u.id,
       left(lower(regexp_replace(split_part(u.email,'@',1), '[^a-zA-Z0-9_]', '', 'g')), 15) || substr(replace(u.id::text,'-',''),1,5),
       split_part(u.email,'@',1)
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id);

-- ---------- 2. таблицы чатов ----------
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('direct','group')),
  title text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);

create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  last_read_at timestamptz not null default now(),
  is_favorite boolean not null default false,
  is_pinned boolean not null default false,
  is_muted boolean not null default false,
  primary key (conversation_id, user_id)
);
create index idx_members_user on public.conversation_members(user_id);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  kind text not null default 'text' check (kind in ('text','image','file','voice')),
  body text check (body is null or char_length(body) <= 4000),
  file_path text,
  file_name text,
  file_size bigint,
  file_type text,
  duration int,
  reply_to uuid references public.messages(id) on delete set null,
  edited_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  check (deleted_at is not null or kind <> 'text' or (body is not null and char_length(body) > 0))
);
create index idx_messages_conv on public.messages(conversation_id, created_at desc);

create table public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);
create index idx_reactions_conv on public.message_reactions(conversation_id);

-- ---------- 3. вспомогательные функции ----------
create function public.is_member(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.conversation_members
                 where conversation_id = cid and user_id = auth.uid());
$$;

-- доступ к файлам чата: первая папка пути = id беседы
create function public.chat_file_member(path text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when split_part(path, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then public.is_member(split_part(path, '/', 1)::uuid)
    else false
  end;
$$;

-- ---------- 4. чаты ----------
create function public.create_direct_conversation(other_username text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  other uuid;
  cid uuid;
begin
  if me is null then raise exception 'not authenticated'; end if;
  select id into other from public.profiles where username = lower(trim(both '@ ' from other_username));
  if other is null then raise exception 'user not found'; end if;
  if other = me then raise exception 'cannot chat with yourself'; end if;

  select c.id into cid
  from public.conversations c
  join public.conversation_members a on a.conversation_id = c.id and a.user_id = me
  join public.conversation_members b on b.conversation_id = c.id and b.user_id = other
  where c.type = 'direct'
  limit 1;
  if cid is not null then return cid; end if;

  insert into public.conversations(type, created_by) values ('direct', me) returning id into cid;
  insert into public.conversation_members(conversation_id, user_id, role)
  values (cid, me, 'owner'), (cid, other, 'member');
  return cid;
end $$;

create function public.create_group_conversation(group_title text, usernames text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  cid uuid;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if group_title is null or char_length(trim(group_title)) = 0 then raise exception 'title required'; end if;
  insert into public.conversations(type, title, created_by)
  values ('group', left(trim(group_title), 60), me) returning id into cid;
  insert into public.conversation_members(conversation_id, user_id, role) values (cid, me, 'owner');
  insert into public.conversation_members(conversation_id, user_id)
  select p.id, 'member' from public.profiles p
  where p.username = any (select lower(trim(both '@ ' from u)) from unnest(usernames) u)
    and p.id <> me
  on conflict do nothing;
  return cid;
end $$;

create function public.add_group_members(cid uuid, usernames text[])
returns int language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  n int;
begin
  if not exists (select 1 from public.conversation_members
                 where conversation_id = cid and user_id = me and role = 'owner') then
    raise exception 'only owner';
  end if;
  if (select type from public.conversations where id = cid) <> 'group' then
    raise exception 'not a group';
  end if;
  insert into public.conversation_members(conversation_id, user_id)
  select cid, p.id from public.profiles p
  where p.username = any (select lower(trim(both '@ ' from u)) from unnest(usernames) u)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create function public.remove_group_member(cid uuid, target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not exists (select 1 from public.conversation_members
                 where conversation_id = cid and user_id = me and role = 'owner') then
    raise exception 'only owner';
  end if;
  if target = me then raise exception 'use leave'; end if;
  delete from public.conversation_members where conversation_id = cid and user_id = target;
end $$;

create function public.leave_conversation(cid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  was_owner boolean;
  remaining int;
begin
  select (role = 'owner') into was_owner from public.conversation_members
   where conversation_id = cid and user_id = me;
  if was_owner is null then raise exception 'not a member'; end if;

  delete from public.conversation_members where conversation_id = cid and user_id = me;
  select count(*) into remaining from public.conversation_members where conversation_id = cid;

  if remaining = 0 then
    delete from public.conversations where id = cid;
  elsif was_owner then
    update public.conversation_members set role = 'owner'
     where conversation_id = cid
       and user_id = (select user_id from public.conversation_members
                       where conversation_id = cid order by joined_at limit 1);
  end if;
end $$;

create function public.rename_group(cid uuid, new_title text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if new_title is null or char_length(trim(new_title)) = 0 then raise exception 'title required'; end if;
  update public.conversations set title = left(trim(new_title), 60)
   where id = cid and type = 'group'
     and exists (select 1 from public.conversation_members
                  where conversation_id = cid and user_id = auth.uid() and role = 'owner');
  if not found then raise exception 'only owner'; end if;
end $$;

-- ---------- 5. сообщения ----------
create function public.edit_message(mid uuid, new_body text)
returns void language plpgsql security definer set search_path = public as $$
declare t text := trim(new_body);
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if t is null or char_length(t) = 0 or char_length(t) > 4000 then raise exception 'invalid body'; end if;
  update public.messages set body = t, edited_at = now()
   where id = mid and sender_id = auth.uid() and kind = 'text' and deleted_at is null;
  if not found then raise exception 'cannot edit'; end if;
end $$;

create function public.delete_message(mid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.messages
     set deleted_at = now(), body = null, file_path = null, file_name = null,
         file_size = null, file_type = null, duration = null
   where id = mid and sender_id = auth.uid() and deleted_at is null;
  if not found then raise exception 'cannot delete'; end if;
end $$;

create function public.toggle_reaction(mid uuid, e text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  cid uuid;
begin
  select conversation_id into cid from public.messages where id = mid;
  if me is null or cid is null or not public.is_member(cid) then raise exception 'forbidden'; end if;
  if exists (select 1 from public.message_reactions r
              where r.message_id = mid and r.user_id = me and r.emoji = e) then
    delete from public.message_reactions r
     where r.message_id = mid and r.user_id = me and r.emoji = e;
    return false;
  end if;
  insert into public.message_reactions(message_id, user_id, conversation_id, emoji)
  values (mid, me, cid, e);
  return true;
end $$;

create function public.mark_read(cid uuid)
returns void language sql security definer set search_path = public as $$
  update public.conversation_members set last_read_at = now()
   where conversation_id = cid and user_id = auth.uid();
$$;

create function public.touch_seen()
returns void language sql security definer set search_path = public as $$
  update public.profiles set last_seen_at = now() where id = auth.uid();
$$;

create function public.get_unread_counts()
returns table(conversation_id uuid, cnt bigint)
language sql stable security definer set search_path = public as $$
  select m.conversation_id, count(*)::bigint
  from public.messages m
  join public.conversation_members cm
    on cm.conversation_id = m.conversation_id and cm.user_id = auth.uid()
  where m.sender_id <> auth.uid() and m.deleted_at is null and m.created_at > cm.last_read_at
  group by m.conversation_id;
$$;

create function public.touch_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set last_message_at = new.created_at where id = new.conversation_id;
  return new;
end $$;
create trigger trg_touch_conversation after insert on public.messages
  for each row execute function public.touch_conversation();

-- ---------- 6. права на функции ----------
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.touch_conversation() from public, anon, authenticated;

revoke all on function public.is_member(uuid) from public, anon;
revoke all on function public.chat_file_member(text) from public, anon;
revoke all on function public.create_direct_conversation(text) from public, anon;
revoke all on function public.create_group_conversation(text, text[]) from public, anon;
revoke all on function public.add_group_members(uuid, text[]) from public, anon;
revoke all on function public.remove_group_member(uuid, uuid) from public, anon;
revoke all on function public.leave_conversation(uuid) from public, anon;
revoke all on function public.rename_group(uuid, text) from public, anon;
revoke all on function public.edit_message(uuid, text) from public, anon;
revoke all on function public.delete_message(uuid) from public, anon;
revoke all on function public.toggle_reaction(uuid, text) from public, anon;
revoke all on function public.mark_read(uuid) from public, anon;
revoke all on function public.touch_seen() from public, anon;
revoke all on function public.get_unread_counts() from public, anon;

grant execute on function public.is_member(uuid) to authenticated;
grant execute on function public.chat_file_member(text) to authenticated;
grant execute on function public.create_direct_conversation(text) to authenticated;
grant execute on function public.create_group_conversation(text, text[]) to authenticated;
grant execute on function public.add_group_members(uuid, text[]) to authenticated;
grant execute on function public.remove_group_member(uuid, uuid) to authenticated;
grant execute on function public.leave_conversation(uuid) to authenticated;
grant execute on function public.rename_group(uuid, text) to authenticated;
grant execute on function public.edit_message(uuid, text) to authenticated;
grant execute on function public.delete_message(uuid) to authenticated;
grant execute on function public.toggle_reaction(uuid, text) to authenticated;
grant execute on function public.mark_read(uuid) to authenticated;
grant execute on function public.touch_seen() to authenticated;
grant execute on function public.get_unread_counts() to authenticated;

-- ---------- 7. права на таблицы и RLS ----------
alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_reactions enable row level security;

-- убираем все старые политики профилей (в т.ч. от прежних установок)
do $$
declare r record;
begin
  for r in select policyname from pg_policies where schemaname = 'public' and tablename = 'profiles'
  loop
    execute format('drop policy %I on public.profiles', r.policyname);
  end loop;
end $$;

revoke all on public.profiles, public.conversations, public.conversation_members,
              public.messages, public.message_reactions from anon, authenticated;

grant select on public.profiles to authenticated;
grant update (display_name, bio, avatar_url) on public.profiles to authenticated;
grant select on public.conversations to authenticated;
grant select on public.conversation_members to authenticated;
grant update (is_favorite, is_pinned, is_muted) on public.conversation_members to authenticated;
grant select on public.messages to authenticated;
grant insert (conversation_id, sender_id, kind, body, file_path, file_name, file_size, file_type, duration, reply_to)
  on public.messages to authenticated;
grant select on public.message_reactions to authenticated;

create policy profiles_select on public.profiles for select to authenticated using (true);
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy conv_select on public.conversations for select to authenticated
  using (public.is_member(id));

create policy members_select on public.conversation_members for select to authenticated
  using (public.is_member(conversation_id));
create policy members_update_self on public.conversation_members for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy msg_select on public.messages for select to authenticated
  using (public.is_member(conversation_id));
create policy msg_insert on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_member(conversation_id));

create policy rx_select on public.message_reactions for select to authenticated
  using (public.is_member(conversation_id));

-- ---------- 8. хранилище файлов ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('chat-files', 'chat-files', false, 26214400)
on conflict (id) do update set public = false, file_size_limit = 26214400;

insert into storage.buckets (id, name, public, file_size_limit)
values ('avatars', 'avatars', true, 3145728)
on conflict (id) do update set public = true, file_size_limit = 3145728;

drop policy if exists octofy_files_select on storage.objects;
create policy octofy_files_select on storage.objects for select to authenticated
  using (bucket_id = 'chat-files' and public.chat_file_member(name));

drop policy if exists octofy_files_insert on storage.objects;
create policy octofy_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-files' and public.chat_file_member(name));

drop policy if exists octofy_avatars_select on storage.objects;
create policy octofy_avatars_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars');

drop policy if exists octofy_avatars_insert on storage.objects;
create policy octofy_avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- 9. realtime ----------
do $$ begin alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.conversation_members;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.message_reactions;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.conversations;
exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
