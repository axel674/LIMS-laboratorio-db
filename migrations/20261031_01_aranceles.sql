-- Aranceles de los estudios por obra social (LIMS-32)
--
-- Los precios siguen el Nomenclador Bioquímico Único (NBU): cada estudio vale una
-- cantidad de unidades bioquímicas (UB) y cada obra social paga un valor por UB.
-- El particular tiene su propio valor de UB. Con obra social, el paciente paga un
-- coseguro (un % de lo que vale el estudio para esa obra social) y la obra social
-- el resto. Los estudios que la obra social no cubre (orden_analisis.cubierto =
-- false) se cobran a valor particular.
--
-- Cada valor de UB guarda desde qué fecha rige: al subir la UB se agrega un valor
-- nuevo y los anteriores quedan como historial. Cada estudio de una orden guarda
-- el precio que valía cuando se cargó, así un aumento no cambia las órdenes viejas.
--
-- Los valores que se cargan acá son DE EJEMPLO: hay que reemplazarlos por los
-- reales del laboratorio desde la pantalla de aranceles.
--
-- Depende de 20261029_04_componentes_y_llegada.sql.

-- 1. Unidades bioquímicas de cada estudio ──────

ALTER TABLE public.analisis
  ADD COLUMN ub numeric(6,2) CHECK (ub >= 0),
  ADD COLUMN codigo_nbu varchar(10);

COMMENT ON COLUMN public.analisis.ub IS
  'Unidades bioquímicas (NBU) que vale el estudio. Vacío: sin arancel. Los componentes (padre_id) no se cobran aparte';
COMMENT ON COLUMN public.analisis.codigo_nbu IS 'Código de la práctica en el Nomenclador Bioquímico Único';

-- 2. Valor de la UB por obra social ────────────

CREATE TABLE public.valores_ub (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- Vacío: valor particular (sin obra social)
  obra_social_id bigint REFERENCES public.obras_sociales (id),
  valor_ub numeric(12,2) NOT NULL CHECK (valor_ub > 0),
  -- Lo que paga el paciente con esta obra social, en % del valor del estudio
  coseguro_pct numeric(5,2) NOT NULL DEFAULT 0 CHECK (coseguro_pct BETWEEN 0 AND 100),
  vigente_desde date NOT NULL DEFAULT privado.hoy(),
  observaciones varchar(200),
  creado_por uuid DEFAULT auth.uid() REFERENCES public.perfiles (id),
  creado_en timestamptz NOT NULL DEFAULT now(),
  -- El particular paga todo: no tiene coseguro
  CONSTRAINT valores_ub_particular_sin_coseguro CHECK (obra_social_id IS NOT NULL OR coseguro_pct = 0),
  CONSTRAINT valores_ub_un_valor_por_dia UNIQUE NULLS NOT DISTINCT (obra_social_id, vigente_desde)
);

COMMENT ON TABLE public.valores_ub IS
  'Valor de la unidad bioquímica (UB) por obra social, con su coseguro y desde cuándo rige. obra_social_id vacío = particular';

ALTER TABLE public.valores_ub ENABLE ROW LEVEL SECURITY;

CREATE POLICY "valores_ub: lectura del personal" ON public.valores_ub
  FOR SELECT TO authenticated
  USING ((SELECT privado.es_personal()));

CREATE POLICY "valores_ub: admin gestiona" ON public.valores_ub
  FOR ALL TO authenticated
  USING ((SELECT privado.tiene_rol('admin')))
  WITH CHECK ((SELECT privado.tiene_rol('admin')));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.valores_ub TO authenticated;

-- Valor que rige en una fecha para una obra social (vacía = particular)
CREATE FUNCTION privado.valor_ub_vigente(p_obra_social_id bigint, p_fecha date)
RETURNS public.valores_ub
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT v.*
  FROM public.valores_ub v
  WHERE v.obra_social_id IS NOT DISTINCT FROM p_obra_social_id
    AND v.vigente_desde <= p_fecha
  ORDER BY v.vigente_desde DESC
  LIMIT 1;
$$;

-- 3. Precio de cada estudio de la orden ────────

ALTER TABLE public.orden_analisis
  ADD COLUMN ub numeric(6,2),
  ADD COLUMN valor_ub numeric(12,2),
  ADD COLUMN importe_obra_social numeric(12,2),
  ADD COLUMN importe_paciente numeric(12,2);

COMMENT ON COLUMN public.orden_analisis.importe_paciente IS
  'Lo que paga el paciente por el estudio (coseguro, o todo si es particular o no cubierto). Lo calcula la base al cargarlo';
COMMENT ON COLUMN public.orden_analisis.importe_obra_social IS
  'Lo que se le factura a la obra social por el estudio. Lo calcula la base al cargarlo';

-- Calcula el precio del estudio con los valores vigentes hoy. Los componentes
-- (ej: Neutrófilos) no se cobran aparte: se cobra su estudio (Fórmula leucocitaria).
-- Sin UB, o sin valor de UB para esa obra social, queda sin arancel (vacío).
CREATE FUNCTION privado.calcular_arancel()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_ub numeric;
  v_obra_social bigint;
  v_valor public.valores_ub;
  v_importe numeric;
BEGIN
  NEW.ub := NULL;
  NEW.valor_ub := NULL;
  NEW.importe_obra_social := NULL;
  NEW.importe_paciente := NULL;

  IF NEW.padre_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT ub INTO v_ub FROM public.analisis WHERE id = NEW.analisis_id;
  IF v_ub IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT obra_social_id INTO v_obra_social FROM public.ordenes WHERE id = NEW.orden_id;

  -- Con obra social y cubierto: el valor de esa obra social. Si no: el particular
  IF v_obra_social IS NOT NULL AND NEW.cubierto THEN
    v_valor := privado.valor_ub_vigente(v_obra_social, privado.hoy());
  ELSE
    v_valor := privado.valor_ub_vigente(NULL, privado.hoy());
  END IF;

  IF v_valor.id IS NULL THEN
    RETURN NEW;
  END IF;

  v_importe := round(v_ub * v_valor.valor_ub, 2);
  NEW.ub := v_ub;
  NEW.valor_ub := v_valor.valor_ub;
  IF v_valor.obra_social_id IS NULL THEN
    NEW.importe_paciente := v_importe;
    NEW.importe_obra_social := 0;
  ELSE
    NEW.importe_paciente := round(v_importe * v_valor.coseguro_pct / 100, 2);
    NEW.importe_obra_social := v_importe - NEW.importe_paciente;
  END IF;
  RETURN NEW;
END;
$$;

-- Los triggers corren por orden alfabético: "arancel" corre antes que "control"
CREATE TRIGGER orden_analisis_arancel
  BEFORE INSERT OR UPDATE OF analisis_id, cubierto, padre_id ON public.orden_analisis
  FOR EACH ROW EXECUTE FUNCTION privado.calcular_arancel();

-- Si cambia la obra social de una orden abierta, se recalculan sus precios
CREATE FUNCTION privado.recalcular_aranceles_orden()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NEW.estado = 'abierta' THEN
    UPDATE public.orden_analisis SET cubierto = cubierto WHERE orden_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER ordenes_aranceles
  AFTER UPDATE OF obra_social_id ON public.ordenes
  FOR EACH ROW
  WHEN (NEW.obra_social_id IS DISTINCT FROM OLD.obra_social_id)
  EXECUTE FUNCTION privado.recalcular_aranceles_orden();

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;

-- 4. Valores de ejemplo ────────────────────────

-- UB aproximadas, a confirmar con el laboratorio. Los índices del hemograma (VCM,
-- HCM, CHCM) se calculan con los otros valores: no se cobran aparte.
UPDATE public.analisis a
SET ub = v.ub
FROM (VALUES
  ('GR', 0.5), ('HB', 0.5), ('HTO', 0.5), ('VCM', 0), ('HCM', 0), ('CHCM', 0),
  ('GB', 0.5), ('FL', 1), ('PLAQ', 1), ('ERS', 1),
  ('GLU', 1.5), ('URE', 1.5), ('CREA', 1.5), ('URIC', 1.5),
  ('COL', 1.5), ('HDL', 2), ('LDL', 2), ('TG', 1.5),
  ('GOT', 2), ('GPT', 2), ('FAL', 2), ('BT', 1.5), ('BD', 1.5),
  ('TSH', 6), ('TP', 2), ('ORINA', 3), ('SOMF', 3)
) AS v (codigo, ub)
WHERE a.codigo = v.codigo;

-- Valor de la UB y coseguro de ejemplo, vigentes desde el 1/10/2026
INSERT INTO public.valores_ub (obra_social_id, valor_ub, coseguro_pct, vigente_desde, observaciones)
SELECT NULL::bigint, 1800, 0, DATE '2026-10-01', 'Valor de ejemplo: reemplazar por el real'
UNION ALL
SELECT os.id, v.valor, v.coseguro, DATE '2026-10-01', 'Valor de ejemplo: reemplazar por el real'
FROM (VALUES
  ('PAMI', 950, 0), ('OSDE', 1500, 10), ('Swiss Medical', 1500, 10), ('Galeno', 1400, 10),
  ('Medifé', 1300, 20), ('Sancor Salud', 1300, 20), ('OSECAC', 1100, 30), ('OSPRERA', 1100, 30),
  ('Unión Personal', 1200, 20), ('Subsidio de Salud', 1100, 20)
) AS v (nombre, valor, coseguro)
JOIN public.obras_sociales os ON os.nombre = v.nombre;

-- Precio de los estudios de las órdenes que ya están cargadas
UPDATE public.orden_analisis SET cubierto = cubierto;
