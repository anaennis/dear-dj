// Dear DJ: Spotify search proxy for Cloudflare Workers (optional)
//
// Why this exists: your Spotify client secret can't live in a GitHub Pages site,
// because anyone can read it. This tiny worker keeps it private and answers
// "search for a song/artist" requests from your site.
//
// Settings to add in Cloudflare (Worker > Settings > Variables and Secrets):
//   SPOTIFY_CLIENT_ID      (text)
//   SPOTIFY_CLIENT_SECRET  (secret)
//   ALLOWED_ORIGIN         (text)  e.g. https://yourname.github.io
//                                  Several are allowed, comma-separated:
//                                  https://yourname.github.io,http://localhost:8000

let cached = { token: null, expires: 0 };

async function getToken(env) {
  if (cached.token && Date.now() < cached.expires - 30_000) return cached.token;
  const res = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: {
      Authorization: 'Basic ' + btoa(`${env.SPOTIFY_CLIENT_ID}:${env.SPOTIFY_CLIENT_SECRET}`),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials',
  });
  if (!res.ok) throw new Error('Spotify token request failed');
  const data = await res.json();
  cached = { token: data.access_token, expires: Date.now() + data.expires_in * 1000 };
  return cached.token;
}

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const allowed = (env.ALLOWED_ORIGIN || '').split(',').map(s => s.trim()).filter(Boolean);
    const cors = {
      'Access-Control-Allow-Origin': allowed.includes(origin) ? origin : (allowed[0] || ''),
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      Vary: 'Origin',
    };
    const json = (body, status = 200, extra = {}) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json', ...cors, ...extra },
      });

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (request.method !== 'GET') return json({ error: 'Method not allowed' }, 405);
    if (!allowed.includes(origin)) return json({ error: 'Forbidden' }, 403);

    const url = new URL(request.url);
    const q = (url.searchParams.get('q') || '').trim().slice(0, 80);
    const type = url.searchParams.get('type') === 'artist' ? 'artist' : 'track';
    if (q.length < 2) return json([]);

    try {
      const token = await getToken(env);
      const res = await fetch(
        'https://api.spotify.com/v1/search?' + new URLSearchParams({ q, type, limit: '5' }),
        { headers: { Authorization: `Bearer ${token}` } }
      );
      if (!res.ok) return json([], 502);
      const data = await res.json();

      const items = type === 'artist'
        ? (data.artists?.items || []).map(a => ({ id: a.id, name: a.name }))
        : (data.tracks?.items || []).map(t => ({
            id: t.id,
            name: t.name,
            artist: (t.artists || []).map(a => a.name).join(', '),
          }));

      return json(items, 200, { 'Cache-Control': 'public, max-age=300' });
    } catch {
      return json([], 502);
    }
  },
};
