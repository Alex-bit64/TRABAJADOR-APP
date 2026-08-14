-- Ejecutar una vez en el SQL Editor de Supabase.
-- Guarda la version real instalada por cada trabajador sin exponer UPDATE
-- directo de la tabla al cliente anonimo.

ALTER TABLE public.trabajador
    ADD COLUMN IF NOT EXISTS app_version TEXT NOT NULL DEFAULT '1.0.0';

ALTER TABLE public.trabajador
    ADD COLUMN IF NOT EXISTS app_build_number TEXT NOT NULL DEFAULT '1';

ALTER TABLE public.trabajador
    ADD COLUMN IF NOT EXISTS app_platform TEXT;

ALTER TABLE public.trabajador
    ADD COLUMN IF NOT EXISTS app_version_actualizada_en TIMESTAMPTZ;

UPDATE public.trabajador
SET
    app_version = COALESCE(NULLIF(trim(app_version), ''), '1.0.0'),
    app_build_number = COALESCE(NULLIF(trim(app_build_number), ''), '1')
WHERE app_version IS NULL
   OR trim(app_version) = ''
   OR app_build_number IS NULL
   OR trim(app_build_number) = '';

CREATE OR REPLACE FUNCTION public.actualizar_version_trabajador(
    p_dni TEXT,
    p_version TEXT,
    p_build_number TEXT DEFAULT '',
    p_plataforma TEXT DEFAULT ''
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actualizados INTEGER := 0;
BEGIN
    IF NULLIF(trim(COALESCE(p_dni, '')), '') IS NULL
       OR NULLIF(trim(COALESCE(p_version, '')), '') IS NULL THEN
        RETURN FALSE;
    END IF;

    IF length(trim(p_version)) > 50
       OR length(trim(COALESCE(p_build_number, ''))) > 50
       OR length(trim(COALESCE(p_plataforma, ''))) > 30 THEN
        RETURN FALSE;
    END IF;

    UPDATE public.trabajador
    SET
        app_version = trim(p_version),
        app_build_number = COALESCE(
            NULLIF(trim(COALESCE(p_build_number, '')), ''),
            app_build_number
        ),
        app_platform = COALESCE(
            NULLIF(lower(trim(COALESCE(p_plataforma, ''))), ''),
            app_platform
        ),
        app_version_actualizada_en = now()
    WHERE dni = trim(p_dni)
      AND estado IS DISTINCT FROM FALSE;

    GET DIAGNOSTICS v_actualizados = ROW_COUNT;
    RETURN v_actualizados = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.actualizar_version_trabajador(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.actualizar_version_trabajador(TEXT, TEXT, TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.actualizar_version_trabajador(TEXT, TEXT, TEXT, TEXT) TO authenticated;
