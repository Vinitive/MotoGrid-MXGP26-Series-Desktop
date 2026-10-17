-- Run this migration in the separate MotoGrid MXGP 26 Series Supabase project's SQL Editor.
create table if not exists public.official_teams (
 id uuid primary key default gen_random_uuid(),
 name text not null check (char_length(trim(name)) between 1 and 60),
 created_at timestamptz not null default now()
);
create unique index if not exists official_teams_name_ci_idx
 on public.official_teams (lower(name));

alter table public.official_teams enable row level security;
drop policy if exists "official teams visible to signed-in riders" on public.official_teams;
create policy "official teams visible to signed-in riders"
 on public.official_teams for select to authenticated using (true);
revoke all on public.official_teams from anon, authenticated;
grant select on public.official_teams to authenticated;

create or replace function public.admin_create_official_team(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
 v_id uuid;
 v_name text := trim(coalesce(p_name, ''));
begin
 if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
  raise exception 'Only league administrators can manage official teams.' using errcode = '42501';
 end if;
 if char_length(v_name) not between 1 and 60 then
  raise exception 'Team name must be between 1 and 60 characters.';
 end if;
 insert into public.official_teams(name) values (v_name) returning id into v_id;
 return v_id;
exception when unique_violation then
 raise exception 'An official team with that name already exists.';
end;
$$;

create or replace function public.admin_delete_official_team(p_team_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_name text;
begin
 if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
  raise exception 'Only league administrators can manage official teams.' using errcode = '42501';
 end if;
 select name into v_name from public.official_teams where id = p_team_id;
 if v_name is null then raise exception 'Official team not found.'; end if;
 update public.profiles set team_name = '' where team_name = v_name;
 delete from public.official_teams where id = p_team_id;
end;
$$;

revoke all on function public.admin_create_official_team(text) from public, anon;
grant execute on function public.admin_create_official_team(text) to authenticated;
revoke all on function public.admin_delete_official_team(uuid) from public, anon;
grant execute on function public.admin_delete_official_team(uuid) to authenticated;
