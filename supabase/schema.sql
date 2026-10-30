-- =====================================================================
-- Patagonia Grooming Co. · Sistema de reservas · schema.sql
--
-- Ejecutar completo en Supabase → SQL Editor → Run (pensado para un
-- proyecto nuevo). Solo crea objetos en el esquema "public" y la
-- extensión btree_gist en el esquema "extensions".
--
-- Se puede volver a ejecutar: no borra reservas. Al re-ejecutarlo se
-- actualizan funciones, políticas, servicios/precios y se REEMPLAZAN
-- los horarios por los de la sección "Datos iniciales".
-- =====================================================================

create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------------
-- 1. CATÁLOGO (fuente oficial de precios, duraciones y horarios)
-- ---------------------------------------------------------------------
create table if not exists public.servicios (
  id            text primary key,                                   -- ej. 'corte' (mismo id que usa la web)
  nombre        text not null,
  categoria     text not null check (categoria in ('cabello', 'barba', 'combos', 'tratamientos')),
  duracion_min  integer not null check (duracion_min between 5 and 480),
  precio_ars    integer not null check (precio_ars >= 0),
  activo        boolean not null default true
);

create table if not exists public.barberos (
  id      text primary key,
  nombre  text not null,
  activo  boolean not null default true
);

-- dia_semana: 0 = domingo … 6 = sábado (igual que Date.getDay() en JavaScript)
create table if not exists public.horarios_barbero (
  barbero_id  text not null references public.barberos(id) on delete cascade,
  dia_semana  smallint not null check (dia_semana between 0 and 6),
  abre        time not null,
  cierra      time not null,
  primary key (barbero_id, dia_semana),
  check (cierra > abre)
);

create table if not exists public.horarios_local (
  dia_semana  smallint primary key check (dia_semana between 0 and 6),
  abre        time not null,
  cierra      time not null,
  check (cierra > abre)
);

-- ---------------------------------------------------------------------
-- 2. ADMINISTRADORES (usuarios de Supabase Auth con acceso al panel)
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  nombre      text,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. RESERVAS
-- ---------------------------------------------------------------------
create table if not exists public.reservas (
  id                        uuid primary key default gen_random_uuid(),
  codigo                    text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
  token                     uuid not null unique default gen_random_uuid(),  -- enlace privado de seguimiento
  barbero_id                text not null references public.barberos(id),
  asignado_automaticamente  boolean not null default false,                  -- el cliente eligió "Cualquier barbero"
  servicios                 jsonb not null,                                  -- copia de nombre/precio/duración al pedir
  duracion_min              integer not null check (duracion_min between 5 and 600),
  total_ars                 integer not null check (total_ars >= 0),
  inicio                    timestamptz not null,
  fin                       timestamptz not null,
  cliente_nombre            text not null check (char_length(cliente_nombre) between 2 and 80),
  cliente_telefono          text not null check (cliente_telefono ~ '^[0-9]{8,15}$'),
  cliente_email             text check (cliente_email is null or (char_length(cliente_email) <= 120 and cliente_email ~* '^[^\s@]+@[^\s@]+\.[^\s@]+$')),
  notas                     text check (notas is null or char_length(notas) <= 500),
  estado                    text not null default 'PENDIENTE'
                              check (estado in ('PENDIENTE', 'CONFIRMADO', 'RECHAZADO', 'CANCELADO')),
  expira_en                 timestamptz,                                     -- hasta cuándo bloquea una solicitud PENDIENTE
  motivo                    text check (motivo is null or char_length(motivo) <= 300),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  check (fin > inicio),
  -- Protección definitiva contra turnos superpuestos del mismo barbero,
  -- incluso si llegan dos solicitudes en el mismo instante.
  constraint reservas_sin_superposicion exclude using gist (
    barbero_id with =,
    tstzrange(inicio, fin, '[)') with &&
  ) where (estado in ('PENDIENTE', 'CONFIRMADO'))
);

create index if not exists reservas_inicio_idx    on public.reservas (inicio);
create index if not exists reservas_estado_idx    on public.reservas (estado, inicio);
create index if not exists reservas_expira_idx    on public.reservas (expira_en) where estado = 'PENDIENTE';
create index if not exists reservas_telefono_idx  on public.reservas (cliente_telefono, estado);

create table if not exists public.reservas_historial (
  id               bigint generated always as identity primary key,
  reserva_id       uuid not null references public.reservas(id) on delete cascade,
  estado_anterior  text,
  estado_nuevo     text not null,
  motivo           text,
  cambiado_por     text not null,   -- 'cliente', 'sistema' o el email del administrador
  created_at       timestamptz not null default now()
);
create index if not exists reservas_historial_reserva_idx on public.reservas_historial (reserva_id, created_at);

-- ---------------------------------------------------------------------
-- 4. PARÁMETROS
-- ---------------------------------------------------------------------
-- Zona horaria de la barbería
create or replace function public.tz_local()
returns text language sql immutable set search_path = public
as $$ select 'America/Argentina/Buenos_Aires'::text $$;

-- Cuánto tiempo una solicitud PENDIENTE bloquea el horario sin ser confirmada.
-- Nunca bloquea más allá del inicio del turno. Para cambiarlo, editá el valor y re-ejecutá.
create or replace function public.plazo_pendiente()
returns interval language sql immutable set search_path = public
as $$ select interval '12 hours' $$;

-- ---------------------------------------------------------------------
-- 5. REGLAS DE ESTADO (validadas en la base, no en el navegador)
--   PENDIENTE  → CONFIRMADO | RECHAZADO | CANCELADO
--   CONFIRMADO → CANCELADO
--   RECHAZADO y CANCELADO son finales
-- ---------------------------------------------------------------------
create or replace function public.validar_cambio_estado()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.estado is distinct from old.estado then
    if not (
      (old.estado = 'PENDIENTE'  and new.estado in ('CONFIRMADO', 'RECHAZADO', 'CANCELADO')) or
      (old.estado = 'CONFIRMADO' and new.estado = 'CANCELADO')
    ) then
      raise exception 'TRANSICION_INVALIDA: no se puede pasar de % a %', old.estado, new.estado
        using errcode = 'P0001';
    end if;
  end if;
  -- Los datos del turno no se editan una vez creado (solo estado y motivo)
  if (new.inicio, new.fin, new.barbero_id, new.servicios, new.total_ars)
     is distinct from (old.inicio, old.fin, old.barbero_id, old.servicios, old.total_ars) then
    raise exception 'RESERVA_INMUTABLE: los datos del turno no se pueden editar' using errcode = 'P0001';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists reservas_validar_estado on public.reservas;
create trigger reservas_validar_estado
  before update on public.reservas
  for each row execute function public.validar_cambio_estado();

-- Libera las solicitudes PENDIENTES vencidas: pasan a CANCELADO y el horario queda libre.
-- Se ejecuta sola cada vez que alguien consulta disponibilidad, pide un turno o abre el panel.
create or replace function public.liberar_pendientes_vencidas()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_n integer;
begin
  with vencidas as (
    update public.reservas
       set estado = 'CANCELADO', motivo = 'Vencida: no se confirmó a tiempo'
     where estado = 'PENDIENTE' and expira_en <= now()
    returning id
  )
  insert into public.reservas_historial (reserva_id, estado_anterior, estado_nuevo, motivo, cambiado_por)
  select id, 'PENDIENTE', 'CANCELADO', 'Vencida: no se confirmó a tiempo', 'sistema' from vencidas;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- =====================================================================
-- 6. API PÚBLICA (la usa la web con la Publishable key / anon)
-- =====================================================================

-- Catálogo oficial: precios, duraciones y horarios
create or replace function public.obtener_catalogo()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'servicios', coalesce((select json_agg(json_build_object('id', id, 'nombre', nombre, 'categoria', categoria,
                   'duracion_min', duracion_min, 'precio_ars', precio_ars) order by categoria, precio_ars)
                   from public.servicios where activo), '[]'),
    'barberos', coalesce((select json_agg(json_build_object('id', id, 'nombre', nombre) order by nombre)
                   from public.barberos where activo), '[]'),
    'horarios_barbero', coalesce((select json_agg(json_build_object('barbero_id', h.barbero_id, 'dia_semana', h.dia_semana,
                   'abre', to_char(h.abre, 'HH24:MI'), 'cierra', to_char(h.cierra, 'HH24:MI')))
                   from public.horarios_barbero h join public.barberos b on b.id = h.barbero_id where b.activo), '[]'),
    'horarios_local', coalesce((select json_agg(json_build_object('dia_semana', dia_semana,
                   'abre', to_char(abre, 'HH24:MI'), 'cierra', to_char(cierra, 'HH24:MI')))
                   from public.horarios_local), '[]'),
    'plazo_pendiente_horas', extract(epoch from public.plazo_pendiente()) / 3600
  );
$$;

-- Horarios ocupados (PENDIENTES vigentes y CONFIRMADOS), sin datos personales
create or replace function public.obtener_ocupacion(p_desde date, p_hasta date)
returns table (barbero_id text, inicio timestamptz, fin timestamptz)
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 62 then
    raise exception 'RANGO_INVALIDO: el rango de fechas debe ser de hasta 62 días' using errcode = 'P0001';
  end if;
  perform public.liberar_pendientes_vencidas();
  return query
    select r.barbero_id, r.inicio, r.fin
    from public.reservas r
    where r.estado in ('PENDIENTE', 'CONFIRMADO')
      and r.inicio < ((p_hasta + 1)::timestamp at time zone public.tz_local())
      and r.fin    > (p_desde::timestamp at time zone public.tz_local())
    order by r.inicio;
end;
$$;

-- Crear una solicitud de turno (siempre queda PENDIENTE)
create or replace function public.crear_solicitud(
  p_servicios  text[],
  p_barbero    text,        -- id del barbero o 'any'
  p_fecha      date,        -- fecha local de la barbería
  p_hora       time,        -- hora local de la barbería (HH:MM)
  p_nombre     text,
  p_telefono   text,
  p_email      text default null,
  p_notas      text default null
)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tz         text := public.tz_local();
  v_nombre     text := btrim(coalesce(p_nombre, ''));
  v_tel        text := regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g');
  v_email      text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_notas      text := nullif(btrim(coalesce(p_notas, '')), '');
  v_ids        text[];
  v_count      int;
  v_duracion   int;
  v_total      int;
  v_snapshot   jsonb;
  v_dow        smallint;
  v_inicio     timestamptz;
  v_fin        timestamptz;
  v_hora_fin   time;
  v_barbero    text;
  v_auto       boolean := false;
  v_hoy        date := (now() at time zone v_tz)::date;
  v_r          public.reservas;
begin
  -- Datos del cliente
  if char_length(v_nombre) < 2 or char_length(v_nombre) > 80 then
    raise exception 'DATOS_INVALIDOS: nombre inválido' using errcode = 'P0001';
  end if;
  if char_length(v_tel) < 8 or char_length(v_tel) > 15 then
    raise exception 'DATOS_INVALIDOS: teléfono inválido' using errcode = 'P0001';
  end if;
  if v_email is not null and (char_length(v_email) > 120 or v_email !~* '^[^\s@]+@[^\s@]+\.[^\s@]+$') then
    raise exception 'DATOS_INVALIDOS: email inválido' using errcode = 'P0001';
  end if;
  if v_notas is not null and char_length(v_notas) > 500 then
    raise exception 'DATOS_INVALIDOS: notas demasiado largas' using errcode = 'P0001';
  end if;

  -- Servicios: entre 1 y 5, existentes y activos. Precio y duración salen de la base.
  select array_agg(distinct s) into v_ids from unnest(coalesce(p_servicios, '{}')) s;
  if v_ids is null or cardinality(v_ids) < 1 or cardinality(v_ids) > 5 then
    raise exception 'DATOS_INVALIDOS: elegí entre 1 y 5 servicios' using errcode = 'P0001';
  end if;
  select count(*), sum(duracion_min), sum(precio_ars),
         jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre, 'duracion_min', duracion_min, 'precio_ars', precio_ars) order by id)
    into v_count, v_duracion, v_total, v_snapshot
    from public.servicios where id = any(v_ids) and activo;
  if v_count <> cardinality(v_ids) then
    raise exception 'DATOS_INVALIDOS: servicio inexistente o no disponible' using errcode = 'P0001';
  end if;

  -- Fecha y hora
  if p_fecha is null or p_hora is null then
    raise exception 'DATOS_INVALIDOS: falta fecha u hora' using errcode = 'P0001';
  end if;
  if extract(minute from p_hora)::int % 15 <> 0 or extract(second from p_hora) <> 0 then
    raise exception 'DATOS_INVALIDOS: horario inválido' using errcode = 'P0001';
  end if;
  if p_fecha > v_hoy + 60 then
    raise exception 'FUERA_DE_RANGO: solo se reservan turnos hasta 60 días adelante' using errcode = 'P0001';
  end if;
  v_inicio   := (p_fecha + p_hora) at time zone v_tz;
  v_fin      := v_inicio + make_interval(mins => v_duracion);
  v_hora_fin := p_hora + make_interval(mins => v_duracion);
  if v_inicio < now() + interval '60 minutes' then
    raise exception 'FUERA_DE_RANGO: el turno debe pedirse con al menos 1 hora de anticipación' using errcode = 'P0001';
  end if;
  if (v_fin at time zone v_tz)::date <> p_fecha then
    raise exception 'HORARIO_NO_DISPONIBLE: el servicio excede el horario del día' using errcode = 'P0001';
  end if;
  v_dow := extract(dow from p_fecha)::smallint;

  if not exists (select 1 from public.horarios_local h
                 where h.dia_semana = v_dow and h.abre <= p_hora and h.cierra >= v_hora_fin) then
    raise exception 'HORARIO_NO_DISPONIBLE: fuera del horario del local' using errcode = 'P0001';
  end if;

  -- Serializa las solicitudes del mismo día (asignación de barbero sin carreras)
  perform pg_advisory_xact_lock(hashtext('reservas:' || p_fecha::text));
  perform public.liberar_pendientes_vencidas();

  -- Anti-spam: máximo 3 solicitudes pendientes futuras por teléfono
  if (select count(*) from public.reservas
      where cliente_telefono = v_tel and estado = 'PENDIENTE' and inicio > now()) >= 3 then
    raise exception 'LIMITE_PENDIENTES: ya tenés 3 solicitudes pendientes' using errcode = 'P0001';
  end if;

  if p_barbero is null or p_barbero = 'any' then
    v_auto := true;
    select b.id into v_barbero
      from public.barberos b
      join public.horarios_barbero h on h.barbero_id = b.id and h.dia_semana = v_dow
     where b.activo and h.abre <= p_hora and h.cierra >= v_hora_fin
       and not exists (select 1 from public.reservas r
                        where r.barbero_id = b.id and r.estado in ('PENDIENTE', 'CONFIRMADO')
                          and tstzrange(r.inicio, r.fin, '[)') && tstzrange(v_inicio, v_fin, '[)'))
     order by (select count(*) from public.reservas r2
                where r2.barbero_id = b.id and r2.estado in ('PENDIENTE', 'CONFIRMADO')
                  and (r2.inicio at time zone v_tz)::date = p_fecha), random()
     limit 1;
  else
    select b.id into v_barbero
      from public.barberos b
      join public.horarios_barbero h on h.barbero_id = b.id and h.dia_semana = v_dow
     where b.id = p_barbero and b.activo and h.abre <= p_hora and h.cierra >= v_hora_fin;
  end if;

  if v_barbero is null then
    raise exception 'HORARIO_NO_DISPONIBLE: no hay barbero disponible en ese horario' using errcode = 'P0001';
  end if;

  begin
    insert into public.reservas (barbero_id, asignado_automaticamente, servicios, duracion_min, total_ars,
                                 inicio, fin, cliente_nombre, cliente_telefono, cliente_email, notas, expira_en)
    values (v_barbero, v_auto, v_snapshot, v_duracion, v_total,
            v_inicio, v_fin, v_nombre, v_tel, v_email, v_notas,
            least(now() + public.plazo_pendiente(), v_inicio))
    returning * into v_r;
  exception when exclusion_violation then
    raise exception 'HORARIO_NO_DISPONIBLE: ese horario acaba de ser reservado' using errcode = 'P0001';
  end;

  insert into public.reservas_historial (reserva_id, estado_anterior, estado_nuevo, cambiado_por)
  values (v_r.id, null, 'PENDIENTE', 'cliente');

  return json_build_object(
    'id', v_r.id, 'codigo', v_r.codigo, 'token', v_r.token, 'estado', v_r.estado,
    'barbero_id', v_r.barbero_id, 'barbero_nombre', (select nombre from public.barberos where id = v_r.barbero_id),
    'asignado_automaticamente', v_r.asignado_automaticamente,
    'servicios', v_r.servicios, 'duracion_min', v_r.duracion_min, 'total_ars', v_r.total_ars,
    'inicio', v_r.inicio, 'fin', v_r.fin, 'expira_en', v_r.expira_en
  );
end;
$$;

-- Estado de una solicitud con su enlace privado (sin teléfono ni email)
create or replace function public.consultar_solicitud(p_token uuid)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v json;
begin
  perform public.liberar_pendientes_vencidas();
  select json_build_object(
    'codigo', r.codigo, 'estado', r.estado, 'motivo', r.motivo,
    'barbero_id', r.barbero_id, 'barbero_nombre', b.nombre,
    'asignado_automaticamente', r.asignado_automaticamente,
    'servicios', r.servicios, 'duracion_min', r.duracion_min, 'total_ars', r.total_ars,
    'inicio', r.inicio, 'fin', r.fin, 'cliente_nombre', r.cliente_nombre,
    'expira_en', case when r.estado = 'PENDIENTE' then r.expira_en end,
    'cancelable', r.estado in ('PENDIENTE', 'CONFIRMADO') and r.inicio > now() + interval '2 hours'
  ) into v
  from public.reservas r join public.barberos b on b.id = r.barbero_id
  where r.token = p_token;
  return v;
end;
$$;

-- El cliente cancela su propia solicitud (hasta 2 h antes)
create or replace function public.cancelar_solicitud(p_token uuid)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_r public.reservas;
begin
  perform public.liberar_pendientes_vencidas();
  select * into v_r from public.reservas where token = p_token for update;
  if not found then
    raise exception 'NO_ENCONTRADA: la solicitud no existe' using errcode = 'P0001';
  end if;
  if v_r.estado not in ('PENDIENTE', 'CONFIRMADO') then
    raise exception 'TRANSICION_INVALIDA: la solicitud ya está %', v_r.estado using errcode = 'P0001';
  end if;
  if v_r.inicio <= now() + interval '2 hours' then
    raise exception 'FUERA_DE_RANGO: solo se puede cancelar hasta 2 horas antes. Escribinos por WhatsApp' using errcode = 'P0001';
  end if;
  update public.reservas set estado = 'CANCELADO', motivo = 'Cancelado por el cliente' where id = v_r.id;
  insert into public.reservas_historial (reserva_id, estado_anterior, estado_nuevo, motivo, cambiado_por)
  values (v_r.id, v_r.estado, 'CANCELADO', 'Cancelado por el cliente', 'cliente');
  return public.consultar_solicitud(p_token);
end;
$$;

-- =====================================================================
-- 7. API ADMINISTRATIVA (solo service_role / Secret key → funciones de Vercel)
-- =====================================================================
create or replace function public.admin_cambiar_estado(
  p_reserva_id  uuid,
  p_estado      text,
  p_motivo      text,
  p_admin       text
)
returns public.reservas
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_anterior  text;
  v_r         public.reservas;
  v_motivo    text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  if p_estado not in ('CONFIRMADO', 'RECHAZADO', 'CANCELADO') then
    raise exception 'DATOS_INVALIDOS: estado inválido' using errcode = 'P0001';
  end if;
  if v_motivo is not null and char_length(v_motivo) > 300 then
    raise exception 'DATOS_INVALIDOS: motivo demasiado largo' using errcode = 'P0001';
  end if;
  perform public.liberar_pendientes_vencidas();   -- una solicitud vencida ya no se puede confirmar
  select estado into v_anterior from public.reservas where id = p_reserva_id for update;
  if not found then
    raise exception 'NO_ENCONTRADA: la reserva no existe' using errcode = 'P0001';
  end if;
  if v_anterior = p_estado then
    raise exception 'TRANSICION_INVALIDA: la reserva ya está %', p_estado using errcode = 'P0001';
  end if;
  update public.reservas set estado = p_estado, motivo = coalesce(v_motivo, motivo)
   where id = p_reserva_id returning * into v_r;
  insert into public.reservas_historial (reserva_id, estado_anterior, estado_nuevo, motivo, cambiado_por)
  values (p_reserva_id, v_anterior, p_estado, v_motivo, coalesce(nullif(p_admin, ''), 'admin'));
  return v_r;
end;
$$;

-- =====================================================================
-- 8. SEGURIDAD: RLS Y PERMISOS
-- =====================================================================
alter table public.servicios          enable row level security;
alter table public.barberos           enable row level security;
alter table public.horarios_barbero   enable row level security;
alter table public.horarios_local     enable row level security;
alter table public.admins             enable row level security;
alter table public.reservas           enable row level security;
alter table public.reservas_historial enable row level security;

-- Catálogo: lectura pública, sin escritura desde el navegador
drop policy if exists "catalogo lectura publica" on public.servicios;
create policy "catalogo lectura publica" on public.servicios for select to anon, authenticated using (activo);
drop policy if exists "catalogo lectura publica" on public.barberos;
create policy "catalogo lectura publica" on public.barberos for select to anon, authenticated using (activo);
drop policy if exists "catalogo lectura publica" on public.horarios_barbero;
create policy "catalogo lectura publica" on public.horarios_barbero for select to anon, authenticated using (true);
drop policy if exists "catalogo lectura publica" on public.horarios_local;
create policy "catalogo lectura publica" on public.horarios_local for select to anon, authenticated using (true);

-- reservas, reservas_historial y admins: SIN políticas para anon/authenticated
-- → desde el navegador no se pueden leer ni escribir. Solo a través de las
--   funciones de arriba (que validan todo) o de service_role en el servidor.

revoke all on public.reservas, public.reservas_historial, public.admins from anon, authenticated;
revoke all on public.servicios, public.barberos, public.horarios_barbero, public.horarios_local from anon, authenticated;
grant select on public.servicios, public.barberos, public.horarios_barbero, public.horarios_local to anon, authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

-- Supabase da EXECUTE a todos por defecto: se quita y se otorga solo lo necesario
revoke execute on function
  public.tz_local(), public.plazo_pendiente(), public.validar_cambio_estado(), public.liberar_pendientes_vencidas(),
  public.obtener_catalogo(), public.obtener_ocupacion(date, date),
  public.crear_solicitud(text[], text, date, time, text, text, text, text),
  public.consultar_solicitud(uuid), public.cancelar_solicitud(uuid),
  public.admin_cambiar_estado(uuid, text, text, text)
from public, anon, authenticated;
grant execute on function public.obtener_catalogo() to anon, authenticated;
grant execute on function public.obtener_ocupacion(date, date) to anon, authenticated;
grant execute on function public.crear_solicitud(text[], text, date, time, text, text, text, text) to anon, authenticated;
grant execute on function public.consultar_solicitud(uuid) to anon, authenticated;
grant execute on function public.cancelar_solicitud(uuid) to anon, authenticated;
grant execute on function public.admin_cambiar_estado(uuid, text, text, text) to service_role;
grant execute on function public.liberar_pendientes_vencidas() to service_role;

-- =====================================================================
-- 9. DATOS INICIALES (mismos que la web). Re-ejecutable.
--    Para cambiar precios/duraciones: editá acá (o en Table Editor) y listo,
--    la web los toma de la base.
-- =====================================================================
insert into public.servicios (id, nombre, categoria, duracion_min, precio_ars) values
  ('corte',     'Corte Clásico / Fade / Degradé',          'cabello',       45, 14000),
  ('infantil',  'Corte Infantil / Juvenil',                'cabello',       35, 11500),
  ('contornos', 'Mantenimiento Contornos & Cuello',        'cabello',       20,  7500),
  ('barba',     'Ritual de Barba Completo',                'barba',         40, 11000),
  ('perfilado', 'Perfilado y Rebaje Express',              'barba',         25,  8000),
  ('cabeza',    'Afeitado de Cabeza a Navaja',             'barba',         40, 13000),
  ('combo',     'Combo Completo Patagónico',               'combos',        75, 22500),
  ('novio',     'Servicio Novio / Evento Especial',        'combos',       105, 38000),
  ('facial',    'Limpieza Facial Profunda con Ozono',      'tratamientos',  35, 12000),
  ('nutricion', 'Baño de Nutrición & Matizador de Canas',  'tratamientos',  30,  9500)
on conflict (id) do update set nombre = excluded.nombre, categoria = excluded.categoria,
  duracion_min = excluded.duracion_min, precio_ars = excluded.precio_ars;

insert into public.barberos (id, nombre) values
  ('facundo',  'Facundo Morales'),
  ('nico',     'Nicolás “Nico” Rossi'),
  ('santiago', 'Santiago Benítez'),
  ('matias',   'Matías Gómez')
on conflict (id) do update set nombre = excluded.nombre;

delete from public.horarios_barbero;
insert into public.horarios_barbero (barbero_id, dia_semana, abre, cierra) values
  ('facundo', 2, '10:00', '19:30'), ('facundo', 3, '10:00', '19:30'), ('facundo', 4, '10:00', '19:30'),
  ('facundo', 5, '10:00', '19:30'), ('facundo', 6, '09:00', '18:00'),
  ('nico', 1, '11:00', '20:30'), ('nico', 2, '11:00', '20:30'), ('nico', 3, '11:00', '20:30'),
  ('nico', 4, '11:00', '20:30'), ('nico', 6, '10:00', '21:00'),
  ('santiago', 1, '09:30', '18:30'), ('santiago', 2, '09:30', '18:30'), ('santiago', 3, '09:30', '18:30'),
  ('santiago', 4, '09:30', '18:30'), ('santiago', 5, '09:30', '18:30'),
  ('matias', 1, '14:00', '20:00'), ('matias', 3, '10:30', '20:30'), ('matias', 4, '10:30', '20:30'),
  ('matias', 5, '10:30', '20:30'), ('matias', 6, '10:30', '20:30');

delete from public.horarios_local;
insert into public.horarios_local (dia_semana, abre, cierra) values
  (1, '09:30', '20:30'), (2, '09:30', '20:30'), (3, '09:30', '20:30'),
  (4, '09:30', '20:30'), (5, '09:30', '20:30'), (6, '09:00', '21:00');
