import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_logger.dart';
import 'qr_service.dart';

class SupabaseService {
  final SupabaseClient _db = Supabase.instance.client;
  static const Duration _cooldownMarcacion = Duration(minutes: 10);
  static const List<String> _tablasAsistencia = ['asistencia', 'asistencias'];

  Future<Map<String, dynamic>?> buscarUsuario(String identificador) async {
    final idNormalizado = _normalizarIdentificador(identificador);
    AppLogger.info('SupabaseService', 'Buscar usuario por identificador', {
      'identificador': AppLogger.shortId(idNormalizado),
    });

    final trabajador = await _buscarTrabajador(idNormalizado);
    if (trabajador == null || trabajador['estado'] == false) {
      AppLogger.warning('SupabaseService', 'Usuario no encontrado o inactivo', {
        'identificador': AppLogger.shortId(idNormalizado),
      });
      return null;
    }

    AppLogger.info('SupabaseService', 'Usuario encontrado', {
      'dni': AppLogger.shortId(trabajador['dni']?.toString() ?? ''),
    });
    return await _normalizarTrabajador(trabajador);
  }

  Future<Map<String, dynamic>?> buscarUsuarioPorCredenciales(
    String identificador,
    String password,
  ) async {
    try {
      final idNormalizado = _normalizarIdentificador(identificador);
      AppLogger.info('SupabaseService', 'Consultando credenciales', {
        'identificador': _maskIdentificador(idNormalizado),
      });

      final trabajadorRpc = await _loginTrabajadorRpc(idNormalizado, password);
      if (trabajadorRpc != null) {
        return await _normalizarTrabajador(trabajadorRpc);
      }

      final trabajador = await _buscarTrabajador(idNormalizado);
      if (trabajador == null) {
        AppLogger.warning('SupabaseService', 'No existe trabajador', {
          'identificador': _maskIdentificador(idNormalizado),
        });
        return null;
      }

      if (trabajador['estado'] == false) {
        AppLogger.warning('SupabaseService', 'Trabajador inactivo', {
          'dni': AppLogger.shortId(trabajador['dni']?.toString() ?? ''),
        });
        return null;
      }

      final contrasena = trabajador['contrasena']?.toString();

      if (contrasena == null || contrasena != password) {
        AppLogger.warning('SupabaseService', 'Contrasena no coincide', {
          'identificador': _maskIdentificador(idNormalizado),
          'dni': AppLogger.shortId(trabajador['dni']?.toString() ?? ''),
        });
        return null;
      }

      AppLogger.info('SupabaseService', 'Credenciales validadas', {
        'dni': AppLogger.shortId(trabajador['dni']?.toString() ?? ''),
        'id_tienda': AppLogger.shortId(
          trabajador['id_tienda']?.toString() ?? '',
        ),
      });
      return await _normalizarTrabajador(trabajador);
    } catch (e, st) {
      AppLogger.error(
        'SupabaseService',
        'Error consultando credenciales',
        e,
        st,
        {'identificador': _maskIdentificador(identificador)},
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _loginTrabajadorRpc(
    String identificador,
    String password,
  ) async {
    try {
      AppLogger.info('SupabaseService', 'Intentando login por RPC', {
        'identificador': _maskIdentificador(identificador),
      });

      final response = await _db.rpc(
        'login_trabajador',
        params: {'p_identificador': identificador, 'p_contrasena': password},
      );

      final row = _firstRow(response);
      if (row == null) {
        AppLogger.warning('SupabaseService', 'RPC rechazo credenciales', {
          'identificador': _maskIdentificador(identificador),
        });
        return null;
      }

      AppLogger.info('SupabaseService', 'RPC valido credenciales', {
        'dni': AppLogger.shortId(row['dni']?.toString() ?? ''),
        'id_tienda': AppLogger.shortId(row['id_tienda']?.toString() ?? ''),
      });
      return row;
    } on PostgrestException catch (e, st) {
      final rpcNoExiste =
          e.code == '42883' || e.message.contains('login_trabajador');
      if (rpcNoExiste) {
        AppLogger.warning(
          'SupabaseService',
          'RPC login_trabajador no existe, usando consulta directa',
          {'code': e.code},
        );
        return null;
      }

      AppLogger.error(
        'SupabaseService',
        'Error en RPC login_trabajador',
        e,
        st,
        {'identificador': _maskIdentificador(identificador), 'code': e.code},
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> obtenerAsistenciaHoy(String dni) async {
    try {
      AppLogger.info(
        'SupabaseService',
        'Consultando asistencia de hoy por RPC',
        {'dni': AppLogger.shortId(dni)},
      );

      final response = await _db.rpc(
        'obtener_asistencia_hoy',
        params: {'p_dni': dni},
      );

      if (response == null || (response is List && response.isEmpty)) {
        AppLogger.info(
          'SupabaseService',
          'Sin asistencia registrada hoy por RPC',
          {'dni': AppLogger.shortId(dni)},
        );
        return null;
      }

      final data = response is List ? response.first : response;
      if (data is! Map && data is! Map<String, dynamic>) {
        AppLogger.warning(
          'SupabaseService',
          'Respuesta RPC inesperada, usando fallback directo',
          {
            'dni': AppLogger.shortId(dni),
            'response_type': response.runtimeType.toString(),
          },
        );
        return await _obtenerAsistenciaHoyDirecto(dni);
      }

      AppLogger.info('SupabaseService', 'Asistencia de hoy encontrada', {
        'dni': AppLogger.shortId(dni),
      });
      return Map<String, dynamic>.from(data as Map);
    } catch (e) {
      AppLogger.warning(
        'SupabaseService',
        'Error consultando asistencia por RPC, intentando fallback',
        {'dni': AppLogger.shortId(dni), 'error': e.toString()},
      );
      return await _obtenerAsistenciaHoyDirecto(dni);
    }
  }

  Future<Map<String, dynamic>?> _obtenerAsistenciaHoyDirecto(String dni) async {
    try {
      final hoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      AppLogger.info(
        'SupabaseService',
        'Consultando asistencia de hoy directo',
        {'dni': AppLogger.shortId(dni), 'fecha': hoy},
      );

      final response = await _selectAsistenciaHoyDirecto(dni, hoy);

      if (response == null || response.isEmpty) {
        AppLogger.info(
          'SupabaseService',
          'Sin asistencia registrada hoy directo',
          {'dni': AppLogger.shortId(dni), 'fecha': hoy},
        );
        return null;
      }

      return Map<String, dynamic>.from(response.first);
    } catch (e, st) {
      AppLogger.error(
        'SupabaseService',
        'Error consultando asistencia directa',
        e,
        st,
        {'dni': AppLogger.shortId(dni)},
      );
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> obtenerHistorialAsistenciasMes(
    String dni,
    DateTime fechaMes,
  ) async {
    try {
      final year = fechaMes.year;
      final month = fechaMes.month;

      AppLogger.info(
        'SupabaseService',
        'Consultando historial mensual por RPC',
        {'dni': AppLogger.shortId(dni), 'year': year, 'month': month},
      );

      final response = await _db.rpc(
        'obtener_historial_asistencias_mes',
        params: {'p_dni': dni, 'p_year': year, 'p_month': month},
      );

      if (response == null || (response is List && response.isEmpty)) {
        AppLogger.info('SupabaseService', 'Sin historial para el mes por RPC', {
          'dni': AppLogger.shortId(dni),
          'year': year,
          'month': month,
        });
        return await _obtenerHistorialDirecto(dni, fechaMes);
      }

      AppLogger.info('SupabaseService', 'Historial mensual recibido', {
        'dni': AppLogger.shortId(dni),
        'registros': response is List ? response.length : 1,
      });

      if (response is List) {
        return List<Map<String, dynamic>>.from(
          response.map((item) => Map<String, dynamic>.from(item)),
        );
      } else {
        return [Map<String, dynamic>.from(response)];
      }
    } catch (e) {
      AppLogger.warning(
        'SupabaseService',
        'Error consultando historial por RPC, intentando fallback',
        {'dni': AppLogger.shortId(dni), 'error': e.toString()},
      );
      return await _obtenerHistorialDirecto(dni, fechaMes);
    }
  }

  Future<List<Map<String, dynamic>>> _obtenerHistorialDirecto(
    String dni,
    DateTime fechaMes,
  ) async {
    try {
      final inicioMes = DateTime(fechaMes.year, fechaMes.month);
      final finMes = DateTime(fechaMes.year, fechaMes.month + 1, 0);
      final inicio = DateFormat('yyyy-MM-dd').format(inicioMes);
      final fin = DateFormat('yyyy-MM-dd').format(finMes);

      AppLogger.info('SupabaseService', 'Consultando historial directo', {
        'dni': AppLogger.shortId(dni),
        'inicio': inicio,
        'fin': fin,
      });

      final response = await _selectHistorialDirecto(dni, inicio, fin);

      return List<Map<String, dynamic>>.from(
        response.map((item) => Map<String, dynamic>.from(item)),
      );
    } catch (e, st) {
      AppLogger.error(
        'SupabaseService',
        'Error consultando historial directo',
        e,
        st,
        {'dni': AppLogger.shortId(dni)},
      );
      return [];
    }
  }

  Future<String> registrarMarcacion(
    Map<String, dynamic> usuario,
    QRValidado qrValidado, {
    required Map<String, double> ubicacion,
    Map<String, dynamic>? horarioManual,
  }) async {
    try {
      final dni =
          usuario['dni']?.toString() ??
          usuario['id_trabajador']?.toString() ??
          '';

      AppLogger.info('SupabaseService', 'Registrando marcacion', {
        'dni': AppLogger.shortId(dni),
        'id_tienda_qr': AppLogger.shortId(qrValidado.idTienda),
      });

      if (dni.isEmpty) {
        AppLogger.warning('SupabaseService', 'Marcacion sin DNI');
        throw Exception(
          'Falta el DNI del trabajador para registrar asistencia.',
        );
      }

      if (horarioManual == null) {
        final resultadoRpc = await _registrarMarcacionRpc(
          dni: dni,
          token: qrValidado.token,
          ubicacion: ubicacion,
        );
        if (resultadoRpc != null) {
          return resultadoRpc;
        }
      }

      if (_esPayloadQrDinamico(qrValidado.token)) {
        throw Exception('No se pudo validar el codigo de asistencia.');
      }

      final hoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final existente = await _selectAsistenciaHoyDirecto(dni, hoy) ?? [];
      final horario =
          horarioManual ??
          await obtenerHorarioTrabajador(dni, diaSemana: _diaHoy());
      final justificado = horarioManual == null && horario != null;

      final asistencia = existente.isEmpty
          ? <String, dynamic>{
              'dni_trabajador': dni,
              'fecha': hoy,
              'horario_entrada': null,
              'horario_inicio_receso': null,
              'horario_fin_receso': null,
              'horario_salida': null,
              'justificado': justificado,
            }
          : Map<String, dynamic>.from(existente.first);

      final orden = _ordenMarcacionesParaHorario(horario);

      final ultimaMarcacion = _ultimaMarcacion(asistencia, orden);
      if (ultimaMarcacion != null) {
        final esperaRestante =
            _cooldownMarcacion -
            DateTime.now().difference(ultimaMarcacion.toLocal());
        if (!esperaRestante.isNegative && esperaRestante.inSeconds > 0) {
          final minutos = esperaRestante.inMinutes + 1;
          AppLogger.warning('SupabaseService', 'Marcacion en cooldown', {
            'dni': AppLogger.shortId(dni),
            'minutos_restantes': minutos,
          });
          return 'Debes esperar $minutos minutos antes de volver a marcar';
        }
      }

      final tipoMarcacion = orden.cast<String?>().firstWhere(
        (campo) => asistencia[campo] == null,
        orElse: () => null,
      );

      if (tipoMarcacion == null) {
        AppLogger.info('SupabaseService', 'Marcaciones ya completas', {
          'dni': AppLogger.shortId(dni),
          'fecha': hoy,
        });
        return 'Ya completaste todas las marcaciones de hoy';
      }

      final cambios = {
        tipoMarcacion: _timestampLocalConZona(),
        'justificado': justificado,
        ..._camposUbicacion(asistencia, tipoMarcacion, ubicacion),
      };

      if (existente.isEmpty) {
        await _insertAsistencia({...asistencia, ...cambios});
        AppLogger.info('SupabaseService', 'Asistencia creada', {
          'dni': AppLogger.shortId(dni),
          'fecha': hoy,
          'tipo': tipoMarcacion,
        });
      } else {
        await _updateAsistencia(dni, hoy, cambios);
        AppLogger.info('SupabaseService', 'Asistencia actualizada', {
          'dni': AppLogger.shortId(dni),
          'fecha': hoy,
          'tipo': tipoMarcacion,
        });
      }

      const nombres = {
        'horario_entrada': 'Entrada',
        'horario_inicio_receso': 'Inicio de receso',
        'horario_fin_receso': 'Fin de receso',
        'horario_salida': 'Salida',
      };

      return nombres[tipoMarcacion] ?? tipoMarcacion;
    } catch (e, st) {
      AppLogger.error('SupabaseService', 'Error registrando marcacion', e, st);
      rethrow;
    }
  }

  Future<String?> _registrarMarcacionRpc({
    required String dni,
    required String token,
    required Map<String, double> ubicacion,
  }) async {
    try {
      AppLogger.info('SupabaseService', 'Intentando marcacion por RPC', {
        'dni': AppLogger.shortId(dni),
        'token': AppLogger.shortId(token),
        'token_length': token.length,
      });

      final response = await _db.rpc(
        'registrar_marcacion_asistencia_qr',
        params: {
          'p_dni': dni,
          'p_token': token,
          'p_latitud': ubicacion['latitude'],
          'p_longitud': ubicacion['longitude'],
        },
      );

      final row = _firstRow(response);
      if (row == null) {
        AppLogger.warning('SupabaseService', 'RPC marcacion sin respuesta', {
          'dni': AppLogger.shortId(dni),
        });
        return null;
      }

      final ok = row['ok'] == true;
      final mensaje = row['mensaje']?.toString() ?? '';
      AppLogger.info('SupabaseService', 'RPC marcacion respondio', {
        'dni': AppLogger.shortId(dni),
        'ok': ok,
        'mensaje': mensaje,
        'tipo': row['tipo_marcacion']?.toString() ?? '',
        'id_asistencia': AppLogger.shortId(
          row['id_asistencia']?.toString() ?? '',
        ),
      });

      if (mensaje.isEmpty) {
        return ok ? 'Marcacion registrada' : 'No se pudo registrar la marca';
      }

      return mensaje;
    } on PostgrestException catch (e, st) {
      final rpcNoExiste =
          e.code == 'PGRST202' ||
          e.code == 'PGRST203' ||
          e.code == '42883' ||
          e.message.contains('registrar_marcacion_asistencia_qr');

      AppLogger.error(
        'SupabaseService',
        'Error en RPC registrar_marcacion_asistencia_qr',
        e,
        st,
        {
          'dni': AppLogger.shortId(dni),
          'code': e.code,
          'fallback_directo': rpcNoExiste,
        },
      );

      if (rpcNoExiste) {
        return null;
      }

      rethrow;
    }
  }

  Future<void> aplicarJornadaManual(
    String dni,
    Map<String, dynamic> horarioManual,
  ) async {
    try {
      final dniLimpio = dni.trim();
      if (dniLimpio.isEmpty) {
        return;
      }

      final hoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final existente = await _selectAsistenciaHoyDirecto(dniLimpio, hoy) ?? [];
      final cambiosJornada = {
        'justificado': false,
        ..._camposAsistenciaParaJornadaManual(horarioManual),
      };

      if (existente.isEmpty) {
        await _insertAsistencia({
          'dni_trabajador': dniLimpio,
          'fecha': hoy,
          'horario_entrada': null,
          'horario_inicio_receso': null,
          'horario_fin_receso': null,
          'horario_salida': null,
          'ubicaciones': <String, dynamic>{},
          ...cambiosJornada,
        });
      } else {
        await _updateAsistencia(dniLimpio, hoy, cambiosJornada);
      }

      AppLogger.info('SupabaseService', 'Jornada manual aplicada', {
        'dni': AppLogger.shortId(dniLimpio),
        'fecha': hoy,
        'tipo': horarioManual['tipo_jornada']?.toString() ?? '',
        'receso': _horarioTieneReceso(horarioManual),
      });
    } catch (e, st) {
      AppLogger.error(
        'SupabaseService',
        'No se pudo aplicar jornada manual',
        e,
        st,
        {'dni': AppLogger.shortId(dni)},
      );
      rethrow;
    }
  }

  Map<String, dynamic> _camposAsistenciaParaJornadaManual(
    Map<String, dynamic> horarioManual,
  ) {
    if (_horarioTieneReceso(horarioManual)) {
      return {};
    }

    return {'horario_inicio_receso': null, 'horario_fin_receso': null};
  }

  Future<Map<String, dynamic>?> obtenerHorarioTrabajador(
    String dni, {
    String? diaSemana,
  }) async {
    try {
      AppLogger.info('SupabaseService', 'Consultando horario trabajador', {
        'dni': AppLogger.shortId(dni),
        'dia': diaSemana ?? 'todos',
      });

      try {
        final response = await _db.rpc(
          'obtener_horario_trabajador',
          params: {'p_dni': dni, 'p_dia_semana': diaSemana},
        );

        final horariosRpc = _normalizarHorarios(response, diaSemana);
        if (horariosRpc == null) {
          AppLogger.warning('SupabaseService', 'Horario RPC no encontrado', {
            'dni': AppLogger.shortId(dni),
            'dia': diaSemana ?? 'todos',
          });
          return null;
        }

        AppLogger.info('SupabaseService', 'Horario recibido por RPC', {
          'dni': AppLogger.shortId(dni),
          'dia': diaSemana ?? 'todos',
        });
        return horariosRpc;
      } on PostgrestException catch (e) {
        final rpcNoExiste =
            e.code == 'PGRST202' ||
            e.code == '42883' ||
            e.message.contains('obtener_horario_trabajador');
        if (!rpcNoExiste) {
          rethrow;
        }

        AppLogger.warning(
          'SupabaseService',
          'RPC obtener_horario_trabajador no existe, usando consulta directa',
          {'code': e.code},
        );
      }

      var query = _db
          .from('horario_trabajador')
          .select()
          .eq('dni_trabajador', dni);

      if (diaSemana != null && diaSemana.isNotEmpty) {
        query = query.eq('dia_semana', diaSemana);
      }

      final response = await query;
      if (response.isEmpty) {
        AppLogger.warning('SupabaseService', 'Horario no encontrado', {
          'dni': AppLogger.shortId(dni),
          'dia': diaSemana ?? 'todos',
        });
        return null;
      }

      if (diaSemana != null && diaSemana.isNotEmpty) {
        return Map<String, dynamic>.from(response.first);
      }

      final horarios = <String, dynamic>{};
      for (final registro in response) {
        final item = Map<String, dynamic>.from(registro);
        horarios[item['dia_semana'].toString()] = item;
      }

      return horarios;
    } catch (e, st) {
      AppLogger.error('SupabaseService', 'Error consultando horario', e, st, {
        'dni': AppLogger.shortId(dni),
        'dia': diaSemana ?? 'todos',
      });
      return null;
    }
  }

  DateTime? _ultimaMarcacion(
    Map<String, dynamic> asistencia,
    List<String> orden,
  ) {
    DateTime? ultima;

    for (final campo in orden) {
      final valor = asistencia[campo];
      if (valor == null) {
        continue;
      }

      final fecha = _parseSupabaseDateTime(valor);
      if (fecha == null) {
        continue;
      }

      if (ultima == null || fecha.isAfter(ultima)) {
        ultima = fecha;
      }
    }

    return ultima;
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

  String _timestampLocalConZona() {
    final ahora = DateTime.now();
    final offset = ahora.timeZoneOffset;
    final signo = offset.isNegative ? '-' : '+';
    final horas = offset.inHours.abs().toString().padLeft(2, '0');
    final minutos = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '${DateFormat('yyyy-MM-dd HH:mm:ss').format(ahora)}$signo$horas:$minutos';
  }

  String _diaHoy() {
    const diasSemana = [
      'lunes',
      'martes',
      'miercoles',
      'jueves',
      'viernes',
      'sabado',
      'domingo',
    ];
    return diasSemana[DateTime.now().weekday - 1];
  }

  List<String> _ordenMarcacionesParaHorario(Map<String, dynamic>? horario) {
    final tieneReceso = horario == null || _horarioTieneReceso(horario);

    return [
      'horario_entrada',
      if (tieneReceso) 'horario_inicio_receso',
      if (tieneReceso) 'horario_fin_receso',
      'horario_salida',
    ];
  }

  bool _horarioTieneReceso(Map<String, dynamic>? horario) {
    final tipoJornada = horario?['tipo_jornada']?.toString();
    if (tipoJornada == 'fulltime') {
      return true;
    }
    if (tipoJornada == 'parttime') {
      return false;
    }

    return horario?['horario_inicio_receso'] != null ||
        horario?['horario_fin_receso'] != null;
  }

  Map<String, dynamic> _camposUbicacion(
    Map<String, dynamic> asistencia,
    String tipoMarcacion,
    Map<String, double> ubicacion,
  ) {
    final latitud = ubicacion['latitude'];
    final longitud = ubicacion['longitude'];
    final ubicacionesActuales = asistencia['ubicaciones'] is Map
        ? Map<String, dynamic>.from(asistencia['ubicaciones'] as Map)
        : <String, dynamic>{};

    ubicacionesActuales[tipoMarcacion] = {
      'latitud': latitud,
      'longitud': longitud,
    };

    return {'ubicaciones': ubicacionesActuales};
  }

  Future<List<dynamic>?> _selectAsistenciaHoyDirecto(
    String dni,
    String fecha,
  ) async {
    for (final tabla in _tablasAsistencia) {
      try {
        final response = await _db
            .from(tabla)
            .select()
            .eq('dni_trabajador', dni)
            .eq('fecha', fecha)
            .limit(1);
        return response;
      } on PostgrestException catch (e, st) {
        if (!_tablaNoExiste(e)) {
          AppLogger.error(
            'SupabaseService',
            'Error consultando asistencia directa',
            e,
            st,
            {'tabla': tabla, 'dni': AppLogger.shortId(dni)},
          );
          rethrow;
        }
        AppLogger.warning('SupabaseService', 'Tabla asistencia no disponible', {
          'tabla': tabla,
          'code': e.code,
        });
      }
    }

    throw Exception('No se encontro la tabla asistencia/asistencias.');
  }

  Future<List<dynamic>> _selectHistorialDirecto(
    String dni,
    String inicio,
    String fin,
  ) async {
    for (final tabla in _tablasAsistencia) {
      try {
        return await _db
            .from(tabla)
            .select()
            .eq('dni_trabajador', dni)
            .gte('fecha', inicio)
            .lte('fecha', fin)
            .order('fecha', ascending: false);
      } on PostgrestException catch (e, st) {
        if (!_tablaNoExiste(e)) {
          AppLogger.error(
            'SupabaseService',
            'Error consultando historial directo',
            e,
            st,
            {'tabla': tabla, 'dni': AppLogger.shortId(dni)},
          );
          rethrow;
        }
        AppLogger.warning('SupabaseService', 'Tabla asistencia no disponible', {
          'tabla': tabla,
          'code': e.code,
        });
      }
    }

    throw Exception('No se encontro la tabla asistencia/asistencias.');
  }

  Future<void> _insertAsistencia(Map<String, dynamic> data) async {
    for (final tabla in _tablasAsistencia) {
      try {
        await _db.from(tabla).insert(data);
        return;
      } on PostgrestException catch (e, st) {
        if (!_tablaNoExiste(e)) {
          AppLogger.error(
            'SupabaseService',
            'Error insertando asistencia',
            e,
            st,
            {'tabla': tabla},
          );
          rethrow;
        }
        AppLogger.warning('SupabaseService', 'Tabla asistencia no disponible', {
          'tabla': tabla,
          'code': e.code,
        });
      }
    }

    throw Exception('No se encontro la tabla asistencia/asistencias.');
  }

  Future<void> _updateAsistencia(
    String dni,
    String fecha,
    Map<String, dynamic> cambios,
  ) async {
    for (final tabla in _tablasAsistencia) {
      try {
        await _db
            .from(tabla)
            .update(cambios)
            .eq('dni_trabajador', dni)
            .eq('fecha', fecha);
        return;
      } on PostgrestException catch (e, st) {
        if (!_tablaNoExiste(e)) {
          AppLogger.error(
            'SupabaseService',
            'Error actualizando asistencia',
            e,
            st,
            {'tabla': tabla, 'dni': AppLogger.shortId(dni)},
          );
          rethrow;
        }
        AppLogger.warning('SupabaseService', 'Tabla asistencia no disponible', {
          'tabla': tabla,
          'code': e.code,
        });
      }
    }

    throw Exception('No se encontro la tabla asistencia/asistencias.');
  }

  bool _tablaNoExiste(PostgrestException e) {
    final mensaje = e.message.toLowerCase();
    return e.code == 'PGRST205' ||
        e.code == '42P01' ||
        mensaje.contains('could not find the table') ||
        mensaje.contains('does not exist');
  }

  bool _esPayloadQrDinamico(String token) {
    return token.trim().startsWith('app-qr-dinamico://');
  }

  Future<Map<String, dynamic>?> _buscarTrabajador(String identificador) async {
    try {
      final idNormalizado = _normalizarIdentificador(identificador);
      AppLogger.info('SupabaseService', 'Buscando trabajador por DNI', {
        'dni': AppLogger.shortId(idNormalizado),
      });

      final porDni = await _db
          .from('trabajador')
          .select()
          .eq('dni', idNormalizado)
          .limit(1);

      if (porDni.isNotEmpty) {
        AppLogger.info('SupabaseService', 'Trabajador encontrado por DNI', {
          'dni': AppLogger.shortId(idNormalizado),
        });
        return Map<String, dynamic>.from(porDni.first);
      }

      AppLogger.info('SupabaseService', 'Buscando trabajador por correo', {
        'correo': _maskIdentificador(idNormalizado),
      });

      final porCorreo = await _db
          .from('trabajador')
          .select()
          .eq('correo', idNormalizado)
          .limit(1);

      if (porCorreo.isNotEmpty) {
        AppLogger.info('SupabaseService', 'Trabajador encontrado por correo', {
          'correo': _maskIdentificador(idNormalizado),
        });
        return Map<String, dynamic>.from(porCorreo.first);
      }

      AppLogger.info('SupabaseService', 'Buscando trabajador por CSI', {
        'csi': AppLogger.shortId(idNormalizado),
      });

      final porCsi = await _db
          .from('trabajador')
          .select()
          .eq('csi', idNormalizado)
          .limit(1);

      if (porCsi.isNotEmpty) {
        AppLogger.info('SupabaseService', 'Trabajador encontrado por CSI', {
          'csi': AppLogger.shortId(idNormalizado),
        });
        return Map<String, dynamic>.from(porCsi.first);
      }

      AppLogger.warning('SupabaseService', 'Trabajador no encontrado', {
        'identificador': AppLogger.shortId(idNormalizado),
      });
      return null;
    } catch (e, st) {
      AppLogger.error('SupabaseService', 'Error buscando trabajador', e, st, {
        'identificador': AppLogger.shortId(identificador),
      });
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _normalizarTrabajador(
    Map<String, dynamic> trabajador,
  ) async {
    final data = Map<String, dynamic>.from(trabajador);
    data['id_trabajador'] = data['dni']?.toString() ?? '';
    await _adjuntarTienda(data);
    return data;
  }

  Future<void> _adjuntarTienda(Map<String, dynamic> data) async {
    final yaTieneNombre =
        data['nombre_tienda']?.toString().trim().isNotEmpty == true;
    final yaTieneDireccion =
        data['direccion_tienda']?.toString().trim().isNotEmpty == true;
    if (yaTieneNombre && yaTieneDireccion) {
      return;
    }

    final idTienda = data['id_tienda']?.toString();
    if (idTienda == null || idTienda.isEmpty) {
      return;
    }

    try {
      final response = await _db
          .from('tienda')
          .select('nombre,direccion')
          .eq('id_tienda', idTienda)
          .limit(1);

      if (response.isEmpty) {
        return;
      }

      final tienda = Map<String, dynamic>.from(response.first);
      data['nombre_tienda'] ??= tienda['nombre'];
      data['direccion_tienda'] ??= tienda['direccion'];
    } catch (e, st) {
      AppLogger.warning('SupabaseService', 'No se pudo adjuntar tienda', {
        'id_tienda': AppLogger.shortId(idTienda),
      });
      AppLogger.error('SupabaseService', 'Detalle adjuntar tienda', e, st);
    }
  }

  Map<String, dynamic>? _firstRow(Object? response) {
    if (response is List && response.isNotEmpty) {
      final first = response.first;
      if (first is Map<String, dynamic>) {
        return Map<String, dynamic>.from(first);
      }
      if (first is Map) {
        return Map<String, dynamic>.from(first);
      }
    }

    if (response is Map<String, dynamic>) {
      return Map<String, dynamic>.from(response);
    }

    if (response is Map) {
      return Map<String, dynamic>.from(response);
    }

    return null;
  }

  Map<String, dynamic>? _normalizarHorarios(
    Object? response,
    String? diaSemana,
  ) {
    if (response is! List || response.isEmpty) {
      return null;
    }

    if (diaSemana != null && diaSemana.isNotEmpty) {
      return Map<String, dynamic>.from(response.first as Map);
    }

    final horarios = <String, dynamic>{};
    for (final registro in response) {
      final item = Map<String, dynamic>.from(registro as Map);
      horarios[item['dia_semana'].toString()] = item;
    }

    return horarios;
  }

  String _maskIdentificador(String identificador) {
    if (identificador.contains('@')) {
      return AppLogger.maskEmail(identificador);
    }
    return AppLogger.shortId(identificador);
  }

  String _normalizarIdentificador(String identificador) {
    final limpio = identificador.trim();
    if (limpio.contains('@')) {
      return limpio.toLowerCase();
    }
    return limpio;
  }
}
