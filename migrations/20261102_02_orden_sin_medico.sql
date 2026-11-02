-- Orden sin pedido médico (LIMS-33)
--
-- Cualquier persona puede venir a hacerse estudios por su cuenta, sin pedido
-- médico. En ese caso todo se cobra como particular.
--
-- Regla:
-- - Sin médico → orden particular: no puede tener obra social. Los estudios
--   quedan sin cobertura y los aranceles (20261031_01) los cobran a valor
--   particular, igual que cualquier orden sin obra social.
-- - Con médico → igual que hasta ahora, con obra social o particular.
--
-- crear_orden y modificar_orden no cambian: ya pasan p_medico_id tal como llega
-- a la columna, y con obra social vacía marcan todos los estudios como no
-- cubiertos. Desde el panel se envía p_medico_id: null.

-- 1. El médico deja de ser obligatorio ─────────

ALTER TABLE public.ordenes ALTER COLUMN medico_id DROP NOT NULL;

-- 2. Sin médico, solo particular ───────────────
-- Las órdenes ya cargadas tienen todas médico: la regla se cumple sin migrar datos.
-- El panel muestra un mensaje propio para este código (ver mensajeDeErrorApi).

ALTER TABLE public.ordenes
  ADD CONSTRAINT ordenes_sin_medico_es_particular
    CHECK (medico_id IS NOT NULL OR obra_social_id IS NULL);

COMMENT ON COLUMN public.ordenes.medico_id IS
  'Médico que pidió los estudios. Vacío = sin pedido médico (el paciente vino por su cuenta): la orden es particular.';
COMMENT ON COLUMN public.ordenes.fecha_orden IS
  'Fecha del pedido médico, o del día en que se cargó si no hay pedido (no puede ser futura).';
COMMENT ON CONSTRAINT ordenes_sin_medico_es_particular ON public.ordenes IS
  'Una orden sin pedido médico no puede tener obra social: se cobra a valor particular.';
