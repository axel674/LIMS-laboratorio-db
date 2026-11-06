-- Exportación de los valores de referencia para revisar con el bioquímico (LIMS-30)
--
-- Devuelve una fila por estudio y rango: el estudio, su muestra, su unidad, el
-- rango general del catálogo (el que se usa cuando no hay uno por sexo y edad) y
-- cada rango por sexo y edad. Los estudios que no tienen rangos propios salen
-- igual, con las columnas del rango en blanco. La fórmula leucocitaria suma sus
-- absolutos, que la base calcula con los glóbulos blancos de la orden; si el
-- rango por edad trae un absoluto propio (neutrófilos y linfocitos en los
-- chicos), se muestra ese y, si no, el general del catálogo.
--
-- Cómo se usa: Supabase → SQL Editor → pegar y Run → Download CSV. Ese archivo
-- es la foto real de la base; `rangos_referencia.csv` es la misma lista tal como
-- queda después de las migraciones, armada para abrir en Excel.
--
-- En la base la edad "hasta" no se incluye (18 a 50 = de 18 a 49 años). Acá se
-- muestra la última edad incluida, igual que en la pantalla de rangos.
-- Los números salen con punto decimal, como los guarda la base.

SELECT
  a.codigo AS "Código",
  a.nombre AS "Estudio",
  tm.nombre AS "Muestra",
  a.unidad AS "Unidad",
  a.valor_ref_min AS "General desde",
  a.valor_ref_max AS "General hasta",
  a.valor_ref_texto AS "General texto",
  -- Sexo vacío en un rango = vale para los dos ("Todos", como en la pantalla de rangos)
  CASE
    WHEN r.id IS NULL THEN NULL
    WHEN r.sexo IS NULL THEN 'Todos'
    WHEN r.sexo = 'F' THEN 'Femenino'
    WHEN r.sexo = 'M' THEN 'Masculino'
    ELSE 'X'
  END AS "Sexo",
  CASE
    WHEN r.id IS NULL THEN NULL
    WHEN r.edad_hasta IS NULL THEN r.edad_desde::text || ' años o más'
    WHEN r.edad_hasta - 1 = r.edad_desde THEN r.edad_desde::text || ' años'
    ELSE r.edad_desde::text || ' a ' || (r.edad_hasta - 1)::text || ' años'
  END AS "Edades",
  r.valor_min AS "Rango desde",
  r.valor_max AS "Rango hasta",
  a.absoluto_unidad AS "Absoluto unidad",
  coalesce(r.absoluto_min, a.absoluto_min) AS "Absoluto desde",
  coalesce(r.absoluto_max, a.absoluto_max) AS "Absoluto hasta"
FROM public.analisis a
JOIN public.tipos_muestra tm ON tm.id = a.tipo_muestra_id
LEFT JOIN public.analisis_rangos r ON r.analisis_id = a.id
WHERE a.activo
ORDER BY a.codigo, r.sexo NULLS FIRST, r.edad_desde, r.id;
