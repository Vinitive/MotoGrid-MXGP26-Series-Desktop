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

-- Qualifying groups: admins create platform-specific groups and manually assign riders.
create table if not exists public.qualifying_groups (
 id uuid primary key default gen_random_uuid(),
 platform text not null check(platform in ('Xbox','PS5','PC')),
 name text not null check(char_length(trim(name)) between 1 and 40),
 created_at timestamptz not null default now(),
 unique(platform,name),
 unique(id,platform)
);
alter table public.profiles add column if not exists qualifying_group_id uuid references public.qualifying_groups(id) on delete set null;
alter table public.race_hosts add column if not exists qualifying_group_id uuid references public.qualifying_groups(id) on delete cascade;

insert into public.qualifying_groups(platform,name)
values ('PC','Group A'),('Xbox','Group A'),('PS5','Group A')
on conflict(platform,name) do nothing;

update public.race_hosts h set qualifying_group_id=g.id
from public.qualifying_groups g
where g.platform=h.platform and g.name='Group A' and h.qualifying_group_id is null;

alter table public.race_hosts alter column qualifying_group_id set not null;
alter table public.race_hosts drop constraint if exists race_hosts_round_name_platform_key;
alter table public.race_hosts drop constraint if exists race_hosts_round_name_qualifying_group_id_key;
alter table public.race_hosts add constraint race_hosts_round_name_qualifying_group_id_key unique(round_name,qualifying_group_id);

alter table public.qualifying_groups enable row level security;
drop policy if exists "qualifying groups visible to signed-in riders" on public.qualifying_groups;
create policy "qualifying groups visible to signed-in riders" on public.qualifying_groups for select to authenticated using(true);
revoke all on public.qualifying_groups from anon,authenticated;
grant select on public.qualifying_groups to authenticated;
grant select(qualifying_group_id) on public.profiles to authenticated;

drop policy if exists "race hosts visible to signed-in riders" on public.race_hosts;
create policy "race hosts visible to signed-in riders" on public.race_hosts for select to authenticated using (
 exists(select 1 from public.profiles p where p.id=auth.uid() and
   (p.role='admin' or p.qualifying_group_id=race_hosts.qualifying_group_id))
);

create or replace function public.admin_create_qualifying_group(p_platform text,p_name text)
returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_id uuid;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='admin') then
   raise exception 'Only league administrators can manage qualifying groups.' using errcode='42501';
 end if;
 if p_platform not in ('Xbox','PS5','PC') then raise exception 'Select a valid platform.'; end if;
 if p_name is null or char_length(trim(p_name)) not between 1 and 40 then raise exception 'Group name must be 1–40 characters.'; end if;
 insert into public.qualifying_groups(platform,name) values(p_platform,trim(p_name))
 on conflict(platform,name) do update set name=excluded.name returning id into v_id;
 return v_id;
end;
$$;
revoke all on function public.admin_create_qualifying_group(text,text) from public,anon;
grant execute on function public.admin_create_qualifying_group(text,text) to authenticated;

create or replace function public.admin_assign_rider_group(p_rider_id uuid,p_group_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_admin boolean; v_rider_platform text; v_group_platform text;
begin
 select exists(select 1 from public.profiles where id=auth.uid() and role='admin') into v_admin;
 if not v_admin then raise exception 'Only league administrators can assign qualifying groups.' using errcode='42501'; end if;
 select platform into v_rider_platform from public.profiles where id=p_rider_id;
 if not found then raise exception 'Rider account not found.'; end if;
 if p_group_id is null then
   update public.profiles set qualifying_group_id=null where id=p_rider_id;
   return;
 end if;
 select platform into v_group_platform from public.qualifying_groups where id=p_group_id;
 if not found then raise exception 'Qualifying group not found.'; end if;
 if v_rider_platform is distinct from v_group_platform then
   raise exception 'Rider platform must match the qualifying group platform.';
 end if;
 update public.profiles set qualifying_group_id=p_group_id where id=p_rider_id;
end;
$$;
revoke all on function public.admin_assign_rider_group(uuid,uuid) from public,anon;
grant execute on function public.admin_assign_rider_group(uuid,uuid) to authenticated;

drop function if exists public.admin_save_race_host(text,date,text,text,text,text);
create or replace function public.admin_save_race_host(p_round_name text,p_race_date date,p_platform text,p_qualifying_group_id uuid,p_host_name text,p_room_name text,p_room_password text)
returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_id uuid; v_group_platform text;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='admin') then
   raise exception 'Only league administrators can manage race hosts.' using errcode='42501';
 end if;
 if p_round_name is null or char_length(trim(p_round_name)) not between 1 and 100 or p_race_date is null then raise exception 'Select a valid scheduled round.'; end if;
 select platform into v_group_platform from public.qualifying_groups where id=p_qualifying_group_id;
 if not found or v_group_platform is distinct from p_platform then raise exception 'Choose a qualifying group that matches the selected platform.'; end if;
 if p_host_name is null or char_length(trim(p_host_name)) not between 1 and 80 then raise exception 'Enter a host name or gamertag.'; end if;
 if p_room_name is null or char_length(trim(p_room_name)) not between 1 and 100 then raise exception 'Enter the lobby room name.'; end if;
 insert into public.race_hosts(round_name,race_date,platform,qualifying_group_id,host_name,room_name,room_password,updated_at)
 values(trim(p_round_name),p_race_date,p_platform,p_qualifying_group_id,trim(p_host_name),trim(p_room_name),coalesce(trim(p_room_password),''),now())
 on conflict(round_name,qualifying_group_id) do update set race_date=excluded.race_date,platform=excluded.platform,host_name=excluded.host_name,room_name=excluded.room_name,room_password=excluded.room_password,updated_at=now()
 returning id into v_id;
 return v_id;
end;
$$;
revoke all on function public.admin_save_race_host(text,date,text,uuid,text,text,text) from public,anon;
grant execute on function public.admin_save_race_host(text,date,text,uuid,text,text,text) to authenticated;
