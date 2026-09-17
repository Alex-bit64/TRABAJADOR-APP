import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_logger.dart';
import '../services/app_update_download_service.dart';
import '../services/app_version_service.dart';
import '../theme/app_theme.dart';

class AppUpdateGate extends StatefulWidget {
  final Widget child;
  final Future<AppReleaseInfo?> Function()? verificarVersion;
  final AppUpdateDownloadService? downloadService;
  final bool? esAndroid;
  final Duration checkingTimeout;

  const AppUpdateGate({
    super.key,
    required this.child,
    this.verificarVersion,
    this.downloadService,
    this.esAndroid,
    this.checkingTimeout = const Duration(seconds: 12),
  });

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate>
    with WidgetsBindingObserver {
  AppReleaseInfo? _release;
  bool _checking = true;
  bool _opening = false;
  bool _consultando = false;
  bool _downloading = false;
  bool _installing = false;
  File? _apk;
  String? _status;
  UpdateDownloadProgress? _progress;
  late final AppUpdateDownloadService _downloader;
  String? _launchError;
  bool get _android => widget.esAndroid ?? Platform.isAndroid;
  bool get _busy => _opening || _downloading || _installing;

  @override
  void initState() {
    super.initState();
    _downloader = widget.downloadService ?? AppUpdateDownloadService();
    WidgetsBinding.instance.addObserver(this);
    _checkForUpdate();
  }

  @override
  void dispose() {
    _downloader.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No desmontar el login al volver de biometría o permisos de cámara.
    if (state == AppLifecycleState.resumed &&
        _release != null &&
        !_busy &&
        _apk == null) {
      _checkForUpdate();
    }
  }

  Future<void> _checkForUpdate() async {
    if (_consultando || _busy || _apk != null) return;
    _consultando = true;
    if (mounted) {
      setState(() => _checking = true);
    }
    try {
      final release =
          await (widget.verificarVersion?.call() ??
                  AppVersionService().verificarActualizacion())
              .timeout(widget.checkingTimeout);
      if (mounted) setState(() => _release = release);
    } catch (e, st) {
      AppLogger.error(
        'AppUpdate',
        'No se pudo verificar la actualización',
        e,
        st,
      );
    } finally {
      _consultando = false;
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openDownload() async {
    if (!_android) return _openBrowserDownload();
    final release = _release;
    if (release == null || _busy) return;
    if (_apk != null) return _installApk();
    setState(() {
      _downloading = true;
      _launchError = null;
      _status = null;
      _progress = null;
    });
    try {
      final apk = await _downloader.download(
        release,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _apk = apk;
        _downloading = false;
        _progress = null;
        _status = 'APK descargado y verificado.';
      });
      await _installApk();
    } on UpdateDownloadCancelled {
      if (mounted) {
        setState(() => _status = 'Descarga cancelada. Puedes reintentar.');
      }
    } catch (e, st) {
      _showUpdateError(e, st);
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
          _progress = null;
        });
      }
    }
  }

  void _showUpdateError(Object error, StackTrace stack) {
    AppLogger.error('AppUpdate', 'Actualización interrumpida', error, stack);
    if (!mounted) return;
    setState(() {
      _launchError = error is UpdateDownloadException
          ? error.message
          : error is PlatformException
          ? error.message ?? 'No se pudo abrir el instalador.'
          : error is TimeoutException
          ? 'El proceso dejó de responder. Puedes reintentar.'
          : 'No se pudo completar la actualización. Reintenta o usa la descarga alternativa.';
    });
  }

  Future<void> _installApk() async {
    final apk = _apk;
    final release = _release;
    if (apk == null || release == null || _installing) return;
    setState(() {
      _installing = true;
      _launchError = null;
    });
    try {
      final result = await _downloader.install(apk, release.buildNumber);
      if (!mounted) return;
      setState(() {
        switch (result) {
          case UpdateInstallStatus.permissionRequired:
            _status =
                'Activa “Permitir desde esta fuente” para el Marcador. Luego vuelve y pulsa Instalar actualización. No necesitas descargar otra vez.';
          case UpdateInstallStatus.installerOpened:
            _status =
                'Confirma la actualización en el instalador de Android. Si la cancelaste, pulsa Instalar actualización para volver a abrirlo.';
          case UpdateInstallStatus.alreadyUpdated:
            _release = null;
            _apk = null;
        }
      });
    } catch (e, st) {
      _showUpdateError(e, st);
      if (e is PlatformException && e.code == 'UPDATE_APK' && mounted) {
        setState(() => _apk = null);
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _openBrowserDownload() async {
    final release = _release;
    if (release == null || _busy) return;
    setState(() {
      _opening = true;
      _launchError = null;
    });
    try {
      final opened = await launchUrl(
        release.downloadUrl,
        mode: LaunchMode.externalApplication,
      ).timeout(const Duration(seconds: 8));
      if (!opened && mounted) {
        setState(() => _launchError = 'No se pudo abrir la descarga.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _launchError = 'No se pudo abrir la descarga.');
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final release = _release;
    if (release == null) {
      return widget.child;
    }

    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !release.mandatory,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: AppPalette.verdeAzulado.withValues(
                              alpha: 0.16,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.system_update_alt_rounded,
                            size: 38,
                            color: AppPalette.verdeAzulado,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Actualizacion disponible',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          release.message,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Version ${release.version} (${release.buildNumber})',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        if (_downloading) ...[
                          const SizedBox(height: 20),
                          LinearProgressIndicator(value: _progress?.fraction),
                          const SizedBox(height: 8),
                          Text(
                            _progress?.phase == UpdateDownloadPhase.verifying
                                ? 'Verificando el APK…'
                                : _progress == null
                                ? 'Conectando con el servidor…'
                                : '${(_progress!.received / 1048576).toStringAsFixed(1)} MB'
                                      '${_progress!.total == null ? '' : ' / ${(_progress!.total! / 1048576).toStringAsFixed(1)} MB'}',
                            textAlign: TextAlign.center,
                          ),
                          TextButton(
                            onPressed: _downloader.cancel,
                            child: const Text('Cancelar descarga'),
                          ),
                        ],
                        if (_status != null) ...[
                          const SizedBox(height: 16),
                          Text(_status!, textAlign: TextAlign.center),
                        ],
                        if (_launchError != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _launchError!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.error),
                          ),
                        ],
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: _busy ? null : _openDownload,
                          icon: _busy
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download_rounded),
                          label: Text(
                            _downloading
                                ? 'Descargando…'
                                : _installing
                                ? 'Abriendo instalador…'
                                : _opening
                                ? 'Abriendo…'
                                : _apk != null
                                ? 'Instalar actualización'
                                : 'Actualizar ahora',
                          ),
                        ),
                        if (_android && !_busy) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _openBrowserDownload,
                            child: const Text(
                              'Descarga alternativa en navegador',
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(
                                  text: release.downloadUrl.toString(),
                                ),
                              );
                              if (mounted) {
                                setState(
                                  () => _status =
                                      'Enlace copiado. Puedes abrirlo en otro navegador.',
                                );
                              }
                            },
                            child: const Text('Copiar enlace de descarga'),
                          ),
                        ],
                        if (!release.mandatory) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _release = null),
                            child: const Text('Continuar por ahora'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
