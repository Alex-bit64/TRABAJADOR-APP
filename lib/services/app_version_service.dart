import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'app_logger.dart';
import 'supabase_service.dart';

class AppVersionService {
  final SupabaseService _supabaseService;

  AppVersionService({SupabaseService? supabaseService})
    : _supabaseService = supabaseService ?? SupabaseService();

  Future<void> registrarParaUsuario(Map<String, dynamic> usuario) async {
    final dni =
        usuario['dni']?.toString() ??
        usuario['id_trabajador']?.toString() ??
        '';
    if (dni.trim().isEmpty) {
      return;
    }

    try {
      final info = await PackageInfo.fromPlatform();
      await _supabaseService.actualizarVersionApp(
        dni: dni,
        version: info.version,
        buildNumber: info.buildNumber,
        plataforma: Platform.operatingSystem,
      );
    } catch (e, st) {
      AppLogger.error(
        'AppVersionService',
        'No se pudo leer o registrar la version instalada',
        e,
        st,
        {'dni': AppLogger.shortId(dni)},
      );
    }
  }
}
