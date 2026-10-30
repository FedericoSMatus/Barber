# Patagonia Grooming Co. · Barbería & Club · Neuquén

Sitio web de una sola página (`index.html`) con navegación entre secciones:
Inicio, Servicios & Tarifas, Profesionales, Reservar Turno y Ubicación & Horarios.
Reservas guardadas en **Supabase** y panel de administración en `/admin`.
Se despliega en **Vercel** (archivos estáticos + funciones en `/api`).

## Cómo funciona una reserva

1. El cliente elige servicio(s), barbero, día y horario. Solo se muestran horarios libres
   (los turnos PENDIENTES y CONFIRMADOS ocupan el lugar).
2. Completa sus datos y toca **Confirmar Reserva** → la solicitud se guarda en Supabase con estado **PENDIENTE**
   y recibe un código (ej. `3B5631`) y un enlace privado de seguimiento (`/#turno/<token>`).
3. Se abre el mensaje de WhatsApp para la barbería con todos los datos, el código y el enlace.
4. La barbería entra a `/admin`, revisa la solicitud y la **confirma**, **rechaza** o **cancela**.
   El panel arma el mensaje de WhatsApp para avisarle al cliente.
5. En el enlace de seguimiento el cliente ve el estado actualizado. Recién cuando está **CONFIRMADO**
   aparece “Agregar a Google Calendar” como turno confirmado. Mientras está pendiente, el evento
   opcional se crea con el título “⏳ PENDIENTE DE CONFIRMACIÓN”.

Estados: `PENDIENTE` → `CONFIRMADO` | `RECHAZADO` | `CANCELADO`; `CONFIRMADO` → `CANCELADO`.

**Vencimiento de pendientes:** una solicitud PENDIENTE bloquea el horario como máximo **12 horas**
(o hasta la hora del turno, lo que ocurra primero). Si nadie la confirma, pasa sola a `CANCELADO`
con motivo “Vencida: no se confirmó a tiempo” y el horario se libera. El plazo se cambia en la
función `plazo_pendiente()` de `supabase/schema.sql`.
Cada cambio queda registrado en `reservas_historial` con fecha y quién lo hizo.
El cliente puede cancelar su propia solicitud desde el seguimiento hasta 2 horas antes.

Si Supabase no responde, la web sigue funcionando como antes: avisa que no pudo registrar la
solicitud y permite enviarla igual por WhatsApp o reintentar.

## Estructura

| Archivo | Qué hace |
|---|---|
| `index.html` | Sitio público + turnero + página de seguimiento |
| `admin.html` | Panel de turnos (login con Supabase Auth) |
| `api/config.js` | Entrega al navegador la URL y la clave **pública** de Supabase |
| `api/admin/reservas.js` | Lista de reservas (solo administradores) |
| `api/admin/estado.js` | Confirmar / rechazar / cancelar (solo administradores) |
| `api/_lib/supabase.js` | Utilidades del servidor (cliente service_role, verificación de admin) |
| `supabase/schema.sql` | Tablas, restricciones, índices, funciones, RLS y datos iniciales |
| `supabase/verificacion.sql` | Controles de solo lectura para ejecutar después del schema |

## Configuración (una sola vez)

### 1. Supabase
1. Creá un proyecto en <https://supabase.com>.
2. **SQL Editor** → pegá el contenido de `supabase/schema.sql` → **Run**.
   Después ejecutá `supabase/verificacion.sql`: todas las filas deben decir `OK`
   (la del administrador se completa en el paso 5).
3. **Authentication → Sign In / Providers**: desactivá **Allow new users to sign up**
   (los administradores los creás vos).
4. **Authentication → Users → Add user → Create new user**: email y contraseña del administrador
   (marcá *Auto Confirm User*).
5. **SQL Editor** → dale permisos de administrador a ese usuario:
   ```sql
   insert into public.admins (user_id, nombre)
   select id, 'Administrador' from auth.users where email = 'TU-EMAIL@ejemplo.com';
   ```
6. **Project Settings → API Keys**: copiá la **Publishable key** (`sb_publishable_…`) y la
   **Secret key** (`sb_secret_…`). La Project URL está en **Project Settings → Data API**.

### 2. Vercel
1. Importá el repositorio de GitHub en Vercel (Framework Preset: **Other**, sin build command).
2. **Settings → Environment Variables** (Production y Preview):

   | Variable | Valor | Visibilidad |
   |---|---|---|
   | `SUPABASE_URL` | `https://xxxx.supabase.co` | pública |
   | `SUPABASE_PUBLISHABLE_KEY` | `sb_publishable_…` | pública (protegida por RLS) |
   | `SUPABASE_SECRET_KEY` | `sb_secret_…` | **secreta, solo servidor** |

   (Si usás las claves clásicas, también funcionan `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY`.)

3. Deploy. El panel queda en `https://tu-dominio/admin`.

## Seguridad

- **RLS activado en todas las tablas.** `reservas`, `reservas_historial` y `admins` no tienen
  políticas para `anon`/`authenticated`: desde el navegador no se pueden leer ni escribir.
- El navegador solo usa funciones controladas: `obtener_ocupacion` (sin datos personales),
  `crear_solicitud` (valida todo y siempre crea `PENDIENTE`), `consultar_solicitud` y
  `cancelar_solicitud` (con el token privado del cliente).
- Precio y duración se calculan en la base, no se confía en el navegador.
- **Turnos superpuestos imposibles**: restricción `EXCLUDE` por barbero + rango horario, más un
  bloqueo por día al asignar “Cualquier barbero”. Dos solicitudes simultáneas → solo una entra.
- Anti-spam: máximo 3 solicitudes pendientes futuras por teléfono.
- `admin_cambiar_estado` solo la puede ejecutar `service_role`, y solo se usa desde las funciones
  de Vercel después de verificar la sesión del usuario y que esté en la tabla `admins`.
- La clave `service_role` vive únicamente en las variables de entorno de Vercel.

## Personalización

**Supabase es la fuente oficial** de precios, duraciones, servicios activos, barberos activos y
horarios: la web los lee al cargar (`obtener_catalogo`). Para cambiarlos, editá las tablas
`servicios`, `barberos`, `horarios_barbero` y `horarios_local` en Supabase (Table Editor).
Un servicio con `activo = false` desaparece de la web.

Los textos, descripciones, íconos y fotos siguen en `SERVICES` y `BARBERS` al final de
`index.html` (se usan si el `id` coincide con el de la base). Si Supabase no responde, la web
muestra esos valores como respaldo.

## Desarrollo local

```bash
npm install
npx vercel dev
```
Con un archivo `.env.local` basado en `.env.example`.
