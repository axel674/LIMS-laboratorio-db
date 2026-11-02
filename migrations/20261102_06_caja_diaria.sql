-- Caja diaria por sucursal (LIMS-20)
--
-- Al empezar el día, recepción abre la caja de su sucursal con el efectivo inicial.
-- Al terminar la cierra contando el efectivo, y el sistema muestra lo cobrado en el
-- día por cada medio de pago y la diferencia entre lo esperado y lo contado.
--
-- Decidido con el equipo (02/11/2026):
-- - Para cobrar hay que tener abierta la caja del día de la sucursal de la orden.
-- - Con la caja cerrada no se cobra ni se anulan cobros de ese día (cambiarían el
--   cierre). Si hubo un error, el admin la reabre con motivo.
-- - Una caja por sucursal y por día. Lo esperado en efectivo es el monto inicial
--   más los cobros en efectivo del día; los demás medios se informan como total.
--
-- Depende de 20261102_05_cobros.sql.

-- 1. Cajas ─────────────────────────────────────

CREATE TABLE public.cajas (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sucursal_id bigint NOT NULL REFERENCES public.sucursales (id),
  fecha date NOT NULL,
  monto_inicial numeric(12,2) NOT NULL CHECK (monto_inicial >= 0),
  abierta_por uuid NOT NULL REFERENCES public.perfiles (id),
  abierta_en timestamptz NOT NULL DEFAULT now(),
  -- Efectivo que había en la caja al cerrarla
  monto_contado numeric(12,2) CHECK (monto_contado >= 0),
  observaciones_cierre varchar(300),
  cerrada_por uuid REFERENCES public.perfiles (id),
  cerrada_en timestamptz,
  -- Última reapertura (la hace el admin, con motivo)
  motivo_reapertura text,
  reabierta_por uuid REFERENCES public.perfiles (id),
  reabierta_en timestamptz,
  CONSTRAINT cajas_una_por_dia UNIQUE (sucursal_id, fecha),
  CONSTRAINT cajas_cierre_completo CHECK ((cerrada_en IS NULL) = (monto_contado IS NULL))
);

COMMENT ON TABLE public.cajas IS
  'Caja de cada sucursal por día: se abre con el efectivo inicial y se cierra contando el efectivo. Abierta = sin cerrada_en. Se modifica solo con abrir_caja, cerrar_caja y reabrir_caja.';
COMMENT ON COLUMN public.cajas.monto_contado IS 'Efectivo contado al cerrar. Se compara con el inicial más los cobros en efectivo del día.';
COMMENT ON COLUMN public.cajas.motivo_reapertura IS 'Por qué el admin reabrió la caja (la última vez).';

ALTER TABLE public.cajas ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON public.cajas FROM authenticated, anon;

CREATE POLICY "cajas: las ve el personal de la sucursal" ON public.cajas
  FOR SELECT TO authenticated
  USING ((SELECT privado.ve_sucursal(sucursal_id)));

-- 2. Resumen de un día ─────────────────────────
-- Lo cobrado por medio de pago (sin los anulados) y lo esperado en efectivo.
-- SECURITY INVOKER: las políticas de cobros y cajas deciden qué sucursal se ve.

CREATE FUNCTION public.resumen_caja(p_sucursal_id bigint, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE
  v_fecha date := coalesce(p_fecha, privado.hoy());
  v_caja public.cajas;
  v_medios jsonb;
  v_efectivo numeric;
  v_anulados integer;
BEGIN
  SELECT * INTO v_caja FROM public.cajas WHERE sucursal_id = p_sucursal_id AND fecha = v_fecha;

  SELECT
    coalesce(jsonb_agg(jsonb_build_object('medio_pago', medio_pago, 'total', total, 'cantidad', cantidad) ORDER BY medio_pago), '[]'::jsonb),
    coalesce(sum(total) FILTER (WHERE medio_pago = 'efectivo'), 0)
  INTO v_medios, v_efectivo
  FROM (
    SELECT medio_pago, sum(monto) AS total, count(*) AS cantidad
    FROM public.cobros
    WHERE sucursal_id = p_sucursal_id
      AND (cobrado_en AT TIME ZONE 'America/Argentina/Tucuman')::date = v_fecha
      AND anulado_en IS NULL
    GROUP BY medio_pago
  ) AS m;

  SELECT count(*) INTO v_anulados
  FROM public.cobros
  WHERE sucursal_id = p_sucursal_id
    AND (cobrado_en AT TIME ZONE 'America/Argentina/Tucuman')::date = v_fecha
    AND anulado_en IS NOT NULL;

  RETURN jsonb_build_object(
    'fecha', v_fecha,
    'caja', CASE WHEN v_caja.id IS NULL THEN NULL ELSE to_jsonb(v_caja) END,
    'por_medio', v_medios,
    'cobros_anulados', v_anulados,
    'efectivo_esperado', CASE WHEN v_caja.id IS NULL THEN NULL ELSE v_caja.monto_inicial + v_efectivo END,
    'diferencia', CASE WHEN v_caja.monto_contado IS NULL THEN NULL
                       ELSE v_caja.monto_contado - (v_caja.monto_inicial + v_efectivo) END
  );
END;
$$;

-- 3. Abrir, cerrar y reabrir ───────────────────
-- SECURITY DEFINER: nadie escribe la tabla directo. Revisan a mano rol y sucursal.

CREATE FUNCTION public.abrir_caja(p_sucursal_id bigint, p_monto_inicial numeric)
RETURNS public.cajas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_caja public.cajas;
BEGIN
  IF NOT privado.tiene_rol('recepcion', 'admin') THEN
    RAISE EXCEPTION 'Solo recepción puede abrir la caja' USING ERRCODE = '42501';
  END IF;
  IF NOT privado.ve_sucursal(p_sucursal_id) THEN
    RAISE EXCEPTION 'No trabaja en esa sucursal' USING ERRCODE = '42501';
  END IF;
  IF p_monto_inicial IS NULL OR p_monto_inicial < 0 THEN
    RAISE EXCEPTION 'Ingrese el efectivo inicial (puede ser 0)' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.cajas (sucursal_id, fecha, monto_inicial, abierta_por)
  VALUES (p_sucursal_id, privado.hoy(), round(p_monto_inicial, 2), auth.uid())
  ON CONFLICT (sucursal_id, fecha) DO NOTHING
  RETURNING * INTO v_caja;

  IF v_caja.id IS NULL THEN
    RAISE EXCEPTION 'La caja de hoy ya se abrió' USING ERRCODE = '22023';
  END IF;
  RETURN v_caja;
END;
$$;

-- p_fecha: la de hoy si no se indica. Sirve para cerrar una caja de otro día que se
-- olvidó abierta o que el admin reabrió para corregir algo.
CREATE FUNCTION public.cerrar_caja(
  p_sucursal_id bigint,
  p_monto_contado numeric,
  p_observaciones text DEFAULT NULL,
  p_fecha date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_fecha date := coalesce(p_fecha, privado.hoy());
  v_caja public.cajas;
BEGIN
  IF NOT privado.tiene_rol('recepcion', 'admin') THEN
    RAISE EXCEPTION 'Solo recepción puede cerrar la caja' USING ERRCODE = '42501';
  END IF;
  IF NOT privado.ve_sucursal(p_sucursal_id) THEN
    RAISE EXCEPTION 'No trabaja en esa sucursal' USING ERRCODE = '42501';
  END IF;
  IF p_monto_contado IS NULL OR p_monto_contado < 0 THEN
    RAISE EXCEPTION 'Ingrese el efectivo que contó en la caja' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_caja FROM public.cajas
  WHERE sucursal_id = p_sucursal_id AND fecha = v_fecha
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La caja del % no se abrió', to_char(v_fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
  END IF;
  IF v_caja.cerrada_en IS NOT NULL THEN
    RAISE EXCEPTION 'La caja del % ya está cerrada', to_char(v_fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
  END IF;

  UPDATE public.cajas
  SET monto_contado = round(p_monto_contado, 2),
      observaciones_cierre = nullif(btrim(p_observaciones), ''),
      cerrada_por = auth.uid(),
      cerrada_en = now()
  WHERE id = v_caja.id;

  -- Devuelve el resumen del día cerrado (la sucursal ya se controló arriba)
  RETURN public.resumen_caja(p_sucursal_id, v_caja.fecha);
END;
$$;

CREATE FUNCTION public.reabrir_caja(p_caja_id bigint, p_motivo text)
RETURNS public.cajas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_caja public.cajas;
BEGIN
  IF NOT privado.tiene_rol('admin') THEN
    RAISE EXCEPTION 'Solo el administrador puede reabrir una caja' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_motivo), '') IS NULL THEN
    RAISE EXCEPTION 'Indique el motivo de la reapertura' USING ERRCODE = '22023';
  END IF;

  UPDATE public.cajas
  SET monto_contado = NULL,
      observaciones_cierre = NULL,
      cerrada_por = NULL,
      cerrada_en = NULL,
      motivo_reapertura = btrim(p_motivo),
      reabierta_por = auth.uid(),
      reabierta_en = now()
  WHERE id = p_caja_id AND cerrada_en IS NOT NULL
  RETURNING * INTO v_caja;

  IF v_caja.id IS NULL THEN
    RAISE EXCEPTION 'No se encontró la caja o no está cerrada' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_caja;
END;
$$;

-- 4. Los cobros respetan la caja ───────────────
-- Cobrar: solo con la caja de hoy abierta en la sucursal de la orden.
-- Anular un cobro: no si la caja del día de ese cobro ya se cerró.

CREATE FUNCTION privado.controlar_caja_de_cobro()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_dia date;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.cajas
      WHERE sucursal_id = NEW.sucursal_id AND fecha = privado.hoy() AND cerrada_en IS NULL
    ) THEN
      RAISE EXCEPTION 'La caja de hoy no está abierta: ábrala en Caja antes de cobrar' USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.anulado_en IS NOT NULL AND OLD.anulado_en IS NULL THEN
    v_dia := (OLD.cobrado_en AT TIME ZONE 'America/Argentina/Tucuman')::date;
    IF EXISTS (
      SELECT 1 FROM public.cajas
      WHERE sucursal_id = OLD.sucursal_id AND fecha = v_dia AND cerrada_en IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'La caja del % está cerrada: el administrador tiene que reabrirla para anular el cobro',
        to_char(v_dia, 'DD/MM/YYYY') USING ERRCODE = '22023';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER cobros_caja
  BEFORE INSERT OR UPDATE OF anulado_en ON public.cobros
  FOR EACH ROW EXECUTE FUNCTION privado.controlar_caja_de_cobro();

-- Las funciones del panel solo las usa el personal logueado
REVOKE ALL ON FUNCTION public.resumen_caja(bigint, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.abrir_caja(bigint, numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cerrar_caja(bigint, numeric, text, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reabrir_caja(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resumen_caja(bigint, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.abrir_caja(bigint, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cerrar_caja(bigint, numeric, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reabrir_caja(bigint, text) TO authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;
