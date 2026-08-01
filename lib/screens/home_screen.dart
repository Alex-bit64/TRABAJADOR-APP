import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:uuid/uuid.dart';

import '../services/app_requirements_service.dart';
import '../services/app_logger.dart';
import '../services/device_security_service.dart';
import '../services/local_database_service.dart';
import '../services/qr_service.dart';
import '../services/session_service.dart';
import '../services/supabase_service.dart';
import '../services/top_message_service.dart';
import '../theme/app_google_fonts.dart';
import '../theme/app_theme.dart';
import 'app_requirements_screen.dart';
import 'login_screen.dart';

enum _ModoRegistro { asistencia, tracking }

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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _platform = MethodChannel('trabajador_app/platform');

  final _supabaseService = SupabaseService();
  final _qrService = QRService();
  final _requirementsService = AppRequirementsService();
  final _localDatabase = LocalDatabaseService.instance;
  final _deviceSecurity = DeviceSecurityService();
  static const Duration _cooldownMarcacion = Duration(minutes: 10);
  static const Duration _toleranciaFusionMarcacionNormal = Duration(
    minutes: 15,
  );
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
  List<Map<String, dynamic>> _trackingHoy = [];
  List<Map<String, dynamic>> _trackingActual = [];
  List<Map<String, dynamic>> _trackingAnterior = [];
  bool _escaneando = false;
  bool _procesando = false;
  bool _qrProcesado = false;
  bool _enCooldown = false;
  bool _sincronizandoTracking = false;
  bool _sincronizandoPendientes = false;
  bool _hayInternet = true;
  int _cantidadPendientes = 0;
  Set<String> _marcasPendientesHoy = <String>{};
  final Set<String> _marcasVisualesProtegidas = <String>{};
  Map<String, Set<String>> _marcasPendientesPorFecha = {};
  Duration _cooldownRestante = Duration.zero;
  Timer? _cooldownTimer;
  Timer? _requirementsTimer;
  int _mesSeleccionado = 0;
  int? _diaSeleccionado;
  bool _selectorJornadaAbierto = false;
  bool _verificandoRequisitosContinuos = false;
  bool _redirigiendoRequisitos = false;
  _ModoRegistro _modoRegistro = _ModoRegistro.asistencia;

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
    WidgetsBinding.instance.addObserver(this);
    AppLogger.info('Home', 'Home iniciado', {
      'dni': AppLogger.shortId(_dni),
      'id_tienda': AppLogger.shortId(
        widget.usuario['id_tienda']?.toString() ?? '',
      ),
      'scanner_auto': widget.abrirScannerAutomatico,
    });
    _cargarDatos();
    _iniciarMonitorRequisitos();
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
    WidgetsBinding.instance.removeObserver(this);
    _cooldownTimer?.cancel();
    _requirementsTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _verificarRequisitosContinuos();
    }
  }

  void _iniciarMonitorRequisitos() {
    _requirementsTimer?.cancel();
    _requirementsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _verificarRequisitosContinuos();
    });

    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) {
        _verificarRequisitosContinuos();
      }
    });
  }

  Future<void> _verificarRequisitosContinuos() async {
    if (_verificandoRequisitosContinuos ||
        _redirigiendoRequisitos ||
        !mounted) {
      return;
    }

    _verificandoRequisitosContinuos = true;
    try {
      final requisitos = await _requirementsService.check();
      if (!mounted) {
        return;
      }
      if (_hayInternet != requisitos.hasInternet) {
        setState(() => _hayInternet = requisitos.hasInternet);
      }
      if (requisitos.hasInternet) {
        unawaited(_sincronizarMarcacionesPendientes());
      }
      if (requisitos.ready) {
        return;
      }

      AppLogger.warning('Home', 'Requisitos desactivados durante uso', {
        'dni': AppLogger.shortId(_dni),
      });
      _mostrarMensaje(
        'Requisitos incompletos. Activa internet, ubicacion y camara.',
        esError: true,
      );
      _abrirFlujoRequisitos(abrirScannerAutomatico: false);
    } finally {
      _verificandoRequisitosContinuos = false;
    }
  }

  Future<void> _cargarDatos() async {
    AppLogger.info('Home', 'Carga de datos iniciada', {
      'dni': AppLogger.shortId(_dni),
    });

    await _cargarPendientes();
    await Future.wait([
      _cargarAsistencia(),
      _cargarHorario(),
      _cargarHistorial(),
      _cargarTracking(),
    ]);

    await _sincronizarAsistenciaConTracking();
    if (_hayInternet) {
      await _sincronizarMarcacionesPendientes();
    }

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

    final local = await _localDatabase.obtenerAsistencia(_dni, DateTime.now());
    if (mounted && local != null && _asistenciaHoy == null) {
      setState(() => _asistenciaHoy = local);
      _actualizarCooldownDesdeAsistencia(local);
    }

    final remoto = await _supabaseService.obtenerAsistenciaHoy(_dni);
    final data = _combinarAsistenciaVisible(
      remoto: remoto,
      local: local,
      actual: _asistenciaHoy,
    );
    if (data != null) {
      await _localDatabase.guardarAsistencia(data);
    }
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
    final ahora = DateTime.now();
    final horarioRemoto = await _supabaseService.obtenerHorarioTrabajador(
      _dni,
      diaSemana: diaHoy,
    );
    if (horarioRemoto != null) {
      await SessionService().guardarHorarioDia(_dni, ahora, horarioRemoto);
    }
    final horarioGuardado = horarioRemoto == null
        ? await SessionService().obtenerHorarioDia(_dni, ahora)
        : null;
    final horarioAsignado = horarioRemoto ?? horarioGuardado;
    final horarioManual = horarioAsignado == null
        ? await SessionService().obtenerHorarioManual(_dni, ahora)
        : null;
    final horarioVisible = horarioAsignado ?? horarioManual;

    AppLogger.info('Home', 'Horario cargado', {
      'dni': AppLogger.shortId(_dni),
      'dia': diaHoy,
      'existe': horarioVisible != null,
      'cache': horarioRemoto == null && horarioGuardado != null,
    });
    if (mounted) {
      setState(() => _horarioHoy = horarioVisible);
    }
  }

  Future<void> _verificarHorarioDelDia() async {
    if (!mounted || _dni.isEmpty) {
      return;
    }

    if (_horarioManualActivo && _horarioHoy != null) {
      await _aplicarJornadaManualSegura(_horarioHoy!);
      await Future.wait([_cargarAsistencia(), _cargarHistorial()]);
      return;
    }

    if (_horarioHoy != null) {
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
      await _aplicarJornadaManualSegura(horarioGuardado);
      await Future.wait([_cargarAsistencia(), _cargarHistorial()]);
      if (mounted) {
        setState(() => _horarioHoy = horarioGuardado);
      }
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
      await _aplicarJornadaManualSegura(horarioInferido);
      if (mounted) {
        setState(() => _horarioHoy = horarioInferido);
      }
      await Future.wait([_cargarAsistencia(), _cargarHistorial()]);
      if (mounted) {
        setState(() => _horarioHoy = horarioInferido);
      }
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

    if (mounted) {
      setState(() => _horarioHoy = horarioElegido);
    }

    await SessionService().guardarHorarioManual(
      _dni,
      DateTime.now(),
      horarioElegido,
    );
    await _aplicarJornadaManualSegura(horarioElegido);

    if (mounted) {
      setState(() => _horarioHoy = horarioElegido);
    }
    await Future.wait([
      _cargarAsistencia(),
      _cargarHistorial(),
      _cargarTracking(),
    ]);
    if (mounted) {
      setState(() => _horarioHoy = horarioElegido);
    }
  }

  Future<void> _aplicarJornadaManualSegura(Map<String, dynamic> horario) async {
    try {
      await _supabaseService.aplicarJornadaManual(_dni, horario);
    } catch (e, st) {
      AppLogger.error(
        'Home',
        'La jornada queda guardada localmente hasta recuperar internet',
        e,
        st,
        {'dni': AppLogger.shortId(_dni)},
      );
      if (_supabaseService.esErrorConexion(e) && mounted) {
        setState(() => _hayInternet = false);
      }
    }
  }

  Future<void> _cargarHistorial() async {
    if (_dni.isEmpty) {
      AppLogger.warning('Home', 'No se carga historial porque DNI esta vacio');
      return;
    }

    final ahora = DateTime.now();
    final mesActual = DateTime(ahora.year, ahora.month);
    final mesAnterior = DateTime(ahora.year, ahora.month - 1);

    final locales = await Future.wait([
      _localDatabase.obtenerHistorialMes(_dni, mesActual),
      _localDatabase.obtenerHistorialMes(_dni, mesAnterior),
    ]);
    final remotos = await Future.wait([
      _supabaseService.obtenerHistorialAsistenciasMes(_dni, mesActual),
      _supabaseService.obtenerHistorialAsistenciasMes(_dni, mesAnterior),
    ]);
    final historialActual = _combinarHistorial(remotos[0], locales[0]);
    final historialAnterior = _combinarHistorial(remotos[1], locales[1]);
    await Future.wait([
      _localDatabase.guardarHistorial(_dni, historialActual),
      _localDatabase.guardarHistorial(_dni, historialAnterior),
    ]);

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

  Future<void> _cargarPendientes() async {
    if (_dni.isEmpty) {
      return;
    }
    final pendientes = await _localDatabase.obtenerMarcacionesPendientes(
      dni: _dni,
    );
    final porFecha = <String, Set<String>>{};
    for (final pendiente in pendientes) {
      porFecha
          .putIfAbsent(pendiente.fecha, () => <String>{})
          .add(pendiente.tipoMarcacion);
    }
    final hoy = _fechaKey(DateTime.now());
    if (mounted) {
      setState(() {
        _cantidadPendientes = pendientes.length;
        _marcasPendientesPorFecha = porFecha;
        _marcasPendientesHoy = porFecha[hoy] ?? <String>{};
      });
    }
  }

  Map<String, dynamic>? _combinarAsistenciaVisible({
    required Map<String, dynamic>? remoto,
    required Map<String, dynamic>? local,
    required Map<String, dynamic>? actual,
  }) {
    if (remoto == null) {
      final fallback = actual ?? local;
      return fallback == null ? null : Map<String, dynamic>.from(fallback);
    }

    final resultado = Map<String, dynamic>.from(remoto);
    for (final item in _ordenMarcaciones) {
      final campo = item.$2;
      if (_marcaExiste(resultado[campo])) {
        _marcasVisualesProtegidas.remove(campo);
        continue;
      }
      final protegida =
          _marcasPendientesHoy.contains(campo) ||
          _marcasVisualesProtegidas.contains(campo);
      if (!protegida) {
        continue;
      }
      final valor = actual?[campo] ?? local?[campo];
      if (_marcaExiste(valor)) {
        resultado[campo] = valor;
      }
    }
    return resultado;
  }

  List<Map<String, dynamic>> _combinarHistorial(
    List<Map<String, dynamic>> remotos,
    List<Map<String, dynamic>> locales,
  ) {
    final porFecha = <String, Map<String, dynamic>>{};
    for (final local in locales) {
      final fecha = _fechaRegistro(local);
      if (fecha != null) {
        porFecha[_fechaKey(fecha)] = Map<String, dynamic>.from(local);
      }
    }
    for (final remoto in remotos) {
      final fecha = _fechaRegistro(remoto);
      if (fecha == null) {
        continue;
      }
      final key = _fechaKey(fecha);
      final combinado = Map<String, dynamic>.from(remoto);
      final local = porFecha[key];
      for (final campo in _marcasPendientesPorFecha[key] ?? const <String>{}) {
        if (!_marcaExiste(combinado[campo]) && _marcaExiste(local?[campo])) {
          combinado[campo] = local![campo];
        }
      }
      porFecha[key] = combinado;
    }
    final resultado = porFecha.values.toList();
    resultado.sort((a, b) {
      final fechaA = _fechaRegistro(a) ?? DateTime(1970);
      final fechaB = _fechaRegistro(b) ?? DateTime(1970);
      return fechaB.compareTo(fechaA);
    });
    return resultado;
  }

  Future<void> _sincronizarMarcacionesPendientes() async {
    if (_sincronizandoPendientes || !_hayInternet) {
      return;
    }
    _sincronizandoPendientes = true;
    var sincronizadas = 0;
    try {
      final pendientes = await _localDatabase.obtenerMarcacionesPendientes();
      for (final pendiente in pendientes) {
        try {
          await _supabaseService.sincronizarMarcacionPendiente(pendiente);
          await _localDatabase.eliminarPendiente(pendiente.id);
          sincronizadas++;
        } catch (e, st) {
          await _localDatabase.registrarIntento(pendiente.id, e);
          AppLogger.error(
            'Home',
            'No se pudo sincronizar una marcacion pendiente',
            e,
            st,
            {
              'dni': AppLogger.shortId(pendiente.dni),
              'tipo': pendiente.tipoMarcacion,
            },
          );
          if (_supabaseService.esErrorConexion(e)) {
            if (mounted) {
              setState(() => _hayInternet = false);
            }
            break;
          }
        }
      }
    } finally {
      _sincronizandoPendientes = false;
    }

    await _cargarPendientes();
    if (sincronizadas > 0 && mounted) {
      await Future.wait([_cargarAsistencia(), _cargarHistorial()]);
      unawaited(_cargarTracking());
      _mostrarMensaje(
        sincronizadas == 1
            ? 'Se sincronizo 1 marcacion pendiente.'
            : 'Se sincronizaron $sincronizadas marcaciones pendientes.',
      );
    }
  }

  Future<void> _cargarTracking() async {
    if (_dni.isEmpty) {
      AppLogger.warning('Home', 'No se carga tracking porque DNI esta vacio');
      return;
    }

    final ahora = DateTime.now();
    final mesActual = DateTime(ahora.year, ahora.month);
    final mesAnterior = DateTime(ahora.year, ahora.month - 1);

    final resultados = await Future.wait([
      _supabaseService.obtenerTrackingDia(widget.usuario, ahora),
      _supabaseService.obtenerTrackingMes(widget.usuario, mesActual),
      _supabaseService.obtenerTrackingMes(widget.usuario, mesAnterior),
    ]);

    if (mounted) {
      AppLogger.info('Home', 'Tracking cargado', {
        'dni': AppLogger.shortId(_dni),
        'hoy': resultados[0].length,
        'actual': resultados[1].length,
        'anterior': resultados[2].length,
      });
      setState(() {
        _trackingHoy = resultados[0];
        _trackingActual = resultados[1];
        _trackingAnterior = resultados[2];
      });
    }
  }

  Future<void> _sincronizarAsistenciaConTracking() async {
    if (_sincronizandoTracking || _dni.isEmpty) {
      return;
    }

    final asistencias = <Map<String, dynamic>>[
      ...?(_asistenciaHoy == null ? null : [_asistenciaHoy!]),
      ..._historialActual,
      ..._historialAnterior,
    ];
    if (asistencias.isEmpty) {
      return;
    }

    _sincronizandoTracking = true;
    try {
      final cantidad = await _supabaseService.sincronizarAsistenciasEnTracking(
        widget.usuario,
        asistencias,
      );
      if (cantidad > 0 && mounted) {
        await _cargarTracking();
      }
    } finally {
      _sincronizandoTracking = false;
    }
  }

  Future<void> _procesarQR(String qrValue) async {
    final bloqueadoPorCooldown =
        _modoRegistro == _ModoRegistro.asistencia && _enCooldown;
    if (_procesando || _qrProcesado || bloqueadoPorCooldown) {
      AppLogger.warning('Home', 'QR ignorado por estado de scanner', {
        'procesando': _procesando,
        'qr_procesado': _qrProcesado,
        'cooldown': bloqueadoPorCooldown,
        'modo': _modoRegistro.name,
      });
      return;
    }

    AppLogger.info('Home', 'QR detectado', {
      'dni': AppLogger.shortId(_dni),
      'raw_length': qrValue.length,
      'raw_preview': _debugPreview(qrValue),
      'modo': _modoRegistro.name,
    });

    setState(() {
      _procesando = true;
      _qrProcesado = true;
    });

    final resultado = await _qrService.validarQR(qrValue, widget.usuario);
    AppLogger.info('Home', 'Resultado validacion QR', {
      'valido': resultado.valido,
      'mensaje': resultado.mensajeError ?? '',
      'id_tienda': AppLogger.shortId(resultado.qrValidado?.idTienda ?? ''),
      'tienda': resultado.qrValidado?.nombreTienda ?? '',
      'ubicacion_actual': resultado.ubicacion == null ? 'no' : 'si',
      'qr_ubicacion_keys':
          resultado.qrValidado?.ubicacionQr.keys.join(',') ?? '',
    });
    if (!resultado.valido ||
        resultado.qrValidado == null ||
        resultado.ubicacion == null) {
      final mensajeError =
          resultado.mensajeError ?? 'No se pudo validar el QR.';
      AppLogger.warning('Home', 'QR invalido', {'mensaje': mensajeError});
      _mostrarMensaje(mensajeError, esError: true);
      if (_esErrorRequisito(mensajeError)) {
        _abrirFlujoRequisitos();
        return;
      }
      _reiniciarScanner();
      return;
    }

    DeviceCredentials? dispositivo;
    if (_modoRegistro == _ModoRegistro.asistencia) {
      try {
        final vinculado = await _deviceSecurity.estaVinculadoLocalmente(_dni);
        if (!vinculado) {
          throw const DeviceSecurityException(
            'Este celular no esta vinculado a tu usuario. Cierra sesion e ingresa nuevamente.',
          );
        }
        await _deviceSecurity.autenticar(
          motivo: 'Confirma tu identidad para registrar esta asistencia.',
        );
        dispositivo = await _deviceSecurity.obtenerCredenciales(
          crearSiFaltan: false,
        );
      } on DeviceSecurityException catch (e, st) {
        AppLogger.error(
          'Home',
          'Marcacion cancelada por validacion biometrica',
          e,
          st,
          {'dni': AppLogger.shortId(_dni)},
        );
        _mostrarMensaje(e.message, esError: true);
        _reiniciarScanner();
        return;
      }
    }

    try {
      if (_modoRegistro == _ModoRegistro.tracking) {
        AppLogger.info('Home', 'Registrando tracking desde QR', {
          'dni': AppLogger.shortId(_dni),
          'id_tienda_qr': AppLogger.shortId(resultado.qrValidado!.idTienda),
        });

        final tracking = await _supabaseService.registrarMovimientoPersonal(
          widget.usuario,
          resultado.qrValidado!,
          ubicacion: resultado.ubicacion!,
        );

        AppLogger.info('Home', 'Tracking procesado', {
          'dni': AppLogger.shortId(_dni),
          'resultado': tracking,
          'tienda': resultado.qrValidado!.nombreTienda,
        });
        await _cargarTracking();
        final tiendaTracking = resultado.qrValidado!.nombreTienda;
        _mostrarMensaje(
          tiendaTracking == 'QR de tienda'
              ? tracking
              : '$tracking en $tiendaTracking',
        );
      } else {
        AppLogger.info('Home', 'Registrando marcacion desde QR', {
          'dni': AppLogger.shortId(_dni),
          'id_tienda_qr': AppLogger.shortId(resultado.qrValidado!.idTienda),
          'tienda': resultado.qrValidado!.nombreTienda,
          'lat': resultado.ubicacion!['latitude']?.toStringAsFixed(6),
          'lng': resultado.ubicacion!['longitude']?.toStringAsFixed(6),
          'horario_manual': _horarioManualActivo,
          'tipo_jornada': _horarioHoy?['tipo_jornada']?.toString() ?? '',
        });

        final siguienteEsperada = _siguienteCampoMarcacion();
        var guardadaOffline = false;
        late final String marcacion;
        if (!_hayInternet) {
          marcacion = await _registrarMarcacionOffline(
            resultado.qrValidado!,
            resultado.ubicacion!,
          );
          guardadaOffline = true;
        } else {
          try {
            marcacion = await _supabaseService.registrarMarcacion(
              widget.usuario,
              resultado.qrValidado!,
              ubicacion: resultado.ubicacion!,
              horarioManual: _horarioManualActivo ? _horarioHoy : null,
              horarioDia: _horarioManualActivo ? null : _horarioHoy,
              dispositivo: dispositivo,
            );
          } catch (e) {
            if (!_supabaseService.esErrorConexion(e)) {
              rethrow;
            }
            if (mounted) {
              setState(() => _hayInternet = false);
            }
            marcacion = await _registrarMarcacionOffline(
              resultado.qrValidado!,
              resultado.ubicacion!,
            );
            guardadaOffline = true;
          }
        }

        final enCooldown = marcacion.startsWith('Debes esperar');
        AppLogger.info('Home', 'Marcacion procesada', {
          'dni': AppLogger.shortId(_dni),
          'resultado': marcacion,
          'tienda': resultado.qrValidado!.nombreTienda,
        });
        final marcacionExitosa = _esMarcacionExitosa(marcacion);
        if (marcacionExitosa && !guardadaOffline) {
          _aplicarMarcaVisual(marcacion, campoPreferido: siguienteEsperada);
        }
        final mensajeUsuario = _mensajeMarcacionUsuario(
          marcacion,
          resultado.qrValidado!.nombreTienda,
        );
        _mostrarMensaje(
          guardadaOffline && marcacionExitosa
              ? '$mensajeUsuario. Pendiente de sincronizar.'
              : mensajeUsuario,
          esError: !marcacionExitosa,
        );

        if (guardadaOffline) {
          await _cargarPendientes();
          _actualizarHistorialConAsistenciaActual();
        } else {
          await _recargarDespuesDeMarcacion();
        }

        if (mounted) {
          if (marcacionExitosa) {
            _iniciarCooldown(_cooldownMarcacion);
          } else if (enCooldown) {
            _iniciarCooldown(_extraerEsperaCooldown(marcacion));
          }
        }
      }
    } catch (e, st) {
      AppLogger.error('Home', 'Error procesando QR', e, st, {
        'dni': AppLogger.shortId(_dni),
        'modo': _modoRegistro.name,
        'error_type': e.runtimeType.toString(),
      });
      final accion = _modoRegistro == _ModoRegistro.tracking
          ? 'el tracking'
          : 'la marcacion';
      _mostrarMensaje(_mensajeErrorRegistro(e, accion), esError: true);
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

  Future<void> _abrirScannerConRequisitos() async {
    final requisitos = await _requirementsService.check();
    if (!mounted) {
      return;
    }

    if (_hayInternet != requisitos.hasInternet) {
      setState(() => _hayInternet = requisitos.hasInternet);
    }

    if (!requisitos.ready) {
      _abrirFlujoRequisitos();
      return;
    }

    setState(() => _escaneando = true);
  }

  void _abrirFlujoRequisitos({bool abrirScannerAutomatico = true}) {
    if (!mounted || _redirigiendoRequisitos) {
      return;
    }

    _redirigiendoRequisitos = true;
    _requirementsTimer?.cancel();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => AppRequirementsScreen(
          usuario: widget.usuario,
          themeMode: widget.themeMode,
          onThemeToggle: widget.onThemeToggle,
          abrirScannerAutomatico: abrirScannerAutomatico,
        ),
      ),
    );
  }

  bool _esErrorRequisito(String mensaje) {
    final normalizado = mensaje.toLowerCase();
    return normalizado.contains('ubicacion') ||
        normalizado.contains('gps') ||
        normalizado.contains('permiso') ||
        normalizado.contains('camara') ||
        normalizado.contains('internet');
  }

  String _mensajeErrorRegistro(Object error, String accion) {
    final raw = error.toString().replaceFirst('Exception: ', '').trim();
    final normalizado = raw.toLowerCase();
    final mensajeSeguro =
        normalizado.contains('fuera del rango') ||
        normalizado.contains('ubicacion') ||
        normalizado.contains('gps') ||
        normalizado.contains('permiso') ||
        normalizado.contains('codigo de asistencia') ||
        normalizado.contains('código de asistencia') ||
        normalizado.contains('codigo no valido') ||
        normalizado.contains('no se pudo validar') ||
        normalizado.contains('resolver el qr') ||
        normalizado.contains('qr dinamico') ||
        normalizado.contains('rango') ||
        normalizado.contains('postgrestexception') ||
        normalizado.contains('supabase') ||
        normalizado.contains('schema cache') ||
        normalizado.contains('could not find') ||
        normalizado.contains('column') ||
        normalizado.contains('permission denied') ||
        normalizado.contains('row-level security') ||
        normalizado.contains('violates') ||
        normalizado.contains('invalid input') ||
        normalizado.contains('json') ||
        normalizado.contains('pgrst') ||
        normalizado.contains('token') ||
        normalizado.contains('qr invalido') ||
        normalizado.contains('qr inválido') ||
        normalizado.contains('ultima marca') ||
        normalizado.contains('última marca') ||
        normalizado.contains('primero registra') ||
        normalizado.contains('entrada antes') ||
        normalizado.contains('debes esperar') ||
        normalizado.contains('completaste todas') ||
        normalizado.contains('ya existia') ||
        normalizado.contains('ya existía');

    if (mensajeSeguro && raw.isNotEmpty) {
      return raw;
    }

    return 'No se pudo registrar $accion en este momento. Intenta de nuevo.';
  }

  Future<String> _registrarMarcacionOffline(
    QRValidado qr,
    Map<String, double> ubicacion,
  ) async {
    if (qr.token.startsWith('app-qr-dinamico://')) {
      throw Exception(
        'El QR dinamico necesita internet para comprobar que sigue vigente.',
      );
    }

    final tipoMarcacion = _siguienteCampoMarcacion();
    if (tipoMarcacion == null) {
      return 'Ya completaste todas las marcaciones de hoy';
    }
    _supabaseService.validarRangoQrLocal(
      qr,
      ubicacion,
      tipoMarcacion: tipoMarcacion,
    );

    final ahora = DateTime.now();
    final asistencia = <String, dynamic>{
      'dni_trabajador': _dni,
      'fecha': _fechaKey(ahora),
      'horario_entrada': null,
      'horario_inicio_receso': null,
      'horario_fin_receso': null,
      'horario_salida': null,
      'justificado': !_horarioManualActivo && _horarioHoy != null,
      ...?_asistenciaHoy,
      tipoMarcacion: ahora.toIso8601String(),
    };
    final pendiente = MarcacionPendiente(
      id: const Uuid().v4(),
      dni: _dni,
      fecha: _fechaKey(ahora),
      tipoMarcacion: tipoMarcacion,
      marcadoEn: ahora,
      usuario: Map<String, dynamic>.from(widget.usuario),
      qr: qr.toMap(),
      ubicacion: Map<String, double>.from(ubicacion),
      horarioManual: _horarioManualActivo && _horarioHoy != null
          ? Map<String, dynamic>.from(_horarioHoy!)
          : null,
      horarioDia: !_horarioManualActivo && _horarioHoy != null
          ? Map<String, dynamic>.from(_horarioHoy!)
          : null,
    );
    await _localDatabase.encolarMarcacion(pendiente);
    if (mounted) {
      setState(() {
        _asistenciaHoy = asistencia;
        _marcasPendientesHoy = {..._marcasPendientesHoy, tipoMarcacion};
      });
      _actualizarCooldownDesdeAsistencia(asistencia);
    }
    return _nombreCampoMarcacion(tipoMarcacion);
  }

  String? _siguienteCampoMarcacion() {
    for (final item in _marcacionesParaHorario(_horarioHoy)) {
      if (!_marcaExiste(_asistenciaHoy?[item.$2])) {
        return item.$2;
      }
    }
    return null;
  }

  void _aplicarMarcaVisual(String mensaje, {String? campoPreferido}) {
    final campo = _campoDesdeMensaje(mensaje) ?? campoPreferido;
    if (campo == null || !mounted) {
      return;
    }
    final ahora = DateTime.now().toIso8601String();
    final asistencia = <String, dynamic>{
      'dni_trabajador': _dni,
      'fecha': _fechaKey(DateTime.now()),
      'horario_entrada': null,
      'horario_inicio_receso': null,
      'horario_fin_receso': null,
      'horario_salida': null,
      ...?_asistenciaHoy,
      campo: ahora,
    };
    setState(() {
      _asistenciaHoy = asistencia;
      _marcasVisualesProtegidas.add(campo);
    });
    unawaited(_localDatabase.guardarAsistencia(asistencia));
  }

  String? _campoDesdeMensaje(String mensaje) {
    switch (mensaje.trim().toLowerCase()) {
      case 'entrada':
        return 'horario_entrada';
      case 'inicio de receso':
        return 'horario_inicio_receso';
      case 'fin de receso':
        return 'horario_fin_receso';
      case 'salida':
        return 'horario_salida';
    }
    return null;
  }

  String _nombreCampoMarcacion(String campo) {
    return switch (campo) {
      'horario_entrada' => 'Entrada',
      'horario_inicio_receso' => 'Inicio de receso',
      'horario_fin_receso' => 'Fin de receso',
      'horario_salida' => 'Salida',
      _ => 'Marcacion registrada',
    };
  }

  void _actualizarHistorialConAsistenciaActual() {
    final asistencia = _asistenciaHoy;
    if (asistencia == null || !mounted) {
      return;
    }
    final fecha = _fechaRegistro(asistencia);
    if (fecha == null) {
      return;
    }
    final key = _fechaKey(fecha);
    final actualizados = [
      Map<String, dynamic>.from(asistencia),
      ..._historialActual.where((item) {
        final itemFecha = _fechaRegistro(item);
        return itemFecha == null || _fechaKey(itemFecha) != key;
      }),
    ];
    setState(() => _historialActual = actualizados);
  }

  Future<void> _recargarDespuesDeMarcacion() async {
    await _ejecutarRecargaParcial('asistencia', _cargarAsistencia);
    await _ejecutarRecargaParcial('historial', _cargarHistorial);
    await _ejecutarRecargaParcial('tracking', _cargarTracking);
    await _ejecutarRecargaParcial(
      'sincronizacion_tracking',
      _sincronizarAsistenciaConTracking,
    );
    await _ejecutarRecargaParcial('horario_dia', _verificarHorarioDelDia);
  }

  Future<void> _ejecutarRecargaParcial(
    String nombre,
    Future<void> Function() accion,
  ) async {
    try {
      await accion();
    } catch (e, st) {
      AppLogger.error('Home', 'Error en recarga parcial', e, st, {
        'dni': AppLogger.shortId(_dni),
        'parte': nombre,
      });
    }
  }

  void _mostrarMensaje(String msg, {bool esError = false}) {
    if (!mounted) {
      return;
    }

    TopMessageService.show(context, msg, isError: esError);
  }

  bool get _horarioManualActivo =>
      _horarioHoy?['origen']?.toString() == _origenHorarioManual;

  Map<String, dynamic>? _inferirHorarioManualDesdeAsistencia(
    Map<String, dynamic>? asistencia,
  ) {
    if (asistencia == null) {
      return null;
    }

    final ubicacionesRaw = asistencia['ubicaciones'];
    Map<String, dynamic> ubicaciones = <String, dynamic>{};
    if (ubicacionesRaw is Map) {
      ubicaciones = Map<String, dynamic>.from(ubicacionesRaw);
    } else if (ubicacionesRaw is String && ubicacionesRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(ubicacionesRaw);
        if (decoded is Map) {
          ubicaciones = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // Se intenta la inferencia por marcas como compatibilidad.
      }
    }
    final jornadaRaw = ubicaciones['_jornada_manual'];
    if (jornadaRaw is Map) {
      final tipo = jornadaRaw['tipo_jornada']?.toString().toLowerCase();
      if (tipo == 'parttime' || tipo == 'part_time' || tipo == '2_marcas') {
        return _horarioManual('parttime');
      }
      if (tipo == 'fulltime' || tipo == 'full_time' || tipo == '4_marcas') {
        return _horarioManual('fulltime');
      }
    }

    final tieneEntrada = _marcaExiste(asistencia['horario_entrada']);
    final tieneSalida = _marcaExiste(asistencia['horario_salida']);
    final tieneReceso =
        _marcaExiste(asistencia['horario_inicio_receso']) ||
        _marcaExiste(asistencia['horario_fin_receso']);

    if (tieneReceso) {
      return _horarioManual('fulltime');
    }

    if (tieneEntrada && tieneSalida) {
      return _horarioManual('parttime');
    }

    return null;
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

  String _fechaKey(DateTime fecha) {
    final local = fecha.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  DateTime? _fechaTracking(Map<String, dynamic> registro) {
    final ubicaciones = _ubicacionesTracking(registro);
    return _parseSupabaseDateTime(
      registro['Fecha'] ??
          registro['fecha'] ??
          registro['hora_marca'] ??
          ubicaciones['hora_marca'] ??
          ubicaciones['registrado_en'],
    );
  }

  Map<String, dynamic> _ubicacionesTracking(Map<String, dynamic> registro) {
    final ubicaciones = registro['ubicaciones'] ?? registro['ubicacion'];
    final resultado = <String, dynamic>{};
    if (ubicaciones is Map<String, dynamic>) {
      resultado.addAll(ubicaciones);
    } else if (ubicaciones is Map) {
      resultado.addAll(Map<String, dynamic>.from(ubicaciones));
    } else if (ubicaciones is String && ubicaciones.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(ubicaciones);
        if (parsed is Map<String, dynamic>) {
          resultado.addAll(parsed);
        } else if (parsed is Map) {
          resultado.addAll(Map<String, dynamic>.from(parsed));
        }
      } catch (_) {
        // Los exports antiguos pueden traer JSON como texto; si no parsea,
        // seguimos con los campos planos del registro.
      }
    }

    void agregarSiFalta(String clave, Object? valor) {
      if (valor != null && !resultado.containsKey(clave)) {
        resultado[clave] = valor;
      }
    }

    agregarSiFalta('dni_trabajador', registro['id_trabajador']);
    agregarSiFalta('id_tienda_qr', registro['id_tienda']);
    agregarSiFalta('hora_marca', registro['hora_marca']);
    agregarSiFalta('registrado_en', registro['hora_marca']);
    agregarSiFalta('tipo', registro['tipo']);
    agregarSiFalta('nombre_tienda', registro['nombre_tienda']);
    agregarSiFalta('direccion_tienda', registro['direccion_tienda']);
    agregarSiFalta('nombre_trabajador', registro['nombre_trabajador']);
    agregarSiFalta('cargo_trabajador', registro['cargo_trabajador']);

    return resultado;
  }

  List<Map<String, dynamic>> _trackingOrdenado(
    Iterable<Map<String, dynamic>> registros,
  ) {
    final ordenados = registros.map(Map<String, dynamic>.from).toList();
    ordenados.sort((a, b) {
      final fechaA = _fechaTracking(a);
      final fechaB = _fechaTracking(b);
      if (fechaA == null && fechaB == null) {
        return 0;
      }
      if (fechaA == null) {
        return 1;
      }
      if (fechaB == null) {
        return -1;
      }
      return fechaA.compareTo(fechaB);
    });
    return ordenados;
  }

  List<Map<String, dynamic>> _trackingCombinado(
    Iterable<Map<String, dynamic>> tracking,
    Map<String, dynamic>? asistencia,
  ) {
    if (asistencia == null || !_marcaExiste(asistencia['horario_entrada'])) {
      return [];
    }

    final sinteticos = _trackingDesdeAsistencia(asistencia);
    final sinteticosPorFecha = <String, Map<String, dynamic>>{};
    for (final sintetico in sinteticos) {
      final clave = _claveFechaTracking(sintetico);
      if (clave.isNotEmpty) {
        sinteticosPorFecha[clave] = sintetico;
      }
    }

    final fechasNormalesReales = <String>{};
    final registros = <Map<String, dynamic>>[];

    for (final registro in tracking) {
      final esNormal = _tipoMovimientoTracking(registro) == 'NORMAL';
      if (!esNormal) {
        registros.add(registro);
        continue;
      }

      final clave = _claveFechaTracking(registro);
      final sintetico =
          sinteticosPorFecha[clave] ??
          _sinteticoCercanoParaTrackingNormal(registro, sinteticos);
      final tipoExplicito = _tipoMarcacionExplicita(registro);
      if (sintetico == null && tipoExplicito == null) {
        continue;
      }
      final claveSintetico = sintetico == null
          ? ''
          : _claveFechaTracking(sintetico);
      if (claveSintetico.isNotEmpty) {
        fechasNormalesReales.add(claveSintetico);
      }
      registros.add(_fusionarTrackingNormal(registro, sintetico));
    }

    for (final sintetico in sinteticos) {
      final clave = _claveFechaTracking(sintetico);
      if (clave.isEmpty || !fechasNormalesReales.contains(clave)) {
        registros.add(sintetico);
      }
    }

    return _deduplicarTrackingVisual(registros);
  }

  List<Map<String, dynamic>> _trackingDesdeAsistencia(
    Map<String, dynamic>? asistencia,
  ) {
    if (asistencia == null) {
      return [];
    }

    final registros = <Map<String, dynamic>>[];
    final ubicaciones = asistencia['ubicaciones'] is Map
        ? Map<String, dynamic>.from(asistencia['ubicaciones'] as Map)
        : <String, dynamic>{};
    String valorConFallback(Object? valor, String fallback) {
      final texto = valor?.toString().trim() ?? '';
      return texto.isNotEmpty ? texto : fallback;
    }

    for (final item in _marcacionesParaDetalle(asistencia)) {
      final marca = asistencia[item.$2];
      if (!_marcaExiste(marca)) {
        continue;
      }

      final detalleUbicacion = ubicaciones[item.$2] is Map
          ? Map<String, dynamic>.from(ubicaciones[item.$2] as Map)
          : <String, dynamic>{};

      registros.add({
        'Fecha': marca,
        'ubicaciones': {
          'latitud': detalleUbicacion['latitud'],
          'longitud': detalleUbicacion['longitud'],
          'id_tienda_qr': valorConFallback(
            detalleUbicacion['id_tienda_qr'],
            widget.usuario['id_tienda']?.toString() ?? '',
          ),
          'nombre_tienda': valorConFallback(
            detalleUbicacion['nombre_tienda'],
            widget.usuario['nombre_tienda']?.toString() ?? 'Tienda asignada',
          ),
          'direccion_tienda': valorConFallback(
            detalleUbicacion['direccion_tienda'],
            widget.usuario['direccion_tienda']?.toString() ?? '',
          ),
          'dni_trabajador': _dni,
          'nombre_trabajador': widget.usuario['nombre']?.toString() ?? '',
          'cargo_trabajador': widget.usuario['cargo']?.toString() ?? '',
          'tipo_marcacion': item.$1,
          'origen': 'normal',
          'tipo': 'NORMAL',
          'registrado_en': marca.toString(),
        },
      });
    }

    return registros;
  }

  Map<String, dynamic>? _sinteticoCercanoParaTrackingNormal(
    Map<String, dynamic> real,
    List<Map<String, dynamic>> sinteticos,
  ) {
    if (_tipoMovimientoTracking(real) != 'NORMAL') {
      return null;
    }

    final fechaReal = _fechaTracking(real)?.toLocal();
    if (fechaReal == null) {
      return null;
    }

    final tipoReal = _tipoMarcacionExplicita(real);
    Map<String, dynamic>? mejor;
    Duration? menorDiferencia;

    for (final sintetico in sinteticos) {
      final fechaSintetica = _fechaTracking(sintetico)?.toLocal();
      if (fechaSintetica == null ||
          fechaSintetica.year != fechaReal.year ||
          fechaSintetica.month != fechaReal.month ||
          fechaSintetica.day != fechaReal.day) {
        continue;
      }

      final tipoSintetico = _tipoMarcacionExplicita(sintetico);
      if (tipoReal != null &&
          tipoSintetico != null &&
          tipoReal != tipoSintetico) {
        continue;
      }

      final diferencia = fechaSintetica.difference(fechaReal).abs();
      if (diferencia > _toleranciaFusionMarcacionNormal) {
        continue;
      }

      if (menorDiferencia == null || diferencia < menorDiferencia) {
        menorDiferencia = diferencia;
        mejor = sintetico;
      }
    }

    return mejor;
  }

  String _claveFechaTracking(Map<String, dynamic> registro) {
    final fecha = _fechaTracking(registro)?.toLocal();
    if (fecha == null) {
      return registro['Fecha']?.toString() ??
          registro['hora_marca']?.toString() ??
          '';
    }

    return DateTime(
      fecha.year,
      fecha.month,
      fecha.day,
      fecha.hour,
      fecha.minute,
      fecha.second,
    ).toIso8601String();
  }

  Map<String, dynamic> _fusionarTrackingNormal(
    Map<String, dynamic> real,
    Map<String, dynamic>? sintetico,
  ) {
    if (sintetico == null) {
      return real;
    }

    final combinado = Map<String, dynamic>.from(real);
    final ubicacionReal = _ubicacionesTracking(real);
    final ubicacionSintetica = _ubicacionesTracking(sintetico);
    final ubicaciones = <String, dynamic>{
      ...ubicacionSintetica,
      ...ubicacionReal,
    };

    final tipoReal = ubicacionReal['tipo_marcacion']?.toString().trim();
    if (tipoReal == null || tipoReal.isEmpty) {
      ubicaciones['tipo_marcacion'] = ubicacionSintetica['tipo_marcacion'];
    }

    ubicaciones['origen'] = 'normal';
    ubicaciones['tipo'] = 'NORMAL';
    combinado['ubicaciones'] = ubicaciones;
    return combinado;
  }

  List<Map<String, dynamic>> _deduplicarTrackingVisual(
    Iterable<Map<String, dynamic>> registros,
  ) {
    final posiciones = <String, int>{};
    final resultado = <Map<String, dynamic>>[];

    for (final registro in _trackingOrdenado(registros)) {
      final ubicaciones = _ubicacionesTracking(registro);
      final fecha =
          _fechaTracking(registro)?.toIso8601String() ??
          registro['Fecha']?.toString() ??
          '';
      final tipoMovimiento = _tipoMovimientoTracking(registro);
      final key = [
        fecha,
        tipoMovimiento,
        tipoMovimiento == 'NORMAL'
            ? _tipoTracking(registro)
            : ubicaciones['id_tienda_qr']?.toString() ?? '',
      ].join('|');
      final posicion = posiciones[key];
      if (posicion == null) {
        posiciones[key] = resultado.length;
        resultado.add(registro);
        continue;
      }

      final actual = resultado[posicion];
      final actualTieneNombre =
          _ubicacionesTracking(
            actual,
          )['tipo_marcacion']?.toString().trim().isNotEmpty ==
          true;
      final nuevoTieneNombre =
          ubicaciones['tipo_marcacion']?.toString().trim().isNotEmpty == true;
      if (!actualTieneNombre && nuevoTieneNombre) {
        resultado[posicion] = registro;
      }
    }

    return resultado;
  }

  Color _colorModo(_ModoRegistro modo) {
    return modo == _ModoRegistro.asistencia
        ? AppPalette.verdeAzulado
        : AppPalette.celesteClaro;
  }

  List<Map<String, dynamic>> _trackingParaDia(
    List<Map<String, dynamic>> registros,
    DateTime mes,
    int? dia,
  ) {
    if (dia == null) {
      return [];
    }

    return _trackingOrdenado(
      registros.where((reg) {
        final fecha = _fechaTracking(reg)?.toLocal();
        return fecha != null &&
            fecha.year == mes.year &&
            fecha.month == mes.month &&
            fecha.day == dia;
      }),
    );
  }

  String _nombreTiendaTracking(Map<String, dynamic> registro) {
    final ubicaciones = _ubicacionesTracking(registro);
    final nombres = [
      ubicaciones['nombre_tienda']?.toString().trim(),
      registro['nombre_tienda']?.toString().trim(),
    ];
    for (final nombre in nombres) {
      if (nombre != null && nombre.isNotEmpty) {
        return nombre;
      }
    }

    final ids = [
      ubicaciones['id_tienda_qr']?.toString().trim(),
      registro['id_tienda']?.toString().trim(),
    ];
    for (final idTienda in ids) {
      if (idTienda != null && idTienda.isNotEmpty) {
        return 'Tienda $idTienda';
      }
    }

    return 'Tienda';
  }

  String _horaTracking(Map<String, dynamic> registro, {bool corta = false}) {
    final fecha = _fechaTracking(registro)?.toLocal();
    if (fecha == null) {
      return '--:--';
    }
    return DateFormat(corta ? 'HH:mm' : 'hh:mm a').format(fecha);
  }

  String _tipoTracking(Map<String, dynamic> registro) {
    final tipo = _tipoMarcacionExplicita(registro);
    if (tipo != null && tipo.isNotEmpty) {
      return tipo;
    }
    return _tipoMovimientoTracking(registro) == 'NORMAL'
        ? 'Marca normal'
        : 'Marca';
  }

  String? _tipoMarcacionExplicita(Map<String, dynamic> registro) {
    final ubicaciones = _ubicacionesTracking(registro);
    final candidatos = [
      ubicaciones['tipo_marcacion'],
      registro['tipo_marcacion'],
    ];

    for (final candidato in candidatos) {
      final tipo = candidato?.toString().trim();
      if (tipo != null && tipo.isNotEmpty) {
        return tipo;
      }
    }

    return null;
  }

  String _subtituloTracking(Map<String, dynamic> registro) {
    return 'Sede: ${_nombreTiendaTracking(registro)}';
  }

  String _tipoMovimientoTracking(Map<String, dynamic> registro) {
    final ubicaciones = _ubicacionesTracking(registro);
    final candidatos = [
      ubicaciones['tipo'],
      registro['tipo'],
      ubicaciones['origen'],
      registro['origen'],
    ];

    for (final candidato in candidatos) {
      final tipo = candidato?.toString().trim().toUpperCase();
      if (tipo == null || tipo.isEmpty) {
        continue;
      }
      if (tipo == 'NORMAL') {
        return 'NORMAL';
      }
      if (tipo == 'MULTIPLE' ||
          tipo == 'PUNTO_A_B' ||
          tipo == 'PUNTO-A-B' ||
          tipo == 'PUNTO A B' ||
          tipo == 'TRACKING') {
        return 'MULTIPLE';
      }
    }

    return 'MULTIPLE';
  }

  Color _colorTrackingRegistro(Map<String, dynamic> registro) {
    if (_tipoMovimientoTracking(registro) == 'NORMAL') {
      return AppPalette.verdeAzulado;
    }
    return AppPalette.celesteClaro;
  }

  String _contadorTracking(int cantidad) {
    return cantidad == 1 ? '1 marca' : '$cantidad marcas';
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

    if (mensaje.startsWith('Tu ultima marca de tracking')) {
      return mensaje;
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

  Widget _buildModoRegistroControl() {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<_ModoRegistro>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: _ModoRegistro.asistencia,
            icon: Icon(Icons.badge_outlined, size: 18),
            label: Text('Asistencia'),
          ),
          ButtonSegment(
            value: _ModoRegistro.tracking,
            icon: Icon(Icons.route_outlined, size: 18),
            label: Text('Tracking'),
          ),
        ],
        selected: {_modoRegistro},
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return _colorModo(_modoRegistro).withValues(alpha: 0.92);
            }
            return AppTheme.glassSurface(context, alpha: 0.44);
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return Colors.white;
            }
            return scheme.onSurface.withValues(alpha: 0.82);
          }),
          side: WidgetStatePropertyAll(
            BorderSide(
              color: _colorModo(_modoRegistro).withValues(alpha: 0.42),
            ),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          textStyle: WidgetStatePropertyAll(
            GoogleFonts.robotoCondensed(
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        onSelectionChanged: (selection) {
          setState(() => _modoRegistro = selection.first);
        },
      ),
    );
  }

  Widget _buildHorarioMarcacionesCard() {
    if (_modoRegistro == _ModoRegistro.tracking) {
      return _buildTrackingMarcacionesCard();
    }

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
                'ASISTENCIA DE HOY',
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
          if (_cantidadPendientes > 0) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.secondary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: scheme.secondary.withValues(alpha: 0.48),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.cloud_upload_outlined, color: scheme.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _cantidadPendientes == 1
                          ? '1 marcacion guardada en el equipo, pendiente de sincronizar'
                          : '$_cantidadPendientes marcaciones guardadas en el equipo, pendientes de sincronizar',
                      style: GoogleFonts.robotoCondensed(
                        fontSize: 12,
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          ...marcaciones.map((item) {
            final marcada = _marcaExiste(_asistenciaHoy?[item.$2]);
            final pendienteSincronizar = _marcasPendientesHoy.contains(item.$2);
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
                        pendienteSincronizar
                            ? 'Por sincronizar'
                            : marcada
                            ? 'Marcado'
                            : 'Pendiente',
                        style: GoogleFonts.robotoCondensed(
                          fontSize: 12,
                          color: pendienteSincronizar
                              ? scheme.secondary
                              : marcada
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

  Widget _buildTrackingMarcacionesCard() {
    final scheme = Theme.of(context).colorScheme;
    final tracking = _trackingCombinado(_trackingHoy, _asistenciaHoy);
    final trackingColor = _colorModo(_ModoRegistro.tracking);

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
                'TRACKING DE HOY',
                style: GoogleFonts.robotoCondensed(
                  fontSize: 13,
                  color: scheme.onSurface.withValues(alpha: 0.92),
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                _contadorTracking(tracking.length),
                style: GoogleFonts.bebasNeue(
                  fontSize: 18,
                  color: tracking.isEmpty
                      ? scheme.onSurface.withValues(alpha: 0.66)
                      : trackingColor,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (tracking.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppTheme.glassBorder(context, alpha: 0.16),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.route_outlined,
                    color: scheme.onSurface.withValues(alpha: 0.52),
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Sin movimientos de tracking hoy',
                      style: GoogleFonts.robotoCondensed(
                        fontSize: 13,
                        color: scheme.onSurface.withValues(alpha: 0.78),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            ...tracking.asMap().entries.map(
              (entry) => _buildTrackingMarcaTile(entry.value, entry.key + 1),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTrackingMarcaTile(Map<String, dynamic> registro, int index) {
    final scheme = Theme.of(context).colorScheme;
    final trackingColor = _colorTrackingRegistro(registro);
    final tipo = _tipoTracking(registro);
    final subtitulo = _subtituloTracking(registro);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: trackingColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: trackingColor.withValues(alpha: 0.62)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: trackingColor.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: trackingColor),
            ),
            child: Center(
              child: Text(
                index.toString(),
                style: GoogleFonts.bebasNeue(
                  fontSize: 16,
                  color: trackingColor,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tipo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.robotoCondensed(
                    fontSize: 14,
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.robotoCondensed(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.64),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _horaTracking(registro),
            style: GoogleFonts.bebasNeue(
              fontSize: 20,
              color: trackingColor,
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
    final trackingDatos = _mesSeleccionado == 0
        ? _trackingActual
        : _trackingAnterior;
    final mes = _mesSeleccionado == 0
        ? DateTime(ahora.year, ahora.month)
        : DateTime(ahora.year, ahora.month - 1);

    final primerDia = DateTime(mes.year, mes.month);
    final ultimoDia = DateTime(mes.year, mes.month + 1, 0);
    final diasDelMes = ultimoDia.day;
    final diaInicio = primerDia.weekday;

    final diasConAsistencia = <int>{};
    final diasConEntrada = <int>{};
    for (final reg in datos) {
      final fecha = _fechaRegistro(reg);
      if (fecha != null && fecha.year == mes.year && fecha.month == mes.month) {
        diasConAsistencia.add(fecha.day);
        if (_marcaExiste(reg['horario_entrada'])) {
          diasConEntrada.add(fecha.day);
        }
      }
    }

    final diasConTracking = <int>{};
    for (final reg in trackingDatos) {
      final fecha = _fechaTracking(reg)?.toLocal();
      if (fecha != null &&
          fecha.year == mes.year &&
          fecha.month == mes.month &&
          diasConEntrada.contains(fecha.day)) {
        diasConTracking.add(fecha.day);
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
    final trackingDia = _trackingCombinado(
      _trackingParaDia(trackingDatos, mes, _diaSeleccionado),
      detallesDia,
    );

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
                  final tieneTracking = diasConTracking.contains(dia);
                  final tieneActividad = tieneAsistencia || tieneTracking;
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
                            : tieneTracking
                            ? AppPalette.celesteClaro.withValues(alpha: 0.22)
                            : scheme.onSurface.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: esSeleccionado
                              ? AppPalette.turquesaBrillante
                              : tieneAsistencia
                              ? AppPalette.verdeAzulado
                              : tieneTracking
                              ? AppPalette.celesteClaro
                              : AppTheme.glassBorder(context, alpha: 0.12),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            dia.toString(),
                            style: GoogleFonts.bebasNeue(
                              fontSize: 12,
                              color: tieneActividad || esSeleccionado
                                  ? Colors.white
                                  : scheme.onSurface.withValues(alpha: 0.72),
                              letterSpacing: 0.5,
                            ),
                          ),
                          if (tieneActividad) ...[
                            const SizedBox(height: 3),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (tieneAsistencia)
                                  Container(
                                    width: 4,
                                    height: 4,
                                    decoration: const BoxDecoration(
                                      color: AppPalette.turquesaBrillante,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                if (tieneAsistencia && tieneTracking)
                                  const SizedBox(width: 3),
                                if (tieneTracking)
                                  Container(
                                    width: 4,
                                    height: 4,
                                    decoration: const BoxDecoration(
                                      color: AppPalette.celesteClaro,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        if (detallesDia != null || trackingDia.isNotEmpty) ...[
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
                if (trackingDia.isEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.glassBorder(context, alpha: 0.14),
                      ),
                    ),
                    child: Text(
                      'Sin marcaciones registradas',
                      style: GoogleFonts.robotoCondensed(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  ...trackingDia.asMap().entries.map(
                    (entry) =>
                        _buildTrackingMarcaTile(entry.value, entry.key + 1),
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
    final textoScanner = _modoRegistro == _ModoRegistro.tracking
        ? 'Apunta al QR de la tienda para tracking'
        : 'Apunta al QR de la tienda';

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
            textoScanner,
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

  String _textoBotonScanner(bool scannerBloqueado) {
    if (_modoRegistro == _ModoRegistro.tracking) {
      return 'ESCANEAR QR DE TRACKING';
    }

    if (scannerBloqueado) {
      return 'ESPERA ${_formatearCooldown(_cooldownRestante)}';
    }

    return 'ESCANEAR QR PARA MARCAR';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final scannerBloqueado =
        _modoRegistro == _ModoRegistro.asistencia && _enCooldown;
    final textoBoton = _textoBotonScanner(scannerBloqueado);
    final colorModo = _colorModo(_modoRegistro);

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
                          _buildModoRegistroControl(),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            onPressed: scannerBloqueado
                                ? null
                                : _abrirScannerConRequisitos,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colorModo,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: colorModo.withValues(
                                alpha: 0.45,
                              ),
                              minimumSize: const Size.fromHeight(52),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: Text(
                              textoBoton,
                              style: GoogleFonts.bebasNeue(
                                fontSize: 18,
                                color: Colors.white,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                          if (scannerBloqueado) ...[
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
