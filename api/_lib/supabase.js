// Utilidades compartidas por las funciones de Vercel (no es un endpoint: el "_" lo excluye)
import { createClient } from '@supabase/supabase-js';

// Acepta el nombre nuevo de Supabase o el clásico (ej. SUPABASE_PUBLISHABLE_KEY o SUPABASE_ANON_KEY)
export function env(...names) {
  for (const n of names) if (process.env[n]) return process.env[n];
  throw Object.assign(new Error(`Falta la variable de entorno ${names[0]}`), { status: 500 });
}
export const supabaseUrl = () => env('SUPABASE_URL');
export const publishableKey = () => env('SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_ANON_KEY');
const secretKey = () => env('SUPABASE_SECRET_KEY', 'SUPABASE_SERVICE_ROLE_KEY');

// Cliente con la Secret key (service_role): SOLO se usa en el servidor, nunca se envía al navegador.
export function adminClient() {
  return createClient(supabaseUrl(), secretKey(), {
    auth: { persistSession: false, autoRefreshToken: false }
  });
}

export function send(res, status, body, cache = 'no-store') {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', cache);
  res.end(JSON.stringify(body));
}

export async function readJson(req) {
  if (req.body !== undefined) return typeof req.body === 'string' ? JSON.parse(req.body || '{}') : req.body;
  let raw = '';
  for await (const chunk of req) { raw += chunk; if (raw.length > 10_000) throw Object.assign(new Error('Cuerpo demasiado grande'), { status: 413 }); }
  return raw ? JSON.parse(raw) : {};
}

// Verifica el JWT de Supabase Auth y que el usuario figure en la tabla admins.
export async function requireAdmin(req) {
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) throw Object.assign(new Error('No autenticado'), { status: 401 });
  const db = adminClient();
  const { data, error } = await db.auth.getUser(token);
  if (error || !data?.user) throw Object.assign(new Error('Sesión inválida o vencida'), { status: 401 });
  const { data: row, error: e2 } = await db.from('admins').select('user_id').eq('user_id', data.user.id).maybeSingle();
  if (e2) throw Object.assign(new Error('No se pudo verificar el permiso'), { status: 500 });
  if (!row) throw Object.assign(new Error('Tu usuario no tiene permisos de administrador'), { status: 403 });
  return { user: data.user, db };
}

export function handleError(res, e) {
  const status = e.status || 500;
  if (status >= 500) console.error(e);
  send(res, status, { error: status >= 500 && !e.status ? 'Error interno' : e.message });
}
