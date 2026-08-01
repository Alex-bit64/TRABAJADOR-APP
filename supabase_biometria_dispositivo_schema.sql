-- Ejecutar una vez en el SQL Editor de Supabase y luego volver a ejecutar
-- supabase_qr_asistencia_rpc.sql.
-- No guarda huellas ni rostros. Solo guarda un identificador aleatorio del
-- dispositivo y el hash de un secreto generado dentro de la instalacion.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

ALTER TABLE public.trabajador
    ADD COLUMN IF NOT EXISTS biometria_requerida BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS public.trabajador_dispositivo (
    dni_trabajador VARCHAR(20) PRIMARY KEY
        REFERENCES public.trabajador(dni) ON DELETE CASCADE,
    dispositivo_id UUID NOT NULL UNIQUE,
    secreto_hash BYTEA NOT NULL,
    plataforma TEXT,
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    vinculado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    ultima_validacion_en TIMESTAMPTZ
);

ALTER TABLE public.trabajador_dispositivo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.trabajador_dispositivo FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.dispositivo_trabajador_valido(
    p_dni TEXT,
    p_dispositivo_id UUID,
    p_dispositivo_secreto TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.trabajador_dispositivo d
        WHERE d.dni_trabajador = trim(p_dni)
          AND d.dispositivo_id = p_dispositivo_id
          AND d.activo = TRUE
          AND d.secreto_hash = digest(
              convert_to(p_dispositivo_secreto, 'UTF8'),
              'sha256'
          )
    );
$$;

REVOKE ALL ON FUNCTION public.dispositivo_trabajador_valido(TEXT, UUID, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.vincular_dispositivo_trabajador(
    p_identificador TEXT,
    p_contrasena TEXT,
    p_dispositivo_id UUID,
    p_dispositivo_secreto TEXT,
    p_plataforma TEXT DEFAULT ''
)
RETURNS TABLE (
    ok BOOLEAN,
    mensaje TEXT,
    dni_vinculado TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_identificador TEXT := trim(COALESCE(p_identificador, ''));
    v_dni TEXT;
    v_dni_dispositivo TEXT;
    v_dispositivo_trabajador UUID;
BEGIN
    IF v_identificador = ''
       OR COALESCE(p_contrasena, '') = ''
       OR p_dispositivo_id IS NULL
       OR length(COALESCE(p_dispositivo_secreto, '')) < 32 THEN
        RETURN QUERY SELECT FALSE, 'Datos incompletos para vincular el dispositivo.', NULL::TEXT;
        RETURN;
    END IF;

    SELECT t.dni::TEXT
    INTO v_dni
    FROM public.trabajador t
    WHERE t.estado = TRUE
      AND t.contrasena = p_contrasena
      AND (
          t.dni = v_identificador
          OR lower(trim(t.correo::TEXT)) = lower(v_identificador)
          OR t.csi = v_identificador
      )
    LIMIT 1;

    IF v_dni IS NULL THEN
        RETURN QUERY SELECT FALSE, 'No se pudieron validar las credenciales del trabajador.', NULL::TEXT;
        RETURN;
    END IF;

    SELECT d.dni_trabajador
    INTO v_dni_dispositivo
    FROM public.trabajador_dispositivo d
    WHERE d.dispositivo_id = p_dispositivo_id
      AND d.activo = TRUE
    LIMIT 1;

    IF v_dni_dispositivo IS NOT NULL AND v_dni_dispositivo <> v_dni THEN
        RETURN QUERY SELECT FALSE,
            'Este celular ya esta vinculado a otro trabajador. Solicita al administrador que lo libere.',
            v_dni;
        RETURN;
    END IF;

    SELECT d.dispositivo_id
    INTO v_dispositivo_trabajador
    FROM public.trabajador_dispositivo d
    WHERE d.dni_trabajador = v_dni
      AND d.activo = TRUE
    LIMIT 1;

    IF v_dispositivo_trabajador IS NOT NULL
       AND v_dispositivo_trabajador <> p_dispositivo_id THEN
        RETURN QUERY SELECT FALSE,
            'Tu usuario ya esta vinculado a otro celular. Solicita al administrador que libere el dispositivo anterior.',
            v_dni;
        RETURN;
    END IF;

    INSERT INTO public.trabajador_dispositivo (
        dni_trabajador,
        dispositivo_id,
        secreto_hash,
        plataforma,
        activo,
        vinculado_en,
        ultima_validacion_en
    ) VALUES (
        v_dni,
        p_dispositivo_id,
        digest(convert_to(p_dispositivo_secreto, 'UTF8'), 'sha256'),
        NULLIF(lower(trim(COALESCE(p_plataforma, ''))), ''),
        TRUE,
        now(),
        now()
    )
    ON CONFLICT (dni_trabajador) DO UPDATE
    SET
        secreto_hash = EXCLUDED.secreto_hash,
        plataforma = EXCLUDED.plataforma,
        activo = TRUE,
        ultima_validacion_en = now()
    WHERE trabajador_dispositivo.dispositivo_id = EXCLUDED.dispositivo_id;

    UPDATE public.trabajador
    SET biometria_requerida = TRUE
    WHERE dni = v_dni;

    RETURN QUERY SELECT TRUE, 'Dispositivo vinculado correctamente.', v_dni;
END;
$$;

REVOKE ALL ON FUNCTION public.vincular_dispositivo_trabajador(TEXT, TEXT, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.vincular_dispositivo_trabajador(TEXT, TEXT, UUID, TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.vincular_dispositivo_trabajador(TEXT, TEXT, UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.validar_dispositivo_trabajador(
    p_dni TEXT,
    p_dispositivo_id UUID,
    p_dispositivo_secreto TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_valido BOOLEAN;
BEGIN
    v_valido := public.dispositivo_trabajador_valido(
        p_dni,
        p_dispositivo_id,
        p_dispositivo_secreto
    );

    IF v_valido THEN
        UPDATE public.trabajador_dispositivo
        SET ultima_validacion_en = now()
        WHERE dni_trabajador = trim(p_dni)
          AND dispositivo_id = p_dispositivo_id;
    END IF;

    RETURN v_valido;
END;
$$;

REVOKE ALL ON FUNCTION public.validar_dispositivo_trabajador(TEXT, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validar_dispositivo_trabajador(TEXT, UUID, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.validar_dispositivo_trabajador(TEXT, UUID, TEXT) TO authenticated;

-- Para entregar un celular a otra persona, ejecutar como administrador:
-- DELETE FROM public.trabajador_dispositivo WHERE dni_trabajador = 'DNI';
-- UPDATE public.trabajador SET biometria_requerida = FALSE WHERE dni = 'DNI';

NOTIFY pgrst, 'reload schema';
