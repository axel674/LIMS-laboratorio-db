-- Migración 02: seguridad (roles, trazabilidad y Row Level Security)
--
-- Regla general: el frontend habla directo con la base usando la clave pública,
-- así que TODO acceso pasa por las políticas de este archivo.
-- - anon (sin sesión): no ve ninguna tabla.
-- - paciente: solo sus propios datos y sus informes publicados.
-- - personal: según su rol (admin, bioquimico, tecnico, recepcion).

-- ─────────────────────────────────────────────
-- Funciones auxiliares (esquema privado, no expuesto por la API)
-- ─────────────────────────────────────────────

CREATE SCHEMA IF NOT EXISTS privado;
GRANT USAGE ON SCHEMA privado TO authenticated;

-- Rol del usuario que hace la consulta. SECURITY DEFINER evita que las políticas
-- de perfiles se llamen a sí mismas en forma recursiva.
CREATE FUNCTION privado.rol_actual()
RETURNS public.rol_usuario
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT rol FROM public.perfiles WHERE id = auth.uid() AND activo;
$$;

CREATE FUNCTION privado.tiene_rol(VARIADIC roles public.rol_usuario[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT coalesce(privado.rol_actual() = ANY (roles), false);
$$;

CREATE FUNCTION privado.es_personal()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT privado.tiene_rol('admin', 'bioquimico', 'tecnico', 'recepcion');
$$;

-- Ficha de paciente del usuario logueado (null si no es paciente).
CREATE FUNCTION privado.paciente_actual_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT id FROM public.pacientes WHERE perfil_id = auth.uid();
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;

-- ─────────────────────────────────────────────
-- Trazabilidad automática de muestras
-- ─────────────────────────────────────────────
-- Cada alta o cambio de estado de una muestra deja un movimiento con el usuario,
-- la fecha y la hora, sin que el personal tenga que hacer nada extra.

CREATE FUNCTION privado.registrar_movimiento_muestra()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Los cambios de estado de una muestra deben hacerse con un usuario logueado (trazabilidad)';
  END IF;

  IF TG_OP = 'INSERT' OR NEW.estado IS DISTINCT FROM OLD.estado THEN
    INSERT INTO public.movimientos_muestra (muestra_id, estado_anterior, estado_nuevo, usuario_id, observacion)
    VALUES (
      NEW.id,
      CASE WHEN TG_OP = 'UPDATE' THEN OLD.estado END,
      NEW.estado,
      auth.uid(),
      CASE WHEN NEW.estado = 'rechazada' THEN NEW.motivo_rechazo END
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER muestras_trazabilidad
  AFTER INSERT OR UPDATE OF estado ON public.muestras
  FOR EACH ROW EXECUTE FUNCTION privado.registrar_movimiento_muestra();

-- ─────────────────────────────────────────────
-- Primer ingreso del paciente
-- ─────────────────────────────────────────────
-- El frontend primero cambia la contraseña (supabase.auth.updateUser) y después
-- llama a esta función para guardar el email real y dar por completado el alta.

CREATE FUNCTION public.completar_primer_ingreso(p_email text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_email text := lower(trim(p_email));
BEGIN
  IF privado.rol_actual() IS DISTINCT FROM 'paciente' THEN
    RAISE EXCEPTION 'Solo un paciente puede completar su primer ingreso';
  END IF;
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'El email no tiene un formato válido';
  END IF;

  UPDATE public.pacientes SET email = v_email WHERE perfil_id = auth.uid();
  UPDATE public.perfiles SET debe_cambiar_password = false WHERE id = auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION public.completar_primer_ingreso(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.completar_primer_ingreso(text) TO authenticated;

-- ─────────────────────────────────────────────
-- Permisos base: anon no accede a nada; authenticated queda sujeto a RLS
-- ─────────────────────────────────────────────

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Las notificaciones solo se pueden marcar como leídas
REVOKE UPDATE ON public.notificaciones FROM authenticated;
GRANT UPDATE (leida) ON public.notificaciones TO authenticated;

-- La trazabilidad no se edita ni se borra: solo la escribe el trigger
REVOKE INSERT, UPDATE, DELETE ON public.movimientos_muestra FROM authenticated;

-- ─────────────────────────────────────────────
-- Row Level Security
-- ─────────────────────────────────────────────

ALTER TABLE public.perfiles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.personal             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pacientes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.obras_sociales       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medicos              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.turnos               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ordenes              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tipos_muestra        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analisis             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grupos_analisis      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grupo_analisis_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.muestras             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimientos_muestra  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orden_analisis       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resultados           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.informes             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notificaciones       ENABLE ROW LEVEL SECURITY;

-- Usuarios y personas ────────────────────────

CREATE POLICY "perfiles: cada uno ve el suyo, el personal ve todos" ON public.perfiles
  FOR SELECT TO authenticated
  USING (id = (SELECT auth.uid()) OR (SELECT privado.es_personal()));
CREATE POLICY "perfiles: admin gestiona" ON public.perfiles
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('admin'))) WITH CHECK ((SELECT privado.tiene_rol('admin')));

CREATE POLICY "personal: lo ve el personal" ON public.personal
  FOR SELECT TO authenticated
  USING ((SELECT privado.es_personal()));
CREATE POLICY "personal: admin gestiona" ON public.personal
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('admin'))) WITH CHECK ((SELECT privado.tiene_rol('admin')));

CREATE POLICY "pacientes: el paciente ve su ficha, el personal todas" ON public.pacientes
  FOR SELECT TO authenticated
  USING (perfil_id = (SELECT auth.uid()) OR (SELECT privado.es_personal()));
CREATE POLICY "pacientes: recepcion y admin dan de alta" ON public.pacientes
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT privado.tiene_rol('recepcion', 'admin')));
CREATE POLICY "pacientes: recepcion y admin modifican" ON public.pacientes
  FOR UPDATE TO authenticated
  USING ((SELECT privado.tiene_rol('recepcion', 'admin')))
  WITH CHECK ((SELECT privado.tiene_rol('recepcion', 'admin')));
CREATE POLICY "pacientes: admin borra" ON public.pacientes
  FOR DELETE TO authenticated
  USING ((SELECT privado.tiene_rol('admin')));

-- Catálogos: los lee cualquier usuario logueado ─

CREATE POLICY "obras_sociales: lectura" ON public.obras_sociales
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "obras_sociales: admin gestiona" ON public.obras_sociales
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('admin'))) WITH CHECK ((SELECT privado.tiene_rol('admin')));

CREATE POLICY "medicos: lectura del personal" ON public.medicos
  FOR SELECT TO authenticated USING ((SELECT privado.es_personal()));
CREATE POLICY "medicos: recepcion y admin dan de alta" ON public.medicos
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT privado.tiene_rol('recepcion', 'admin')));
CREATE POLICY "medicos: recepcion y admin modifican" ON public.medicos
  FOR UPDATE TO authenticated
  USING ((SELECT privado.tiene_rol('recepcion', 'admin')))
  WITH CHECK ((SELECT privado.tiene_rol('recepcion', 'admin')));
CREATE POLICY "medicos: admin borra" ON public.medicos
  FOR DELETE TO authenticated
  USING ((SELECT privado.tiene_rol('admin')));

CREATE POLICY "tipos_muestra: lectura" ON public.tipos_muestra
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "tipos_muestra: admin gestiona" ON public.tipos_muestra
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('admin'))) WITH CHECK ((SELECT privado.tiene_rol('admin')));

CREATE POLICY "analisis: lectura" ON public.analisis
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "analisis: admin gestiona" ON public.analisis
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('admin'))) WITH CHECK ((SELECT privado.tiene_rol('admin')));

CREATE POLICY "grupos_analisis: lectura" ON public.grupos_analisis
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "grupos_analisis: admin gestiona" ON public.grupos_analisis
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('admin'))) WITH CHECK ((SELECT privado.tiene_rol('admin')));

CREATE POLICY "grupo_analisis_items: lectura" ON public.grupo_analisis_items
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "grupo_analisis_items: admin gestiona" ON public.grupo_analisis_items
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('admin'))) WITH CHECK ((SELECT privado.tiene_rol('admin')));

-- Recepción ───────────────────────────────────

CREATE POLICY "turnos: el paciente ve los suyos, el personal todos" ON public.turnos
  FOR SELECT TO authenticated
  USING (paciente_id = (SELECT privado.paciente_actual_id()) OR (SELECT privado.es_personal()));
CREATE POLICY "turnos: recepcion y admin gestionan" ON public.turnos
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('recepcion', 'admin')))
  WITH CHECK ((SELECT privado.tiene_rol('recepcion', 'admin')));

CREATE POLICY "ordenes: el paciente ve las suyas, el personal todas" ON public.ordenes
  FOR SELECT TO authenticated
  USING (paciente_id = (SELECT privado.paciente_actual_id()) OR (SELECT privado.es_personal()));
CREATE POLICY "ordenes: recepcion y admin gestionan" ON public.ordenes
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('recepcion', 'admin')))
  WITH CHECK ((SELECT privado.tiene_rol('recepcion', 'admin')));

CREATE POLICY "orden_analisis: lo ve el personal" ON public.orden_analisis
  FOR SELECT TO authenticated USING ((SELECT privado.es_personal()));
CREATE POLICY "orden_analisis: recepcion y admin tildan estudios" ON public.orden_analisis
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT privado.tiene_rol('recepcion', 'admin')));
CREATE POLICY "orden_analisis: el personal asigna tubos y corrige" ON public.orden_analisis
  FOR UPDATE TO authenticated
  USING ((SELECT privado.es_personal())) WITH CHECK ((SELECT privado.es_personal()));
CREATE POLICY "orden_analisis: recepcion y admin destildan" ON public.orden_analisis
  FOR DELETE TO authenticated
  USING ((SELECT privado.tiene_rol('recepcion', 'admin')));

-- Muestras y trazabilidad ─────────────────────

CREATE POLICY "muestras: las ve el personal" ON public.muestras
  FOR SELECT TO authenticated USING ((SELECT privado.es_personal()));
CREATE POLICY "muestras: el personal registra extracciones" ON public.muestras
  FOR INSERT TO authenticated WITH CHECK ((SELECT privado.es_personal()));
CREATE POLICY "muestras: tecnico, bioquimico y admin cambian el estado" ON public.muestras
  FOR UPDATE TO authenticated
  USING ((SELECT privado.tiene_rol('tecnico', 'bioquimico', 'admin')))
  WITH CHECK ((SELECT privado.tiene_rol('tecnico', 'bioquimico', 'admin')));

CREATE POLICY "movimientos_muestra: los ve el personal" ON public.movimientos_muestra
  FOR SELECT TO authenticated USING ((SELECT privado.es_personal()));

-- Resultados e informes ───────────────────────

CREATE POLICY "resultados: los ve el personal" ON public.resultados
  FOR SELECT TO authenticated USING ((SELECT privado.es_personal()));
CREATE POLICY "resultados: bioquimico y admin cargan" ON public.resultados
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT privado.tiene_rol('bioquimico', 'admin')));
CREATE POLICY "resultados: bioquimico y admin validan" ON public.resultados
  FOR UPDATE TO authenticated
  USING ((SELECT privado.tiene_rol('bioquimico', 'admin')))
  WITH CHECK ((SELECT privado.tiene_rol('bioquimico', 'admin')));

CREATE POLICY "informes: el paciente ve los suyos publicados, el personal todos" ON public.informes
  FOR SELECT TO authenticated
  USING (
    (SELECT privado.es_personal())
    OR (
      estado = 'publicado'
      AND orden_id IN (
        SELECT id FROM public.ordenes WHERE paciente_id = (SELECT privado.paciente_actual_id())
      )
    )
  );
CREATE POLICY "informes: bioquimico y admin firman y publican" ON public.informes
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT privado.tiene_rol('bioquimico', 'admin')));
CREATE POLICY "informes: bioquimico y admin modifican" ON public.informes
  FOR UPDATE TO authenticated
  USING ((SELECT privado.tiene_rol('bioquimico', 'admin')))
  WITH CHECK ((SELECT privado.tiene_rol('bioquimico', 'admin')));

-- Notificaciones ──────────────────────────────

CREATE POLICY "notificaciones: cada uno ve las suyas" ON public.notificaciones
  FOR SELECT TO authenticated USING (destinatario_id = (SELECT auth.uid()));
CREATE POLICY "notificaciones: cada uno marca las suyas como leidas" ON public.notificaciones
  FOR UPDATE TO authenticated
  USING (destinatario_id = (SELECT auth.uid()))
  WITH CHECK (destinatario_id = (SELECT auth.uid()));
CREATE POLICY "notificaciones: el personal las genera" ON public.notificaciones
  FOR INSERT TO authenticated WITH CHECK ((SELECT privado.es_personal()));
