// Edge Function: restablecer-password
//
// Le da una contraseña provisoria nueva a una cuenta que la olvidó (LIMS-45):
// - Recepción o el admin, a un paciente (el paciente va al mostrador).
// - Solo el admin, a alguien del personal.
// Nadie restablece la propia: para eso está "Mi perfil".
//
// 1. Genera la contraseña provisoria y la guarda en Supabase Auth.
// 2. Marca debe_cambiar_password: en el siguiente ingreso se pide elegir una propia,
//    como en el primer ingreso.
// 3. Lo registra en cambios_password (a quién, quién y cuándo).
// Devuelve la contraseña UNA sola vez, para entregársela a la persona.
//
// Corre en el servidor porque cambiar la contraseña de otro requiere la clave
// secreta, que nunca puede estar en el frontend.

import { createClient } from 'npm:@supabase/supabase-js@2';

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

function claveSecreta(): string {
  const nuevas = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (nuevas) return JSON.parse(nuevas)['default'];
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
}

// Sin caracteres que se confunden al dictarla o leerla (0/O, 1/l/I)
function generarPasswordProvisoria(largo = 12): string {
  const alfabeto = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  const valores = crypto.getRandomValues(new Uint32Array(largo));
  return Array.from(valores, (v) => alfabeto[v % alfabeto.length]).join('');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return responder({ error: 'Método no permitido' }, 405);

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, claveSecreta(), {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ¿Quién llama? Recepción o un admin, con la cuenta activa
  const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? '';
  const { data: llamador, error: errorLlamador } = await admin.auth.getUser(token);
  if (errorLlamador || !llamador.user) return responder({ error: 'Sesión inválida' }, 401);

  const { data: perfilLlamador } = await admin
    .from('perfiles')
    .select('rol, activo')
    .eq('id', llamador.user.id)
    .single();
  if (!perfilLlamador?.activo || !['admin', 'recepcion'].includes(perfilLlamador.rol)) {
    return responder({ error: 'Solo recepción o un administrador pueden restablecer contraseñas' }, 403);
  }

  let datos: Record<string, unknown>;
  try {
    datos = await req.json();
  } catch {
    return responder({ error: 'El cuerpo de la solicitud no es JSON válido' }, 400);
  }
  const perfilId = String(datos.perfil_id ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(perfilId)) return responder({ error: 'Falta la cuenta' }, 400);
  if (perfilId === llamador.user.id) {
    return responder({ error: 'Su propia contraseña se cambia desde Mi perfil' }, 400);
  }

  const { data: perfil } = await admin
    .from('perfiles')
    .select('rol, activo, nombre, apellido')
    .eq('id', perfilId)
    .maybeSingle();
  if (!perfil) return responder({ error: 'No se encontró la cuenta' }, 404);
  if (!perfil.activo) return responder({ error: 'La cuenta está desactivada: actívela antes de restablecer la contraseña' }, 409);
  if (perfil.rol !== 'paciente' && perfilLlamador.rol !== 'admin') {
    return responder({ error: 'Solo un administrador restablece la contraseña del personal' }, 403);
  }

  const password = generarPasswordProvisoria();
  const { error: errorAuth } = await admin.auth.admin.updateUserById(perfilId, { password });
  if (errorAuth) {
    console.error('No se pudo cambiar la contraseña:', errorAuth);
    return responder({ error: 'No se pudo restablecer la contraseña' }, 500);
  }

  // La contraseña ya cambió: si falla alguno de estos pasos se avisa en el log, pero la
  // provisoria igual se entrega (si no, la persona quedaría sin poder entrar)
  const { error: errorPerfil } = await admin.from('perfiles').update({ debe_cambiar_password: true }).eq('id', perfilId);
  if (errorPerfil) console.error('No se pudo marcar el cambio obligatorio:', errorPerfil);
  const { error: errorRegistro } = await admin
    .from('cambios_password')
    .insert({ perfil_id: perfilId, via: 'panel', hecho_por: llamador.user.id });
  if (errorRegistro) console.error('No se pudo registrar el cambio de contraseña:', errorRegistro);

  return responder({ password, nombre: perfil.nombre, apellido: perfil.apellido });
});
