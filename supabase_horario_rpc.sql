CREATE OR REPLACE FUNCTION public.obtener_horario_trabajador(
    p_dni TEXT,
    p_dia_semana TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_horario UUID,
    dni_trabajador VARCHAR(20),
    dia_semana TEXT,
    horario_entrada TIME,
    horario_inicio_receso TIME,
    horario_fin_receso TIME,
    horario_salida TIME
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        h.id_horario,
        h.dni_trabajador,
        h.dia_semana::TEXT,
        h.horario_entrada,
        h.horario_inicio_receso,
        h.horario_fin_receso,
        h.horario_salida
    FROM public.horario_trabajador h
    WHERE h.dni_trabajador = p_dni
      AND (
          p_dia_semana IS NULL
          OR h.dia_semana::TEXT = p_dia_semana
      )
    ORDER BY
      CASE h.dia_semana::TEXT
        WHEN 'lunes' THEN 1
        WHEN 'martes' THEN 2
        WHEN 'miercoles' THEN 3
        WHEN 'jueves' THEN 4
        WHEN 'viernes' THEN 5
        WHEN 'sabado' THEN 6
        WHEN 'domingo' THEN 7
        ELSE 8
      END;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_horario_trabajador(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_horario_trabajador(TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.obtener_horario_trabajador(TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
