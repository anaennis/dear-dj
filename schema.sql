-- Dear DJ: database schema for Supabase
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run once on a fresh project. (Running it twice will error on "already exists".)

------------------------------------------------------------------
-- Tables
------------------------------------------------------------------

create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Anonymous'
               check (char_length(display_name) between 1 and 40 and display_name not like '%@%'),
  is_admin     boolean not null default false,
  is_banned    boolean not null default false,
  created_at   timestamptz not null default now()
);

create table public.requests (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  title       text not null check (char_length(title) between 3 and 80),
  top_songs   jsonb not null
              check (jsonb_typeof(top_songs) = 'array' and jsonb_array_length(top_songs) between 1 and 5),
  top_artists jsonb not null
              check (jsonb_typeof(top_artists) = 'array' and jsonb_array_length(top_artists) between 1 and 5),
  wants       text[] not null default '{}'
              check (wants <@ array['new_artists','new_songs','mood']),
  mood        text check (char_length(mood) <= 120),
  notes       text check (char_length(notes) <= 500),
  status      text not null default 'open' check (status in ('open','closed','hidden')),
  created_at  timestamptz not null default now()
);

create table public.playlists (
  id         uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  -- We store only the 22-character Spotify ID, never a free-form URL.
  spotify_id text not null check (spotify_id ~ '^[A-Za-z0-9]{22}$'),
  note       text check (char_length(note) <= 300),
  status     text not null default 'visible' check (status in ('visible','hidden')),
  created_at timestamptz not null default now(),
  unique (request_id, user_id)
);

-- Comments live under a playlist (not under the request itself).
create table public.comments (
  id          uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  body        text not null check (char_length(trim(body)) between 1 and 500),
  status      text not null default 'visible' check (status in ('visible','hidden')),
  created_at  timestamptz not null default now()
);

create table public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_type text not null check (target_type in ('request','playlist','comment')),
  target_id   uuid not null,
  reason      text not null check (reason in ('spam','offensive','not_a_playlist','other')),
  resolved    boolean not null default false,
  created_at  timestamptz not null default now(),
  unique (reporter_id, target_type, target_id)
);

-- Words you never want to see. Lowercase only. Edit in the Table Editor any time.
create table public.blocked_terms (
  term text primary key check (term = lower(term) and char_length(term) > 0)
);

create index on public.requests (created_at desc);
create index on public.playlists (request_id);
create index on public.comments (playlist_id, created_at);
create index on public.reports (resolved, created_at);

------------------------------------------------------------------
-- Helper functions
------------------------------------------------------------------

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

create function public.is_banned() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_banned from public.profiles where id = auth.uid()), false)
$$;

-- Create a profile automatically whenever someone signs up.
-- The public name is NEVER derived from the email address. If no usable name is
-- given (or it looks like an email), the person shows up as "Anonymous".
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  nm := left(trim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 40);
  if nm = '' or nm like '%@%' then nm := 'Anonymous'; end if;
  insert into public.profiles (id, display_name) values (new.id, nm);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

------------------------------------------------------------------
-- Spam protection: text filter
------------------------------------------------------------------

create function public.check_blocked_terms() returns trigger
language plpgsql security definer set search_path = public as $$
declare txt text;
begin
  if tg_table_name = 'requests' then
    txt := lower(concat_ws(' ', new.title, new.mood, new.notes,
                           new.top_songs::text, new.top_artists::text));
  elsif tg_table_name = 'comments' then
    txt := lower(new.body);
  else
    txt := lower(coalesce(new.note, ''));
  end if;

  if exists (select 1 from public.blocked_terms where position(term in txt) > 0) then
    raise exception 'That text includes a word that isn’t allowed here.';
  end if;
  return new;
end $$;

create trigger requests_text_filter  before insert on public.requests
  for each row execute function public.check_blocked_terms();
create trigger playlists_text_filter before insert on public.playlists
  for each row execute function public.check_blocked_terms();
create trigger comments_text_filter  before insert on public.comments
  for each row execute function public.check_blocked_terms();

------------------------------------------------------------------
-- Spam protection: daily rate limits
------------------------------------------------------------------

create function public.enforce_rate_limit() returns trigger
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

create trigger requests_rate_limit  before insert on public.requests
  for each row execute function public.enforce_rate_limit();
create trigger playlists_rate_limit before insert on public.playlists
  for each row execute function public.enforce_rate_limit();
create trigger comments_rate_limit  before insert on public.comments
  for each row execute function public.enforce_rate_limit();
create trigger reports_rate_limit   before insert on public.reports
  for each row execute function public.enforce_rate_limit();

------------------------------------------------------------------
-- Moderation: three different people report it -> hidden until admin reviews
------------------------------------------------------------------

create function public.auto_hide_reported() returns trigger
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
    else
      update public.comments set status = 'hidden' where id = new.target_id;
    end if;
  end if;
  return new;
end $$;

create trigger reports_auto_hide
  after insert on public.reports
  for each row execute function public.auto_hide_reported();

-- Admin actions, called from the Admin page.
--   hide    = hide the content, close the report
--   ban     = hide the content, ban its author, close the report
--   dismiss = put the content back (if it was auto-hidden), close the report
create function public.admin_moderate(p_report_id uuid, p_action text) returns void
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
    else
      update public.comments set status = 'visible' where id = r.target_id and status = 'hidden';
    end if;
  end if;

  update public.reports set resolved = true
    where target_type = r.target_type and target_id = r.target_id;
end $$;

------------------------------------------------------------------
-- Row-level security
------------------------------------------------------------------

alter table public.profiles      enable row level security;
alter table public.requests      enable row level security;
alter table public.playlists     enable row level security;
alter table public.comments      enable row level security;
alter table public.reports       enable row level security;
alter table public.blocked_terms enable row level security;  -- no policies = nobody but you can touch it

-- profiles: everyone can see names; you can edit only your own name
create policy "names are public" on public.profiles
  for select using (true);
create policy "edit own name" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- requests
create policy "read requests" on public.requests
  for select using (status <> 'hidden' or user_id = auth.uid() or public.is_admin());
create policy "write own request" on public.requests
  for insert with check (user_id = auth.uid() and not public.is_banned() and status = 'open');
create policy "open or close own request" on public.requests
  for update using (user_id = auth.uid() and status <> 'hidden')
  with check (user_id = auth.uid() and status in ('open','closed'));
create policy "delete own request" on public.requests
  for delete using (user_id = auth.uid() or public.is_admin());

-- playlists
create policy "read playlists" on public.playlists
  for select using (status = 'visible' or user_id = auth.uid() or public.is_admin());
create policy "send a playlist" on public.playlists
  for insert with check (
    user_id = auth.uid()
    and not public.is_banned()
    and status = 'visible'
    and exists (select 1 from public.requests r where r.id = request_id and r.status = 'open')
  );
create policy "delete own playlist" on public.playlists
  for delete using (user_id = auth.uid() or public.is_admin());

-- comments: anyone signed in can comment on a visible playlist
create policy "read comments" on public.comments
  for select using (status = 'visible' or user_id = auth.uid() or public.is_admin());
create policy "write a comment" on public.comments
  for insert with check (
    user_id = auth.uid()
    and not public.is_banned()
    and status = 'visible'
    and exists (select 1 from public.playlists p where p.id = playlist_id and p.status = 'visible')
  );
create policy "delete own comment" on public.comments
  for delete using (user_id = auth.uid() or public.is_admin());

-- reports: anyone signed in can file one, only admins can read them
create policy "file a report" on public.reports
  for insert with check (reporter_id = auth.uid() and not public.is_banned());
create policy "admins read reports" on public.reports
  for select using (public.is_admin());

------------------------------------------------------------------
-- Explicit permissions (Supabase now requires these to be spelled out)
------------------------------------------------------------------

revoke all on public.profiles, public.requests, public.playlists, public.comments,
              public.reports, public.blocked_terms from anon, authenticated;

grant usage on schema public to anon, authenticated;

-- Only the safe columns of profiles are public (is_admin / is_banned stay private).
grant select (id, display_name) on public.profiles to anon, authenticated;
grant update (display_name)     on public.profiles to authenticated;

grant select on public.requests, public.playlists to anon, authenticated;
grant insert, delete on public.requests, public.playlists to authenticated;
grant update (status) on public.requests to authenticated;

grant select on public.comments to anon, authenticated;
grant insert, delete on public.comments to authenticated;

grant select, insert on public.reports to authenticated;

revoke execute on function public.admin_moderate(uuid, text) from public, anon;
grant  execute on function public.admin_moderate(uuid, text) to authenticated;
grant  execute on function public.is_admin() to anon, authenticated;

------------------------------------------------------------------
-- Starter word filter (add your own rows later in Table Editor)
------------------------------------------------------------------
insert into public.blocked_terms (term) values
  ('http://'), ('https://bit.ly'), ('free money'), ('crypto giveaway');

-- After you sign up on your site, make yourself the admin by running this
-- (swap in your own email):
--
--   update public.profiles set is_admin = true
--   where id = (select id from auth.users where email = 'you@example.com');
