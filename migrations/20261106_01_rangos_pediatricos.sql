-- Correcciones de los valores de referencia aprobadas por el bioquímico (LIMS-30)
--
-- El bioquímico revisó la planilla del 03/11 y aprobó:
--   1. Menores de 1 año: siguen usando el rango general del catálogo. No se
--      agregan franjas de 0 a 1 año (decisión 1A).
--   2. Rangos pediátricos de 1 a 17 años para los estudios que usaban el
--      general a toda edad.
--   3. Absolutos pediátricos de neutrófilos y linfocitos. Los de monocitos,
--      eosinófilos y basófilos no cambian: ya son iguales a toda edad.
--   4. Unidades y valores puntuales: confirmados sin cambios.
--
-- Los resultados ya cargados no cambian: guardan el rango con el que se
-- compararon (resultados.ref_min/max y abs_ref_min/max).

-- 1. Absoluto por rango de edad ────────────────
-- Hasta ahora el absoluto de la fórmula salía siempre del catálogo
-- (analisis.absoluto_min/max). Los neutrófilos y los linfocitos cambian en los
-- chicos, así que el rango por edad puede llevar su propio absoluto. Si el
-- rango no lo trae, se usa el general del catálogo.

ALTER TABLE public.analisis_rangos
  ADD COLUMN absoluto_min numeric,
  ADD COLUMN absoluto_max numeric;

COMMENT ON TABLE public.analisis_rangos IS
  'Valores de referencia por sexo y edad. Los rangos pediátricos empiezan a los 1 año: los menores de 1 año usan el general del catálogo (analisis.valor_ref_min/max). Si no hay un rango que corresponda al paciente, también se usa el general.';
COMMENT ON COLUMN public.analisis_rangos.absoluto_min IS
  'Absoluto mínimo del componente en ese rango de edad (ej: neutrófilos /mm³). Vacío = el general del catálogo (analisis.absoluto_min).';
COMMENT ON COLUMN public.analisis_rangos.absoluto_max IS
  'Absoluto máximo del componente en ese rango de edad. Vacío = el general del catálogo (analisis.absoluto_max).';

-- 2. Rangos pediátricos de 1 a 17 años ─────────
-- Valores aprobados por el bioquímico. En la base la edad "hasta" no se
-- incluye: 18 = 17 años inclusive.
-- Se agregan solo si no existen, y después se fijan los valores aprobados:
-- así la migración no falla si alguien ya los había cargado desde el panel.

INSERT INTO public.analisis_rangos (analisis_id, sexo, edad_desde, edad_hasta, valor_min, valor_max)
SELECT a.id, NULL, 1, 18, v.minimo, v.maximo
FROM (VALUES
  ('GLU', 60,   100),
  ('URE', 15,   40),
  ('TSH', 0.7,  5.0),
  ('GOT', NULL, 40),
  ('GPT', NULL, 30),
  ('HDL', 40,   NULL),
  ('COL', NULL, 170),
  ('TG',  NULL, 100),
  ('LDL', NULL, 110)
) AS v (codigo, minimo, maximo)
JOIN public.analisis a ON a.codigo = v.codigo
WHERE NOT EXISTS (
  SELECT 1
  FROM public.analisis_rangos r
  WHERE r.analisis_id = a.id
    AND r.sexo IS NULL
    AND r.edad_desde = 1
    AND r.edad_hasta = 18
);

UPDATE public.analisis_rangos r
SET valor_min = v.minimo,
    valor_max = v.maximo
FROM (VALUES
  ('GLU', 60,   100),
  ('URE', 15,   40),
  ('TSH', 0.7,  5.0),
  ('GOT', NULL, 40),
  ('GPT', NULL, 30),
  ('HDL', 40,   NULL),
  ('COL', NULL, 170),
  ('TG',  NULL, 100),
  ('LDL', NULL, 110)
) AS v (codigo, minimo, maximo)
JOIN public.analisis a ON a.codigo = v.codigo
WHERE r.analisis_id = a.id
  AND r.sexo IS NULL
  AND r.edad_desde = 1
  AND r.edad_hasta = 18;

-- 3. Absolutos pediátricos de la fórmula leucocitaria ──
-- Solo cambian neutrófilos y linfocitos; monocitos, eosinófilos y basófilos
-- mantienen el absoluto general.

UPDATE public.analisis_rangos r
SET absoluto_min = v.abs_min,
    absoluto_max = v.abs_max
FROM (VALUES ('FL-NEU', 1500, 8500), ('FL-LIN', 1500, 7000)) AS v (codigo, abs_min, abs_max)
JOIN public.analisis a ON a.codigo = v.codigo
WHERE r.analisis_id = a.id
  AND r.sexo IS NULL
  AND r.edad_desde = 1
  AND r.edad_hasta = 18;

-- 4. El rango que corresponde trae también el absoluto ──
-- Cambia el tipo de retorno, así que se recrean las funciones.

DROP FUNCTION public.rangos_de_orden(uuid);
DROP FUNCTION public.rango_de_estudio(uuid);

CREATE FUNCTION public.rango_de_estudio(p_orden_analisis_id uuid)
RETURNS TABLE (
  valor_min numeric,
  valor_max numeric,
  valor_texto varchar,
  absoluto_min numeric,
  absoluto_max numeric
)
LANGUAGE sql STABLE SET search_path = ''
AS $$
  WITH estudio AS (
    SELECT a.id AS analisis_id, a.valor_ref_min, a.valor_ref_max, a.valor_ref_texto,
           a.absoluto_min, a.absoluto_max, p.sexo,
           extract(year FROM age(o.fecha_orden, p.fecha_nacimiento))::int AS edad
    FROM public.orden_analisis oa
    JOIN public.ordenes o ON o.id = oa.orden_id
    JOIN public.pacientes p ON p.id = o.paciente_id
    JOIN public.analisis a ON a.id = oa.analisis_id
    WHERE oa.id = p_orden_analisis_id
  ),
  especifico AS (
    SELECT r.valor_min, r.valor_max, r.absoluto_min, r.absoluto_max
    FROM estudio e
    JOIN public.analisis_rangos r ON r.analisis_id = e.analisis_id
    WHERE (r.sexo IS NULL OR r.sexo = e.sexo)
      AND e.edad IS NOT NULL
      AND e.edad >= r.edad_desde
      AND (r.edad_hasta IS NULL OR e.edad < r.edad_hasta)
    ORDER BY (r.sexo IS NOT NULL) DESC, coalesce(r.edad_hasta, 200) - r.edad_desde
    LIMIT 1
  )
  SELECT
    coalesce((SELECT valor_min FROM especifico), CASE WHEN NOT EXISTS (SELECT 1 FROM especifico) THEN e.valor_ref_min END),
    coalesce((SELECT valor_max FROM especifico), CASE WHEN NOT EXISTS (SELECT 1 FROM especifico) THEN e.valor_ref_max END),
    e.valor_ref_texto,
    coalesce((SELECT absoluto_min FROM especifico), e.absoluto_min),
    coalesce((SELECT absoluto_max FROM especifico), e.absoluto_max)
  FROM estudio e;
$$;

CREATE FUNCTION public.rangos_de_orden(p_orden_id uuid)
RETURNS TABLE (
  orden_analisis_id uuid,
  valor_min numeric,
  valor_max numeric,
  valor_texto varchar,
  absoluto_min numeric,
  absoluto_max numeric
)
LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT oa.id, r.valor_min, r.valor_max, r.valor_texto, r.absoluto_min, r.absoluto_max
  FROM public.orden_analisis oa
  CROSS JOIN LATERAL public.rango_de_estudio(oa.id) AS r
  WHERE oa.orden_id = p_orden_id;
$$;

-- 5. El resultado guarda el absoluto del rango que le corresponde ──
-- Misma función que en 20261029_04, con abs_ref_* tomado de v_rango (que ya
-- trae el absoluto del rango por edad o, si no hay, el general del catálogo).

CREATE OR REPLACE FUNCTION privado.controlar_resultado()
RETURNS trigger
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_rango record;
  v_analisis public.analisis;
  v_base numeric;
  v_validador boolean := privado.tiene_rol('bioquimico', 'admin');
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- Validado: queda fijo (salvo que el bioquímico lo vuelva a pendiente, LIMS-14)
    IF OLD.estado = 'validado' AND (
         NEW.valor_numerico IS DISTINCT FROM OLD.valor_numerico
      OR NEW.valor_texto IS DISTINCT FROM OLD.valor_texto
    ) THEN
      RAISE EXCEPTION 'El resultado ya está validado: no se puede corregir' USING ERRCODE = '22023';
    END IF;
    -- Validar o rechazar es solo del bioquímico (o el admin)
    IF NOT v_validador AND (
         NEW.estado IS DISTINCT FROM OLD.estado
      OR NEW.validado_por IS DISTINCT FROM OLD.validado_por
      OR NEW.validado_en IS DISTINCT FROM OLD.validado_en
    ) THEN
      RAISE EXCEPTION 'Solo el bioquímico valida los resultados' USING ERRCODE = '42501';
    END IF;
    NEW.orden_analisis_id := OLD.orden_analisis_id;
    -- Un resultado rechazado que se corrige vuelve a pendiente, para que el bioquímico lo revise de nuevo
    IF OLD.estado = 'rechazado' AND (
         NEW.valor_numerico IS DISTINCT FROM OLD.valor_numerico
      OR NEW.valor_texto IS DISTINCT FROM OLD.valor_texto
    ) THEN
      NEW.estado := 'pendiente';
      NEW.validado_por := NULL;
      NEW.validado_en := NULL;
    END IF;
  ELSE
    NEW.estado := 'pendiente';
    NEW.validado_por := NULL;
    NEW.validado_en := NULL;
  END IF;

  NEW.valor_texto := nullif(btrim(NEW.valor_texto), '');
  SELECT * INTO v_rango FROM public.rango_de_estudio(NEW.orden_analisis_id);
  SELECT a.* INTO v_analisis
  FROM public.orden_analisis oa JOIN public.analisis a ON a.id = oa.analisis_id
  WHERE oa.id = NEW.orden_analisis_id;

  -- Un estudio con rango numérico lleva un número; uno con referencia de texto, un texto
  IF v_rango.valor_min IS NOT NULL OR v_rango.valor_max IS NOT NULL THEN
    IF NEW.valor_numerico IS NULL THEN
      RAISE EXCEPTION 'Ingrese un valor numérico' USING ERRCODE = '22023';
    END IF;
    IF NEW.valor_numerico < 0 THEN
      RAISE EXCEPTION 'El valor no puede ser negativo' USING ERRCODE = '22023';
    END IF;
  ELSIF NEW.valor_numerico IS NULL AND NEW.valor_texto IS NULL THEN
    RAISE EXCEPTION 'Ingrese el resultado' USING ERRCODE = '22023';
  END IF;

  -- Absoluto: con el resultado del estudio base de la misma orden (si ya está cargado)
  NEW.valor_absoluto := NULL;
  NEW.abs_ref_min := v_rango.absoluto_min;
  NEW.abs_ref_max := v_rango.absoluto_max;
  IF v_analisis.absoluto_de IS NOT NULL AND NEW.valor_numerico IS NOT NULL THEN
    SELECT r.valor_numerico INTO v_base
    FROM public.orden_analisis oa
    JOIN public.orden_analisis base ON base.orden_id = oa.orden_id AND base.analisis_id = v_analisis.absoluto_de
    JOIN public.resultados r ON r.orden_analisis_id = base.id
    WHERE oa.id = NEW.orden_analisis_id;
    IF v_base IS NOT NULL THEN
      NEW.valor_absoluto := round(NEW.valor_numerico * v_base / 100);
    END IF;
  END IF;

  NEW.ref_min := v_rango.valor_min;
  NEW.ref_max := v_rango.valor_max;
  NEW.ref_texto := v_rango.valor_texto;
  NEW.fuera_de_rango := CASE
    WHEN NEW.valor_numerico IS NOT NULL AND (v_rango.valor_min IS NOT NULL OR v_rango.valor_max IS NOT NULL) THEN
      NEW.valor_numerico < coalesce(v_rango.valor_min, NEW.valor_numerico)
      OR NEW.valor_numerico > coalesce(v_rango.valor_max, NEW.valor_numerico)
      OR coalesce(NEW.valor_absoluto < NEW.abs_ref_min OR NEW.valor_absoluto > NEW.abs_ref_max, false)
    -- Referencia de texto (ej. "Negativo"): fuera de rango si el resultado es otro
    WHEN NEW.valor_texto IS NOT NULL AND v_rango.valor_texto IS NOT NULL AND v_rango.valor_texto <> 'Ver informe' THEN
      lower(NEW.valor_texto) <> lower(v_rango.valor_texto)
    ELSE false
  END;

  IF TG_OP = 'INSERT'
     OR NEW.valor_numerico IS DISTINCT FROM OLD.valor_numerico
     OR NEW.valor_texto IS DISTINCT FROM OLD.valor_texto THEN
    NEW.cargado_por := auth.uid();
    NEW.cargado_en := now();
  ELSE
    NEW.cargado_por := OLD.cargado_por;
    NEW.cargado_en := OLD.cargado_en;
  END IF;
  RETURN NEW;
END;
$$;

-- 6. Permisos de las funciones recreadas ────────

REVOKE ALL ON FUNCTION public.rango_de_estudio(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rangos_de_orden(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rango_de_estudio(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rangos_de_orden(uuid) TO authenticated;
