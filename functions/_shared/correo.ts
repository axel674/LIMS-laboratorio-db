// Envío de mails del laboratorio (LIMS-18; lo va a reutilizar LIMS-45).
//
// Sin dominio propio, se manda desde la cuenta de Gmail del laboratorio por los
// servidores de Google (SMTP, puerto 465 con SSL): así pasa los controles
// anti-spam. Supabase no deja salir por los puertos 25 y 587.
//
// La cuenta y su contraseña de aplicación son secretos de Supabase
// (Edge Functions → Secrets): GMAIL_USER y GMAIL_APP_PASSWORD. Nunca van en el código.
// Si se compra un dominio, se cambia este archivo por Resend sin tocar el resto.

import nodemailer from 'npm:nodemailer@6.9.16';

export type Correo = {
  para: string;
  asunto: string;
  texto: string;
  html: string;
};

// Error propio: la función que llama distingue "falta configurar" de "falló el envío"
export class CorreoSinConfigurar extends Error {}

export async function enviarCorreo({ para, asunto, texto, html }: Correo) {
  const usuario = Deno.env.get('GMAIL_USER');
  // Google la muestra en grupos de 4 letras: se sacan los espacios por si se cargó así
  const clave = Deno.env.get('GMAIL_APP_PASSWORD')?.replace(/\s/g, '');
  if (!usuario || !clave) {
    throw new CorreoSinConfigurar('Faltan los secretos GMAIL_USER y GMAIL_APP_PASSWORD en Supabase');
  }

  const transporte = nodemailer.createTransport({
    host: 'smtp.gmail.com',
    port: 465,
    secure: true,
    auth: { user: usuario, pass: clave },
  });

  await transporte.sendMail({
    from: `"LIMS Laboratorio" <${usuario}>`,
    to: para,
    subject: asunto,
    text: texto,
    html,
  });
}

// Para meter datos del paciente en el HTML del mail sin que se interpreten como etiquetas
export function escaparHtml(texto: string) {
  return texto.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
}
