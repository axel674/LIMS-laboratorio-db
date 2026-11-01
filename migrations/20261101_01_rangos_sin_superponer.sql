-- Rangos de referencia por sexo y edad sin superponerse (LIMS-29)
--
-- Los rangos de analisis_rangos (LIMS-13) se cargan ahora desde el panel. Para
-- que siempre quede claro cuál se usa, dos rangos del mismo estudio y del mismo
-- sexo no pueden cubrir la misma edad. Un rango para "todos" (sexo vacío) sí
-- puede convivir con uno de un sexo: rango_de_estudio elige primero el que
-- tiene sexo.
--
-- La edad "hasta" no se incluye: 18 a 50 cubre de 18 a 49 años y "50 en
-- adelante" (hasta vacía) sigue desde ahí sin encimarse.
--
-- Depende de 20261029_03_resultados.sql.

CREATE FUNCTION privado.controlar_rango()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_otro public.analisis_rangos;
BEGIN
  SELECT * INTO v_otro
  FROM public.analisis_rangos r
  WHERE r.analisis_id = NEW.analisis_id
    AND r.id IS DISTINCT FROM NEW.id
    AND r.sexo IS NOT DISTINCT FROM NEW.sexo
    AND int4range(r.edad_desde, r.edad_hasta) && int4range(NEW.edad_desde, NEW.edad_hasta)
  LIMIT 1;

  IF v_otro.id IS NOT NULL THEN
    RAISE EXCEPTION 'Se superpone con el rango de % a %: ajuste las edades',
      v_otro.edad_desde,
      coalesce(v_otro.edad_hasta::text || ' años', 'más')
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER analisis_rangos_control
  BEFORE INSERT OR UPDATE ON public.analisis_rangos
  FOR EACH ROW EXECUTE FUNCTION privado.controlar_rango();

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA privado FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO authenticated;
