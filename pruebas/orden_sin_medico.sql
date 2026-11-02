-- Prueba de la orden sin pedido médico (LIMS-33)
--
-- Qué verifica:
--   1. Una orden sin médico y particular se carga, con sus estudios a valor particular.
--   2. Una orden sin médico con obra social se rechaza.
--   3. Una orden con médico sigue aceptando obra social.
-- Todo va dentro de una transacción que termina en ROLLBACK: no deja datos.
--
-- Antes de ejecutarlo: tener aplicada la migración 20261102_02_orden_sin_medico.sql.
-- Se ejecuta en el SQL Editor de Supabase (corre como postgres).

BEGIN;

-- Los triggers de la orden registran quién la cargó: se usa el admin
SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (SELECT id FROM public.perfiles WHERE rol = 'admin' ORDER BY created_at LIMIT 1),
    'role', 'authenticated'
  )::text,
  true
);

INSERT INTO public.pacientes (dni, nombre, apellido, fecha_nacimiento)
VALUES ('99999998', 'Prueba', 'Sin Medico', '1990-01-01')
ON CONFLICT (dni) DO NOTHING;

INSERT INTO public.medicos (nombre, apellido, matricula)
VALUES ('Prueba', 'Sin Medico', 'PRUEBA-SM')
ON CONFLICT (matricula) DO NOTHING;

-- 1. Sin médico y particular: se carga ─────────

INSERT INTO public.ordenes (nro_orden, paciente_id, sucursal_id, medico_id, obra_social_id, observaciones)
SELECT '', p.id, s.id, NULL, NULL, 'PRUEBA-SIN-MEDICO'
FROM public.pacientes p, public.sucursales s
WHERE p.dni = '99999998' AND s.prefijo = 'S1';

INSERT INTO public.orden_analisis (orden_id, analisis_id, cubierto)
SELECT o.id, a.id, false
FROM public.ordenes o, (SELECT id FROM public.analisis WHERE activo ORDER BY id LIMIT 1) a
WHERE o.observaciones = 'PRUEBA-SIN-MEDICO';

-- Debe mostrar la orden sin médico, sin obra social y el estudio con su importe particular
SELECT o.nro_orden, o.medico_id, o.obra_social_id, oa.cubierto, oa.importe_paciente
FROM public.ordenes o
JOIN public.orden_analisis oa ON oa.orden_id = o.id
WHERE o.observaciones = 'PRUEBA-SIN-MEDICO';

-- 2. Sin médico con obra social: se rechaza ───

DO $$
BEGIN
  BEGIN
    INSERT INTO public.ordenes (nro_orden, paciente_id, sucursal_id, medico_id, obra_social_id, observaciones)
    SELECT '', p.id, s.id, NULL, (SELECT id FROM public.obras_sociales ORDER BY id LIMIT 1), 'PRUEBA-RECHAZO'
    FROM public.pacientes p, public.sucursales s
    WHERE p.dni = '99999998' AND s.prefijo = 'S1';
    RAISE EXCEPTION 'FALLÓ: se aceptó una orden sin médico con obra social';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: la orden sin médico con obra social se rechazó';
  END;
END $$;

-- Pasar una orden ya cargada a "sin médico" sin sacarle la obra social también se rechaza
DO $$
BEGIN
  BEGIN
    UPDATE public.ordenes
    SET obra_social_id = (SELECT id FROM public.obras_sociales ORDER BY id LIMIT 1)
    WHERE observaciones = 'PRUEBA-SIN-MEDICO';
    RAISE EXCEPTION 'FALLÓ: se agregó obra social a una orden sin médico';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: no se puede agregar obra social a una orden sin médico';
  END;
END $$;

-- 3. Con médico y obra social: sigue funcionando

INSERT INTO public.ordenes (nro_orden, paciente_id, sucursal_id, medico_id, obra_social_id, observaciones)
SELECT '', p.id, s.id, m.id, (SELECT id FROM public.obras_sociales ORDER BY id LIMIT 1), 'PRUEBA-CON-MEDICO'
FROM public.pacientes p, public.sucursales s, public.medicos m
WHERE p.dni = '99999998' AND s.prefijo = 'S1' AND m.matricula = 'PRUEBA-SM';

SELECT 'Con médico y obra social: cargada' AS resultado, nro_orden
FROM public.ordenes WHERE observaciones = 'PRUEBA-CON-MEDICO';

ROLLBACK;
