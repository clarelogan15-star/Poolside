-- Poolside database setup.
-- Paste this whole file into Supabase > SQL Editor and click Run.
-- BEFORE running: change the email on the last line to the email you'll sign in with.

create extension if not exists pgcrypto;

-- Who is allowed into the coach side of the app.
create table if not exists coach (
  email text primary key
);
alter table coach enable row level security;

create or replace function is_coach() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from coach where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

-- Families, swimmers, lessons, updates, plans, video feedback and settings.
create table if not exists records (
  collection text not null,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (collection, id)
);
alter table records enable row level security;
drop policy if exists coach_all on records;
create policy coach_all on records for all to authenticated using (is_coach()) with check (is_coach());

-- Open lesson times parents can request.
create table if not exists slots (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  time text not null check (time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  length int not null default 30 check (length between 10 and 120),
  status text not null default 'open' check (status in ('open', 'held', 'booked')),
  example boolean not null default false,
  created_at timestamptz not null default now()
);
alter table slots enable row level security;
drop policy if exists coach_all on slots;
create policy coach_all on slots for all to authenticated using (is_coach()) with check (is_coach());

-- Requests parents send from the booking page.
create table if not exists booking_requests (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid references slots(id) on delete set null,
  slot_date date not null,
  slot_time text not null,
  slot_length int not null default 30,
  parent_name text not null,
  phone text not null,
  email text not null default '',
  child_name text not null,
  child_age text not null default '',
  note text not null default '',
  location text not null default '',
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  lesson_id text,
  example boolean not null default false,
  created_at timestamptz not null default now()
);
alter table booking_requests add column if not exists location text not null default '';
alter table booking_requests enable row level security;
drop policy if exists coach_all on booking_requests;
create policy coach_all on booking_requests for all to authenticated using (is_coach()) with check (is_coach());

-- What the public booking page can see: names from settings and open future times. Nothing else.
create or replace function get_booking_page() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'coach', coalesce((select data ->> 'coach' from records where collection = 'settings' and id = 'main'), ''),
    'business', coalesce((select data ->> 'business' from records where collection = 'settings' and id = 'main'), ''),
    'venmo', coalesce((select left(data ->> 'venmo', 60) from records where collection = 'settings' and id = 'main'), ''),
    'zelle', coalesce((select left(data ->> 'zelle', 100) from records where collection = 'settings' and id = 'main'), ''),
    'prices', coalesce((select left(data ->> 'prices', 1500) from records where collection = 'settings' and id = 'main'), ''),
    'about', coalesce((select left(data ->> 'about', 2000) from records where collection = 'settings' and id = 'main'), ''),
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'date', s.date, 'time', s.time, 'length', s.length) order by s.date, s.time)
      from slots s
      where s.status = 'open' and s.date >= current_date - 1 and s.date <= current_date + 60
    ), '[]'::jsonb)
  );
$$;

-- A parent asks for one open time. The time is held until the coach approves or declines.
drop function if exists request_booking(uuid, text, text, text, text, text, text);
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
  insert into booking_requests (slot_id, slot_date, slot_time, slot_length, parent_name, phone, email, child_name, child_age, note, location)
  values (s.id, s.date, s.time, s.length, trim(p_parent), trim(p_phone), trim(coalesce(p_email, '')), trim(p_child), trim(coalesce(p_age, '')), trim(coalesce(p_note, '')), trim(coalesce(p_location, '')));
  return 'ok';
end;
$$;

revoke all on function get_booking_page() from public;
revoke all on function request_booking(uuid, text, text, text, text, text, text, text) from public;
revoke all on function is_coach() from public;
grant execute on function get_booking_page() to anon, authenticated;
grant execute on function request_booking(uuid, text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function is_coach() to authenticated;

-- CHANGE THIS to the email you will use to sign in to Poolside.
insert into coach (email) values ('you@example.com') on conflict do nothing;
