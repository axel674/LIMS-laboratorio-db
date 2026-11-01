-- Mensaje del rango que se superpone, con las edades como se leen en el panel (LIMS-29)
--
-- La edad "hasta" de la base no se incluye; el panel muestra la última edad
-- incluida: "18 años o más", "1 a 17 años". El aviso usa la misma forma.
--
-- Depende de 20261101_01_rangos_sin_superponer.sql.

CREATE OR REPLACE FUNCTION privado.controlar_rango()
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
    RAISE EXCEPTION 'Se superpone con el rango de %: ajuste las edades',
      CASE
        WHEN v_otro.edad_hasta IS NULL THEN v_otro.edad_desde || ' años o más'
        WHEN v_otro.edad_hasta - 1 = v_otro.edad_desde THEN v_otro.edad_desde || ' años'
        ELSE v_otro.edad_desde || ' a ' || (v_otro.edad_hasta - 1) || ' años'
      END
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;
