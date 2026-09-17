import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trabajador_app/services/session_service.dart';
import 'package:trabajador_app/services/theme_preference_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('conserva el modo oscuro inicial sin preferencia guardada', () async {
    expect(await ThemePreferenceService().cargar(), ThemeMode.dark);
  });

  test('restaura el modo blanco al crear una nueva instancia', () async {
    await ThemePreferenceService().guardar(ThemeMode.light);
    expect(await ThemePreferenceService().cargar(), ThemeMode.light);
  });

  test('guarda nuevamente el modo oscuro', () async {
    await ThemePreferenceService().guardar(ThemeMode.light);
    await ThemePreferenceService().guardar(ThemeMode.dark);
    expect(await ThemePreferenceService().cargar(), ThemeMode.dark);
  });

  test('cerrar sesión no borra el tema escogido', () async {
    await ThemePreferenceService().guardar(ThemeMode.light);
    await SessionService().guardarUsuario({'dni': '73484040'});
    await SessionService().cerrarSesion();
    expect(await SessionService().obtenerUsuario(), isNull);
    expect(await ThemePreferenceService().cargar(), ThemeMode.light);
  });
}
