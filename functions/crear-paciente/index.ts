// Edge Function: crear-paciente
//
// Recepción (o un admin) da de alta a un paciente con acceso al portal:
// 1. Crea la cuenta en Supabase Auth con un email interno <dni>@pacientes.lims.local
//    y una contraseña provisoria aleatoria.
// 2. Crea su perfil (rol paciente, debe_cambiar_password = true).
// 3. Crea su ficha en pacientes, o enlaza la ficha si el DNI ya estaba cargado.
//    Obra social: obra_social_id vacío = particular; si tiene obra social, el
//    número de afiliado es obligatorio.
// Devuelve el id de la ficha y la contraseña provisoria UNA sola vez, para
// entregársela al paciente.
//
// Corre en el servidor porque crear usuarios requiere la clave secreta,
// que nunca puede estar en el frontend.

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const DOMINIO_PACIENTES = 'pacientes.lims.local';

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
function generarPasswordProvisoria(largo = 10): string {
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

  // ¿Quién llama? Tiene que ser recepción o admin.
  const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? '';
  const { data: llamador, error: errorLlamador } = await admin.auth.getUser(token);
  if (errorLlamador || !llamador.user) return responder({ error: 'Sesión inválida' }, 401);

  const { data: perfilLlamador } = await admin
    .from('perfiles')
    .select('rol, activo')
    .eq('id', llamador.user.id)
    .single();
  if (!perfilLlamador?.activo || !['recepcion', 'admin'].includes(perfilLlamador.rol)) {
    return responder({ error: 'Solo recepción o un administrador pueden dar de alta pacientes' }, 403);
  }

  let datos: Record<string, unknown>;
  try {
    datos = await req.json();
  } catch {
    return responder({ error: 'El cuerpo de la solicitud no es JSON válido' }, 400);
  }

  const dni = String(datos.dni ?? '').replace(/[.\s]/g, '');
  const nombre = String(datos.nombre ?? '').trim();
  const apellido = String(datos.apellido ?? '').trim();
  const fechaNacimiento = String(datos.fecha_nacimiento ?? '').trim();

  if (!/^\d{7,8}$/.test(dni)) return responder({ error: 'El DNI debe tener 7 u 8 dígitos' }, 400);
  if (!nombre || !apellido) return responder({ error: 'Nombre y apellido son obligatorios' }, 400);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fechaNacimiento)) {
    return responder({ error: 'La fecha de nacimiento debe tener el formato AAAA-MM-DD' }, 400);
  }

  const obraSocialId = datos.obra_social_id ? Number(datos.obra_social_id) : null;
  const nroAfiliado = String(datos.nro_afiliado ?? '').trim() || null;
  if (obraSocialId !== null) {
    if (!Number.isInteger(obraSocialId)) return responder({ error: 'La obra social no es válida' }, 400);
    const { data: obraSocial } = await admin
      .from('obras_sociales')
      .select('id')
      .eq('id', obraSocialId)
      .eq('activa', true)
      .maybeSingle();
    if (!obraSocial) return responder({ error: 'La obra social elegida no existe o no está activa' }, 400);
    if (!nroAfiliado) return responder({ error: 'El número de afiliado es obligatorio si tiene obra social' }, 400);
  }

  const { data: fichaExistente } = await admin
    .from('pacientes')
    .select('id, perfil_id')
    .eq('dni', dni)
    .maybeSingle();
  if (fichaExistente?.perfil_id) {
    return responder({ error: 'Este paciente ya tiene una cuenta en el portal' }, 409);
  }

  const passwordProvisoria = generarPasswordProvisoria();
  const { data: creado, error: errorCreacion } = await admin.auth.admin.createUser({
    email: `${dni}@${DOMINIO_PACIENTES}`,
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
    rol: 'paciente',
    nombre,
    apellido,
    telefono: datos.telefono || null,
    debe_cambiar_password: true,
  });
  if (errorPerfil) return deshacer(`No se pudo crear el perfil: ${errorPerfil.message}`);

  const ficha = {
    perfil_id: userId,
    dni,
    nombre,
    apellido,
    fecha_nacimiento: fechaNacimiento,
    sexo: datos.sexo || null,
    telefono: datos.telefono || null,
    obra_social_id: obraSocialId,
    nro_afiliado: obraSocialId === null ? null : nroAfiliado,
  };
  const { data: fichaGuardada, error: errorFicha } = fichaExistente
    ? await admin.from('pacientes').update(ficha).eq('id', fichaExistente.id).select('id').single()
    : await admin.from('pacientes').insert(ficha).select('id').single();
  if (errorFicha) return deshacer(`No se pudo guardar la ficha del paciente: ${errorFicha.message}`);

  return responder({ paciente_id: fichaGuardada.id, dni, password_provisoria: passwordProvisoria }, 201);
});
