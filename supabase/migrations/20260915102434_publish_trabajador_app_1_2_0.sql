insert into public.version_trabajador_app (
  plataforma,
  version_publicada,
  build_publicado,
  url_descarga,
  sha256,
  mensaje,
  obligatoria,
  activa,
  actualizada_en
)
values (
  'android',
  '1.2.0',
  4,
  'https://github.com/Alex-bit64/TRABAJADOR-APP/releases/download/v1.2.0/marcador-trabajador-1.2.0.apk',
  '63e8eb56c6aef5ab24d93b021995f94cb661f8e33b3baba80b6d5120c7c1a30f',
  'Hay una nueva version del Marcador. Actualiza para continuar usando la aplicacion.',
  true,
  true,
  now()
)
on conflict (plataforma) do update
set version_publicada = excluded.version_publicada,
    build_publicado = excluded.build_publicado,
    url_descarga = excluded.url_descarga,
    sha256 = excluded.sha256,
    mensaje = excluded.mensaje,
    obligatoria = excluded.obligatoria,
    activa = excluded.activa,
    actualizada_en = excluded.actualizada_en;
