-- Activate only after verifying the release APK and its existing signing certificate.
insert into public.version_trabajador_app (
  plataforma, version_publicada, build_publicado, url_descarga, sha256,
  mensaje, obligatoria, activa, actualizada_en
)
values (
  'android', '1.2.1', 5,
  'https://github.com/Alex-bit64/TRABAJADOR-APP/releases/download/v1.2.1/marcador-trabajador-1.2.1.apk',
  '79cf26931e9d392700f746863a4ac492f832c54330d47639681cb27a8ce654f8',
  'Actualiza el Marcador: correccion de carga del horario, tema claro/oscuro guardado y nuevo logo.',
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
