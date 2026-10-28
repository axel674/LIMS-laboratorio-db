-- Órdenes médicas (LIMS-10)
--
-- Relevamiento (23/10 y 28/10/2026):
-- - El número de orden lo genera la base: prefijo de la sucursal + año +
--   correlativo de 6 dígitos (ej: S1-2026-000123). El correlativo es de cada
--   sucursal y vuelve a empezar cada año.
-- - Un paciente puede traer varias órdenes en la misma visita (ej: sangre en
--   una orden y orina en otra, o de médicos distintos): se quita el límite de
--   una orden por turno.
-- - El médico es obligatorio. Si no está cargado, recepción lo da de alta en el
--   momento (la matrícula ya es obligatoria y única en medicos).
-- - La obra social va por orden: se propone la del paciente y se puede cambiar.
--   Además, cada estudio indica si lo cubre la obra social: los que no cubre se
--   cobran como particulares.
-- - Se carga la fecha de la orden (la que firmó el médico) y observaciones.
-- - Recepción y el admin cargan, editan mientras la orden está abierta y la
--   anulan con motivo. Las reglas de sucursal son las de 20261028_01.

-- 1. Varias órdenes por turno ──────────────────

ALTER TABLE public.ordenes DROP CONSTRAINT ordenes_turno_id_key;
CREATE INDEX ordenes_turno_id_idx ON public.ordenes (turno_id);

-- 2. Datos nuevos de la orden ──────────────────

ALTER TABLE public.ordenes
  ADD COLUMN fecha_orden date NOT NULL DEFAULT (privado.hoy()),
  ADD COLUMN motivo_anulacion text,
  ADD COLUMN anulada_por uuid REFERENCES public.perfiles(id),
  ADD COLUMN anulada_en timestamptz,
  ADD CONSTRAINT ordenes_motivo_si_anulada
    CHECK (estado <> 'anulada' OR nullif(btrim(motivo_anulacion), '') IS NOT NULL);

-- No hay órdenes cargadas todavía: el médico pasa a ser obligatorio sin migrar datos
ALTER TABLE public.ordenes ALTER COLUMN medico_id SET NOT NULL;

COMMENT ON COLUMN public.ordenes.nro_orden IS
  'Lo genera la base al crear la orden: prefijo de la sucursal + año + correlativo (ej: S1-2026-000123).';
COMMENT ON COLUMN public.ordenes.fecha_orden IS 'Fecha en que el médico firmó la orden (no puede ser futura).';
COMMENT ON COLUMN public.ordenes.obra_social_id IS
  'Obra social con la que se atiende esta orden (se propone la del paciente). Vacío = particular.';
COMMENT ON COLUMN public.ordenes.motivo_anulacion IS 'Obligatorio cuando la orden se anula.';

ALTER TABLE public.orden_analisis
  ADD COLUMN cubierto boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.orden_analisis.cubierto IS
  'Si la obra social de la orden cubre este estudio. Falso = se cobra como particular.';

-- 3. Número de orden ───────────────────────────

-- Último número usado por sucursal y año. Está en el esquema privado: solo la
-- usa el trigger, que es SECURITY DEFINER.
CREATE TABLE privado.numeracion_ordenes (
  sucursal_id bigint NOT NULL REFERENCES public.sucursales(id),
  anio smallint NOT NULL,
  ultimo integer NOT NULL,
  PRIMARY KEY (sucursal_id, anio)
);

CREATE FUNCTION privado.numerar_orden()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_anio smallint := extract(year FROM privado.hoy());
  v_numero integer;
  v_prefijo varchar;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- El número no se cambia nunca, aunque la orden cambie de turno o de sucursal
    NEW.nro_orden := OLD.nro_orden;
    RETURN NEW;
  END IF;

  -- INSERT ... ON CONFLICT reserva el número de forma atómica: dos recepciones
  -- que cargan a la vez nunca reciben el mismo
  INSERT INTO privado.numeracion_ordenes AS n (sucursal_id, anio, ultimo)
  VALUES (NEW.sucursal_id, v_anio, 1)
  ON CONFLICT (sucursal_id, anio) DO UPDATE SET ultimo = n.ultimo + 1
  RETURNING ultimo INTO v_numero;

  SELECT prefijo INTO v_prefijo FROM public.sucursales WHERE id = NEW.sucursal_id;
  NEW.nro_orden := v_prefijo || '-' || v_anio || '-' || lpad(v_numero::text, 6, '0');
  RETURN NEW;
END;
$$;

-- Los triggers BEFORE corren en orden alfabético: "zz" asegura que este corra
-- después de ordenes_sucursal, que completa la sucursal desde el turno
CREATE TRIGGER ordenes_zz_numero
  BEFORE INSERT OR UPDATE ON public.ordenes
  FOR EACH ROW EXECUTE FUNCTION privado.numerar_orden();

-- 4. Reglas de edición ─────────────────────────

CREATE FUNCTION privado.controlar_orden()
RETURNS trigger
LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF NEW.fecha_orden > privado.hoy() THEN
    RAISE EXCEPTION 'La fecha de la orden no puede ser posterior a hoy' USING ERRCODE = '22023';
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- El turno tiene que ser del mismo paciente de la orden
    IF NEW.turno_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.turnos WHERE id = NEW.turno_id AND paciente_id = NEW.paciente_id
    ) THEN
      RAISE EXCEPTION 'El turno indicado es de otro paciente' USING ERRCODE = '22023';
    END IF;
    NEW.recibida_por := auth.uid();
    NEW.estado := 'abierta';
    NEW.motivo_anulacion := NULL;
    NEW.anulada_por := NULL;
    NEW.anulada_en := NULL;
    RETURN NEW;
  END IF;

  IF OLD.estado = 'anulada' THEN
    RAISE EXCEPTION 'La orden % está anulada: no se puede modificar', OLD.nro_orden USING ERRCODE = '22023';
  END IF;

  -- Anular: solo una orden abierta (todavía sin procesar) y siempre con motivo
  IF NEW.estado = 'anulada' THEN
    IF OLD.estado <> 'abierta' THEN
      RAISE EXCEPTION 'Solo se puede anular una orden abierta' USING ERRCODE = '22023';
    END IF;
    NEW.anulada_por := auth.uid();
    NEW.anulada_en := now();
    RETURN NEW;
  END IF;

  -- Los datos de la orden solo se corrigen mientras está abierta
  IF OLD.estado <> 'abierta' AND (
       NEW.medico_id IS DISTINCT FROM OLD.medico_id
    OR NEW.obra_social_id IS DISTINCT FROM OLD.obra_social_id
    OR NEW.fecha_orden IS DISTINCT FROM OLD.fecha_orden
    OR NEW.paciente_id IS DISTINCT FROM OLD.paciente_id
  ) THEN
    RAISE EXCEPTION 'La orden % ya está en proceso: no se puede modificar', OLD.nro_orden USING ERRCODE = '22023';
  END IF;

  NEW.recibida_por := OLD.recibida_por;
  NEW.motivo_anulacion := OLD.motivo_anulacion;
  NEW.anulada_por := OLD.anulada_por;
  NEW.anulada_en := OLD.anulada_en;
  RETURN NEW;
END;
$$;

CREATE TRIGGER ordenes_control
  BEFORE INSERT OR UPDATE ON public.ordenes
  FOR EACH ROW EXECUTE FUNCTION privado.controlar_orden();

-- Los estudios se agregan, se quitan o cambian de cobertura solo con la orden abierta.
-- La asignación de tubos (muestra_id) sigue permitida después.
CREATE FUNCTION privado.controlar_estudio()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_orden uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.orden_id ELSE NEW.orden_id END;
  v_estado public.estado_orden;
BEGIN
  SELECT estado INTO v_estado FROM public.ordenes WHERE id = v_orden;
  IF v_estado <> 'abierta' AND (
       TG_OP <> 'UPDATE'
    OR NEW.analisis_id IS DISTINCT FROM OLD.analisis_id
    OR NEW.cubierto IS DISTINCT FROM OLD.cubierto
  ) THEN
    RAISE EXCEPTION 'Los estudios solo se modifican con la orden abierta' USING ERRCODE = '22023';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER orden_analisis_control
  BEFORE INSERT OR UPDATE OR DELETE ON public.orden_analisis
  FOR EACH ROW EXECUTE FUNCTION privado.controlar_estudio();

-- 5. Funciones para el panel ───────────────────
-- Son SECURITY INVOKER: corren con los permisos de quien llama, así que se
-- aplican las mismas reglas de rol y sucursal que en las tablas. Sirven para
-- guardar la orden y sus estudios juntos (si algo falla, no queda nada a medias).
-- p_estudios: [{"analisis_id": 1, "cubierto": true}, ...]

CREATE FUNCTION public.crear_orden(
  p_paciente_id uuid,
  p_medico_id bigint,
  p_estudios jsonb,
  p_fecha_orden date,
  p_obra_social_id bigint DEFAULT NULL,
  p_turno_id uuid DEFAULT NULL,
  p_sucursal_id bigint DEFAULT NULL,
  p_observaciones text DEFAULT NULL
)
RETURNS public.ordenes
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_orden public.ordenes;
BEGIN
  IF jsonb_typeof(p_estudios) IS DISTINCT FROM 'array' OR jsonb_array_length(p_estudios) = 0 THEN
    RAISE EXCEPTION 'La orden necesita al menos un estudio' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.ordenes (nro_orden, paciente_id, medico_id, turno_id, sucursal_id, obra_social_id, fecha_orden, observaciones)
  VALUES ('', p_paciente_id, p_medico_id, p_turno_id, p_sucursal_id, p_obra_social_id, p_fecha_orden,
          nullif(btrim(p_observaciones), ''))
  RETURNING * INTO v_orden;

  INSERT INTO public.orden_analisis (orden_id, analisis_id, cubierto)
  SELECT v_orden.id, (e ->> 'analisis_id')::bigint,
         -- Sin obra social no hay cobertura: todo es particular
         p_obra_social_id IS NOT NULL AND coalesce((e ->> 'cubierto')::boolean, true)
  FROM jsonb_array_elements(p_estudios) AS e;

  RETURN v_orden;
END;
$$;

-- Corrige una orden abierta: reemplaza sus datos y su lista de estudios
CREATE FUNCTION public.modificar_orden(
  p_orden_id uuid,
  p_medico_id bigint,
  p_estudios jsonb,
  p_fecha_orden date,
  p_obra_social_id bigint DEFAULT NULL,
  p_observaciones text DEFAULT NULL
)
RETURNS public.ordenes
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_orden public.ordenes;
BEGIN
  IF jsonb_typeof(p_estudios) IS DISTINCT FROM 'array' OR jsonb_array_length(p_estudios) = 0 THEN
    RAISE EXCEPTION 'La orden necesita al menos un estudio' USING ERRCODE = '22023';
  END IF;

  UPDATE public.ordenes
  SET medico_id = p_medico_id,
      obra_social_id = p_obra_social_id,
      fecha_orden = p_fecha_orden,
      observaciones = nullif(btrim(p_observaciones), '')
  WHERE id = p_orden_id
  RETURNING * INTO v_orden;

  -- Sin fila: la orden no existe o es de otra sucursal (la política no la deja ver)
  IF v_orden.id IS NULL THEN
    RAISE EXCEPTION 'No se encontró la orden' USING ERRCODE = 'P0002';
  END IF;

  -- Los estudios que se sacaron se borran; los demás se agregan o actualizan
  DELETE FROM public.orden_analisis
  WHERE orden_id = p_orden_id
    AND analisis_id NOT IN (SELECT (e ->> 'analisis_id')::bigint FROM jsonb_array_elements(p_estudios) AS e);

  INSERT INTO public.orden_analisis (orden_id, analisis_id, cubierto)
  SELECT p_orden_id, (e ->> 'analisis_id')::bigint,
         p_obra_social_id IS NOT NULL AND coalesce((e ->> 'cubierto')::boolean, true)
  FROM jsonb_array_elements(p_estudios) AS e
  ON CONFLICT (orden_id, analisis_id) DO UPDATE SET cubierto = excluded.cubierto
  WHERE public.orden_analisis.cubierto IS DISTINCT FROM excluded.cubierto;

  RETURN v_orden;
END;
$$;

CREATE FUNCTION public.anular_orden(p_orden_id uuid, p_motivo text)
RETURNS public.ordenes
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_orden public.ordenes;
BEGIN
  IF nullif(btrim(p_motivo), '') IS NULL THEN
    RAISE EXCEPTION 'Indique el motivo de la anulación' USING ERRCODE = '22023';
  END IF;

  UPDATE public.ordenes
  SET estado = 'anulada', motivo_anulacion = btrim(p_motivo)
  WHERE id = p_orden_id
  RETURNING * INTO v_orden;

  IF v_orden.id IS NULL THEN
    RAISE EXCEPTION 'No se encontró la orden' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_orden;
END;
$$;

-- Las funciones del panel solo las usa el personal logueado (las políticas deciden el resto)
REVOKE ALL ON FUNCTION public.crear_orden(uuid, bigint, jsonb, date, bigint, uuid, bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.modificar_orden(uuid, bigint, jsonb, date, bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.anular_orden(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_orden(uuid, bigint, jsonb, date, bigint, uuid, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.modificar_orden(uuid, bigint, jsonb, date, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.anular_orden(uuid, text) TO authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;
