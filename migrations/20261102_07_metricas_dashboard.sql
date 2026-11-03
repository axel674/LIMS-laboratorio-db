-- Dashboard de métricas (LIMS-22)
--
-- Una sola función le entrega al admin los números del laboratorio para un período
-- y, si quiere, una sucursal:
-- - totales: órdenes, estudios, pacientes nuevos, lo que se factura (paciente y obra
--   social) y lo cobrado de verdad
-- - órdenes y cobros por día, órdenes por estado, estudios más pedidos,
--   cobrado por medio de pago y el rendimiento de cada sucursal
-- - Las órdenes anuladas y los cobros anulados no cuentan (salvo en "por estado").
-- - Los componentes de un estudio (padre_id) no se cuentan aparte, igual que en los cobros.
-- - Los días se miden en hora de Tucumán, no en UTC.
--
-- Solo el admin la puede llamar: ve todas las sucursales.
-- Depende de 20261102_05_cobros.sql.

CREATE FUNCTION public.metricas_dashboard(
  p_desde date,
  p_hasta date,
  p_sucursal_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_zona constant text := 'America/Argentina/Tucuman';
  v_resultado jsonb;
BEGIN
  IF NOT privado.tiene_rol('admin') THEN
    RAISE EXCEPTION 'Solo el administrador puede ver las métricas' USING ERRCODE = '42501';
  END IF;
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta THEN
    RAISE EXCEPTION 'Indique un rango de fechas válido' USING ERRCODE = '22023';
  END IF;
  IF p_hasta - p_desde > 366 THEN
    RAISE EXCEPTION 'El rango no puede superar un año' USING ERRCODE = '22023';
  END IF;

  WITH
  -- Órdenes del período (todas, anuladas incluidas) con el día en hora local
  ord AS (
    SELECT o.id, o.estado, o.sucursal_id, o.paciente_id,
           (o.fecha_recepcion AT TIME ZONE v_zona)::date AS dia
    FROM public.ordenes o
    WHERE (o.fecha_recepcion AT TIME ZONE v_zona)::date BETWEEN p_desde AND p_hasta
      AND (p_sucursal_id IS NULL OR o.sucursal_id = p_sucursal_id)
  ),
  vigentes AS (SELECT * FROM ord WHERE estado <> 'anulada'),
  -- Estudios pedidos en órdenes vigentes, con lo que se factura de cada uno
  est AS (
    SELECT v.sucursal_id, v.dia, oa.analisis_id,
           coalesce(oa.importe_paciente, 0) AS importe_paciente,
           coalesce(oa.importe_obra_social, 0) AS importe_obra_social
    FROM vigentes v
    JOIN public.orden_analisis oa ON oa.orden_id = v.id AND oa.padre_id IS NULL
  ),
  cob AS (
    SELECT c.sucursal_id, c.medio_pago, c.monto,
           (c.cobrado_en AT TIME ZONE v_zona)::date AS dia
    FROM public.cobros c
    WHERE c.anulado_en IS NULL
      AND (c.cobrado_en AT TIME ZONE v_zona)::date BETWEEN p_desde AND p_hasta
      AND (p_sucursal_id IS NULL OR c.sucursal_id = p_sucursal_id)
  ),
  -- Con una sucursal elegida, "nuevos" son los registrados en el período que tienen una orden ahí
  nuevos AS (
    SELECT count(*) AS cantidad
    FROM public.pacientes p
    WHERE (p.created_at AT TIME ZONE v_zona)::date BETWEEN p_desde AND p_hasta
      AND (p_sucursal_id IS NULL OR EXISTS (
        SELECT 1 FROM public.ordenes o
        WHERE o.paciente_id = p.id AND o.sucursal_id = p_sucursal_id
      ))
  ),
  dias AS (SELECT d::date AS dia FROM generate_series(p_desde, p_hasta, interval '1 day') AS d)
  SELECT jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'sucursal_id', p_sucursal_id,
    'totales', jsonb_build_object(
      'ordenes', (SELECT count(*) FROM vigentes),
      'estudios', (SELECT count(*) FROM est),
      'pacientes_nuevos', (SELECT cantidad FROM nuevos),
      'facturado_pacientes', (SELECT coalesce(sum(importe_paciente), 0) FROM est),
      'facturado_obras_sociales', (SELECT coalesce(sum(importe_obra_social), 0) FROM est),
      'cobrado', (SELECT coalesce(sum(monto), 0) FROM cob)
    ),
    'por_dia', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'dia', d.dia,
        'ordenes', (SELECT count(*) FROM vigentes v WHERE v.dia = d.dia),
        'estudios', (SELECT count(*) FROM est e WHERE e.dia = d.dia),
        'cobrado', (SELECT coalesce(sum(monto), 0) FROM cob c WHERE c.dia = d.dia)
      ) ORDER BY d.dia), '[]'::jsonb)
      FROM dias d
    ),
    'por_estado', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('estado', estado, 'cantidad', cantidad)
                                ORDER BY estado), '[]'::jsonb)
      FROM (SELECT estado, count(*) AS cantidad FROM ord GROUP BY estado) t
    ),
    'top_analisis', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'cantidad', cantidad)
                                ORDER BY cantidad DESC, nombre), '[]'::jsonb)
      FROM (
        SELECT a.codigo, a.nombre, count(*) AS cantidad
        FROM est e JOIN public.analisis a ON a.id = e.analisis_id
        GROUP BY a.codigo, a.nombre
        ORDER BY count(*) DESC, a.nombre
        LIMIT 8
      ) t
    ),
    'por_medio_pago', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('medio_pago', medio_pago, 'monto', monto)
                                ORDER BY monto DESC), '[]'::jsonb)
      FROM (SELECT medio_pago, sum(monto) AS monto FROM cob GROUP BY medio_pago) t
    ),
    'por_sucursal', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'sucursal_id', s.id,
        'nombre', s.nombre,
        'ordenes', (SELECT count(*) FROM vigentes v WHERE v.sucursal_id = s.id),
        'estudios', (SELECT count(*) FROM est e WHERE e.sucursal_id = s.id),
        'facturado', (SELECT coalesce(sum(importe_paciente + importe_obra_social), 0)
                      FROM est e WHERE e.sucursal_id = s.id),
        'cobrado', (SELECT coalesce(sum(monto), 0) FROM cob c WHERE c.sucursal_id = s.id)
      ) ORDER BY s.nombre), '[]'::jsonb)
      FROM public.sucursales s
      WHERE p_sucursal_id IS NULL OR s.id = p_sucursal_id
    )
  ) INTO v_resultado;

  RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION public.metricas_dashboard(date, date, bigint) IS
  'Números del dashboard del admin para un período y, opcionalmente, una sucursal.';

REVOKE ALL ON FUNCTION public.metricas_dashboard(date, date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.metricas_dashboard(date, date, bigint) TO authenticated;
