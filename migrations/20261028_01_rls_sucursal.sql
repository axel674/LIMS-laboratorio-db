-- Migración 08: RLS por sucursal
--
-- Hasta ahora la sucursal era solo un filtro de trabajo: cada persona elegía al
-- entrar en cuál trabajaba y podía ver las dos (rota entre sucursales). A partir
-- de esta migración es también un límite de seguridad: cada empleado pertenece a
-- una sucursal y solo ve las órdenes, muestras y resultados de esa sucursal.
-- El admin sigue viendo todo.
--
-- Toda la información cuelga de la orden:
--   ordenes.sucursal_id
--     ├─ muestras.orden_id
--     ├─ orden_analisis.orden_id ─ resultados.orden_analisis_id
--     ├─ informes.orden_id
--     └─ movimientos_muestra.muestra_id
--
-- Las políticas se reemplazan (DROP + CREATE): en PostgreSQL las políticas
-- permisivas se suman con OR, así que agregar una nueva no restringe nada.

-- ─────────────────────────────────────────────
-- 1. Sucursal del empleado
-- ─────────────────────────────────────────────

ALTER TABLE public.personal
  ADD COLUMN sucursal_id bigint REFERENCES public.sucursales(id);

COMMENT ON COLUMN public.personal.sucursal_id IS
  'Sucursal donde trabaja el empleado. Vacío = sin asignar: solo el admin puede trabajar así; el resto no ve datos de ninguna sucursal.';

-- Los empleados que ya existen quedan en la primera sucursal activa para no
-- dejarlos sin acceso. El admin los reasigna desde el panel (LIMS-21).
UPDATE public.personal
SET sucursal_id = (SELECT id FROM public.sucursales WHERE activa ORDER BY id LIMIT 1)
WHERE sucursal_id IS NULL;

CREATE INDEX personal_sucursal_id_idx ON public.personal (sucursal_id);

-- ─────────────────────────────────────────────
-- 2. Sucursal de la orden
-- ─────────────────────────────────────────────

ALTER TABLE public.ordenes
  ADD COLUMN sucursal_id bigint REFERENCES public.sucursales(id);

COMMENT ON COLUMN public.ordenes.sucursal_id IS
  'Sucursal que emitió la orden. Se hereda del turno; si la orden no viene de un turno, hay que indicarla al crearla.';

-- Órdenes anteriores: heredan la sucursal del turno del que salieron.
-- Una orden sin turno y sin sucursal queda invisible para el personal (solo la
-- ve el admin) hasta que se le asigne una.
UPDATE public.ordenes o
SET sucursal_id = t.sucursal_id
FROM public.turnos t
WHERE t.id = o.turno_id
  AND o.sucursal_id IS NULL;

CREATE INDEX ordenes_sucursal_id_idx ON public.ordenes (sucursal_id);

-- La sucursal se toma del turno para que no pueda quedar distinta de la del
-- paciente que se atendió. Si la orden no viene de un turno, se exige al crearla.
CREATE FUNCTION privado.completar_sucursal_orden()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Al crear: si viene de un turno, la sucursal es la del turno
    IF NEW.turno_id IS NOT NULL THEN
      SELECT t.sucursal_id INTO NEW.sucursal_id
      FROM public.turnos t
      WHERE t.id = NEW.turno_id;

      IF NEW.sucursal_id IS NULL THEN
        RAISE EXCEPTION 'El turno indicado en la orden no existe';
      END IF;
    END IF;

    IF NEW.sucursal_id IS NULL THEN
      RAISE EXCEPTION 'La orden necesita una sucursal: indique sucursal_id o un turno_id';
    END IF;
  ELSIF NEW.turno_id IS DISTINCT FROM OLD.turno_id AND NEW.turno_id IS NOT NULL THEN
    -- Si le cambian el turno, la orden pasa a la sucursal de ese turno
    SELECT t.sucursal_id INTO NEW.sucursal_id
    FROM public.turnos t
    WHERE t.id = NEW.turno_id;

    IF NEW.sucursal_id IS NULL THEN
      RAISE EXCEPTION 'El turno indicado en la orden no existe';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER ordenes_sucursal
  BEFORE INSERT OR UPDATE ON public.ordenes
  FOR EACH ROW EXECUTE FUNCTION privado.completar_sucursal_orden();

-- ─────────────────────────────────────────────
-- 3. Funciones auxiliares
-- ─────────────────────────────────────────────

-- Sucursal del empleado logueado (vacío si no es personal, si su cuenta está
-- inactiva o si todavía no tiene sucursal asignada).
CREATE FUNCTION privado.sucursal_actual()
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT p.sucursal_id
  FROM public.personal p
  JOIN public.perfiles pf ON pf.id = p.perfil_id
  WHERE p.perfil_id = auth.uid()
    AND pf.activo;
$$;

-- ¿El empleado logueado puede ver la sucursal indicada? El admin ve todas.
CREATE FUNCTION privado.ve_sucursal(p_sucursal bigint)
RETURNS boolean
LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT privado.tiene_rol('admin')
      OR (p_sucursal IS NOT NULL AND p_sucursal = privado.sucursal_actual());
$$;

-- Sucursal de la orden a la que pertenece una muestra, un estudio o un movimiento.
-- Son SECURITY DEFINER para no encadenar las políticas de las tablas de arriba.
CREATE FUNCTION privado.sucursal_de_orden(p_orden_id uuid)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT sucursal_id FROM public.ordenes WHERE id = p_orden_id;
$$;

CREATE FUNCTION privado.sucursal_de_estudio(p_orden_analisis_id uuid)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT o.sucursal_id
  FROM public.orden_analisis oa
  JOIN public.ordenes o ON o.id = oa.orden_id
  WHERE oa.id = p_orden_analisis_id;
$$;

CREATE FUNCTION privado.sucursal_de_muestra(p_muestra_id uuid)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT o.sucursal_id
  FROM public.muestras m
  JOIN public.ordenes o ON o.id = m.orden_id
  WHERE m.id = p_muestra_id;
$$;

-- Las funciones nuevas también quedan sin acceso para anon
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;

-- ─────────────────────────────────────────────
-- 4. Órdenes
-- ─────────────────────────────────────────────

DROP POLICY IF EXISTS "ordenes: el paciente ve las suyas, el personal todas" ON public.ordenes;
CREATE POLICY "ordenes: el paciente ve las suyas, el personal las de su sucursal" ON public.ordenes
  FOR SELECT TO authenticated
  USING (
    paciente_id = (SELECT privado.paciente_actual_id())
    OR (SELECT privado.ve_sucursal(sucursal_id))
  );

DROP POLICY IF EXISTS "ordenes: recepcion y admin gestionan" ON public.ordenes;
CREATE POLICY "ordenes: recepcion y admin gestionan" ON public.ordenes
  FOR ALL TO authenticated
  USING (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('recepcion')) AND (SELECT privado.ve_sucursal(sucursal_id)))
  )
  WITH CHECK (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('recepcion')) AND (SELECT privado.ve_sucursal(sucursal_id)))
  );

-- ─────────────────────────────────────────────
-- 5. Estudios tildados en la orden
-- ─────────────────────────────────────────────

DROP POLICY IF EXISTS "orden_analisis: lo ve el personal" ON public.orden_analisis;
CREATE POLICY "orden_analisis: lo ve el personal" ON public.orden_analisis
  FOR SELECT TO authenticated
  USING ((SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))));

DROP POLICY IF EXISTS "orden_analisis: recepcion y admin tildan estudios" ON public.orden_analisis;
CREATE POLICY "orden_analisis: recepcion y admin tildan estudios" ON public.orden_analisis
  FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('recepcion')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))))
  );

DROP POLICY IF EXISTS "orden_analisis: el personal asigna tubos y corrige" ON public.orden_analisis;
CREATE POLICY "orden_analisis: el personal asigna tubos y corrige" ON public.orden_analisis
  FOR UPDATE TO authenticated
  USING ((SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))))
  WITH CHECK ((SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))));

DROP POLICY IF EXISTS "orden_analisis: recepcion y admin destildan" ON public.orden_analisis;
CREATE POLICY "orden_analisis: recepcion y admin destildan" ON public.orden_analisis
  FOR DELETE TO authenticated
  USING (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('recepcion')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))))
  );

-- ─────────────────────────────────────────────
-- 6. Muestras y trazabilidad
-- ─────────────────────────────────────────────

DROP POLICY IF EXISTS "muestras: las ve el personal" ON public.muestras;
CREATE POLICY "muestras: las ve el personal" ON public.muestras
  FOR SELECT TO authenticated
  USING ((SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))));

DROP POLICY IF EXISTS "muestras: el personal registra extracciones" ON public.muestras;
CREATE POLICY "muestras: el personal registra extracciones" ON public.muestras
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))));

DROP POLICY IF EXISTS "muestras: tecnico, bioquimico y admin cambian el estado" ON public.muestras;
CREATE POLICY "muestras: tecnico, bioquimico y admin cambian el estado" ON public.muestras
  FOR UPDATE TO authenticated
  USING (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('tecnico', 'bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))))
  )
  WITH CHECK (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('tecnico', 'bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))))
  );

DROP POLICY IF EXISTS "movimientos_muestra: los ve el personal" ON public.movimientos_muestra;
CREATE POLICY "movimientos_muestra: los ve el personal" ON public.movimientos_muestra
  FOR SELECT TO authenticated
  USING ((SELECT privado.ve_sucursal(privado.sucursal_de_muestra(muestra_id))));

-- ─────────────────────────────────────────────
-- 7. Resultados
-- ─────────────────────────────────────────────

DROP POLICY IF EXISTS "resultados: los ve el personal" ON public.resultados;
CREATE POLICY "resultados: los ve el personal" ON public.resultados
  FOR SELECT TO authenticated
  USING ((SELECT privado.ve_sucursal(privado.sucursal_de_estudio(orden_analisis_id))));

DROP POLICY IF EXISTS "resultados: bioquimico y admin cargan" ON public.resultados;
CREATE POLICY "resultados: bioquimico y admin cargan" ON public.resultados
  FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_estudio(orden_analisis_id))))
  );

DROP POLICY IF EXISTS "resultados: bioquimico y admin validan" ON public.resultados;
CREATE POLICY "resultados: bioquimico y admin validan" ON public.resultados
  FOR UPDATE TO authenticated
  USING (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_estudio(orden_analisis_id))))
  )
  WITH CHECK (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_estudio(orden_analisis_id))))
  );

-- ─────────────────────────────────────────────
-- 8. Informes
-- ─────────────────────────────────────────────

DROP POLICY IF EXISTS "informes: el paciente ve los suyos publicados, el personal todos" ON public.informes;
CREATE POLICY "informes: el paciente ve los suyos publicados, el personal los de su sucursal" ON public.informes
  FOR SELECT TO authenticated
  USING (
    (SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id)))
    OR (
      estado = 'publicado'
      AND orden_id IN (
        SELECT id FROM public.ordenes WHERE paciente_id = (SELECT privado.paciente_actual_id())
      )
    )
  );

DROP POLICY IF EXISTS "informes: bioquimico y admin firman y publican" ON public.informes;
CREATE POLICY "informes: bioquimico y admin firman y publican" ON public.informes
  FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))))
  );

DROP POLICY IF EXISTS "informes: bioquimico y admin modifican" ON public.informes;
CREATE POLICY "informes: bioquimico y admin modifican" ON public.informes
  FOR UPDATE TO authenticated
  USING (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))))
  )
  WITH CHECK (
    (SELECT privado.tiene_rol('admin'))
    OR ((SELECT privado.tiene_rol('bioquimico')) AND (SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))))
  );

-- Pendiente para otra tarea: `turnos` también tiene sucursal_id y hoy el
-- personal ve la fila de las dos sucursales. No se filtra acá porque Recepción
-- consulta los turnos del paciente para avisar si ya se registró en la otra
-- sucursal (ver RegistroLlegada.jsx).
