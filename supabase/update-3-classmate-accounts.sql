-- Update 3 (Nov 2026): let other coaches (classmates) create their own Poolside accounts.
-- Every account gets its own private space. Nobody can see anyone else's families, lessons or booking requests.
-- The original coach (the email in the "coach" table) keeps all existing data and unlimited AI.
-- Other accounts get a daily AI limit so the Anthropic bill stays small.
-- Safe to run more than once. Copy all of this into Supabase > SQL Editor > New snippet and click Run.

-- 1. Every row remembers which account owns it.
alter table records add column if not exists owner uuid;
alter table slots add column if not exists owner uuid;
alter table booking_requests add column if not exists owner uuid;

-- 2. Give all existing data to the original coach. Stops with an error (and changes nothing) if that account can't be found.
do $$
declare main_id uuid;
begin
  select u.id into main_id from auth.users u join coach c on lower(c.email) = lower(u.email) order by u.created_at limit 1;
  if main_id is null then
    if exists (select 1 from records where owner is null) or exists (select 1 from slots where owner is null) then
      raise exception 'Could not find the sign-in account for the email in the coach table, so nothing was changed.';
    end if;
    return;
  end if;
  update records set owner = main_id where owner is null;
  update slots set owner = main_id where owner is null;
  update booking_requests set owner = main_id where owner is null;
end $$;

alter table records alter column owner set default auth.uid();
alter table records alter column owner set not null;
alter table slots alter column owner set default auth.uid();
alter table slots alter column owner set not null;
alter table booking_requests alter column owner set default auth.uid();
alter table booking_requests alter column owner set not null;

-- Each account has its own "settings / main", examples, etc., so the owner is part of the key.
do $$
begin
  if not exists (
    select 1 from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
    where i.indrelid = 'public.records'::regclass and i.indisprimary and a.attname = 'owner'
  ) then
    alter table records drop constraint records_pkey;
    alter table records add primary key (owner, collection, id);
  end if;
end $$;
create index if not exists slots_owner_idx on slots (owner, date);
create index if not exists booking_requests_owner_idx on booking_requests (owner, status);

-- 3. Privacy rules: a signed-in account sees and changes only its own rows.
drop policy if exists coach_all on records;
drop policy if exists own_rows on records;
create policy own_rows on records for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists coach_all on slots;
drop policy if exists own_rows on slots;
create policy own_rows on slots for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists coach_all on booking_requests;
drop policy if exists own_rows on booking_requests;
create policy own_rows on booking_requests for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

-- 4. AI limits. The original coach is unlimited. Every other account gets a few AI uses a day,
--    and all of them together share a daily ceiling. Change the two numbers here any time and run this again.
create table if not exists ai_usage (
  owner uuid not null,
  day date not null default current_date,
  uses int not null default 0,
  primary key (owner, day)
);
alter table ai_usage enable row level security; -- no policies: only the functions below touch it

create or replace function main_coach_id() returns uuid
language sql stable security definer set search_path = public as $$
  select u.id from auth.users u join coach c on lower(c.email) = lower(u.email) order by u.created_at limit 1;
$$;

create or replace function ai_limits() returns jsonb
language sql immutable as $$
  select jsonb_build_object('per_account', 15, 'all_guests', 250);
$$;

-- The AI helper (Edge Function) calls this before every AI request. It used to mean "is this the coach";
-- now it means "may this account use AI right now", and it counts the use.
create or replace function is_coach() returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); used int; total int;
begin
  if me is null then return false; end if;
  if me = main_coach_id() then return true; end if;
  select coalesce(sum(uses), 0) into total from ai_usage where day = current_date and owner <> coalesce(main_coach_id(), '00000000-0000-0000-0000-000000000000'::uuid);
  select coalesce(uses, 0) into used from ai_usage where owner = me and day = current_date;
  if coalesce(used, 0) >= (ai_limits() ->> 'per_account')::int or total >= (ai_limits() ->> 'all_guests')::int then
    return false;
  end if;
  insert into ai_usage (owner, day, uses) values (me, current_date, 1)
  on conflict (owner, day) do update set uses = ai_usage.uses + 1;
  return true;
end;
$$;

-- What the app asks when someone signs in: is this the original coach, and how many AI uses are left today.
create or replace function my_account() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', auth.uid(),
    'main', auth.uid() is not null and auth.uid() = main_coach_id(),
    'ai_left', case when auth.uid() = main_coach_id() then null else greatest(0,
      (ai_limits() ->> 'per_account')::int - coalesce((select uses from ai_usage where owner = auth.uid() and day = current_date), 0)) end
  );
$$;

-- 5. Booking pages. With no coach given, it's the original coach's page, so the link parents already have keeps working.
drop function if exists get_booking_page();
create or replace function get_booking_page(p_coach uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (select coalesce(p_coach, main_coach_id()) as id),
  st as (select r.data from records r, c where r.owner = c.id and r.collection = 'settings' and r.id = 'main')
  select jsonb_build_object(
    'coach', coalesce((select data ->> 'coach' from st), ''),
    'business', coalesce((select data ->> 'business' from st), ''),
    -- Only whether Venmo / Zelle are set up. The usernames go in the confirmation text, not on the public page.
    'venmo', coalesce((select coalesce(data ->> 'venmo', '') <> '' from st), false),
    'zelle', coalesce((select coalesce(data ->> 'zelle', '') <> '' from st), false),
    'prices', coalesce((select left(data ->> 'prices', 1500) from st), ''),
    'about', coalesce((select left(data ->> 'about', 2000) from st), ''),
    'main', (select id from c) = main_coach_id(),
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'date', s.date, 'time', s.time, 'length', s.length) order by s.date, s.time)
      from slots s, c
      where s.owner = c.id and s.status = 'open' and s.date >= current_date - 1 and s.date <= current_date + 60
    ), '[]'::jsonb)
  );
$$;

-- A parent asks for one open time. The request goes to whichever coach owns that time.
create or replace function request_booking(
  p_slot uuid, p_parent text, p_phone text, p_email text, p_child text, p_age text, p_note text, p_location text default ''
) returns text
language plpgsql security definer set search_path = public as $$
declare s slots%rowtype;
begin
  if coalesce(trim(p_parent), '') = '' or coalesce(trim(p_child), '') = '' or coalesce(trim(p_phone), '') = '' then
    raise exception 'missing_fields';
  end if;
  if length(p_parent) > 100 or length(p_child) > 100 or length(p_phone) > 30 or length(coalesce(p_email, '')) > 200
     or length(coalesce(p_age, '')) > 20 or length(coalesce(p_note, '')) > 1000 or length(coalesce(p_location, '')) > 200 then
    raise exception 'too_long';
  end if;
  if (select count(*) from booking_requests where status = 'pending' and regexp_replace(phone, '\D', '', 'g') = regexp_replace(p_phone, '\D', '', 'g')) >= 10 then
    raise exception 'too_many';
  end if;
  update slots set status = 'held' where id = p_slot and status = 'open' and date >= current_date - 1 returning * into s;
  if not found then
    raise exception 'taken';
  end if;
  insert into booking_requests (owner, slot_id, slot_date, slot_time, slot_length, parent_name, phone, email, child_name, child_age, note, location)
  values (s.owner, s.id, s.date, s.time, s.length, trim(p_parent), trim(p_phone), trim(coalesce(p_email, '')), trim(p_child), trim(coalesce(p_age, '')), trim(coalesce(p_note, '')), trim(coalesce(p_location, '')));
  return 'ok';
end;
$$;

revoke all on function main_coach_id() from public;
revoke all on function is_coach() from public;
revoke all on function my_account() from public;
revoke all on function get_booking_page(uuid) from public;
revoke all on function request_booking(uuid, text, text, text, text, text, text, text) from public;
grant execute on function is_coach() to authenticated;
grant execute on function my_account() to authenticated;
grant execute on function get_booking_page(uuid) to anon, authenticated;
grant execute on function request_booking(uuid, text, text, text, text, text, text, text) to anon, authenticated;
