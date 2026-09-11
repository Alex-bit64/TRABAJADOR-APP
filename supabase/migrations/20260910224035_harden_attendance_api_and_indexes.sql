-- Remove the obsolete overload that accepted an arbitrary timestamp without
-- validating QR, device identity or location. The mobile app uses the current
-- ten-argument implementation through registrar_marcacion_asistencia_qr.
drop function if exists public.registrar_marcacion_asistencia(
  text,
  timestamp with time zone,
  text
);

-- This view contains worker and attendance information and is not part of the
-- public mobile API. Keep it available to postgres/service_role only and make
-- any future grants respect the caller's RLS context.
alter view public.v_asistencia_resumen set (security_invoker = true);
revoke all on table public.v_asistencia_resumen from public, anon, authenticated;

-- Event-trigger helpers are invoked by PostgreSQL, never by mobile clients.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- Cover the foreign key used when punctuality configurations are joined or
-- removed by store.
create index if not exists idx_alerta_puntualidad_config_id_tienda
  on public.alerta_puntualidad_config (id_tienda);
