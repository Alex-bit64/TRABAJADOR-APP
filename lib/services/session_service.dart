import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

class SessionService {
  static const String _usuarioKey = 'trabajador_usuario';
  static const String _horarioManualPrefix = 'horario_manual';

  Future<void> guardarUsuario(Map<String, dynamic> usuario) async {
    try {
      final data = Map<String, dynamic>.from(usuario)..remove('contrasena');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_usuarioKey, jsonEncode(data));
      AppLogger.info('SessionService', 'Sesion guardada', {
        'dni': AppLogger.shortId(data['dni']?.toString() ?? ''),
      });
    } catch (e, st) {
      AppLogger.error('SessionService', 'No se pudo guardar sesion', e, st);
    }
  }

  Future<Map<String, dynamic>?> obtenerUsuario() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_usuarioKey);
      if (raw == null || raw.trim().isEmpty) {
        return null;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await cerrarSesion();
        return null;
      }

      final usuario = Map<String, dynamic>.from(decoded);
      if ((usuario['dni']?.toString() ?? '').trim().isEmpty) {
        await cerrarSesion();
        return null;
      }

      return usuario;
    } catch (e, st) {
      AppLogger.error('SessionService', 'No se pudo restaurar sesion', e, st);
      await cerrarSesion();
      return null;
    }
  }

  Future<void> cerrarSesion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_usuarioKey);
    } catch (e, st) {
      AppLogger.error('SessionService', 'No se pudo limpiar sesion', e, st);
    }
  }

  Future<void> guardarHorarioManual(
    String dni,
    DateTime fecha,
    Map<String, dynamic> horario,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_horarioManualKey(dni, fecha), jsonEncode(horario));
      AppLogger.info('SessionService', 'Horario manual guardado', {
        'dni': AppLogger.shortId(dni),
        'fecha': _fechaKey(fecha),
        'tipo': horario['tipo_jornada']?.toString() ?? '',
      });
    } catch (e, st) {
      AppLogger.error(
        'SessionService',
        'No se pudo guardar horario manual',
        e,
        st,
      );
    }
  }

  Future<Map<String, dynamic>?> obtenerHorarioManual(
    String dni,
    DateTime fecha,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_horarioManualKey(dni, fecha));
      if (raw == null || raw.trim().isEmpty) {
        return null;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }

      return Map<String, dynamic>.from(decoded);
    } catch (e, st) {
      AppLogger.error(
        'SessionService',
        'No se pudo restaurar horario manual',
        e,
        st,
      );
      return null;
    }
  }

  String _horarioManualKey(String dni, DateTime fecha) {
    return '$_horarioManualPrefix:${dni.trim()}:${_fechaKey(fecha)}';
  }

  String _fechaKey(DateTime fecha) {
    final local = fecha.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}
