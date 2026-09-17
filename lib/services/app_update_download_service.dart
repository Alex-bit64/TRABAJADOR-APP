import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_version_service.dart';

enum UpdateDownloadPhase { downloading, verifying }

enum UpdateInstallStatus { permissionRequired, installerOpened, alreadyUpdated }

class UpdateDownloadProgress {
  final int received;
  final int? total;
  final UpdateDownloadPhase phase;

  const UpdateDownloadProgress(this.received, this.total, this.phase);

  double? get fraction =>
      total != null && total! > 0 ? (received / total!).clamp(0.0, 1.0) : null;
}

class UpdateDownloadException implements Exception {
  final String message;
  const UpdateDownloadException(this.message);
  @override
  String toString() => message;
}

class UpdateDownloadCancelled implements Exception {}

Future<String> _hashFile(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

/// Descarga acotada y verificable; nunca instala un archivo parcial.
class AppUpdateDownloadService {
  static const _channel = MethodChannel('trabajador_app/platform');
  final Future<Directory> Function()? directoryProvider;
  final Duration inactivityTimeout;
  final Duration fileTimeout;
  final Duration maximumDuration;
  final int maximumBytes;
  HttpClient? _client;
  bool _active = false;
  bool _cancelled = false;
  bool _expired = false;

  AppUpdateDownloadService({
    this.directoryProvider,
    this.inactivityTimeout = const Duration(seconds: 30),
    this.fileTimeout = const Duration(seconds: 20),
    this.maximumDuration = const Duration(minutes: 15),
    this.maximumBytes = 150 * 1024 * 1024,
  });

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  void _checkCancelled() {
    if (_expired) {
      throw const UpdateDownloadException(
        'La descarga tardó demasiado. Revisa la conexión y reintenta.',
      );
    }
    if (_cancelled) throw UpdateDownloadCancelled();
  }

  Future<Directory> _directory() async {
    if (directoryProvider != null) return directoryProvider!();
    final path = await _channel.invokeMethod<String>('prepareUpdateDirectory');
    if (path == null || path.isEmpty) {
      throw const UpdateDownloadException('No se pudo preparar la descarga.');
    }
    return Directory(path);
  }

  Future<File> download(
    AppReleaseInfo release, {
    required void Function(UpdateDownloadProgress) onProgress,
  }) async {
    if (_active) {
      throw const UpdateDownloadException('Ya hay una descarga en curso.');
    }
    if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(release.sha256)) {
      throw const UpdateDownloadException(
        'Esta versión no tiene una verificación válida. Usa el enlace alternativo.',
      );
    }
    _active = true;
    _cancelled = false;
    _expired = false;
    final timer = Timer(maximumDuration, () {
      _expired = true;
      _client?.close(force: true);
    });
    File? partial;
    RandomAccessFile? writer;
    try {
      final directory = await _directory().timeout(fileTimeout);
      await directory.create(recursive: true).timeout(fileTimeout);
      final target = File(
        p.join(directory.path, 'marcador-${release.buildNumber}.apk'),
      );
      final oldFiles = await directory.list().toList().timeout(fileTimeout);
      for (final entry in oldFiles.whereType<File>()) {
        final name = entry.uri.pathSegments.last;
        if (RegExp(r'^marcador-\d+\.apk(?:\.part)?$').hasMatch(name) &&
            entry.path != target.path &&
            entry.path != '${target.path}.part') {
          try {
            await entry.delete().timeout(fileTimeout);
          } catch (_) {
            // Solo son temporales propios; no bloquear si Android los mantiene abiertos.
          }
        }
      }
      if (await target.exists().timeout(fileTimeout)) {
        final digest = await compute(
          _hashFile,
          target.path,
        ).timeout(fileTimeout);
        _checkCancelled();
        if (digest == release.sha256.toLowerCase()) return target;
        await target.delete().timeout(fileTimeout);
      }
      _checkCancelled();
      partial = File('${target.path}.part');
      writer = await partial.open(mode: FileMode.write).timeout(fileTimeout);
      _client = HttpClient()..connectionTimeout = inactivityTimeout;
      final request = await _client!
          .getUrl(release.downloadUrl)
          .timeout(inactivityTimeout);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(inactivityTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateDownloadException(
          'El servidor no pudo entregar el APK (${response.statusCode}). Reintenta.',
        );
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      if (total != null && total > maximumBytes) {
        throw const UpdateDownloadException(
          'El archivo supera el tamaño permitido.',
        );
      }
      var received = 0;
      final progressClock = Stopwatch()..start();
      onProgress(
        UpdateDownloadProgress(0, total, UpdateDownloadPhase.downloading),
      );
      await for (final chunk in response.timeout(inactivityTimeout)) {
        _checkCancelled();
        received += chunk.length;
        if (received > maximumBytes) {
          throw const UpdateDownloadException(
            'El archivo supera el tamaño permitido.',
          );
        }
        await writer.writeFrom(chunk).timeout(fileTimeout);
        if (progressClock.elapsedMilliseconds >= 200 || received == total) {
          onProgress(
            UpdateDownloadProgress(
              received,
              total,
              UpdateDownloadPhase.downloading,
            ),
          );
          progressClock.reset();
        }
      }
      _checkCancelled();
      if (received == 0 || (total != null && received != total)) {
        throw const UpdateDownloadException(
          'La descarga quedó incompleta. Reintenta.',
        );
      }
      onProgress(
        UpdateDownloadProgress(received, total, UpdateDownloadPhase.verifying),
      );
      await writer.flush().timeout(fileTimeout);
      await writer.close().timeout(fileTimeout);
      writer = null;
      final digest = await compute(
        _hashFile,
        partial.path,
      ).timeout(fileTimeout);
      _checkCancelled();
      if (digest != release.sha256.toLowerCase()) {
        throw const UpdateDownloadException(
          'El APK no coincide con la versión publicada. Descárgalo nuevamente.',
        );
      }
      final complete = await partial.rename(target.path).timeout(fileTimeout);
      _checkCancelled();
      return complete;
    } on TimeoutException {
      _checkCancelled();
      throw const UpdateDownloadException(
        'La descarga dejó de responder. Revisa la conexión y reintenta.',
      );
    } on FileSystemException {
      _checkCancelled();
      throw const UpdateDownloadException(
        'No se pudo guardar el APK. Comprueba el espacio libre del celular.',
      );
    } on SocketException {
      _checkCancelled();
      throw const UpdateDownloadException(
        'Se perdió la conexión. Reintenta la descarga.',
      );
    } on HttpException {
      _checkCancelled();
      throw const UpdateDownloadException(
        'La descarga se interrumpió. Reintenta.',
      );
    } finally {
      timer.cancel();
      _client?.close(force: true);
      _client = null;
      try {
        await writer?.close().timeout(fileTimeout);
        if (partial != null && await partial.exists().timeout(fileTimeout)) {
          await partial.delete().timeout(fileTimeout);
        }
      } catch (_) {
        // No impedir el reintento si el sistema no permite borrar el parcial.
      }
      _active = false;
    }
  }

  Future<UpdateInstallStatus> install(File apk, int expectedBuild) async {
    final status = await _channel
        .invokeMethod<String>('installUpdate', {
          'path': apk.path,
          'expectedBuild': expectedBuild,
        })
        .timeout(const Duration(seconds: 30));
    return switch (status) {
      'permission_required' => UpdateInstallStatus.permissionRequired,
      'installer_opened' => UpdateInstallStatus.installerOpened,
      'already_updated' => UpdateInstallStatus.alreadyUpdated,
      _ => throw const UpdateDownloadException(
        'No se pudo abrir el instalador.',
      ),
    };
  }
}
