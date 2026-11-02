-- Registro y rotulado de muestras en extracción (LIMS-28)
--
-- Relevamiento (28/10/2026):
-- - Cuando el técnico llama al paciente desde su box, rotula sus tubos.
-- - El número de muestra es POR PACIENTE: todos sus tubos llevan el mismo y se
--   distinguen por el tipo de muestra (sangre entera, suero, orina…). Si trae
--   varias órdenes en la misma visita, todos sus tubos comparten el número.
-- - Es un correlativo del día y por sucursal que vuelve a empezar cada día
--   (M1 – 28/10/2026, M2 – 28/10/2026…). Se asigna al rotular, no al llegar:
--   quien se retira sin extraerse no gasta número.
-- - Por ahora el número se escribe a mano en el tubo (sin etiquetas impresas).
--
-- Como un tubo puede servir a varias órdenes de la misma visita, la muestra
-- pasa a pertenecer al turno (la visita) y no a una orden. Cada estudio sigue
-- diciendo en qué tubo se procesa con orden_analisis.muestra_id.

-- 1. Número de muestra del día ─────────────────

ALTER TABLE public.turnos
  ADD COLUMN numero_muestra integer,
  ADD CONSTRAINT turnos_numero_muestra_unico UNIQUE (sucursal_id, fecha, numero_muestra);

COMMENT ON COLUMN public.turnos.numero_muestra IS
  'Número de muestra del día (M1, M2…), por sucursal. Lo asigna rotular_muestras al extraer; vacío = todavía no se extrajo.';

-- Último número usado por sucursal y día. Como la numeración de órdenes, solo la
-- usa una función SECURITY DEFINER.
CREATE TABLE privado.numeracion_muestras (
  sucursal_id bigint NOT NULL REFERENCES public.sucursales(id),
  fecha date NOT NULL,
  ultimo integer NOT NULL,
  PRIMARY KEY (sucursal_id, fecha)
);

-- 2. La muestra pertenece a la visita ──────────
-- Las políticas usan muestras.orden_id: se quitan antes de sacar la columna y se
-- vuelven a crear abajo, filtradas por la sucursal del turno.

DROP POLICY "muestras: las ve el personal" ON public.muestras;
DROP POLICY "muestras: el personal registra extracciones" ON public.muestras;
DROP POLICY "muestras: tecnico, bioquimico y admin cambian el estado" ON public.muestras;

ALTER TABLE public.muestras ADD COLUMN turno_id uuid REFERENCES public.turnos(id);

-- Si hubiera muestras cargadas a mano, se pasan al turno de su orden
UPDATE public.muestras m
SET turno_id = o.turno_id
FROM public.ordenes o
WHERE o.id = m.orden_id;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.muestras WHERE turno_id IS NULL) THEN
    RAISE EXCEPTION 'Hay muestras cuya orden no tiene turno: revisarlas antes de aplicar esta migración';
  END IF;
END;
$$;

ALTER TABLE public.muestras
  ALTER COLUMN turno_id SET NOT NULL,
  DROP COLUMN orden_id,
  ADD CONSTRAINT muestras_un_tubo_por_tipo UNIQUE (turno_id, tipo_muestra_id);

COMMENT ON TABLE public.muestras IS
  'Cada tubo de una visita del paciente, uno por tipo de muestra. Estados internos: extraida → procesada o rechazada.';
COMMENT ON COLUMN public.muestras.turno_id IS
  'Visita en la que se extrajo. Todos los tubos de la visita llevan el número de muestra del turno.';
COMMENT ON COLUMN public.muestras.codigo_barras IS
  'Prefijo de la sucursal + fecha + número de muestra + tipo (ej: S1-20261028-M1-2): no se repite entre días ni sucursales.';

-- 3. Sucursal de una muestra ───────────────────

CREATE FUNCTION privado.sucursal_de_turno(p_turno_id uuid)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT sucursal_id FROM public.turnos WHERE id = p_turno_id;
$$;

CREATE OR REPLACE FUNCTION privado.sucursal_de_muestra(p_muestra_id uuid)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT t.sucursal_id
  FROM public.muestras m
  JOIN public.turnos t ON t.id = m.turno_id
  WHERE m.id = p_muestra_id;
$$;

-- 4. Políticas ─────────────────────────────────
-- Los tubos se crean solo con rotular_muestras (no hay política de alta directa).

CREATE POLICY "muestras: las ve el personal" ON public.muestras
  FOR SELECT TO authenticated
  USING ((SELECT privado.ve_sucursal(privado.sucursal_de_turno(turno_id))));

CREATE POLICY "muestras: tecnico, bioquimico y admin cambian el estado" ON public.muestras
  FOR UPDATE TO authenticated
  USING (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('tecnico', 'bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_turno(turno_id))))
  )
  WITH CHECK (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('tecnico', 'bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_turno(turno_id))))
  );

-- 5. Rotular las muestras del paciente llamado ─
-- Asigna el número M del día (si todavía no tiene), crea un tubo por cada tipo de
-- muestra de los estudios de sus órdenes y une cada estudio con su tubo. Si se
-- vuelve a llamar (ej: recepción agregó una orden), reusa el número y solo suma
-- los tubos y estudios que faltan.
-- Es SECURITY DEFINER porque el técnico no edita turnos ni estudios: revisa a
-- mano el rol y la sucursal.

CREATE FUNCTION public.rotular_muestras(p_turno_id uuid)
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

  -- Un tubo por tipo de muestra (el trigger de trazabilidad registra quién extrajo)
  INSERT INTO public.muestras (codigo_barras, turno_id, tipo_muestra_id)
  SELECT DISTINCT
    v_prefijo || '-' || to_char(v_turno.fecha, 'YYYYMMDD') || '-M' || v_turno.numero_muestra || '-' || a.tipo_muestra_id,
    p_turno_id,
    a.tipo_muestra_id
  FROM public.orden_analisis oa
  JOIN public.ordenes o ON o.id = oa.orden_id
  JOIN public.analisis a ON a.id = oa.analisis_id
  WHERE o.turno_id = p_turno_id AND o.estado <> 'anulada'
  ON CONFLICT (turno_id, tipo_muestra_id) DO NOTHING;

  -- Cada estudio (y sus componentes) queda unido al tubo de su tipo de muestra
  UPDATE public.orden_analisis oa
  SET muestra_id = m.id
  FROM public.ordenes o, public.analisis a, public.muestras m
  WHERE o.id = oa.orden_id
    AND a.id = oa.analisis_id
    AND m.turno_id = p_turno_id
    AND m.tipo_muestra_id = a.tipo_muestra_id
    AND o.turno_id = p_turno_id
    AND o.estado <> 'anulada'
    AND oa.muestra_id IS NULL;

  RETURN jsonb_build_object(
    'turno_id', p_turno_id,
    'numero_muestra', v_turno.numero_muestra,
    'fecha', v_turno.fecha
  );
END;
$$;

-- 6. Tubo no obtenido o rechazado ──────────────
-- SECURITY INVOKER: la política de UPDATE decide quién puede (técnico,
-- bioquímico o admin de la sucursal). El trigger de trazabilidad guarda el motivo.

CREATE FUNCTION public.rechazar_muestra(p_muestra_id uuid, p_motivo text)
RETURNS public.muestras
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_muestra public.muestras;
BEGIN
  IF nullif(btrim(p_motivo), '') IS NULL THEN
    RAISE EXCEPTION 'Indique el motivo' USING ERRCODE = '22023';
  END IF;

  UPDATE public.muestras
  SET estado = 'rechazada', motivo_rechazo = btrim(p_motivo)
  WHERE id = p_muestra_id AND estado = 'extraida'
  RETURNING * INTO v_muestra;

  -- Sin fila: no existe, es de otra sucursal, no tiene permiso o ya no está "extraida"
  IF v_muestra.id IS NULL THEN
    RAISE EXCEPTION 'No se encontró la muestra o ya no se puede rechazar' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_muestra;
END;
$$;

-- Las funciones del panel solo las usa el personal logueado
REVOKE ALL ON FUNCTION public.rotular_muestras(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rechazar_muestra(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rotular_muestras(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rechazar_muestra(uuid, text) TO authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;
