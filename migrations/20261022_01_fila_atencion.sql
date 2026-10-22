-- Fila de atención del día
--
-- Relevamiento (22/10/2026): el laboratorio NO da turnos con hora. Se atiende
-- por orden de llegada, sin límite de pacientes, de lunes a sábado de 8:00 a 10:00.
-- 1. Recepción registra la llegada del paciente (lo busca por DNI o lo da de alta)
--    y la base le asigna el número de atención del día.
-- 2. Extracción (técnico o, por alguna eventualidad, bioquímico) llama al
--    siguiente desde su box y lo marca como atendido o "se retiró".
-- 3. Los que quedan en espera al terminar el día pasan solos a "se retiró".
--
-- La tabla turnos (vacía hasta ahora) pasa a representar esa fila: un turno es
-- el número de atención de un paciente en un día. Se modifica solo a través de
-- las funciones de esta migración, que asignan el número sin repetirlo y evitan
-- que dos boxes llamen al mismo paciente.
--
-- También: configuración del laboratorio (cantidad de boxes), carga de obras
-- sociales y número de afiliado obligatorio cuando el paciente tiene obra social.

-- 1. Fecha de hoy en Tucumán ──────────────────
-- La base trabaja en UTC: a las 21:00 de Tucumán en UTC ya es el día siguiente.

CREATE FUNCTION privado.hoy()
RETURNS date
LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT (now() AT TIME ZONE 'America/Argentina/Tucuman')::date;
$$;

-- 2. Configuración del laboratorio ────────────
-- Una sola fila (id siempre true). El admin la modifica desde el panel.

CREATE TABLE public.configuracion (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  cantidad_boxes smallint NOT NULL DEFAULT 2 CHECK (cantidad_boxes BETWEEN 1 AND 20),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.perfiles (id)
);
COMMENT ON TABLE public.configuracion IS
  'Parámetros del laboratorio que el administrador puede cambiar. Tiene una sola fila.';
COMMENT ON COLUMN public.configuracion.cantidad_boxes IS
  'Boxes de extracción habilitados (Box 1 a Box N).';

INSERT INTO public.configuracion (id) VALUES (true);

ALTER TABLE public.configuracion ENABLE ROW LEVEL SECURITY;

CREATE POLICY "configuracion: lectura del personal" ON public.configuracion
  FOR SELECT TO authenticated USING ((SELECT privado.es_personal()));
CREATE POLICY "configuracion: admin modifica" ON public.configuracion
  FOR UPDATE TO authenticated
  USING ((SELECT privado.tiene_rol('admin'))) WITH CHECK ((SELECT privado.tiene_rol('admin')));

-- 3. Obras sociales y número de afiliado ──────
-- Obra social vacía = paciente particular. Si tiene obra social, el número de
-- afiliado es obligatorio.

INSERT INTO public.obras_sociales (nombre) VALUES
  ('PAMI'),
  ('Subsidio de Salud'),
  ('OSDE'),
  ('Swiss Medical'),
  ('Galeno'),
  ('Medifé'),
  ('Sancor Salud'),
  ('OSECAC'),
  ('OSPRERA'),
  ('Unión Personal')
ON CONFLICT (nombre) DO NOTHING;

ALTER TABLE public.pacientes
  ADD CONSTRAINT pacientes_afiliado_si_obra_social
    CHECK (obra_social_id IS NULL OR nullif(btrim(nro_afiliado), '') IS NOT NULL);

-- 4. Turnos = fila de atención ────────────────

-- Hasta ahora recepción y admin escribían la tabla directo. Desde acá solo se
-- modifica con las funciones de abajo (SECURITY DEFINER); la lectura no cambia.
DROP POLICY "turnos: recepcion y admin gestionan" ON public.turnos;

-- No hay hora pactada: la hora de llegada es created_at
ALTER TABLE public.turnos DROP COLUMN fecha_hora;

-- Estados nuevos (la tabla está vacía, no hay datos que convertir)
CREATE TYPE public.estado_atencion AS ENUM ('en_espera', 'llamado', 'atendido', 'se_retiro');
ALTER TABLE public.turnos ALTER COLUMN estado DROP DEFAULT;
ALTER TABLE public.turnos
  ALTER COLUMN estado TYPE public.estado_atencion USING 'en_espera'::public.estado_atencion;
ALTER TABLE public.turnos ALTER COLUMN estado SET DEFAULT 'en_espera';
DROP TYPE public.estado_turno;

ALTER TABLE public.turnos
  ADD COLUMN fecha date NOT NULL,
  ADD COLUMN numero integer NOT NULL,
  ADD COLUMN box smallint,
  ADD COLUMN registrado_por uuid REFERENCES public.perfiles (id),
  ADD COLUMN llamado_por uuid REFERENCES public.perfiles (id),
  ADD COLUMN llamado_at timestamptz,
  ADD COLUMN finalizado_por uuid REFERENCES public.perfiles (id),
  ADD COLUMN finalizado_at timestamptz,
  ADD CONSTRAINT turnos_numero_por_dia UNIQUE (fecha, numero),
  ADD CONSTRAINT turnos_una_vez_por_dia UNIQUE (paciente_id, fecha),
  ADD CONSTRAINT turnos_numero_positivo CHECK (numero > 0),
  ADD CONSTRAINT turnos_box_positivo CHECK (box IS NULL OR box > 0);

CREATE INDEX turnos_fila_del_dia ON public.turnos (fecha, estado, numero);

COMMENT ON TABLE public.turnos IS
  'Fila de atención: un paciente con su número de atención en un día. Se atiende por orden de llegada.';
COMMENT ON COLUMN public.turnos.numero IS 'Número de atención; se reinicia cada día.';
COMMENT ON COLUMN public.turnos.box IS 'Box de extracción desde el que se llamó al paciente.';
COMMENT ON COLUMN public.turnos.created_at IS 'Hora de llegada.';

-- 5. Funciones de la fila ─────────────────────

-- Cierra los días anteriores: quien quedó en espera o llamado pasa a "se retiró".
-- No hay tareas programadas en el proyecto: se ejecuta al registrar y al llamar.
CREATE FUNCTION privado.cerrar_dias_anteriores()
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
  UPDATE public.turnos
  SET estado = 'se_retiro', finalizado_at = now()
  WHERE fecha < privado.hoy() AND estado IN ('en_espera', 'llamado');
$$;

-- Recepción registra la llegada de un paciente y la base le asigna el número.
-- Si ya estaba registrado hoy, devuelve ese turno en vez de crear otro.
-- Devuelve { turno, ya_registrado }.
CREATE FUNCTION public.registrar_llegada(
  p_paciente_id uuid,
  p_tipo public.tipo_extraccion DEFAULT 'ambulatoria',
  p_observaciones text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_hoy date := privado.hoy();
  v_turno public.turnos;
BEGIN
  IF NOT privado.tiene_rol('recepcion', 'admin') THEN
    RAISE EXCEPTION 'Solo recepción puede registrar llegadas' USING ERRCODE = '42501';
  END IF;

  PERFORM privado.cerrar_dias_anteriores();

  -- Un registro a la vez por día: dos recepcionistas nunca reciben el mismo número
  PERFORM pg_advisory_xact_lock(hashtext('turnos:' || v_hoy));

  SELECT * INTO v_turno FROM public.turnos WHERE paciente_id = p_paciente_id AND fecha = v_hoy;
  IF FOUND THEN
    RETURN jsonb_build_object('turno', to_jsonb(v_turno), 'ya_registrado', true);
  END IF;

  INSERT INTO public.turnos (paciente_id, fecha, numero, tipo, observaciones, registrado_por)
  VALUES (
    p_paciente_id,
    v_hoy,
    (SELECT coalesce(max(numero), 0) + 1 FROM public.turnos WHERE fecha = v_hoy),
    coalesce(p_tipo, 'ambulatoria'),
    nullif(btrim(p_observaciones), ''),
    auth.uid()
  )
  RETURNING * INTO v_turno;

  RETURN jsonb_build_object('turno', to_jsonb(v_turno), 'ya_registrado', false);
END;
$$;

-- Extracción llama al siguiente paciente desde su box.
-- Si el box ya tiene a alguien llamado sin terminar, devuelve ese mismo.
-- SKIP LOCKED: si dos boxes llaman a la vez, cada uno se lleva a un paciente distinto.
-- Devuelve el turno llamado, o null si no hay nadie en espera.
CREATE FUNCTION public.llamar_siguiente(p_box smallint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_hoy date := privado.hoy();
  v_boxes smallint;
  v_turno public.turnos;
BEGIN
  IF NOT privado.tiene_rol('tecnico', 'bioquimico', 'admin') THEN
    RAISE EXCEPTION 'Solo extracción puede llamar pacientes' USING ERRCODE = '42501';
  END IF;

  SELECT cantidad_boxes INTO v_boxes FROM public.configuracion;
  IF p_box IS NULL OR p_box < 1 OR p_box > v_boxes THEN
    RAISE EXCEPTION 'El box % no existe', p_box USING ERRCODE = '22023';
  END IF;

  PERFORM privado.cerrar_dias_anteriores();

  SELECT * INTO v_turno FROM public.turnos
  WHERE fecha = v_hoy AND estado = 'llamado' AND box = p_box
  ORDER BY llamado_at
  LIMIT 1;
  IF FOUND THEN
    RETURN to_jsonb(v_turno);
  END IF;

  SELECT * INTO v_turno FROM public.turnos
  WHERE fecha = v_hoy AND estado = 'en_espera'
  ORDER BY numero
  LIMIT 1
  FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  UPDATE public.turnos
  SET estado = 'llamado', box = p_box, llamado_por = auth.uid(), llamado_at = now()
  WHERE id = v_turno.id
  RETURNING * INTO v_turno;

  RETURN to_jsonb(v_turno);
END;
$$;

-- Termina la atención de un paciente: "atendido" (solo extracción, después de
-- llamarlo) o "se_retiro" (extracción o recepción, mientras espera o lo llamaron).
CREATE FUNCTION public.finalizar_atencion(p_turno_id uuid, p_estado public.estado_atencion)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_turno public.turnos;
  v_extraccion boolean := privado.tiene_rol('tecnico', 'bioquimico', 'admin');
  v_recepcion boolean := privado.tiene_rol('recepcion', 'admin');
BEGIN
  IF p_estado NOT IN ('atendido', 'se_retiro') THEN
    RAISE EXCEPTION 'Estado final inválido: %', p_estado USING ERRCODE = '22023';
  END IF;
  IF p_estado = 'atendido' AND NOT v_extraccion THEN
    RAISE EXCEPTION 'Solo extracción puede marcar a un paciente como atendido' USING ERRCODE = '42501';
  END IF;
  IF p_estado = 'se_retiro' AND NOT (v_extraccion OR v_recepcion) THEN
    RAISE EXCEPTION 'No tiene permiso para modificar la fila' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_turno FROM public.turnos WHERE id = p_turno_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El turno no existe' USING ERRCODE = 'P0002';
  END IF;
  IF p_estado = 'atendido' AND v_turno.estado <> 'llamado' THEN
    RAISE EXCEPTION 'Solo se puede marcar como atendido a un paciente llamado' USING ERRCODE = '22023';
  END IF;
  IF v_turno.estado NOT IN ('en_espera', 'llamado') THEN
    RAISE EXCEPTION 'La atención de este paciente ya terminó' USING ERRCODE = '22023';
  END IF;

  UPDATE public.turnos
  SET estado = p_estado, finalizado_por = auth.uid(), finalizado_at = now()
  WHERE id = p_turno_id
  RETURNING * INTO v_turno;

  RETURN to_jsonb(v_turno);
END;
$$;

-- Solo usuarios con sesión: cada función revisa además el rol
REVOKE EXECUTE ON FUNCTION public.registrar_llegada(uuid, public.tipo_extraccion, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.llamar_siguiente(smallint) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.finalizar_atencion(uuid, public.estado_atencion) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_llegada(uuid, public.tipo_extraccion, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.llamar_siguiente(smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalizar_atencion(uuid, public.estado_atencion) TO authenticated;
