# trabajador_app

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

- Flutter 3.0+ / Flutter 4.0+ compatible.
- Android SDK instalado y configurado.
- Xcode instalado para iOS (opcional).
- Cuenta y proyecto en Supabase con las funciones RPC usadas en el repositorio.

## Ejecución

Desde la raíz del proyecto:

```bash
flutter pub get
flutter run
```

Para generar APK de Android:

```bash
flutter build apk
```

## Personalización

- Para cambiar el bootón de modo oscuro / claro, ajusta `lib/screens/login_screen.dart`.
- Para modificar colores o tipografías, revisa `lib/theme/app_theme.dart`.
- Si quieres adaptar el backend, revisa `supabase_horario_rpc.sql`, `supabase_login_rpc.sql` y `supabase_qr_asistencia_rpc.sql`.

## Notas

- El login ahora utiliza un panel blanco/crema con texto oscuro en modo claro.
- El bloque de `REGISTRO` está centrado verticalmente y es responsive.
- Se mejoró el contraste del texto en el modo claro para que sea legible.

## Licencia

Este repositorio es de uso personal y puede adaptarse según tu proyecto.

