-- Dashboard de métricas: todas las secciones (LIMS-22)
--
-- Reemplaza metricas_dashboard (20261102_07) con lo que se definió para el
-- dashboard del admin. Una sola función devuelve todo, para un período y, si se
-- elige, una sucursal; la pantalla muestra u oculta cada sección.
--
-- - Actividad: órdenes, estudios y pacientes atendidos; órdenes por día y por estado.
-- - Facturación y cobros: a cargo del paciente, a facturar a obras sociales, lo
--   cobrado (por medio de pago) y lo pendiente de cobro.
-- - Por obra social: órdenes y montos de cada una (y particulares).
-- - Tiempos: días promedio hasta informar, órdenes atrasadas y espera en la fila.
-- - Calidad: resultados fuera de rango y tubos rechazados, con los motivos.
-- - Estudios más pedidos y médicos que más derivan.
-- - Por sucursal: las mismas cifras lado a lado.
--
-- Reglas:
-- - Las órdenes y los cobros anulados no cuentan (salvo en "por estado").
-- - Los componentes de un estudio (padre_id) no se cuentan ni se cobran aparte;
--   sí cuentan sus resultados en "fuera de rango".
-- - Pendiente de cobro: por cada orden del período, lo que paga el paciente menos
--   lo cobrado de esa orden (cualquier día), sin bajar de cero.
-- - Atrasada: orden del período sin informar cuyo plazo venció (la fecha de
--   recepción más los días de demora del estudio más lento).
-- - Los días se miden en hora de Tucumán.
--
-- Solo la puede llamar el admin: ve todas las sucursales.

CREATE OR REPLACE FUNCTION public.metricas_dashboard(
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
  -- Órdenes del período (anuladas incluidas) con el día en hora local
  ord AS (
    SELECT o.id, o.estado, o.sucursal_id, o.paciente_id, o.medico_id, o.obra_social_id,
           o.fecha_recepcion, (o.fecha_recepcion AT TIME ZONE v_zona)::date AS dia
    FROM public.ordenes o
    WHERE (o.fecha_recepcion AT TIME ZONE v_zona)::date BETWEEN p_desde AND p_hasta
      AND (p_sucursal_id IS NULL OR o.sucursal_id = p_sucursal_id)
  ),
  vigentes AS (SELECT * FROM ord WHERE estado <> 'anulada'),
  -- Estudios pedidos (sin componentes) con lo que se factura de cada uno
  est AS (
    SELECT v.id AS orden_id, v.sucursal_id, v.dia, oa.analisis_id,
           coalesce(oa.importe_paciente, 0) AS importe_paciente,
           coalesce(oa.importe_obra_social, 0) AS importe_obra_social
    FROM vigentes v
    JOIN public.orden_analisis oa ON oa.orden_id = v.id AND oa.padre_id IS NULL
  ),
  -- Por orden: lo que paga el paciente, lo cobrado (cualquier día) y lo que falta
  cuenta AS (
    SELECT v.id AS orden_id, v.sucursal_id,
           coalesce((SELECT sum(e.importe_paciente) FROM est e WHERE e.orden_id = v.id), 0) AS total,
           coalesce((SELECT sum(c.monto) FROM public.cobros c
                     WHERE c.orden_id = v.id AND c.anulado_en IS NULL), 0) AS cobrado
    FROM vigentes v
  ),
  pendiente AS (
    SELECT orden_id, sucursal_id, greatest(total - cobrado, 0) AS monto FROM cuenta
  ),
  -- Cobros hechos en el período (de cualquier orden), sin los anulados
  cob AS (
    SELECT c.sucursal_id, c.medio_pago, c.monto,
           (c.cobrado_en AT TIME ZONE v_zona)::date AS dia
    FROM public.cobros c
    WHERE c.anulado_en IS NULL
      AND (c.cobrado_en AT TIME ZONE v_zona)::date BETWEEN p_desde AND p_hasta
      AND (p_sucursal_id IS NULL OR c.sucursal_id = p_sucursal_id)
  ),
  -- Órdenes sin informar con el plazo vencido
  atrasadas AS (
    SELECT v.id, v.sucursal_id
    FROM vigentes v
    WHERE v.estado <> 'informada'
      AND v.dia + coalesce((
            SELECT max(a.dias_demora)
            FROM public.orden_analisis oa
            JOIN public.analisis a ON a.id = oa.analisis_id
            WHERE oa.orden_id = v.id
          ), 0) < privado.hoy()
  ),
  -- Días entre la recepción y la publicación del informe
  informadas AS (
    SELECT v.sucursal_id,
           extract(epoch FROM (i.publicado_en - v.fecha_recepcion)) / 86400.0 AS dias
    FROM vigentes v
    JOIN public.informes i ON i.orden_id = v.id AND i.estado = 'publicado' AND i.publicado_en IS NOT NULL
  ),
  -- Minutos entre la llegada a la fila y el llamado
  espera AS (
    SELECT t.sucursal_id, extract(epoch FROM (t.llamado_at - t.created_at)) / 60.0 AS minutos
    FROM public.turnos t
    WHERE t.fecha BETWEEN p_desde AND p_hasta
      AND t.llamado_at IS NOT NULL
      AND (p_sucursal_id IS NULL OR t.sucursal_id = p_sucursal_id)
  ),
  -- Resultados de las órdenes del período (componentes incluidos)
  res AS (
    SELECT r.fuera_de_rango
    FROM vigentes v
    JOIN public.orden_analisis oa ON oa.orden_id = v.id
    JOIN public.resultados r ON r.orden_analisis_id = oa.id
  ),
  -- Tubos extraídos en el período
  tubos AS (
    SELECT m.estado, nullif(btrim(m.motivo_rechazo), '') AS motivo
    FROM public.muestras m
    JOIN public.turnos t ON t.id = m.turno_id
    WHERE t.fecha BETWEEN p_desde AND p_hasta
      AND (p_sucursal_id IS NULL OR t.sucursal_id = p_sucursal_id)
  ),
  dias AS (SELECT d::date AS dia FROM generate_series(p_desde, p_hasta, interval '1 day') AS d)
  SELECT jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'sucursal_id', p_sucursal_id,
    'totales', jsonb_build_object(
      'ordenes', (SELECT count(*) FROM vigentes),
      'estudios', (SELECT count(*) FROM est),
      'pacientes', (SELECT count(DISTINCT paciente_id) FROM vigentes),
      'facturado_pacientes', (SELECT coalesce(sum(importe_paciente), 0) FROM est),
      'facturado_obras_sociales', (SELECT coalesce(sum(importe_obra_social), 0) FROM est),
      'cobrado', (SELECT coalesce(sum(monto), 0) FROM cob),
      'pendiente_cobro', (SELECT coalesce(sum(monto), 0) FROM pendiente),
      'ordenes_con_saldo', (SELECT count(*) FROM pendiente WHERE monto > 0),
      'atrasadas', (SELECT count(*) FROM atrasadas)
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
    'por_medio_pago', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('medio_pago', medio_pago, 'monto', monto, 'cantidad', cantidad)
                                ORDER BY monto DESC), '[]'::jsonb)
      FROM (SELECT medio_pago, sum(monto) AS monto, count(*) AS cantidad FROM cob GROUP BY medio_pago) t
    ),
    -- obra_social_id vacío = particular
    'por_obra_social', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'obra_social_id', t.obra_social_id,
        'nombre', coalesce(os.nombre, 'Particular'),
        'ordenes', t.ordenes,
        'facturado_obra_social', t.facturado_obra_social,
        'facturado_paciente', t.facturado_paciente
      ) ORDER BY t.ordenes DESC, coalesce(os.nombre, 'Particular')), '[]'::jsonb)
      FROM (
        SELECT v.obra_social_id, count(DISTINCT v.id) AS ordenes,
               coalesce(sum(e.importe_obra_social), 0) AS facturado_obra_social,
               coalesce(sum(e.importe_paciente), 0) AS facturado_paciente
        FROM vigentes v
        LEFT JOIN est e ON e.orden_id = v.id
        GROUP BY v.obra_social_id
      ) t
      LEFT JOIN public.obras_sociales os ON os.id = t.obra_social_id
    ),
    'tiempos', jsonb_build_object(
      'dias_hasta_informar', (SELECT round(avg(dias)::numeric, 1) FROM informadas),
      'informadas', (SELECT count(*) FROM informadas),
      'espera_fila_minutos', (SELECT round(avg(minutos)::numeric, 0) FROM espera),
      'llamados', (SELECT count(*) FROM espera),
      'atrasadas', (SELECT count(*) FROM atrasadas)
    ),
    'calidad', jsonb_build_object(
      'resultados', (SELECT count(*) FROM res),
      'fuera_de_rango', (SELECT count(*) FROM res WHERE fuera_de_rango),
      'tubos', (SELECT count(*) FROM tubos),
      'tubos_rechazados', (SELECT count(*) FROM tubos WHERE estado = 'rechazada'),
      'motivos', (
        SELECT coalesce(jsonb_agg(jsonb_build_object('motivo', motivo, 'cantidad', cantidad)
                                  ORDER BY cantidad DESC, motivo), '[]'::jsonb)
        FROM (
          SELECT motivo, count(*) AS cantidad
          FROM tubos WHERE estado = 'rechazada' AND motivo IS NOT NULL
          GROUP BY motivo ORDER BY count(*) DESC, motivo LIMIT 5
        ) t
      )
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
    -- Las órdenes sin pedido médico no cuentan acá
    'top_medicos', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'medico_id', id, 'nombre', nombre, 'apellido', apellido, 'matricula', matricula,
        'ordenes', ordenes, 'estudios', estudios
      ) ORDER BY ordenes DESC, apellido, nombre), '[]'::jsonb)
      FROM (
        SELECT m.id, m.nombre, m.apellido, m.matricula,
               count(DISTINCT v.id) AS ordenes, count(e.orden_id) AS estudios
        FROM vigentes v
        JOIN public.medicos m ON m.id = v.medico_id
        LEFT JOIN est e ON e.orden_id = v.id
        GROUP BY m.id, m.nombre, m.apellido, m.matricula
        ORDER BY count(DISTINCT v.id) DESC, m.apellido, m.nombre
        LIMIT 8
      ) t
    ),
    'por_sucursal', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'sucursal_id', s.id,
        'nombre', s.nombre,
        'ordenes', (SELECT count(*) FROM vigentes v WHERE v.sucursal_id = s.id),
        'estudios', (SELECT count(*) FROM est e WHERE e.sucursal_id = s.id),
        'facturado', (SELECT coalesce(sum(importe_paciente + importe_obra_social), 0)
                      FROM est e WHERE e.sucursal_id = s.id),
        'cobrado', (SELECT coalesce(sum(monto), 0) FROM cob c WHERE c.sucursal_id = s.id),
        'pendiente_cobro', (SELECT coalesce(sum(monto), 0) FROM pendiente p WHERE p.sucursal_id = s.id),
        'atrasadas', (SELECT count(*) FROM atrasadas a WHERE a.sucursal_id = s.id),
        'dias_hasta_informar', (SELECT round(avg(dias)::numeric, 1) FROM informadas i WHERE i.sucursal_id = s.id)
      ) ORDER BY s.nombre), '[]'::jsonb)
      FROM public.sucursales s
      WHERE p_sucursal_id IS NULL OR s.id = p_sucursal_id
    )
  ) INTO v_resultado;

  RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION public.metricas_dashboard(date, date, bigint) IS
  'Números del dashboard del admin para un período y, opcionalmente, una sucursal: actividad, facturación y cobros, obras sociales, tiempos, calidad, estudios más pedidos, médicos que más derivan y comparación por sucursal.';

REVOKE ALL ON FUNCTION public.metricas_dashboard(date, date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.metricas_dashboard(date, date, bigint) TO authenticated;
