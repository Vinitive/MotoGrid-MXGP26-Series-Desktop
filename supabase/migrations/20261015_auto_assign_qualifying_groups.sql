-- Automatically place new accounts into the first qualifying group with room.
-- Each platform group has a hard capacity of 10 riders. If every existing group is full,
-- create the next group for that platform automatically.
create index if not exists profiles_qualifying_group_id_idx
 on public.profiles(qualifying_group_id);

create or replace function public.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
 v_base text;
 v_username text;
 v_platform text;
 v_group_id uuid;
 v_group_count integer;
 v_group_name text;
begin
 v_base := coalesce(nullif(trim(new.raw_user_meta_data->>'username'),''),nullif(split_part(coalesce(new.email,''),'@',1),''),'rider');
 v_username := left(regexp_replace(lower(v_base),'[^a-z0-9_]+','_','g'),50)||'_'||substr(replace(new.id::text,'-',''),1,6);
 v_platform := coalesce(new.raw_user_meta_data->>'platform','PC');
 if v_platform not in ('Xbox','PS5','PC') then v_platform := 'PC'; end if;

 -- Serialize signups per platform so simultaneous signups cannot overfill a group.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('motogrid_group_assignment'),pg_catalog.hashtext(v_platform));

 select g.id into v_group_id
 from public.qualifying_groups g
 where g.platform=v_platform
   and (select count(*) from public.profiles p where p.qualifying_group_id=g.id)<10
 order by g.created_at,g.name
 limit 1;

 if v_group_id is null then
   select count(*)::integer into v_group_count from public.qualifying_groups where platform=v_platform;
   v_group_count := v_group_count + 1;
   loop
     if v_group_count<=26 then
       v_group_name := 'Group '||chr(64+v_group_count);
     else
       v_group_name := 'Group '||v_group_count::text;
     end if;
     exit when not exists(
       select 1 from public.qualifying_groups g
       where g.platform=v_platform and g.name=v_group_name
     );
     v_group_count := v_group_count + 1;
   end loop;
   insert into public.qualifying_groups(platform,name) values(v_platform,v_group_name)
   returning id into v_group_id;
 end if;

 insert into public.profiles(id,email,username,display_name,platform,qualifying_group_id)
 values(new.id,coalesce(new.email,''),v_username,
   coalesce(nullif(left(trim(new.raw_user_meta_data->>'display_name'),40),''),nullif(left(v_base,40),''),'Rider'),
   v_platform,v_group_id)
 on conflict(id) do nothing;
 return new;
end;
$$;
