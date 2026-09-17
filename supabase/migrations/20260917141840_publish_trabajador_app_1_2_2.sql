-- Publish only after the actual APK download has passed the app's verifier.
insert into public.version_trabajador_app (
  plataforma, version_publicada, build_publicado, url_descarga, sha256,
  mensaje, obligatoria, activa, actualizada_en
)
values (
  'android', '1.2.2', 6,
  'https://github.com/Alex-bit64/TRABAJADOR-APP/releases/download/v1.2.2/marcador-trabajador-1.2.2.apk',
  'd8c2802906ccf13cec03430c56ea09b1458e778efab13e0e8189654a41d7db15',
  'Actualiza el Marcador: descargador interno con progreso, verificacion del APK y recuperacion de permisos de instalacion.',
  true, true, now()
)
on conflict (plataforma) do update
set version_publicada = excluded.version_publicada,
    build_publicado = excluded.build_publicado,
    url_descarga = excluded.url_descarga,
    sha256 = excluded.sha256,
    mensaje = excluded.mensaje,
    obligatoria = excluded.obligatoria,
    activa = excluded.activa,
    actualizada_en = excluded.actualizada_en
where public.version_trabajador_app.build_publicado <= excluded.build_publicado;
