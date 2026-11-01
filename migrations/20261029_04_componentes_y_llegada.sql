-- Estudios con componentes (fórmula leucocitaria) y orden unida a la llegada
--
-- 1. Un estudio puede tener componentes: la fórmula leucocitaria se pide como un
--    solo estudio, pero se informa con 5 valores (neutrófilos, linfocitos,
--    monocitos, eosinófilos y basófilos), cada uno con su rango. Al agregar el
--    estudio a una orden, la base le agrega sus componentes; en la carga de
--    resultados se despliegan debajo del estudio.
-- 2. Valor absoluto: cada componente se carga en % y la base calcula el valor
--    absoluto con los glóbulos blancos de la misma orden (% × GB / 100). Si
--    cambian los glóbulos blancos, se recalcula. Fuera de rango si el % o el
--    absoluto quedan fuera.
-- 3. Una orden que se cargó antes de registrar la llegada del paciente se une
--    sola al turno cuando se registra su llegada ese día en esa sucursal.
--
-- Los valores de referencia son orientativos: los confirma el bioquímico.

-- 1. Componentes en el catálogo ────────────────

ALTER TABLE public.analisis
  ADD COLUMN padre_id bigint REFERENCES public.analisis(id),
  ADD COLUMN absoluto_de bigint REFERENCES public.analisis(id),
  ADD COLUMN absoluto_min numeric,
  ADD COLUMN absoluto_max numeric,
  ADD COLUMN absoluto_unidad varchar,
  ADD CONSTRAINT analisis_no_es_su_padre CHECK (padre_id IS DISTINCT FROM id);

COMMENT ON COLUMN public.analisis.padre_id IS
  'Estudio del que es componente (ej: Neutrófilos de la Fórmula leucocitaria). Los componentes no se eligen sueltos en la orden.';
COMMENT ON COLUMN public.analisis.absoluto_de IS
  'Si el valor se carga en %, estudio con el que se calcula el absoluto (ej: Glóbulos blancos): absoluto = % × valor / 100.';

CREATE INDEX analisis_padre_id_idx ON public.analisis (padre_id);

INSERT INTO public.analisis
  (codigo, nombre, tipo_muestra_id, unidad, valor_ref_min, valor_ref_max, dias_demora,
   padre_id, absoluto_de, absoluto_min, absoluto_max, absoluto_unidad)
SELECT c.codigo, c.nombre, fl.tipo_muestra_id, '%', c.minimo, c.maximo, fl.dias_demora,
       fl.id, gb.id, c.abs_min, c.abs_max, '/mm³'
FROM (VALUES
  ('FL-NEU', 'Neutrófilos', 40, 75, 1800, 7700),
  ('FL-LIN', 'Linfocitos',  20, 45, 1000, 4800),
  ('FL-MON', 'Monocitos',    2, 10,  200, 1000),
  ('FL-EOS', 'Eosinófilos',  1,  6,   50,  500),
  ('FL-BAS', 'Basófilos',    0,  1,    0,  100)
) AS c (codigo, nombre, minimo, maximo, abs_min, abs_max)
CROSS JOIN (SELECT id, tipo_muestra_id, dias_demora FROM public.analisis WHERE codigo = 'FL') fl
CROSS JOIN (SELECT id FROM public.analisis WHERE codigo = 'GB') gb
ON CONFLICT (codigo) DO NOTHING;

-- En los niños predominan los linfocitos
INSERT INTO public.analisis_rangos (analisis_id, sexo, edad_desde, edad_hasta, valor_min, valor_max)
SELECT a.id, NULL, 1, 18, r.minimo, r.maximo
FROM (VALUES ('FL-NEU', 30, 65), ('FL-LIN', 25, 55)) AS r (codigo, minimo, maximo)
JOIN public.analisis a ON a.codigo = r.codigo;

-- La fórmula se informa con sus componentes: ya no lleva un texto propio
UPDATE public.analisis SET valor_ref_texto = NULL WHERE codigo = 'FL';

-- 2. Componentes en la orden ───────────────────

ALTER TABLE public.orden_analisis
  ADD COLUMN padre_id uuid REFERENCES public.orden_analisis(id) ON DELETE CASCADE;
COMMENT ON COLUMN public.orden_analisis.padre_id IS
  'Estudio de la orden del que es componente. Lo agrega la base al agregar el estudio.';
CREATE INDEX orden_analisis_padre_id_idx ON public.orden_analisis (padre_id);

CREATE FUNCTION privado.agregar_componentes()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.orden_analisis (orden_id, analisis_id, cubierto, grupo_id, padre_id)
  SELECT NEW.orden_id, c.id, NEW.cubierto, NEW.grupo_id, NEW.id
  FROM public.analisis c
  WHERE c.padre_id = NEW.analisis_id
  ON CONFLICT (orden_id, analisis_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER orden_analisis_componentes
  AFTER INSERT ON public.orden_analisis
  FOR EACH ROW EXECUTE FUNCTION privado.agregar_componentes();

-- Órdenes abiertas que ya tenían la fórmula: se le agregan los componentes
INSERT INTO public.orden_analisis (orden_id, analisis_id, cubierto, grupo_id, padre_id)
SELECT oa.orden_id, c.id, oa.cubierto, oa.grupo_id, oa.id
FROM public.orden_analisis oa
JOIN public.ordenes o ON o.id = oa.orden_id AND o.estado = 'abierta'
JOIN public.analisis c ON c.padre_id = oa.analisis_id
ON CONFLICT (orden_id, analisis_id) DO NOTHING;

-- Al corregir una orden, los componentes siguen a su estudio: no se borran por no
-- venir en la lista y copian su cobertura y su grupo
CREATE OR REPLACE FUNCTION public.modificar_orden(
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

  -- Los estudios que se sacaron se borran (sus componentes, en cascada)
  DELETE FROM public.orden_analisis
  WHERE orden_id = p_orden_id
    AND padre_id IS NULL
    AND analisis_id NOT IN (SELECT (e ->> 'analisis_id')::bigint FROM jsonb_array_elements(p_estudios) AS e);

  INSERT INTO public.orden_analisis AS oa (orden_id, analisis_id, cubierto, grupo_id)
  SELECT p_orden_id, (e ->> 'analisis_id')::bigint,
         p_obra_social_id IS NOT NULL AND coalesce((e ->> 'cubierto')::boolean, true),
         (e ->> 'grupo_id')::bigint
  FROM jsonb_array_elements(p_estudios) AS e
  ON CONFLICT (orden_id, analisis_id) DO UPDATE SET cubierto = excluded.cubierto, grupo_id = excluded.grupo_id
  WHERE oa.cubierto IS DISTINCT FROM excluded.cubierto OR oa.grupo_id IS DISTINCT FROM excluded.grupo_id;

  UPDATE public.orden_analisis c
  SET cubierto = p.cubierto, grupo_id = p.grupo_id
  FROM public.orden_analisis p
  WHERE c.padre_id = p.id AND p.orden_id = p_orden_id
    AND (c.cubierto IS DISTINCT FROM p.cubierto OR c.grupo_id IS DISTINCT FROM p.grupo_id);

  RETURN v_orden;
END;
$$;

-- 3. Valor absoluto del resultado ──────────────

ALTER TABLE public.resultados
  ADD COLUMN valor_absoluto numeric,
  ADD COLUMN abs_ref_min numeric,
  ADD COLUMN abs_ref_max numeric;
COMMENT ON COLUMN public.resultados.valor_absoluto IS
  'Calculado por la base: % × el estudio base de la misma orden (ej: glóbulos blancos) / 100.';

-- Misma función que en 20261029_03, más el cálculo del absoluto
CREATE OR REPLACE FUNCTION privado.controlar_resultado()
RETURNS trigger
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_rango record;
  v_analisis public.analisis;
  v_base numeric;
  v_validador boolean := privado.tiene_rol('bioquimico', 'admin');
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- Validado: queda fijo (salvo que el bioquímico lo vuelva a pendiente, LIMS-14)
    IF OLD.estado = 'validado' AND (
         NEW.valor_numerico IS DISTINCT FROM OLD.valor_numerico
      OR NEW.valor_texto IS DISTINCT FROM OLD.valor_texto
    ) THEN
      RAISE EXCEPTION 'El resultado ya está validado: no se puede corregir' USING ERRCODE = '22023';
    END IF;
    -- Validar o rechazar es solo del bioquímico (o el admin)
    IF NOT v_validador AND (
         NEW.estado IS DISTINCT FROM OLD.estado
      OR NEW.validado_por IS DISTINCT FROM OLD.validado_por
      OR NEW.validado_en IS DISTINCT FROM OLD.validado_en
    ) THEN
      RAISE EXCEPTION 'Solo el bioquímico valida los resultados' USING ERRCODE = '42501';
    END IF;
    NEW.orden_analisis_id := OLD.orden_analisis_id;
    -- Un resultado rechazado que se corrige vuelve a pendiente, para que el bioquímico lo revise de nuevo
    IF OLD.estado = 'rechazado' AND (
         NEW.valor_numerico IS DISTINCT FROM OLD.valor_numerico
      OR NEW.valor_texto IS DISTINCT FROM OLD.valor_texto
    ) THEN
      NEW.estado := 'pendiente';
      NEW.validado_por := NULL;
      NEW.validado_en := NULL;
    END IF;
  ELSE
    NEW.estado := 'pendiente';
    NEW.validado_por := NULL;
    NEW.validado_en := NULL;
  END IF;

  NEW.valor_texto := nullif(btrim(NEW.valor_texto), '');
  SELECT * INTO v_rango FROM public.rango_de_estudio(NEW.orden_analisis_id);
  SELECT a.* INTO v_analisis
  FROM public.orden_analisis oa JOIN public.analisis a ON a.id = oa.analisis_id
  WHERE oa.id = NEW.orden_analisis_id;

  -- Un estudio con rango numérico lleva un número; uno con referencia de texto, un texto
  IF v_rango.valor_min IS NOT NULL OR v_rango.valor_max IS NOT NULL THEN
    IF NEW.valor_numerico IS NULL THEN
      RAISE EXCEPTION 'Ingrese un valor numérico' USING ERRCODE = '22023';
    END IF;
    IF NEW.valor_numerico < 0 THEN
      RAISE EXCEPTION 'El valor no puede ser negativo' USING ERRCODE = '22023';
    END IF;
  ELSIF NEW.valor_numerico IS NULL AND NEW.valor_texto IS NULL THEN
    RAISE EXCEPTION 'Ingrese el resultado' USING ERRCODE = '22023';
  END IF;

  -- Absoluto: con el resultado del estudio base de la misma orden (si ya está cargado)
  NEW.valor_absoluto := NULL;
  NEW.abs_ref_min := v_analisis.absoluto_min;
  NEW.abs_ref_max := v_analisis.absoluto_max;
  IF v_analisis.absoluto_de IS NOT NULL AND NEW.valor_numerico IS NOT NULL THEN
    SELECT r.valor_numerico INTO v_base
    FROM public.orden_analisis oa
    JOIN public.orden_analisis base ON base.orden_id = oa.orden_id AND base.analisis_id = v_analisis.absoluto_de
    JOIN public.resultados r ON r.orden_analisis_id = base.id
    WHERE oa.id = NEW.orden_analisis_id;
    IF v_base IS NOT NULL THEN
      NEW.valor_absoluto := round(NEW.valor_numerico * v_base / 100);
    END IF;
  END IF;

  NEW.ref_min := v_rango.valor_min;
  NEW.ref_max := v_rango.valor_max;
  NEW.ref_texto := v_rango.valor_texto;
  NEW.fuera_de_rango := CASE
    WHEN NEW.valor_numerico IS NOT NULL AND (v_rango.valor_min IS NOT NULL OR v_rango.valor_max IS NOT NULL) THEN
      NEW.valor_numerico < coalesce(v_rango.valor_min, NEW.valor_numerico)
      OR NEW.valor_numerico > coalesce(v_rango.valor_max, NEW.valor_numerico)
      OR coalesce(NEW.valor_absoluto < NEW.abs_ref_min OR NEW.valor_absoluto > NEW.abs_ref_max, false)
    -- Referencia de texto (ej. "Negativo"): fuera de rango si el resultado es otro
    WHEN NEW.valor_texto IS NOT NULL AND v_rango.valor_texto IS NOT NULL AND v_rango.valor_texto <> 'Ver informe' THEN
      lower(NEW.valor_texto) <> lower(v_rango.valor_texto)
    ELSE false
  END;

  IF TG_OP = 'INSERT'
     OR NEW.valor_numerico IS DISTINCT FROM OLD.valor_numerico
     OR NEW.valor_texto IS DISTINCT FROM OLD.valor_texto THEN
    NEW.cargado_por := auth.uid();
    NEW.cargado_en := now();
  ELSE
    NEW.cargado_por := OLD.cargado_por;
    NEW.cargado_en := OLD.cargado_en;
  END IF;
  RETURN NEW;
END;
$$;

-- Si cambia (o se borra) el resultado del estudio base, se recalculan los absolutos
-- de la misma orden. El UPDATE no cambia el valor: solo vuelve a correr el control.
CREATE FUNCTION privado.recalcular_absolutos()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_fila public.resultados := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.valor_numerico IS NOT DISTINCT FROM OLD.valor_numerico THEN
    RETURN NEW;
  END IF;

  UPDATE public.resultados r
  SET valor_numerico = r.valor_numerico
  FROM public.orden_analisis oa_base
  JOIN public.orden_analisis oa ON oa.orden_id = oa_base.orden_id
  JOIN public.analisis a ON a.id = oa.analisis_id AND a.absoluto_de = oa_base.analisis_id
  WHERE oa_base.id = v_fila.orden_analisis_id
    AND r.orden_analisis_id = oa.id;

  RETURN v_fila;
END;
$$;

CREATE TRIGGER resultados_absolutos
  AFTER INSERT OR UPDATE OR DELETE ON public.resultados
  FOR EACH ROW EXECUTE FUNCTION privado.recalcular_absolutos();

-- 4. La orden se une a la llegada del paciente ─

CREATE FUNCTION privado.unir_ordenes_al_turno()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  UPDATE public.ordenes
  SET turno_id = NEW.id
  WHERE paciente_id = NEW.paciente_id
    AND sucursal_id = NEW.sucursal_id
    AND turno_id IS NULL
    AND estado = 'abierta'
    AND (fecha_recepcion AT TIME ZONE 'America/Argentina/Tucuman')::date = NEW.fecha;
  RETURN NEW;
END;
$$;

CREATE TRIGGER turnos_unir_ordenes
  AFTER INSERT ON public.turnos
  FOR EACH ROW EXECUTE FUNCTION privado.unir_ordenes_al_turno();

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;
