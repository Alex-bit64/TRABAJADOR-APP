-- Keep the address displayed for a tracking mark separate from the store's
-- administrative address. Only the service-role report function can use this
-- cache or reserve a slot on the public reverse-geocoding service.
create table if not exists public.tracking_geocode_cache (
  clave text primary key,
  direccion text not null,
  fuente text not null,
  actualizado_en timestamptz not null default now()
);

alter table public.tracking_geocode_cache enable row level security;
revoke all on public.tracking_geocode_cache from anon, authenticated;
grant select, insert, update on public.tracking_geocode_cache to service_role;

create table if not exists public.tracking_geocode_rate_limit (
  id smallint primary key check (id = 1),
  proximo_en timestamptz not null
);

alter table public.tracking_geocode_rate_limit enable row level security;
revoke all on public.tracking_geocode_rate_limit from anon, authenticated;
grant select, update on public.tracking_geocode_rate_limit to service_role;

insert into public.tracking_geocode_rate_limit (id, proximo_en)
values (1, '-infinity'::timestamptz)
on conflict (id) do nothing;

create or replace function public.reservar_tracking_geocode_slot()
returns timestamptz
language plpgsql
security invoker
set search_path = ''
as $$
declare
  reserva timestamptz;
begin
  select greatest(proximo_en, clock_timestamp()) into reserva
  from public.tracking_geocode_rate_limit
  where id = 1
  for update;

  if reserva is null or reserva > clock_timestamp() + interval '20 seconds' then
    return null;
  end if;

  update public.tracking_geocode_rate_limit
  set proximo_en = reserva + interval '15 seconds'
  where id = 1;

  return reserva;
end;
$$;

revoke all on function public.reservar_tracking_geocode_slot()
from public, anon, authenticated;
grant execute on function public.reservar_tracking_geocode_slot() to service_role;
