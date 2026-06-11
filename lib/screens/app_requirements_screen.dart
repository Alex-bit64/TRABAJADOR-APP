import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_requirements_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

class AppRequirementsScreen extends StatefulWidget {
  final Map<String, dynamic> usuario;
  final ThemeMode themeMode;
  final VoidCallback onThemeToggle;
  final bool abrirScannerAutomatico;

  const AppRequirementsScreen({
    super.key,
    required this.usuario,
    required this.themeMode,
    required this.onThemeToggle,
    this.abrirScannerAutomatico = false,
  });

  @override
  State<AppRequirementsScreen> createState() => _AppRequirementsScreenState();
}

class _AppRequirementsScreenState extends State<AppRequirementsScreen>
    with WidgetsBindingObserver {
  final _requirementsService = AppRequirementsService();
  AppRequirementsResult? _result;
  bool _checking = true;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkRequirements(requestPermissions: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_navigated) {
      _checkRequirements();
    }
  }

  Future<void> _checkRequirements({bool requestPermissions = false}) async {
    if (!mounted) {
      return;
    }

    setState(() => _checking = true);
    final result = await _requirementsService.check(
      requestPermissions: requestPermissions,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _result = result;
      _checking = false;
    });

    if (result.ready) {
      _goHome();
    }
  }

  Future<void> _openSettings() async {
    await _requirementsService.openRelevantSettings(_result);
  }

  void _goHome() {
    if (_navigated || !mounted) {
      return;
    }
    _navigated = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => HomeScreen(
          usuario: widget.usuario,
          themeMode: widget.themeMode,
          onThemeToggle: widget.onThemeToggle,
          abrirScannerAutomatico: widget.abrirScannerAutomatico,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pending = _result?.pending ?? const <AppRequirementStatus>[];
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          Image.asset(
            AppTheme.backgroundFor(context),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
          Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.58)
                : Colors.white.withValues(alpha: 0.22),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppTheme.glassSurface(context),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.glassBorder(context)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'REQUISITOS DEL APP',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.bebasNeue(
                            fontSize: 28,
                            color: scheme.onSurface,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Antes de entrar al menu principal necesitamos internet, GPS y camara activos.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.robotoCondensed(
                            fontSize: 14,
                            color: scheme.onSurface.withValues(alpha: 0.76),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 18),
                        if (_checking)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 28),
                            child: Center(
                              child: CircularProgressIndicator(
                                color: AppPalette.turquesaBrillante,
                              ),
                            ),
                          )
                        else if (pending.isEmpty)
                          _RequirementRow(
                            icon: Icons.check_circle,
                            title: 'Todo listo',
                            message: 'Entrando al menu principal...',
                            color: AppPalette.verdeAzulado,
                          )
                        else
                          ...pending.map(
                            (item) => _RequirementRow(
                              icon: item.blocked
                                  ? Icons.settings
                                  : Icons.error_outline,
                              title: item.title,
                              message: item.message,
                              color: item.blocked
                                  ? AppPalette.alerta
                                  : AppPalette.error,
                            ),
                          ),
                        const SizedBox(height: 18),
                        ElevatedButton(
                          onPressed: _checking
                              ? null
                              : () => _checkRequirements(
                                  requestPermissions: true,
                                ),
                          child: Text(
                            _checking ? 'VERIFICANDO' : 'VERIFICAR Y CONTINUAR',
                            style: GoogleFonts.bebasNeue(
                              fontSize: 18,
                              color: Colors.white,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        if ((_result?.hasBlockedPending ?? false) &&
                            !_checking) ...[
                          const SizedBox(height: 10),
                          TextButton(
                            onPressed: _openSettings,
                            child: Text(
                              'ABRIR AJUSTES',
                              style: GoogleFonts.bebasNeue(
                                fontSize: 16,
                                color: scheme.secondary,
                                letterSpacing: 1,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RequirementRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Color color;

  const _RequirementRow({
    required this.icon,
    required this.title,
    required this.message,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.48)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.robotoCondensed(
                    fontSize: 14,
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: GoogleFonts.robotoCondensed(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.74),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
