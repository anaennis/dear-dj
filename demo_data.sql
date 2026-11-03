-- Dear DJ: optional demo data
--
-- Run this AFTER schema.sql and AFTER you've signed up once on your site.
-- It adds three sample requests, a playlist, a comment and a mixtape under the first account
-- that signed up, so the board and the tables have something in them.
--
-- Paste into Supabase > SQL Editor > New query > Run.
-- To remove it again, run the last block at the bottom of this file.

do $$
declare
  me uuid := (select id from public.profiles order by created_at limit 1);
  r1 uuid := gen_random_uuid();
  r2 uuid := gen_random_uuid();
  p1 uuid := gen_random_uuid();
begin
  if me is null then
    raise exception 'No accounts yet. Sign up on your site first, then run this again.';
  end if;

  insert into public.requests (id, user_id, title, top_songs, top_artists, wants, mood, notes) values
  (r1, me, 'Rainy day focus',
   '[{"kind":"track","name":"Open Eye Signal","artist":"Jon Hopkins"},{"kind":"track","name":"Teardrop","artist":"Massive Attack"}]',
   '[{"kind":"artist","name":"Bonobo"},{"kind":"artist","name":"Floating Points"}]',
   '{new_artists,mood}', 'rainy-day focus', 'Nothing with lyrics, please.'),
  (r2, me, 'Road trip, windows down',
   '[{"kind":"track","name":"Dreams","artist":"Fleetwood Mac"}]',
   '[{"kind":"artist","name":"The War on Drugs"}]',
   '{new_songs}', 'road trip', null),
  (gen_random_uuid(), me, 'Songs to cook to',
   '[{"kind":"track","name":"September","artist":"Earth, Wind & Fire"}]',
   '[{"kind":"artist","name":"Khruangbin"}]',
   '{new_songs,new_artists}', null, null);

  insert into public.playlists (id, request_id, user_id, spotify_id, note)
  values (p1, r1, me, '37i9dQZF1DXcBWIGoYBM5M', 'Demo playlist. Delete me any time.');

  insert into public.comments (playlist_id, user_id, body)
  values (p1, me, 'Demo comment: this is what a comment looks like.');

  insert into public.mixtapes (user_id, spotify_id, title, description, tags)
  values (me, '37i9dQZF1DX4sWSpwq3LiO', 'Demo mixtape: peaceful piano',
          'Demo mixtape. This is what a shared playlist looks like. Delete me any time.',
          '{calm,piano,focus}');
end $$;

-- ---------------------------------------------------------------
-- To remove the demo rows again, run just this (it only touches rows
-- whose text matches the demo content):
--
--   delete from public.requests
--   where title in ('Rainy day focus','Road trip, windows down','Songs to cook to');
--   delete from public.mixtapes where title = 'Demo mixtape: peaceful piano';
-- ---------------------------------------------------------------
