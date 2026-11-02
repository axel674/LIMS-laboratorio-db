-- Volver a extraer un tubo rechazado (LIMS-28)
--
-- Con 20261102_03 había un solo tubo por tipo de muestra en cada visita, contando
-- los rechazados: si el tubo de suero salía hemolizado o no se obtenía, no había
-- forma de sacar otro y sus estudios quedaban unidos al tubo rechazado.
--
-- Ahora:
-- - La regla "un tubo por tipo" cuenta solo los tubos que no están rechazados.
-- - rotular_muestras crea un tubo nuevo para el tipo cuyo tubo se rechazó y le pasa
--   los estudios. El tubo rechazado queda con su motivo en la trazabilidad.
-- - El tubo nuevo lleva el mismo número de muestra del paciente y un sufijo con el
--   intento (ej: S1-20261102-M1-3-2), porque el código de barras no se repite.

-- 1. Un tubo activo por tipo ───────────────────

ALTER TABLE public.muestras DROP CONSTRAINT muestras_un_tubo_por_tipo;

CREATE UNIQUE INDEX muestras_un_tubo_activo_por_tipo
  ON public.muestras (turno_id, tipo_muestra_id)
  WHERE estado <> 'rechazada';

COMMENT ON INDEX public.muestras_un_tubo_activo_por_tipo IS
  'Un tubo por tipo de muestra en cada visita, sin contar los rechazados (se puede volver a extraer).';

-- 2. Rotular también reemplaza los tubos rechazados

CREATE OR REPLACE FUNCTION public.rotular_muestras(p_turno_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_turno public.turnos;
  v_prefijo varchar;
BEGIN
  IF NOT privado.tiene_rol('tecnico', 'bioquimico', 'admin') THEN
    RAISE EXCEPTION 'Solo extracción puede rotular muestras' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_turno FROM public.turnos WHERE id = p_turno_id FOR UPDATE;
  IF NOT FOUND OR NOT privado.ve_sucursal(v_turno.sucursal_id) THEN
    RAISE EXCEPTION 'El turno no existe' USING ERRCODE = 'P0002';
  END IF;
  IF v_turno.estado <> 'llamado' OR v_turno.fecha <> privado.hoy() THEN
    RAISE EXCEPTION 'Solo se rotulan las muestras del paciente que está llamado hoy' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.orden_analisis oa
    JOIN public.ordenes o ON o.id = oa.orden_id
    WHERE o.turno_id = p_turno_id AND o.estado <> 'anulada'
  ) THEN
    RAISE EXCEPTION 'El paciente no tiene órdenes con estudios: recepción tiene que cargar la orden antes de extraer'
      USING ERRCODE = '22023';
  END IF;

  -- INSERT ... ON CONFLICT reserva el número de forma atómica: dos boxes que
  -- rotulan a la vez nunca reciben el mismo
  IF v_turno.numero_muestra IS NULL THEN
    INSERT INTO privado.numeracion_muestras AS n (sucursal_id, fecha, ultimo)
    VALUES (v_turno.sucursal_id, v_turno.fecha, 1)
    ON CONFLICT (sucursal_id, fecha) DO UPDATE SET ultimo = n.ultimo + 1
    RETURNING ultimo INTO v_turno.numero_muestra;

    UPDATE public.turnos SET numero_muestra = v_turno.numero_muestra WHERE id = p_turno_id;
  END IF;

  SELECT prefijo INTO v_prefijo FROM public.sucursales WHERE id = v_turno.sucursal_id;

  -- Un tubo por tipo de muestra que todavía no tenga uno activo (nunca se sacó, o se
  -- rechazó). Desde el segundo intento el código lleva el número de intento al final.
  -- El trigger de trazabilidad registra quién extrajo.
  INSERT INTO public.muestras (codigo_barras, turno_id, tipo_muestra_id)
  SELECT
    v_prefijo || '-' || to_char(v_turno.fecha, 'YYYYMMDD') || '-M' || v_turno.numero_muestra || '-' || tipos.tipo_muestra_id
      || CASE WHEN tipos.anteriores > 0 THEN '-' || (tipos.anteriores + 1) ELSE '' END,
    p_turno_id,
    tipos.tipo_muestra_id
  FROM (
    SELECT DISTINCT a.tipo_muestra_id,
      (SELECT count(*) FROM public.muestras x WHERE x.turno_id = p_turno_id AND x.tipo_muestra_id = a.tipo_muestra_id) AS anteriores
    FROM public.orden_analisis oa
    JOIN public.ordenes o ON o.id = oa.orden_id
    JOIN public.analisis a ON a.id = oa.analisis_id
    WHERE o.turno_id = p_turno_id AND o.estado <> 'anulada'
  ) AS tipos
  WHERE NOT EXISTS (
    SELECT 1 FROM public.muestras x
    WHERE x.turno_id = p_turno_id AND x.tipo_muestra_id = tipos.tipo_muestra_id AND x.estado <> 'rechazada'
  )
  ON CONFLICT (turno_id, tipo_muestra_id) WHERE estado <> 'rechazada' DO NOTHING;

  -- Cada estudio (y sus componentes) sin tubo, o con su tubo rechazado, pasa al tubo
  -- activo de su tipo de muestra
  UPDATE public.orden_analisis oa
  SET muestra_id = m.id
  FROM public.ordenes o, public.analisis a, public.muestras m
  WHERE o.id = oa.orden_id
    AND a.id = oa.analisis_id
    AND m.turno_id = p_turno_id
    AND m.tipo_muestra_id = a.tipo_muestra_id
    AND m.estado <> 'rechazada'
    AND o.turno_id = p_turno_id
    AND o.estado <> 'anulada'
    AND (oa.muestra_id IS NULL
         OR EXISTS (SELECT 1 FROM public.muestras r WHERE r.id = oa.muestra_id AND r.estado = 'rechazada'));

  RETURN jsonb_build_object(
    'turno_id', p_turno_id,
    'numero_muestra', v_turno.numero_muestra,
    'fecha', v_turno.fecha
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rotular_muestras(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rotular_muestras(uuid) TO authenticated;
