create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text not null default 'Rider' check (char_length(display_name) between 1 and 40),
  team_name text not null default '' check (char_length(team_name) <= 60),
  bio text not null default '' check (char_length(bio) <= 240),
  role text not null default 'rider' check (role in ('rider','admin')),
  championship_points integer not null default 0,
  wins integer not null default 0,
  races_entered integer not null default 0,
  rating integer not null default 1000,
  ranked_races integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.races (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 100),
  race_date date not null,
  track text not null default '' check (char_length(track) <= 100),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.race_results (
  race_id uuid not null references public.races(id) on delete cascade,
  rider_id uuid not null references public.profiles(id),
  position integer not null check (position > 0),
  championship_points integer not null default 0 check (championship_points >= 0),
  rating_change integer not null default 0,
  primary key (race_id, rider_id),
  unique (race_id, position)
);

create index if not exists race_results_rider_idx on public.race_results(rider_id);
create index if not exists races_order_idx on public.races(race_date, created_at);

create or replace function public.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles(id,email,display_name)
  values(new.id,coalesce(new.email,''),coalesce(nullif(new.raw_user_meta_data->>'display_name',''),split_part(coalesce(new.email,'rider'),'@',1)))
  on conflict(id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_motogrid on auth.users;
create trigger on_auth_user_created_motogrid after insert on auth.users
for each row execute procedure public.create_profile_for_new_user();

alter table public.profiles enable row level security;
alter table public.races enable row level security;
alter table public.race_results enable row level security;

drop policy if exists "profiles visible to signed-in riders" on public.profiles;
create policy "profiles visible to signed-in riders" on public.profiles
for select to authenticated using (true);

drop policy if exists "riders can create their own profile" on public.profiles;
create policy "riders can create their own profile" on public.profiles
for insert to authenticated with check (auth.uid() = id and role = 'rider');

drop policy if exists "riders can edit their own profile" on public.profiles;
create policy "riders can edit their own profile" on public.profiles
for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "races visible to signed-in riders" on public.races;
create policy "races visible to signed-in riders" on public.races
for select to authenticated using (true);

drop policy if exists "results visible to signed-in riders" on public.race_results;
create policy "results visible to signed-in riders" on public.race_results
for select to authenticated using (true);

-- Lock sensitive profile fields against client-side edits. Only the trusted
-- SECURITY DEFINER result function can update scores, ratings, or role.
revoke all on public.profiles from anon, authenticated;
grant select (id,display_name,team_name,bio,role,championship_points,wins,races_entered,rating,ranked_races,created_at) on public.profiles to authenticated;
grant insert (id,email,display_name,team_name,bio) on public.profiles to authenticated;
grant update (display_name,team_name,bio) on public.profiles to authenticated;

revoke all on public.races from anon, authenticated;
grant select on public.races to authenticated;
revoke all on public.race_results from anon, authenticated;
grant select on public.race_results to authenticated;

create or replace function public.admin_publish_race(
  p_name text,
  p_race_date date,
  p_track text,
  p_finisher_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean;
  v_race_id uuid;
  v_rider uuid;
  v_opponent uuid;
  v_pos integer;
  v_opp_pos integer;
  v_rating numeric;
  v_opp_rating numeric;
  v_expected numeric;
  v_actual numeric;
  v_delta integer;
  v_event record;
  v_result record;
  v_points integer;
begin
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin') into v_admin;
  if not v_admin then raise exception 'Only league administrators can publish race results.' using errcode = '42501'; end if;
  if p_name is null or char_length(trim(p_name)) not between 1 and 100 then raise exception 'Enter a valid event name.'; end if;
  if p_race_date is null then raise exception 'Race date is required.'; end if;
  if p_track is null then p_track := ''; end if;
  if coalesce(array_length(p_finisher_ids,1),0) < 2 then raise exception 'At least two finishers are required.'; end if;
  if (select count(distinct x) from unnest(p_finisher_ids) x) <> array_length(p_finisher_ids,1) then raise exception 'A rider can only appear once in a finishing order.'; end if;
  if exists(select 1 from unnest(p_finisher_ids) x left join public.profiles p on p.id=x where p.id is null) then raise exception 'Every finisher must be a registered rider.'; end if;

  select id into v_race_id from public.races
  where lower(name)=lower(trim(p_name)) and race_date=p_race_date and track=trim(p_track)
  order by created_at desc limit 1;
  if v_race_id is null then
    insert into public.races(name,race_date,track,created_by)
    values(trim(p_name),p_race_date,trim(p_track),auth.uid()) returning id into v_race_id;
  else
    update public.races set name=trim(p_name),track=trim(p_track),created_by=auth.uid() where id=v_race_id;
    delete from public.race_results where race_id=v_race_id;
  end if;

  for v_rider, v_pos in
    select x, ord::integer from unnest(p_finisher_ids) with ordinality as u(x,ord)
  loop
    v_points := case when v_pos <= 20 then (array[25,22,20,18,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1])[v_pos] else 0 end;
    insert into public.race_results(race_id,rider_id,position,championship_points)
    values(v_race_id,v_rider,v_pos,v_points);
  end loop;

  -- Ratings are replayed chronologically from a 1000 baseline on every publish.
  -- This makes correcting an event deterministic instead of compounding changes.
  create temporary table if not exists mg_rating_work(
    rider_id uuid primary key, rating numeric not null, ranked_races integer not null default 0
  ) on commit drop;
  create temporary table if not exists mg_rating_changes(
    rider_id uuid primary key, delta integer not null
  ) on commit drop;
  truncate table pg_temp.mg_rating_work;
  truncate table pg_temp.mg_rating_changes;
  insert into pg_temp.mg_rating_work(rider_id,rating,ranked_races)
  select id,1000,0 from public.profiles;

  for v_event in select id from public.races order by race_date,created_at,id loop
    truncate table pg_temp.mg_rating_changes;
    for v_result in select rider_id,position from public.race_results where race_id=v_event.id order by position loop
      select rating into v_rating from pg_temp.mg_rating_work where rider_id=v_result.rider_id;
      v_delta := 0;
      for v_opponent, v_opp_pos in select rider_id,position from public.race_results where race_id=v_event.id and rider_id<>v_result.rider_id loop
        select rating into v_opp_rating from pg_temp.mg_rating_work where rider_id=v_opponent;
        v_expected := 1.0/(1.0+power(10.0,(v_opp_rating-v_rating)/400.0));
        v_actual := case when v_result.position < v_opp_pos then 1.0 else 0.0 end;
        v_delta := v_delta + round(32.0*(v_actual-v_expected))::integer;
      end loop;
      insert into pg_temp.mg_rating_changes(rider_id,delta) values(v_result.rider_id,v_delta)
      on conflict(rider_id) do update set delta=excluded.delta;
    end loop;
    update pg_temp.mg_rating_work w set rating=greatest(100,least(4000,w.rating+c.delta)),ranked_races=w.ranked_races+1
    from pg_temp.mg_rating_changes c where c.rider_id=w.rider_id;
    update public.race_results rr set rating_change=c.delta
    from pg_temp.mg_rating_changes c where rr.race_id=v_event.id and rr.rider_id=c.rider_id;
  end loop;

  update public.profiles p set
    championship_points=coalesce(a.points,0),
    wins=coalesce(a.wins,0),
    races_entered=coalesce(a.races,0),
    rating=coalesce(round(w.rating)::integer,1000),
    ranked_races=coalesce(w.ranked_races,0)
  from pg_temp.mg_rating_work w
  left join (
    select rider_id,sum(championship_points)::integer points,
      count(*) filter(where position=1)::integer wins,count(*)::integer races
    from public.race_results group by rider_id
  ) a on a.rider_id=w.rider_id
  where p.id=w.rider_id;

  return v_race_id;
end;
$$;

revoke all on function public.admin_publish_race(text,date,text,uuid[]) from public, anon;
grant execute on function public.admin_publish_race(text,date,text,uuid[]) to authenticated;
