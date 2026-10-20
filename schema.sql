-- Pattes : messagerie + animal de compagnie
-- Nouveau projet, tout est préfixé pat_ (additif, rien d'existant n'est touché).
-- Prérequis Supabase : Authentication > Providers > Email > désactiver "Confirm email".

-- ───────────── Tables ─────────────
create table if not exists public.pat_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  created_at timestamptz not null default now(),
  constraint pat_username_fmt check (username ~ '^[a-z0-9_]{3,20}$')
);
create unique index if not exists pat_profiles_username_idx on public.pat_profiles (username);

create table if not exists public.pat_conversations (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now()
);

create table if not exists public.pat_members (
  conv_id bigint not null references public.pat_conversations(id) on delete cascade,
  user_id uuid not null references public.pat_profiles(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (conv_id, user_id)
);
create index if not exists pat_members_user_idx on public.pat_members (user_id);

create table if not exists public.pat_messages (
  id bigint generated always as identity primary key,
  conv_id bigint not null references public.pat_conversations(id) on delete cascade,
  sender_id uuid not null references public.pat_profiles(id) on delete cascade,
  body text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists pat_messages_conv_idx on public.pat_messages (conv_id, id);

create table if not exists public.pat_notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.pat_profiles(id) on delete cascade,
  kind text not null check (kind in ('message','pet')),
  conv_id bigint references public.pat_conversations(id) on delete cascade,
  message_id bigint,
  text text,
  seen boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists pat_notifications_unseen_idx on public.pat_notifications (user_id) where not seen;

create sequence if not exists public.pat_pets_seq;
create table if not exists public.pat_pets (
  id bigint generated always as identity primary key,
  tracking text not null unique default ('A-' || lpad(nextval('public.pat_pets_seq')::text, 6, '0')),
  owner_id uuid not null references public.pat_profiles(id) on delete cascade,
  name text not null check (length(name) between 1 and 16),
  species text not null check (species in ('chat','chien','lapin','renard')),
  color text not null check (color ~ '^#[0-9a-fA-F]{6}$'),
  accessory text not null default 'aucun' check (accessory in ('aucun','noeud','chapeau','lunettes','couronne')),
  fed_at timestamptz not null default now(),
  played_at timestamptz not null default now(),
  born_at timestamptz not null default now(),
  alive boolean not null default true,
  died_at timestamptz,
  alert_hunger_at timestamptz,
  alert_joy_at timestamptz
);
create unique index if not exists pat_pets_one_alive_idx on public.pat_pets (owner_id) where alive;

-- ───────────── Fonctions ─────────────
create or replace function public.pat_is_member(p_conv bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pat_members where conv_id = p_conv and user_id = auth.uid());
$$;

-- Notification pour chaque message reçu
create or replace function public.pat_on_message()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.pat_notifications (user_id, kind, conv_id, message_id, text)
  select m.user_id, 'message', new.conv_id, new.id, left(new.body, 80)
  from public.pat_members m
  where m.conv_id = new.conv_id and m.user_id <> new.sender_id;
  return new;
end $$;

drop trigger if exists pat_messages_notify on public.pat_messages;
create trigger pat_messages_notify after insert on public.pat_messages
  for each row execute function public.pat_on_message();

create or replace function public.pat_pet_json(r public.pat_pets)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'tracking', r.tracking, 'name', r.name, 'species', r.species, 'color', r.color,
    'accessory', r.accessory, 'alive', r.alive, 'fed_at', r.fed_at, 'played_at', r.played_at,
    'born_at', r.born_at, 'died_at', r.died_at, 'server_now', now());
$$;

-- Mort + alertes (faim / ennui). owner NULL = tous les animaux (cron)
-- Satiété : 100 -> 0 en 48 h. Joie : 100 -> 0 en 72 h. À 0 l'animal meurt.
create or replace function public.pat_tick_all(p_owner uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  r public.pat_pets; sat numeric; jy numeric;
begin
  for r in select * from public.pat_pets where alive and (p_owner is null or owner_id = p_owner) for update loop
    sat := 100 - extract(epoch from (now() - r.fed_at)) / 3600.0 * 100 / 48;
    jy  := 100 - extract(epoch from (now() - r.played_at)) / 3600.0 * 100 / 72;
    if sat <= 0 or jy <= 0 then
      update public.pat_pets set alive = false, died_at = now() where id = r.id;
      insert into public.pat_notifications (user_id, kind, text) values (r.owner_id, 'pet', r.name || ' est mort');
    else
      if sat < 35 and (r.alert_hunger_at is null or r.alert_hunger_at < now() - interval '6 hours') then
        insert into public.pat_notifications (user_id, kind, text) values (r.owner_id, 'pet', r.name || ' a faim');
        update public.pat_pets set alert_hunger_at = now() where id = r.id;
      end if;
      if jy < 35 and (r.alert_joy_at is null or r.alert_joy_at < now() - interval '6 hours') then
        insert into public.pat_notifications (user_id, kind, text) values (r.owner_id, 'pet', r.name || ' s''ennuie');
        update public.pat_pets set alert_joy_at = now() where id = r.id;
      end if;
    end if;
  end loop;
end $$;

create or replace function public.pat_cron()
returns void language sql security definer set search_path = public as $$
  select public.pat_tick_all(null);
$$;

create or replace function public.pat_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.pat_pets;
begin
  if me is null then raise exception 'non_authentifie'; end if;
  perform public.pat_tick_all(me);
  select * into r from public.pat_pets where owner_id = me order by id desc limit 1;
  if not found then return null; end if;
  return public.pat_pet_json(r);
end $$;

create or replace function public.pat_adopt(p_species text, p_name text, p_color text, p_accessory text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.pat_pets; nm text := btrim(coalesce(p_name, ''));
begin
  if me is null then raise exception 'non_authentifie'; end if;
  if length(nm) not between 1 and 16 then raise exception 'nom_invalide'; end if;
  perform public.pat_tick_all(me);
  if exists (select 1 from public.pat_pets where owner_id = me and alive) then raise exception 'deja_un_animal'; end if;
  insert into public.pat_pets (owner_id, name, species, color, accessory)
  values (me, nm, p_species, p_color, p_accessory) returning * into r;
  return public.pat_pet_json(r);
end $$;

create or replace function public.pat_feed()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.pat_pets; sat numeric; nsat numeric;
begin
  if me is null then raise exception 'non_authentifie'; end if;
  perform public.pat_tick_all(me);
  select * into r from public.pat_pets where owner_id = me and alive for update;
  if not found then raise exception 'pas_d_animal'; end if;
  sat := greatest(0, 100 - extract(epoch from (now() - r.fed_at)) / 3600.0 * 100 / 48);
  if sat >= 95 then raise exception 'deja_rassasie'; end if;
  nsat := least(100, sat + 60);
  update public.pat_pets
     set fed_at = now() - (((100 - nsat) * 48 / 100.0)::float8 * interval '1 hour'),
         alert_hunger_at = null
   where id = r.id returning * into r;
  return public.pat_pet_json(r);
end $$;

create or replace function public.pat_play()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.pat_pets; jy numeric; njy numeric;
begin
  if me is null then raise exception 'non_authentifie'; end if;
  perform public.pat_tick_all(me);
  select * into r from public.pat_pets where owner_id = me and alive for update;
  if not found then raise exception 'pas_d_animal'; end if;
  jy := greatest(0, 100 - extract(epoch from (now() - r.played_at)) / 3600.0 * 100 / 72);
  if jy >= 95 then raise exception 'deja_content'; end if;
  njy := least(100, jy + 50);
  update public.pat_pets
     set played_at = now() - (((100 - njy) * 72 / 100.0)::float8 * interval '1 hour'),
         alert_joy_at = null
   where id = r.id returning * into r;
  return public.pat_pet_json(r);
end $$;

create or replace function public.pat_customize(p_name text, p_color text, p_accessory text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.pat_pets; nm text := btrim(coalesce(p_name, ''));
begin
  if me is null then raise exception 'non_authentifie'; end if;
  if length(nm) not between 1 and 16 then raise exception 'nom_invalide'; end if;
  update public.pat_pets set name = nm, color = p_color, accessory = p_accessory
   where owner_id = me and alive returning * into r;
  if not found then raise exception 'pas_d_animal'; end if;
  return public.pat_pet_json(r);
end $$;

create or replace function public.pat_open_conversation(p_username text)
returns bigint language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); target uuid; cid bigint;
begin
  if me is null then raise exception 'non_authentifie'; end if;
  select id into target from public.pat_profiles where username = lower(btrim(p_username));
  if target is null then raise exception 'introuvable'; end if;
  if target = me then raise exception 'soi_meme'; end if;
  select a.conv_id into cid
    from public.pat_members a join public.pat_members b on b.conv_id = a.conv_id
   where a.user_id = me and b.user_id = target limit 1;
  if cid is null then
    insert into public.pat_conversations default values returning id into cid;
    insert into public.pat_members (conv_id, user_id) values (cid, me), (cid, target);
  end if;
  return cid;
end $$;

create or replace function public.pat_list_conversations()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); res jsonb;
begin
  if me is null then raise exception 'non_authentifie'; end if;
  select coalesce(jsonb_agg(s.x order by s.last_at desc), '[]'::jsonb) into res from (
    select jsonb_build_object(
             'conv_id', m.conv_id, 'username', o.username,
             'last_body', lm.body, 'last_at', lm.created_at) as x,
           lm.created_at as last_at
      from public.pat_members m
      join public.pat_members om on om.conv_id = m.conv_id and om.user_id <> me
      join public.pat_profiles o on o.id = om.user_id
      join lateral (select body, created_at from public.pat_messages
                     where conv_id = m.conv_id order by id desc limit 1) lm on true
     where m.user_id = me
  ) s;
  return res;
end $$;

create or replace function public.pat_mark_read(p_conv bigint)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'non_authentifie'; end if;
  update public.pat_members set last_read_at = now() where conv_id = p_conv and user_id = me;
  update public.pat_notifications set seen = true
   where user_id = me and conv_id = p_conv and kind = 'message' and not seen;
end $$;

create or replace function public.pat_mark_pet_seen()
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'non_authentifie'; end if;
  update public.pat_notifications set seen = true where user_id = me and kind = 'pet' and not seen;
end $$;

create or replace function public.pat_mark_all_read()
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'non_authentifie'; end if;
  update public.pat_members set last_read_at = now() where user_id = me;
  update public.pat_notifications set seen = true where user_id = me and not seen;
end $$;

-- ───────────── Droits ─────────────
revoke all on function public.pat_is_member(bigint) from public, anon;
revoke all on function public.pat_on_message() from public, anon, authenticated;
revoke all on function public.pat_pet_json(public.pat_pets) from public, anon, authenticated;
revoke all on function public.pat_tick_all(uuid) from public, anon, authenticated;
revoke all on function public.pat_cron() from public, anon, authenticated;
revoke all on function public.pat_status() from public, anon;
revoke all on function public.pat_adopt(text, text, text, text) from public, anon;
revoke all on function public.pat_feed() from public, anon;
revoke all on function public.pat_play() from public, anon;
revoke all on function public.pat_customize(text, text, text) from public, anon;
revoke all on function public.pat_open_conversation(text) from public, anon;
revoke all on function public.pat_list_conversations() from public, anon;
revoke all on function public.pat_mark_read(bigint) from public, anon;
revoke all on function public.pat_mark_pet_seen() from public, anon;
revoke all on function public.pat_mark_all_read() from public, anon;

grant execute on function public.pat_is_member(bigint) to authenticated;
grant execute on function public.pat_status() to authenticated;
grant execute on function public.pat_adopt(text, text, text, text) to authenticated;
grant execute on function public.pat_feed() to authenticated;
grant execute on function public.pat_play() to authenticated;
grant execute on function public.pat_customize(text, text, text) to authenticated;
grant execute on function public.pat_open_conversation(text) to authenticated;
grant execute on function public.pat_list_conversations() to authenticated;
grant execute on function public.pat_mark_read(bigint) to authenticated;
grant execute on function public.pat_mark_pet_seen() to authenticated;
grant execute on function public.pat_mark_all_read() to authenticated;

-- ───────────── RLS ─────────────
alter table public.pat_profiles enable row level security;
alter table public.pat_conversations enable row level security;
alter table public.pat_members enable row level security;
alter table public.pat_messages enable row level security;
alter table public.pat_notifications enable row level security;
alter table public.pat_pets enable row level security;

drop policy if exists pat_profiles_select on public.pat_profiles;
create policy pat_profiles_select on public.pat_profiles for select to authenticated using (true);
drop policy if exists pat_profiles_insert on public.pat_profiles;
create policy pat_profiles_insert on public.pat_profiles for insert to authenticated with check (id = auth.uid());

drop policy if exists pat_conv_select on public.pat_conversations;
create policy pat_conv_select on public.pat_conversations for select to authenticated using (public.pat_is_member(id));

drop policy if exists pat_members_select on public.pat_members;
create policy pat_members_select on public.pat_members for select to authenticated
  using (user_id = auth.uid() or public.pat_is_member(conv_id));

drop policy if exists pat_messages_select on public.pat_messages;
create policy pat_messages_select on public.pat_messages for select to authenticated using (public.pat_is_member(conv_id));
drop policy if exists pat_messages_insert on public.pat_messages;
create policy pat_messages_insert on public.pat_messages for insert to authenticated
  with check (sender_id = auth.uid() and public.pat_is_member(conv_id));

drop policy if exists pat_notif_select on public.pat_notifications;
create policy pat_notif_select on public.pat_notifications for select to authenticated using (user_id = auth.uid());

drop policy if exists pat_pets_select on public.pat_pets;
create policy pat_pets_select on public.pat_pets for select to authenticated using (owner_id = auth.uid());

grant select on public.pat_profiles, public.pat_conversations, public.pat_members,
                public.pat_messages, public.pat_notifications, public.pat_pets to authenticated;
grant insert on public.pat_profiles, public.pat_messages to authenticated;

-- ───────────── Realtime ─────────────
do $$
declare t text;
begin
  foreach t in array array['pat_messages','pat_notifications','pat_pets'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object or undefined_object then null;
    end;
  end loop;
end $$;

-- ───────────── Optionnel : alertes/mort même hors ligne (pg_cron) ─────────────
-- select cron.schedule('pat_cron', '*/15 * * * *', $$select public.pat_cron()$$);
