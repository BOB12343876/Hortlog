-- =====================================================================
-- Hortlog: orchards, roles, invitations, permissions and spray alerts
-- Run once in the Supabase SQL editor. Safe to run again.
--
-- What it does
--   1. Creates orchards, members, invitations, alerts and profiles.
--   2. Gives every EXISTING user their own orchard (they become Owner)
--      and attaches their existing records and blocks to it. Nothing is
--      changed or deleted in the records themselves.
--   3. Replaces the old "my rows only" security rules on entries and
--      blocks with role-based rules for each orchard.
--   4. Keeps old app versions working: rows saved by an old version are
--      attached to that user's orchard automatically.
--
-- A copy of the old security rules is saved in public._hortlog_policy_backup.
-- =====================================================================

begin;

-- ---------- 1. Tables ----------
create table if not exists public.orchards (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'My orchard',
  tz text not null default 'Pacific/Auckland',
  created_by uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.orchard_members (
  orchard_id uuid not null references public.orchards(id) on delete cascade,
  user_id uuid not null,
  role text not null check (role in ('owner','manager','supervisor','worker','contractor','other')),
  full_name text,
  requested_role text,
  blocks int[],
  created_at timestamptz not null default now(),
  primary key (orchard_id, user_id)
);
create index if not exists orchard_members_user on public.orchard_members(user_id);

create table if not exists public.orchard_invites (
  id uuid primary key default gen_random_uuid(),
  orchard_id uuid not null references public.orchards(id) on delete cascade,
  email text not null,
  role text not null check (role in ('manager','supervisor','worker','contractor','other')),
  blocks int[],
  invited_by uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  accepted_by uuid,
  revoked_at timestamptz
);
create unique index if not exists orchard_invites_pending
  on public.orchard_invites (orchard_id, lower(email))
  where accepted_at is null and revoked_at is null;

create table if not exists public.orchard_alerts (
  id uuid primary key default gen_random_uuid(),
  orchard_id uuid not null references public.orchards(id) on delete cascade,
  alert_date date not null,
  block int,
  kind text not null check (kind in ('spray','spread')),
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index if not exists orchard_alerts_once
  on public.orchard_alerts (orchard_id, alert_date, kind, coalesce(block, 0));

create table if not exists public.profiles (
  user_id uuid primary key,
  prefs jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- ---------- 2. Link existing tables to orchards ----------
alter table public.entries add column if not exists user_id uuid default auth.uid();
alter table public.blocks  add column if not exists user_id uuid default auth.uid();
alter table public.entries add column if not exists orchard_id uuid references public.orchards(id) on delete cascade;
alter table public.blocks  add column if not exists orchard_id uuid references public.orchards(id) on delete cascade;

-- keep a copy of the old rules, once
do $$
begin
  if to_regclass('public._hortlog_policy_backup') is null then
    execute 'create table public._hortlog_policy_backup as
             select now() as saved_at, schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
             from pg_policies where schemaname = ''public'' and tablename in (''entries'',''blocks'')';
    execute 'alter table public._hortlog_policy_backup enable row level security';
  end if;
end $$;

-- ---------- 3. Helper functions ----------
create or replace function public.orchard_role(o uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from public.orchard_members where orchard_id = o and user_id = auth.uid()
$$;

create or replace function public.orchard_blocks(o uuid) returns int[]
language sql stable security definer set search_path = public as $$
  select blocks from public.orchard_members where orchard_id = o and user_id = auth.uid()
$$;

create or replace function public.is_spray_entry(d jsonb) returns boolean
language sql immutable as $$
  select coalesce(d->>'c','') = 'spray'
      or coalesce(d->>'rc','') = 'sf'
      or (coalesce(d->>'rc','') = 'compliance' and coalesce(d->>'rf','') in ('Spray diary','Fertiliser'))
$$;

create or replace function public.is_finished_entry(d jsonb) returns boolean
language sql immutable as $$
  select coalesce(d->>'c','') = 'rec' or (coalesce(d->>'c','') = 'spray' and coalesce(d->>'d','') = 'true')
$$;

create or replace function public.block_of(d jsonb) returns int
language sql immutable as $$
  select case when (d->>'b') ~ '^[0-9]+$' then (d->>'b')::int end
$$;

-- ---------- 4. Backfill: one orchard per existing user ----------
do $$
declare r record; oid uuid; nm text;
begin
  for r in
    select distinct s.u from (
      select user_id as u from public.entries where user_id is not null
      union
      select user_id from public.blocks where user_id is not null
    ) s
    where not exists (select 1 from public.orchard_members m where m.user_id = s.u)
  loop
    select nullif(trim(data->>'biz'), '') into nm
      from public.blocks b where b.user_id = r.u and b.block = 0 limit 1;
    insert into public.orchards (name, created_by) values (coalesce(nm, 'My orchard'), r.u) returning id into oid;
    insert into public.orchard_members (orchard_id, user_id, role) values (oid, r.u, 'owner');
  end loop;

  update public.entries e set orchard_id = (
    select m.orchard_id from public.orchard_members m
    where m.user_id = e.user_id and m.role = 'owner' order by m.created_at limit 1)
  where e.orchard_id is null;

  update public.blocks b set orchard_id = (
    select m.orchard_id from public.orchard_members m
    where m.user_id = b.user_id and m.role = 'owner' order by m.created_at limit 1)
  where b.orchard_id is null;

  if exists (select 1 from public.entries where orchard_id is null)
     or exists (select 1 from public.blocks where orchard_id is null) then
    raise exception 'Some rows have no owner (user_id is empty), so they cannot be attached to an orchard. Nothing was changed. Please review those rows first.';
  end if;
end $$;

alter table public.entries alter column orchard_id set not null;
alter table public.blocks  alter column orchard_id set not null;

-- primary keys now belong to the orchard, so a manager editing a worker's entry updates the same row
do $$
declare c text;
begin
  select conname into c from pg_constraint where conrelid = 'public.entries'::regclass and contype = 'p';
  if c is not null and c <> 'entries_orchard_pk' then
    execute format('alter table public.entries drop constraint %I', c);
    alter table public.entries add constraint entries_orchard_pk primary key (orchard_id, id);
  end if;
  select conname into c from pg_constraint where conrelid = 'public.blocks'::regclass and contype = 'p';
  if c is not null and c <> 'blocks_orchard_pk' then
    execute format('alter table public.blocks drop constraint %I', c);
    alter table public.blocks add constraint blocks_orchard_pk primary key (orchard_id, block);
  end if;
end $$;

-- ---------- 5. Triggers on entries and blocks ----------
-- new rows from an old app version (no orchard sent) go to the user's own orchard
create or replace function public.set_orchard_id() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is null then new.user_id := auth.uid(); end if;
  if new.orchard_id is null then
    select m.orchard_id into new.orchard_id from public.orchard_members m
    where m.user_id = coalesce(new.user_id, auth.uid())
    order by (m.role = 'owner') desc, m.created_at limit 1;
  end if;
  return new;
end $$;

-- authorship and orchard cannot be changed by an edit
create or replace function public.keep_owner_fields() returns trigger
language plpgsql as $$
begin
  new.user_id := old.user_id;
  if new.orchard_id is distinct from old.orchard_id then
    raise exception 'A record cannot be moved to another orchard';
  end if;
  return new;
end $$;

drop trigger if exists entries_set_orchard on public.entries;
create trigger entries_set_orchard before insert on public.entries
  for each row execute function public.set_orchard_id();
drop trigger if exists blocks_set_orchard on public.blocks;
create trigger blocks_set_orchard before insert on public.blocks
  for each row execute function public.set_orchard_id();
drop trigger if exists entries_keep_owner on public.entries;
create trigger entries_keep_owner before update on public.entries
  for each row execute function public.keep_owner_fields();
drop trigger if exists blocks_keep_owner on public.blocks;
create trigger blocks_keep_owner before update on public.blocks
  for each row execute function public.keep_owner_fields();

-- spraying, fertiliser or spreading planned or done today raises one alert per block and day
create or replace function public.entries_alert() returns trigger
language plpgsql security definer set search_path = public as $$
declare d jsonb := new.data; tz text; today date; hit boolean := false; k text;
begin
  if not (coalesce(d->>'c','') = 'spray' or coalesce(d->>'rc','') = 'sf') then return new; end if;
  select o.tz into tz from public.orchards o where o.id = new.orchard_id;
  tz := coalesce(tz, 'Pacific/Auckland');
  today := (now() at time zone tz)::date;
  if coalesce(d->>'d','') <> 'true' and (d->>'due') ~ '^\d{4}-\d{2}-\d{2}$' and (d->>'due')::date = today then hit := true; end if;
  if coalesce(d->>'d','') = 'true' and (d->>'doneAt') ~ '^\d+$'
     and (to_timestamp((d->>'doneAt')::numeric / 1000.0) at time zone tz)::date = today then hit := true; end if;
  if coalesce(d->>'rc','') = 'sf' and (d->>'rdate') ~ '^\d{4}-\d{2}-\d{2}$' and (d->>'rdate')::date = today then hit := true; end if;
  if not hit then return new; end if;
  k := case when coalesce(d->>'fk','') = 'fert' or coalesce(d->>'rf','') = 'Fertiliser'
              or coalesce(d->>'t','') ~* 'fertili|compost|manure|urea|potash|dolomite|gypsum|spread|top ?dress'
            then 'spread' else 'spray' end;
  insert into public.orchard_alerts (orchard_id, alert_date, block, kind, created_by)
  values (new.orchard_id, today, public.block_of(d), k, new.user_id)
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists entries_alert_trg on public.entries;
create trigger entries_alert_trg after insert or update on public.entries
  for each row execute function public.entries_alert();

-- ---------- 6. Security rules (row level security) ----------
do $$
declare p record;
begin
  for p in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('entries','blocks') loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

alter table public.entries enable row level security;
alter table public.blocks enable row level security;
alter table public.orchards enable row level security;
alter table public.orchard_members enable row level security;
alter table public.orchard_invites enable row level security;
alter table public.orchard_alerts enable row level security;
alter table public.profiles enable row level security;

-- entries
create policy entries_select on public.entries for select to authenticated using (
  public.orchard_role(orchard_id) is not null
  and (
    public.orchard_role(orchard_id) <> 'contractor'
    or (not public.is_spray_entry(data)
        and (user_id = auth.uid()
             or public.block_of(data) = any (coalesce(public.orchard_blocks(orchard_id), '{}'::int[]))))
  )
);

create policy entries_insert on public.entries for insert to authenticated with check (
  user_id = auth.uid()
  and (
    public.orchard_role(orchard_id) in ('owner','manager','supervisor','worker')
    or (public.orchard_role(orchard_id) = 'contractor' and not public.is_spray_entry(data)
        and (public.block_of(data) is null
             or public.block_of(data) = any (coalesce(public.orchard_blocks(orchard_id), '{}'::int[]))))
  )
);

create policy entries_update on public.entries for update to authenticated
using (
  public.orchard_role(orchard_id) in ('owner','manager','supervisor')
  or (public.orchard_role(orchard_id) in ('worker','contractor') and user_id = auth.uid())
)
with check (
  public.orchard_role(orchard_id) in ('owner','manager','supervisor')
  or (public.orchard_role(orchard_id) = 'worker' and user_id = auth.uid())
  or (public.orchard_role(orchard_id) = 'contractor' and user_id = auth.uid() and not public.is_spray_entry(data))
);

create policy entries_delete on public.entries for delete to authenticated using (
  public.orchard_role(orchard_id) in ('owner','manager')
  or (public.orchard_role(orchard_id) = 'supervisor'
      and (user_id = auth.uid() or not public.is_finished_entry(data)))
  or (public.orchard_role(orchard_id) in ('worker','contractor') and user_id = auth.uid())
);

-- blocks (block 0 holds orchard settings and products)
create policy blocks_select on public.blocks for select to authenticated using (
  public.orchard_role(orchard_id) is not null
  and (public.orchard_role(orchard_id) <> 'contractor'
       or block = 0
       or block = any (coalesce(public.orchard_blocks(orchard_id), '{}'::int[])))
);
create policy blocks_insert on public.blocks for insert to authenticated with check (
  public.orchard_role(orchard_id) in ('owner','manager','supervisor'));
create policy blocks_update on public.blocks for update to authenticated
  using (public.orchard_role(orchard_id) in ('owner','manager','supervisor'))
  with check (public.orchard_role(orchard_id) in ('owner','manager','supervisor'));
create policy blocks_delete on public.blocks for delete to authenticated using (
  public.orchard_role(orchard_id) in ('owner','manager','supervisor'));

-- orchards, members, alerts, profiles (changes to members and invites go through the functions below)
drop policy if exists orchards_select on public.orchards;
drop policy if exists members_select on public.orchard_members;
drop policy if exists alerts_select on public.orchard_alerts;
drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy orchards_select on public.orchards for select to authenticated
  using (public.orchard_role(id) is not null);
create policy members_select on public.orchard_members for select to authenticated
  using (user_id = auth.uid() or public.orchard_role(orchard_id) is not null);
create policy alerts_select on public.orchard_alerts for select to authenticated
  using (public.orchard_role(orchard_id) is not null);
create policy profiles_select on public.profiles for select to authenticated using (user_id = auth.uid());
create policy profiles_insert on public.profiles for insert to authenticated with check (user_id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- (no policy on orchard_invites: only the functions below can read or write it)

revoke all on public.orchards, public.orchard_members, public.orchard_invites, public.orchard_alerts, public.profiles from anon;
grant select on public.orchards, public.orchard_members, public.orchard_alerts to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.entries, public.blocks to authenticated;

-- ---------- 7. Functions the app calls ----------
create or replace function public.my_orchards()
returns table (orchard_id uuid, name text, tz text, role text, full_name text, blocks int[])
language sql stable security definer set search_path = public as $$
  select o.id, o.name, o.tz, m.role, m.full_name, m.blocks
  from public.orchard_members m join public.orchards o on o.id = m.orchard_id
  where m.user_id = auth.uid() order by m.created_at
$$;

create or replace function public.create_orchard(p_name text, p_full_name text default null)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare oid uuid; meta jsonb := coalesce(auth.jwt()->'user_metadata', '{}'::jsonb);
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if (select count(*) from public.orchard_members where user_id = auth.uid() and role = 'owner') >= 5 then
    raise exception 'You already own the maximum number of orchards';
  end if;
  insert into public.orchards (name, created_by)
    values (coalesce(nullif(trim(p_name), ''), 'My orchard'), auth.uid()) returning id into oid;
  insert into public.orchard_members (orchard_id, user_id, role, full_name, requested_role)
    values (oid, auth.uid(), 'owner', coalesce(nullif(trim(p_full_name), ''), meta->>'full_name'), meta->>'requested_role');
  return oid;
end $$;

create or replace function public.accept_invites()
returns table (orchard_id uuid, name text, role text)
language plpgsql security definer set search_path = public, auth as $$
declare i record; em text; confirmed boolean; meta jsonb := coalesce(auth.jwt()->'user_metadata', '{}'::jsonb);
begin
  if auth.uid() is null then return; end if;
  select lower(u.email), u.email_confirmed_at is not null into em, confirmed from auth.users u where u.id = auth.uid();
  if em is null or not confirmed then return; end if;
  for i in select * from public.orchard_invites v
           where lower(v.email) = em and v.accepted_at is null and v.revoked_at is null and v.expires_at > now() loop
    insert into public.orchard_members (orchard_id, user_id, role, full_name, requested_role, blocks)
      values (i.orchard_id, auth.uid(), i.role, meta->>'full_name', meta->>'requested_role', i.blocks)
      on conflict on constraint orchard_members_pkey do nothing;
    update public.orchard_invites set accepted_at = now(), accepted_by = auth.uid() where id = i.id;
    return query select o.id, o.name, i.role from public.orchards o where o.id = i.orchard_id;
  end loop;
end $$;

create or replace function public.list_members(o uuid)
returns table (user_id uuid, full_name text, role text, blocks int[], email text, created_at timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
declare me text := public.orchard_role(o);
begin
  if me is null then raise exception 'Not a member of this orchard'; end if;
  return query
    select m.user_id, m.full_name, m.role, m.blocks,
           case when me in ('owner','manager') then u.email::text end, m.created_at
    from public.orchard_members m left join auth.users u on u.id = m.user_id
    where m.orchard_id = o
    order by array_position(array['owner','manager','supervisor','worker','contractor','other'], m.role), m.created_at;
end $$;

create or replace function public.set_member(o uuid, u uuid, p_role text, p_blocks int[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare me text := public.orchard_role(o); target text;
begin
  if me is null or me not in ('owner','manager') then raise exception 'Only an owner or manager can change roles'; end if;
  select role into target from public.orchard_members where orchard_id = o and user_id = u;
  if target is null then raise exception 'That person is not in this orchard'; end if;
  if p_role not in ('owner','manager','supervisor','worker','contractor','other') then raise exception 'Unknown role'; end if;
  if me = 'manager' and (target = 'owner' or p_role = 'owner') then raise exception 'Only an owner can change an owner'; end if;
  if target = 'owner' and p_role <> 'owner'
     and (select count(*) from public.orchard_members where orchard_id = o and role = 'owner') <= 1 then
    raise exception 'An orchard needs at least one owner';
  end if;
  update public.orchard_members
     set role = p_role, blocks = case when p_role = 'contractor' then p_blocks else null end
   where orchard_id = o and user_id = u;
end $$;

create or replace function public.remove_member(o uuid, u uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me text := public.orchard_role(o); target text;
begin
  select role into target from public.orchard_members where orchard_id = o and user_id = u;
  if target is null then return; end if;
  if u <> auth.uid() then
    if me is null or me not in ('owner','manager') then raise exception 'Only an owner or manager can remove people'; end if;
    if me = 'manager' and target = 'owner' then raise exception 'Only an owner can remove an owner'; end if;
  end if;
  if target = 'owner' and (select count(*) from public.orchard_members where orchard_id = o and role = 'owner') <= 1 then
    raise exception 'An orchard needs at least one owner. Make someone else an owner first.';
  end if;
  delete from public.orchard_members where orchard_id = o and user_id = u;
end $$;

create or replace function public.create_invite(o uuid, p_email text, p_role text, p_blocks int[] default null)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare me text := public.orchard_role(o); em text := lower(trim(p_email)); iid uuid;
begin
  if me is null or me not in ('owner','manager') then raise exception 'Only an owner or manager can invite people'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That does not look like an email address'; end if;
  if p_role not in ('manager','supervisor','worker','contractor','other') then raise exception 'Choose a role for this person'; end if;
  if exists (select 1 from public.orchard_members m join auth.users u on u.id = m.user_id
             where m.orchard_id = o and lower(u.email) = em) then
    raise exception 'That person is already in this orchard';
  end if;
  insert into public.orchard_invites (orchard_id, email, role, blocks, invited_by)
    values (o, em, p_role, case when p_role = 'contractor' then p_blocks end, auth.uid())
  on conflict (orchard_id, lower(email)) where accepted_at is null and revoked_at is null
  do update set role = excluded.role, blocks = excluded.blocks, invited_by = auth.uid(),
                created_at = now(), expires_at = now() + interval '7 days'
  returning id into iid;
  return iid;
end $$;

create or replace function public.list_invites(o uuid)
returns table (id uuid, email text, role text, blocks int[], expires_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.orchard_role(o),'') not in ('owner','manager') then raise exception 'Not allowed'; end if;
  return query select v.id, v.email, v.role, v.blocks, v.expires_at from public.orchard_invites v
    where v.orchard_id = o and v.accepted_at is null and v.revoked_at is null and v.expires_at > now()
    order by v.created_at desc;
end $$;

create or replace function public.revoke_invite(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  select orchard_id into o from public.orchard_invites where id = p_id;
  if o is null then return; end if;
  if coalesce(public.orchard_role(o),'') not in ('owner','manager') then raise exception 'Not allowed'; end if;
  update public.orchard_invites set revoked_at = now() where id = p_id and accepted_at is null;
end $$;

create or replace function public.set_my_name(o uuid, n text)
returns void language sql security definer set search_path = public as $$
  update public.orchard_members set full_name = nullif(trim(n), '') where orchard_id = o and user_id = auth.uid()
$$;

create or replace function public.rename_orchard(o uuid, n text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.orchard_role(o),'') not in ('owner','manager') then raise exception 'Only an owner or manager can rename the orchard'; end if;
  update public.orchards set name = coalesce(nullif(trim(n), ''), name) where id = o;
end $$;

create or replace function public.todays_alerts(o uuid)
returns table (id uuid, block int, kind text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if public.orchard_role(o) is null then raise exception 'Not a member of this orchard'; end if;
  select coalesce(x.tz, 'Pacific/Auckland') into tz from public.orchards x where x.id = o;
  return query select a.id, a.block, a.kind, a.created_at from public.orchard_alerts a
    where a.orchard_id = o and a.alert_date = (now() at time zone tz)::date order by a.created_at;
end $$;

-- only signed-in users may call these
do $$
declare f text;
begin
  for f in select unnest(array[
    'my_orchards()','create_orchard(text,text)','accept_invites()','list_members(uuid)','set_member(uuid,uuid,text,int[])',
    'remove_member(uuid,uuid)','create_invite(uuid,text,text,int[])','list_invites(uuid)','revoke_invite(uuid)',
    'set_my_name(uuid,text)','rename_orchard(uuid,text)','todays_alerts(uuid)']) loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

commit;
