import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_version_service.dart';
import '../theme/app_theme.dart';

class AppUpdateGate extends StatefulWidget {
  final Widget child;

  const AppUpdateGate({super.key, required this.child});

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate>
    with WidgetsBindingObserver {
  AppReleaseInfo? _release;
  bool _checking = true;
  bool _opening = false;
  String? _launchError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkForUpdate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _release != null && !_opening) {
      _checkForUpdate();
    }
  }

  Future<void> _checkForUpdate() async {
    if (mounted) {
      setState(() => _checking = true);
    }
    final release = await AppVersionService().verificarActualizacion();
    if (!mounted) {
      return;
    }
    setState(() {
      _release = release;
      _checking = false;
      _launchError = null;
    });
  }

  Future<void> _openDownload() async {
    final release = _release;
    if (release == null || _opening) {
      return;
    }
    setState(() {
      _opening = true;
      _launchError = null;
    });
    try {
      final opened = await launchUrl(
        release.downloadUrl,
        mode: LaunchMode.externalApplication,
      );
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
                          onPressed: _opening ? null : _openDownload,
                          icon: _opening
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download_rounded),
                          label: Text(
                            _opening ? 'Abriendo...' : 'Actualizar ahora',
                          ),
                        ),
                        if (!release.mandatory) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => setState(() => _release = null),
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
