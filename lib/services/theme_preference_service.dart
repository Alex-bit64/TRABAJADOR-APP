import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

class ThemePreferenceService {
  static const _key = 'trabajador_theme_mode';

  Future<ThemeMode> cargar() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key) == 'light'
          ? ThemeMode.light
          : ThemeMode.dark;
    } catch (e, st) {
      AppLogger.error('Tema', 'No se pudo restaurar el tema', e, st);
      return ThemeMode.dark;
    }
  }

  Future<void> guardar(ThemeMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, mode == ThemeMode.light ? 'light' : 'dark');
    } catch (e, st) {
      AppLogger.error('Tema', 'No se pudo guardar el tema', e, st);
    }
  }
}
