import 'package:flutter/foundation.dart';

class AppLogger {
  static const bool enabled = kDebugMode;

  static void info(String tag, String message, [Map<String, Object?>? data]) {
    _write('INFO', tag, message, data);
  }

  static void warning(
    String tag,
    String message, [
    Map<String, Object?>? data,
  ]) {
    _write('WARN', tag, message, data);
  }

  static void error(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  ]) {
    _write('ERROR', tag, message, data);
    if (error != null && kDebugMode) {
      debugPrint('[$tag] error=${_sanitizeValue(error)}');
    }
    if (stackTrace != null && kDebugMode) {
      debugPrint(stackTrace.toString());
    }
  }

  static String maskEmail(String email) {
    final parts = email.split('@');
    if (parts.length != 2) {
      return 'correo_invalido';
    }

    final name = parts.first;
    final visible = name.length <= 2 ? name : name.substring(0, 2);
    return '$visible***@${parts.last}';
  }

  static String shortId(String value) {
    if (value.length <= 8) {
      return value;
    }
    return '${value.substring(0, 4)}...${value.substring(value.length - 4)}';
  }

  static void _write(
    String level,
    String tag,
    String message,
    Map<String, Object?>? data,
  ) {
    if (!enabled) {
      return;
    }

    final time = DateTime.now().toIso8601String();
    final details = data == null || data.isEmpty
        ? ''
        : ' ${data.entries.map((e) => '${e.key}=${_sanitizeData(e.key, e.value)}').join(' ')}';
    debugPrint('[$time][$level][$tag] $message$details');
  }

  static Object? _sanitizeData(String key, Object? value) {
    final normalized = key.toLowerCase();
    if (normalized.contains('token') ||
        normalized.contains('password') ||
        normalized.contains('contrasena') ||
        normalized.contains('bytes') ||
        normalized.contains('details') ||
        normalized.contains('hint')) {
      return '[oculto]';
    }
    return _sanitizeValue(value);
  }

  static Object? _sanitizeValue(Object? value) {
    if (value == null) {
      return null;
    }

    final text = value.toString();
    if (text.length <= 120) {
      return text;
    }
    return '${text.substring(0, 120)}...';
  }
}
