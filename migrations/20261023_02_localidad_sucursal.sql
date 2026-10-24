-- Localidad de cada sucursal
--
-- Se muestra en letra chica al lado del logo, en la barra del panel, para que
-- quien trabaja vea de un vistazo en qué sucursal está. El admin la edita desde
-- Configuración.

ALTER TABLE public.sucursales
  ADD COLUMN localidad varchar CHECK (localidad IS NULL OR btrim(localidad) <> '');
COMMENT ON COLUMN public.sucursales.localidad IS 'Ciudad o zona; se muestra al lado del logo en el panel.';

UPDATE public.sucursales SET localidad = 'San Miguel' WHERE prefijo = 'S1';
UPDATE public.sucursales SET localidad = 'Concepción' WHERE prefijo = 'S2';
