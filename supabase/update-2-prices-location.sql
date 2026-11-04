-- Update 2 (Nov 2026): prices, Venmo/Zelle and lesson location on the booking page.
-- Safe to run more than once. Copy all of this into Supabase > SQL Editor > New snippet and click Run.
alter table booking_requests add column if not exists location text not null default '';

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
grant execute on function get_booking_page() to anon, authenticated;
grant execute on function request_booking(uuid, text, text, text, text, text, text, text) to anon, authenticated;
