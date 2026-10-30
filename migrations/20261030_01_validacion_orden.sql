-- Validación final del bioquímico y cierre de la orden (LIMS-14)
--
-- Cuando todos los estudios de una orden tienen resultado, el bioquímico los
-- revisa y los valida. A partir de ahí la orden queda cerrada (estado 'completa':
-- ya no se puede modificar) y se crea el informe del paciente en borrador, listo
-- para firmar y publicar en una etapa posterior.
--
-- La validación es una sola operación (RPC validar_orden): guarda los valores que
-- estén en pantalla, valida todos los resultados con quién y cuándo, cierra la
-- orden y crea el informe. Si falta un resultado, hay uno rechazado o algo falla,
-- no se guarda nada.
--
-- Depende de 20261029_03_resultados.sql y 20261029_04_componentes_y_llegada.sql.

-- 1. Validar y cerrar la orden ─────────────────

CREATE FUNCTION public.validar_orden(p_orden_id uuid, p_resultados jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_orden public.ordenes;
  v_faltan integer;
  v_rechazados integer;
  v_validados integer := 0;
  v_fuera integer := 0;
  v_informe_id uuid;
BEGIN
  IF NOT privado.tiene_rol('bioquimico', 'admin') THEN
    RAISE EXCEPTION 'Solo el bioquímico valida la orden' USING ERRCODE = '42501';
  END IF;

  -- Bloquea la orden mientras se valida: dos bioquímicos a la vez no pueden cerrarla dos veces
  SELECT * INTO v_orden FROM public.ordenes WHERE id = p_orden_id FOR UPDATE;

  -- Sin fila: no existe o es de otra sucursal. La función es SECURITY DEFINER,
  -- así que la sucursal se controla a mano (las políticas no se aplican).
  IF v_orden.id IS NULL OR NOT privado.ve_sucursal(v_orden.sucursal_id) THEN
    RAISE EXCEPTION 'No se encontró la orden' USING ERRCODE = 'P0002';
  END IF;

  IF v_orden.estado = 'anulada' THEN
    RAISE EXCEPTION 'La orden % está anulada', v_orden.nro_orden USING ERRCODE = '22023';
  ELSIF v_orden.estado IN ('completa', 'informada') THEN
    RAISE EXCEPTION 'La orden % ya está validada', v_orden.nro_orden USING ERRCODE = '22023';
  END IF;

  -- Guarda lo que está en pantalla (si vino): se valida exactamente eso
  IF p_resultados IS NOT NULL THEN
    PERFORM public.guardar_resultados(p_orden_id, p_resultados);
  END IF;

  -- Todos los estudios que se cargan (los que no tienen componentes) tienen que
  -- tener resultado. Un estudio con componentes se completa con sus componentes.
  SELECT count(*) INTO v_faltan
  FROM public.orden_analisis oa
  WHERE oa.orden_id = p_orden_id
    AND NOT EXISTS (SELECT 1 FROM public.orden_analisis c WHERE c.padre_id = oa.id)
    AND NOT EXISTS (
      SELECT 1 FROM public.resultados r
      WHERE r.orden_analisis_id = oa.id
    );

  IF v_faltan > 0 THEN
    RAISE EXCEPTION 'Faltan % resultados por cargar: la orden no se puede validar', v_faltan USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_rechazados
  FROM public.resultados r
  JOIN public.orden_analisis oa ON oa.id = r.orden_analisis_id
  WHERE oa.orden_id = p_orden_id AND r.estado = 'rechazado';

  IF v_rechazados > 0 THEN
    RAISE EXCEPTION 'Hay % resultados rechazados: corríjalos antes de validar la orden', v_rechazados USING ERRCODE = '22023';
  END IF;

  -- Valida todos los resultados de la orden, con quién y cuándo
  UPDATE public.resultados r
  SET estado = 'validado',
      validado_por = auth.uid(),
      validado_en = now()
  FROM public.orden_analisis oa
  WHERE oa.id = r.orden_analisis_id
    AND oa.orden_id = p_orden_id
    AND r.estado = 'pendiente';
  GET DIAGNOSTICS v_validados = ROW_COUNT;

  SELECT count(*) INTO v_fuera
  FROM public.resultados r
  JOIN public.orden_analisis oa ON oa.id = r.orden_analisis_id
  WHERE oa.orden_id = p_orden_id AND r.fuera_de_rango;

  -- La orden queda cerrada: no se pueden cambiar más sus resultados ni sus estudios
  UPDATE public.ordenes SET estado = 'completa' WHERE id = p_orden_id;

  -- Informe en borrador para firmar y publicar después
  INSERT INTO public.informes (orden_id) VALUES (p_orden_id)
  ON CONFLICT (orden_id) DO NOTHING
  RETURNING id INTO v_informe_id;

  IF v_informe_id IS NULL THEN
    SELECT id INTO v_informe_id FROM public.informes WHERE orden_id = p_orden_id;
  END IF;

  RETURN jsonb_build_object(
    'validados', v_validados,
    'fuera_de_rango', v_fuera,
    'informe_id', v_informe_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.validar_orden(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validar_orden(uuid, jsonb) TO authenticated;

-- 2. Una orden validada no se modifica ─────────

-- Los resultados de una orden cerrada no se cargan, corrigen ni borran. El trigger
-- se llama "00" para correr antes que el control del resultado, así el mensaje es
-- el del cierre de la orden.
CREATE FUNCTION privado.controlar_resultado_orden_cerrada()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_estudio uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.orden_analisis_id ELSE NEW.orden_analisis_id END;
  v_estado public.estado_orden;
BEGIN
  SELECT o.estado INTO v_estado
  FROM public.orden_analisis oa
  JOIN public.ordenes o ON o.id = oa.orden_id
  WHERE oa.id = v_estudio;

  IF v_estado IN ('completa', 'informada', 'anulada') THEN
    RAISE EXCEPTION 'La orden ya está validada: no se pueden modificar sus resultados' USING ERRCODE = '22023';
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER resultados_00_orden_cerrada
  BEFORE INSERT OR UPDATE OR DELETE ON public.resultados
  FOR EACH ROW EXECUTE FUNCTION privado.controlar_resultado_orden_cerrada();

-- El estado de una orden cerrada no vuelve atrás: 'completa' solo puede pasar a
-- 'informada' (cuando se firma el informe) y 'informada' ya no cambia. Además,
-- solo se llega a 'completa' con todos los resultados validados: una actualización
-- directa de la tabla no puede cerrar una orden sin la validación del bioquímico.
CREATE FUNCTION privado.controlar_estado_orden()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF OLD.estado = 'completa' AND NEW.estado NOT IN ('completa', 'informada') THEN
    RAISE EXCEPTION 'La orden % ya está validada: no se puede reabrir', OLD.nro_orden USING ERRCODE = '22023';
  END IF;

  IF OLD.estado = 'informada' AND NEW.estado IS DISTINCT FROM OLD.estado THEN
    RAISE EXCEPTION 'La orden % ya fue informada: no se puede cambiar su estado', OLD.nro_orden USING ERRCODE = '22023';
  END IF;

  IF NEW.estado = 'completa' AND OLD.estado IS DISTINCT FROM 'completa' THEN
    IF NOT privado.tiene_rol('bioquimico', 'admin') THEN
      RAISE EXCEPTION 'Solo el bioquímico cierra la orden' USING ERRCODE = '42501';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.orden_analisis oa
      WHERE oa.orden_id = NEW.id
        AND NOT EXISTS (SELECT 1 FROM public.orden_analisis c WHERE c.padre_id = oa.id)
        AND NOT EXISTS (
          SELECT 1 FROM public.resultados r
          WHERE r.orden_analisis_id = oa.id AND r.estado = 'validado'
        )
    ) THEN
      RAISE EXCEPTION 'La orden % solo se cierra cuando todos sus resultados están validados', NEW.nro_orden USING ERRCODE = '22023';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER ordenes_estado_control
  BEFORE UPDATE ON public.ordenes
  FOR EACH ROW EXECUTE FUNCTION privado.controlar_estado_orden();

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;
