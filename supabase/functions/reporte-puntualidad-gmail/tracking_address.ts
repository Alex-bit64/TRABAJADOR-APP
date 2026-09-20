export type Coordenadas = { latitud: number; longitud: number };

export function obtenerCoordenadas(
  ubicacion: Record<string, unknown> | null,
): Coordenadas | null {
  if (!ubicacion) return null;
  const latitudCruda = ubicacion.latitud ?? ubicacion.latitude;
  const longitudCruda = ubicacion.longitud ?? ubicacion.longitude;
  if (
    latitudCruda === undefined || latitudCruda === "" ||
    longitudCruda === undefined || longitudCruda === ""
  ) return null;
  const latitud = Number(latitudCruda);
  const longitud = Number(longitudCruda);
  if (
    !Number.isFinite(latitud) || !Number.isFinite(longitud) ||
    Math.abs(latitud) > 90 || Math.abs(longitud) > 180
  ) return null;
  return { latitud, longitud };
}

export function claveCoordenadas({ latitud, longitud }: Coordenadas): string {
  // About 11 m in latitude: nearby marks share a cached approximate street.
  return `${latitud.toFixed(4)},${longitud.toFixed(4)}`;
}

export function direccionCoordenadas(
  { latitud, longitud }: Coordenadas,
): string {
  return `${latitud.toFixed(6)}, ${longitud.toFixed(6)} (ver mapa)`;
}

export function direccionMarca(
  coordenadas: Coordenadas | null,
  direccionGPS?: string,
): string {
  return direccionGPS?.trim() ||
    (coordenadas ? direccionCoordenadas(coordenadas) : "Sin ubicacion registrada");
}

export function direccionGeocodificada(payload: unknown): string | null {
  if (!payload || typeof payload !== "object") return null;
  const address = (payload as Record<string, unknown>).address;
  if (!address || typeof address !== "object") return null;
  const datos = address as Record<string, unknown>;
  const texto = (key: string) =>
    typeof datos[key] === "string" ? (datos[key] as string).trim() : "";
  const via = texto("road") || texto("pedestrian") ||
    texto("residential") || texto("footway");
  if (!via) return null;
  const numero = texto("house_number");
  const barrio = texto("suburb") || texto("neighbourhood");
  const ciudad = texto("city_district") || texto("town") || texto("city");
  return [...new Set([numero ? `${via} ${numero}` : via, barrio, ciudad])]
    .filter(Boolean).join(", ");
}
