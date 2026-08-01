-- Nueva base para alertas de puntualidad.
-- La configuracion sigue indicando a quien y cuando se envia.
-- El log ahora guarda 1 fila por correo resumen, no 1 fila por trabajador.

CREATE TABLE IF NOT EXISTS public.alerta_puntualidad_config (
    id_config UUID NOT NULL DEFAULT gen_random_uuid(),
    id_tienda UUID NULL,
    correo_destino TEXT NOT NULL,
    minutos_tolerancia INTEGER NOT NULL DEFAULT 10,
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    tipo_reporte TEXT NOT NULL DEFAULT 'TIENDA',
    nombre_reporte TEXT NOT NULL DEFAULT 'Reporte',
    hora_envio TIME NOT NULL,
    ventana_minutos INTEGER NOT NULL DEFAULT 5,
    CONSTRAINT alerta_puntualidad_config_pkey PRIMARY KEY (id_config),
    CONSTRAINT alerta_puntualidad_config_tipo_reporte_check
        CHECK (tipo_reporte IN ('TIENDA', 'GENERAL')),
    CONSTRAINT alerta_puntualidad_config_tienda_requerida_check
        CHECK (
            (tipo_reporte = 'GENERAL' AND id_tienda IS NULL)
            OR (tipo_reporte = 'TIENDA' AND id_tienda IS NOT NULL)
        ),
    CONSTRAINT alerta_puntualidad_config_ventana_check
        CHECK (ventana_minutos BETWEEN 1 AND 60),
    CONSTRAINT alerta_puntualidad_config_tolerancia_check
        CHECK (minutos_tolerancia >= 0)
);

CREATE INDEX IF NOT EXISTS idx_alerta_config_activa_hora
    ON public.alerta_puntualidad_config(hora_envio)
    WHERE activo = TRUE;

CREATE UNIQUE INDEX IF NOT EXISTS uq_alerta_config_unica
    ON public.alerta_puntualidad_config(
        COALESCE(id_tienda, '00000000-0000-0000-0000-000000000000'::UUID),
        lower(trim(correo_destino)),
        tipo_reporte,
        hora_envio
    );

-- Si ya existe el log viejo por trabajador, lo eliminamos para partir con
-- el modelo nuevo. Si quieres conservarlo, renombralo antes de ejecutar esto.
DROP TABLE IF EXISTS public.alerta_puntualidad_log;

CREATE TABLE public.alerta_puntualidad_log (
    id_log UUID NOT NULL DEFAULT gen_random_uuid(),
    id_config UUID NULL,
    id_tienda UUID NULL,
    fecha DATE NOT NULL,
    tipo_reporte TEXT NOT NULL DEFAULT 'TIENDA',
    nombre_reporte TEXT NOT NULL,
    hora_envio TIME NOT NULL,
    correo_destino TEXT NOT NULL,
    minutos_tolerancia INTEGER NOT NULL DEFAULT 10,
    total_trabajadores INTEGER NOT NULL DEFAULT 0,
    trabajadores JSONB NOT NULL DEFAULT '[]'::JSONB,
    enviado BOOLEAN NOT NULL DEFAULT FALSE,
    error TEXT NULL,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    enviado_en TIMESTAMPTZ NULL,
    CONSTRAINT alerta_puntualidad_log_pkey PRIMARY KEY (id_log),
    CONSTRAINT alerta_puntualidad_log_id_config_fkey
        FOREIGN KEY (id_config)
        REFERENCES public.alerta_puntualidad_config(id_config)
        ON DELETE SET NULL,
    CONSTRAINT alerta_puntualidad_log_tipo_reporte_check
        CHECK (tipo_reporte IN ('TIENDA', 'GENERAL')),
    CONSTRAINT alerta_puntualidad_log_tienda_requerida_check
        CHECK (
            (tipo_reporte = 'GENERAL' AND id_tienda IS NULL)
            OR (tipo_reporte = 'TIENDA' AND id_tienda IS NOT NULL)
        ),
    CONSTRAINT alerta_puntualidad_log_trabajadores_array_check
        CHECK (jsonb_typeof(trabajadores) = 'array'),
    CONSTRAINT alerta_puntualidad_log_total_check
        CHECK (total_trabajadores >= 0)
);

-- 1 fila por correo programado/configuracion en una fecha y hora.
CREATE UNIQUE INDEX uq_alerta_log_por_config_fecha_hora
    ON public.alerta_puntualidad_log(id_config, fecha, hora_envio)
    WHERE id_config IS NOT NULL;

-- Fallback para logs manuales sin id_config.
CREATE UNIQUE INDEX uq_alerta_log_manual_fecha_hora_correo
    ON public.alerta_puntualidad_log(
        COALESCE(id_tienda, '00000000-0000-0000-0000-000000000000'::UUID),
        fecha,
        hora_envio,
        tipo_reporte,
        lower(trim(correo_destino))
    )
    WHERE id_config IS NULL;

CREATE INDEX idx_alerta_log_busqueda
    ON public.alerta_puntualidad_log(fecha, hora_envio, tipo_reporte, correo_destino);

CREATE INDEX idx_alerta_log_trabajadores_gin
    ON public.alerta_puntualidad_log
    USING GIN (trabajadores);

-- Programacion automatica dinamica.
-- El cron consulta cada minuto y la Edge Function decide que filas estan
-- dentro de la hora_envio + ventana_minutos configuradas en la tabla.
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

DO $$
DECLARE
    nombre_job TEXT;
BEGIN
    FOREACH nombre_job IN ARRAY ARRAY[
        'reporte-no-marcados-contabilidad-0830',
        'alertas-puntualidad-cada-5-min',
        'reporte-tiendas-0830',
        'reporte-tiendas-1330',
        'reporte-puntualidad-dinamico'
    ]
    LOOP
        BEGIN
            PERFORM cron.unschedule(nombre_job);
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;
END $$;

-- Antes de programar el job debe existir en Vault un secreto llamado
-- reporte_puntualidad_cron_secret con el mismo valor de CRON_SECRET
-- configurado en la Edge Function.
SELECT cron.schedule(
    'reporte-puntualidad-dinamico',
    '* * * * *',
    $$
    SELECT net.http_post(
        url := 'https://tlmsnenvqqblmmtimung.supabase.co/functions/v1/reporte-puntualidad-gmail',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', (
                SELECT decrypted_secret
                FROM vault.decrypted_secrets
                WHERE name = 'reporte_puntualidad_cron_secret'
                ORDER BY created_at DESC
                LIMIT 1
            )
        ),
        body := jsonb_build_object('trigger', 'cron'),
        timeout_milliseconds := 60000
    );
    $$
);

-- Ejemplo del JSON esperado en trabajadores:
-- [
--   {
--     "dni_trabajador": "73484040",
--     "nombre_trabajador": "JOEL ALEXANDER DIAZ GUTIERREZ",
--     "cargo": "Ing. Sistemas",
--     "id_tienda": "93bb9635-0a73-47ac-ba01-b21a4f880f26",
--     "nombre_tienda": "Sistemas",
--     "tipo_marcacion": "Entrada",
--     "hora_programada": "08:00:00",
--     "hora_marcada": "08:16:00",
--     "minutos_tarde": 16,
--     "motivo": "Marco tarde"
--   }
-- ]

NOTIFY pgrst, 'reload schema';
