-- Dear DJ: add Mixtapes to an EXISTING project.
-- Only needed if you ran schema.sql before Mixtapes existed (fresh installs already have it).
-- Paste into Supabase > SQL Editor > New query > Run. Run it once.

begin;

-- Mixtapes: playlists people are proud of, shared on their own (not answering a request).
create function public.valid_tags(t text[]) returns boolean
language sql immutable as $$
  select cardinality(t) <= 5 and not exists (
    select 1 from unnest(t) x
    where x is null or x <> lower(trim(x)) or char_length(x) not between 1 and 24 or x like '%,%')
$$;

create table public.mixtapes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  spotify_id  text not null check (spotify_id ~ '^[A-Za-z0-9]{22}$'),
  title       text not null check (char_length(title) between 3 and 80),
  description text check (char_length(description) <= 500),
  tags        text[] not null default '{}' check (public.valid_tags(tags)),
  status      text not null default 'visible' check (status in ('visible','hidden')),
  created_at  timestamptz not null default now(),
  unique (user_id, spotify_id)
);

create index on public.mixtapes (created_at desc);
create index on public.mixtapes using gin (tags);

alter table public.reports drop constraint reports_target_type_check;
alter table public.reports add constraint reports_target_type_check
  check (target_type in ('request','playlist','comment','mixtape'));

-- Updated helpers that now know about mixtapes
create or replace function public.check_blocked_terms() returns trigger
language plpgsql security definer set search_path = public as $$
declare txt text;
begin
  if tg_table_name = 'requests' then
    txt := lower(concat_ws(' ', new.title, new.mood, new.notes,
                           new.top_songs::text, new.top_artists::text));
  elsif tg_table_name = 'comments' then
    txt := lower(new.body);
  elsif tg_table_name = 'mixtapes' then
    txt := lower(concat_ws(' ', new.title, new.description, array_to_string(new.tags, ' ')));
  else
    txt := lower(coalesce(new.note, ''));
  end if;

  if exists (select 1 from public.blocked_terms where position(term in txt) > 0) then
    raise exception 'That text includes a word that isn’t allowed here.';
  end if;
  return new;
end $$;

create or replace function public.enforce_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int; lim int;
begin
  if tg_table_name = 'requests' then
    lim := 3;
    select count(*) into n from public.requests
      where user_id = new.user_id and created_at > now() - interval '1 day';
  elsif tg_table_name = 'playlists' then
    lim := 15;
    select count(*) into n from public.playlists
      where user_id = new.user_id and created_at > now() - interval '1 day';
  elsif tg_table_name = 'comments' then
    lim := 30;
    select count(*) into n from public.comments
      where user_id = new.user_id and created_at > now() - interval '1 day';
  elsif tg_table_name = 'mixtapes' then
    lim := 5;
    select count(*) into n from public.mixtapes
      where user_id = new.user_id and created_at > now() - interval '1 day';
  else
    lim := 20;
    select count(*) into n from public.reports
      where reporter_id = new.reporter_id and created_at > now() - interval '1 day';
  end if;

  if n >= lim then
    raise exception 'Daily limit reached (% per day). Try again tomorrow.', lim;
  end if;
  return new;
end $$;

create or replace function public.auto_hide_reported() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  select count(distinct reporter_id) into n from public.reports
    where target_type = new.target_type and target_id = new.target_id and not resolved;

  if n >= 3 then
    if new.target_type = 'request' then
      update public.requests set status = 'hidden' where id = new.target_id;
    elsif new.target_type = 'playlist' then
      update public.playlists set status = 'hidden' where id = new.target_id;
    elsif new.target_type = 'mixtape' then
      update public.mixtapes set status = 'hidden' where id = new.target_id;
    else
      update public.comments set status = 'hidden' where id = new.target_id;
    end if;
  end if;
  return new;
end $$;

create or replace function public.admin_moderate(p_report_id uuid, p_action text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.reports%rowtype; author uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_action not in ('hide','ban','dismiss') then raise exception 'Unknown action.'; end if;

  select * into r from public.reports where id = p_report_id;
  if not found then raise exception 'Report not found.'; end if;

  if p_action in ('hide','ban') then
    if r.target_type = 'request' then
      update public.requests set status = 'hidden' where id = r.target_id returning user_id into author;
    elsif r.target_type = 'playlist' then
      update public.playlists set status = 'hidden' where id = r.target_id returning user_id into author;
    elsif r.target_type = 'mixtape' then
      update public.mixtapes set status = 'hidden' where id = r.target_id returning user_id into author;
    else
      update public.comments set status = 'hidden' where id = r.target_id returning user_id into author;
    end if;
    if p_action = 'ban' and author is not null then
      update public.profiles set is_banned = true where id = author;
    end if;
  else
    if r.target_type = 'request' then
      update public.requests set status = 'open' where id = r.target_id and status = 'hidden';
    elsif r.target_type = 'playlist' then
      update public.playlists set status = 'visible' where id = r.target_id and status = 'hidden';
    elsif r.target_type = 'mixtape' then
      update public.mixtapes set status = 'visible' where id = r.target_id and status = 'hidden';
    else
      update public.comments set status = 'visible' where id = r.target_id and status = 'hidden';
    end if;
  end if;

  update public.reports set resolved = true
    where target_type = r.target_type and target_id = r.target_id;
end $$;

create trigger mixtapes_text_filter before insert on public.mixtapes
  for each row execute function public.check_blocked_terms();
create trigger mixtapes_rate_limit  before insert on public.mixtapes
  for each row execute function public.enforce_rate_limit();

alter table public.mixtapes enable row level security;
create policy "read mixtapes" on public.mixtapes
  for select using (status = 'visible' or user_id = auth.uid() or public.is_admin());
create policy "share a mixtape" on public.mixtapes
  for insert with check (user_id = auth.uid() and not public.is_banned() and status = 'visible');
create policy "delete own mixtape" on public.mixtapes
  for delete using (user_id = auth.uid() or public.is_admin());

revoke all on public.mixtapes from anon, authenticated;
grant select on public.mixtapes to anon, authenticated;
grant insert, delete on public.mixtapes to authenticated;

commit;
