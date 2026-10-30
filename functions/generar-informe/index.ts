// Edge Function: generar-informe
//
// El bioquímico firma el informe de una orden validada (LIMS-15):
// 1. Trae la orden, el paciente, el médico y los resultados validados, con el
//    rango con el que se comparó cada uno.
// 2. Arma el PDF (liviano: letras estándar del PDF, sin fotos).
// 3. Lo sube al bucket privado "informes" en <paciente_id>/<orden_id>.pdf.
// 4. Llama a publicar_informe con el SHA-256 del archivo: el informe queda
//    firmado y publicado, y la orden informada.
// Devuelve una URL firmada para abrir el PDF en el momento.
//
// Todo se hace con la sesión de quien llama (no con la clave secreta): las
// políticas de la base y del bucket deciden qué puede leer y subir.

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { armarPdf, type Estudio } from './pdf.ts';

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

// ── Datos ────────────────────────────────────────

const CAMPOS_ORDEN =
  'id,nro_orden,estado,fecha_orden,fecha_recepcion,paciente_id,' +
  'sucursales(nombre,direccion,localidad),' +
  'pacientes(dni,nombre,apellido,sexo,fecha_nacimiento),' +
  'medicos(nombre,apellido,matricula),obras_sociales(nombre),' +
  'orden_analisis(id,padre_id,grupo_id,analisis(id,codigo,nombre,unidad,absoluto_unidad),grupos_analisis(nombre),' +
  'resultados(valor_numerico,valor_texto,valor_absoluto,fuera_de_rango,ref_min,ref_max,ref_texto,abs_ref_min,abs_ref_max,' +
  'estado,validado_en,validador:perfiles!resultados_validado_por_fkey(nombre,apellido)))';

// Mismo orden que la pantalla de resultados: cada grupo en el orden en que se armó,
// después los sueltos por nombre; los componentes, en el orden del catálogo
async function ordenarEstudios(cliente: SupabaseClient, estudios: Estudio[]) {
  const grupos = [...new Set(estudios.map((e) => e.grupo_id).filter((g) => g !== null))];
  const posiciones: Record<string, number> = {};
  if (grupos.length > 0) {
    const { data } = await cliente
      .from('grupo_analisis_items')
      .select('grupo_id,analisis_id,orden')
      .in('grupo_id', grupos);
    (data ?? []).forEach((item) => {
      posiciones[`${item.grupo_id}-${item.analisis_id}`] = item.orden ?? 0;
    });
  }
  const clave = (e: Estudio) => [
    e.grupo_id ?? Number.MAX_SAFE_INTEGER,
    posiciones[`${e.grupo_id}-${e.analisis.id}`] ?? Number.MAX_SAFE_INTEGER,
    e.padre_id ? e.analisis.id : 0,
  ];
  return [...estudios].sort((a, b) => {
    const [ga, pa, ca] = clave(a);
    const [gb, pb, cb] = clave(b);
    return ga - gb || pa - pb || ca - cb || a.analisis.nombre.localeCompare(b.analisis.nombre, 'es');
  });
}

async function sha256(bytes: Uint8Array) {
  const digest = await crypto.subtle.digest('SHA-256', new Uint8Array(bytes));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

// ── Pedido ───────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return responder({ error: 'Método no permitido' }, 405);

  const autorizacion = req.headers.get('Authorization') ?? '';
  const cliente = createClient(Deno.env.get('SUPABASE_URL')!, clavePublica(), {
    global: { headers: { Authorization: autorizacion } },
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ¿Quién llama? Tiene que ser un bioquímico con la cuenta activa
  const token = autorizacion.replace('Bearer ', '');
  const { data: sesion, error: errorSesion } = await cliente.auth.getUser(token);
  if (errorSesion || !sesion.user) return responder({ error: 'Sesión inválida' }, 401);

  const { data: perfil } = await cliente
    .from('perfiles')
    .select('rol,activo,nombre,apellido')
    .eq('id', sesion.user.id)
    .single();
  if (!perfil?.activo || perfil.rol !== 'bioquimico') {
    return responder({ error: 'Solo el bioquímico firma el informe' }, 403);
  }
  const { data: personal } = await cliente.from('personal').select('matricula').eq('perfil_id', sesion.user.id).single();

  let datos: Record<string, unknown>;
  try {
    datos = await req.json();
  } catch {
    return responder({ error: 'El cuerpo de la solicitud no es JSON válido' }, 400);
  }
  const ordenId = String(datos.orden_id ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(ordenId)) return responder({ error: 'Falta la orden' }, 400);

  // La orden se lee con la sesión del bioquímico: si es de otra sucursal, no aparece
  const { data: leida, error: errorOrden } = await cliente.from('ordenes').select(CAMPOS_ORDEN).eq('id', ordenId).maybeSingle();
  // El select se arma con texto: el tipo de la fila no se puede deducir
  // deno-lint-ignore no-explicit-any
  const orden = leida as any;
  if (errorOrden) {
    console.error('No se pudo leer la orden:', errorOrden);
    return responder({ error: 'No se pudo leer la orden' }, 500);
  }
  if (!orden) return responder({ error: 'No se encontró la orden' }, 404);
  if (orden.estado === 'informada') return responder({ error: `El informe de la orden ${orden.nro_orden} ya está publicado` }, 409);
  if (orden.estado !== 'completa') {
    return responder({ error: `La orden ${orden.nro_orden} todavía no está validada` }, 409);
  }

  const estudios = await ordenarEstudios(cliente, orden.orden_analisis as Estudio[]);
  const pdf = await armarPdf(orden, estudios, {
    nombre: `${perfil.nombre} ${perfil.apellido}`,
    matricula: personal?.matricula ?? null,
  });
  const ruta = `${orden.paciente_id}/${orden.id}.pdf`;

  // Mientras no se publique, firmar de nuevo reemplaza el archivo
  const { error: errorSubida } = await cliente.storage
    .from('informes')
    .upload(ruta, pdf, { contentType: 'application/pdf', upsert: true });
  if (errorSubida) {
    console.error('No se pudo subir el PDF:', errorSubida);
    return responder({ error: 'No se pudo guardar el PDF del informe' }, 500);
  }

  const { data: publicado, error: errorPublicar } = await cliente.rpc('publicar_informe', {
    p_orden_id: orden.id,
    p_pdf_path: ruta,
    p_hash_firma: await sha256(pdf),
  });
  if (errorPublicar) {
    console.error('No se pudo publicar el informe:', errorPublicar);
    return responder({ error: errorPublicar.message || 'No se pudo publicar el informe' }, 400);
  }

  // Link para abrir el PDF ahora; vence en dos minutos
  const { data: firmado } = await cliente.storage.from('informes').createSignedUrl(ruta, 120);

  return responder({ ...publicado, url: firmado?.signedUrl ?? null, bytes: pdf.length });
});
