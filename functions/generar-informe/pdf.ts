// Armado del PDF del informe de resultados (LIMS-15). Está aparte de index.ts para poder
// probarlo sin la base: recibe los datos ya leídos y devuelve los bytes del PDF.
// Usa las letras estándar del PDF (no se incrustan) y un logo chico: pesa pocos KB.

import { PDFDocument, PDFFont, PDFPage, StandardFonts, rgb } from 'npm:pdf-lib@1.17.1';
import { LOGO_PNG_BASE64 } from './logo.ts';

const ZONA = 'America/Argentina/Tucuman';
const SEXOS: Record<string, string> = { F: 'Femenino', M: 'Masculino', X: 'X' };

// ── Datos ────────────────────────────────────────

export type Resultado = {
  valor_numerico: number | null;
  valor_texto: string | null;
  valor_absoluto: number | null;
  fuera_de_rango: boolean;
  ref_min: number | null;
  ref_max: number | null;
  ref_texto: string | null;
  abs_ref_min: number | null;
  abs_ref_max: number | null;
  estado: string;
  validado_en: string | null;
  validador: { nombre: string; apellido: string } | null;
};

export type Estudio = {
  id: string;
  padre_id: string | null;
  grupo_id: number | null;
  analisis: { id: number; codigo: string; nombre: string; unidad: string | null; absoluto_unidad: string | null };
  grupos_analisis: { nombre: string } | null;
  resultados: Resultado | Resultado[] | null;
};

// PostgREST devuelve el resultado como objeto (un estudio tiene uno solo); por las dudas acepta lista
export function resultadoDe(estudio: Estudio): Resultado | null {
  const r = estudio.resultados;
  return Array.isArray(r) ? (r[0] ?? null) : (r ?? null);
}

// ── Formatos ─────────────────────────────────────

function numero(valor: number) {
  return Number(valor).toLocaleString('es-AR', { maximumFractionDigits: 4 });
}

function referencia(min: number | null, max: number | null, texto: string | null) {
  if (min !== null && max !== null) return `${numero(min)} – ${numero(max)}`;
  if (max !== null) return `Hasta ${numero(max)}`;
  if (min !== null) return `Desde ${numero(min)}`;
  // "Ver informe": el estudio no tiene un valor de referencia que comparar
  return texto && texto !== 'Ver informe' ? texto : '—';
}

function fecha(valor: string) {
  // Una fecha sin hora ("AAAA-MM-DD") se lee como ese día, sin correrla por la zona horaria
  const d = /^\d{4}-\d{2}-\d{2}$/.test(valor) ? new Date(`${valor}T12:00:00Z`) : new Date(valor);
  return new Intl.DateTimeFormat('es-AR', { timeZone: ZONA, day: '2-digit', month: '2-digit', year: 'numeric' }).format(d);
}

function hora(valor: string) {
  return new Intl.DateTimeFormat('es-AR', { timeZone: ZONA, hour: '2-digit', minute: '2-digit', hour12: false }).format(
    new Date(valor),
  );
}

function edad(nacimiento: string, alDia: string) {
  const [a, m, d] = nacimiento.split('-').map(Number);
  const [ha, hm, hd] = alDia.split('-').map(Number);
  return ha - a - (hm < m || (hm === m && hd < d) ? 1 : 0);
}

// Alto o bajo respecto del rango con el que se comparó; "Fuera" si es un texto distinto
function marca(valor: number | null, min: number | null, max: number | null, fuera: boolean) {
  if (valor !== null && max !== null && valor > max) return 'Alto';
  if (valor !== null && min !== null && valor < min) return 'Bajo';
  return fuera ? 'Fuera' : '';
}

// ── PDF ──────────────────────────────────────────

const AZUL = rgb(0x1c / 255, 0x4e / 255, 0x80 / 255);
const GRIS = rgb(0.4, 0.4, 0.4);
const LINEA = rgb(0.82, 0.85, 0.89);
const NARANJA = rgb(0xb5 / 255, 0x47 / 255, 0x08 / 255);
const NEGRO = rgb(0.1, 0.1, 0.1);

const ANCHO = 595.28; // A4
const ALTO = 841.89;
const MARGEN = 42;
const PIE = 54;
const RENGLON = 11; // alto de cada renglón de la tabla

// Columnas de la tabla de resultados
const COL = { estudio: MARGEN, resultado: 262, unidad: 342, referencia: 418, marca: 516 };
const ANCHO_ESTUDIO = COL.resultado - COL.estudio - 8;
const ANCHO_REFERENCIA = COL.marca - COL.referencia - 6;

class Informe {
  doc!: PDFDocument;
  normal!: PDFFont;
  negrita!: PDFFont;
  pagina!: PDFPage;
  y = 0;
  titulo = '';

  static async crear(titulo: string) {
    const informe = new Informe();
    informe.doc = await PDFDocument.create();
    informe.normal = await informe.doc.embedFont(StandardFonts.Helvetica);
    informe.negrita = await informe.doc.embedFont(StandardFonts.HelveticaBold);
    informe.titulo = titulo;
    informe.doc.setTitle(titulo);
    informe.doc.setAuthor('LIMS Laboratorio Bioquímico');
    informe.doc.setProducer('LIMS Laboratorio');
    return informe;
  }

  // Las letras estándar del PDF no tienen todos los caracteres: los que faltan se cambian
  seguro(texto: string, fuente: PDFFont) {
    return Array.from(texto)
      .map((c) => {
        try {
          fuente.encodeText(c);
          return c;
        } catch {
          return c === '≤' ? '<=' : c === '≥' ? '>=' : '?';
        }
      })
      .join('');
  }

  escribir(texto: string, x: number, y: number, opciones: { tam?: number; negrita?: boolean; color?: ReturnType<typeof rgb> } = {}) {
    const fuente = opciones.negrita ? this.negrita : this.normal;
    this.pagina.drawText(this.seguro(texto, fuente), {
      x,
      y,
      size: opciones.tam ?? 9.5,
      font: fuente,
      color: opciones.color ?? NEGRO,
    });
  }

  // Corta un texto en renglones que entren en el ancho dado
  renglones(texto: string, ancho: number, tam = 9.5, negrita = false) {
    const fuente = negrita ? this.negrita : this.normal;
    const palabras = this.seguro(texto, fuente).split(/\s+/);
    const lineas: string[] = [];
    let actual = '';
    for (const palabra of palabras) {
      const prueba = actual ? `${actual} ${palabra}` : palabra;
      if (fuente.widthOfTextAtSize(prueba, tam) <= ancho || !actual) actual = prueba;
      else {
        lineas.push(actual);
        actual = palabra;
      }
    }
    if (actual) lineas.push(actual);
    return lineas;
  }

  nuevaPagina() {
    this.pagina = this.doc.addPage([ANCHO, ALTO]);
    this.y = ALTO - MARGEN;
  }

  // Si no entra lo que sigue, pasa a otra página y repite el encabezado de la tabla
  lugar(alto: number, conEncabezado = true) {
    if (this.y - alto >= PIE) return;
    this.nuevaPagina();
    this.escribir(this.titulo, MARGEN, this.y - 10, { tam: 9, negrita: true, color: AZUL });
    this.y -= 26;
    if (conEncabezado) this.encabezadoTabla();
  }

  linea(y: number, grosor = 0.6, color = LINEA) {
    this.pagina.drawLine({ start: { x: MARGEN, y }, end: { x: ANCHO - MARGEN, y }, thickness: grosor, color });
  }

  encabezadoTabla() {
    const y = this.y - 10;
    this.escribir('Estudio', COL.estudio, y, { tam: 8.5, negrita: true, color: GRIS });
    this.escribir('Resultado', COL.resultado, y, { tam: 8.5, negrita: true, color: GRIS });
    this.escribir('Unidad', COL.unidad, y, { tam: 8.5, negrita: true, color: GRIS });
    this.escribir('Valor de referencia', COL.referencia, y, { tam: 8.5, negrita: true, color: GRIS });
    this.linea(y - 5, 0.8, AZUL);
    this.y = y - 16;
  }

  // Una fila de la tabla. sangria: los componentes van corridos debajo de su estudio
  fila(datos: {
    estudio: string;
    resultado?: string;
    unidad?: string;
    referencia?: string;
    marca?: string;
    sangria?: boolean;
    negritaEstudio?: boolean;
    detalle?: { resultado: string; unidad: string; referencia: string; marca: string } | null;
  }) {
    const xEstudio = COL.estudio + (datos.sangria ? 12 : 0);
    const lineasEstudio = this.renglones(datos.estudio, ANCHO_ESTUDIO - (datos.sangria ? 12 : 0), 9.5, datos.negritaEstudio);
    const lineasRef = this.renglones(datos.referencia ?? '', ANCHO_REFERENCIA, 9);
    const renglones = Math.max(lineasEstudio.length, lineasRef.length) + (datos.detalle ? 1 : 0);
    const alto = renglones * RENGLON + 4;
    this.lugar(alto);

    const fuera = Boolean(datos.marca);
    let y = this.y - 9;
    lineasEstudio.forEach((texto, i) =>
      this.escribir(texto, xEstudio, y - i * RENGLON, { negrita: datos.negritaEstudio }),
    );
    if (datos.resultado) {
      this.escribir(datos.resultado, COL.resultado, y, { negrita: fuera, color: fuera ? NARANJA : NEGRO });
    }
    if (datos.unidad) this.escribir(datos.unidad, COL.unidad, y, { tam: 9, color: GRIS });
    lineasRef.forEach((texto, i) => this.escribir(texto, COL.referencia, y - i * RENGLON, { tam: 9 }));
    if (datos.marca) this.escribir(datos.marca, COL.marca, y, { tam: 8.5, negrita: true, color: NARANJA });

    // Segundo renglón: el valor absoluto de un componente en %
    if (datos.detalle) {
      y -= Math.max(lineasEstudio.length, lineasRef.length) * RENGLON;
      const f = Boolean(datos.detalle.marca);
      this.escribir('Absoluto', xEstudio + 10, y, { tam: 8.5, color: GRIS });
      this.escribir(datos.detalle.resultado, COL.resultado, y, { tam: 9, negrita: f, color: f ? NARANJA : NEGRO });
      this.escribir(datos.detalle.unidad, COL.unidad, y, { tam: 8.5, color: GRIS });
      this.escribir(datos.detalle.referencia, COL.referencia, y, { tam: 8.5 });
      if (datos.detalle.marca) this.escribir(datos.detalle.marca, COL.marca, y, { tam: 8.5, negrita: true, color: NARANJA });
    }

    this.y -= alto;
    this.linea(this.y + 3);
  }

  subtitulo(texto: string) {
    this.lugar(30);
    this.y -= 4;
    this.escribir(texto, COL.estudio, this.y - 9, { tam: 9.5, negrita: true, color: AZUL });
    this.y -= 15;
  }

  // Pie de cada página: número de orden y página
  numerarPaginas(nroOrden: string) {
    const paginas = this.doc.getPages();
    paginas.forEach((pagina, i) => {
      const texto = `Página ${i + 1} de ${paginas.length}`;
      pagina.drawLine({ start: { x: MARGEN, y: 38 }, end: { x: ANCHO - MARGEN, y: 38 }, thickness: 0.6, color: LINEA });
      pagina.drawText(this.seguro(`LIMS Laboratorio Bioquímico · Orden ${nroOrden}`, this.normal), {
        x: MARGEN,
        y: 26,
        size: 8,
        font: this.normal,
        color: GRIS,
      });
      pagina.drawText(texto, {
        x: ANCHO - MARGEN - this.normal.widthOfTextAtSize(texto, 8),
        y: 26,
        size: 8,
        font: this.normal,
        color: GRIS,
      });
    });
  }
}

// Arma el PDF del informe. estudios: los de la orden, ya ordenados como en la pantalla de resultados
// deno-lint-ignore no-explicit-any
export async function armarPdf(orden: any, estudios: Estudio[], firmante: { nombre: string; matricula: string | null }) {
  const informe = await Informe.crear(`Informe de resultados · Orden ${orden.nro_orden}`);
  informe.nuevaPagina();
  const pac = orden.pacientes;
  const suc = orden.sucursales;

  // Encabezado: logo, laboratorio y sucursal
  const logo = await informe.doc.embedPng(Uint8Array.from(atob(LOGO_PNG_BASE64), (c) => c.charCodeAt(0)));
  informe.pagina.drawImage(logo, { x: MARGEN, y: informe.y - 40, width: 40, height: 40 });
  informe.escribir('LIMS Laboratorio Bioquímico', MARGEN + 52, informe.y - 16, { tam: 15, negrita: true, color: AZUL });
  const lugar = [suc?.nombre, suc?.direccion, suc?.localidad].filter(Boolean).join(' · ');
  informe.escribir(lugar, MARGEN + 52, informe.y - 31, { tam: 9, color: GRIS });
  const tituloDoc = 'INFORME DE RESULTADOS';
  informe.escribir(tituloDoc, ANCHO - MARGEN - informe.negrita.widthOfTextAtSize(tituloDoc, 10), informe.y - 16, {
    tam: 10,
    negrita: true,
    color: AZUL,
  });
  const nro = `Orden ${orden.nro_orden}`;
  informe.escribir(nro, ANCHO - MARGEN - informe.normal.widthOfTextAtSize(nro, 9), informe.y - 31, { tam: 9 });
  informe.y -= 52;
  informe.linea(informe.y, 1.2, AZUL);
  informe.y -= 8;

  // Datos del paciente y de la orden, en dos columnas
  const izquierda: [string, string][] = [
    ['Paciente', `${pac.apellido}, ${pac.nombre}`],
    ['DNI', pac.dni],
    ['Edad y sexo', `${edad(pac.fecha_nacimiento, orden.fecha_orden)} años · ${SEXOS[pac.sexo] ?? 'Sin especificar'}`],
    ['Cobertura', orden.obras_sociales?.nombre ?? 'Particular'],
  ];
  const derecha: [string, string][] = [
    ['Médico', orden.medicos ? `${orden.medicos.apellido}, ${orden.medicos.nombre}` : '—'],
    ['Matrícula', orden.medicos?.matricula ?? '—'],
    ['Fecha de la orden', fecha(orden.fecha_orden)],
    ['Recibida', `${fecha(orden.fecha_recepcion)} ${hora(orden.fecha_recepcion)} hs`],
  ];
  izquierda.forEach(([etiqueta, valor], i) => {
    const y = informe.y - 10 - i * 14;
    informe.escribir(etiqueta, MARGEN, y, { tam: 8.5, color: GRIS });
    informe.escribir(valor, MARGEN + 72, y, { negrita: i === 0 });
    const [etiquetaD, valorD] = derecha[i];
    informe.escribir(etiquetaD, 318, y, { tam: 8.5, color: GRIS });
    informe.escribir(valorD, 318 + 86, y);
  });
  informe.y -= 10 + izquierda.length * 14;
  informe.linea(informe.y, 0.6);
  informe.y -= 10;

  // Tabla de resultados, por grupo
  const componentesDe: Record<string, Estudio[]> = {};
  estudios.forEach((e) => {
    if (e.padre_id) (componentesDe[e.padre_id] ??= []).push(e);
  });
  const pedidos = estudios.filter((e) => !e.padre_id);
  const hayGrupos = pedidos.some((e) => e.grupo_id !== null);

  informe.encabezadoTabla();
  let grupoActual: number | null | undefined;
  let fueraDeRango = 0;

  const filaDe = (e: Estudio, sangria: boolean) => {
    const r = resultadoDe(e);
    const m = r ? marca(r.valor_numerico, r.ref_min, r.ref_max, r.fuera_de_rango) : '';
    const tieneAbsoluto = r && r.valor_absoluto !== null;
    const mAbs = tieneAbsoluto ? marca(r.valor_absoluto, r.abs_ref_min, r.abs_ref_max, false) : '';
    if (m || mAbs) fueraDeRango += 1;
    informe.fila({
      estudio: e.analisis.nombre,
      resultado: r ? (r.valor_numerico !== null ? numero(r.valor_numerico) : (r.valor_texto ?? '—')) : '—',
      unidad: e.analisis.unidad ?? '',
      referencia: r ? referencia(r.ref_min, r.ref_max, r.ref_texto) : '—',
      marca: m,
      sangria,
      detalle: tieneAbsoluto
        ? {
            resultado: numero(r.valor_absoluto!),
            unidad: e.analisis.absoluto_unidad ?? '',
            referencia: referencia(r.abs_ref_min, r.abs_ref_max, null),
            marca: mAbs,
          }
        : null,
    });
  };

  for (const estudio of pedidos) {
    if (hayGrupos && estudio.grupo_id !== grupoActual) {
      grupoActual = estudio.grupo_id;
      informe.subtitulo(estudio.grupos_analisis?.nombre ?? 'Otros estudios');
    }
    const componentes = componentesDe[estudio.id];
    if (componentes) {
      // Estudio con componentes (ej: fórmula leucocitaria): su nombre y debajo cada valor
      informe.fila({ estudio: estudio.analisis.nombre, negritaEstudio: true });
      componentes.forEach((c) => filaDe(c, true));
    } else {
      filaDe(estudio, false);
    }
  }

  // Aclaración, validación y firma
  const validados = estudios.map(resultadoDe).filter((r): r is Resultado => Boolean(r?.validado_en));
  const ultimo = validados.sort((a, b) => (a.validado_en! < b.validado_en! ? 1 : -1))[0];
  const validador = ultimo?.validador ? `${ultimo.validador.nombre} ${ultimo.validador.apellido}` : null;
  const ahora = new Date().toISOString();

  informe.lugar(118, false);
  informe.y -= 10;
  const nota =
    fueraDeRango > 0
      ? `${fueraDeRango} ${fueraDeRango === 1 ? 'valor quedó' : 'valores quedaron'} fuera del valor de referencia ` +
        '(Alto o Bajo). Los valores de referencia corresponden al sexo y la edad del paciente.'
      : 'Todos los valores están dentro del valor de referencia, que corresponde al sexo y la edad del paciente.';
  informe.renglones(nota, ANCHO - 2 * MARGEN, 8.5).forEach((texto, i) =>
    informe.escribir(texto, MARGEN, informe.y - 9 - i * 11, { tam: 8.5, color: GRIS }),
  );
  informe.y -= 40;

  // Bloque de firma, a la derecha
  const xFirma = ANCHO - MARGEN - 220;
  informe.pagina.drawLine({
    start: { x: xFirma, y: informe.y },
    end: { x: ANCHO - MARGEN, y: informe.y },
    thickness: 0.8,
    color: NEGRO,
  });
  informe.escribir(`Bioq. ${firmante.nombre}`, xFirma, informe.y - 13, { negrita: true });
  informe.escribir(`Matrícula ${firmante.matricula ?? '—'}`, xFirma, informe.y - 26, { tam: 9 });
  informe.escribir(`Firmado el ${fecha(ahora)} a las ${hora(ahora)} hs`, xFirma, informe.y - 39, { tam: 8.5, color: GRIS });
  if (ultimo?.validado_en) {
    const quien = validador && validador !== firmante.nombre ? ` por ${validador}` : '';
    informe.escribir(
      `Resultados validados${quien} el ${fecha(ultimo.validado_en)} a las ${hora(ultimo.validado_en)} hs`,
      MARGEN,
      informe.y - 13,
      { tam: 8.5, color: GRIS },
    );
  }
  informe.y -= 52;

  informe.numerarPaginas(orden.nro_orden);
  return await informe.doc.save();
}
