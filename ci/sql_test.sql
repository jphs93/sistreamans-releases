\set ON_ERROR_STOP on
-- Nabootsing van Supabase: auth-schema, extensions, rollen.
create schema if not exists auth;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create table auth.users (id uuid primary key default gen_random_uuid(), raw_user_meta_data jsonb);
create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create role authenticated;
grant usage on schema public, extensions, auth to authenticated;

\i code/supabase/schema.sql
\i code/supabase/social.sql
-- Nog een keer: moet veilig herhaalbaar zijn.
\i code/supabase/schema.sql
\i code/supabase/social.sql

grant all on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

-- Account 1 met de startcode, account 2 met een code van account 1.
insert into auth.users (id, raw_user_meta_data) values ('00000000-0000-0000-0000-000000000001', '{"invite":"start-jeffrey"}');
select 'admin ok' where exists (select 1 from app_admins where user_id = '00000000-0000-0000-0000-000000000001');

do $$ begin
  begin
    insert into auth.users (id, raw_user_meta_data) values ('00000000-0000-0000-0000-000000000009', '{"invite":"FOUT"}');
    raise exception 'TEST FAALT: registreren zonder geldige code lukte';
  exception when others then
    if sqlerrm like 'TEST FAALT%' then raise; end if;
    raise notice 'zonder code geweigerd: %', sqlerrm;
  end;
  begin
    insert into auth.users (id, raw_user_meta_data) values ('00000000-0000-0000-0000-000000000008', '{"invite":"START-JEFFREY"}');
    raise exception 'TEST FAALT: startcode twee keer bruikbaar';
  exception when others then
    if sqlerrm like 'TEST FAALT%' then raise; end if;
    raise notice 'startcode tweede keer geweigerd';
  end;
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
select public.create_invite('test') as code \gset
reset role;
insert into auth.users (id, raw_user_meta_data) values ('00000000-0000-0000-0000-000000000002', jsonb_build_object('invite', :'code'));

-- Profielen
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
insert into profiles (id, name) values ('10000000-0000-0000-0000-000000000001', 'Jeffrey');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
insert into profiles (id, name) values ('20000000-0000-0000-0000-000000000002', 'Kees');
select friend_code as kees_code from profiles where id = '20000000-0000-0000-0000-000000000002' \gset
select 'kees ziet ' || count(*) || ' profiel(en)' from profiles;

-- Jeffrey stuurt verzoek, Kees accepteert.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
select public.send_friend_request('10000000-0000-0000-0000-000000000001', :'kees_code');
insert into diary (profile_id, title_key, item, rating, review)
  values ('10000000-0000-0000-0000-000000000001', 'movie:tmdb:1', '{"kind":"movie","title":"Heat"}', 4.5, 'Top');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
do $$ begin
  if (select count(*) from diary) <> 0 then raise exception 'TEST FAALT: logs zichtbaar vóór vriendschap'; end if;
end $$;
select public.accept_friend('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
do $$ begin
  if (select count(*) from diary) <> 1 then raise exception 'TEST FAALT: vriend ziet log niet'; end if;
  if (select count(*) from profiles) <> 2 then raise exception 'TEST FAALT: vriend ziet profiel niet'; end if;
end $$;
-- Kees raadt Jeffrey iets aan.
insert into recommendations (from_profile, to_profile, title_key, item, message)
  values ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'movie:tmdb:2', '{"kind":"movie","title":"Ronin"}', 'Kijken!');
-- Kees mag niet loggen op Jeffreys profiel.
do $$ begin
  begin
    insert into diary (profile_id, title_key, item) values ('10000000-0000-0000-0000-000000000001', 'x', '{}');
    raise exception 'TEST FAALT: loggen op andermans profiel lukte';
  exception when others then
    if sqlerrm like 'TEST FAALT%' then raise; end if;
  end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
do $$ begin
  if (select count(*) from recommendations where seen = false) <> 1 then raise exception 'TEST FAALT: aanrader niet ontvangen'; end if;
  if (select count(*) from watch_history) <> 0 then raise exception 'onverwacht'; end if;
end $$;
update recommendations set seen = true;
select 'ALLES GOED';
