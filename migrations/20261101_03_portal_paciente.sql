-- Portal del paciente: sus estudios y la descarga del informe (LIMS-17)
--
-- El paciente entra con su DNI y ve la lista de sus órdenes: fecha, número,
-- médico y si el informe ya está listo para descargar.
--
-- La base ya deja que cada paciente vea solo sus propias órdenes (política de
-- ordenes) y solo sus informes publicados (política de informes). Faltaba el
-- médico: hoy solo lo lee el personal, así que el portal no podía mostrar quién
-- pidió los estudios. Esta migración agrega esa lectura, limitada a los médicos
-- de las órdenes del paciente que consulta.

CREATE POLICY "medicos: el paciente ve los de sus ordenes" ON public.medicos
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.ordenes o
      WHERE o.medico_id = medicos.id
        AND o.paciente_id = (SELECT privado.paciente_actual_id())
    )
  );
