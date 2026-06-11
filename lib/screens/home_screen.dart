import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/app_logger.dart';
import '../services/qr_service.dart';
import '../services/session_service.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  final Map<String, dynamic> usuario;
  final bool abrirScannerAutomatico;
  final ThemeMode themeMode;
  final VoidCallback onThemeToggle;

  const HomeScreen({
    super.key,
    required this.usuario,
    required this.themeMode,
    required this.onThemeToggle,
    this.abrirScannerAutomatico = false,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _platform = MethodChannel('trabajador_app/platform');

  final _supabaseService = SupabaseService();
  final _qrService = QRService();
  static const Duration _cooldownMarcacion = Duration(minutes: 10);
  static const String _origenHorarioManual = 'manual_sin_horario';
  static const Map<String, Map<String, dynamic>> _horariosPorJornada = {
    'fulltime': {
      'tipo_jornada': 'fulltime',
      'nombre_jornada': 'Full time',
      'origen': _origenHorarioManual,
      'horario_entrada': null,
      'horario_inicio_receso': null,
      'horario_fin_receso': null,
      'horario_salida': null,
    },
    'parttime': {
      'tipo_jornada': 'parttime',
      'nombre_jornada': 'Part time',
      'origen': _origenHorarioManual,
      'horario_entrada': null,
      'horario_inicio_receso': null,
      'horario_fin_receso': null,
      'horario_salida': null,
    },
  };

  Map<String, dynamic>? _asistenciaHoy;
  Map<String, dynamic>? _horarioHoy;
  List<Map<String, dynamic>> _historialActual = [];
  List<Map<String, dynamic>> _historialAnterior = [];
  bool _escaneando = false;
  bool _procesando = false;
  bool _qrProcesado = false;
  bool _enCooldown = false;
  Duration _cooldownRestante = Duration.zero;
  Timer? _cooldownTimer;
  int _mesSeleccionado = 0;
  int? _diaSeleccionado;
  bool _selectorJornadaAbierto = false;

  static const _ordenMarcaciones = [
    ('Entrada', 'horario_entrada'),
    ('Inicio de receso', 'horario_inicio_receso'),
    ('Fin de receso', 'horario_fin_receso'),
    ('Salida', 'horario_salida'),
  ];

  String get _dni =>
      widget.usuario['dni']?.toString() ??
      widget.usuario['id_trabajador']?.toString() ??
      '';

  @override
  void initState() {
    super.initState();
    AppLogger.info('Home', 'Home iniciado', {
      'dni': AppLogger.shortId(_dni),
      'id_tienda': AppLogger.shortId(
        widget.usuario['id_tienda']?.toString() ?? '',
      ),
      'scanner_auto': widget.abrirScannerAutomatico,
    });
    _cargarDatos();
    if (widget.abrirScannerAutomatico) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() => _escaneando = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _cargarDatos() async {
    AppLogger.info('Home', 'Carga de datos iniciada', {
      'dni': AppLogger.shortId(_dni),
    });

    await Future.wait([
      _cargarAsistencia(),
      _cargarHorario(),
      _cargarHistorial(),
    ]);

    AppLogger.info('Home', 'Carga de datos finalizada', {
      'dni': AppLogger.shortId(_dni),
    });

    await _verificarHorarioDelDia();
  }

  Future<void> _cargarAsistencia() async {
    if (_dni.isEmpty) {
      AppLogger.warning('Home', 'No se carga asistencia porque DNI esta vacio');
      return;
    }

    final data = await _supabaseService.obtenerAsistenciaHoy(_dni);
    AppLogger.info('Home', 'Asistencia cargada', {
      'dni': AppLogger.shortId(_dni),
      'existe': data != null,
    });
    if (mounted) {
      setState(() => _asistenciaHoy = data);
      _actualizarCooldownDesdeAsistencia(data);
    }
  }

  Future<void> _cargarHorario() async {
    if (_dni.isEmpty) {
      AppLogger.warning('Home', 'No se carga horario porque DNI esta vacio');
      return;
    }

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
    final horario = await _supabaseService.obtenerHorarioTrabajador(
      _dni,
      diaSemana: diaHoy,
    );

    AppLogger.info('Home', 'Horario cargado', {
      'dni': AppLogger.shortId(_dni),
      'dia': diaHoy,
      'existe': horario != null,
    });
    if (mounted) {
      setState(() => _horarioHoy = horario);
    }
  }

  Future<void> _verificarHorarioDelDia() async {
    if (!mounted || _dni.isEmpty || _horarioHoy != null) {
      return;
    }

    final horarioGuardado = await SessionService().obtenerHorarioManual(
      _dni,
      DateTime.now(),
    );
    if (horarioGuardado != null) {
      AppLogger.info('Home', 'Horario manual restaurado', {
        'dni': AppLogger.shortId(_dni),
        'tipo': horarioGuardado['tipo_jornada']?.toString() ?? '',
      });
      if (mounted) {
        setState(() => _horarioHoy = horarioGuardado);
      }
      await _supabaseService.aplicarJornadaManual(_dni, horarioGuardado);
      await Future.wait([_cargarAsistencia(), _cargarHistorial()]);
      return;
    }

    final horarioInferido = _inferirHorarioManualDesdeAsistencia(
      _asistenciaHoy,
    );
    if (horarioInferido != null) {
      AppLogger.info('Home', 'Horario manual inferido desde asistencia', {
        'dni': AppLogger.shortId(_dni),
        'tipo': horarioInferido['nombre_jornada']?.toString() ?? '',
      });
      await SessionService().guardarHorarioManual(
        _dni,
        DateTime.now(),
        horarioInferido,
      );
      await _supabaseService.aplicarJornadaManual(_dni, horarioInferido);
      if (mounted) {
        setState(() => _horarioHoy = horarioInferido);
      }
      await Future.wait([_cargarAsistencia(), _cargarHistorial()]);
      return;
    }

    if (_selectorJornadaAbierto) {
      return;
    }

    _selectorJornadaAbierto = true;
    final horarioElegido = await _mostrarSelectorJornada();
    _selectorJornadaAbierto = false;

    if (horarioElegido == null || !mounted) {
      return;
    }

    await SessionService().guardarHorarioManual(
      _dni,
      DateTime.now(),
      horarioElegido,
    );
    await _supabaseService.aplicarJornadaManual(_dni, horarioElegido);

    if (mounted) {
      setState(() => _horarioHoy = horarioElegido);
    }
    await Future.wait([_cargarAsistencia(), _cargarHistorial()]);
  }

  Future<void> _cargarHistorial() async {
    if (_dni.isEmpty) {
      AppLogger.warning('Home', 'No se carga historial porque DNI esta vacio');
      return;
    }

    final ahora = DateTime.now();
    final mesActual = DateTime(ahora.year, ahora.month);
    final mesAnterior = DateTime(ahora.year, ahora.month - 1);

    final historialActual = await _supabaseService
        .obtenerHistorialAsistenciasMes(_dni, mesActual);
    final historialAnterior = await _supabaseService
        .obtenerHistorialAsistenciasMes(_dni, mesAnterior);

    if (mounted) {
      AppLogger.info('Home', 'Historial cargado', {
        'dni': AppLogger.shortId(_dni),
        'actual': historialActual.length,
        'anterior': historialAnterior.length,
      });
      setState(() {
        _historialActual = historialActual;
        _historialAnterior = historialAnterior;
      });
    }
  }

  Future<void> _procesarQR(String qrValue) async {
    if (_procesando || _qrProcesado || _enCooldown) {
      AppLogger.warning('Home', 'QR ignorado por estado de scanner', {
        'procesando': _procesando,
        'qr_procesado': _qrProcesado,
        'cooldown': _enCooldown,
      });
      return;
    }

    AppLogger.info('Home', 'QR detectado', {
      'dni': AppLogger.shortId(_dni),
      'raw_length': qrValue.length,
      'raw_preview': _debugPreview(qrValue),
    });

    setState(() {
      _procesando = true;
      _qrProcesado = true;
    });

    final resultado = await _qrService.validarQR(qrValue, widget.usuario);
    if (!resultado.valido ||
        resultado.qrValidado == null ||
        resultado.ubicacion == null) {
      AppLogger.warning('Home', 'QR invalido', {
        'mensaje': resultado.mensajeError ?? 'sin_mensaje',
      });
      _mostrarMensaje(
        resultado.mensajeError ?? 'No se pudo validar el QR.',
        esError: true,
      );
      _reiniciarScanner();
      return;
    }

    try {
      AppLogger.info('Home', 'Registrando marcacion desde QR', {
        'dni': AppLogger.shortId(_dni),
        'id_tienda_qr': AppLogger.shortId(resultado.qrValidado!.idTienda),
      });

      final marcacion = await _supabaseService.registrarMarcacion(
        widget.usuario,
        resultado.qrValidado!,
        ubicacion: resultado.ubicacion!,
        horarioManual: _horarioManualActivo ? _horarioHoy : null,
      );

      await _cargarDatos();
      final enCooldown = marcacion.startsWith('Debes esperar');
      AppLogger.info('Home', 'Marcacion procesada', {
        'dni': AppLogger.shortId(_dni),
        'resultado': marcacion,
        'tienda': resultado.qrValidado!.nombreTienda,
      });
      final marcacionExitosa = _esMarcacionExitosa(marcacion);
      _mostrarMensaje(
        _mensajeMarcacionUsuario(marcacion, resultado.qrValidado!.nombreTienda),
        esError: !marcacionExitosa,
      );

      if (mounted) {
        if (marcacionExitosa) {
          _iniciarCooldown(_cooldownMarcacion);
        } else if (enCooldown) {
          _iniciarCooldown(_extraerEsperaCooldown(marcacion));
        }
      }
    } catch (e, st) {
      AppLogger.error('Home', 'Error procesando QR', e, st, {
        'dni': AppLogger.shortId(_dni),
      });
      _mostrarMensaje(
        'No se pudo registrar la marcacion en este momento. Intenta de nuevo.',
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

  void _reiniciarScanner() {
    if (!mounted) {
      return;
    }

    AppLogger.info('Home', 'Scanner reiniciado', {
      'dni': AppLogger.shortId(_dni),
    });

    setState(() {
      _procesando = false;
      _qrProcesado = false;
      _escaneando = false;
    });
  }

  void _mostrarMensaje(String msg, {bool esError = false}) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
        backgroundColor: esError ? AppPalette.error : AppPalette.verdeAzulado,
      ),
    );
  }

  bool get _horarioManualActivo =>
      _horarioHoy?['origen']?.toString() == _origenHorarioManual;

  Map<String, dynamic>? _inferirHorarioManualDesdeAsistencia(
    Map<String, dynamic>? asistencia,
  ) {
    if (asistencia == null) {
      return null;
    }

    final tieneEntrada = _marcaExiste(asistencia['horario_entrada']);
    final tieneSalida = _marcaExiste(asistencia['horario_salida']);
    final tieneReceso =
        _marcaExiste(asistencia['horario_inicio_receso']) ||
        _marcaExiste(asistencia['horario_fin_receso']);

    if (tieneReceso) {
      return _horarioManual('fulltime');
    }

    if (!tieneEntrada && !tieneSalida) {
      return null;
    }

    return _horarioManual('parttime');
  }

  Map<String, dynamic> _horarioManual(String key) {
    return Map<String, dynamic>.from(_horariosPorJornada[key]!);
  }

  Future<Map<String, dynamic>?> _mostrarSelectorJornada() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) {
      return null;
    }

    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        String? seleccion = 'fulltime';
        final scheme = Theme.of(sheetContext).colorScheme;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Container(
                margin: const EdgeInsets.all(14),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.glassBorder(context)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'NO TIENES HORARIO HOY',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.bebasNeue(
                        fontSize: 24,
                        color: scheme.onSurface,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Elige tu jornada para registrar asistencia de hoy. Se guardara como no justificada.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.robotoCondensed(
                        fontSize: 13,
                        color: scheme.onSurface.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _JornadaOption(
                      title: 'Full time',
                      subtitle: '4 marcaciones: entrada, receso y salida',
                      selected: seleccion == 'fulltime',
                      onTap: () => setSheetState(() => seleccion = 'fulltime'),
                    ),
                    const SizedBox(height: 10),
                    _JornadaOption(
                      title: 'Part time',
                      subtitle: '2 marcaciones: entrada y salida',
                      selected: seleccion == 'parttime',
                      onTap: () => setSheetState(() => seleccion = 'parttime'),
                    ),
                    const SizedBox(height: 18),
                    ElevatedButton(
                      onPressed: seleccion == null
                          ? null
                          : () async {
                              final confirmado =
                                  await _confirmarJornadaSeleccionada(
                                    context,
                                    _horariosPorJornada[seleccion]!['nombre_jornada']
                                        .toString(),
                                  );
                              if (confirmado == true && context.mounted) {
                                Navigator.pop(
                                  context,
                                  Map<String, dynamic>.from(
                                    _horariosPorJornada[seleccion]!,
                                  ),
                                );
                              }
                            },
                      child: Text(
                        'CONFIRMAR',
                        style: GoogleFonts.bebasNeue(
                          fontSize: 18,
                          color: Colors.white,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<bool?> _confirmarJornadaSeleccionada(
    BuildContext context,
    String jornada,
  ) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(
          'Confirmar jornada',
          style: GoogleFonts.bebasNeue(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 22,
            letterSpacing: 1,
          ),
        ),
        content: Text(
          'Seguro que quieres usar $jornada para hoy?',
          style: GoogleFonts.robotoCondensed(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.72),
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancelar',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Si, confirmar',
              style: TextStyle(color: AppPalette.verdeAzulado),
            ),
          ),
        ],
      ),
    );
  }

  String _debugPreview(String value) {
    final limpio = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (limpio.length <= 80) {
      return limpio;
    }
    return '${limpio.substring(0, 80)}...';
  }

  Duration _extraerEsperaCooldown(String mensaje) {
    final minutos = RegExp(r'(\d+)').firstMatch(mensaje)?.group(1);
    final valor = int.tryParse(minutos ?? '');
    return Duration(minutes: valor ?? _cooldownMarcacion.inMinutes);
  }

  void _actualizarCooldownDesdeAsistencia(Map<String, dynamic>? asistencia) {
    final ultima = _ultimaMarcacion(asistencia);
    if (ultima == null) {
      _detenerCooldown();
      return;
    }

    final restante = _cooldownMarcacion - DateTime.now().difference(ultima);
    if (restante.inSeconds > 0) {
      _iniciarCooldown(restante);
    } else {
      _detenerCooldown();
    }
  }

  DateTime? _ultimaMarcacion(Map<String, dynamic>? asistencia) {
    if (asistencia == null) {
      return null;
    }

    DateTime? ultima;
    for (final item in _ordenMarcaciones) {
      final valor = asistencia[item.$2];
      if (!_marcaExiste(valor)) {
        continue;
      }

      final fecha = _parseSupabaseDateTime(valor)?.toLocal();
      if (fecha == null) {
        continue;
      }

      if (ultima == null || fecha.isAfter(ultima)) {
        ultima = fecha;
      }
    }

    return ultima;
  }

  void _iniciarCooldown(Duration duracion) {
    _cooldownTimer?.cancel();
    final segundos = duracion.inSeconds <= 0 ? 0 : duracion.inSeconds;

    setState(() {
      _cooldownRestante = Duration(seconds: segundos);
      _enCooldown = segundos > 0;
    });

    if (segundos <= 0) {
      return;
    }

    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final siguiente = _cooldownRestante - const Duration(seconds: 1);
      if (siguiente.inSeconds <= 0) {
        timer.cancel();
        setState(() {
          _cooldownRestante = Duration.zero;
          _enCooldown = false;
        });
        return;
      }

      setState(() => _cooldownRestante = siguiente);
    });
  }

  void _detenerCooldown() {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    if (mounted) {
      setState(() {
        _cooldownRestante = Duration.zero;
        _enCooldown = false;
      });
    }
  }

  String _formatearCooldown(Duration duracion) {
    final minutos = duracion.inMinutes.remainder(60).toString().padLeft(2, '0');
    final segundos = duracion.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return '$minutos:$segundos';
  }

  Future<void> _abrirWhatsApp() async {
    final nombre = widget.usuario['nombre']?.toString().trim();
    final cargo = widget.usuario['cargo']?.toString().trim();
    final dni = _dni.trim();
    final tienda = widget.usuario['nombre_tienda']?.toString().trim();
    final direccion = widget.usuario['direccion_tienda']?.toString().trim();
    final tiendaTexto = [
      if (tienda?.isNotEmpty == true) tienda,
      if (direccion?.isNotEmpty == true) direccion,
    ].whereType<String>().join(', ');

    final mensaje = [
      'Hola, deseo justificar una marcacion.',
      '',
      'Usuario: ${nombre?.isNotEmpty == true ? nombre : 'No especificado'}',
      'DNI: ${dni.isNotEmpty ? dni : 'No especificado'}',
      'Tienda asignada: ${tiendaTexto.isNotEmpty ? tiendaTexto : 'No especificada'}',
      'Cargo: ${cargo?.isNotEmpty == true ? cargo : 'No especificado'}',
      'Fecha: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
      '',
      'Motivo:',
    ].join('\n');

    final abierto =
        await _platform.invokeMethod<bool>('openWhatsApp', {
          'phone': '51970556585',
          'message': mensaje,
        }) ??
        false;
    if (!abierto) {
      _mostrarMensaje('No se pudo abrir WhatsApp.', esError: true);
    }
  }

  Future<void> _cerrarSesion() async {
    AppLogger.info('Home', 'Solicitud de cierre de sesion', {
      'dni': AppLogger.shortId(_dni),
    });

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(
          'Cerrar sesion',
          style: GoogleFonts.bebasNeue(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 22,
            letterSpacing: 1,
          ),
        ),
        content: Text(
          'Seguro que quieres cerrar sesion?',
          style: GoogleFonts.robotoCondensed(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.72),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancelar',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Cerrar sesion',
              style: TextStyle(color: AppPalette.error),
            ),
          ),
        ],
      ),
    );

    if (confirmar == true && mounted) {
      AppLogger.info('Home', 'Sesion cerrada', {
        'dni': AppLogger.shortId(_dni),
      });
      await SessionService().cerrarSesion();
      if (!mounted) {
        return;
      }
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => LoginScreen(
            themeMode: widget.themeMode,
            onThemeToggle: widget.onThemeToggle,
          ),
        ),
        (route) => false,
      );
    }
  }

  int _marcacionesCompletadas(Map<String, dynamic>? data) {
    if (data == null) {
      return 0;
    }
    return _marcacionesParaHorario(
      _horarioHoy,
    ).where((item) => _marcaExiste(data[item.$2])).length;
  }

  String _horaProgramada(String horarioKey) {
    if (_horarioManualActivo) {
      return 'Sin hora fija';
    }

    final valor = _horarioHoy?[horarioKey]?.toString();
    if (valor == null || valor.isEmpty) {
      return '--:--';
    }
    final horaStr = valor.length >= 5 ? valor.substring(0, 5) : valor;
    final partes = horaStr.split(':');
    if (partes.length == 2) {
      final hora = int.tryParse(partes[0]) ?? 0;
      final minuto = int.tryParse(partes[1]) ?? 0;
      final ampm = hora >= 12 ? 'PM' : 'AM';
      final hora12 = hora > 12 ? hora - 12 : (hora == 0 ? 12 : hora);
      return '${hora12.toString().padLeft(2, '0')}:${minuto.toString().padLeft(2, '0')} $ampm';
    }
    return horaStr;
  }

  String _horaMarcada(Map<String, dynamic>? data, String marcacionKey) {
    final marca = data?[marcacionKey];
    if (!_marcaExiste(marca)) {
      return '--:--';
    }

    final parsed = _parseSupabaseDateTime(marca);
    if (parsed != null) {
      return DateFormat('hh:mm a').format(parsed.toLocal());
    }

    return '--:--';
  }

  Color _calcularColorPuntualidad(String marcacionKey) {
    return _calcularColorPuntualidadEn(_asistenciaHoy, marcacionKey);
  }

  Color _calcularColorPuntualidadEn(
    Map<String, dynamic>? asistencia,
    String marcacionKey,
  ) {
    final marca = asistencia?[marcacionKey];
    if (!_marcaExiste(marca)) {
      return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.24);
    }

    if (_horarioManualActivo) {
      return AppPalette.verdeAzulado;
    }

    if (marcacionKey == 'horario_inicio_receso' ||
        marcacionKey == 'horario_fin_receso') {
      return AppPalette.verdeAzulado;
    }

    final horaEsperada = _horarioHoy?[marcacionKey];
    if (horaEsperada == null) {
      return AppPalette.verdeAzulado;
    }

    final marcaDateTime = _parseSupabaseDateTime(marca)?.toLocal();

    if (marcaDateTime == null) {
      return AppPalette.verdeAzulado;
    }

    final horaEsperadaStr = horaEsperada.toString();
    final partesHora = horaEsperadaStr.split(':');
    if (partesHora.length < 2) {
      return AppPalette.verdeAzulado;
    }

    final horaEsperadaInt = int.tryParse(partesHora[0]) ?? 0;
    final minutoEsperadoInt = int.tryParse(partesHora[1]) ?? 0;

    final horaMarcada = marcaDateTime.hour;
    final minutoMarcado = marcaDateTime.minute;

    final diferenciaTotalMinutos =
        (horaMarcada * 60 + minutoMarcado) -
        (horaEsperadaInt * 60 + minutoEsperadoInt);

    if (diferenciaTotalMinutos <= 10) {
      return AppPalette.verdeAzulado;
    } else if (diferenciaTotalMinutos <= 30) {
      return AppPalette.alerta;
    } else {
      return AppPalette.error;
    }
  }

  DateTime? _fechaRegistro(Map<String, dynamic> registro) {
    final fecha = registro['fecha'];
    if (fecha is DateTime) {
      return fecha;
    }
    if (fecha == null) {
      return null;
    }
    return DateTime.tryParse(fecha.toString());
  }

  bool _marcaExiste(Object? value) {
    return value != null && value.toString().trim().isNotEmpty;
  }

  DateTime? _parseSupabaseDateTime(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value;
    }

    var text = value.toString().trim();
    if (text.isEmpty) {
      return null;
    }

    text = text.replaceFirst(' ', 'T');
    text = text.replaceFirstMapped(
      RegExp(r'([+-]\d{2})$'),
      (match) => '${match.group(1)}:00',
    );
    text = text.replaceFirstMapped(
      RegExp(r'([+-]\d{2})(\d{2})$'),
      (match) => '${match.group(1)}:${match.group(2)}',
    );

    return DateTime.tryParse(text);
  }

  bool _esMarcacionExitosa(String mensaje) {
    return mensaje == 'Entrada' ||
        mensaje == 'Inicio de receso' ||
        mensaje == 'Fin de receso' ||
        mensaje == 'Salida' ||
        mensaje == 'Marcacion registrada';
  }

  String _mensajeMarcacionUsuario(String mensaje, String tienda) {
    if (_esMarcacionExitosa(mensaje)) {
      return '$mensaje registrada en $tienda';
    }

    if (mensaje.startsWith('Debes esperar')) {
      return mensaje;
    }

    if (mensaje.startsWith('Ya')) {
      return 'Ya completaste tus marcaciones de hoy.';
    }

    return 'No se pudo registrar la marcacion. Intenta de nuevo.';
  }

  List<(String, String)> _marcacionesParaHorario(
    Map<String, dynamic>? horario,
  ) {
    final tieneReceso = _horarioTieneReceso(horario);

    return [
      _ordenMarcaciones[0],
      if (tieneReceso) _ordenMarcaciones[1],
      if (tieneReceso) _ordenMarcaciones[2],
      _ordenMarcaciones[3],
    ];
  }

  bool _horarioTieneReceso(Map<String, dynamic>? horario) {
    if (horario == null) {
      return true;
    }

    if (horario['origen']?.toString() == _origenHorarioManual) {
      return horario['tipo_jornada']?.toString() == 'fulltime';
    }

    return horario['horario_inicio_receso'] != null ||
        horario['horario_fin_receso'] != null;
  }

  List<(String, String)> _marcacionesParaDetalle(Map<String, dynamic> data) {
    final tieneReceso =
        _marcaExiste(data['horario_inicio_receso']) ||
        _marcaExiste(data['horario_fin_receso']);

    return [
      _ordenMarcaciones[0],
      if (tieneReceso) _ordenMarcaciones[1],
      if (tieneReceso) _ordenMarcaciones[2],
      _ordenMarcaciones[3],
    ];
  }

  Widget _buildHorarioMarcacionesCard() {
    final marcaciones = _marcacionesParaHorario(_horarioHoy);
    final completadas = _marcacionesCompletadas(_asistenciaHoy);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.glassSurface(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.glassBorder(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.24),
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
                  color: scheme.onSurface.withValues(alpha: 0.92),
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '$completadas/${marcaciones.length} completas',
                style: GoogleFonts.bebasNeue(
                  fontSize: 18,
                  color: completadas == marcaciones.length
                      ? AppPalette.verdeAzulado
                      : scheme.onSurface,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_horarioManualActivo) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppPalette.alerta.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppPalette.alerta.withValues(alpha: 0.54),
                ),
              ),
              child: Text(
                '${_horarioHoy?['nombre_jornada'] ?? 'Jornada'} elegida para hoy - no justificada',
                style: GoogleFonts.robotoCondensed(
                  fontSize: 12,
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
          ...marcaciones.map((item) {
            final marcada = _marcaExiste(_asistenciaHoy?[item.$2]);
            final colorPuntualidad = _calcularColorPuntualidad(item.$2);

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: marcada
                    ? colorPuntualidad.withValues(alpha: 0.14)
                    : scheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: marcada
                      ? colorPuntualidad
                      : AppTheme.glassBorder(context, alpha: 0.16),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: marcada ? colorPuntualidad : Colors.white24,
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
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Horario: ${_horaProgramada(item.$2)}',
                          style: GoogleFonts.robotoCondensed(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.72),
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
                              ? colorPuntualidad
                              : scheme.onSurface.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        marcada
                            ? _horaMarcada(_asistenciaHoy, item.$2)
                            : '--:--',
                        style: GoogleFonts.bebasNeue(
                          fontSize: 20,
                          color: marcada
                              ? colorPuntualidad
                              : scheme.onSurface.withValues(alpha: 0.38),
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
    final scheme = Theme.of(context).colorScheme;
    final marcada = _marcaExiste(data?[key]);
    final colorPuntualidad = marcada
        ? _calcularColorPuntualidadEn(data, key)
        : scheme.onSurface.withValues(alpha: 0.38);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              nombre,
              style: GoogleFonts.robotoCondensed(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.7),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            marcada ? _horaMarcada(data, key) : 'Pendiente',
            style: GoogleFonts.bebasNeue(
              fontSize: 16,
              color: colorPuntualidad,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarioHistorial() {
    final scheme = Theme.of(context).colorScheme;
    final ahora = DateTime.now();
    final datos = _mesSeleccionado == 0 ? _historialActual : _historialAnterior;
    final mes = _mesSeleccionado == 0
        ? DateTime(ahora.year, ahora.month)
        : DateTime(ahora.year, ahora.month - 1);

    final primerDia = DateTime(mes.year, mes.month);
    final ultimoDia = DateTime(mes.year, mes.month + 1, 0);
    final diasDelMes = ultimoDia.day;
    final diaInicio = primerDia.weekday;

    final diasConAsistencia = <int>{};
    for (final reg in datos) {
      final fecha = _fechaRegistro(reg);
      if (fecha != null && fecha.year == mes.year && fecha.month == mes.month) {
        diasConAsistencia.add(fecha.day);
      }
    }

    Map<String, dynamic>? detallesDia;
    if (_diaSeleccionado != null) {
      for (final reg in datos) {
        final fecha = _fechaRegistro(reg);
        if (fecha != null &&
            fecha.year == mes.year &&
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
            IconButton(
              onPressed: _mesSeleccionado == 0
                  ? () => setState(() {
                      _mesSeleccionado = -1;
                      _diaSeleccionado = null;
                    })
                  : null,
              icon: const Icon(Icons.chevron_left),
              color: scheme.onSurface.withValues(alpha: 0.64),
              style: IconButton.styleFrom(
                backgroundColor: AppTheme.glassSurface(context, alpha: 0.32),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            Text(
              DateFormat('MMMM yyyy', 'es').format(mes),
              style: GoogleFonts.bebasNeue(
                fontSize: 16,
                color: scheme.onSurface,
                letterSpacing: 1,
              ),
            ),
            IconButton(
              onPressed: _mesSeleccionado == -1
                  ? () => setState(() {
                      _mesSeleccionado = 0;
                      _diaSeleccionado = null;
                    })
                  : null,
              icon: const Icon(Icons.chevron_right),
              color: scheme.onSurface.withValues(alpha: 0.64),
              style: IconButton.styleFrom(
                backgroundColor: AppTheme.glassSurface(context, alpha: 0.32),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.glassSurface(context, alpha: 0.56),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppTheme.glassBorder(context, alpha: 0.18),
            ),
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
                          color: scheme.onSurface.withValues(alpha: 0.6),
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
                            ? AppPalette.azulOscuro
                            : tieneAsistencia
                            ? AppPalette.verdeAzulado.withValues(alpha: 0.3)
                            : scheme.onSurface.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: esSeleccionado
                              ? AppPalette.turquesaBrillante
                              : tieneAsistencia
                              ? AppPalette.verdeAzulado
                              : AppTheme.glassBorder(context, alpha: 0.12),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          dia.toString(),
                          style: GoogleFonts.bebasNeue(
                            fontSize: 12,
                            color: tieneAsistencia || esSeleccionado
                                ? Colors.white
                                : scheme.onSurface.withValues(alpha: 0.72),
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
              color: AppTheme.glassSurface(context, alpha: 0.56),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppPalette.turquesaBrillante),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Detalles del $_diaSeleccionado de ${DateFormat('MMMM', 'es').format(mes)}',
                  style: GoogleFonts.bebasNeue(
                    fontSize: 14,
                    color: scheme.onSurface,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 8),
                ..._marcacionesParaDetalle(detallesDia).map(
                  (item) =>
                      _buildDetalleMarcacion(item.$1, detallesDia, item.$2),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildScannerOverlay() {
    final scheme = Theme.of(context).colorScheme;

    return Stack(
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
            onPressed: _reiniciarScanner,
            icon: const Icon(Icons.close, color: Colors.white, size: 32),
          ),
        ),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: AppPalette.turquesaBrillante, width: 3),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        if (_procesando)
          Container(
            color: Colors.black54,
            child: const Center(
              child: CircularProgressIndicator(
                color: AppPalette.turquesaBrillante,
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
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
              shadows: const [Shadow(color: Colors.black87, blurRadius: 12)],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final nombre = widget.usuario['nombre']?.toString() ?? 'Trabajador';
    final cargo = widget.usuario['cargo']?.toString() ?? '';
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Bienvenido',
                    style: GoogleFonts.robotoCondensed(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.74),
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    nombre,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    softWrap: true,
                    style: GoogleFonts.bebasNeue(
                      fontSize: 24,
                      color: scheme.onSurface,
                      letterSpacing: 1,
                      shadows: const [
                        Shadow(color: Colors.black54, blurRadius: 8),
                      ],
                    ),
                  ),
                  if (cargo.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      cargo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.robotoCondensed(
                        fontSize: 13,
                        color: scheme.onSurface.withValues(alpha: 0.84),
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(width: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Abrir WhatsApp',
                onPressed: _abrirWhatsApp,
                icon: const Icon(Icons.chat, color: Colors.white, size: 18),
                style: IconButton.styleFrom(
                  backgroundColor: AppPalette.verdeAzulado,
                  side: BorderSide(color: AppPalette.turquesaBrillante),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _cerrarSesion,
                icon: Icon(
                  Icons.logout,
                  color: scheme.onSurface.withValues(alpha: 0.68),
                  size: 18,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: AppTheme.glassSurface(context, alpha: 0.34),
                  side: BorderSide(color: AppTheme.glassBorder(context)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

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
                ? Colors.black.withValues(alpha: 0.50)
                : Colors.white.withValues(alpha: 0.20),
          ),
          if (_escaneando) _buildScannerOverlay(),
          if (!_escaneando)
            SafeArea(
              child: Column(
                children: [
                  _buildHeader(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ElevatedButton(
                            onPressed: _enCooldown
                                ? null
                                : () => setState(() => _escaneando = true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: scheme.primary,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: scheme.primary
                                  .withValues(alpha: 0.45),
                              minimumSize: const Size.fromHeight(52),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: Text(
                              _enCooldown
                                  ? 'ESPERA ${_formatearCooldown(_cooldownRestante)}'
                                  : 'ESCANEAR QR PARA MARCAR',
                              style: GoogleFonts.bebasNeue(
                                fontSize: 18,
                                color: Colors.white,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                          if (_enCooldown) ...[
                            const SizedBox(height: 10),
                            Text(
                              'Debes esperar ${_formatearCooldown(_cooldownRestante)} antes de volver a marcar.',
                              style: GoogleFonts.robotoCondensed(
                                fontSize: 13,
                                color: scheme.onSurface.withValues(alpha: 0.82),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          _buildHorarioMarcacionesCard(),
                          const SizedBox(height: 20),
                          Text(
                            'HISTORIAL',
                            style: GoogleFonts.robotoCondensed(
                              fontSize: 12,
                              color: scheme.onSurface.withValues(alpha: 0.82),
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

class _JornadaOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _JornadaOption({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? AppPalette.turquesaBrillante : scheme.onSurface;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? AppPalette.turquesaBrillante.withValues(alpha: 0.14)
              : scheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? AppPalette.turquesaBrillante
                : scheme.onSurface.withValues(alpha: 0.14),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: color,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.robotoCondensed(
                      fontSize: 15,
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: GoogleFonts.robotoCondensed(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
