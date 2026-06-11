import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_logger.dart';
import '../services/session_service.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';
import 'app_requirements_screen.dart';

class LoginScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onThemeToggle;

  const LoginScreen({
    super.key,
    required this.themeMode,
    required this.onThemeToggle,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _mostrarPassword = false;
  bool _cargando = false;
  bool _assetsPrecargados = false;

  @override
  void initState() {
    super.initState();
    _restaurarSesionGuardada();
  }

  Future<void> _restaurarSesionGuardada() async {
    final usuario = await SessionService().obtenerUsuario();
    if (!mounted) {
      return;
    }

    if (usuario == null) {
      return;
    }

    AppLogger.info('Login', 'Sesion guardada restaurada', {
      'dni': AppLogger.shortId(usuario['dni']?.toString() ?? ''),
    });

    _abrirRequisitos(usuario);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_assetsPrecargados) {
      return;
    }
    _assetsPrecargados = true;
    precacheImage(const AssetImage('assets/fondo1.png'), context);
    precacheImage(const AssetImage('assets/fondo2.png'), context);
    precacheImage(const AssetImage('assets/logo.png'), context);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _continuar() async {
    final identificador = _normalizarIdentificador(_emailController.text);
    final password = _passwordController.text.trim();

    AppLogger.info('Login', 'Intento de login iniciado', {
      'identificador': identificador.isEmpty
          ? 'vacio'
          : _maskIdentificador(identificador),
    });

    if (identificador.isEmpty || password.isEmpty) {
      AppLogger.warning('Login', 'Login cancelado por campos vacios', {
        'identificador_vacio': identificador.isEmpty,
        'password_vacio': password.isEmpty,
      });
      _mostrarError('Completa usuario y contrasena para continuar.');
      return;
    }

    setState(() => _cargando = true);

    try {
      final usuario = await SupabaseService().buscarUsuarioPorCredenciales(
        identificador,
        password,
      );

      if (!mounted) {
        return;
      }

      if (usuario == null) {
        AppLogger.warning('Login', 'Credenciales rechazadas', {
          'identificador': _maskIdentificador(identificador),
        });
        _mostrarError('Credenciales no validas. Verifica tus datos.');
        return;
      }

      AppLogger.info('Login', 'Login exitoso', {
        'dni': AppLogger.shortId(usuario['dni']?.toString() ?? ''),
        'id_tienda': AppLogger.shortId(usuario['id_tienda']?.toString() ?? ''),
      });

      await SessionService().guardarUsuario(usuario);

      if (!mounted) {
        return;
      }

      _abrirRequisitos(usuario);
    } catch (e, st) {
      AppLogger.error('Login', 'Error durante login', e, st, {
        'identificador': _maskIdentificador(identificador),
      });
      if (mounted) {
        _mostrarError(
          'No se pudo iniciar sesion. Revisa tu conexion e intenta de nuevo.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  void _mostrarError(String mensaje) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensaje), backgroundColor: AppPalette.error),
    );
  }

  void _abrirRequisitos(Map<String, dynamic> usuario) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => AppRequirementsScreen(
          usuario: usuario,
          themeMode: widget.themeMode,
          onThemeToggle: widget.onThemeToggle,
        ),
      ),
    );
  }

  String _maskIdentificador(String identificador) {
    if (identificador.contains('@')) {
      return AppLogger.maskEmail(identificador);
    }
    return AppLogger.shortId(identificador);
  }

  String _normalizarIdentificador(String value) {
    final limpio = value.trim();
    if (limpio.contains('@')) {
      return limpio.toLowerCase();
    }
    return limpio;
  }

  void _normalizarCorreoEnCampo(String value) {
    if (!value.contains('@')) {
      return;
    }

    final lower = value.toLowerCase();
    if (lower == value) {
      return;
    }

    final seleccion = _emailController.selection;
    _emailController.value = TextEditingValue(
      text: lower,
      selection: seleccion.copyWith(
        baseOffset: seleccion.baseOffset.clamp(0, lower.length),
        extentOffset: seleccion.extentOffset.clamp(0, lower.length),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          RepaintBoundary(
            child: Image.asset(
              AppTheme.backgroundFor(context),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        Colors.black.withValues(alpha: 0.40),
                        Colors.black.withValues(alpha: 0.62),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.10),
                        Colors.white.withValues(alpha: 0.18),
                      ],
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final availableHeight =
                    constraints.maxHeight -
                    MediaQuery.of(context).viewInsets.bottom;

                return SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    28,
                    18,
                    28,
                    MediaQuery.of(context).viewInsets.bottom + 24,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: availableHeight),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.centerRight,
                              child: IconButton(
                                tooltip: isDark ? 'Modo claro' : 'Modo oscuro',
                                onPressed: widget.onThemeToggle,
                                icon: Icon(
                                  isDark ? Icons.light_mode : Icons.dark_mode,
                                ),
                                style: IconButton.styleFrom(
                                  foregroundColor: AppPalette.turquesaBrillante,
                                  backgroundColor: Colors.white.withValues(
                                    alpha: 0.12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.all(28),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.black.withValues(alpha: 0.42)
                                    : const Color(
                                        0xFFFAF3E9,
                                      ).withValues(alpha: 0.96),
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: isDark
                                      ? AppPalette.turquesaBrillante.withValues(
                                          alpha: 0.22,
                                        )
                                      : Colors.black12,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: isDark
                                        ? Colors.black.withValues(alpha: 0.35)
                                        : Colors.black.withValues(alpha: 0.12),
                                    blurRadius: 28,
                                    offset: const Offset(0, 14),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'REGISTRO',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.bebasNeue(
                                      fontSize: 38,
                                      color: isDark
                                          ? Colors.white
                                          : AppPalette.azulOscuro,
                                      letterSpacing: 3.5,
                                      height: 1.0,
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  const _EtiquetaCampo(texto: 'Correo'),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _emailController,
                                    keyboardType: TextInputType.emailAddress,
                                    textInputAction: TextInputAction.next,
                                    textCapitalization: TextCapitalization.none,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    onChanged: _normalizarCorreoEnCampo,
                                    cursorColor: scheme.primary,
                                    style: TextStyle(
                                      color: isDark
                                          ? Colors.white.withValues(alpha: 0.95)
                                          : Colors.black87,
                                      fontSize: 16,
                                    ),
                                    decoration: _inputDecoration(''),
                                  ),
                                  const SizedBox(height: 16),
                                  const _EtiquetaCampo(texto: 'Contraseña'),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _passwordController,
                                    obscureText: !_mostrarPassword,
                                    textInputAction: TextInputAction.done,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    onSubmitted: (_) =>
                                        _cargando ? null : _continuar(),
                                    cursorColor: scheme.primary,
                                    style: TextStyle(
                                      color: isDark
                                          ? Colors.white.withValues(alpha: 0.95)
                                          : Colors.black87,
                                      fontSize: 16,
                                    ),
                                    decoration: _inputDecoration('').copyWith(
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _mostrarPassword
                                              ? Icons.visibility_off
                                              : Icons.visibility,
                                          color: isDark
                                              ? AppPalette.verdeAzulado
                                              : AppPalette.azulOscuro,
                                        ),
                                        onPressed: () {
                                          setState(
                                            () => _mostrarPassword =
                                                !_mostrarPassword,
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 26),
                                  ElevatedButton(
                                    onPressed: _cargando ? null : _continuar,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor:
                                          AppPalette.turquesaBrillante,
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size.fromHeight(54),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      elevation: 0,
                                    ),
                                    child: _cargando
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              color: Colors.white,
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : Text(
                                            'ENTRAR',
                                            style: GoogleFonts.bebasNeue(
                                              fontSize: 18,
                                              color: Colors.white,
                                              letterSpacing: 1.5,
                                            ),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return InputDecoration(
      filled: true,
      fillColor: isDark
          ? Colors.black.withValues(alpha: 0.28)
          : const Color(0xFFFAF3E9).withValues(alpha: 0.96),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: isDark ? AppTheme.glassBorder(context) : Colors.black12,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      hintText: hint,
      hintStyle: TextStyle(color: isDark ? Colors.white70 : Colors.black45),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }
}

class _EtiquetaCampo extends StatelessWidget {
  final String texto;

  const _EtiquetaCampo({required this.texto});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Text(
      texto,
      style: GoogleFonts.robotoCondensed(
        fontSize: 14,
        color: isDark ? Colors.white70 : Colors.black87,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
      ),
    );
  }
}
