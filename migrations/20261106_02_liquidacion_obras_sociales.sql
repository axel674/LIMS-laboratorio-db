-- Liquidación mensual a obras sociales (LIMS-47)
--
-- El admin elige una obra social y un mes y obtiene lo que hay que presentarle para
-- cobrarle: una fila por estudio cubierto de las órdenes del mes, con los datos que
-- pide la obra social (número de afiliado, médico y matrícula, código NBU, UB e
-- importe). El dashboard (LIMS-22) ya muestra el total por obra social, pero no el
-- detalle por estudio ni el número de afiliado.
--
-- Reglas:
-- - Órdenes de esa obra social recibidas en el mes (día de Tucumán), de todas las
--   sucursales. Las anuladas no se presentan.
-- - Solo los estudios que cubre la obra social (orden_analisis.cubierto): los no
--   cubiertos los pagó el paciente como particulares.
-- - Los componentes (padre_id) no se presentan aparte: van con su estudio.
-- - Los importes son los que se guardaron al cargar la orden (aranceles, LIMS-32).
--   Un estudio sin arancel cargado sale con el importe vacío, para que se note.
--
-- Solo el admin la puede llamar. SECURITY INVOKER: el admin ve todas las sucursales
-- por las políticas de RLS. Depende de 20261031_01_aranceles.sql.

CREATE FUNCTION public.liquidacion_obra_social(p_obra_social_id bigint, p_mes date)
RETURNS TABLE (
  fecha date,
  nro_orden text,
  sucursal text,
  paciente text,
  dni text,
  nro_afiliado text,
  medico text,
  matricula text,
  codigo_nbu text,
  codigo text,
  estudio text,
  ub numeric,
  valor_ub numeric,
  importe_obra_social numeric,
  coseguro_paciente numeric
)
LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE
  v_zona constant text := 'America/Argentina/Tucuman';
  -- Cualquier día del mes sirve: se toma el mes entero
  v_desde date := date_trunc('month', p_mes)::date;
  v_hasta date := (date_trunc('month', p_mes) + interval '1 month')::date;
BEGIN
  IF NOT privado.tiene_rol('admin') THEN
    RAISE EXCEPTION 'Solo el administrador puede ver la liquidación' USING ERRCODE = '42501';
  END IF;
  IF p_obra_social_id IS NULL OR p_mes IS NULL THEN
    RAISE EXCEPTION 'Elija la obra social y el mes' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    (o.fecha_recepcion AT TIME ZONE v_zona)::date,
    o.nro_orden::text,
    s.nombre::text,
    (p.apellido || ', ' || p.nombre)::text,
    p.dni::text,
    p.nro_afiliado::text,
    CASE WHEN m.id IS NULL THEN NULL ELSE (m.apellido || ', ' || m.nombre) END::text,
    m.matricula::text,
    a.codigo_nbu::text,
    a.codigo::text,
    a.nombre::text,
    oa.ub,
    oa.valor_ub,
    oa.importe_obra_social,
    oa.importe_paciente
  FROM public.ordenes o
  JOIN public.pacientes p ON p.id = o.paciente_id
  LEFT JOIN public.sucursales s ON s.id = o.sucursal_id
  LEFT JOIN public.medicos m ON m.id = o.medico_id
  JOIN public.orden_analisis oa ON oa.orden_id = o.id
  JOIN public.analisis a ON a.id = oa.analisis_id
  WHERE o.obra_social_id = p_obra_social_id
    AND o.estado <> 'anulada'
    AND o.fecha_recepcion >= (v_desde::timestamp AT TIME ZONE v_zona)
    AND o.fecha_recepcion < (v_hasta::timestamp AT TIME ZONE v_zona)
    AND oa.padre_id IS NULL
    AND oa.cubierto
  ORDER BY o.fecha_recepcion, o.nro_orden, a.nombre;
END;
$$;

COMMENT ON FUNCTION public.liquidacion_obra_social(bigint, date) IS
  'Detalle para presentarle a una obra social lo del mes: una fila por estudio cubierto de sus órdenes no anuladas. Solo el admin.';

REVOKE ALL ON FUNCTION public.liquidacion_obra_social(bigint, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.liquidacion_obra_social(bigint, date) TO authenticated;
