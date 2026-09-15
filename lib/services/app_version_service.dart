import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'app_logger.dart';
import 'supabase_service.dart';

class AppReleaseInfo {
  final String version;
  final int buildNumber;
  final Uri downloadUrl;
  final String message;
  final bool mandatory;

  const AppReleaseInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.message,
    required this.mandatory,
  });
}

class AppVersionService {
  final SupabaseService _supabaseService;

  AppVersionService({SupabaseService? supabaseService})
    : _supabaseService = supabaseService ?? SupabaseService();

  static bool requiereActualizacion({
    required int buildInstalado,
    required int buildPublicado,
  }) => buildPublicado > buildInstalado;

  Future<AppReleaseInfo?> verificarActualizacion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final buildInstalado = int.tryParse(info.buildNumber.trim()) ?? 0;
      final data = await _supabaseService.obtenerVersionTrabajadorApp(
        Platform.operatingSystem,
      );
      if (data == null) {
        return null;
      }

      final buildPublicado = data['build_publicado'] is num
          ? (data['build_publicado'] as num).toInt()
          : int.tryParse(data['build_publicado']?.toString() ?? '') ?? 0;
      if (!requiereActualizacion(
        buildInstalado: buildInstalado,
        buildPublicado: buildPublicado,
      )) {
        return null;
      }

      final url = Uri.tryParse(data['url_descarga']?.toString().trim() ?? '');
      if (url == null || url.scheme != 'https') {
        AppLogger.warning(
          'AppVersionService',
          'La version publicada no tiene una URL HTTPS valida',
          {'build_publicado': buildPublicado},
        );
        return null;
      }

      return AppReleaseInfo(
        version: data['version_publicada']?.toString().trim() ?? '',
        buildNumber: buildPublicado,
        downloadUrl: url,
        message:
            data['mensaje']?.toString().trim() ??
            'Hay una nueva version del Marcador disponible.',
        mandatory: data['obligatoria'] != false,
      );
    } catch (e, st) {
      AppLogger.error(
        'AppVersionService',
        'No se pudo verificar la version publicada',
        e,
        st,
      );
      return null;
    }
  }

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
