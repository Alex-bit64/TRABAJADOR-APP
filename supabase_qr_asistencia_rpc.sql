DROP FUNCTION IF EXISTS public.normalizar_token_qr(TEXT);
DROP FUNCTION IF EXISTS public.buscar_qr_por_token(TEXT);
DROP FUNCTION IF EXISTS public.payload_qr_valido_tienda(TEXT, UUID);
DROP FUNCTION IF EXISTS public.generar_payload_qr_tienda(TEXT, BIGINT);
DROP FUNCTION IF EXISTS public.registrar_marcacion_asistencia_qr(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.registrar_marcacion_asistencia_qr(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION);
DROP FUNCTION IF EXISTS public.registrar_marcacion_asistencia(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.registrar_marcacion_asistencia(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION);
DROP FUNCTION IF EXISTS public.registrar_marcacion_asistencia(VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS public.registrar_marcacion_asistencia(TEXT, VARCHAR);
DROP FUNCTION IF EXISTS public.registrar_marcacion_asistencia(VARCHAR, TEXT);
DROP FUNCTION IF EXISTS public.registrar_marcacion_asistencia(TEXT, TIMESTAMPTZ, TEXT);
DROP FUNCTION IF EXISTS public.registrar_marcacion_asistencia(TEXT, TIMESTAMP WITH TIME ZONE, TEXT);
DROP FUNCTION IF EXISTS public.debug_qr_token(TEXT);
DROP FUNCTION IF EXISTS public.debug_marcacion_qr(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.obtener_asistencia_hoy(TEXT, DATE);
DROP FUNCTION IF EXISTS public.obtener_historial_asistencias_mes(TEXT, INT, INT);

ALTER TABLE public.asistencia
    ALTER COLUMN horario_entrada TYPE TIMESTAMPTZ(0) USING date_trunc('second', horario_entrada),
    ALTER COLUMN horario_inicio_receso TYPE TIMESTAMPTZ(0) USING date_trunc('second', horario_inicio_receso),
    ALTER COLUMN horario_fin_receso TYPE TIMESTAMPTZ(0) USING date_trunc('second', horario_fin_receso),
    ALTER COLUMN horario_salida TYPE TIMESTAMPTZ(0) USING date_trunc('second', horario_salida);

ALTER TABLE public.asistencia
    ADD COLUMN IF NOT EXISTS ubicaciones JSONB NOT NULL DEFAULT '{}'::JSONB;

ALTER TABLE public.asistencia
    ADD COLUMN IF NOT EXISTS justificado BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.asistencia
    DROP COLUMN IF EXISTS latitud_entrada,
    DROP COLUMN IF EXISTS longitud_entrada,
    DROP COLUMN IF EXISTS latitud_inicio_receso,
    DROP COLUMN IF EXISTS longitud_inicio_receso,
    DROP COLUMN IF EXISTS latitud_fin_receso,
    DROP COLUMN IF EXISTS longitud_fin_receso,
    DROP COLUMN IF EXISTS latitud_salida,
    DROP COLUMN IF EXISTS longitud_salida;

CREATE OR REPLACE FUNCTION public.normalizar_token_qr(
    p_raw TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_raw TEXT := trim(COALESCE(p_raw, ''));
    v_json JSONB;
    v_token TEXT;
BEGIN
    IF v_raw = '' THEN
        RETURN '';
    END IF;

    IF v_raw LIKE 'app-qr-dinamico://%' THEN
        RETURN v_raw;
    END IF;

    BEGIN
        v_json := v_raw::JSONB;

        IF jsonb_typeof(v_json) = 'array' AND jsonb_array_length(v_json) > 0 THEN
            v_json := v_json -> 0;
        END IF;

        IF jsonb_typeof(v_json) = 'object' THEN
            v_token := COALESCE(
                v_json ->> 'token',
                v_json ->> 'qr_token',
                v_json ->> 'codigo',
                v_json ->> 'code',
                v_json ->> 'value'
            );
            IF v_token IS NOT NULL AND trim(v_token) <> '' THEN
                v_raw := trim(v_token);
            END IF;
        ELSIF jsonb_typeof(v_json) = 'string' THEN
            v_raw := trim(v_json #>> '{}');
        END IF;
    EXCEPTION WHEN others THEN
        NULL;
    END;

    IF v_raw LIKE 'app-qr-dinamico://%' THEN
        RETURN v_raw;
    END IF;

    v_token := substring(v_raw from '(?:token|qr|code)=([^&?#[:space:]]+)');
    IF v_token IS NOT NULL AND trim(v_token) <> '' THEN
        v_raw := trim(v_token);
    END IF;

    v_token := substring(v_raw from '([0-9a-fA-F]{32,})');
    IF v_token IS NOT NULL AND trim(v_token) <> '' THEN
        v_raw := trim(v_token);
    END IF;

    RETURN trim(BOTH '"' FROM trim(v_raw));
END;
$$;

REVOKE ALL ON FUNCTION public.normalizar_token_qr(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.normalizar_token_qr(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.normalizar_token_qr(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.buscar_qr_por_token(
    p_token TEXT
)
RETURNS TABLE (
    id UUID,
    id_tienda UUID,
    token VARCHAR(512),
    fecha_creada TIMESTAMPTZ,
    nombre_tienda VARCHAR(150),
    direccion VARCHAR(255)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_token TEXT := public.normalizar_token_qr(p_token);
BEGIN
    RETURN QUERY
    SELECT
        q.id,
        q.id_tienda,
        q.token,
        q.fecha_creada,
        COALESCE(t.nombre, 'Tienda') AS nombre_tienda,
        COALESCE(t.direccion, '') AS direccion
    FROM public.qr q
    LEFT JOIN public.tienda t ON t.id_tienda = q.id_tienda
    WHERE trim(q.token::TEXT) = v_token
    LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.buscar_qr_por_token(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.buscar_qr_por_token(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.buscar_qr_por_token(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.generar_payload_qr_tienda(
    p_token TEXT,
    p_slot BIGINT DEFAULT NULL
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_slot BIGINT := COALESCE(p_slot, floor(extract(epoch FROM NOW()) / 30)::BIGINT);
    v_firma TEXT;
BEGIN
    v_firma := md5(trim(p_token) || ':' || v_slot::TEXT || ':qr_dinamico:v2');
    RETURN 'app-qr-dinamico://' || v_slot::TEXT || '/' || v_firma;
END;
$$;

REVOKE ALL ON FUNCTION public.generar_payload_qr_tienda(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generar_payload_qr_tienda(TEXT, BIGINT) TO anon;
GRANT EXECUTE ON FUNCTION public.generar_payload_qr_tienda(TEXT, BIGINT) TO authenticated;

CREATE OR REPLACE FUNCTION public.payload_qr_valido_tienda(
    p_payload TEXT,
    p_id_tienda UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_payload TEXT := trim(COALESCE(p_payload, ''));
    v_slot_actual BIGINT := floor(extract(epoch FROM NOW()) / 30)::BIGINT;
    v_slot BIGINT;
BEGIN
    FOR v_slot IN (v_slot_actual - 2)..(v_slot_actual + 2) LOOP
        IF EXISTS (
            SELECT 1
            FROM public.qr q
            INNER JOIN public.tienda t ON t.id_tienda = q.id_tienda
            WHERE q.id_tienda = p_id_tienda
              AND t.estado = TRUE
              AND v_payload = public.generar_payload_qr_tienda(q.token, v_slot)
        ) THEN
            RETURN TRUE;
        END IF;
    END LOOP;

    RETURN FALSE;
END;
$$;

REVOKE ALL ON FUNCTION public.payload_qr_valido_tienda(TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.payload_qr_valido_tienda(TEXT, UUID) TO anon;
GRANT EXECUTE ON FUNCTION public.payload_qr_valido_tienda(TEXT, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.registrar_marcacion_asistencia(
    p_dni TEXT,
    p_token TEXT,
    p_latitud DOUBLE PRECISION DEFAULT NULL,
    p_longitud DOUBLE PRECISION DEFAULT NULL
)
RETURNS TABLE (
    ok BOOLEAN,
    mensaje TEXT,
    tipo_marcacion TEXT,
    id_asistencia UUID,
    fecha_asistencia DATE,
    horario_entrada TIMESTAMPTZ,
    horario_inicio_receso TIMESTAMPTZ,
    horario_fin_receso TIMESTAMPTZ,
    horario_salida TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_fecha DATE := (now() AT TIME ZONE 'America/Lima')::DATE;
    v_token TEXT := public.normalizar_token_qr(p_token);
    v_asistencia public.asistencia%ROWTYPE;
    v_ultima TIMESTAMPTZ;
    v_restante INTERVAL;
    v_minutos INTEGER;
    v_tipo TEXT;
    v_ahora TIMESTAMPTZ := date_trunc('second', now());
    v_trabajador_activo BOOLEAN := FALSE;
    v_dia_semana TEXT;
    v_tiene_receso BOOLEAN := TRUE;
    v_tiene_horario BOOLEAN := FALSE;
    v_justificado BOOLEAN := FALSE;
BEGIN
    IF p_dni IS NULL OR trim(p_dni) = '' THEN
        RETURN QUERY SELECT FALSE, 'Falta el DNI del trabajador para registrar asistencia.', NULL::TEXT,
            NULL::UUID, v_fecha AS fecha_asistencia, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    SELECT t.estado
    INTO v_trabajador_activo
    FROM public.trabajador t
    WHERE t.dni = trim(p_dni)
    LIMIT 1;

    IF v_trabajador_activo IS DISTINCT FROM TRUE THEN
        RETURN QUERY SELECT FALSE, 'Trabajador no encontrado o inactivo.', NULL::TEXT,
            NULL::UUID, v_fecha AS fecha_asistencia, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.qr q
        INNER JOIN public.tienda ti ON ti.id_tienda = q.id_tienda
        WHERE ti.estado = TRUE
          AND (
              trim(q.token::TEXT) = v_token
              OR public.payload_qr_valido_tienda(v_token, q.id_tienda)
          )
    ) THEN
        RETURN QUERY SELECT FALSE, 'QR invalido, vencido o no pertenece a una tienda activa.', NULL::TEXT,
            NULL::UUID, v_fecha AS fecha_asistencia, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    v_dia_semana := CASE extract(isodow FROM v_fecha)::INT
        WHEN 1 THEN 'lunes'
        WHEN 2 THEN 'martes'
        WHEN 3 THEN 'miercoles'
        WHEN 4 THEN 'jueves'
        WHEN 5 THEN 'viernes'
        WHEN 6 THEN 'sabado'
        WHEN 7 THEN 'domingo'
    END;

    SELECT
        TRUE,
        NOT (
            h.horario_inicio_receso IS NULL
            AND h.horario_fin_receso IS NULL
        )
    INTO
        v_tiene_horario,
        v_tiene_receso
    FROM public.horario_trabajador h
    WHERE h.dni_trabajador = trim(p_dni)
      AND h.dia_semana::TEXT = v_dia_semana
    LIMIT 1;

    v_tiene_horario := COALESCE(v_tiene_horario, FALSE);
    v_tiene_receso := COALESCE(v_tiene_receso, TRUE);
    v_justificado := v_tiene_horario;

    SELECT *
    INTO v_asistencia
    FROM public.asistencia a
    WHERE a.dni_trabajador = trim(p_dni)
      AND a.fecha = v_fecha
    LIMIT 1;

    IF v_asistencia.id_asistencia IS NULL THEN
        INSERT INTO public.asistencia (
            dni_trabajador,
            fecha,
            horario_entrada,
            horario_inicio_receso,
            horario_fin_receso,
            horario_salida,
            justificado
        )
        VALUES (
            trim(p_dni),
            v_fecha,
            NULL,
            NULL,
            NULL,
            NULL,
            v_justificado
        )
        RETURNING *
        INTO v_asistencia;
    END IF;

    SELECT MAX(marca)
    INTO v_ultima
    FROM (
        VALUES
            (v_asistencia.horario_entrada),
            (v_asistencia.horario_inicio_receso),
            (v_asistencia.horario_fin_receso),
            (v_asistencia.horario_salida)
    ) AS marcas(marca);

    IF v_ultima IS NOT NULL THEN
        v_restante := INTERVAL '10 minutes' - (v_ahora - v_ultima);
        IF v_restante > INTERVAL '0 seconds' THEN
            v_minutos := CEIL(EXTRACT(EPOCH FROM v_restante) / 60.0)::INTEGER;
            RETURN QUERY SELECT FALSE, 'Debes esperar ' || v_minutos || ' minutos antes de volver a marcar',
                NULL::TEXT,
                v_asistencia.id_asistencia,
                v_asistencia.fecha AS fecha_asistencia,
                v_asistencia.horario_entrada,
                v_asistencia.horario_inicio_receso,
                v_asistencia.horario_fin_receso,
                v_asistencia.horario_salida;
            RETURN;
        END IF;
    END IF;

    IF v_asistencia.horario_entrada IS NULL THEN
        v_tipo := 'horario_entrada';
        UPDATE public.asistencia
        SET
            horario_entrada = v_ahora,
            justificado = v_justificado,
            ubicaciones = jsonb_set(
                COALESCE(ubicaciones, '{}'::JSONB),
                '{horario_entrada}',
                jsonb_build_object('latitud', p_latitud, 'longitud', p_longitud),
                TRUE
            )
        WHERE asistencia.id_asistencia = v_asistencia.id_asistencia;
    ELSIF v_tiene_receso AND v_asistencia.horario_inicio_receso IS NULL THEN
        v_tipo := 'horario_inicio_receso';
        UPDATE public.asistencia
        SET
            horario_inicio_receso = v_ahora,
            justificado = v_justificado,
            ubicaciones = jsonb_set(
                COALESCE(ubicaciones, '{}'::JSONB),
                '{horario_inicio_receso}',
                jsonb_build_object('latitud', p_latitud, 'longitud', p_longitud),
                TRUE
            )
        WHERE asistencia.id_asistencia = v_asistencia.id_asistencia;
    ELSIF v_tiene_receso AND v_asistencia.horario_fin_receso IS NULL THEN
        v_tipo := 'horario_fin_receso';
        UPDATE public.asistencia
        SET
            horario_fin_receso = v_ahora,
            justificado = v_justificado,
            ubicaciones = jsonb_set(
                COALESCE(ubicaciones, '{}'::JSONB),
                '{horario_fin_receso}',
                jsonb_build_object('latitud', p_latitud, 'longitud', p_longitud),
                TRUE
            )
        WHERE asistencia.id_asistencia = v_asistencia.id_asistencia;
    ELSIF v_asistencia.horario_salida IS NULL THEN
        v_tipo := 'horario_salida';
        UPDATE public.asistencia
        SET
            horario_salida = v_ahora,
            justificado = v_justificado,
            ubicaciones = jsonb_set(
                COALESCE(ubicaciones, '{}'::JSONB),
                '{horario_salida}',
                jsonb_build_object('latitud', p_latitud, 'longitud', p_longitud),
                TRUE
            )
        WHERE asistencia.id_asistencia = v_asistencia.id_asistencia;
    ELSE
        RETURN QUERY SELECT FALSE, 'Ya completaste todas las marcaciones de hoy',
            NULL::TEXT,
            v_asistencia.id_asistencia,
            v_asistencia.fecha AS fecha_asistencia,
            v_asistencia.horario_entrada,
            v_asistencia.horario_inicio_receso,
            v_asistencia.horario_fin_receso,
            v_asistencia.horario_salida;
        RETURN;
    END IF;

    SELECT *
    INTO v_asistencia
    FROM public.asistencia a
    WHERE a.id_asistencia = v_asistencia.id_asistencia;

    RETURN QUERY SELECT TRUE,
        CASE v_tipo
            WHEN 'horario_entrada' THEN 'Entrada'
            WHEN 'horario_inicio_receso' THEN 'Inicio de receso'
            WHEN 'horario_fin_receso' THEN 'Fin de receso'
            WHEN 'horario_salida' THEN 'Salida'
            ELSE v_tipo
        END,
        v_tipo,
        v_asistencia.id_asistencia,
        v_asistencia.fecha AS fecha_asistencia,
        v_asistencia.horario_entrada,
        v_asistencia.horario_inicio_receso,
        v_asistencia.horario_fin_receso,
        v_asistencia.horario_salida;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_marcacion_asistencia(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_marcacion_asistencia(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO anon;
GRANT EXECUTE ON FUNCTION public.registrar_marcacion_asistencia(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;

CREATE OR REPLACE FUNCTION public.registrar_marcacion_asistencia_qr(
    p_dni TEXT,
    p_token TEXT,
    p_latitud DOUBLE PRECISION DEFAULT NULL,
    p_longitud DOUBLE PRECISION DEFAULT NULL
)
RETURNS TABLE (
    ok BOOLEAN,
    mensaje TEXT,
    tipo_marcacion TEXT,
    id_asistencia UUID,
    fecha_asistencia DATE,
    horario_entrada TIMESTAMPTZ,
    horario_inicio_receso TIMESTAMPTZ,
    horario_fin_receso TIMESTAMPTZ,
    horario_salida TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT *
    FROM public.registrar_marcacion_asistencia(p_dni, p_token, p_latitud, p_longitud);
$$;

REVOKE ALL ON FUNCTION public.registrar_marcacion_asistencia_qr(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_marcacion_asistencia_qr(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO anon;
GRANT EXECUTE ON FUNCTION public.registrar_marcacion_asistencia_qr(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;

CREATE OR REPLACE FUNCTION public.debug_qr_token(
    p_token TEXT
)
RETURNS TABLE (
    token_recibido TEXT,
    token_normalizado TEXT,
    encontrado BOOLEAN,
    total_qr BIGINT,
    token_encontrado TEXT,
    id_tienda UUID,
    usado BOOLEAN,
    session_id TEXT,
    usado_expira_en TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_token TEXT := public.normalizar_token_qr(p_token);
BEGIN
    RETURN QUERY
    SELECT
        p_token,
        v_token,
        q.id IS NOT NULL OR EXISTS (
            SELECT 1
            FROM public.qr q2
            INNER JOIN public.tienda ti2 ON ti2.id_tienda = q2.id_tienda
            WHERE ti2.estado = TRUE
              AND public.payload_qr_valido_tienda(v_token, q2.id_tienda)
        ),
        (SELECT COUNT(*) FROM public.qr),
        q.token::TEXT,
        q.id_tienda,
        CASE WHEN to_jsonb(q) ? 'usado' THEN (to_jsonb(q) ->> 'usado')::BOOLEAN ELSE NULL END,
        CASE WHEN to_jsonb(q) ? 'session_id' THEN to_jsonb(q) ->> 'session_id' ELSE NULL END,
        CASE
            WHEN to_jsonb(q) ? 'usado_expira_en'
            THEN (to_jsonb(q) ->> 'usado_expira_en')::TIMESTAMPTZ
            ELSE NULL
        END
    FROM (SELECT 1) s
    LEFT JOIN public.qr q ON trim(q.token::TEXT) = v_token
    LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.debug_qr_token(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.debug_qr_token(TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.debug_qr_token(TEXT) FROM authenticated;

CREATE OR REPLACE FUNCTION public.debug_marcacion_qr(
    p_dni TEXT,
    p_token TEXT
)
RETURNS TABLE (
    dni_normalizado TEXT,
    token_normalizado TEXT,
    id_tienda_qr UUID,
    trabajador_activo BOOLEAN,
    qr_plano_valido BOOLEAN,
    qr_dinamico_valido BOOLEAN,
    slot_supabase BIGINT,
    mensaje TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_dni TEXT := trim(COALESCE(p_dni, ''));
    v_token TEXT := public.normalizar_token_qr(p_token);
    v_id_tienda_qr UUID;
    v_activo BOOLEAN := FALSE;
    v_qr_plano BOOLEAN := FALSE;
    v_qr_dinamico BOOLEAN := FALSE;
BEGIN
    SELECT t.estado
    INTO v_activo
    FROM public.trabajador t
    WHERE t.dni = v_dni
    LIMIT 1;

    SELECT EXISTS (
        SELECT 1
        FROM public.qr q
        INNER JOIN public.tienda ti ON ti.id_tienda = q.id_tienda
        WHERE ti.estado = TRUE
          AND trim(q.token::TEXT) = v_token
    )
    INTO v_qr_plano;

    SELECT EXISTS (
        SELECT 1
        FROM public.qr q
        INNER JOIN public.tienda ti ON ti.id_tienda = q.id_tienda
        WHERE ti.estado = TRUE
          AND public.payload_qr_valido_tienda(v_token, q.id_tienda)
    )
    INTO v_qr_dinamico;

    SELECT q.id_tienda
    INTO v_id_tienda_qr
    FROM public.qr q
    INNER JOIN public.tienda ti ON ti.id_tienda = q.id_tienda
    WHERE ti.estado = TRUE
      AND (
          trim(q.token::TEXT) = v_token
          OR public.payload_qr_valido_tienda(v_token, q.id_tienda)
      )
    ORDER BY q.fecha_creada DESC
    LIMIT 1;

    RETURN QUERY
    SELECT
        v_dni,
        v_token,
        v_id_tienda_qr,
        COALESCE(v_activo, FALSE),
        v_qr_plano,
        v_qr_dinamico,
        floor(extract(epoch FROM NOW()) / 30)::BIGINT,
        CASE
            WHEN v_dni = '' THEN 'DNI vacio.'
            WHEN NOT EXISTS (SELECT 1 FROM public.trabajador t WHERE t.dni = v_dni) THEN 'Trabajador no encontrado.'
            WHEN COALESCE(v_activo, FALSE) = FALSE THEN 'Trabajador inactivo.'
            WHEN v_qr_plano OR v_qr_dinamico THEN 'QR valido para marcar.'
            ELSE 'QR vencido, token cacheado, tienda inactiva o reloj desfasado.'
        END;
END;
$$;

REVOKE ALL ON FUNCTION public.debug_marcacion_qr(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.debug_marcacion_qr(TEXT, TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.debug_marcacion_qr(TEXT, TEXT) FROM authenticated;

CREATE OR REPLACE FUNCTION public.obtener_asistencia_hoy(
    p_dni TEXT,
    p_fecha DATE DEFAULT NULL
)
RETURNS TABLE (
    id_asistencia UUID,
    dni_trabajador VARCHAR,
    fecha DATE,
    horario_entrada TIMESTAMPTZ,
    horario_inicio_receso TIMESTAMPTZ,
    horario_fin_receso TIMESTAMPTZ,
    horario_salida TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_fecha DATE := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Lima')::DATE);
BEGIN
    RETURN QUERY
    SELECT
        a.id_asistencia,
        a.dni_trabajador,
        a.fecha,
        a.horario_entrada,
        a.horario_inicio_receso,
        a.horario_fin_receso,
        a.horario_salida
    FROM public.asistencia a
    WHERE a.dni_trabajador = trim(p_dni)
      AND a.fecha = v_fecha
    LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_asistencia_hoy(TEXT, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_asistencia_hoy(TEXT, DATE) TO anon;
GRANT EXECUTE ON FUNCTION public.obtener_asistencia_hoy(TEXT, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION public.obtener_historial_asistencias_mes(
    p_dni TEXT,
    p_year INT,
    p_month INT
)
RETURNS TABLE (
    id_asistencia UUID,
    dni_trabajador VARCHAR,
    fecha DATE,
    horario_entrada TIMESTAMPTZ,
    horario_inicio_receso TIMESTAMPTZ,
    horario_fin_receso TIMESTAMPTZ,
    horario_salida TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inicio_mes DATE;
    v_fin_mes DATE;
BEGIN
    v_inicio_mes := make_date(p_year, p_month, 1);
    v_fin_mes := (v_inicio_mes + INTERVAL '1 month' - INTERVAL '1 day')::DATE;

    RETURN QUERY
    SELECT
        a.id_asistencia,
        a.dni_trabajador,
        a.fecha,
        a.horario_entrada,
        a.horario_inicio_receso,
        a.horario_fin_receso,
        a.horario_salida
    FROM public.asistencia a
    WHERE a.dni_trabajador = trim(p_dni)
      AND a.fecha >= v_inicio_mes
      AND a.fecha <= v_fin_mes
    ORDER BY a.fecha DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.obtener_historial_asistencias_mes(TEXT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_historial_asistencias_mes(TEXT, INT, INT) TO anon;
GRANT EXECUTE ON FUNCTION public.obtener_historial_asistencias_mes(TEXT, INT, INT) TO authenticated;

NOTIFY pgrst, 'reload schema';
