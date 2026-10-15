create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 email text not null default '',
 username text not null unique,
 display_name text not null default 'Rider' check(char_length(display_name) between 1 and 40),
 team_name text not null default '' check(char_length(team_name)<=60),
 platform text not null default 'Unassigned' check(platform in ('Xbox','PS5','PC','Unassigned')),
 bio text not null default '' check(char_length(bio)<=240),
 role text not null default 'rider' check(role in ('rider','admin')),
 championship_points integer not null default 0,
 wins integer not null default 0,
 races_entered integer not null default 0,
 created_at timestamptz not null default now()
);
create table if not exists public.races (
 id uuid primary key default gen_random_uuid(),
 name text not null check(char_length(name) between 1 and 100),
 race_date date not null,
 track text not null default '' check(char_length(track)<=100),
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create table if not exists public.race_results (
 race_id uuid not null references public.races(id) on delete cascade,
 rider_id uuid not null references public.profiles(id),
 position integer not null check(position>0),
 championship_points integer not null default 0 check(championship_points>=0),
 primary key(race_id,rider_id),
 unique(race_id,position)
);
create index if not exists race_results_rider_idx on public.race_results(rider_id);
create index if not exists races_order_idx on public.races(race_date,created_at);
create or replace function public.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_base text; v_username text;
begin
 v_base:=coalesce(nullif(trim(new.raw_user_meta_data->>'username'),''),nullif(split_part(coalesce(new.email,''),'@',1),''),'rider');
 v_username:=left(regexp_replace(lower(v_base),'[^a-z0-9_]+','_','g'),50)||'_'||substr(replace(new.id::text,'-',''),1,6);
 insert into public.profiles(id,email,username,display_name)
 values(new.id,coalesce(new.email,''),v_username,coalesce(nullif(left(trim(new.raw_user_meta_data->>'display_name'),40),''),nullif(left(v_base,40),''),'Rider'))
 on conflict(id) do nothing;
 return new;
end;
$$;
drop trigger if exists on_auth_user_created_motogrid on auth.users;
create trigger on_auth_user_created_motogrid after insert on auth.users for each row execute function public.create_profile_for_new_user();
alter table public.profiles enable row level security;
alter table public.races enable row level security;
alter table public.race_results enable row level security;
drop policy if exists "profiles visible to signed-in riders" on public.profiles;
create policy "profiles visible to signed-in riders" on public.profiles for select to authenticated using(true);
drop policy if exists "riders can create their own profile" on public.profiles;
create policy "riders can create their own profile" on public.profiles for insert to authenticated with check(auth.uid()=id and role='rider');
drop policy if exists "riders can edit their own profile" on public.profiles;
create policy "riders can edit their own profile" on public.profiles for update to authenticated using(auth.uid()=id) with check(auth.uid()=id);
drop policy if exists "races visible to signed-in riders" on public.races;
create policy "races visible to signed-in riders" on public.races for select to authenticated using(true);
drop policy if exists "results visible to signed-in riders" on public.race_results;
create policy "results visible to signed-in riders" on public.race_results for select to authenticated using(true);
revoke all on public.profiles from anon,authenticated;
grant select(id,email,username,display_name,team_name,bio,platform,role,championship_points,wins,races_entered,created_at) on public.profiles to authenticated;
grant insert(id,email,username,display_name,team_name,bio,platform) on public.profiles to authenticated;
grant update(display_name,team_name,bio,platform) on public.profiles to authenticated;
revoke all on public.races from anon,authenticated;
grant select on public.races to authenticated;
revoke all on public.race_results from anon,authenticated;
grant select on public.race_results to authenticated;
create or replace function public.admin_publish_race(p_name text,p_race_date date,p_track text,p_finisher_ids uuid[])
returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_admin boolean; v_race_id uuid; v_rider uuid; v_pos integer; v_points integer;
begin
 select exists(select 1 from public.profiles where id=auth.uid() and role='admin') into v_admin;
 if not v_admin then raise exception 'Only league administrators can publish race results.' using errcode='42501'; end if;
 if p_name is null or char_length(trim(p_name)) not between 1 and 100 then raise exception 'Enter a valid event name.'; end if;
 if p_race_date is null then raise exception 'Race date is required.'; end if;
 p_track:=coalesce(trim(p_track),'');
 if coalesce(array_length(p_finisher_ids,1),0)<2 then raise exception 'At least two finishers are required.'; end if;
 if (select count(distinct x) from unnest(p_finisher_ids) as u(x))<>array_length(p_finisher_ids,1) then raise exception 'A rider can only appear once in a finishing order.'; end if;
 if exists(select 1 from unnest(p_finisher_ids) as u(x) left join public.profiles p on p.id=u.x where p.id is null) then raise exception 'Every finisher must be a registered rider.'; end if;
 select id into v_race_id from public.races where lower(name)=lower(trim(p_name)) and race_date=p_race_date and track=p_track order by created_at desc limit 1;
 if v_race_id is null then insert into public.races(name,race_date,track,created_by) values(trim(p_name),p_race_date,p_track,auth.uid()) returning id into v_race_id;
 else update public.races set name=trim(p_name),track=p_track,created_by=auth.uid() where id=v_race_id; delete from public.race_results where race_id=v_race_id; end if;
 for v_rider,v_pos in select x,ord::integer from unnest(p_finisher_ids) with ordinality as u(x,ord) loop
  v_points:=case when v_pos<=20 then (array[25,22,20,18,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1])[v_pos] else 0 end;
  insert into public.race_results(race_id,rider_id,position,championship_points) values(v_race_id,v_rider,v_pos,v_points);
 end loop;
 update public.profiles p set championship_points=coalesce(a.points,0),wins=coalesce(a.wins,0),races_entered=coalesce(a.races,0)
 from (select base.id,coalesce(sr.points,0) points,coalesce(sr.wins,0) wins,coalesce(sr.races,0) races from public.profiles base left join
 (select rider_id,sum(championship_points)::integer points,count(*) filter(where position=1)::integer wins,count(*)::integer races from public.race_results group by rider_id) sr on sr.rider_id=base.id) a
 where p.id=a.id;
 return v_race_id;
end;
$$;
revoke all on function public.admin_publish_race(text,date,text,uuid[]) from public,anon;
grant execute on function public.admin_publish_race(text,date,text,uuid[]) to authenticated;


-- MotoGrid MXGP 26 Series: qualifying leaderboards and race-host details.
-- Apply in the separate MXGP 26 Series Supabase project after the earlier schema/migrations.
create table if not exists public.qualifying_results (
 id uuid primary key default gen_random_uuid(),
 round_name text not null check(char_length(round_name) between 1 and 100),
 race_date date not null,
 platform text not null check(platform in ('Xbox','PS5','PC')),
 rider_id uuid not null references public.profiles(id) on delete cascade,
 position integer not null check(position>0),
 qualifying_time text not null default '' check(char_length(qualifying_time)<=32),
 created_at timestamptz not null default now(),
 unique(round_name,platform,rider_id),
 unique(round_name,platform,position)
);
create index if not exists qualifying_results_board_idx on public.qualifying_results(platform,race_date,position);
create table if not exists public.race_hosts (
 id uuid primary key default gen_random_uuid(),
 round_name text not null check(char_length(round_name) between 1 and 100),
 race_date date not null,
 platform text not null check(platform in ('Xbox','PS5','PC')),
 host_name text not null check(char_length(host_name) between 1 and 80),
 room_name text not null check(char_length(room_name) between 1 and 100),
 room_password text not null default '' check(char_length(room_password)<=100),
 updated_at timestamptz not null default now(),
 unique(round_name,platform)
);
alter table public.qualifying_results enable row level security;
alter table public.race_hosts enable row level security;
drop policy if exists "qualifying visible to signed-in riders" on public.qualifying_results;
create policy "qualifying visible to signed-in riders" on public.qualifying_results for select to authenticated using(true);
drop policy if exists "race hosts visible to signed-in riders" on public.race_hosts;
create policy "race hosts visible to signed-in riders" on public.race_hosts for select to authenticated using(true);
revoke all on public.qualifying_results from anon,authenticated;
grant select on public.qualifying_results to authenticated;
revoke all on public.race_hosts from anon,authenticated;
grant select on public.race_hosts to authenticated;
create or replace function public.admin_publish_qualifying(p_round_name text,p_race_date date,p_platform text,p_rider_ids uuid[],p_times text[])
returns integer language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_count integer; v_rider uuid; v_pos integer; v_time text; v_admin boolean;
begin
 select exists(select 1 from public.profiles where id=auth.uid() and role='admin') into v_admin;
 if not v_admin then raise exception 'Only league administrators can publish qualifying.' using errcode='42501'; end if;
 if p_round_name is null or char_length(trim(p_round_name)) not between 1 and 100 or p_race_date is null then raise exception 'Select a valid scheduled round.'; end if;
 if p_platform not in ('Xbox','PS5','PC') then raise exception 'Select a valid platform.'; end if;
 if coalesce(array_length(p_rider_ids,1),0)<1 then raise exception 'Add at least one qualifying rider.'; end if;
 if (select count(distinct x) from unnest(p_rider_ids) as u(x))<>array_length(p_rider_ids,1) then raise exception 'A rider can only appear once.'; end if;
 if coalesce(array_length(p_times,1),0)<>array_length(p_rider_ids,1) then raise exception 'Qualifying time entries do not match riders.'; end if;
 if exists(select 1 from unnest(p_rider_ids) as u(x) left join public.profiles p on p.id=u.x where p.id is null or p.platform<>p_platform) then raise exception 'Every qualifying rider must be registered on the selected platform.'; end if;
 delete from public.qualifying_results where round_name=trim(p_round_name) and platform=p_platform;
 for v_rider,v_pos in select x,ord::integer from unnest(p_rider_ids) with ordinality as u(x,ord) loop
  v_time:=coalesce(p_times[v_pos],'');
  insert into public.qualifying_results(round_name,race_date,platform,rider_id,position,qualifying_time)
  values(trim(p_round_name),p_race_date,p_platform,v_rider,v_pos,trim(v_time));
 end loop;
 return array_length(p_rider_ids,1);
end;
$$;
revoke all on function public.admin_publish_qualifying(text,date,text,uuid[],text[]) from public,anon;
grant execute on function public.admin_publish_qualifying(text,date,text,uuid[],text[]) to authenticated;
create or replace function public.admin_save_race_host(p_round_name text,p_race_date date,p_platform text,p_host_name text,p_room_name text,p_room_password text)
returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_id uuid; v_admin boolean;
begin
 select exists(select 1 from public.profiles where id=auth.uid() and role='admin') into v_admin;
 if not v_admin then raise exception 'Only league administrators can manage race hosts.' using errcode='42501'; end if;
 if p_round_name is null or char_length(trim(p_round_name)) not between 1 and 100 or p_race_date is null then raise exception 'Select a valid scheduled round.'; end if;
 if p_platform not in ('Xbox','PS5','PC') then raise exception 'Select a valid platform.'; end if;
 if p_host_name is null or char_length(trim(p_host_name)) not between 1 and 80 then raise exception 'Enter a host name or gamertag.'; end if;
 if p_room_name is null or char_length(trim(p_room_name)) not between 1 and 100 then raise exception 'Enter the lobby room name.'; end if;
 insert into public.race_hosts(round_name,race_date,platform,host_name,room_name,room_password,updated_at)
 values(trim(p_round_name),p_race_date,p_platform,trim(p_host_name),trim(p_room_name),coalesce(trim(p_room_password),''),now())
 on conflict(round_name,platform) do update set race_date=excluded.race_date,host_name=excluded.host_name,room_name=excluded.room_name,room_password=excluded.room_password,updated_at=now()
 returning id into v_id;
 return v_id;
end;
$$;
revoke all on function public.admin_save_race_host(text,date,text,text,text,text) from public,anon;
grant execute on function public.admin_save_race_host(text,date,text,text,text,text) to authenticated;
