// Edge Function: crear-personal
//
// Un administrador da de alta a una persona del personal con acceso al sistema:
// 1. Crea la cuenta en Supabase Auth con un email interno <usuario>@personal.lims.local
//    y una contraseña provisoria aleatoria.
// 2. Crea su perfil (rol de personal, debe_cambiar_password = true).
// 3. Crea su fila en personal (usuario, matrícula y cargo).
// Devuelve la contraseña provisoria UNA sola vez, para entregársela a la persona.
// En su primer ingreso el sistema le exige elegir una contraseña propia
// (ver completar_primer_ingreso_personal en la migración 20261013_01).
//
// Corre en el servidor porque crear usuarios requiere la clave secreta,
// que nunca puede estar en el frontend.

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const DOMINIO_PERSONAL = 'personal.lims.local';
const ROLES_PERSONAL = ['admin', 'bioquimico', 'tecnico', 'recepcion'];

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

  // ¿Quién llama? Tiene que ser un administrador activo.
  const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? '';
  const { data: llamador, error: errorLlamador } = await admin.auth.getUser(token);
  if (errorLlamador || !llamador.user) return responder({ error: 'Sesión inválida' }, 401);

  const { data: perfilLlamador } = await admin
    .from('perfiles')
    .select('rol, activo')
    .eq('id', llamador.user.id)
    .single();
  if (!perfilLlamador?.activo || perfilLlamador.rol !== 'admin') {
    return responder({ error: 'Solo un administrador puede dar de alta personal' }, 403);
  }

  let datos: Record<string, unknown>;
  try {
    datos = await req.json();
  } catch {
    return responder({ error: 'El cuerpo de la solicitud no es JSON válido' }, 400);
  }

  const usuario = String(datos.usuario ?? '').trim().toLowerCase();
  const nombre = String(datos.nombre ?? '').trim();
  const apellido = String(datos.apellido ?? '').trim();
  const rol = String(datos.rol ?? '').trim();
  const telefono = String(datos.telefono ?? '').trim() || null;
  const matricula = String(datos.matricula ?? '').trim() || null;
  const cargo = String(datos.cargo ?? '').trim() || null;

  if (!/^[a-z0-9._-]{3,32}$/.test(usuario)) {
    return responder(
      { error: 'El usuario debe tener entre 3 y 32 caracteres: minúsculas, números, punto, guion o guion bajo' },
      400,
    );
  }
  if (!nombre || !apellido) return responder({ error: 'Nombre y apellido son obligatorios' }, 400);
  if (!ROLES_PERSONAL.includes(rol)) return responder({ error: 'El rol no es válido' }, 400);
  if (rol === 'bioquimico' && !matricula) {
    return responder({ error: 'La matrícula es obligatoria para un bioquímico' }, 400);
  }

  const { data: usuarioExistente } = await admin
    .from('personal')
    .select('perfil_id')
    .eq('usuario', usuario)
    .maybeSingle();
  if (usuarioExistente) return responder({ error: 'Ya existe una persona con ese usuario' }, 409);

  if (matricula) {
    const { data: matriculaExistente } = await admin
      .from('personal')
      .select('perfil_id')
      .eq('matricula', matricula)
      .maybeSingle();
    if (matriculaExistente) return responder({ error: 'Esa matrícula ya está asignada a otra persona' }, 409);
  }

  const passwordProvisoria = generarPasswordProvisoria();
  const { data: creado, error: errorCreacion } = await admin.auth.admin.createUser({
    email: `${usuario}@${DOMINIO_PERSONAL}`,
    password: passwordProvisoria,
    email_confirm: true,
  });
  if (errorCreacion || !creado.user) {
    return responder({ error: `No se pudo crear la cuenta: ${errorCreacion?.message}` }, 400);
  }
  const userId = creado.user.id;

  // Si algo falla después de crear la cuenta, se borra para no dejar usuarios huérfanos.
  async function deshacer(mensaje: string) {
    await admin.auth.admin.deleteUser(userId);
    return responder({ error: mensaje }, 500);
  }

  const { error: errorPerfil } = await admin.from('perfiles').insert({
    id: userId,
    rol,
    nombre,
    apellido,
    telefono,
    debe_cambiar_password: true,
  });
  if (errorPerfil) return deshacer(`No se pudo crear el perfil: ${errorPerfil.message}`);

  const { error: errorPersonal } = await admin.from('personal').insert({
    perfil_id: userId,
    usuario,
    matricula,
    cargo,
  });
  if (errorPersonal) return deshacer(`No se pudo guardar los datos del personal: ${errorPersonal.message}`);

  return responder({ usuario, password_provisoria: passwordProvisoria }, 201);
});
