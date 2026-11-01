# Dear DJ

A request board for friends and family. Someone lists up to five songs and five artists they love and what they're after (new artists, new songs, or a mood). Anyone else can answer with a Spotify playlist.

Hosting: GitHub Pages (site) + Supabase (database and accounts) + an optional Cloudflare Worker (song search). All free at this size.

## Files

| File | What it is |
|---|---|
| `index.html` | The whole website |
| `config.js` | Your three settings (Supabase URL, publishable key, optional search URL). The only file you edit. |
| `schema.sql` | Database tables, permissions, spam protection, moderation |
| `worker.js` | Optional: Spotify search-as-you-type |
| `demo_data.sql` | Optional: a few sample requests, a playlist and a comment, so the tables aren't empty. Run it after you've signed up once. |

## Setup

### 1. Supabase (10 minutes)

1. Create a free project at supabase.com.
2. **SQL Editor → New query**, paste all of `schema.sql`, click **Run**.
3. **Authentication → Sign In / Providers → Email**: turn **off** "Confirm email". For a friends-and-family site this avoids Supabase's tight limit on built-in emails. (Anyone can then sign up with any address, so only share the link with people you trust, or ask me to add an invite code.)
4. Copy your **Project URL** and your **publishable key** (it starts with `sb_publishable_`). The easiest place is the **Connect** button at the top of the dashboard, or **Project Settings → API Keys**, on the *Publishable and secret API keys* tab. Older projects may only show a legacy key labelled **anon**, which also works.
5. Open `config.js` and paste them between the quotes on the `SUPABASE_URL` and `SUPABASE_ANON_KEY` lines (yes, the publishable key goes in the `ANON_KEY` slot. The name is just left over from the older key). Your settings live in this file so that a new `index.html` never overwrites them.

The publishable (or anon) key is meant to be public. The permissions in `schema.sql` are what protect your data. Never put a **secret** key (`sb_secret_...`) or the legacy `service_role` key anywhere in this project, since those skip all the protections.

### 2. GitHub Pages (5 minutes)

1. Create a new public repo, e.g. `dear-dj`, and upload `index.html` and `config.js` (the other files are optional to include).
2. **Settings → Pages → Build and deployment**: Source "Deploy from a branch", branch `main`, folder `/ (root)`.
3. Your site appears at `https://YOURNAME.github.io/dear-dj/` after a minute or two.

### 3. Make yourself admin

Sign up on your live site, then in Supabase's SQL Editor run (with your own email):

```sql
update public.profiles set is_admin = true
where id = (select id from auth.users where email = 'you@example.com');
```

Only change the text between the single quotes, and keep the quotes and everything else exactly as written. If you'd rather not type your email, this does the same for the very first account that signed up:

```sql
update public.profiles set is_admin = true
where id = (select id from public.profiles order by created_at limit 1);
```

Reload the site. An **Admin** link appears in the menu.

### 4. Song search (optional, 15 minutes)

Skip this and everything still works, people just type songs by hand.

1. At developer.spotify.com/dashboard, create an app. Note its Client ID and Client secret. Check Spotify's current developer terms while you're there, since they change.
2. At dash.cloudflare.com → **Workers & Pages → Create → Start with Hello World**. Deploy, then **Edit code** and replace everything with `worker.js`.
3. **Settings → Variables and Secrets**, add `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET` (as a secret) and `ALLOWED_ORIGIN` = `https://YOURNAME.github.io` (no path, no trailing slash).
4. Paste the worker's URL (`https://something.workers.dev`) into `SEARCH_URL` in `config.js`.

## How moderation works

- **Login required** to post, send playlists, or report.
- **Comments** go under each playlist (not under the request). Same rules apply: login required, word filter, report button, auto-hide after three reports, and you can delete any comment. People can delete their own.
- **Rate limits**: 3 requests, 15 playlists, 30 comments and 20 reports per person per day.
- **Link checking**: only real `open.spotify.com/playlist/...` links are accepted, and only the 22-character ID is stored.
- **Word filter**: add lowercase rows to the `blocked_terms` table in Supabase's Table Editor.
- **Reports**: anyone signed in can report a request or playlist. Three different people reporting something hides it until you review it on the Admin page, where you can dismiss, hide, or hide and ban the author.
- **Closed requests** stop accepting playlists. Authors can close, reopen or delete their own.

## Privacy: where emails live

Emails are stored only in Supabase's private `auth.users` table. The public `profiles` table holds an ID and a display name, and its permissions allow reading only those two columns. Nothing in the site's queries touches emails, and the admin page shows display names only, not emails.

Two things to check or know:

1. **Keep the auth schema private.** In Supabase, open **Project Settings → API → Exposed schemas** (wording varies) and make sure only `public` is listed (`graphql_public` is also fine). Never add `auth`. Never create a view or function that reads `auth.users` and expose it.
2. **Account-existence check (a known limitation).** With "Confirm email" turned off, someone who tries to sign up with an address that already has an account gets an error saying so. That means a determined person could test whether a specific email is registered, though they can't see anything about the account. Turning "Confirm email" back on closes this, at the cost of needing a working email sender (see Supabase's custom SMTP option).

If you ran an earlier version of `schema.sql`, apply this fix in the SQL Editor (it stops public names ever being derived from emails):

```sql
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  nm := left(trim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 40);
  if nm = '' or nm like '%@%' then nm := 'Anonymous'; end if;
  insert into public.profiles (id, display_name) values (new.id, nm);
  return new;
end $$;

alter table public.profiles add constraint no_email_in_name check (display_name not like '%@%');

-- Fix anyone who already got an email-derived name:
update public.profiles set display_name = 'Anonymous' where display_name like '%@%';
```

## Free-tier chores

- **Auto-pause**: Supabase pauses free projects after a week with no database activity. If the site ever goes blank, open your Supabase dashboard and click Restore. A scheduled GitHub Action that pings the database daily avoids this.
- **No backups** on the free plan. Export your data now and then.
