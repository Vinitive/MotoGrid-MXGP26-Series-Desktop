-- Add standalone points to each published qualifying race.
-- Apply this migration in the separate MXGP 26 Series Supabase project.
alter table public.qualifying_results
  add column if not exists points integer not null default 0 check (points >= 0);

create or replace function public.admin_publish_qualifying(
  p_round_name text,
  p_race_date date,
  p_platform text,
  p_rider_ids uuid[],
  p_times text[]
)
returns integer
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_count integer;
  v_rider uuid;
  v_pos integer;
  v_time text;
  v_admin boolean;
begin
  select exists(
    select 1 from public.profiles
    where id=auth.uid() and role='admin'
  ) into v_admin;

  if not v_admin then
    raise exception 'Only league administrators can publish qualifying.' using errcode='42501';
  end if;
  if p_round_name is null or char_length(trim(p_round_name)) not between 1 and 100 or p_race_date is null then
    raise exception 'Select a valid scheduled round.';
  end if;
  if p_platform not in ('Xbox','PS5','PC') then
    raise exception 'Select a valid platform.';
  end if;
  if coalesce(array_length(p_rider_ids,1),0)<1 then
    raise exception 'Add at least one qualifying rider.';
  end if;
  if (select count(distinct x) from unnest(p_rider_ids) as u(x))<>array_length(p_rider_ids,1) then
    raise exception 'A rider can only appear once.';
  end if;
  if coalesce(array_length(p_times,1),0)<>array_length(p_rider_ids,1) then
    raise exception 'Qualifying time entries do not match riders.';
  end if;
  if exists(
    select 1 from unnest(p_rider_ids) as u(x)
    left join public.profiles p on p.id=u.x
    where p.id is null or p.platform<>p_platform
  ) then
    raise exception 'Every qualifying rider must be registered on the selected platform.';
  end if;

  delete from public.qualifying_results
  where round_name=trim(p_round_name) and platform=p_platform;

  for v_rider,v_pos in
    select x,ord::integer
    from unnest(p_rider_ids) with ordinality as u(x,ord)
  loop
    v_time:=coalesce(p_times[v_pos],'');
    insert into public.qualifying_results(
      round_name,race_date,platform,rider_id,position,qualifying_time,points
    )
    values(
      trim(p_round_name),p_race_date,p_platform,v_rider,v_pos,trim(v_time),greatest(11-v_pos,0)
    );
  end loop;

  return array_length(p_rider_ids,1);
end;
$$;

revoke all on function public.admin_publish_qualifying(text,date,text,uuid[],text[]) from public,anon;
grant execute on function public.admin_publish_qualifying(text,date,text,uuid[],text[]) to authenticated;
