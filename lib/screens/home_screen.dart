import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/firestore_service.dart';
import '../services/qr_service.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  final Map<String, dynamic> usuario;
  final bool abrirScannerAutomatico;

  const HomeScreen({
    super.key,
    required this.usuario,
    this.abrirScannerAutomatico = false,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _auth = LocalAuthentication();
  final _firestoreService = FirestoreService();
  final _qrService = QRService();

  Map<String, dynamic>? _asistenciaHoy;
  Map<String, dynamic>? _horarioHoy;
  List<Map<String, dynamic>> _historialActual = [];
  List<Map<String, dynamic>> _historialAnterior = [];
  bool _escaneando = false;
  bool _procesando = false;
  bool _qrProcesado = false;
  int _mesSeleccionado = 0;
  int? _diaSeleccionado;

  static const _ordenMarcaciones = [
    ('Entrada', 'hora_inicio', 'entrada'),
    ('Receso Inicio', 'inicio_receso', 'refrigerio_inicio'),
    ('Receso Fin', 'final_receso', 'refrigerio_fin'),
    ('Salida', 'hora_final', 'salida'),
  ];

  @override
  void initState() {
    super.initState();
    _cargarDatos();
    if (widget.abrirScannerAutomatico) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() => _escaneando = true);
        }
      });
    }
  }

  Future<void> _cargarDatos() async {
    await Future.wait([
      _cargarAsistencia(),
      _cargarPerfilUsuario(),
      _cargarHistorial(),
    ]);
  }

  Future<void> _cargarAsistencia() async {
    final data = await _firestoreService.obtenerAsistenciaHoy(
      widget.usuario['id_trabajador']?.toString() ?? '',
      idSede: widget.usuario['id_sede']?.toString(),
    );

    if (mounted) {
      setState(() => _asistenciaHoy = data);
    }
  }

  Future<void> _cargarPerfilUsuario() async {
    final horarios = widget.usuario['horario'] as Map<String, dynamic>?;
    final diasSemana = [
      'lunes',
      'martes',
      'miercoles',
      'jueves',
      'viernes',
      'sabado',
      'domingo',
    ];
    final diaHoy = diasSemana[DateTime.now().weekday - 1];
    final horarioDia = horarios?[diaHoy] as Map<String, dynamic>?;

    if (mounted) {
      setState(
        () => _horarioHoy = horarioDia == null
            ? null
            : Map<String, dynamic>.from(horarioDia),
      );
    }
  }

  Future<void> _cargarHistorial() async {
    final idTrabajador = widget.usuario['id_trabajador']?.toString() ?? '';
    final idSede = widget.usuario['id_sede']?.toString();

    if (idTrabajador.isEmpty || idSede == null || idSede.isEmpty) {
      return;
    }

    final ahora = DateTime.now();
    final mesActual = DateTime(ahora.year, ahora.month, 1);
    final mesAnterior = DateTime(ahora.year, ahora.month - 1, 1);

    final historialActual = await _firestoreService
        .obtenerHistorialAsistenciasMes(
          idTrabajador,
          mesActual,
          idSede: idSede,
        );
    final historialAnterior = await _firestoreService
        .obtenerHistorialAsistenciasMes(
          idTrabajador,
          mesAnterior,
          idSede: idSede,
        );

    if (mounted) {
      setState(() {
        _historialActual = historialActual;
        _historialAnterior = historialAnterior;
      });
    }
  }

  Future<void> _procesarQR(String qrValue) async {
    if (_procesando || _qrProcesado) {
      return;
    }

    setState(() {
      _procesando = true;
      _qrProcesado = true;
    });

    final resultado = await _qrService.validarQR(qrValue, widget.usuario);
    if (!resultado.valido ||
        resultado.qrValidado == null ||
        resultado.ubicacion == null) {
      _mostrarMensaje(
        resultado.mensajeError ?? 'No se pudo validar el QR.',
        esError: true,
      );
      _reiniciarScanner();
      return;
    }

    final autenticado = await _confirmarBiometria(resultado.qrValidado!);
    if (!autenticado) {
      _mostrarMensaje('No se pudo confirmar la huella digital.', esError: true);
      _reiniciarScanner();
      return;
    }

    try {
      final marcacion = await _firestoreService.registrarMarcacion(
        widget.usuario,
        resultado.qrValidado!,
        ubicacion: resultado.ubicacion!,
      );

      await _cargarDatos();
      _mostrarMensaje(
        marcacion.startsWith('Ya')
            ? marcacion
            : '${_nombreMarcacion(marcacion)} registrada en ${resultado.qrValidado!.nombreTienda}',
        esError: marcacion.startsWith('Ya'),
      );
    } catch (e, st) {
      debugPrint('HomeScreen._procesarQR error: $e');
      debugPrint('$st');
      _mostrarMensaje(
        'No se pudo registrar la marcación en este momento. Intenta de nuevo.',
        esError: true,
      );
    }

    if (mounted) {
      setState(() {
        _procesando = false;
        _escaneando = false;
      });
    }

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _qrProcesado = false);
      }
    });
  }

  Future<bool> _confirmarBiometria(QRValidado qrValidado) async {
    try {
      return await _auth.authenticate(
        localizedReason:
            'Confirma tu huella para marcar en ${qrValidado.nombreSede} - ${qrValidado.nombreTienda}',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } on PlatformException catch (e) {
      _mostrarMensaje(_mensajeBiometriaError(e), esError: true);
      return false;
    } catch (e, st) {
      debugPrint('HomeScreen._confirmarBiometria error: $e');
      debugPrint('$st');
      _mostrarMensaje(
        'No se pudo confirmar la huella digital. Intenta nuevamente.',
        esError: true,
      );
      return false;
    }
  }

  String _mensajeBiometriaError(PlatformException e) {
    final codigo = e.code.toLowerCase();
    if (codigo.contains('notavailable') || codigo.contains('notenrolled')) {
      return 'No hay biometría disponible en este dispositivo.';
    }
    if (codigo.contains('lockedout') ||
        codigo.contains('permanentlylockedout')) {
      return 'La biometría está bloqueada. Desbloquea el teléfono e intenta de nuevo.';
    }
    return 'No se pudo verificar la biometía. Intenta nuevamente.';
  }

  void _reiniciarScanner() {
    if (!mounted) {
      return;
    }

    setState(() {
      _procesando = false;
      _qrProcesado = false;
      _escaneando = false;
    });
  }

  String _nombreMarcacion(String key) {
    const nombres = {
      'entrada': 'Entrada',
      'refrigerio_inicio': 'Inicio de receso',
      'refrigerio_fin': 'Fin de receso',
      'salida': 'Salida',
    };
    return nombres[key] ?? key;
  }

  void _mostrarMensaje(String msg, {bool esError = false}) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
        backgroundColor: esError
            ? const Color(0xFFE63232)
            : const Color(0xFF4ECA8B),
      ),
    );
  }

  Future<void> _cerrarSesion() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          'Cerrar sesion',
          style: GoogleFonts.bebasNeue(
            color: Colors.white,
            fontSize: 22,
            letterSpacing: 1,
          ),
        ),
        content: Text(
          'Seguro que quieres cerrar sesion?',
          style: GoogleFonts.robotoCondensed(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Cerrar sesion',
              style: TextStyle(color: Color(0xFFE63232)),
            ),
          ),
        ],
      ),
    );

    if (confirmar == true && mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  int _marcacionesCompletadas(Map<String, dynamic>? data) {
    if (data == null) {
      return 0;
    }

    return _ordenMarcaciones.where((item) => data[item.$3] != null).length;
  }

  String _horaProgramada(String horarioKey) {
    final valor = _horarioHoy?[horarioKey]?.toString();
    if (valor == null || valor.isEmpty) {
      return '--:--';
    }
    return valor;
  }

  String _horaMarcada(Map<String, dynamic>? data, String marcacionKey) {
    final marca = data?[marcacionKey];
    if (marca == null) {
      return '--:--';
    }

    if (marca is Map<String, dynamic>) {
      final hora = marca['hora'];
      if (hora is String && hora.isNotEmpty) {
        return hora;
      }

      final ts = marca['marca'];
      if (ts is Timestamp) {
        return DateFormat('HH:mm').format(ts.toDate());
      }
    }

    return '--:--';
  }

  Widget _buildHorarioMarcacionesCard() {
    final completadas = _marcacionesCompletadas(_asistenciaHoy);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.38),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'HORARIO Y MARCACIONES',
                style: GoogleFonts.robotoCondensed(
                  fontSize: 13,
                  color: Colors.white.withOpacity(0.92),
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '$completadas/4 completas',
                style: GoogleFonts.bebasNeue(
                  fontSize: 18,
                  color: completadas == 4
                      ? const Color(0xFF4ECA8B)
                      : Colors.white,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ..._ordenMarcaciones.map((item) {
            final marcada = _asistenciaHoy?[item.$3] != null;
            final horaProgramada = _horaProgramada(item.$2);
            final horaMarcada = _horaMarcada(_asistenciaHoy, item.$3);

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: marcada
                    ? const Color(0xFF4ECA8B).withOpacity(0.14)
                    : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: marcada
                      ? const Color(0xFF4ECA8B)
                      : Colors.white.withOpacity(0.08),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: marcada ? const Color(0xFF4ECA8B) : Colors.white24,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.$1,
                          style: GoogleFonts.robotoCondensed(
                            fontSize: 14,
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Horario: $horaProgramada',
                          style: GoogleFonts.robotoCondensed(
                            fontSize: 12,
                            color: Colors.white.withOpacity(0.88),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        marcada ? 'Marcado' : 'Pendiente',
                        style: GoogleFonts.robotoCondensed(
                          fontSize: 12,
                          color: marcada
                              ? const Color(0xFF4ECA8B)
                              : Colors.white.withOpacity(0.88),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        marcada ? horaMarcada : '--:--',
                        style: GoogleFonts.bebasNeue(
                          fontSize: 20,
                          color: marcada
                              ? const Color(0xFF4ECA8B)
                              : Colors.white38,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDetalleMarcacion(
    String nombre,
    Map<String, dynamic>? data,
    String key,
  ) {
    final hora = _horaMarcada(data, key);
    final marcada = data?[key] != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              nombre,
              style: GoogleFonts.robotoCondensed(
                fontSize: 12,
                color: Colors.white70,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            marcada ? hora : 'Pendiente',
            style: GoogleFonts.bebasNeue(
              fontSize: 16,
              color: marcada ? const Color(0xFF4ECA8B) : Colors.white38,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarioHistorial() {
    final ahora = DateTime.now();
    final datos = _mesSeleccionado == 0 ? _historialActual : _historialAnterior;
    final mes = _mesSeleccionado == 0
        ? DateTime(ahora.year, ahora.month)
        : DateTime(ahora.year, ahora.month - 1);

    final primerDia = DateTime(mes.year, mes.month, 1);
    final ultimoDia = DateTime(mes.year, mes.month + 1, 0);
    final diasDelMes = ultimoDia.day;
    final diaInicio = primerDia.weekday;

    final diasConAsistencia = <int>{};
    for (final reg in datos) {
      final fecha = reg['__fecha'] as DateTime;
      if (fecha.year == mes.year && fecha.month == mes.month) {
        diasConAsistencia.add(fecha.day);
      }
    }

    Map<String, dynamic>? detallesDia;
    if (_diaSeleccionado != null) {
      for (final reg in datos) {
        final fecha = reg['__fecha'] as DateTime;
        if (fecha.year == mes.year &&
            fecha.month == mes.month &&
            fecha.day == _diaSeleccionado) {
          detallesDia = reg;
          break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: _mesSeleccionado == 0
                  ? () => setState(() {
                      _mesSeleccionado = -1;
                      _diaSeleccionado = null;
                    })
                  : null,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.chevron_left,
                  color: _mesSeleccionado == 0
                      ? Colors.white54
                      : Colors.white30,
                ),
              ),
            ),
            Text(
              DateFormat('MMMM yyyy', 'es').format(mes),
              style: GoogleFonts.bebasNeue(
                fontSize: 16,
                color: Colors.white,
                letterSpacing: 1,
              ),
            ),
            GestureDetector(
              onTap: _mesSeleccionado == -1
                  ? () => setState(() {
                      _mesSeleccionado = 0;
                      _diaSeleccionado = null;
                    })
                  : null,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.chevron_right,
                  color: _mesSeleccionado == -1
                      ? Colors.white54
                      : Colors.white30,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: ['Lun', 'Mar', 'Mie', 'Jue', 'Vie', 'Sab', 'Dom']
                    .map(
                      (d) => Text(
                        d,
                        style: GoogleFonts.robotoCondensed(
                          fontSize: 10,
                          color: Colors.white.withOpacity(0.6),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  childAspectRatio: 1,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: diaInicio - 1 + diasDelMes,
                itemBuilder: (_, i) {
                  if (i < diaInicio - 1) {
                    return const SizedBox.shrink();
                  }

                  final dia = i - diaInicio + 2;
                  final tieneAsistencia = diasConAsistencia.contains(dia);
                  final esSeleccionado = _diaSeleccionado == dia;

                  return GestureDetector(
                    onTap: () {
                      setState(
                        () => _diaSeleccionado = esSeleccionado ? null : dia,
                      );
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: esSeleccionado
                            ? const Color(0xFFE63232)
                            : tieneAsistencia
                            ? const Color(0xFF4ECA8B).withOpacity(0.3)
                            : Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: esSeleccionado
                              ? const Color(0xFFE63232)
                              : tieneAsistencia
                              ? const Color(0xFF4ECA8B)
                              : Colors.white.withOpacity(0.08),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          dia.toString(),
                          style: GoogleFonts.bebasNeue(
                            fontSize: 12,
                            color: tieneAsistencia || esSeleccionado
                                ? Colors.white
                                : Colors.white70,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        if (detallesDia != null) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE63232)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Detalles del $_diaSeleccionado de ${DateFormat('MMMM', 'es').format(mes)}',
                  style: GoogleFonts.bebasNeue(
                    fontSize: 14,
                    color: Colors.white,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 8),
                _buildDetalleMarcacion('Entrada', detallesDia, 'entrada'),
                _buildDetalleMarcacion(
                  'Receso Inicio',
                  detallesDia,
                  'refrigerio_inicio',
                ),
                _buildDetalleMarcacion(
                  'Receso Fin',
                  detallesDia,
                  'refrigerio_fin',
                ),
                _buildDetalleMarcacion('Salida', detallesDia, 'salida'),
              ],
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Image.asset(
            'assets/fondo.png',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
          Container(color: Colors.black.withOpacity(0.58)),
          if (_escaneando)
            Stack(
              children: [
                MobileScanner(
                  onDetect: (capture) {
                    final barcode = capture.barcodes.firstOrNull;
                    final rawValue = barcode?.rawValue;
                    if (rawValue != null) {
                      _procesarQR(rawValue);
                    }
                  },
                ),
                Positioned(
                  top: 60,
                  left: 20,
                  child: IconButton(
                    onPressed: () {
                      setState(() {
                        _escaneando = false;
                        _qrProcesado = false;
                        _procesando = false;
                      });
                    },
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
                Center(
                  child: Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: const Color(0xFFE63232),
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                if (_procesando)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFFE63232),
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 100,
                  left: 0,
                  right: 0,
                  child: Text(
                    'Apunta al QR de la tienda',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.robotoCondensed(
                      fontSize: 17,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      shadows: const [
                        Shadow(color: Colors.black87, blurRadius: 12),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          if (!_escaneando)
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Bienvenido',
                                style: GoogleFonts.robotoCondensed(
                                  fontSize: 12,
                                  color: Colors.white.withOpacity(0.88),
                                  letterSpacing: 1,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.usuario['nombre_trabajador']
                                        ?.toString() ??
                                    'Trabajador',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                softWrap: true,
                                style: GoogleFonts.bebasNeue(
                                  fontSize: 24,
                                  color: Colors.white,
                                  letterSpacing: 1,
                                  shadows: const [
                                    Shadow(
                                      color: Colors.black87,
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                              ),
                              if ((widget.usuario['area']?.toString() ?? '')
                                  .isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  widget.usuario['area']?.toString() ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.robotoCondensed(
                                    fontSize: 13,
                                    color: Colors.white,
                                    letterSpacing: 0.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFE63232,
                                  ).withOpacity(0.15),
                                  border: Border.all(
                                    color: const Color(0xFFE63232),
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  widget.usuario['codigo']?.toString() ?? '',
                                  style: GoogleFonts.bebasNeue(
                                    fontSize: 14,
                                    color: const Color(0xFFE63232),
                                    letterSpacing: 1,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                              const SizedBox(width: 8),
                              if ((widget.usuario['registro_huella'] == true ||
                                  widget.usuario['biometria_registrada'] ==
                                      true)) ...[
                                GestureDetector(
                                  onTap: () async {
                                    final confirmar = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        backgroundColor: Colors.grey[900],
                                        title: Text(
                                          'Desvincular huella',
                                          style: GoogleFonts.bebasNeue(
                                            color: Colors.white,
                                          ),
                                        ),
                                        content: Text(
                                          '¿Deseas desvincular la huella de este dispositivo para este usuario?',
                                          style: GoogleFonts.robotoCondensed(
                                            color: Colors.white70,
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, false),
                                            child: const Text(
                                              'Cancelar',
                                              style: TextStyle(
                                                color: Colors.grey,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: const Text(
                                              'Desvincular',
                                              style: TextStyle(
                                                color: Color(0xFFE63232),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );

                                    if (confirmar != true) return;

                                    try {
                                      final idTrab =
                                          widget.usuario['id_trabajador']
                                              ?.toString() ??
                                          '';
                                      final deviceId = await _firestoreService
                                          .obtenerDeviceIdActual();
                                      await _firestoreService
                                          .desvincularDeviceId(
                                            idTrab,
                                            deviceId,
                                          );
                                      if (mounted) {
                                        setState(() {
                                          widget.usuario['registro_huella'] =
                                              false;
                                          widget.usuario['biometria_registrada'] =
                                              false;
                                          widget.usuario.remove('device_id');
                                          final devices =
                                              widget.usuario['devices']
                                                  as Map<String, dynamic>?;
                                          devices?.remove(deviceId);
                                        });
                                        _mostrarMensaje(
                                          'Dispositivo desvinculado correctamente.',
                                        );
                                      }
                                    } catch (e) {
                                      _mostrarMensaje(
                                        e.toString(),
                                        esError: true,
                                      );
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.04),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(
                                      Icons.link_off,
                                      color: Colors.white54,
                                      size: 18,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              GestureDetector(
                                onTap: _cerrarSesion,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.15),
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.logout,
                                    color: Colors.white54,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap: () => setState(() => _escaneando = true),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE63232),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFFE63232),
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  'ESCANEAR QR PARA MARCAR',
                                  style: GoogleFonts.bebasNeue(
                                    fontSize: 18,
                                    color: Colors.white,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          _buildHorarioMarcacionesCard(),
                          const SizedBox(height: 20),
                          Text(
                            'HISTORIAL',
                            style: GoogleFonts.robotoCondensed(
                              fontSize: 12,
                              color: Colors.white.withOpacity(0.88),
                              letterSpacing: 1,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _buildCalendarioHistorial(),
                          const SizedBox(height: 40),
                        ],
                      ),
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
