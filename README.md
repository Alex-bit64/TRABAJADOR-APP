# Marcador de Asistencias

Aplicación Flutter para registro de trabajadores con login, modo claro/oscuro y gestión de asistencia mediante QR.

## Descripción

Este proyecto es una app móvil de trabajador que incluye:

- Pantalla de login con modo claro y modo oscuro.
- Formulario de acceso responsive y centrado.
- Diseño de pantalla de login adaptado al estilo del app del trabajador.
- Autenticación con Supabase.
- Pantalla principal con escaneo de QR y registro de asistencia.
- Manejo de conexiones y mensajes de error con snackbar.

## Estructura principal

- `lib/main.dart` - Punto de entrada de la app.
- `lib/screens/login_screen.dart` - Pantalla de inicio de sesión.
- `lib/screens/home_screen.dart` - Pantalla principal después del login.
- `lib/services/supabase_service.dart` - Comunicación con Supabase.
- `lib/services/qr_service.dart` - Lógica de QR si aplica.
- `lib/theme/app_theme.dart` - Temas y paleta de colores.
- `lib/supabase_options.dart` - Opciones de Supabase.

## Requisitos

- Flutter 3.41.9 y Dart 3.11.5.
- Android SDK instalado y configurado.
- macOS, Xcode y CocoaPods para compilar iOS localmente. GitHub Actions y
  Codemagic también validan la compilación iOS sin firma.
- Cuenta y proyecto en Supabase con las funciones RPC usadas en el repositorio.

## Ejecución

Desde la raíz del proyecto:

```bash
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run
```

Para generar APK de Android:

```bash
flutter build apk --release
```

Para comprobar iOS en macOS sin certificados de distribución:

```bash
flutter build ios --release --no-codesign
```

La instalación en un iPhone o publicación en App Store requiere una cuenta de
Apple Developer, un identificador definitivo de la app y firma válida.

## Personalización

- Para cambiar el botón de modo oscuro/claro, ajusta `lib/screens/login_screen.dart`.
- Para modificar colores o tipografías, revisa `lib/theme/app_theme.dart`.
- Si quieres adaptar el backend, revisa `supabase_horario_rpc.sql`, `supabase_login_rpc.sql` y `supabase_qr_asistencia_rpc.sql`.
- El logo original está en `assets/app_icon_source.jpeg`. En Windows,
  `./scripts/update_app_icons.ps1` regenera los iconos Android/iOS y los logos
  de las pantallas sin cambiar identificadores ni firma de instalación.

## Cambios de la versión 1.2.1

- La carga del horario distingue ausencia confirmada de errores de conexión.
  Muestra primero el horario guardado del día, reintenta la consulta y permite
  volver a consultar sin elegir una jornada manual por un fallo de red.
- El modo claro/oscuro se conserva entre aperturas y cierres de sesión.
- Nuevo icono basado en `ColorMarcosGrandes.jpeg`.
- Android consulta `obtener_version_trabajador_app` al abrir la aplicación.
  La versión publicada se activa solo después de verificar su APK descargable.
  Equipos anteriores al sistema de actualización necesitan una instalación
  manual inicial; la app no puede instalar un APK remotamente.

## Cambios de la versión 1.2.2

- Actualización Android dentro de la app: descarga con progreso, cancelación,
  límite de inactividad y reintento, sin depender del gestor del navegador.
- El APK parcial nunca se instala: se comprueba longitud y SHA-256 publicado.
  Android valida además identificador, build y firma antes de abrir el instalador.
- Se conserva el APK verificado al regresar de “Permitir desde esta fuente”
  o al cancelar el instalador; no se descarga otra vez innecesariamente.
- Los temporales de versiones anteriores se limpian para no acumular APKs.
- La consulta inicial de versión tiene un tiempo máximo. Hay enlace alternativo
  y opción de copiarlo si el dispositivo impide la instalación desde el Marcador.
- Instalar 1.2.2 desde 1.2.0/1.2.1 requiere completar una última descarga externa,
  porque esas versiones aún no contienen el nuevo descargador.

## Notas

- El login ahora utiliza un panel blanco/crema con texto oscuro en modo claro.
- El bloque de `REGISTRO` está centrado verticalmente y es responsive.
- Se mejoró el contraste del texto en el modo claro para que sea legible.

## Datos offline y sincronización

- La app guarda en SQLite el historial consultado, los QR estáticos ya
  validados y las marcaciones que no pudieron llegar a Supabase.
- Una marca offline conserva su hora, ubicación y jornada originales. La app
  intenta sincronizarla al recuperar internet y muestra `Por sincronizar`
  mientras siga pendiente.
- Por seguridad, un QR dinámico necesita internet. Un QR estático puede usarse
  offline solamente si ese dispositivo ya lo validó antes contra Supabase.
- SQLite es la copia local de cada dispositivo; Supabase continúa siendo la
  fuente central para reportes y administración.

## SQL requerido en Supabase

Ejecuta en el SQL Editor, en este orden:

1. `supabase_version_app_schema.sql`, para agregar versión, build, plataforma y
   fecha de actualización a cada trabajador.
2. `supabase_biometria_dispositivo_schema.sql`, para vincular un trabajador con
   un único celular sin guardar huellas ni rostros.
3. `supabase_qr_asistencia_rpc.sql`, para instalar la versión del RPC que acepta
   eventos offline idempotentes y conserva la hora original.

La versión se toma automáticamente de `version` en `pubspec.yaml`. Para una
nueva entrega incrementa, por ejemplo, `1.0.0+1` a `1.0.1+2`; al abrir sesión
se actualizará el registro del trabajador.

## Biometría y dispositivo autorizado

- En el primer inicio de sesión la contraseña y una validación biométrica
  vinculan el trabajador con ese celular.
- Después de validar cada QR de asistencia, Android/iOS muestra su diálogo
  de seguridad. Usa rostro o huella cuando están disponibles y permite el
  patrón, PIN o código configurado en el sistema como alternativa.
- Si el teléfono no tiene ningún bloqueo local configurado, la app permite
  continuar con el registro de acuerdo con la regla funcional actual.
- Supabase solo recibe un UUID aleatorio del dispositivo y el hash de un secreto
  local. El sistema operativo nunca entrega a la app la imagen o plantilla de
  la huella.
- Un celular no puede vincularse simultáneamente con dos trabajadores, y un
  trabajador no puede vincularse con dos celulares.
- Para reemplazar o reasignar un equipo, un administrador debe ejecutar:

```sql
DELETE FROM public.trabajador_dispositivo
WHERE dni_trabajador = 'DNI';

UPDATE public.trabajador
SET biometria_requerida = FALSE
WHERE dni = 'DNI';
```

## Licencia

Este repositorio es de uso personal y puede adaptarse según tu proyecto.
