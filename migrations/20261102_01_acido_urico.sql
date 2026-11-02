-- Ácido úrico en el catálogo (LIMS-30)
--
-- El ácido úrico (URIC) se cargó en Supabase desde el panel y ninguna migración
-- lo crea. 20261029_02 lo suma al grupo Sangre completa, 20261029_03 le carga
-- sus rangos por sexo y edad y 20261031_01 sus UB, pero las tres buscan el
-- estudio por código: en una base armada solo con las migraciones no existe y
-- esas filas se saltean sin error.
--
-- Esta migración lo da de alta con los mismos datos que tiene en Supabase y
-- completa lo que le falte. En Supabase, donde ya existe, no cambia nada.

INSERT INTO public.analisis (codigo, nombre, tipo_muestra_id, unidad, valor_ref_min, valor_ref_max, dias_demora, ub)
SELECT 'URIC', 'Ácido úrico', t.id, 'mg/dL', 2.5, 7, 1, 1.5
FROM public.tipos_muestra t
WHERE t.nombre = 'Suero'
ON CONFLICT (codigo) DO NOTHING;

-- En el grupo Sangre completa, en el mismo lugar que en Supabase
INSERT INTO public.grupo_analisis_items (grupo_id, analisis_id, orden)
SELECT g.id, a.id, 14
FROM public.grupos_analisis g
JOIN public.analisis a ON a.codigo = 'URIC'
WHERE g.codigo = 'SANGRE'
ON CONFLICT (grupo_id, analisis_id) DO NOTHING;

-- Rangos por sexo y edad, solo si el estudio todavía no tiene ninguno
INSERT INTO public.analisis_rangos (analisis_id, sexo, edad_desde, edad_hasta, valor_min, valor_max)
SELECT a.id, r.sexo::public.sexo, r.desde, r.hasta, r.minimo, r.maximo
FROM (VALUES
  (NULL, 1,  18,   2.0, 5.5),
  ('M',  18, NULL, 3.4, 7.0),
  ('F',  18, NULL, 2.4, 6.0)
) AS r (sexo, desde, hasta, minimo, maximo)
JOIN public.analisis a ON a.codigo = 'URIC'
WHERE NOT EXISTS (SELECT 1 FROM public.analisis_rangos x WHERE x.analisis_id = a.id);
