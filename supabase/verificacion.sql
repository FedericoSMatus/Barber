-- =====================================================================
-- Verificación posterior a schema.sql (solo lectura, no modifica nada)
-- Ejecutar en Supabase → SQL Editor. Todas las filas deben decir OK.
-- =====================================================================
with checks(control, ok, detalle) as (
  values
  -- Estructura
  ('Extensión btree_gist instalada',
     exists (select 1 from pg_extension where extname = 'btree_gist'), ''),
  ('7 tablas creadas',
     (select count(*) from pg_tables where schemaname = 'public' and tablename in
       ('servicios','barberos','horarios_barbero','horarios_local','admins','reservas','reservas_historial')) = 7, ''),
  ('Restricción anti-superposición',
     exists (select 1 from pg_constraint where conname = 'reservas_sin_superposicion' and contype = 'x'), ''),
  ('Trigger de estados',
     exists (select 1 from pg_trigger where tgname = 'reservas_validar_estado'), ''),
  -- Datos
  ('10 servicios activos',  (select count(*) from public.servicios where activo) = 10,
     (select count(*)::text from public.servicios where activo)),
  ('4 barberos activos',    (select count(*) from public.barberos where activo) = 4,
     (select count(*)::text from public.barberos where activo)),
  ('Horarios cargados',     (select count(*) from public.horarios_barbero) = 20 and (select count(*) from public.horarios_local) = 6, ''),
  ('Plazo de pendientes',   public.plazo_pendiente() > interval '0', public.plazo_pendiente()::text),
  -- RLS
  ('RLS activo en las 7 tablas',
     (select bool_and(relrowsecurity) from pg_class where relnamespace = 'public'::regnamespace and relname in
       ('servicios','barberos','horarios_barbero','horarios_local','admins','reservas','reservas_historial')), ''),
  ('Sin políticas en reservas/historial/admins',
     not exists (select 1 from pg_policies where schemaname = 'public' and tablename in ('reservas','reservas_historial','admins')), ''),
  -- Permisos del navegador (anon = Publishable key)
  ('anon NO lee reservas',            not has_table_privilege('anon', 'public.reservas', 'select'), ''),
  ('anon NO inserta reservas',        not has_table_privilege('anon', 'public.reservas', 'insert'), ''),
  ('anon NO lee historial',           not has_table_privilege('anon', 'public.reservas_historial', 'select'), ''),
  ('anon NO lee admins',              not has_table_privilege('anon', 'public.admins', 'select'), ''),
  ('anon NO modifica precios',        not has_table_privilege('anon', 'public.servicios', 'update'), ''),
  ('anon lee el catálogo',            has_table_privilege('anon', 'public.servicios', 'select'), ''),
  ('anon puede pedir turnos',         has_function_privilege('anon', 'public.crear_solicitud(text[], text, date, time, text, text, text, text)', 'execute'), ''),
  ('anon consulta ocupación',         has_function_privilege('anon', 'public.obtener_ocupacion(date, date)', 'execute'), ''),
  ('anon NO confirma turnos',         not has_function_privilege('anon', 'public.admin_cambiar_estado(uuid, text, text, text)', 'execute'), ''),
  ('authenticated NO confirma turnos', not has_function_privilege('authenticated', 'public.admin_cambiar_estado(uuid, text, text, text)', 'execute'), ''),
  ('service_role confirma turnos',    has_function_privilege('service_role', 'public.admin_cambiar_estado(uuid, text, text, text)', 'execute'), ''),
  -- Administración
  ('Al menos 1 administrador (paso posterior)', (select count(*) from public.admins) >= 1,
     coalesce((select string_agg(u.email, ', ') from public.admins a join auth.users u on u.id = a.user_id), 'ninguno todavía'))
)
select case when ok then 'OK' else 'REVISAR' end as resultado, control, detalle from checks;
