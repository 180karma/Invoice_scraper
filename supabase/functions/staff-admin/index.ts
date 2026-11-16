// Kitchen staff list for the invoice scraper. Only admins on the list may call it.
// Deployed with verify_jwt off: the caller's token is checked here against Supabase Auth.
// The service key is used only inside this function and never reaches a browser.
//
// POST { op: "list" }                          -> { staff: [{ email, role, created_at }] }
// POST { op: "add", email, role }              -> adds (or updates) the person and creates their sign-in account
// POST { op: "remove", email }                 -> removes the person and deletes their sign-in account
// POST { op: "role", email, role }             -> changes admin / staff
// Every success returns the new list. Errors: { error: { code, message } }.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const URL_ = (Deno.env.get('SUPABASE_URL') || '').replace(/\/+$/, '');
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

type Staff = { email: string; role: 'admin' | 'staff'; created_at?: string };

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}
const fail = (status: number, code: string, message: string) => json(status, { error: { code, status, message } });

function serviceKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}');
    if (keys && typeof keys.default === 'string' && keys.default) return keys.default;
  } catch { /* fall back to the legacy key */ }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
}
// sb_secret_ keys go in apikey only; a legacy service_role JWT also goes in Authorization
function adminHeaders(extra: Record<string, string> = {}): Record<string, string> {
  const key = serviceKey(), h: Record<string, string> = { apikey: key, 'Content-Type': 'application/json', ...extra };
  if (key.split('.').length === 3) h.Authorization = 'Bearer ' + key;
  return h;
}

async function signedInEmail(req: Request): Promise<string> {
  const token = /^Bearer\s+(.+)$/i.exec(req.headers.get('authorization') || '')?.[1] || '';
  if (!token || /^sb_/.test(token)) return '';
  const apikey = Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '';
  const r = await fetch(URL_ + '/auth/v1/user', { headers: { apikey, Authorization: 'Bearer ' + token } });
  if (!r.ok) return '';
  const u = await r.json().catch(() => null);
  return u && u.id ? String(u.email || '').toLowerCase() : '';
}

async function rest(path: string, init: RequestInit = {}): Promise<unknown> {
  const r = await fetch(URL_ + '/rest/v1/' + path, { ...init, headers: adminHeaders((init.headers as Record<string, string>) || {}) });
  const text = await r.text();
  if (!r.ok) throw new Error('Database: ' + text.slice(0, 200));
  return text ? JSON.parse(text) : null;
}
const list = async () => (await rest('staff?select=email,role,created_at&order=email.asc')) as Staff[];

async function authUserId(email: string): Promise<string> {
  for (let page = 1; page <= 50; page++) {
    const r = await fetch(URL_ + '/auth/v1/admin/users?per_page=200&page=' + page, { headers: adminHeaders() });
    if (!r.ok) throw new Error('Auth: ' + (await r.text()).slice(0, 200));
    const users = ((await r.json()) || {}).users || [];
    const u = users.find((x: { email?: string }) => String(x.email || '').toLowerCase() === email);
    if (u) return u.id;
    if (users.length < 200) return '';
  }
  return '';
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail(405, 'method', 'Use POST.');
  if (!URL_ || !serviceKey()) return fail(503, 'not_configured', 'The function has no service key. Redeploy it in Supabase.');

  const me = await signedInEmail(req).catch(() => '');
  if (!me) return fail(401, 'unauthorized', 'Sign in again.');

  let msg: { op?: string; email?: string; role?: string };
  try { msg = await req.json(); } catch { return fail(400, 'bad_request', 'The request is not JSON.'); }

  try {
    let staff = await list();
    if (!staff.some(s => s.email === me && s.role === 'admin')) return fail(403, 'not_admin', 'Only admins can manage staff.');
    const email = String(msg.email || '').trim().toLowerCase();
    const role = msg.role === 'admin' ? 'admin' : 'staff';
    const admins = staff.filter(s => s.role === 'admin').length;
    const target = staff.find(s => s.email === email);

    if (msg.op === 'list') return json(200, { staff });
    if (!EMAIL.test(email)) return fail(400, 'bad_email', 'That is not an email address.');

    if (msg.op === 'add') {
      if (target && target.role === 'admin' && role !== 'admin' && admins <= 1) return fail(409, 'last_admin', 'The kitchen needs at least one admin.');
      await rest('staff?on_conflict=email', { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify([{ email, role }]) });
      if (!(await authUserId(email))) {
        const r = await fetch(URL_ + '/auth/v1/admin/users', { method: 'POST', headers: adminHeaders(), body: JSON.stringify({ email, email_confirm: true }) });
        if (!r.ok && r.status !== 422) throw new Error('Auth: ' + (await r.text()).slice(0, 200));
      }
    } else if (msg.op === 'role') {
      if (!target) return fail(404, 'not_found', 'That email is not on the staff list.');
      if (email === me && role !== 'admin') return fail(409, 'self', 'You can’t remove your own admin role. Ask another admin.');
      if (target.role === 'admin' && role !== 'admin' && admins <= 1) return fail(409, 'last_admin', 'The kitchen needs at least one admin.');
      await rest('staff?email=eq.' + encodeURIComponent(email), { method: 'PATCH', body: JSON.stringify({ role }) });
    } else if (msg.op === 'remove') {
      if (email === me) return fail(409, 'self', 'You can’t remove yourself. Ask another admin.');
      if (target && target.role === 'admin' && admins <= 1) return fail(409, 'last_admin', 'The kitchen needs at least one admin.');
      await rest('staff?email=eq.' + encodeURIComponent(email), { method: 'DELETE' });
      const id = await authUserId(email);
      if (id) {
        const r = await fetch(URL_ + '/auth/v1/admin/users/' + id, { method: 'DELETE', headers: adminHeaders() });
        if (!r.ok && r.status !== 404) throw new Error('Auth: ' + (await r.text()).slice(0, 200));
      }
    } else {
      return fail(400, 'bad_op', 'Unknown operation.');
    }
    staff = await list();
    return json(200, { staff });
  } catch (e) {
    return fail(500, 'failed', String((e as Error).message || e).slice(0, 300));
  }
});
