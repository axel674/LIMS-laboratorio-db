-- Prueba de los rangos pediátricos aprobados por el bioquímico (LIMS-30)
--
-- Qué verifica:
--   1. Los rangos de 1 a 17 años de glucemia, uremia, TSH, GOT, GPT, HDL,
--      colesterol, triglicéridos y LDL tienen los valores aprobados.
--   2. Los neutrófilos y linfocitos de 1 a 17 años tienen su absoluto propio.
--   3. El rango general y los absolutos generales no cambiaron.
-- Todo va dentro de una transacción que termina en ROLLBACK: no deja datos.
--
-- Antes de ejecutarlo: tener aplicada la migración 20261106_01_rangos_pediatricos.sql.
-- Se ejecuta en el SQL Editor de Supabase (corre como postgres).

BEGIN;

-- 1. Rangos pediátricos de 1 a 17 años ──────────

DO $$
DECLARE
  v_faltan text;
BEGIN
  SELECT string_agg(e.codigo, ', ' ORDER BY e.codigo) INTO v_faltan
  FROM (VALUES
    ('GLU', 60::numeric,  100::numeric),
    ('URE', 15::numeric,   40::numeric),
    ('TSH', 0.7::numeric,  5.0::numeric),
    ('GOT', NULL::numeric, 40::numeric),
    ('GPT', NULL::numeric, 30::numeric),
    ('HDL', 40::numeric,  NULL::numeric),
    ('COL', NULL::numeric, 170::numeric),
    ('TG',  NULL::numeric, 100::numeric),
    ('LDL', NULL::numeric, 110::numeric)
  ) AS e (codigo, minimo, maximo)
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.analisis_rangos r
    JOIN public.analisis a ON a.id = r.analisis_id
    WHERE a.codigo = e.codigo
      AND r.sexo IS NULL
      AND r.edad_desde = 1
      AND r.edad_hasta = 18
      AND r.valor_min IS NOT DISTINCT FROM e.minimo
      AND r.valor_max IS NOT DISTINCT FROM e.maximo
  );

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan o están mal los rangos pediátricos: %', v_faltan;
  END IF;
END;
$$;

-- 2. Absolutos pediátricos de la fórmula leucocitaria ──

DO $$
DECLARE
  v_faltan text;
BEGIN
  SELECT string_agg(e.codigo, ', ' ORDER BY e.codigo) INTO v_faltan
  FROM (VALUES
    ('FL-NEU', 1500::numeric, 8500::numeric),
    ('FL-LIN', 1500::numeric, 7000::numeric)
  ) AS e (codigo, abs_min, abs_max)
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.analisis_rangos r
    JOIN public.analisis a ON a.id = r.analisis_id
    WHERE a.codigo = e.codigo
      AND r.sexo IS NULL
      AND r.edad_desde = 1
      AND r.edad_hasta = 18
      AND r.absoluto_min IS NOT DISTINCT FROM e.abs_min
      AND r.absoluto_max IS NOT DISTINCT FROM e.abs_max
  );

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan o están mal los absolutos pediátricos: %', v_faltan;
  END IF;
END;
$$;

-- 3. El rango general y los absolutos generales no cambiaron ──

DO $$
DECLARE
  v_faltan text;
BEGIN
  SELECT string_agg(e.codigo, ', ' ORDER BY e.codigo) INTO v_faltan
  FROM (VALUES
    ('GLU',    70::numeric,   110::numeric),
    ('URE',    15::numeric,    45::numeric),
    ('TSH',     0.4::numeric,   4.0::numeric),
    ('COL',    NULL::numeric, 200::numeric),
    ('TG',     NULL::numeric, 150::numeric),
    ('LDL',    NULL::numeric, 130::numeric),
    ('FL-NEU', 40::numeric,    75::numeric),
    ('FL-LIN', 20::numeric,    45::numeric)
  ) AS e (codigo, minimo, maximo)
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.analisis a
    WHERE a.codigo = e.codigo
      AND a.valor_ref_min IS NOT DISTINCT FROM e.minimo
      AND a.valor_ref_max IS NOT DISTINCT FROM e.maximo
  );

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Cambió el rango general de: %', v_faltan;
  END IF;

  SELECT string_agg(e.codigo, ', ' ORDER BY e.codigo) INTO v_faltan
  FROM (VALUES
    ('FL-NEU', 1800::numeric, 7700::numeric),
    ('FL-LIN', 1000::numeric, 4800::numeric)
  ) AS e (codigo, abs_min, abs_max)
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.analisis a
    WHERE a.codigo = e.codigo
      AND a.absoluto_min IS NOT DISTINCT FROM e.abs_min
      AND a.absoluto_max IS NOT DISTINCT FROM e.abs_max
  );

  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Cambió el absoluto general de: %', v_faltan;
  END IF;
END;
$$;

ROLLBACK;
