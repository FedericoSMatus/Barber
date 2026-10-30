// POST /api/admin/estado  { id, estado: 'CONFIRMADO' | 'RECHAZADO' | 'CANCELADO', motivo? }
// Cambia el estado de una reserva. Las reglas de transición se validan en la base.
import { requireAdmin, readJson, send, handleError } from '../_lib/supabase.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function handler(req, res) {
  if (req.method !== 'POST') return send(res, 405, { error: 'Método no permitido' });
  try {
    const { user, db } = await requireAdmin(req);
    const { id, estado, motivo } = await readJson(req);
    if (!UUID.test(id || '')) return send(res, 400, { error: 'Reserva inválida' });
    if (!['CONFIRMADO', 'RECHAZADO', 'CANCELADO'].includes(estado)) return send(res, 400, { error: 'Estado inválido' });
    if (motivo != null && (typeof motivo !== 'string' || motivo.length > 300)) return send(res, 400, { error: 'Motivo inválido' });

    const { data, error } = await db.rpc('admin_cambiar_estado', {
      p_reserva_id: id, p_estado: estado, p_motivo: motivo || null, p_admin: user.email || user.id
    });
    if (error) {
      // Errores de negocio de la base: "TRANSICION_INVALIDA: …", "NO_ENCONTRADA: …"
      if (error.code === 'P0001') return send(res, error.message.startsWith('NO_ENCONTRADA') ? 404 : 409, { error: error.message.replace(/^[A-Z_]+:\s*/, '') });
      throw error;
    }
    send(res, 200, { reserva: data });
  } catch (e) {
    handleError(res, e);
  }
}
