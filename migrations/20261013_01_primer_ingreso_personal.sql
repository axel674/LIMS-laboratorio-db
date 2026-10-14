-- Primer ingreso del personal
--
-- Cuando un administrador da de alta a una persona del personal (Edge Function
-- crear-personal), la cuenta nace con una contraseña provisoria y
-- perfiles.debe_cambiar_password = true. En su primer ingreso la persona elige
-- una contraseña propia (Supabase Auth) y esta función baja ese indicador.
--
-- Es el equivalente de completar_primer_ingreso(p_email), que solo sirve para
-- pacientes. Una persona del personal no puede modificar su propio perfil por RLS
-- (solo el admin), por eso el cambio se hace con SECURITY DEFINER y toca únicamente
-- el indicador de quien llama.

CREATE OR REPLACE FUNCTION public.completar_primer_ingreso_personal()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NOT privado.es_personal() THEN
    RAISE EXCEPTION 'Solo el personal del laboratorio puede completar este primer ingreso';
  END IF;

  UPDATE public.perfiles SET debe_cambiar_password = false WHERE id = auth.uid();
END;
$$;

REVOKE EXECUTE ON FUNCTION public.completar_primer_ingreso_personal() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.completar_primer_ingreso_personal() TO authenticated;
