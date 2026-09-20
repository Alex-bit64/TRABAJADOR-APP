-- Supabase grants function EXECUTE directly to API roles by default.
revoke all on function public.reservar_tracking_geocode_slot()
from public, anon, authenticated;
