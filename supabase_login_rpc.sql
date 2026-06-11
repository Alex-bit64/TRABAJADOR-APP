DROP FUNCTION IF EXISTS public.login_trabajador(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.login_trabajador(
    p_identificador TEXT,
    p_contrasena TEXT
)
RETURNS TABLE (
    dni VARCHAR(20),
    id_tienda UUID,
    correo VARCHAR(150),
    nombre VARCHAR(150),
    cargo VARCHAR(100),
    sueldo NUMERIC(10,2),
    telefono VARCHAR(20),
    csi VARCHAR(50),
    foto_dni VARCHAR(500),
    estado BOOLEAN,
    nombre_tienda VARCHAR(150),
    direccion_tienda VARCHAR(255)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_identificador TEXT := trim(COALESCE(p_identificador, ''));
BEGIN
    RETURN QUERY
    SELECT
        t.dni,
        t.id_tienda,
        t.correo,
        t.nombre,
        t.cargo,
        t.sueldo,
        t.telefono,
        t.csi,
        t.foto_dni,
        t.estado,
        ti.nombre AS nombre_tienda,
        ti.direccion AS direccion_tienda
    FROM public.trabajador t
    LEFT JOIN public.tienda ti ON ti.id_tienda = t.id_tienda
    WHERE t.estado = TRUE
      AND t.contrasena = p_contrasena
      AND (
          t.dni = v_identificador
          OR lower(trim(t.correo::TEXT)) = lower(v_identificador)
          OR t.csi = v_identificador
      )
    LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.login_trabajador(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.login_trabajador(TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.login_trabajador(TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
