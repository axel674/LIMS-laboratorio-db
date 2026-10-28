-- Grupos de estudios (LIMS-27)
--
-- Un grupo es un conjunto de estudios que se piden juntos, como "Sangre
-- completa" (la rutina). El admin los arma desde el catálogo de análisis y, al
-- cargar una orden, recepción elige el grupo y se agregan todos sus estudios.
-- Las tablas grupos_analisis y grupo_analisis_items ya existían (esquema
-- inicial); acá se completan las reglas, se cargan los estudios de rutina que
-- faltaban en el catálogo y los dos primeros grupos.
--
-- Los valores de referencia son los habituales en adultos: los confirma o
-- ajusta el bioquímico desde el catálogo.

-- 1. Estudios que faltaban ─────────────────────

INSERT INTO public.analisis
  (codigo, nombre, tipo_muestra_id, unidad, valor_ref_min, valor_ref_max, valor_ref_texto, dias_demora)
SELECT a.codigo, a.nombre, t.id, a.unidad, a.minimo, a.maximo, a.texto, a.dias
FROM (VALUES
  ('GR',   'Glóbulos rojos',                                   'Sangre entera', 'millones/mm³', 4.2,  5.5,  NULL,          1),
  ('VCM',  'Volumen corpuscular medio (VCM)',                  'Sangre entera', 'fL',           80,   100,  NULL,          1),
  ('HCM',  'Hemoglobina corpuscular media (HCM)',              'Sangre entera', 'pg',           27,   33,   NULL,          1),
  ('CHCM', 'Concentración de hemoglobina corpuscular media (CHCM)', 'Sangre entera', 'g/dL',     32,   36,   NULL,          1),
  ('FL',   'Fórmula leucocitaria',                             'Sangre entera', NULL,           NULL, NULL, 'Ver informe', 1),
  ('ERS',  'Eritrosedimentación (VSG)',                        'Sangre entera', 'mm/1ª hora',   NULL, 20,   NULL,          1),
  ('HDL',  'Colesterol HDL',                                   'Suero',         'mg/dL',        40,   NULL, NULL,          1),
  ('LDL',  'Colesterol LDL',                                   'Suero',         'mg/dL',        NULL, 130,  NULL,          1),
  ('GOT',  'Transaminasa GOT (AST)',                           'Suero',         'U/L',          NULL, 40,   NULL,          1),
  ('GPT',  'Transaminasa GPT (ALT)',                           'Suero',         'U/L',          NULL, 41,   NULL,          1),
  ('FAL',  'Fosfatasa alcalina',                               'Suero',         'U/L',          40,   129,  NULL,          1),
  ('BT',   'Bilirrubina total',                                'Suero',         'mg/dL',        NULL, 1.2,  NULL,          1),
  ('BD',   'Bilirrubina directa',                              'Suero',         'mg/dL',        NULL, 0.3,  NULL,          1)
) AS a (codigo, nombre, tipo, unidad, minimo, maximo, texto, dias)
JOIN public.tipos_muestra t ON t.nombre = a.tipo
ON CONFLICT (codigo) DO NOTHING;

-- 2. Reglas de los grupos ──────────────────────

ALTER TABLE public.grupos_analisis
  ADD CONSTRAINT grupos_analisis_codigo_formato CHECK (codigo ~ '^[A-Z0-9_-]{2,20}$'),
  ADD CONSTRAINT grupos_analisis_nombre_no_vacio CHECK (btrim(nombre) <> ''),
  ADD CONSTRAINT grupos_analisis_nombre_key UNIQUE (nombre);

COMMENT ON TABLE public.grupos_analisis IS
  'Conjunto de estudios que se piden juntos (ej: Sangre completa). No se borran: se desactivan.';
COMMENT ON COLUMN public.grupo_analisis_items.orden IS 'Orden en que se listan los estudios del grupo.';

-- 3. Primeros grupos ───────────────────────────

INSERT INTO public.grupos_analisis (codigo, nombre)
VALUES ('SANGRE', 'Sangre completa'), ('HEPATO', 'Hepatograma')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO public.grupo_analisis_items (grupo_id, analisis_id, orden)
SELECT g.id, a.id, i.orden
FROM (VALUES
  ('SANGRE', 'GR', 1), ('SANGRE', 'HB', 2), ('SANGRE', 'HTO', 3), ('SANGRE', 'VCM', 4),
  ('SANGRE', 'HCM', 5), ('SANGRE', 'CHCM', 6), ('SANGRE', 'GB', 7), ('SANGRE', 'FL', 8),
  ('SANGRE', 'PLAQ', 9), ('SANGRE', 'ERS', 10), ('SANGRE', 'GLU', 11), ('SANGRE', 'URE', 12),
  ('SANGRE', 'CREA', 13), ('SANGRE', 'URIC', 14), ('SANGRE', 'COL', 15), ('SANGRE', 'HDL', 16),
  ('SANGRE', 'LDL', 17), ('SANGRE', 'TG', 18),
  ('HEPATO', 'GOT', 1), ('HEPATO', 'GPT', 2), ('HEPATO', 'FAL', 3), ('HEPATO', 'BT', 4), ('HEPATO', 'BD', 5)
) AS i (grupo, analisis, orden)
JOIN public.grupos_analisis g ON g.codigo = i.grupo
JOIN public.analisis a ON a.codigo = i.analisis
ON CONFLICT (grupo_id, analisis_id) DO NOTHING;

-- 4. Guardar un grupo con sus estudios ─────────
-- SECURITY INVOKER: las políticas dejan modificar solo al admin.
-- p_analisis: ids de los estudios en el orden en que se listan.

CREATE FUNCTION public.guardar_grupo(
  p_codigo varchar,
  p_nombre varchar,
  p_analisis bigint[],
  p_id bigint DEFAULT NULL
)
RETURNS public.grupos_analisis
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_grupo public.grupos_analisis;
BEGIN
  IF coalesce(array_length(p_analisis, 1), 0) = 0 THEN
    RAISE EXCEPTION 'El grupo necesita al menos un estudio' USING ERRCODE = '22023';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.grupos_analisis (codigo, nombre)
    VALUES (upper(btrim(p_codigo)), btrim(p_nombre))
    RETURNING * INTO v_grupo;
  ELSE
    UPDATE public.grupos_analisis
    SET codigo = upper(btrim(p_codigo)), nombre = btrim(p_nombre)
    WHERE id = p_id
    RETURNING * INTO v_grupo;
    IF v_grupo.id IS NULL THEN
      RAISE EXCEPTION 'No se encontró el grupo o no tiene permiso para modificarlo' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  DELETE FROM public.grupo_analisis_items
  WHERE grupo_id = v_grupo.id AND NOT (analisis_id = ANY (p_analisis));

  INSERT INTO public.grupo_analisis_items (grupo_id, analisis_id, orden)
  SELECT v_grupo.id, a.id, a.posicion::int
  FROM unnest(p_analisis) WITH ORDINALITY AS a (id, posicion)
  ON CONFLICT (grupo_id, analisis_id) DO UPDATE SET orden = excluded.orden;

  RETURN v_grupo;
END;
$$;

REVOKE ALL ON FUNCTION public.guardar_grupo(varchar, varchar, bigint[], bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_grupo(varchar, varchar, bigint[], bigint) TO authenticated;

-- 5. Grupo de cada estudio de la orden ─────────
-- orden_analisis.grupo_id ya existía: ahora las funciones de la orden lo
-- reciben. p_estudios: [{"analisis_id": 1, "cubierto": true, "grupo_id": 3}, ...]

CREATE OR REPLACE FUNCTION public.crear_orden(
  p_paciente_id uuid,
  p_medico_id bigint,
  p_estudios jsonb,
  p_fecha_orden date,
  p_obra_social_id bigint DEFAULT NULL,
  p_turno_id uuid DEFAULT NULL,
  p_sucursal_id bigint DEFAULT NULL,
  p_observaciones text DEFAULT NULL
)
RETURNS public.ordenes
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_orden public.ordenes;
BEGIN
  IF jsonb_typeof(p_estudios) IS DISTINCT FROM 'array' OR jsonb_array_length(p_estudios) = 0 THEN
    RAISE EXCEPTION 'La orden necesita al menos un estudio' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.ordenes (nro_orden, paciente_id, medico_id, turno_id, sucursal_id, obra_social_id, fecha_orden, observaciones)
  VALUES ('', p_paciente_id, p_medico_id, p_turno_id, p_sucursal_id, p_obra_social_id, p_fecha_orden,
          nullif(btrim(p_observaciones), ''))
  RETURNING * INTO v_orden;

  INSERT INTO public.orden_analisis (orden_id, analisis_id, cubierto, grupo_id)
  SELECT v_orden.id, (e ->> 'analisis_id')::bigint,
         -- Sin obra social no hay cobertura: todo es particular
         p_obra_social_id IS NOT NULL AND coalesce((e ->> 'cubierto')::boolean, true),
         (e ->> 'grupo_id')::bigint
  FROM jsonb_array_elements(p_estudios) AS e;

  RETURN v_orden;
END;
$$;

CREATE OR REPLACE FUNCTION public.modificar_orden(
  p_orden_id uuid,
  p_medico_id bigint,
  p_estudios jsonb,
  p_fecha_orden date,
  p_obra_social_id bigint DEFAULT NULL,
  p_observaciones text DEFAULT NULL
)
RETURNS public.ordenes
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_orden public.ordenes;
BEGIN
  IF jsonb_typeof(p_estudios) IS DISTINCT FROM 'array' OR jsonb_array_length(p_estudios) = 0 THEN
    RAISE EXCEPTION 'La orden necesita al menos un estudio' USING ERRCODE = '22023';
  END IF;

  UPDATE public.ordenes
  SET medico_id = p_medico_id,
      obra_social_id = p_obra_social_id,
      fecha_orden = p_fecha_orden,
      observaciones = nullif(btrim(p_observaciones), '')
  WHERE id = p_orden_id
  RETURNING * INTO v_orden;

  -- Sin fila: la orden no existe o es de otra sucursal (la política no la deja ver)
  IF v_orden.id IS NULL THEN
    RAISE EXCEPTION 'No se encontró la orden' USING ERRCODE = 'P0002';
  END IF;

  -- Los estudios que se sacaron se borran; los demás se agregan o actualizan
  DELETE FROM public.orden_analisis
  WHERE orden_id = p_orden_id
    AND analisis_id NOT IN (SELECT (e ->> 'analisis_id')::bigint FROM jsonb_array_elements(p_estudios) AS e);

  INSERT INTO public.orden_analisis AS oa (orden_id, analisis_id, cubierto, grupo_id)
  SELECT p_orden_id, (e ->> 'analisis_id')::bigint,
         p_obra_social_id IS NOT NULL AND coalesce((e ->> 'cubierto')::boolean, true),
         (e ->> 'grupo_id')::bigint
  FROM jsonb_array_elements(p_estudios) AS e
  ON CONFLICT (orden_id, analisis_id) DO UPDATE SET cubierto = excluded.cubierto, grupo_id = excluded.grupo_id
  WHERE oa.cubierto IS DISTINCT FROM excluded.cubierto OR oa.grupo_id IS DISTINCT FROM excluded.grupo_id;

  RETURN v_orden;
END;
$$;

-- El grupo de un estudio también se cambia solo con la orden abierta
CREATE OR REPLACE FUNCTION privado.controlar_estudio()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_orden uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.orden_id ELSE NEW.orden_id END;
  v_estado public.estado_orden;
BEGIN
  SELECT estado INTO v_estado FROM public.ordenes WHERE id = v_orden;
  IF v_estado <> 'abierta' AND (
       TG_OP <> 'UPDATE'
    OR NEW.analisis_id IS DISTINCT FROM OLD.analisis_id
    OR NEW.cubierto IS DISTINCT FROM OLD.cubierto
    OR NEW.grupo_id IS DISTINCT FROM OLD.grupo_id
  ) THEN
    RAISE EXCEPTION 'Los estudios solo se modifican con la orden abierta' USING ERRCODE = '22023';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
