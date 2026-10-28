-- Prueba del aislamiento por sucursal (RLS)
--
-- Qué hace: arma datos de prueba en las dos sucursales, simula el ingreso de
-- cada cuenta y comprueba que solo vea lo suyo. Todo va dentro de una
-- transacción que termina en ROLLBACK: no deja datos ni cambia sucursales.
--
-- Antes de ejecutarlo:
--   1. Tener aplicada la migración 20261028_01_rls_sucursal.sql.
--   2. Crear desde el panel (admin → Administración de perfiles) dos cuentas de
--      recepción con los usuarios: recepcion_s1 y recepcion_s2.
--
-- Se ejecuta en el SQL Editor de Supabase: corre como postgres y puede simular
-- el token de cada usuario con set_config('request.jwt.claims', ...).

BEGIN;

-- ─────────────────────────────────────────────
-- 1. Sucursal de cada cuenta de prueba
-- ─────────────────────────────────────────────

UPDATE public.personal p
SET sucursal_id = s.id
FROM public.sucursales s
WHERE s.prefijo = 'S1' AND p.usuario = 'recepcion_s1';

UPDATE public.personal p
SET sucursal_id = s.id
FROM public.sucursales s
WHERE s.prefijo = 'S2' AND p.usuario = 'recepcion_s2';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.personal
    WHERE usuario IN ('recepcion_s1', 'recepcion_s2') AND sucursal_id IS NOT NULL
    GROUP BY true
    HAVING count(*) = 2
  ) THEN
    RAISE EXCEPTION 'Faltan las cuentas recepcion_s1 y recepcion_s2 (crearlas desde el panel)';
  END IF;
END $$;

-- ─────────────────────────────────────────────
-- 2. Datos de prueba (se deshacen con el ROLLBACK)
-- ─────────────────────────────────────────────

-- El trigger de trazabilidad de muestras pide un usuario logueado: se usa el admin
SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (SELECT id FROM public.perfiles WHERE rol = 'admin' ORDER BY created_at LIMIT 1),
    'role', 'authenticated'
  )::text,
  true
);

INSERT INTO public.pacientes (dni, nombre, apellido, fecha_nacimiento)
VALUES ('99999999', 'Prueba', 'Aislamiento', '1990-01-01')
ON CONFLICT (dni) DO NOTHING;

-- Una orden por sucursal (la sucursal se indica porque no vienen de un turno)
INSERT INTO public.ordenes (nro_orden, paciente_id, sucursal_id)
SELECT 'PRUEBA-S1', p.id, s.id
FROM public.pacientes p, public.sucursales s
WHERE p.dni = '99999999' AND s.prefijo = 'S1'
ON CONFLICT (nro_orden) DO NOTHING;

INSERT INTO public.ordenes (nro_orden, paciente_id, sucursal_id)
SELECT 'PRUEBA-S2', p.id, s.id
FROM public.pacientes p, public.sucursales s
WHERE p.dni = '99999999' AND s.prefijo = 'S2'
ON CONFLICT (nro_orden) DO NOTHING;

-- Un estudio tildado por orden (el primero del catálogo)
INSERT INTO public.orden_analisis (orden_id, analisis_id)
SELECT o.id, a.id
FROM public.ordenes o, (SELECT id FROM public.analisis ORDER BY id LIMIT 1) a
WHERE o.nro_orden IN ('PRUEBA-S1', 'PRUEBA-S2')
ON CONFLICT (orden_id, analisis_id) DO NOTHING;

-- Una muestra por orden
INSERT INTO public.muestras (codigo_barras, orden_id, tipo_muestra_id)
SELECT 'PRUEBA-M1', o.id, (SELECT id FROM public.tipos_muestra ORDER BY id LIMIT 1)
FROM public.ordenes o
WHERE o.nro_orden = 'PRUEBA-S1'
ON CONFLICT (codigo_barras) DO NOTHING;

INSERT INTO public.muestras (codigo_barras, orden_id, tipo_muestra_id)
SELECT 'PRUEBA-M2', o.id, (SELECT id FROM public.tipos_muestra ORDER BY id LIMIT 1)
FROM public.ordenes o
WHERE o.nro_orden = 'PRUEBA-S2'
ON CONFLICT (codigo_barras) DO NOTHING;

-- Un resultado por estudio
INSERT INTO public.resultados (orden_analisis_id, valor_texto)
SELECT oa.id, 'Negativo'
FROM public.orden_analisis oa
JOIN public.ordenes o ON o.id = oa.orden_id
WHERE o.nro_orden IN ('PRUEBA-S1', 'PRUEBA-S2')
ON CONFLICT (orden_analisis_id) DO NOTHING;

-- Se guarda el id del resultado de S2 para consultarlo después como S1
SELECT set_config(
  'prueba.resultado_s2',
  coalesce(
    (
      SELECT r.id::text
      FROM public.resultados r
      JOIN public.orden_analisis oa ON oa.id = r.orden_analisis_id
      JOIN public.ordenes o ON o.id = oa.orden_id
      WHERE o.nro_orden = 'PRUEBA-S2'
      LIMIT 1
    ),
    ''
  ),
  true
);

-- ─────────────────────────────────────────────
-- 3. Recepción de la Sucursal 1
-- ─────────────────────────────────────────────

SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (SELECT id FROM auth.users WHERE email = 'recepcion_s1@personal.lims.local'),
    'role', 'authenticated'
  )::text,
  true
);

SET LOCAL ROLE authenticated;

SELECT 'ordenes' AS tabla, nro_orden AS dato FROM public.ordenes WHERE nro_orden LIKE 'PRUEBA-%'
UNION ALL
SELECT 'muestras', codigo_barras FROM public.muestras WHERE codigo_barras LIKE 'PRUEBA-%'
ORDER BY 1, 2;
-- Esperado: PRUEBA-S1 y PRUEBA-M1 (nada de S2)

-- Consulta directa por el número de la otra sucursal: tiene que dar 0
SELECT count(*) AS ordenes_de_s2 FROM public.ordenes WHERE nro_orden = 'PRUEBA-S2';

-- Consulta directa por el id del resultado de la otra sucursal: tiene que dar 0
SELECT count(*) AS resultado_de_s2
FROM public.resultados
WHERE id = nullif(current_setting('prueba.resultado_s2', true), '')::uuid;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.ordenes WHERE nro_orden = 'PRUEBA-S2') THEN
    RAISE EXCEPTION 'FALLA: recepción de S1 ve una orden de S2';
  END IF;
  IF EXISTS (SELECT 1 FROM public.muestras WHERE codigo_barras = 'PRUEBA-M2') THEN
    RAISE EXCEPTION 'FALLA: recepción de S1 ve una muestra de S2';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.resultados
    WHERE id = nullif(current_setting('prueba.resultado_s2', true), '')::uuid
  ) THEN
    RAISE EXCEPTION 'FALLA: recepción de S1 ve un resultado de S2';
  END IF;
  RAISE NOTICE 'OK: recepción de S1 solo ve los datos de S1';
END $$;

RESET ROLE;

-- ─────────────────────────────────────────────
-- 4. Recepción de la Sucursal 2
-- ─────────────────────────────────────────────

SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (SELECT id FROM auth.users WHERE email = 'recepcion_s2@personal.lims.local'),
    'role', 'authenticated'
  )::text,
  true
);

SET LOCAL ROLE authenticated;

SELECT 'ordenes' AS tabla, nro_orden AS dato FROM public.ordenes WHERE nro_orden LIKE 'PRUEBA-%'
UNION ALL
SELECT 'muestras', codigo_barras FROM public.muestras WHERE codigo_barras LIKE 'PRUEBA-%'
ORDER BY 1, 2;
-- Esperado: PRUEBA-S2 y PRUEBA-M2 (nada de S1)

SELECT count(*) AS ordenes_de_s1 FROM public.ordenes WHERE nro_orden = 'PRUEBA-S1';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.ordenes WHERE nro_orden = 'PRUEBA-S1') THEN
    RAISE EXCEPTION 'FALLA: recepción de S2 ve una orden de S1';
  END IF;
  RAISE NOTICE 'OK: recepción de S2 solo ve los datos de S2';
END $$;

RESET ROLE;

-- ─────────────────────────────────────────────
-- 5. Administrador: ve las dos sucursales
-- ─────────────────────────────────────────────

SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (SELECT id FROM public.perfiles WHERE rol = 'admin' ORDER BY created_at LIMIT 1),
    'role', 'authenticated'
  )::text,
  true
);

SET LOCAL ROLE authenticated;

SELECT nro_orden FROM public.ordenes WHERE nro_orden LIKE 'PRUEBA-%' ORDER BY nro_orden;
-- Esperado: PRUEBA-S1 y PRUEBA-S2

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.ordenes WHERE nro_orden = 'PRUEBA-S1')
     OR NOT EXISTS (SELECT 1 FROM public.ordenes WHERE nro_orden = 'PRUEBA-S2') THEN
    RAISE EXCEPTION 'FALLA: el admin no ve las órdenes de las dos sucursales';
  END IF;
  RAISE NOTICE 'OK: el admin ve las dos sucursales';
END $$;

RESET ROLE;

ROLLBACK;
