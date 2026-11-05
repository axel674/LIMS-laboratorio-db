// Aviso al paciente de que su informe está listo (LIMS-18).
//
// Lo usan generar-informe (al publicar) y enviar-resultado (para reenviarlo).
// - El mail lleva solo el aviso y el link al portal: el PDF NO se adjunta (son
//   datos de salud y el mail puede terminar en manos de otro).
// - Si el paciente no cargó su email (lo carga en su primer ingreso), no se envía.
// - Después de enviar se marca informes.email_enviado_en, que es lo único que se
//   puede cambiar de un informe publicado.
// Todo con el cliente de quien llama: las políticas deciden si puede leer la orden
// y marcar el informe (bioquímico o admin de la sucursal).

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { CorreoSinConfigurar, enviarCorreo, escaparHtml } from './correo.ts';

// Dirección del sitio publicado. SITIO_URL permite cambiarla sin tocar el código
const SITIO = Deno.env.get('SITIO_URL') ?? 'https://lims-laboratorio-frontend.vercel.app';

export type ResultadoAviso =
  | 'enviado' // se mandó y quedó marcado
  | 'ya_enviado' // ya se había avisado (y no se pidió reenviar)
  | 'sin_email' // el paciente no tiene email cargado
  | 'no_publicado' // el informe todavía no se publicó
  | 'sin_configurar' // faltan los secretos del mail en Supabase
  | 'error'; // falló el envío (se puede reintentar con enviar-resultado)

export async function avisarResultado(
  cliente: SupabaseClient,
  ordenId: string,
  reenviar = false,
): Promise<ResultadoAviso> {
  const { data, error } = await cliente
    .from('ordenes')
    .select('nro_orden,pacientes(nombre,email),informes(id,estado,email_enviado_en)')
    .eq('id', ordenId)
    .maybeSingle();
  if (error || !data) {
    console.error('Aviso por mail: no se pudo leer la orden', ordenId, error);
    return 'error';
  }
  // El select se arma con texto: el tipo de la fila no se puede deducir
  // deno-lint-ignore no-explicit-any
  const orden = data as any;
  const informe = Array.isArray(orden.informes) ? orden.informes[0] : orden.informes;
  const email: string | null = orden.pacientes?.email?.trim() || null;

  if (informe?.estado !== 'publicado') return 'no_publicado';
  if (informe.email_enviado_en && !reenviar) return 'ya_enviado';
  if (!email) return 'sin_email';

  const nombre = orden.pacientes.nombre as string;
  const link = `${SITIO}/mis-estudios`;
  try {
    await enviarCorreo({
      para: email,
      asunto: 'Sus resultados están disponibles · LIMS Laboratorio',
      texto:
        `Hola ${nombre}:\n\n` +
        `Los resultados de su orden ${orden.nro_orden} ya están disponibles.\n` +
        `Para verlos y descargar el informe, ingrese al portal con su DNI:\n${link}\n\n` +
        'Por su privacidad, el informe no va adjunto a este mail.\n\n' +
        'LIMS Laboratorio Bioquímico',
      html:
        `<p>Hola ${escaparHtml(nombre)}:</p>` +
        `<p>Los resultados de su orden <strong>${escaparHtml(orden.nro_orden)}</strong> ya están disponibles.</p>` +
        `<p>Para verlos y descargar el informe, ingrese al portal con su DNI:</p>` +
        `<p><a href="${link}">${link}</a></p>` +
        '<p style="color:#666;font-size:13px">Por su privacidad, el informe no va adjunto a este mail.</p>' +
        '<p>LIMS Laboratorio Bioquímico</p>',
    });
  } catch (errorEnvio) {
    if (errorEnvio instanceof CorreoSinConfigurar) return 'sin_configurar';
    console.error('Aviso por mail: no se pudo enviar', orden.nro_orden, errorEnvio);
    return 'error';
  }

  const { error: errorMarca } = await cliente
    .from('informes')
    .update({ email_enviado_en: new Date().toISOString() })
    .eq('id', informe.id);
  // El mail ya salió: si no se pudo marcar, solo queda registrado en el log
  if (errorMarca) console.error('Aviso por mail: se envió pero no se pudo marcar', orden.nro_orden, errorMarca);
  return 'enviado';
}
