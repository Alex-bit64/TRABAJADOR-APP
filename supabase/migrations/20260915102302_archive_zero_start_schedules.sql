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
  'La jornada conservaba 00:00 como hora centinela.'
from public.horario_trabajador
where horario_entrada = time '00:00'
   or horario_salida = time '00:00'
on conflict (id_horario) do nothing;

delete from public.horario_trabajador
where horario_entrada = time '00:00'
   or horario_salida = time '00:00';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'horario_trabajador_horas_no_cero'
      and conrelid = 'public.horario_trabajador'::regclass
  ) then
    alter table public.horario_trabajador
      add constraint horario_trabajador_horas_no_cero check (
        horario_entrada <> time '00:00'
        and horario_salida <> time '00:00'
      );
  end if;
end
$$;
