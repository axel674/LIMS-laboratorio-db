-- Borra la tabla configuracion, sin uso desde 20261023_01_sucursales.
--
-- Guardaba la cantidad de boxes de todo el laboratorio en una sola fila. Desde que hay sucursales,
-- cada una tiene sus boxes en sucursales.cantidad_boxes y ninguna función ni pantalla la lee
-- (la ruta /panel/configuracion del front solo redirige a Sucursales).
-- Verificado el 13/11/2026: ninguna función, vista ni clave foránea depende de ella.
-- DROP TABLE también borra sus dos políticas RLS.

DROP TABLE IF EXISTS public.configuracion;
