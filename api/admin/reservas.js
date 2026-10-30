// GET /api/admin/reservas?estado=PENDIENTE&desde=2026-11-01&hasta=2026-11-30
// Lista de reservas con datos de contacto e historial. Requiere sesión de administrador.
import { requireAdmin, send, handleError } from '../_lib/supabase.js';

const ESTADOS = ['PENDIENTE', 'CONFIRMADO', 'RECHAZADO', 'CANCELADO'];
const FECHA = /^\d{4}-\d{2}-\d{2}$/;

export default async function handler(req, res) {
  if (req.method !== 'GET') return send(res, 405, { error: 'Método no permitido' });
  try {
    const { db } = await requireAdmin(req);
    const url = new URL(req.url, 'http://localhost');
    const estado = url.searchParams.get('estado');
    const desde = url.searchParams.get('desde');
    const hasta = url.searchParams.get('hasta');

    // Primero se liberan las solicitudes pendientes vencidas, para que el panel muestre el estado real
    const { error: e1 } = await db.rpc('liberar_pendientes_vencidas');
    if (e1) throw e1;

    let q = db.from('reservas')
      .select('id, codigo, token, barbero_id, asignado_automaticamente, servicios, duracion_min, total_ars, inicio, fin, ' +
              'cliente_nombre, cliente_telefono, cliente_email, notas, estado, expira_en, motivo, created_at, ' +
              'barberos(nombre), reservas_historial(estado_anterior, estado_nuevo, motivo, cambiado_por, created_at)')
      .order('inicio', { ascending: true })
      .limit(300);
    if (estado) {
      if (!ESTADOS.includes(estado)) return send(res, 400, { error: 'Estado inválido' });
      q = q.eq('estado', estado);
    }
    // Las fechas se interpretan en hora de Argentina (UTC-3)
    if (desde) { if (!FECHA.test(desde)) return send(res, 400, { error: 'Fecha inválida' }); q = q.gte('inicio', `${desde}T00:00:00-03:00`); }
    if (hasta) { if (!FECHA.test(hasta)) return send(res, 400, { error: 'Fecha inválida' }); q = q.lte('inicio', `${hasta}T23:59:59-03:00`); }

    const { data, error } = await q;
    if (error) throw error;
    send(res, 200, { reservas: data });
  } catch (e) {
    handleError(res, e);
  }
}
