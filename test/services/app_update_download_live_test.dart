import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trabajador_app/services/app_update_download_service.dart';
import 'package:trabajador_app/services/app_version_service.dart';

/// Ejecutar antes de publicar la versión en Supabase con URL y SHA del APK.
/// Sin estas variables, CI no descarga archivos externos.
void main() {
  final url = Platform.environment['TRABAJADOR_UPDATE_TEST_URL'];
  final digest = Platform.environment['TRABAJADOR_UPDATE_TEST_SHA256'];
  test(
    'descarga el APK real publicado con el mismo flujo que usa Android',
    () async {
      HttpOverrides.global = null;
      final directory = await Directory.systemTemp.createTemp(
        'trabajador-live-update-',
      );
      final service = AppUpdateDownloadService(
        directoryProvider: () async => directory,
        maximumDuration: const Duration(minutes: 3),
      );
      try {
        var verified = false;
        final file = await service.download(
          AppReleaseInfo(
            version: 'publicada',
            buildNumber: 6,
            downloadUrl: Uri.parse(url!),
            message: 'Prueba',
            mandatory: true,
            sha256: digest!,
          ),
          onProgress: (progress) {
            if (progress.phase == UpdateDownloadPhase.verifying)
              verified = true;
          },
        );
        expect(verified, isTrue);
        expect(await file.length(), greaterThan(1024 * 1024));
        expect(await File('${file.path}.part').exists(), isFalse);
      } finally {
        service.cancel();
        await directory.delete(recursive: true);
      }
    },
    skip: url == null || digest == null,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
