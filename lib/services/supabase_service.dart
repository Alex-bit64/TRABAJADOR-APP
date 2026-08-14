import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_logger.dart';
import 'device_security_service.dart';
import 'local_database_service.dart';
import 'qr_service.dart';

typedef _MarcacionRpcResult = ({
  bool ok,
  String mensaje,
  String? tipoMarcacion,
  Object? marcadoEn,
});
typedef _AsistenciaFechaResult = ({
  Map<String, dynamic>? registro,
  bool confiable,
});

class DeviceBindingResult {
  final bool ok;
  final String message;

  const DeviceBindingResult({required this.ok, required this.message});
}

class SupabaseService {
  final SupabaseClient _db = Supabase.instance.client;
  static const Duration _cooldownMarcacion = Duration(minutes: 10);
  static const double _radioQrMetros = 150;
  static const List<String> _tablasAsistencia = ['asistencia', 'asistencias'];

  bool esErrorConexion(Object error) {
    if (error is SocketException || error is TimeoutException) {
      return true;
    }
    final text = error.toString().toLowerCase();
    return text.contains('failed host lookup') ||
        text.contains('socketexception') ||
        text.contains('clientexception') ||
        text.contains('connection refused') ||
        text.contains('connection reset') ||
        text.contains('network is unreachable') ||
        text.contains('network request failed') ||
        text.contains('no address associated') ||
        text.contains('timed out') ||
        text.contains('timeout');
  }

  void validarRangoQrLocal(
    QRValidado qrValidado,
    Map<String, double> ubicacion, {
    required String tipoMarcacion,
  }) {
    _validarRangoQr(
      qrValidado,
      _normalizarUbicacion(ubicacion),
      tipoMarcacion: tipoMarcacion,
    );
  }

  Future<void> actualizarVersionApp({
    required String dni,
    required String version,
    required String buildNumber,
    required String plataforma,
  }) async {
    final dniLimpio = dni.trim();
    if (dniLimpio.isEmpty) {
      return;
    }
    try {
      await _db.rpc(
        'actualizar_version_trabajador',
        params: {
          'p_dni': dniLimpio,
          'p_version': version.trim(),
          'p_build_number': buildNumber.trim(),
          'p_plataforma': plataforma.trim(),
        },
      );
      AppLogger.info('SupabaseService', 'Version del app actualizada', {
        'dni': AppLogger.shortId(dniLimpio),
        'version': version,
        'build': buildNumber,
        'plataforma': plataforma,
      });
    } catch (e, st) {
      AppLogger.error(
        'SupabaseService',
        'No se pudo actualizar la version del app',
        e,
        st,
        {'dni': AppLogger.shortId(dniLimpio), 'version': version},
      );
    }
  }

  Future<DeviceBindingResult> vincularDispositivo({
    required String identificador,
    required String password,
    required DeviceCredentials credentials,
  }) async {
    try {
      final response = await _db.rpc(
        'vincular_dispositivo_trabajador',
        params: {
          'p_identificador': _normalizarIdentificador(identificador),
          'p_contrasena': password,
          'p_dispositivo_id': credentials.deviceId,
          'p_dispositivo_secreto': credentials.secret,
          'p_plataforma': Platform.operatingSystem,
        },
      );
      final row = _firstRow(response);
      return DeviceBindingResult(
        ok: row?['ok'] == true,
        message:
            row?['mensaje']?.toString() ??
            'No se pudo vincular el dispositivo.',
      );
    } catch (e, st) {
      AppLogger.error(
        'SupabaseService',
        'Error vinculando dispositivo',
        e,
        st,
        {'identificador': _maskIdentificador(identificador)},
      );
      rethrow;
    }
  }

  Future<bool> validarDispositivo({
    required String dni,
    required DeviceCredentials credentials,
  }) async {
    final response = await _db.rpc(
      'validar_dispositivo_trabajador',
      params: {
        'p_dni': dni.trim(),
        'p_dispositivo_id': credentials.deviceId,
        'p_dispositivo_secreto': credentials.secret,
      },
    );
    return response == true || response?.toString().toLowerCase() == 'true';
  }

  Future<String> sincronizarMarcacionPendiente(
    MarcacionPendiente pendiente,
  ) async {
    final seguridad = DeviceSecurityService();
    if (!await seguridad.estaVinculadoLocalmente(pendiente.dni)) {
      throw const DeviceSecurityException(
        'El dispositivo local no corresponde al trabajador de la marca pendiente.',
      );
    }
    final dispositivo = await seguridad.obtenerCredenciales(
      crearSiFaltan: false,
    );
    final qr = QRValidado.fromMap(pendiente.qr);
    final resultado = await _registrarMarcacionRpc(
      dni: pendiente.dni,
      token: qr.token,
      ubicacion: pendiente.ubicacion,
      tipoJornadaManual: pendiente.horarioManual?['tipo_jornada']?.toString(),
      marcadoEn: pendiente.marcadoEn,
      eventoId: pendiente.id,
      tipoMarcacionEsperado: pendiente.tipoMarcacion,
      dispositivoId: dispositivo.deviceId,
      dispositivoSecreto: dispositivo.secret,
    );
    if (resultado == null) {
      throw Exception(
        'El servidor aun no tiene instalada la migracion de sincronizacion offline.',
      );
    }
    if (!resultado.ok) {
      throw Exception(resultado.mensaje);
    }
    if (resultado.tipoMarcacion != null &&
        resultado.tipoMarcacion != pendiente.tipoMarcacion) {
      throw Exception(
        'El orden de la marca local no coincide con el registro del servidor.',
      );
    }

    await _registrarTrackingDesdeAsistenciaSeguro(
      pendiente.usuario,
      qr,
      ubicacion: pendiente.ubicacion,
      tipoMarcacion: resultado.mensaje,
      registradoEn: pendiente.marcadoEn,
    );
    return resultado.mensaje;
  }

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

  Future<_AsistenciaFechaResult> _obtenerAsistenciaPorFechaSegura(
    String dni,
    String fecha,
  ) async {
    final dniLimpio = dni.trim();
    if (dniLimpio.isEmpty) {
      return (registro: null, confiable: true);
    }

    try {
      AppLogger.info(
        'SupabaseService',
        'Consultando asistencia por fecha por RPC',
        {'dni': AppLogger.shortId(dniLimpio), 'fecha': fecha},
      );

      final response = await _db.rpc(
        'obtener_asistencia_hoy',
        params: {'p_dni': dniLimpio, 'p_fecha': fecha},
      );
      final row = _firstRow(response);

      if (row != null) {
        AppLogger.info(
          'SupabaseService',
          'Asistencia por fecha encontrada por RPC',
          {'dni': AppLogger.shortId(dniLimpio), 'fecha': fecha},
        );
        return (registro: row, confiable: true);
      }

      AppLogger.info('SupabaseService', 'Sin asistencia por fecha por RPC', {
        'dni': AppLogger.shortId(dniLimpio),
        'fecha': fecha,
      });
      return (registro: null, confiable: true);
    } on PostgrestException catch (e, st) {
      final rpcFechaNoDisponible =
          e.code == 'PGRST202' ||
          e.code == 'PGRST203' ||
          e.code == '42883' ||
          e.message.contains('obtener_asistencia_hoy') ||
          e.message.contains('p_fecha');
      AppLogger.error(
        'SupabaseService',
        'Error consultando asistencia por fecha por RPC',
        e,
        st,
        {
          'dni': AppLogger.shortId(dniLimpio),
          'fecha': fecha,
          'code': e.code,
          'fallback': true,
        },
      );

      final hoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      if (rpcFechaNoDisponible && fecha == hoy) {
        final asistenciaHoy = await obtenerAsistenciaHoy(dniLimpio);
        if (asistenciaHoy != null) {
          return (registro: asistenciaHoy, confiable: true);
        }
      }
    } catch (e, st) {
      AppLogger.error(
        'SupabaseService',
        'Error inesperado consultando asistencia por fecha',
        e,
        st,
        {'dni': AppLogger.shortId(dniLimpio), 'fecha': fecha},
      );
    }

    try {
      final response = await _selectAsistenciaHoyDirecto(dniLimpio, fecha);
      if (response == null || response.isEmpty) {
        AppLogger.info('SupabaseService', 'Sin asistencia por fecha directa', {
          'dni': AppLogger.shortId(dniLimpio),
          'fecha': fecha,
        });
        return (registro: null, confiable: false);
      }

      AppLogger.info(
        'SupabaseService',
        'Asistencia por fecha encontrada directa',
        {'dni': AppLogger.shortId(dniLimpio), 'fecha': fecha},
      );
      return (
        registro: Map<String, dynamic>.from(response.first as Map),
        confiable: true,
      );
    } catch (e, st) {
      AppLogger.error(
        'SupabaseService',
        'Error consultando asistencia por fecha directa',
        e,
        st,
        {'dni': AppLogger.shortId(dniLimpio), 'fecha': fecha},
      );
      return (registro: null, confiable: false);
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
    Map<String, dynamic>? horarioDia,
    DeviceCredentials? dispositivo,
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
      final ubicacionMarca = _normalizarUbicacion(ubicacion);
      if (!_ubicacionTieneCoordenadas(ubicacionMarca)) {
        AppLogger.warning('SupabaseService', 'Marcacion sin ubicacion valida', {
          'dni': AppLogger.shortId(dni),
        });
        throw Exception(
          'No se pudo obtener una ubicacion valida para registrar la marca.',
        );
      }

      var qrParaMarcacion = qrValidado;
      final qrResuelto = await _resolverQrDinamicoParaMarcacion(qrValidado);
      if (qrResuelto != null) {
        qrParaMarcacion = qrResuelto;
      }
      AppLogger.info('SupabaseService', 'QR listo para marcacion', {
        'dni': AppLogger.shortId(dni),
        'dinamico': _esPayloadQrDinamico(qrParaMarcacion.token),
        'id_tienda': AppLogger.shortId(qrParaMarcacion.idTienda),
        'tienda': qrParaMarcacion.nombreTienda,
        'ubicacion_qr_keys': qrParaMarcacion.ubicacionQr.keys.join(','),
        'horario_manual': horarioManual?['tipo_jornada']?.toString() ?? '',
        'horario_dia': horarioDia == null ? 'no' : 'si',
      });

      final bloqueoSede = await _mensajeBloqueoSedeUltimoTracking(
        usuario,
        qrParaMarcacion,
      );
      if (bloqueoSede != null) {
        AppLogger.warning('SupabaseService', 'Marcacion bloqueada por sede', {
          'dni': AppLogger.shortId(dni),
          'mensaje': bloqueoSede,
        });
        return bloqueoSede;
      }

      final tipoJornadaManual = horarioManual?['tipo_jornada']
          ?.toString()
          .trim();
      final requiereRpc =
          dispositivo != null ||
          horarioManual != null ||
          (horarioDia == null || _esPayloadQrDinamico(qrParaMarcacion.token));
      AppLogger.info('SupabaseService', 'Ruta de marcacion decidida', {
        'dni': AppLogger.shortId(dni),
        'requiere_rpc': requiereRpc,
        'horario_manual': tipoJornadaManual ?? '',
        'qr_dinamico': _esPayloadQrDinamico(qrParaMarcacion.token),
        'id_tienda_qr': AppLogger.shortId(qrParaMarcacion.idTienda),
      });

      if (requiereRpc) {
        final resultadoRpc = await _registrarMarcacionRpc(
          dni: dni,
          token: qrParaMarcacion.token,
          ubicacion: ubicacionMarca,
          tipoJornadaManual: tipoJornadaManual,
          dispositivoId: dispositivo?.deviceId,
          dispositivoSecreto: dispositivo?.secret,
        );
        if (resultadoRpc != null) {
          await _registrarTrackingDesdeAsistenciaSeguro(
            usuario,
            qrParaMarcacion,
            ubicacion: ubicacionMarca,
            tipoMarcacion: resultadoRpc.mensaje,
            registradoEn: resultadoRpc.marcadoEn,
          );
          return resultadoRpc.mensaje;
        }
        if (dispositivo != null) {
          throw Exception(
            'El servidor aun no tiene instalada la validacion de dispositivo.',
          );
        }
      }

      if (_esPayloadQrDinamico(qrParaMarcacion.token) &&
          qrParaMarcacion.idTienda.trim().isEmpty) {
        final resultadoRpc = await _registrarMarcacionRpc(
          dni: dni,
          token: qrParaMarcacion.token,
          ubicacion: ubicacionMarca,
          tipoJornadaManual: tipoJornadaManual,
          dispositivoId: dispositivo?.deviceId,
          dispositivoSecreto: dispositivo?.secret,
        );
        if (resultadoRpc != null) {
          await _registrarTrackingDesdeAsistenciaSeguro(
            usuario,
            qrParaMarcacion,
            ubicacion: ubicacionMarca,
            tipoMarcacion: resultadoRpc.mensaje,
            registradoEn: resultadoRpc.marcadoEn,
          );
          return resultadoRpc.mensaje;
        }
        throw Exception(
          'No se pudo resolver el QR dinamico para marcar asistencia.',
        );
      }

      final hoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final existente = await _selectAsistenciaHoyDirecto(dni, hoy) ?? [];
      final horario =
          horarioManual ??
          horarioDia ??
          await obtenerHorarioTrabajador(dni, diaSemana: _diaHoy());
      final justificado = horarioManual == null && horario != null;
      AppLogger.info('SupabaseService', 'Asistencia local preparada', {
        'dni': AppLogger.shortId(dni),
        'fecha': hoy,
        'existente': existente.isNotEmpty,
        'tipo_jornada': horario?['tipo_jornada']?.toString() ?? '',
        'tiene_receso': _horarioTieneReceso(horario),
        'justificado': justificado,
      });

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
      AppLogger.info('SupabaseService', 'Siguiente marcacion calculada', {
        'dni': AppLogger.shortId(dni),
        'fecha': hoy,
        'tipo': tipoMarcacion,
        'orden': orden.join(','),
      });

      _validarRangoQr(
        qrParaMarcacion,
        ubicacionMarca,
        tipoMarcacion: tipoMarcacion,
      );

      final asistenciaParaUbicacion = horarioManual == null
          ? asistencia
          : {
              ...asistencia,
              'ubicaciones': _ubicacionesConJornadaManual(
                asistencia['ubicaciones'],
                horarioManual,
              ),
            };
      final registradoEn = _timestampLocalConZona();
      final cambios = {
        tipoMarcacion: registradoEn,
        'justificado': justificado,
        ..._camposUbicacion(
          asistenciaParaUbicacion,
          tipoMarcacion,
          ubicacionMarca,
          qrParaMarcacion,
        ),
      };

      if (existente.isEmpty) {
        try {
          await _insertAsistencia({...asistencia, ...cambios});
        } on PostgrestException catch (e) {
          if (!_esConflictoDuplicado(e)) {
            rethrow;
          }
          AppLogger.warning(
            'SupabaseService',
            'Asistencia ya existia, reintentando como actualizacion',
            {'dni': AppLogger.shortId(dni), 'fecha': hoy, 'code': e.code},
          );
          await _updateAsistencia(dni, hoy, cambios);
        }
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

      final mensaje = nombres[tipoMarcacion] ?? tipoMarcacion;
      await _registrarTrackingDesdeAsistenciaSeguro(
        usuario,
        qrParaMarcacion,
        ubicacion: ubicacionMarca,
        tipoMarcacion: mensaje,
        registradoEn: registradoEn,
      );
      return mensaje;
    } catch (e, st) {
      AppLogger.error('SupabaseService', 'Error registrando marcacion', e, st);
      rethrow;
    }
  }

  Future<String> registrarMovimientoPersonal(
    Map<String, dynamic> usuario,
    QRValidado qrValidado, {
    required Map<String, double> ubicacion,
    String tipoMarcacion = 'Marca',
    String origen = 'multiple',
    Object? registradoEn,
  }) async {
    return _registrarMovimientoPersonalInterno(
      usuario,
      qrValidado,
      ubicacion: ubicacion,
      tipoMarcacion: tipoMarcacion,
      origen: origen,
      registradoEn: registradoEn,
    );
  }

  Future<void> _registrarTrackingDesdeAsistenciaSeguro(
    Map<String, dynamic> usuario,
    QRValidado qrValidado, {
    required Map<String, double> ubicacion,
    required String tipoMarcacion,
    Object? registradoEn,
  }) async {
    if (!_esMarcacionExitosa(tipoMarcacion)) {
      return;
    }

    try {
      await _registrarMovimientoPersonalInterno(
        usuario,
        qrValidado,
        ubicacion: ubicacion,
        tipoMarcacion: tipoMarcacion,
        origen: 'normal',
        registradoEn: registradoEn,
      );
    } catch (e, st) {
      AppLogger.warning('SupabaseService', 'No se pudo reflejar en tracking', {
        'dni': AppLogger.shortId(
          usuario['dni']?.toString() ??
              usuario['id_trabajador']?.toString() ??
              '',
        ),
        'tipo': tipoMarcacion,
      });
      AppLogger.error('SupabaseService', 'Detalle reflejo tracking', e, st);
    }
  }

  Future<String> _registrarMovimientoPersonalInterno(
    Map<String, dynamic> usuario,
    QRValidado qrValidado, {
    required Map<String, double> ubicacion,
    required String tipoMarcacion,
    required String origen,
    Object? registradoEn,
  }) async {
    try {
      final dni =
          usuario['dni']?.toString() ??
          usuario['id_trabajador']?.toString() ??
          '';

      if (dni.trim().isEmpty) {
        AppLogger.warning('SupabaseService', 'Tracking sin DNI');
        throw Exception(
          'Falta el DNI del trabajador para registrar el movimiento.',
        );
      }
      final ubicacionTracking = _normalizarUbicacion(ubicacion);
      if (!_ubicacionTieneCoordenadas(ubicacionTracking)) {
        AppLogger.warning('SupabaseService', 'Tracking sin ubicacion valida', {
          'dni': AppLogger.shortId(dni),
        });
        throw Exception(
          'No se pudo obtener una ubicacion valida para registrar el movimiento.',
        );
      }

      final idTiendaTracking = qrValidado.idTienda.trim().isNotEmpty
          ? qrValidado.idTienda.trim()
          : usuario['id_tienda']?.toString().trim() ?? '';
      final registradoEnTexto =
          registradoEn?.toString().trim().isNotEmpty == true
          ? registradoEn.toString()
          : _timestampLocalConZona();
      final tipo = tipoMarcacion.trim().isEmpty
          ? 'Marca'
          : tipoMarcacion.trim();
      final origenNormalizado = origen.trim().toLowerCase() == 'normal'
          ? 'normal'
          : 'multiple';
      final tipoMovimiento = origenNormalizado == 'normal'
          ? 'NORMAL'
          : 'MULTIPLE';

      var entradaConfirmada = true;
      if (tipoMovimiento == 'MULTIPLE') {
        entradaConfirmada = await _exigirEntradaAntesDeTracking(
          dni.trim(),
          registradoEnTexto,
        );
      }

      final debeValidarRangoQr =
          origenNormalizado != 'normal' || qrValidado.ubicacionQr.isNotEmpty;
      if (debeValidarRangoQr) {
        _validarRangoQr(qrValidado, ubicacionTracking, tipoMarcacion: tipo);
      } else {
        AppLogger.info(
          'SupabaseService',
          'Rango QR omitido en reflejo normal ya validado',
          {'dni': AppLogger.shortId(dni), 'tipo': tipo},
        );
      }

      final payload = <String, dynamic>{
        'id_trabajador': dni.trim(),
        'id_tienda': idTiendaTracking,
        'hora_marca': registradoEnTexto,
        'ubicacion': {
          'latitud': ubicacionTracking['latitude'],
          'longitud': ubicacionTracking['longitude'],
        },
        'tipo': tipoMovimiento,
      };

      AppLogger.info('SupabaseService', 'Registrando tracking', {
        'dni': AppLogger.shortId(dni),
        'id_tienda': AppLogger.shortId(idTiendaTracking),
      });

      final registradoPorRpc = await _registrarMovimientoPersonalRpc(
        usuario,
        qrValidado,
        dni: dni.trim(),
        ubicacion: ubicacionTracking,
        tipoMarcacion: tipo,
        origen: origenNormalizado,
        tipoMovimiento: tipoMovimiento,
        registradoEn: registradoEnTexto,
      );
      if (registradoPorRpc) {
        return origenNormalizado == 'normal'
            ? '$tipo registrado en tracking'
            : 'Movimiento registrado';
      }

      if (tipoMovimiento == 'MULTIPLE' && !entradaConfirmada) {
        throw Exception(
          'No se pudo confirmar tu Entrada antes de usar Tracking. Intenta de nuevo.',
        );
      }

      await _db.from('asistencia_multiple').insert(payload);

      return origenNormalizado == 'normal'
          ? '$tipo registrado en tracking'
          : 'Movimiento registrado';
    } on PostgrestException catch (e, st) {
      AppLogger.error('SupabaseService', 'Error registrando tracking', e, st, {
        'code': e.code,
      });

      if (_tablaNoExiste(e)) {
        throw Exception('Falta crear la tabla asistencia_multiple.');
      }

      rethrow;
    } catch (e, st) {
      AppLogger.error('SupabaseService', 'Error registrando tracking', e, st);
      rethrow;
    }
  }

  Future<bool> _registrarMovimientoPersonalRpc(
    Map<String, dynamic> usuario,
    QRValidado qrValidado, {
    required String dni,
    required Map<String, double> ubicacion,
    required String tipoMarcacion,
    required String origen,
    required String tipoMovimiento,
    required String registradoEn,
  }) async {
    try {
      final response = await _db.rpc(
        'registrar_tracking_personal',
        params: {
          'p_dni': dni,
          'p_token': qrValidado.token,
          'p_id_tienda_qr': qrValidado.idTienda,
          'p_nombre_tienda': qrValidado.nombreTienda,
          'p_direccion_tienda': qrValidado.direccion,
          'p_latitud': ubicacion['latitude'],
          'p_longitud': ubicacion['longitude'],
          'p_nombre_trabajador': usuario['nombre']?.toString() ?? '',
          'p_cargo_trabajador': usuario['cargo']?.toString() ?? '',
          'p_id_trabajador':
              usuario['id']?.toString() ??
              usuario['idx']?.toString() ??
              usuario['id_trabajador']?.toString() ??
              '',
          'p_id_tienda_asignada': usuario['id_tienda']?.toString() ?? '',
          'p_tipo_marcacion': tipoMarcacion,
          'p_origen': origen,
          'p_tipo': tipoMovimiento,
          'p_registrado_en': registradoEn,
        },
      );

      final row = _firstRow(response);
      if (row == null) {
        AppLogger.info(
          'SupabaseService',
          'RPC tracking sin fila de respuesta',
          {
            'dni': AppLogger.shortId(dni),
            'tipo': tipoMovimiento,
            'origen': origen,
          },
        );
        return true;
      }

      AppLogger.info('SupabaseService', 'RPC tracking respondio', {
        'dni': AppLogger.shortId(dni),
        'ok': row['ok']?.toString() ?? '',
        'mensaje': row['mensaje']?.toString() ?? '',
        'tipo': tipoMovimiento,
        'origen': origen,
      });

      if (row['ok'] == false) {
        throw Exception(
          row['mensaje']?.toString() ?? 'No se pudo registrar el tracking.',
        );
      }

      return true;
    } on PostgrestException catch (e, st) {
      final rpcNoExiste =
          e.code == 'PGRST202' ||
          e.code == 'PGRST203' ||
          e.code == '42883' ||
          e.message.contains('registrar_tracking_personal');
      AppLogger.error(
        'SupabaseService',
        'Error en RPC registrar_tracking_personal',
        e,
        st,
        {
          'dni': AppLogger.shortId(dni),
          'code': e.code,
          'fallback': rpcNoExiste,
        },
      );
      if (rpcNoExiste) {
        return false;
      }
      rethrow;
    }
  }

  Future<int> sincronizarAsistenciasEnTracking(
    Map<String, dynamic> usuario,
    Iterable<Map<String, dynamic>> asistencias,
  ) async {
    var sincronizadas = 0;

    for (final asistencia in asistencias) {
      for (final item in _ordenMarcacionesParaHorario(asistencia)) {
        final valor = asistencia[item];
        if (!_valorPresente(valor)) {
          continue;
        }

        final nombre = _nombreMarcacion(item);
        final ubicacionAsistencia = _ubicacionDesdeAsistencia(asistencia, item);
        if (!_ubicacionTieneCoordenadas(ubicacionAsistencia)) {
          AppLogger.warning(
            'SupabaseService',
            'Sincronizacion omitida por ubicacion vacia',
            {
              'dni': AppLogger.shortId(
                usuario['dni']?.toString() ??
                    usuario['id_trabajador']?.toString() ??
                    '',
              ),
              'tipo': nombre,
            },
          );
          continue;
        }
        try {
          await _registrarMovimientoPersonalInterno(
            usuario,
            _qrDesdeAsistencia(usuario, asistencia, item),
            ubicacion: ubicacionAsistencia,
            tipoMarcacion: nombre,
            origen: 'normal',
            registradoEn: valor,
          );
          sincronizadas++;
        } catch (e, st) {
          AppLogger.warning('SupabaseService', 'No se sincronizo asistencia', {
            'dni': AppLogger.shortId(
              usuario['dni']?.toString() ??
                  usuario['id_trabajador']?.toString() ??
                  '',
            ),
            'tipo': nombre,
          });
          AppLogger.error(
            'SupabaseService',
            'Detalle sincronizar asistencia',
            e,
            st,
          );
        }
      }
    }

    return sincronizadas;
  }

  Future<List<Map<String, dynamic>>> obtenerTrackingDia(
    Map<String, dynamic> usuario,
    DateTime fecha,
  ) {
    final inicio = DateTime(fecha.year, fecha.month, fecha.day);
    final fin = inicio.add(const Duration(days: 1));
    return _obtenerTrackingEnRango(usuario, inicio, fin);
  }

  Future<List<Map<String, dynamic>>> obtenerTrackingMes(
    Map<String, dynamic> usuario,
    DateTime fechaMes,
  ) {
    final inicio = DateTime(fechaMes.year, fechaMes.month);
    final fin = DateTime(fechaMes.year, fechaMes.month + 1);
    return _obtenerTrackingEnRango(usuario, inicio, fin);
  }

  Future<List<Map<String, dynamic>>> _obtenerTrackingEnRango(
    Map<String, dynamic> usuario,
    DateTime inicio,
    DateTime fin,
  ) async {
    final dni =
        (usuario['dni']?.toString() ??
                usuario['id_trabajador']?.toString() ??
                '')
            .trim();
    if (dni.isEmpty) {
      AppLogger.warning('SupabaseService', 'Tracking sin DNI para consulta');
      return [];
    }

    final idTrabajador =
        _smallIntOrNull(usuario['id_trabajador']) ??
        _smallIntOrNull(usuario['id']) ??
        _smallIntOrNull(usuario['idx']);
    final inicioTexto = _timestampConZona(inicio);
    final finTexto = _timestampConZona(fin);

    final trackingRpc = await _obtenerTrackingRpc(
      dni: dni,
      inicio: inicioTexto,
      fin: finTexto,
    );
    if (trackingRpc != null) {
      return trackingRpc;
    }

    final grupos = <List<Map<String, dynamic>>>[];

    try {
      final response = await _db
          .from('asistencia_multiple')
          .select()
          .eq('id_trabajador', dni)
          .gte('hora_marca', inicioTexto)
          .lt('hora_marca', finTexto)
          .order('hora_marca', ascending: true);
      grupos.add(_normalizarTrackingResponse(response));
    } on PostgrestException catch (e) {
      if (_tablaNoExiste(e)) {
        return [];
      }
      AppLogger.warning('SupabaseService', 'Tracking por DNI no disponible', {
        'dni': AppLogger.shortId(dni),
        'code': e.code,
      });
    }

    var tracking = _deduplicarTracking(grupos)
        .where((item) => _trackingPerteneceAlUsuario(item, dni, idTrabajador))
        .toList();

    if (tracking.isNotEmpty) {
      return tracking;
    }

    try {
      final response = await _db
          .from('asistencia_multiple')
          .select()
          .gte('hora_marca', inicioTexto)
          .lt('hora_marca', finTexto)
          .order('hora_marca', ascending: true);
      tracking = _normalizarTrackingResponse(response)
          .where((item) => _trackingPerteneceAlUsuario(item, dni, idTrabajador))
          .toList();
      return _deduplicarTracking([tracking]);
    } on PostgrestException catch (e, st) {
      if (_tablaNoExiste(e)) {
        return [];
      }
      AppLogger.error('SupabaseService', 'Error consultando tracking', e, st, {
        'dni': AppLogger.shortId(dni),
        'code': e.code,
      });
      return [];
    } catch (e, st) {
      AppLogger.error('SupabaseService', 'Error consultando tracking', e, st, {
        'dni': AppLogger.shortId(dni),
      });
      return [];
    }
  }

  Future<List<Map<String, dynamic>>?> _obtenerTrackingRpc({
    required String dni,
    required String inicio,
    required String fin,
  }) async {
    try {
      final response = await _db.rpc(
        'obtener_tracking_personal',
        params: {'p_dni': dni, 'p_inicio': inicio, 'p_fin': fin},
      );

      if (response == null) {
        return [];
      }

      if (response is List) {
        return _normalizarTrackingResponse(response);
      }

      if (response is Map) {
        return [Map<String, dynamic>.from(response)];
      }

      return [];
    } on PostgrestException catch (e, st) {
      final rpcNoExiste =
          e.code == 'PGRST202' ||
          e.code == 'PGRST203' ||
          e.code == '42883' ||
          e.message.contains('obtener_tracking_personal');
      AppLogger.error(
        'SupabaseService',
        'Error en RPC obtener_tracking_personal',
        e,
        st,
        {
          'dni': AppLogger.shortId(dni),
          'code': e.code,
          'fallback': rpcNoExiste,
        },
      );
      if (rpcNoExiste) {
        return null;
      }
      return [];
    }
  }

  Future<_MarcacionRpcResult?> _registrarMarcacionRpc({
    required String dni,
    required String token,
    required Map<String, double> ubicacion,
    String? tipoJornadaManual,
    DateTime? marcadoEn,
    String? eventoId,
    String? tipoMarcacionEsperado,
    String? dispositivoId,
    String? dispositivoSecreto,
  }) async {
    try {
      AppLogger.info('SupabaseService', 'Intentando marcacion por RPC', {
        'dni': AppLogger.shortId(dni),
        'token': AppLogger.shortId(token),
        'token_length': token.length,
        'tipo_jornada_manual': tipoJornadaManual ?? '',
      });

      final params = <String, dynamic>{
        'p_dni': dni,
        'p_token': token,
        'p_latitud': ubicacion['latitude'],
        'p_longitud': ubicacion['longitude'],
      };
      if (tipoJornadaManual != null && tipoJornadaManual.trim().isNotEmpty) {
        params['p_tipo_jornada_manual'] = tipoJornadaManual.trim();
      }
      if (marcadoEn != null) {
        params['p_marcado_en'] = marcadoEn.toUtc().toIso8601String();
      }
      if (eventoId != null && eventoId.trim().isNotEmpty) {
        params['p_evento_id'] = eventoId.trim();
      }
      if (tipoMarcacionEsperado != null &&
          tipoMarcacionEsperado.trim().isNotEmpty) {
        params['p_tipo_marcacion_esperado'] = tipoMarcacionEsperado.trim();
      }
      if (dispositivoId != null && dispositivoId.trim().isNotEmpty) {
        params['p_dispositivo_id'] = dispositivoId.trim();
      }
      if (dispositivoSecreto != null && dispositivoSecreto.trim().isNotEmpty) {
        params['p_dispositivo_secreto'] = dispositivoSecreto;
      }

      final response = await _db.rpc(
        'registrar_marcacion_asistencia_qr',
        params: params,
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
      final tipoMarcacion = row['tipo_marcacion']?.toString();
      final registradoEn = tipoMarcacion != null && tipoMarcacion.isNotEmpty
          ? row[tipoMarcacion]
          : null;
      AppLogger.info('SupabaseService', 'RPC marcacion respondio', {
        'dni': AppLogger.shortId(dni),
        'ok': ok,
        'mensaje': mensaje,
        'tipo': tipoMarcacion ?? '',
        'id_asistencia': AppLogger.shortId(
          row['id_asistencia']?.toString() ?? '',
        ),
      });

      if (mensaje.isEmpty) {
        return (
          ok: ok,
          mensaje: ok
              ? 'Marcacion registrada'
              : 'No se pudo registrar la marca',
          tipoMarcacion: tipoMarcacion,
          marcadoEn: registradoEn,
        );
      }

      return (
        ok: ok,
        mensaje: mensaje,
        tipoMarcacion: tipoMarcacion,
        marcadoEn: registradoEn,
      );
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
      final asistenciaExistente = existente.isEmpty
          ? null
          : Map<String, dynamic>.from(existente.first as Map);
      final cambiosJornada = {
        'justificado': false,
        'ubicaciones': _ubicacionesConJornadaManual(
          asistenciaExistente?['ubicaciones'],
          horarioManual,
        ),
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
      if (e is PostgrestException && _esErrorRls(e)) {
        AppLogger.warning(
          'SupabaseService',
          'Jornada manual no precreada por RLS; se creara al marcar por RPC',
          {'dni': AppLogger.shortId(dni)},
        );
        return;
      }
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

  bool _esErrorRls(PostgrestException error) {
    final texto =
        '${error.code} ${error.message} ${error.details ?? ''} ${error.hint ?? ''}'
            .toLowerCase();
    return texto.contains('42501') ||
        texto.contains('row-level security') ||
        texto.contains('violates row-level security') ||
        texto.contains('unauthorized');
  }

  Map<String, dynamic> _camposAsistenciaParaJornadaManual(
    Map<String, dynamic> horarioManual,
  ) {
    if (_horarioTieneReceso(horarioManual)) {
      return {};
    }

    return {'horario_inicio_receso': null, 'horario_fin_receso': null};
  }

  Map<String, dynamic> _ubicacionesConJornadaManual(
    Object? ubicaciones,
    Map<String, dynamic> horarioManual,
  ) {
    final data = _mapaJson(ubicaciones);
    data['_jornada_manual'] = {
      'tipo_jornada': horarioManual['tipo_jornada']?.toString() ?? '',
      'nombre_jornada': horarioManual['nombre_jornada']?.toString() ?? '',
      'tiene_receso': _horarioTieneReceso(horarioManual),
      'registrado_en': _timestampLocalConZona(),
    };
    return data;
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

  Future<QRValidado?> _resolverQrDinamicoParaMarcacion(
    QRValidado qrValidado,
  ) async {
    if (!_esPayloadQrDinamico(qrValidado.token) ||
        qrValidado.idTienda.trim().isNotEmpty) {
      return qrValidado;
    }

    try {
      final response = await _db.rpc(
        'buscar_qr_por_token',
        params: {'p_token': qrValidado.token},
      );
      final row = _firstRow(response);
      if (row == null) {
        AppLogger.warning(
          'SupabaseService',
          'QR dinamico no resuelto para marcacion local',
          {'token': AppLogger.shortId(qrValidado.token)},
        );
        return null;
      }

      final idTienda = row['id_tienda']?.toString() ?? '';
      if (idTienda.trim().isEmpty) {
        return null;
      }

      final nombreTienda =
          row['nombre_tienda']?.toString() ?? qrValidado.nombreTienda;
      final direccion = row['direccion']?.toString() ?? qrValidado.direccion;

      AppLogger.info(
        'SupabaseService',
        'QR dinamico resuelto para asistencia',
        {'id_tienda': AppLogger.shortId(idTienda)},
      );

      return QRValidado(
        token: qrValidado.token,
        idSede: idTienda,
        nombreSede: nombreTienda,
        idTienda: idTienda,
        nombreTienda: nombreTienda,
        direccion: direccion,
        ubicacionQr: _mapaJson(row['ubicacion']),
      );
    } on PostgrestException catch (e, st) {
      final rpcNoExiste =
          e.code == 'PGRST202' ||
          e.code == 'PGRST203' ||
          e.code == '42883' ||
          e.message.contains('buscar_qr_por_token');
      AppLogger.error(
        'SupabaseService',
        'Error resolviendo QR dinamico para asistencia',
        e,
        st,
        {'code': e.code, 'fallback': rpcNoExiste},
      );
      if (rpcNoExiste) {
        return null;
      }
      rethrow;
    } catch (e, st) {
      AppLogger.error(
        'SupabaseService',
        'Error resolviendo QR dinamico para asistencia',
        e,
        st,
      );
      return null;
    }
  }

  Future<String?> _mensajeBloqueoSedeUltimoTracking(
    Map<String, dynamic> usuario,
    QRValidado qrValidado,
  ) async {
    final idTiendaMarcacion = qrValidado.idTienda.trim();
    if (idTiendaMarcacion.isEmpty) {
      return null;
    }

    final ahora = DateTime.now();
    final inicio = DateTime(ahora.year, ahora.month, ahora.day);
    final fin = inicio.add(const Duration(days: 1));
    final tracking = await _obtenerTrackingEnRango(usuario, inicio, fin);
    if (tracking.isEmpty) {
      return null;
    }

    final ultimo = tracking.last;
    if (_tipoMovimientoTracking(ultimo) != 'MULTIPLE') {
      return null;
    }

    final idTiendaUltima = _idTiendaTracking(ultimo);
    if (idTiendaUltima.isEmpty || idTiendaUltima == idTiendaMarcacion) {
      return null;
    }

    return 'Tu ultima marca de tracking fue en otra sede. Registra tracking en esta sede antes de marcar asistencia.';
  }

  Future<bool> _exigirEntradaAntesDeTracking(
    String dni,
    String registradoEn,
  ) async {
    final fechaTracking =
        _parseSupabaseDateTime(registradoEn)?.toLocal() ?? DateTime.now();
    final fechaConsulta = DateFormat('yyyy-MM-dd').format(fechaTracking);
    final consulta = await _obtenerAsistenciaPorFechaSegura(dni, fechaConsulta);
    final registro = consulta.registro;
    if (registro == null) {
      if (!consulta.confiable) {
        AppLogger.warning(
          'SupabaseService',
          'Entrada no confirmada por lectura; validara RPC tracking',
          {
            'dni': AppLogger.shortId(dni),
            'fecha': fechaConsulta,
            'origen_validacion': 'indeterminado',
          },
        );
        return false;
      }

      AppLogger.warning('SupabaseService', 'Tracking bloqueado sin entrada', {
        'dni': AppLogger.shortId(dni),
        'fecha': fechaConsulta,
        'origen_validacion': 'rpc_segura',
      });
      throw Exception('Primero registra tu Entrada antes de usar Tracking.');
    }

    final entrada = _parseSupabaseDateTime(
      registro['horario_entrada'],
    )?.toLocal();
    if (entrada == null || entrada.isAfter(fechaTracking)) {
      AppLogger.warning('SupabaseService', 'Tracking bloqueado sin entrada', {
        'dni': AppLogger.shortId(dni),
        'fecha': fechaConsulta,
        'entrada': entrada?.toIso8601String() ?? '',
        'tracking': fechaTracking.toIso8601String(),
      });
      throw Exception('Primero registra tu Entrada antes de usar Tracking.');
    }

    AppLogger.info('SupabaseService', 'Entrada validada para tracking', {
      'dni': AppLogger.shortId(dni),
      'fecha': fechaConsulta,
      'entrada': entrada.toIso8601String(),
      'tracking': fechaTracking.toIso8601String(),
    });
    return true;
  }

  String _idTiendaTracking(Map<String, dynamic> registro) {
    final ubicaciones = _ubicacionesTracking(registro);
    final candidatos = [
      ubicaciones['id_tienda_qr'],
      registro['id_tienda'],
      ubicaciones['id_tienda'],
    ];

    for (final candidato in candidatos) {
      final value = candidato?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }

    return '';
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
      final value = candidato?.toString().trim().toUpperCase();
      if (value == 'NORMAL') {
        return 'NORMAL';
      }
      if (value == 'MULTIPLE' ||
          value == 'TRACKING' ||
          value == 'PUNTO_A_B' ||
          value == 'PUNTO-A-B' ||
          value == 'PUNTO A B') {
        return 'MULTIPLE';
      }
    }

    return 'MULTIPLE';
  }

  void _validarRangoQr(
    QRValidado qrValidado,
    Map<String, double> ubicacion, {
    String? tipoMarcacion,
  }) {
    final referencia = _ubicacionReferenciaQr(
      qrValidado.ubicacionQr,
      tipoMarcacion,
    );
    if (referencia == null) {
      AppLogger.warning('SupabaseService', 'QR sin ubicacion de referencia', {
        'id_tienda': AppLogger.shortId(qrValidado.idTienda),
        'tipo': tipoMarcacion ?? '',
        'dinamico': _esPayloadQrDinamico(qrValidado.token),
      });
      throw Exception(
        'El QR no tiene ubicacion de referencia para validar el rango.',
      );
    }

    final distancia = _distanciaMetros(
      referencia['latitude']!,
      referencia['longitude']!,
      ubicacion['latitude']!,
      ubicacion['longitude']!,
    );

    AppLogger.info('SupabaseService', 'Rango QR validado', {
      'id_tienda': AppLogger.shortId(qrValidado.idTienda),
      'tipo': tipoMarcacion ?? '',
      'distancia_m': distancia.toStringAsFixed(1),
      'radio_m': _radioQrMetros.toStringAsFixed(0),
    });

    if (distancia > _radioQrMetros) {
      AppLogger.warning('SupabaseService', 'Marcacion fuera del radio QR', {
        'id_tienda': AppLogger.shortId(qrValidado.idTienda),
        'tipo': tipoMarcacion ?? '',
        'distancia_m': distancia.toStringAsFixed(1),
      });
      throw Exception(
        'Fuera del rango permitido del QR. Acercate a la sede para marcar.',
      );
    }
  }

  Map<String, double>? _ubicacionReferenciaQr(
    Map<String, dynamic> ubicacionQr,
    String? tipoMarcacion,
  ) {
    final directa = _latLngDesdeObjeto(ubicacionQr);
    if (directa != null) {
      return directa;
    }

    for (final clave in _clavesUbicacionQr(tipoMarcacion)) {
      final detalle = ubicacionQr[clave];
      final ubicacion = _latLngDesdeObjeto(detalle);
      if (ubicacion != null) {
        return ubicacion;
      }
    }

    for (final detalle in ubicacionQr.values) {
      final ubicacion = _latLngDesdeObjeto(detalle);
      if (ubicacion != null) {
        if (_tipoQrRequiereUbicacionEspecifica(tipoMarcacion)) {
          AppLogger.info('SupabaseService', 'Usando ubicacion general del QR', {
            'tipo': tipoMarcacion ?? '',
          });
        }
        return ubicacion;
      }
    }

    if (_tipoQrRequiereUbicacionEspecifica(tipoMarcacion)) {
      AppLogger.warning(
        'SupabaseService',
        'QR sin ubicacion especifica ni general para la marca',
        {'tipo': tipoMarcacion ?? ''},
      );
    }

    return null;
  }

  List<String> _clavesUbicacionQr(String? tipoMarcacion) {
    final claves = <String>{};

    void agregar(String? value) {
      final limpio = value?.trim();
      if (limpio != null && limpio.isNotEmpty) {
        claves.add(limpio);
        claves.add(_normalizarClaveUbicacionQr(limpio));
      }
    }

    agregar(tipoMarcacion);
    final tipo = _normalizarClaveUbicacionQr(tipoMarcacion ?? '');
    switch (tipo) {
      case 'entrada':
      case 'horario_entrada':
        agregar('horario_entrada');
        agregar('entrada');
        break;
      case 'inicio_de_receso':
      case 'inicio_receso':
      case 'horario_inicio_receso':
        agregar('horario_inicio_receso');
        agregar('inicio_receso');
        break;
      case 'fin_de_receso':
      case 'fin_receso':
      case 'horario_fin_receso':
        agregar('horario_fin_receso');
        agregar('fin_receso');
        break;
      case 'salida':
      case 'horario_salida':
        agregar('horario_salida');
        agregar('salida');
        break;
      default:
        break;
    }

    if (!_tipoQrRequiereUbicacionEspecifica(tipoMarcacion)) {
      agregar('marca');
      agregar('tracking');
      agregar('horario_entrada');
      agregar('horario_inicio_receso');
      agregar('horario_fin_receso');
      agregar('horario_salida');
    }
    return claves.toList(growable: false);
  }

  bool _tipoQrRequiereUbicacionEspecifica(String? tipoMarcacion) {
    final tipo = _normalizarClaveUbicacionQr(tipoMarcacion ?? '');
    return tipo == 'entrada' ||
        tipo == 'horario_entrada' ||
        tipo == 'inicio_de_receso' ||
        tipo == 'inicio_receso' ||
        tipo == 'horario_inicio_receso' ||
        tipo == 'fin_de_receso' ||
        tipo == 'fin_receso' ||
        tipo == 'horario_fin_receso' ||
        tipo == 'salida' ||
        tipo == 'horario_salida';
  }

  String _normalizarClaveUbicacionQr(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll('\u00e1', 'a')
        .replaceAll('\u00e9', 'e')
        .replaceAll('\u00ed', 'i')
        .replaceAll('\u00f3', 'o')
        .replaceAll('\u00fa', 'u')
        .replaceAll(RegExp(r'\s+'), '_');
  }

  Map<String, double>? _latLngDesdeObjeto(Object? value) {
    if (value is! Map) {
      return null;
    }

    final data = Map<String, dynamic>.from(value);
    final latitud = _doubleOrNull(
      data['latitud'] ?? data['latitude'] ?? data['lat'],
    );
    final longitud = _doubleOrNull(
      data['longitud'] ?? data['longitude'] ?? data['lng'] ?? data['lon'],
    );
    if (latitud == null || longitud == null) {
      return null;
    }

    final ubicacion = {'latitude': latitud, 'longitude': longitud};
    return _ubicacionTieneCoordenadas(ubicacion) ? ubicacion : null;
  }

  double _distanciaMetros(
    double latitudA,
    double longitudA,
    double latitudB,
    double longitudB,
  ) {
    const radioTierra = 6371000.0;
    final dLat = _gradosARadianes(latitudB - latitudA);
    final dLng = _gradosARadianes(longitudB - longitudA);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_gradosARadianes(latitudA)) *
            math.cos(_gradosARadianes(latitudB)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final seguro = a.clamp(0.0, 1.0).toDouble();
    return radioTierra *
        2 *
        math.atan2(math.sqrt(seguro), math.sqrt(1 - seguro));
  }

  double _gradosARadianes(double grados) => grados * math.pi / 180;

  Map<String, double> _normalizarUbicacion(Map<String, double> ubicacion) {
    return {
      'latitude': ubicacion['latitude'] ?? ubicacion['latitud'] ?? 0,
      'longitude': ubicacion['longitude'] ?? ubicacion['longitud'] ?? 0,
    };
  }

  bool _ubicacionTieneCoordenadas(Map<String, double> ubicacion) {
    final latitud = ubicacion['latitude'] ?? 0;
    final longitud = ubicacion['longitude'] ?? 0;
    return latitud.abs() > 0.000001 || longitud.abs() > 0.000001;
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
    return _timestampConZona(DateTime.now());
  }

  String _timestampConZona(DateTime fecha) {
    final local = fecha.toLocal();
    final offset = local.timeZoneOffset;
    final signo = offset.isNegative ? '-' : '+';
    final horas = offset.inHours.abs().toString().padLeft(2, '0');
    final minutos = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '${DateFormat('yyyy-MM-dd HH:mm:ss').format(local)}$signo$horas:$minutos';
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
    QRValidado qrValidado,
  ) {
    final latitud = ubicacion['latitude'];
    final longitud = ubicacion['longitude'];
    final ubicacionesActuales = asistencia['ubicaciones'] is Map
        ? Map<String, dynamic>.from(asistencia['ubicaciones'] as Map)
        : <String, dynamic>{};

    final detalle = <String, dynamic>{'latitud': latitud, 'longitud': longitud};

    void agregarSiNoVacio(String clave, String valor) {
      final limpio = valor.trim();
      if (limpio.isNotEmpty) {
        detalle[clave] = limpio;
      }
    }

    agregarSiNoVacio('id_tienda_qr', qrValidado.idTienda);
    agregarSiNoVacio('nombre_tienda', qrValidado.nombreTienda);
    agregarSiNoVacio('direccion_tienda', qrValidado.direccion);

    ubicacionesActuales[tipoMarcacion] = detalle;

    return {'ubicaciones': ubicacionesActuales};
  }

  QRValidado _qrDesdeUsuario(Map<String, dynamic> usuario) {
    final idTienda = usuario['id_tienda']?.toString() ?? '';
    final nombreTienda = usuario['nombre_tienda']?.toString() ?? 'Tienda';
    final direccion = usuario['direccion_tienda']?.toString() ?? '';
    return QRValidado(
      token: '',
      idSede: idTienda,
      nombreSede: nombreTienda,
      idTienda: idTienda,
      nombreTienda: nombreTienda,
      direccion: direccion,
    );
  }

  QRValidado _qrDesdeAsistencia(
    Map<String, dynamic> usuario,
    Map<String, dynamic> asistencia,
    String tipoMarcacion,
  ) {
    final fallback = _qrDesdeUsuario(usuario);
    final ubicaciones = asistencia['ubicaciones'];
    final ubicacionesMap = ubicaciones is Map
        ? Map<String, dynamic>.from(ubicaciones)
        : <String, dynamic>{};
    final detalle = ubicacionesMap[tipoMarcacion];
    final detalleMap = detalle is Map
        ? Map<String, dynamic>.from(detalle)
        : <String, dynamic>{};

    final idTienda = _primerTextoNoVacio([
      detalleMap['id_tienda_qr'],
      detalleMap['id_tienda'],
      fallback.idTienda,
    ]);
    final nombreTienda = _primerTextoNoVacio([
      detalleMap['nombre_tienda'],
      detalleMap['nombre_sede'],
      fallback.nombreTienda,
    ]);
    final direccion = _primerTextoNoVacio([
      detalleMap['direccion_tienda'],
      detalleMap['direccion_sede'],
      fallback.direccion,
    ]);

    return QRValidado(
      token: '',
      idSede: idTienda,
      nombreSede: nombreTienda.isNotEmpty ? nombreTienda : 'Tienda',
      idTienda: idTienda,
      nombreTienda: nombreTienda.isNotEmpty ? nombreTienda : 'Tienda',
      direccion: direccion,
    );
  }

  Map<String, double> _ubicacionDesdeAsistencia(
    Map<String, dynamic> asistencia,
    String tipoMarcacion,
  ) {
    final ubicaciones = asistencia['ubicaciones'];
    final ubicacionesMap = ubicaciones is Map
        ? Map<String, dynamic>.from(ubicaciones)
        : <String, dynamic>{};
    final detalle = ubicacionesMap[tipoMarcacion];
    final detalleMap = detalle is Map
        ? Map<String, dynamic>.from(detalle)
        : <String, dynamic>{};

    return {
      'latitude': _doubleOrZero(detalleMap['latitud']),
      'longitude': _doubleOrZero(detalleMap['longitud']),
    };
  }

  double? _doubleOrNull(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  String _primerTextoNoVacio(Iterable<Object?> valores) {
    for (final valor in valores) {
      final texto = valor?.toString().trim();
      if (texto != null && texto.isNotEmpty) {
        return texto;
      }
    }
    return '';
  }

  double _doubleOrZero(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _nombreMarcacion(String tipoMarcacion) {
    const nombres = {
      'horario_entrada': 'Entrada',
      'horario_inicio_receso': 'Inicio de receso',
      'horario_fin_receso': 'Fin de receso',
      'horario_salida': 'Salida',
    };
    return nombres[tipoMarcacion] ?? tipoMarcacion;
  }

  bool _valorPresente(Object? value) {
    return value != null && value.toString().trim().isNotEmpty;
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
        AppLogger.info('SupabaseService', 'Asistencia insertada', {
          'tabla': tabla,
          'columnas': data.keys.join(','),
        });
        return;
      } on PostgrestException catch (e, st) {
        if (_requiereAsistenciaBasica(e, data)) {
          final dataBasica = _payloadAsistenciaBasico(data);
          AppLogger.warning(
            'SupabaseService',
            'Reintentando insert de asistencia con columnas basicas',
            {
              'tabla': tabla,
              'code': e.code,
              'mensaje': e.message,
              'columnas_originales': data.keys.join(','),
              'columnas_basicas': dataBasica.keys.join(','),
            },
          );
          await _db.from(tabla).insert(dataBasica);
          return;
        }
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
        AppLogger.info('SupabaseService', 'Asistencia actualizada', {
          'tabla': tabla,
          'dni': AppLogger.shortId(dni),
          'fecha': fecha,
          'columnas': cambios.keys.join(','),
        });
        return;
      } on PostgrestException catch (e, st) {
        if (_requiereAsistenciaBasica(e, cambios)) {
          final cambiosBasicos = _payloadAsistenciaBasico(cambios);
          AppLogger.warning(
            'SupabaseService',
            'Reintentando update de asistencia con columnas basicas',
            {
              'tabla': tabla,
              'dni': AppLogger.shortId(dni),
              'fecha': fecha,
              'code': e.code,
              'mensaje': e.message,
              'columnas_originales': cambios.keys.join(','),
              'columnas_basicas': cambiosBasicos.keys.join(','),
            },
          );
          await _db
              .from(tabla)
              .update(cambiosBasicos)
              .eq('dni_trabajador', dni)
              .eq('fecha', fecha);
          return;
        }
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

  bool _requiereAsistenciaBasica(
    PostgrestException error,
    Map<String, dynamic> payload,
  ) {
    if (!payload.keys.any(_esColumnaAsistenciaOpcional)) {
      return false;
    }

    final texto =
        '${error.code} ${error.message} ${error.details ?? ''} ${error.hint ?? ''}'
            .toLowerCase();
    return texto.contains('pgrst204') ||
        texto.contains('42703') ||
        texto.contains('could not find') ||
        texto.contains('schema cache') ||
        texto.contains('column');
  }

  bool _esColumnaAsistenciaOpcional(String columna) {
    return columna == 'ubicaciones' || columna == 'justificado';
  }

  Map<String, dynamic> _payloadAsistenciaBasico(Map<String, dynamic> payload) {
    final limpio = Map<String, dynamic>.from(payload);
    limpio.removeWhere((key, _) => _esColumnaAsistenciaOpcional(key));
    return limpio;
  }

  bool _tablaNoExiste(PostgrestException e) {
    final mensaje = e.message.toLowerCase();
    return e.code == 'PGRST205' ||
        e.code == '42P01' ||
        mensaje.contains('could not find the table') ||
        mensaje.contains('does not exist');
  }

  bool _esConflictoDuplicado(PostgrestException e) {
    final mensaje = e.message.toLowerCase();
    return e.code == '23505' ||
        mensaje.contains('duplicate key') ||
        mensaje.contains('llave duplicada') ||
        mensaje.contains('unique constraint');
  }

  int? _smallIntOrNull(Object? value) {
    if (value == null) {
      return null;
    }

    final parsed = int.tryParse(value.toString());
    if (parsed == null || parsed < -32768 || parsed > 32767) {
      return null;
    }

    return parsed;
  }

  List<Map<String, dynamic>> _normalizarTrackingResponse(List<dynamic> data) {
    final normalizados = <Map<String, dynamic>>[];
    for (final item in data) {
      if (item is Map<String, dynamic>) {
        normalizados.add(Map<String, dynamic>.from(item));
      } else if (item is Map) {
        normalizados.add(Map<String, dynamic>.from(item));
      }
    }
    return normalizados;
  }

  List<Map<String, dynamic>> _deduplicarTracking(
    List<List<Map<String, dynamic>>> grupos,
  ) {
    final vistos = <String>{};
    final resultado = <Map<String, dynamic>>[];

    for (final grupo in grupos) {
      for (final item in grupo) {
        final ubicacion = _ubicacionesTracking(item);
        final key = [
          item['id']?.toString(),
          item['Fecha']?.toString() ??
              item['hora_marca']?.toString() ??
              ubicacion['hora_marca']?.toString(),
          ubicacion['dni_trabajador']?.toString(),
          ubicacion['id_tienda_qr']?.toString(),
        ].where((value) => value != null && value.isNotEmpty).join('|');

        if (vistos.add(key)) {
          resultado.add(item);
        }
      }
    }

    resultado.sort((a, b) {
      final ubicacionA = _ubicacionesTracking(a);
      final ubicacionB = _ubicacionesTracking(b);
      final fechaA = _parseSupabaseDateTime(
        a['Fecha'] ?? a['hora_marca'] ?? ubicacionA['hora_marca'],
      );
      final fechaB = _parseSupabaseDateTime(
        b['Fecha'] ?? b['hora_marca'] ?? ubicacionB['hora_marca'],
      );
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

    return resultado;
  }

  bool _trackingPerteneceAlUsuario(
    Map<String, dynamic> registro,
    String dni,
    int? idTrabajador,
  ) {
    final ubicacion = _ubicacionesTracking(registro);
    final dniRegistro =
        (registro['dni_trabajador']?.toString() ??
                ubicacion['dni_trabajador']?.toString() ??
                '')
            .trim();
    if (dniRegistro == dni) {
      return true;
    }

    final idTrabajadorTexto = registro['id_trabajador']?.toString().trim();
    if (idTrabajadorTexto == dni) {
      return true;
    }

    final idRegistro =
        _smallIntOrNull(registro['id_trabajador']) ??
        _smallIntOrNull(ubicacion['id_trabajador']);
    return idTrabajador != null && idRegistro == idTrabajador;
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
        // Algunas respuestas antiguas pueden traer JSON como texto invalido.
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

  bool _esMarcacionExitosa(String mensaje) {
    return mensaje == 'Entrada' ||
        mensaje == 'Inicio de receso' ||
        mensaje == 'Fin de receso' ||
        mensaje == 'Salida' ||
        mensaje == 'Marcacion registrada';
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

  Map<String, dynamic> _mapaJson(Object? value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) {
          return Map<String, dynamic>.from(decoded);
        }
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        return <String, dynamic>{};
      }
    }

    return <String, dynamic>{};
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
