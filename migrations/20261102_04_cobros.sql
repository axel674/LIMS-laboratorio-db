-- Cobros por orden (LIMS-19)
--
-- Recepción registra lo que paga el paciente por su orden y con qué medio.
-- - Lo que hay que cobrar ya lo calcula la base (aranceles, 20261031_01): la suma
--   de orden_analisis.importe_paciente de los estudios de la orden. Los componentes
--   (padre_id) no se cobran aparte. Lo que paga la obra social se factura aparte.
-- - Se puede pagar en partes (ej: una parte en efectivo y otra con débito). La
--   orden está pagada cuando lo cobrado cubre el total; no es un estado nuevo de
--   la orden, sale de sumar sus cobros.
-- - Un cobro mal cargado no se borra: se anula con motivo, como las órdenes.
-- - Una orden con cobros vigentes no se puede anular: primero se anulan los cobros.
-- - Recepción y el admin registran y anulan; el personal de la sucursal los ve.
--   La caja diaria (LIMS-20) va a sumar estos cobros por sucursal y por día.
--
-- Depende de 20261031_01_aranceles.sql.

-- 1. Cobros ────────────────────────────────────

CREATE TYPE public.medio_pago AS ENUM ('efectivo', 'debito', 'credito', 'transferencia');

CREATE TABLE public.cobros (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  orden_id uuid NOT NULL REFERENCES public.ordenes (id),
  -- La de la orden: la caja de cada sucursal suma sus cobros
  sucursal_id bigint NOT NULL REFERENCES public.sucursales (id),
  monto numeric(12,2) NOT NULL CHECK (monto > 0),
  medio_pago public.medio_pago NOT NULL,
  observaciones varchar(200),
  cobrado_por uuid NOT NULL REFERENCES public.perfiles (id),
  cobrado_en timestamptz NOT NULL DEFAULT now(),
  motivo_anulacion text,
  anulado_por uuid REFERENCES public.perfiles (id),
  anulado_en timestamptz,
  CONSTRAINT cobros_anulacion_completa
    CHECK ((anulado_en IS NULL) = (nullif(btrim(motivo_anulacion), '') IS NULL))
);

CREATE INDEX cobros_orden_id_idx ON public.cobros (orden_id);
CREATE INDEX cobros_sucursal_dia_idx ON public.cobros (sucursal_id, cobrado_en);

COMMENT ON TABLE public.cobros IS
  'Lo que pagó el paciente por una orden. Se registra y se anula solo con registrar_cobro y anular_cobro.';
COMMENT ON COLUMN public.cobros.sucursal_id IS 'Sucursal de la orden: la caja diaria suma los cobros de cada sucursal.';
COMMENT ON COLUMN public.cobros.motivo_anulacion IS 'Obligatorio cuando el cobro se anula. Un cobro anulado no cuenta.';

-- 2. Cuenta de una orden ───────────────────────
-- total: lo que paga el paciente · cobrado: la suma de sus cobros vigentes

CREATE FUNCTION privado.cuenta_de_orden(p_orden_id uuid, OUT total numeric, OUT cobrado numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    (SELECT coalesce(sum(importe_paciente), 0)
     FROM public.orden_analisis
     WHERE orden_id = p_orden_id AND padre_id IS NULL),
    (SELECT coalesce(sum(monto), 0)
     FROM public.cobros
     WHERE orden_id = p_orden_id AND anulado_en IS NULL);
$$;

-- 3. Seguridad ─────────────────────────────────
-- Nadie escribe la tabla directo: las funciones controlan el saldo y la anulación.

ALTER TABLE public.cobros ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON public.cobros FROM authenticated, anon;

CREATE POLICY "cobros: los ve el personal de la sucursal" ON public.cobros
  FOR SELECT TO authenticated
  USING ((SELECT privado.ve_sucursal(sucursal_id)));

-- 4. Registrar un cobro ────────────────────────
-- SECURITY DEFINER: revisa a mano el rol y la sucursal. Bloquea la orden mientras
-- calcula el saldo, así dos cobros a la vez no pasan del total.

CREATE FUNCTION public.registrar_cobro(
  p_orden_id uuid,
  p_monto numeric,
  p_medio_pago public.medio_pago,
  p_observaciones text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_orden public.ordenes;
  v_cuenta record;
  v_saldo numeric;
  v_cobro public.cobros;
BEGIN
  IF NOT privado.tiene_rol('recepcion', 'admin') THEN
    RAISE EXCEPTION 'Solo recepción puede registrar cobros' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_orden FROM public.ordenes WHERE id = p_orden_id FOR UPDATE;
  IF NOT FOUND OR NOT privado.ve_sucursal(v_orden.sucursal_id) THEN
    RAISE EXCEPTION 'No se encontró la orden' USING ERRCODE = 'P0002';
  END IF;
  IF v_orden.estado = 'anulada' THEN
    RAISE EXCEPTION 'La orden % está anulada: no se puede cobrar', v_orden.nro_orden USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_cuenta FROM privado.cuenta_de_orden(p_orden_id);
  v_saldo := v_cuenta.total - v_cuenta.cobrado;

  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'Ingrese un monto mayor a cero' USING ERRCODE = '22023';
  END IF;
  IF v_saldo <= 0 THEN
    RAISE EXCEPTION 'La orden % ya está paga', v_orden.nro_orden USING ERRCODE = '22023';
  END IF;
  IF p_monto > v_saldo THEN
    RAISE EXCEPTION 'El monto supera lo que falta cobrar ($ %)', round(v_saldo, 2) USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.cobros (orden_id, sucursal_id, monto, medio_pago, observaciones, cobrado_por)
  VALUES (p_orden_id, v_orden.sucursal_id, round(p_monto, 2), p_medio_pago,
          nullif(btrim(p_observaciones), ''), auth.uid())
  RETURNING * INTO v_cobro;

  RETURN jsonb_build_object(
    'cobro', to_jsonb(v_cobro),
    'total', v_cuenta.total,
    'cobrado', v_cuenta.cobrado + v_cobro.monto,
    'saldo', v_saldo - v_cobro.monto
  );
END;
$$;

-- 5. Anular un cobro ───────────────────────────

CREATE FUNCTION public.anular_cobro(p_cobro_id bigint, p_motivo text)
RETURNS public.cobros
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_cobro public.cobros;
BEGIN
  IF NOT privado.tiene_rol('recepcion', 'admin') THEN
    RAISE EXCEPTION 'Solo recepción puede anular cobros' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_motivo), '') IS NULL THEN
    RAISE EXCEPTION 'Indique el motivo de la anulación' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_cobro FROM public.cobros WHERE id = p_cobro_id FOR UPDATE;
  IF NOT FOUND OR NOT privado.ve_sucursal(v_cobro.sucursal_id) THEN
    RAISE EXCEPTION 'No se encontró el cobro' USING ERRCODE = 'P0002';
  END IF;
  IF v_cobro.anulado_en IS NOT NULL THEN
    RAISE EXCEPTION 'El cobro ya está anulado' USING ERRCODE = '22023';
  END IF;

  UPDATE public.cobros
  SET motivo_anulacion = btrim(p_motivo), anulado_por = auth.uid(), anulado_en = now()
  WHERE id = p_cobro_id
  RETURNING * INTO v_cobro;

  RETURN v_cobro;
END;
$$;

-- 6. Una orden cobrada no se anula ─────────────

CREATE FUNCTION privado.controlar_anulacion_con_cobros()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NEW.estado = 'anulada' AND OLD.estado <> 'anulada' AND EXISTS (
    SELECT 1 FROM public.cobros WHERE orden_id = NEW.id AND anulado_en IS NULL
  ) THEN
    RAISE EXCEPTION 'La orden % tiene cobros: anúlelos antes de anular la orden', OLD.nro_orden
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER ordenes_cobros_al_anular
  BEFORE UPDATE OF estado ON public.ordenes
  FOR EACH ROW EXECUTE FUNCTION privado.controlar_anulacion_con_cobros();

-- Las funciones del panel solo las usa el personal logueado
REVOKE ALL ON FUNCTION public.registrar_cobro(uuid, numeric, public.medio_pago, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.anular_cobro(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_cobro(uuid, numeric, public.medio_pago, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.anular_cobro(bigint, text) TO authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;
