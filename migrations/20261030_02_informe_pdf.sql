-- Informe PDF de resultados (LIMS-15)
--
-- Después de validar la orden (LIMS-14) el bioquímico firma el informe: la Edge
-- Function generar-informe arma el PDF, lo sube al bucket privado "informes" y
-- llama a publicar_informe, que lo deja publicado y pasa la orden a 'informada'.
--
-- Dónde queda el PDF: bucket privado "informes", un archivo por orden en
-- <paciente_id>/<orden_id>.pdf. La ruta queda en informes.pdf_path. El paciente
-- solo puede bajar los suyos publicados (con una URL firmada que vence), el
-- personal los de su sucursal y solo el bioquímico sube archivos.
--
-- Depende de 20261030_01_validacion_orden.sql.

-- 1. Bucket privado ────────────────────────────

-- Privado (sin links públicos), solo PDF y hasta 1 MB por archivo: un informe
-- pesa menos de 100 KB
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('informes', 'informes', false, 1048576, ARRAY['application/pdf'])
ON CONFLICT (id) DO NOTHING;

-- 2. Quién lee y quién sube ────────────────────

-- Ruta del PDF de una orden: <paciente_id>/<orden_id>.pdf
CREATE FUNCTION privado.ruta_informe(p_orden public.ordenes)
RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT p_orden.paciente_id::text || '/' || p_orden.id::text || '.pdf';
$$;

-- Sube (o reemplaza) el PDF el bioquímico de la sucursal, mientras la orden está
-- validada y todavía no se publicó. Una vez informada, el archivo ya no cambia.
CREATE FUNCTION privado.puede_subir_informe(p_nombre text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT privado.tiene_rol('bioquimico') AND EXISTS (
    SELECT 1 FROM public.ordenes o
    WHERE privado.ruta_informe(o) = p_nombre
      AND o.estado = 'completa'
      AND privado.ve_sucursal(o.sucursal_id)
  );
$$;

-- Lee el PDF el paciente si es suyo y está publicado, o el personal de la sucursal
CREATE FUNCTION privado.puede_leer_informe(p_nombre text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.informes i
    JOIN public.ordenes o ON o.id = i.orden_id
    WHERE i.pdf_path = p_nombre
      AND (
        (i.estado = 'publicado' AND o.paciente_id = privado.paciente_actual_id())
        OR (privado.es_personal() AND privado.ve_sucursal(o.sucursal_id))
      )
  );
$$;

-- Leer también hace falta para reemplazar el archivo (upsert) antes de publicarlo
CREATE POLICY "informes: lectura del pdf" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'informes' AND (privado.puede_leer_informe(name) OR privado.puede_subir_informe(name)));

CREATE POLICY "informes: el bioquimico sube el pdf" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'informes' AND privado.puede_subir_informe(name));

CREATE POLICY "informes: el bioquimico reemplaza el pdf" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'informes' AND privado.puede_subir_informe(name))
  WITH CHECK (bucket_id = 'informes' AND privado.puede_subir_informe(name));

-- Sin política de DELETE: nadie borra un informe desde la app

-- 3. Firmar y publicar ─────────────────────────

-- La llama generar-informe después de subir el PDF, con la sesión del bioquímico.
-- Deja el informe firmado (quién, cuándo y el SHA-256 del archivo) y publicado,
-- y la orden informada. Todo o nada.
CREATE FUNCTION public.publicar_informe(p_orden_id uuid, p_pdf_path text, p_hash_firma text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_orden public.ordenes;
  v_informe public.informes;
BEGIN
  IF NOT privado.tiene_rol('bioquimico') THEN
    RAISE EXCEPTION 'Solo el bioquímico firma el informe' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_orden FROM public.ordenes WHERE id = p_orden_id FOR UPDATE;

  -- Es SECURITY DEFINER: la sucursal se controla a mano
  IF v_orden.id IS NULL OR NOT privado.ve_sucursal(v_orden.sucursal_id) THEN
    RAISE EXCEPTION 'No se encontró la orden' USING ERRCODE = 'P0002';
  END IF;

  IF v_orden.estado = 'informada' THEN
    RAISE EXCEPTION 'El informe de la orden % ya está publicado', v_orden.nro_orden USING ERRCODE = '22023';
  ELSIF v_orden.estado <> 'completa' THEN
    RAISE EXCEPTION 'La orden % todavía no está validada', v_orden.nro_orden USING ERRCODE = '22023';
  END IF;

  IF p_pdf_path IS DISTINCT FROM privado.ruta_informe(v_orden) THEN
    RAISE EXCEPTION 'La ruta del PDF no corresponde a la orden' USING ERRCODE = '22023';
  END IF;

  IF p_hash_firma IS NULL OR p_hash_firma !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'La firma del PDF no es válida' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'informes' AND name = p_pdf_path) THEN
    RAISE EXCEPTION 'No se encontró el PDF del informe' USING ERRCODE = 'P0002';
  END IF;

  -- La validación ya crea el informe en borrador; por las dudas se crea si falta
  INSERT INTO public.informes (orden_id) VALUES (p_orden_id) ON CONFLICT (orden_id) DO NOTHING;

  UPDATE public.informes
  SET estado = 'publicado',
      firmado_por = auth.uid(),
      firmado_en = now(),
      hash_firma = p_hash_firma,
      pdf_path = p_pdf_path,
      publicado_en = now()
  WHERE orden_id = p_orden_id
  RETURNING * INTO v_informe;

  UPDATE public.ordenes SET estado = 'informada' WHERE id = p_orden_id;

  RETURN jsonb_build_object(
    'informe_id', v_informe.id,
    'pdf_path', v_informe.pdf_path,
    'publicado_en', v_informe.publicado_en
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publicar_informe(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publicar_informe(uuid, text, text) TO authenticated;

-- 4. Un informe publicado no cambia ────────────

-- Lo firmado (archivo, firma, quién y cuándo) queda fijo. Solo se puede marcar
-- después que se envió por mail (LIMS-18). Un informe se publica únicamente con
-- publicar_informe, que deja la orden informada.
CREATE FUNCTION privado.controlar_informe()
RETURNS trigger
LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF OLD.estado = 'publicado' AND (
       NEW.estado IS DISTINCT FROM OLD.estado
    OR NEW.pdf_path IS DISTINCT FROM OLD.pdf_path
    OR NEW.hash_firma IS DISTINCT FROM OLD.hash_firma
    OR NEW.firmado_por IS DISTINCT FROM OLD.firmado_por
    OR NEW.firmado_en IS DISTINCT FROM OLD.firmado_en
    OR NEW.publicado_en IS DISTINCT FROM OLD.publicado_en
    OR NEW.orden_id IS DISTINCT FROM OLD.orden_id
  ) THEN
    RAISE EXCEPTION 'El informe ya está publicado: no se puede modificar' USING ERRCODE = '22023';
  END IF;

  IF NEW.estado = 'publicado' AND OLD.estado IS DISTINCT FROM 'publicado' AND (
       NEW.pdf_path IS NULL OR NEW.hash_firma IS NULL OR NEW.firmado_por IS NULL
    OR NOT EXISTS (SELECT 1 FROM public.ordenes WHERE id = NEW.orden_id AND estado = 'completa')
  ) THEN
    RAISE EXCEPTION 'El informe se publica al firmarlo, con su PDF' USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER informes_control
  BEFORE UPDATE ON public.informes
  FOR EACH ROW EXECUTE FUNCTION privado.controlar_informe();

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;
