-- Pedido médico adjunto a la orden (LIMS-34)
--
-- Recepción puede respaldar el pedido médico que trae el paciente: hasta 5 fotos
-- (JPG o PNG) o PDF. No es obligatorio: la orden se carga igual sin archivo.
--
-- - Los archivos van al bucket privado "pedidos", uno por hoja en
--   <orden_id>/<nombre único>. La tabla orden_adjuntos guarda el nombre original,
--   el tipo, el tamaño y quién y cuándo lo subió.
-- - Los ve solo el personal de la sucursal de la orden. El paciente no los ve en
--   su portal (ya tiene el papel).
-- - Recepción y el admin suben y quitan adjuntos mientras la orden está abierta.
-- - La ruta se abre con una URL firmada que vence a los pocos minutos (LIMS-15).
--
-- Depende de 20261028_01_rls_sucursal.sql.

-- 1. Bucket privado ────────────────────────────

-- Privado (sin links públicos), solo fotos y PDF, y hasta 5 MB por archivo.
-- Las fotos se achican en el navegador antes de subirlas: suelen pesar unos
-- cientos de KB.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'pedidos',
  'pedidos',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'application/pdf']
)
ON CONFLICT (id) DO NOTHING;

-- 2. Adjuntos de la orden ───────────────────────

CREATE TABLE public.orden_adjuntos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  orden_id uuid NOT NULL REFERENCES public.ordenes (id) ON DELETE CASCADE,
  -- Ruta en el bucket "pedidos": <orden_id>/<nombre único>
  path text NOT NULL UNIQUE,
  nombre varchar NOT NULL,
  tipo varchar NOT NULL,
  tamano bigint NOT NULL CHECK (tamano > 0),
  -- Quien sube el archivo: sale del token, no lo elige el navegador
  subido_por uuid NOT NULL DEFAULT auth.uid() REFERENCES public.perfiles (id),
  subido_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT orden_adjuntos_path_de_la_orden CHECK (path LIKE orden_id::text || '/%')
);

CREATE INDEX orden_adjuntos_orden_id_idx ON public.orden_adjuntos (orden_id);

COMMENT ON TABLE public.orden_adjuntos IS
  'Pedido médico escaneado que respalda una orden: hasta 5 fotos o PDF en el bucket privado "pedidos".';
COMMENT ON COLUMN public.orden_adjuntos.path IS 'Ruta en el bucket "pedidos": <orden_id>/<nombre único>.';
COMMENT ON COLUMN public.orden_adjuntos.nombre IS 'Nombre original del archivo, el que ve el usuario.';
COMMENT ON COLUMN public.orden_adjuntos.tipo IS 'image/jpeg, image/png o application/pdf.';

-- 3. Reglas de la fila ─────────────────────────
-- La ruta empieza con la orden, el adjunto se registra a nombre de quien lo sube
-- y la orden admite hasta 5. El rol y la sucursal los controlan las políticas.

CREATE FUNCTION privado.controlar_adjunto()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_orden public.ordenes;
  v_cantidad int;
BEGIN
  SELECT * INTO v_orden FROM public.ordenes WHERE id = NEW.orden_id;

  IF v_orden.id IS NULL OR NOT privado.ve_sucursal(v_orden.sucursal_id) THEN
    RAISE EXCEPTION 'No se encontró la orden' USING ERRCODE = 'P0002';
  END IF;

  IF NEW.path NOT LIKE v_orden.id::text || '/%' THEN
    RAISE EXCEPTION 'La ruta del adjunto no corresponde a la orden' USING ERRCODE = '22023';
  END IF;

  IF NEW.subido_por IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'El adjunto se registra a nombre de quien lo sube' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_cantidad FROM public.orden_adjuntos WHERE orden_id = NEW.orden_id;
  IF v_cantidad >= 5 THEN
    RAISE EXCEPTION 'Una orden admite hasta 5 adjuntos del pedido médico' USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER orden_adjuntos_control
  BEFORE INSERT ON public.orden_adjuntos
  FOR EACH ROW EXECUTE FUNCTION privado.controlar_adjunto();

-- 4. Seguridad de la tabla ─────────────────────
-- Los adjuntos no se modifican: se suben y se quitan.

ALTER TABLE public.orden_adjuntos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.orden_adjuntos FROM anon;
GRANT SELECT, INSERT, DELETE ON public.orden_adjuntos TO authenticated;
REVOKE UPDATE ON public.orden_adjuntos FROM authenticated;

-- ¿El empleado logueado gestiona los adjuntos de esta orden? Recepción o admin
-- de la sucursal, mientras la orden está abierta.
CREATE FUNCTION privado.puede_gestionar_adjuntos(p_orden_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.ordenes o
    WHERE o.id = p_orden_id
      AND o.estado = 'abierta'
      AND privado.tiene_rol('recepcion', 'admin')
      AND privado.ve_sucursal(o.sucursal_id)
  );
$$;

CREATE POLICY "orden_adjuntos: los ve el personal de la sucursal" ON public.orden_adjuntos
  FOR SELECT TO authenticated
  USING ((SELECT privado.ve_sucursal(privado.sucursal_de_orden(orden_id))));

CREATE POLICY "orden_adjuntos: recepcion y admin suben" ON public.orden_adjuntos
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT privado.puede_gestionar_adjuntos(orden_id)));

CREATE POLICY "orden_adjuntos: recepcion y admin quitan" ON public.orden_adjuntos
  FOR DELETE TO authenticated
  USING ((SELECT privado.puede_gestionar_adjuntos(orden_id)));

-- 5. Seguridad del bucket ──────────────────────
-- Las mismas reglas que la tabla, aplicadas al archivo. El paciente no lee.

-- Orden a la que pertenece un archivo: el primer tramo de la ruta.
CREATE FUNCTION privado.orden_de_pedido(p_nombre text)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT o.id
  FROM public.ordenes o
  WHERE o.id::text = split_part(p_nombre, '/', 1);
$$;

CREATE FUNCTION privado.puede_leer_pedido(p_nombre text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.ordenes o
    WHERE o.id = privado.orden_de_pedido(p_nombre)
      AND privado.es_personal()
      AND privado.ve_sucursal(o.sucursal_id)
  );
$$;

CREATE FUNCTION privado.puede_gestionar_pedido(p_nombre text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT privado.puede_gestionar_adjuntos(privado.orden_de_pedido(p_nombre));
$$;

CREATE POLICY "pedidos: lo lee el personal de la sucursal" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'pedidos' AND privado.puede_leer_pedido(name));

CREATE POLICY "pedidos: recepcion y admin suben" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'pedidos' AND privado.puede_gestionar_pedido(name));

CREATE POLICY "pedidos: recepcion y admin quitan" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'pedidos' AND privado.puede_gestionar_pedido(name));

-- 6. Permisos de las funciones nuevas ───────────

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;
