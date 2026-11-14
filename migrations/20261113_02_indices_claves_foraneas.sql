-- Índices para las claves foráneas que no tenían (auditoría del 12/11 y LIMS-44).
--
-- PostgreSQL crea índice solo para las claves primarias y únicas: una columna que apunta a otra tabla
-- no lo tiene si no se crea a mano. Sin índice, cruzar tablas por esa columna (ej: las órdenes de un
-- médico o de una obra social, los estudios de un análisis) y borrar o cambiar la fila a la que apunta
-- obliga a recorrer la tabla entera. Hoy no se nota porque hay pocos datos; con un año de uso, sí.
--
-- Lista sacada de la base el 13/11/2026: las 26 claves foráneas de public sin un índice que empiece por
-- esa columna (las que ya tenían uno, como resultados.orden_analisis_id o informes.orden_id, no se tocan).
-- IF NOT EXISTS: se puede volver a correr sin error.

CREATE INDEX IF NOT EXISTS analisis_absoluto_de_idx ON public.analisis (absoluto_de);
CREATE INDEX IF NOT EXISTS analisis_tipo_muestra_id_idx ON public.analisis (tipo_muestra_id);
CREATE INDEX IF NOT EXISTS cajas_abierta_por_idx ON public.cajas (abierta_por);
CREATE INDEX IF NOT EXISTS cajas_cerrada_por_idx ON public.cajas (cerrada_por);
CREATE INDEX IF NOT EXISTS cajas_reabierta_por_idx ON public.cajas (reabierta_por);
CREATE INDEX IF NOT EXISTS cambios_password_hecho_por_idx ON public.cambios_password (hecho_por);
CREATE INDEX IF NOT EXISTS cobros_anulado_por_idx ON public.cobros (anulado_por);
CREATE INDEX IF NOT EXISTS cobros_cobrado_por_idx ON public.cobros (cobrado_por);
CREATE INDEX IF NOT EXISTS informes_firmado_por_idx ON public.informes (firmado_por);
CREATE INDEX IF NOT EXISTS movimientos_muestra_usuario_id_idx ON public.movimientos_muestra (usuario_id);
CREATE INDEX IF NOT EXISTS muestras_tipo_muestra_id_idx ON public.muestras (tipo_muestra_id);
CREATE INDEX IF NOT EXISTS notificaciones_orden_id_idx ON public.notificaciones (orden_id);
CREATE INDEX IF NOT EXISTS orden_adjuntos_subido_por_idx ON public.orden_adjuntos (subido_por);
CREATE INDEX IF NOT EXISTS orden_analisis_analisis_id_idx ON public.orden_analisis (analisis_id);
CREATE INDEX IF NOT EXISTS orden_analisis_grupo_id_idx ON public.orden_analisis (grupo_id);
CREATE INDEX IF NOT EXISTS ordenes_anulada_por_idx ON public.ordenes (anulada_por);
CREATE INDEX IF NOT EXISTS ordenes_medico_id_idx ON public.ordenes (medico_id);
CREATE INDEX IF NOT EXISTS ordenes_obra_social_id_idx ON public.ordenes (obra_social_id);
CREATE INDEX IF NOT EXISTS ordenes_recibida_por_idx ON public.ordenes (recibida_por);
CREATE INDEX IF NOT EXISTS pacientes_obra_social_id_idx ON public.pacientes (obra_social_id);
CREATE INDEX IF NOT EXISTS resultados_cargado_por_idx ON public.resultados (cargado_por);
CREATE INDEX IF NOT EXISTS resultados_validado_por_idx ON public.resultados (validado_por);
CREATE INDEX IF NOT EXISTS turnos_finalizado_por_idx ON public.turnos (finalizado_por);
CREATE INDEX IF NOT EXISTS turnos_llamado_por_idx ON public.turnos (llamado_por);
CREATE INDEX IF NOT EXISTS turnos_registrado_por_idx ON public.turnos (registrado_por);
CREATE INDEX IF NOT EXISTS valores_ub_creado_por_idx ON public.valores_ub (creado_por);
