import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:local_auth/local_auth.dart';

import '../services/firestore_service.dart';
import 'home_screen.dart';

class BiometricScreen extends StatefulWidget {
  final Map<String, dynamic> usuario;

  const BiometricScreen({super.key, required this.usuario});

  @override
  State<BiometricScreen> createState() => _BiometricScreenState();
}

class _BiometricScreenState extends State<BiometricScreen> {
  final _auth = LocalAuthentication();
  final _firestoreService = FirestoreService();
  bool _procesando = false;

  Future<void> _registrarHuella() async {
    setState(() => _procesando = true);

    try {
      final disponible = await _auth.canCheckBiometrics;
      if (!disponible) {
        _mostrarError('La biometría no está disponible en este dispositivo.');
        return;
      }

      final autenticado = await _auth.authenticate(
        localizedReason: 'Registra tu huella para vincular este dispositivo',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );

      if (!autenticado) {
        _mostrarError('Autenticación cancelada. Intenta de nuevo.');
        return;
      }

      final idTrabajador = widget.usuario['id_trabajador']?.toString() ?? '';
      final idDispositivo = await _firestoreService.obtenerDeviceIdActual();

      await _firestoreService.guardarDeviceId(idTrabajador, idDispositivo);

      final usuarioActualizado = Map<String, dynamic>.from(widget.usuario);
      usuarioActualizado['registro_huella'] = true;
      usuarioActualizado['biometria_registrada'] = true;
      usuarioActualizado['devices'] = {
        idDispositivo: {'registered_at': DateTime.now().toIso8601String()},
      };

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => HomeScreen(
              usuario: usuarioActualizado,
              abrirScannerAutomatico: true,
            ),
          ),
        );
      }
    } on PlatformException catch (e) {
      _mostrarError(_mensajeBiometriaError(e));
    } catch (e, st) {
      debugPrint('BiometricScreen._registrarHuella error: $e');
      debugPrint('$st');
      final msg = e is Exception
          ? e.toString().replaceFirst('Exception: ', '')
          : 'No se pudo registrar la huella. Intenta nuevamente.';
      _mostrarError(msg);
    } finally {
      if (mounted) {
        setState(() => _procesando = false);
      }
    }
  }

  String _mensajeBiometriaError(PlatformException e) {
    final codigo = e.code.toLowerCase();
    if (codigo.contains('notavailable') || codigo.contains('notenrolled')) {
      return 'No hay biometría configurada en este dispositivo.';
    }
    if (codigo.contains('lockedout') ||
        codigo.contains('permanentlylockedout')) {
      return 'La biometría está bloqueada. Desbloquea el teléfono e intenta de nuevo.';
    }
    return 'No se pudo completar la autenticación biométrica. Intenta nuevamente.';
  }

  void _mostrarError(String msg) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFFE63232)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nombreTrabajador =
        widget.usuario['nombre_trabajador'] ?? 'Trabajador';
    final idTrabajador = widget.usuario['id_trabajador'] ?? '';

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
                      fontSize: 36,
                      color: Colors.white,
                      letterSpacing: 3,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      border: Border.all(color: Colors.white.withOpacity(0.12)),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          idTrabajador,
                          style: GoogleFonts.robotoCondensed(
                            fontSize: 13,
                            color: const Color(0xFFE63232),
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          nombreTrabajador,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.bebasNeue(
                            fontSize: 22,
                            color: Colors.white,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFE63232),
                        width: 2,
                      ),
                      color: const Color(0xFFE63232).withOpacity(0.08),
                    ),
                    child: const Icon(
                      Icons.fingerprint,
                      size: 56,
                      color: Color(0xFFE63232),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'PRIMER ACCESO',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.bebasNeue(
                      fontSize: 28,
                      color: Colors.white,
                      letterSpacing: 3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Registra tu huella digital para vincular este dispositivo. Solo se hace una vez.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.robotoCondensed(
                      fontSize: 13,
                      color: Colors.white60,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 30),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _procesando ? null : _registrarHuella,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE63232),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _procesando
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : Text(
                              'REGISTRAR HUELLA',
                              style: GoogleFonts.robotoCondensed(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                letterSpacing: 2,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Tu biometria nunca sale de este dispositivo',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.robotoCondensed(
                      fontSize: 10,
                      color: Colors.white24,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
