-- Remove Ranked rating data and retain championship standings only.
-- Does not delete rider accounts, profiles, race events, or results.
drop function if exists public.admin_publish_race(text,date,text,uuid[]);
alter table public.profiles drop column if exists rating, drop column if exists ranked_races;
alter table public.race_results drop column if exists rating_change;
create or replace function public.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_base text; v_username text;
begin
 v_base:=coalesce(nullif(trim(new.raw_user_meta_data->>'username'),''),nullif(split_part(coalesce(new.email,''),'@',1),''),'rider');
 v_username:=left(regexp_replace(lower(v_base),'[^a-z0-9_]+','_','g'),50)||'_'||substr(replace(new.id::text,'-',''),1,6);
 insert into public.profiles(id,email,username,display_name) values(new.id,coalesce(new.email,''),v_username,coalesce(nullif(left(trim(new.raw_user_meta_data->>'display_name'),40),''),nullif(left(v_base,40),''),'Rider')) on conflict(id) do nothing;
 return new;
end;
$$;
drop trigger if exists on_auth_user_created_motogrid on auth.users;
create trigger on_auth_user_created_motogrid after insert on auth.users for each row execute function public.create_profile_for_new_user();
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
 from (select base.id,coalesce(sr.points,0) points,coalesce(sr.wins,0) wins,coalesce(sr.races,0) races from public.profiles base left join (select rider_id,sum(championship_points)::integer points,count(*) filter(where position=1)::integer wins,count(*)::integer races from public.race_results group by rider_id) sr on sr.rider_id=base.id) a where p.id=a.id;
 return v_race_id;
end;
$$;
revoke all on function public.admin_publish_race(text,date,text,uuid[]) from public,anon;
grant execute on function public.admin_publish_race(text,date,text,uuid[]) to authenticated;
