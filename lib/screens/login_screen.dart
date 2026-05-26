import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/firestore_service.dart';
import '../services/biometric_store.dart';
import 'biometric_screen.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _mostrarPassword = false;
  bool _cargando = false;
  final _biometricStore = BiometricStore();
  bool _tryingBiometric = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_tryBiometricAutoLogin);
  }

  Future<void> _tryBiometricAutoLogin() async {
    if (_tryingBiometric) return;
    _tryingBiometric = true;
    try {
      final keys = await _biometricStore.getSavedProfilesKeys();
      if (keys.isEmpty) return;

      final profile = await _biometricStore.readProfileWithBiometrics(
        keys.first,
        reason: 'Inicia sesión con tu huella',
      );

      if (profile == null) return;

      final correo = profile['correo'] ?? '';
      final password = profile['password'] ?? '';
      if (correo.isEmpty || password.isEmpty) return;

      _emailController.text = correo;
      _passwordController.text = password;
      await _continuar();
    } finally {
      _tryingBiometric = false;
    }
  }

  Future<void> _continuar() async {
    final correo = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (correo.isEmpty || password.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Completa correo y contraseña para continuar.'),
            backgroundColor: Color(0xFFE63232),
          ),
        );
      }
      return;
    }

    setState(() => _cargando = true);

    try {
      final svc = FirestoreService();
      final usuario = await svc.buscarUsuarioPorCredenciales(correo, password);

      if (usuario == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Usuario no encontrado. Contacta al administrador.',
              ),
              backgroundColor: Color(0xFFE63232),
            ),
          );
        }
        return;
      }

      if (!mounted) {
        return;
      }

      final biometriaRegistrada =
          usuario['biometria_registrada'] == true ||
          usuario['registro_huella'] == true;

      if (biometriaRegistrada) {
        final autenticado = await svc.verificarBiometriaLogin(usuario);
        if (!mounted) {
          return;
        }

        if (!autenticado) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Huella no verificada.'),
                backgroundColor: Color(0xFFE63232),
              ),
            );
          }
          return;
        }
      } else {
        // Si no tiene biometría registrada, pedir registro en la pantalla de biometría.
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => BiometricScreen(usuario: usuario),
            ),
          );
        }
        return;
      }
      // Guardar perfil localmente cifrado para futuros inicios por huella
      try {
        if (await _biometricStore.canCheckBiometrics()) {
          final idTrab = usuario['id_trabajador']?.toString() ?? '';
          if (idTrab.isNotEmpty) {
            await _biometricStore.saveProfile(
              idTrabajador: idTrab,
              correo: correo,
              password: password,
            );
          }
        }
      } catch (_) {
        // Silenciar errores de almacenamiento local
      }
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomeScreen(usuario: usuario)),
      );
    } catch (e, st) {
      debugPrint('LoginScreen._continuar error: $e');
      debugPrint('$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No se pudo iniciar sesión. Revisa tu conexión e intenta de nuevo.',
            ),
            backgroundColor: Color(0xFFE63232),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Image.asset(
            'assets/fondo.png',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                28,
                24,
                28,
                MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 40),
                  Text(
                    'ALMACEN\nDE REMATES',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.bebasNeue(
                      fontSize: 42,
                      color: Colors.white,
                      letterSpacing: 3,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 36),
                  Text(
                    'Correo',
                    style: GoogleFonts.robotoCondensed(
                      fontSize: 14,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    cursorColor: Colors.white,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.black,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.white54),
                      ),
                      hintText: 'correo@ejemplo.com',
                      hintStyle: TextStyle(color: Colors.white54),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Contrasena',
                    style: GoogleFonts.robotoCondensed(
                      fontSize: 14,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passwordController,
                    obscureText: !_mostrarPassword,
                    cursorColor: Colors.white,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.black,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.white54),
                      ),
                      hintText: 'Contrasena',
                      hintStyle: TextStyle(color: Colors.white54),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _mostrarPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                          color: Colors.white70,
                        ),
                        onPressed: () {
                          setState(() => _mostrarPassword = !_mostrarPassword);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  GestureDetector(
                    onTap: _cargando ? null : _continuar,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE63232),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
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
                                'Entrar',
                                style: GoogleFonts.bebasNeue(
                                  fontSize: 18,
                                  color: Colors.white,
                                  letterSpacing: 1,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
