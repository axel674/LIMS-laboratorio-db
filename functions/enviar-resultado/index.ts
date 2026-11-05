// Edge Function: enviar-resultado
//
// Avisa por mail al paciente que su informe está listo (LIMS-18), con el link al
// portal y sin el PDF adjunto. generar-informe ya lo hace al publicar; esta función
// sirve para reenviarlo (ej: el paciente cargó su email después, o falló el envío).
// Pedido: { orden_id, reenviar? }. Con reenviar: true se manda aunque ya se haya avisado.
//
// Necesita los secretos GMAIL_USER y GMAIL_APP_PASSWORD (ver _shared/correo.ts).
// Todo se hace con la sesión de quien llama: bioquímico o admin de la sucursal.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { avisarResultado } from '../_shared/aviso-resultado.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function responder(cuerpo: unknown, status = 200) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

function clavePublica(): string {
  const nuevas = Deno.env.get('SUPABASE_PUBLISHABLE_KEYS');
  if (nuevas) return JSON.parse(nuevas)['default'];
  return Deno.env.get('SUPABASE_ANON_KEY')!;
}

// Mensaje para el panel según cómo terminó el aviso
const MENSAJES = {
  enviado: 'Se avisó al paciente por mail.',
  ya_enviado: 'Ya se le había avisado al paciente.',
  sin_email: 'El paciente no tiene un email cargado.',
  no_publicado: 'El informe todavía no está publicado.',
  sin_configurar: 'El envío de mails todavía no está configurado.',
  error: 'No se pudo enviar el mail. Intente de nuevo más tarde.',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return responder({ error: 'Método no permitido' }, 405);

  const autorizacion = req.headers.get('Authorization') ?? '';
  const cliente = createClient(Deno.env.get('SUPABASE_URL')!, clavePublica(), {
    global: { headers: { Authorization: autorizacion } },
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const token = autorizacion.replace('Bearer ', '');
  const { data: sesion, error: errorSesion } = await cliente.auth.getUser(token);
  if (errorSesion || !sesion.user) return responder({ error: 'Sesión inválida' }, 401);

  // Los mismos que pueden marcar el informe (políticas de informes)
  const { data: perfil } = await cliente.from('perfiles').select('rol,activo').eq('id', sesion.user.id).single();
  if (!perfil?.activo || !['bioquimico', 'admin'].includes(perfil.rol)) {
    return responder({ error: 'Solo el bioquímico o el administrador avisan al paciente' }, 403);
  }

  let datos: Record<string, unknown>;
  try {
    datos = await req.json();
  } catch {
    return responder({ error: 'El cuerpo de la solicitud no es JSON válido' }, 400);
  }
  const ordenId = String(datos.orden_id ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(ordenId)) return responder({ error: 'Falta la orden' }, 400);

  const resultado = await avisarResultado(cliente, ordenId, datos.reenviar === true);
  const status = resultado === 'enviado' || resultado === 'ya_enviado' || resultado === 'sin_email' ? 200
    : resultado === 'no_publicado' ? 409
    : resultado === 'sin_configurar' ? 503
    : 502;
  return responder(
    status === 200 ? { resultado, mensaje: MENSAJES[resultado] } : { resultado, error: MENSAJES[resultado] },
    status,
  );
});
