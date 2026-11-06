// Edge Function: recuperar-password
//
// "¿Olvidó su contraseña?" del portal del paciente (LIMS-45). El paciente escribe su DNI
// y, si cargó su email en el primer ingreso, le llega un link para elegir una nueva.
//
// La cuenta de Supabase Auth usa un email interno (<dni>@pacientes.lims.local) que no
// recibe correos: por eso el link lo genera esta función con la clave secreta y lo manda
// por la cuenta de Gmail del laboratorio al email real del paciente.
//
// - Responde siempre lo mismo, exista o no el DNI: así no sirve para averiguar quién es
//   paciente del laboratorio.
// - Manda como mucho un mail cada 5 minutos por paciente.
// - El link vence en 1 hora (lo que dura el link de recuperación de Supabase) y lleva a
//   /restablecer-password, donde el paciente elige la contraseña nueva.
// - El personal no tiene email: si se olvida la contraseña, se la restablece el admin.
//
// Se despliega con verify_jwt en false: la llama alguien que todavía no inició sesión.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { enviarCorreo, escaparHtml } from '../_shared/correo.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Dirección del sitio publicado. SITIO_URL permite cambiarla sin tocar el código
const SITIO = Deno.env.get('SITIO_URL') ?? 'https://lims-laboratorio-frontend.vercel.app';
const ESPERA_MINUTOS = 5;

// La misma respuesta para todos los casos (ver arriba)
const RESPUESTA = {
  mensaje: 'Si el DNI corresponde a un paciente con email cargado, le enviamos un link para restablecer la contraseña.',
};

function responder(cuerpo: unknown, status = 200) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

function claveSecreta(): string {
  const nuevas = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (nuevas) return JSON.parse(nuevas)['default'];
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
}

// El link vuelve al sitio desde donde se pidió si es el publicado o uno local de desarrollo.
// Supabase además solo redirige a las direcciones permitidas en Auth → URL Configuration.
function sitioDeVuelta(req: Request) {
  const origen = req.headers.get('Origin') ?? '';
  return origen === SITIO || /^http:\/\/localhost:\d+$/.test(origen) ? origen : SITIO;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return responder({ error: 'Método no permitido' }, 405);

  let datos: Record<string, unknown>;
  try {
    datos = await req.json();
  } catch {
    return responder({ error: 'El cuerpo de la solicitud no es JSON válido' }, 400);
  }
  const dni = String(datos.dni ?? '').replace(/[.\s]/g, '');
  if (!/^\d{7,8}$/.test(dni)) return responder({ error: 'Ingrese su DNI: solo números, 7 u 8 dígitos.' }, 400);

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, claveSecreta(), {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: paciente } = await admin
    .from('pacientes')
    .select('perfil_id, nombre, email, perfiles(activo)')
    .eq('dni', dni)
    .maybeSingle();
  // deno-lint-ignore no-explicit-any
  const activo = (paciente?.perfiles as any)?.activo === true;
  const email = paciente?.email?.trim();
  if (!paciente?.perfil_id || !activo || !email) return responder(RESPUESTA);

  // Un mail cada 5 minutos como mucho, para que nadie le llene la casilla con su DNI
  const desde = new Date(Date.now() - ESPERA_MINUTOS * 60_000).toISOString();
  const { count } = await admin
    .from('cambios_password')
    .select('id', { count: 'exact', head: true })
    .eq('perfil_id', paciente.perfil_id)
    .eq('via', 'mail_pedido')
    .gte('creado_en', desde);
  if ((count ?? 0) > 0) return responder(RESPUESTA);

  const { data: cuenta } = await admin.auth.admin.getUserById(paciente.perfil_id);
  if (!cuenta?.user?.email) return responder(RESPUESTA);

  const { data: link, error: errorLink } = await admin.auth.admin.generateLink({
    type: 'recovery',
    email: cuenta.user.email,
    options: { redirectTo: `${sitioDeVuelta(req)}/restablecer-password` },
  });
  // Si algo falla se responde igual que siempre: un error distinto delataría que el DNI tiene email
  if (errorLink || !link?.properties?.action_link) {
    console.error('No se pudo generar el link de recuperación:', errorLink);
    return responder(RESPUESTA);
  }
  const url = link.properties.action_link;

  // Se registra antes de mandar: completar_recuperacion_password exige este pedido
  const { error: errorRegistro } = await admin
    .from('cambios_password')
    .insert({ perfil_id: paciente.perfil_id, via: 'mail_pedido' });
  if (errorRegistro) {
    console.error('No se pudo registrar el pedido de recuperación:', errorRegistro);
    return responder(RESPUESTA);
  }

  try {
    await enviarCorreo({
      para: email,
      asunto: 'Restablecer su contraseña · LIMS Laboratorio',
      texto:
        `Hola ${paciente.nombre}:\n\n` +
        'Recibimos un pedido para restablecer la contraseña del portal de resultados.\n' +
        `Para elegir una nueva, abra este link (vence en 1 hora):\n${url}\n\n` +
        'Si no lo pidió usted, ignore este mail: su contraseña no cambia.\n\n' +
        'LIMS Laboratorio Bioquímico',
      html:
        `<p>Hola ${escaparHtml(paciente.nombre)}:</p>` +
        '<p>Recibimos un pedido para restablecer la contraseña del portal de resultados.</p>' +
        `<p><a href="${escaparHtml(url)}">Elegir una contraseña nueva</a> (el link vence en 1 hora).</p>` +
        '<p style="color:#666;font-size:13px">Si no lo pidió usted, ignore este mail: su contraseña no cambia.</p>' +
        '<p>LIMS Laboratorio Bioquímico</p>',
    });
  } catch (errorEnvio) {
    console.error('No se pudo enviar el mail de recuperación:', errorEnvio);
  }

  return responder(RESPUESTA);
});
