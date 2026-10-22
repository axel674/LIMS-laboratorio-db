-- Catálogo de análisis: reglas y carga inicial
--
-- El administrador gestiona el catálogo desde el panel (/panel/analisis). Las
-- políticas RLS ya existen (20261002_02_seguridad.sql): todo usuario con sesión
-- lo lee y solo el admin lo modifica. Esta migración agrega:
--
-- 1. Reglas de consistencia, para que la base rechace datos imposibles aunque
--    lleguen sin pasar por el formulario.
-- 2. Los tipos de muestra y un primer conjunto de análisis de rutina.
--
-- IMPORTANTE: los valores de referencia son orientativos (adulto, valores de
-- uso habitual) y están cargados para poder trabajar con el sistema. Antes de
-- usarlos con pacientes reales, un bioquímico del laboratorio debe revisarlos y
-- ajustarlos a la metodología y al equipo que se use.

-- 1. Reglas ───────────────────────────────────

ALTER TABLE public.analisis
  ADD CONSTRAINT analisis_codigo_formato
    CHECK (codigo ~ '^[A-Z0-9_-]{2,20}$'),
  ADD CONSTRAINT analisis_nombre_no_vacio
    CHECK (btrim(nombre) <> ''),
  ADD CONSTRAINT analisis_rango_valido
    CHECK (valor_ref_min IS NULL OR valor_ref_max IS NULL OR valor_ref_min <= valor_ref_max),
  ADD CONSTRAINT analisis_dias_demora_valido
    CHECK (dias_demora IS NULL OR dias_demora BETWEEN 0 AND 60);

ALTER TABLE public.tipos_muestra
  ADD CONSTRAINT tipos_muestra_nombre_no_vacio
    CHECK (btrim(nombre) <> '');

-- 2. Carga inicial ─────────────────────────────
-- ON CONFLICT DO NOTHING: si la migración se vuelve a correr no duplica nada.

INSERT INTO public.tipos_muestra (nombre, tubo) VALUES
  ('Sangre entera', 'Tapa lila (EDTA)'),
  ('Suero', 'Tapa roja o amarilla (con gel)'),
  ('Plasma citratado', 'Tapa celeste (citrato)'),
  ('Orina', 'Frasco estéril'),
  ('Materia fecal', 'Frasco con conservante')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.analisis
  (codigo, nombre, tipo_muestra_id, unidad, valor_ref_min, valor_ref_max, valor_ref_texto, dias_demora)
SELECT a.codigo, a.nombre, t.id, a.unidad, a.minimo, a.maximo, a.texto, a.dias
FROM (VALUES
  ('HTO',   'Hematocrito',               'Sangre entera',    '%',          36,    50,   NULL,       1),
  ('HB',    'Hemoglobina',               'Sangre entera',    'g/dL',       12,    17,   NULL,       1),
  ('GB',    'Glóbulos blancos',          'Sangre entera',    '/mm³',     4000, 10000,   NULL,       1),
  ('PLAQ',  'Recuento de plaquetas',     'Sangre entera',    '/mm³',   150000, 400000,  NULL,       1),
  ('GLU',   'Glucemia',                  'Suero',            'mg/dL',      70,   110,   NULL,       1),
  ('URE',   'Uremia',                    'Suero',            'mg/dL',      15,    45,   NULL,       1),
  ('CREA',  'Creatinina',                'Suero',            'mg/dL',     0.6,   1.2,   NULL,       1),
  ('COL',   'Colesterol total',          'Suero',            'mg/dL',    NULL,   200,   NULL,       1),
  ('TG',    'Triglicéridos',             'Suero',            'mg/dL',    NULL,   150,   NULL,       1),
  ('TSH',   'Tirotrofina (TSH)',         'Suero',            'µUI/mL',    0.4,   4.0,   NULL,       2),
  ('TP',    'Tiempo de protrombina',     'Plasma citratado', 's',          11,    14,   NULL,       1),
  ('ORINA', 'Orina completa',            'Orina',            NULL,       NULL,  NULL,   'Ver informe', 1),
  ('SOMF',  'Sangre oculta en materia fecal', 'Materia fecal', NULL,     NULL,  NULL,   'Negativo', 2)
) AS a (codigo, nombre, tipo, unidad, minimo, maximo, texto, dias)
JOIN public.tipos_muestra t ON t.nombre = a.tipo
ON CONFLICT (codigo) DO NOTHING;
