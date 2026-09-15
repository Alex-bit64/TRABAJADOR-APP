-- El Marcador de trabajadores necesita su propio canal de actualizaciones.
-- La tabla version_aplicacion existente corresponde a QR Sucursal.
create table if not exists public.version_trabajador_app (
  plataforma text primary key,
  version_publicada text not null,
  build_publicado integer not null,
  url_descarga text not null,
  sha256 text,
  mensaje text not null default 'Hay una nueva version del Marcador disponible.',
  obligatoria boolean not null default true,
  activa boolean not null default true,
  actualizada_en timestamptz not null default now(),
  constraint version_trabajador_app_plataforma_check
    check (plataforma in ('android', 'ios')),
  constraint version_trabajador_app_version_check
    check (length(trim(version_publicada)) between 1 and 32),
  constraint version_trabajador_app_build_check
    check (build_publicado > 0),
  constraint version_trabajador_app_url_check
    check (url_descarga ~ '^https://'),
  constraint version_trabajador_app_sha256_check
    check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$')
);

create or replace function public.obtener_version_trabajador_app(
  p_plataforma text
)
returns table (
  plataforma text,
  version_publicada text,
  build_publicado integer,
  url_descarga text,
  sha256 text,
  mensaje text,
  obligatoria boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    v.plataforma,
    v.version_publicada,
    v.build_publicado,
    v.url_descarga,
    v.sha256,
    v.mensaje,
    v.obligatoria
  from public.version_trabajador_app v
  where v.plataforma = lower(trim(p_plataforma))
    and v.activa = true
  limit 1;
$$;

revoke all on function public.obtener_version_trabajador_app(text) from public;
grant execute on function public.obtener_version_trabajador_app(text)
  to anon, authenticated;

-- 00:00 se usaba como valor centinela para "sin refrigerio". Convertirlo
-- a NULL evita que el Marcador solicite cuatro marcas en jornadas de dos.
update public.horario_trabajador
set horario_inicio_receso = null,
    horario_fin_receso = null
where horario_inicio_receso = time '00:00'
   or horario_fin_receso = time '00:00';

-- Los horarios con inicio >= fin no representan una jornada del mismo dia.
-- Se apartan de la tabla operativa sin perder el registro original.
create table if not exists public.horario_trabajador_invalido_archivo (
  id_horario uuid primary key,
  dni_trabajador varchar not null,
  dia_semana text not null,
  horario_entrada time not null,
  horario_inicio_receso time,
  horario_fin_receso time,
  horario_salida time not null,
  motivo text not null,
  archivado_en timestamptz not null default now()
);

insert into public.horario_trabajador_invalido_archivo (
  id_horario,
  dni_trabajador,
  dia_semana,
  horario_entrada,
  horario_inicio_receso,
  horario_fin_receso,
  horario_salida,
  motivo
)
select
  id_horario,
  dni_trabajador,
  dia_semana::text,
  horario_entrada,
  horario_inicio_receso,
  horario_fin_receso,
  horario_salida,
  'La hora de entrada era igual o posterior a la salida.'
from public.horario_trabajador
where horario_entrada >= horario_salida
on conflict (id_horario) do nothing;

delete from public.horario_trabajador
where horario_entrada >= horario_salida;

-- La fecha de la fila es la fecha laboral autoritativa. Conservamos la hora
-- local de las marcas históricas que quedaron guardadas en otro día.
update public.asistencia
set horario_entrada = case
      when horario_entrada is not null
       and (horario_entrada at time zone 'America/Lima')::date <> fecha
      then (fecha::timestamp + (horario_entrada at time zone 'America/Lima')::time)
           at time zone 'America/Lima'
      else horario_entrada
    end,
    horario_inicio_receso = case
      when horario_inicio_receso is not null
       and (horario_inicio_receso at time zone 'America/Lima')::date <> fecha
      then (fecha::timestamp + (horario_inicio_receso at time zone 'America/Lima')::time)
           at time zone 'America/Lima'
      else horario_inicio_receso
    end,
    horario_fin_receso = case
      when horario_fin_receso is not null
       and (horario_fin_receso at time zone 'America/Lima')::date <> fecha
      then (fecha::timestamp + (horario_fin_receso at time zone 'America/Lima')::time)
           at time zone 'America/Lima'
      else horario_fin_receso
    end,
    horario_salida = case
      when horario_salida is not null
       and (horario_salida at time zone 'America/Lima')::date <> fecha
      then (fecha::timestamp + (horario_salida at time zone 'America/Lima')::time)
           at time zone 'America/Lima'
      else horario_salida
    end
where (horario_entrada is not null and (horario_entrada at time zone 'America/Lima')::date <> fecha)
   or (horario_inicio_receso is not null and (horario_inicio_receso at time zone 'America/Lima')::date <> fecha)
   or (horario_fin_receso is not null and (horario_fin_receso at time zone 'America/Lima')::date <> fecha)
   or (horario_salida is not null and (horario_salida at time zone 'America/Lima')::date <> fecha);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'horario_trabajador_orden_valido'
      and conrelid = 'public.horario_trabajador'::regclass
  ) then
    alter table public.horario_trabajador
      add constraint horario_trabajador_orden_valido check (
        horario_entrada < horario_salida
        and (
          (horario_inicio_receso is null and horario_fin_receso is null)
          or (
            horario_entrada < horario_inicio_receso
            and horario_inicio_receso < horario_fin_receso
            and horario_fin_receso < horario_salida
          )
        )
      ) not valid;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'asistencia_marcas_misma_fecha'
      and conrelid = 'public.asistencia'::regclass
  ) then
    alter table public.asistencia
      add constraint asistencia_marcas_misma_fecha check (
        (horario_entrada is null or (horario_entrada at time zone 'America/Lima')::date = fecha)
        and (horario_inicio_receso is null or (horario_inicio_receso at time zone 'America/Lima')::date = fecha)
        and (horario_fin_receso is null or (horario_fin_receso at time zone 'America/Lima')::date = fecha)
        and (horario_salida is null or (horario_salida at time zone 'America/Lima')::date = fecha)
      ) not valid;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'asistencia_orden_cronologico'
      and conrelid = 'public.asistencia'::regclass
  ) then
    alter table public.asistencia
      add constraint asistencia_orden_cronologico check (
        (horario_entrada is null or horario_inicio_receso is null or horario_entrada <= horario_inicio_receso)
        and (horario_inicio_receso is null or horario_fin_receso is null or horario_inicio_receso <= horario_fin_receso)
        and (horario_fin_receso is null or horario_salida is null or horario_fin_receso <= horario_salida)
        and (horario_entrada is null or horario_salida is null or horario_entrada <= horario_salida)
      ) not valid;
  end if;
end
$$;

alter table public.horario_trabajador
  validate constraint horario_trabajador_orden_valido;

alter table public.asistencia
  validate constraint asistencia_marcas_misma_fecha;

comment on table public.version_trabajador_app is
  'Version vigente y APK del Marcador de trabajadores, separado de QR Sucursal.';

comment on table public.horario_trabajador_invalido_archivo is
  'Respaldo recuperable de horarios apartados por no representar una jornada valida.';
