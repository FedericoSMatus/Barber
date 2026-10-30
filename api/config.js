// Entrega al navegador SOLO los datos públicos de Supabase (Project URL + Publishable key).
// La Secret key nunca sale del servidor.
import { send, handleError, supabaseUrl, publishableKey } from './_lib/supabase.js';

export default function handler(req, res) {
  if (req.method !== 'GET') return send(res, 405, { error: 'Método no permitido' });
  try {
    send(res, 200, { supabaseUrl: supabaseUrl(), supabaseAnonKey: publishableKey() }, 'public, max-age=300');
  } catch (e) {
    handleError(res, e);
  }
}
