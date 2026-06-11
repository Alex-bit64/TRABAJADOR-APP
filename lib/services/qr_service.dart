import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_logger.dart';

class QRService {
  Future<QRValidacionResult> validarQR(
    String qrRaw,
    Map<String, dynamic> usuario,
  ) async {
    try {
      AppLogger.info('QRService', 'Validacion QR iniciada', {
        'dni': AppLogger.shortId(usuario['dni']?.toString() ?? ''),
        'raw_length': qrRaw.length,
      });

      final qrData = _parsearQR(qrRaw);
      final tokenQR = _extraerToken(qrData);

      if (tokenQR == null || tokenQR.isEmpty) {
        AppLogger.warning('QRService', 'QR sin token');
        return QRValidacionResult.error('El QR no contiene un token valido.');
      }

      AppLogger.info('QRService', 'Buscando QR registrado', {
        'token': AppLogger.shortId(tokenQR),
        'token_length': tokenQR.length,
        'token_prefix': tokenQR.length >= 8 ? tokenQR.substring(0, 8) : tokenQR,
        'id_tienda_qr': AppLogger.shortId(
          qrData['id_tienda']?.toString() ?? '',
        ),
      });

      if (_esPayloadDinamico(tokenQR)) {
        final ubicacion = await _obtenerUbicacion();

        AppLogger.info(
          'QRService',
          'QR dinamico recibido para validacion RPC',
          {'raw_length': tokenQR.length},
        );

        return QRValidacionResult.exito(
          qrValidado: QRValidado(
            token: tokenQR,
            idSede: '',
            nombreSede: 'QR de tienda',
            idTienda: '',
            nombreTienda: 'QR de tienda',
            direccion: '',
          ),
          ubicacion: ubicacion,
        );
      }

      final qrRecord = await _buscarQR(qrData, tokenQR);
      if (qrRecord == null) {
        AppLogger.warning('QRService', 'QR no encontrado', {
          'token': AppLogger.shortId(tokenQR),
        });
        return QRValidacionResult.error('Codigo no valido o vencido.');
      }

      final tokenSupabase = qrRecord['token']?.toString() ?? '';
      final idTiendaQR = qrRecord['id_tienda']?.toString() ?? '';

      if (tokenSupabase != tokenQR) {
        AppLogger.warning('QRService', 'Token QR no coincide', {
          'token_qr': AppLogger.shortId(tokenQR),
          'token_db': AppLogger.shortId(tokenSupabase),
        });
        return QRValidacionResult.error('Codigo no valido o vencido.');
      }

      final tiendaInfo = qrRecord['nombre_tienda'] == null
          ? await _obtenerInfoTienda(idTiendaQR)
          : null;
      final nombreTienda =
          qrRecord['nombre_tienda']?.toString() ??
          tiendaInfo?['nombre']?.toString() ??
          'Tienda';
      final direccion =
          qrRecord['direccion']?.toString() ??
          tiendaInfo?['direccion']?.toString() ??
          '';
      final ubicacion = await _obtenerUbicacion();

      AppLogger.info('QRService', 'QR validado correctamente', {
        'id_tienda': AppLogger.shortId(idTiendaQR),
        'tienda': nombreTienda,
        'lat': ubicacion['latitude']?.toStringAsFixed(5),
        'lng': ubicacion['longitude']?.toStringAsFixed(5),
      });

      return QRValidacionResult.exito(
        qrValidado: QRValidado(
          token: tokenSupabase,
          idSede: idTiendaQR,
          nombreSede: nombreTienda,
          idTienda: idTiendaQR,
          nombreTienda: nombreTienda,
          direccion: direccion,
        ),
        ubicacion: ubicacion,
      );
    } catch (e, st) {
      AppLogger.error('QRService', 'Error validando QR', e, st);
      final rawMensaje = e.toString();
      if (rawMensaje.contains('Activa la ubicacion') ||
          rawMensaje.contains('permiso de ubicacion') ||
          rawMensaje.contains('bloqueado')) {
        return QRValidacionResult.error(
          rawMensaje.replaceAll('Exception: ', ''),
        );
      }

      return QRValidacionResult.error(
        'No se pudo validar el QR. Revisa tu conexion e intenta de nuevo.',
      );
    }
  }

  Map<String, dynamic> _parsearQR(String qrRaw) {
    final limpio = qrRaw.trim();
    try {
      final data = jsonDecode(limpio);
      if (data is Map<String, dynamic>) {
        AppLogger.info('QRService', 'QR parseado como JSON', {
          'keys': data.keys.join(','),
        });
        return data;
      }
      if (data is List && data.isNotEmpty && data.first is Map) {
        final item = Map<String, dynamic>.from(data.first as Map);
        AppLogger.info('QRService', 'QR parseado como lista JSON', {
          'keys': item.keys.join(','),
        });
        return item;
      }
      if (data is String) {
        AppLogger.info('QRService', 'QR parseado como string JSON');
        return {'token': data.trim()};
      }
      throw const FormatException();
    } catch (_) {
      AppLogger.info('QRService', 'QR parseado como token plano');
      return {'token': limpio};
    }
  }

  String? _extraerToken(Map<String, dynamic> qrData) {
    final candidatos = [
      qrData['token'],
      qrData['qr_token'],
      qrData['codigo'],
      qrData['code'],
      qrData['value'],
    ];

    for (final candidato in candidatos) {
      final token = _normalizarToken(candidato?.toString());
      if (token != null && token.isNotEmpty) {
        AppLogger.info('QRService', 'Token extraido de QR', {
          'token': AppLogger.shortId(token),
          'length': token.length,
        });
        return token;
      }
    }

    return null;
  }

  String? _normalizarToken(String? raw) {
    if (raw == null) {
      return null;
    }

    var value = raw.trim();
    if (value.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(value);
    if (_esPayloadDinamico(value)) {
      return value;
    }

    if (uri != null && uri.hasQuery) {
      final tokenParam =
          uri.queryParameters['token'] ??
          uri.queryParameters['qr'] ??
          uri.queryParameters['code'];
      if (tokenParam != null && tokenParam.trim().isNotEmpty) {
        value = tokenParam.trim();
      }
    }

    if (_esPayloadDinamico(value)) {
      return value;
    }

    final tokenHex = RegExp(r'[0-9a-fA-F]{32,}').firstMatch(value)?.group(0);
    if (tokenHex != null && tokenHex.isNotEmpty) {
      value = tokenHex;
    }

    value = value.replaceAll('"', '').trim();
    return value;
  }

  bool _esPayloadDinamico(String value) {
    return value.trim().startsWith('app-qr-dinamico://');
  }

  Future<Map<String, dynamic>?> _buscarQR(
    Map<String, dynamic> qrData,
    String tokenQR,
  ) async {
    try {
      final supabase = Supabase.instance.client;
      AppLogger.info('QRService', 'Consulta QR por RPC', {
        'token': AppLogger.shortId(tokenQR),
        'token_length': tokenQR.length,
      });

      final rpcRecord = await _buscarQRRpc(supabase, tokenQR);
      if (rpcRecord != null) {
        return rpcRecord;
      }

      AppLogger.info('QRService', 'Consulta QR directa por token', {
        'token': AppLogger.shortId(tokenQR),
        'token_length': tokenQR.length,
      });

      final porToken = await supabase
          .from('qr')
          .select()
          .eq('token', tokenQR)
          .limit(1);

      if (porToken.isNotEmpty) {
        AppLogger.info('QRService', 'QR encontrado por token', {
          'token': AppLogger.shortId(tokenQR),
        });
        return Map<String, dynamic>.from(porToken.first);
      }

      final porTokenNormalizado = await supabase
          .from('qr')
          .select()
          .ilike('token', tokenQR)
          .limit(1);

      if (porTokenNormalizado.isNotEmpty) {
        AppLogger.info('QRService', 'QR encontrado por token normalizado', {
          'token': AppLogger.shortId(tokenQR),
        });
        return Map<String, dynamic>.from(porTokenNormalizado.first);
      }

      AppLogger.warning('QRService', 'No se encontro QR', {
        'token': AppLogger.shortId(tokenQR),
        'token_length': tokenQR.length,
      });
      return null;
    } catch (e, st) {
      AppLogger.error('QRService', 'Error buscando QR', e, st, {
        'token': AppLogger.shortId(tokenQR),
      });
      return null;
    }
  }

  Future<Map<String, dynamic>?> _buscarQRRpc(
    SupabaseClient supabase,
    String tokenQR,
  ) async {
    try {
      final response = await supabase.rpc(
        'buscar_qr_por_token',
        params: {'p_token': tokenQR},
      );

      final row = _firstRow(response);
      if (row == null) {
        AppLogger.warning('QRService', 'RPC QR no encontro token', {
          'token': AppLogger.shortId(tokenQR),
          'token_length': tokenQR.length,
        });
        return null;
      }

      AppLogger.info('QRService', 'QR encontrado por RPC', {
        'token': AppLogger.shortId(row['token']?.toString() ?? ''),
        'id_tienda': AppLogger.shortId(row['id_tienda']?.toString() ?? ''),
      });
      return row;
    } on PostgrestException catch (e, st) {
      final rpcNoExiste =
          e.code == 'PGRST202' ||
          e.code == '42883' ||
          e.message.contains('buscar_qr_por_token');
      AppLogger.error('QRService', 'Error RPC buscar_qr_por_token', e, st, {
        'code': e.code,
        'fallback_directo': rpcNoExiste,
      });
      if (rpcNoExiste) {
        return null;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _obtenerInfoTienda(String idTienda) async {
    try {
      AppLogger.info('QRService', 'Consultando tienda del QR', {
        'id_tienda': AppLogger.shortId(idTienda),
      });

      final response = await Supabase.instance.client
          .from('tienda')
          .select()
          .eq('id_tienda', idTienda)
          .limit(1);

      if (response.isEmpty) {
        AppLogger.warning('QRService', 'Tienda no encontrada para QR', {
          'id_tienda': AppLogger.shortId(idTienda),
        });
        return null;
      }

      AppLogger.info('QRService', 'Tienda encontrada para QR', {
        'id_tienda': AppLogger.shortId(idTienda),
      });
      return Map<String, dynamic>.from(response.first);
    } catch (e, st) {
      AppLogger.error('QRService', 'Error consultando tienda', e, st, {
        'id_tienda': AppLogger.shortId(idTienda),
      });
      return null;
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

  Future<Map<String, double>> _obtenerUbicacion() async {
    AppLogger.info('QRService', 'Verificando servicio de ubicacion');
    final servicioActivo = await Geolocator.isLocationServiceEnabled();
    if (!servicioActivo) {
      AppLogger.warning('QRService', 'Servicio de ubicacion desactivado');
      throw Exception('Activa la ubicacion del dispositivo para continuar.');
    }

    var permiso = await Geolocator.checkPermission();
    AppLogger.info('QRService', 'Permiso de ubicacion actual', {
      'permiso': permiso.name,
    });

    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
      AppLogger.info('QRService', 'Permiso de ubicacion solicitado', {
        'permiso': permiso.name,
      });
    }

    if (permiso == LocationPermission.denied) {
      AppLogger.warning('QRService', 'Permiso de ubicacion denegado');
      throw Exception('Debes aceptar el permiso de ubicacion para marcar.');
    }

    if (permiso == LocationPermission.deniedForever) {
      AppLogger.warning('QRService', 'Permiso de ubicacion bloqueado');
      throw Exception(
        'El permiso de ubicacion esta bloqueado. Habilitalo desde ajustes.',
      );
    }

    try {
      final posicion = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      AppLogger.info('QRService', 'Ubicacion actual obtenida', {
        'lat': posicion.latitude.toStringAsFixed(5),
        'lng': posicion.longitude.toStringAsFixed(5),
      });
      return {'latitude': posicion.latitude, 'longitude': posicion.longitude};
    } catch (e, st) {
      AppLogger.warning('QRService', 'No se pudo obtener ubicacion actual', {
        'error': e.toString(),
      });
      AppLogger.error('QRService', 'Detalle error ubicacion actual', e, st);
      final posicion = await Geolocator.getLastKnownPosition();
      AppLogger.info('QRService', 'Usando ultima ubicacion conocida', {
        'lat': posicion?.latitude.toStringAsFixed(5) ?? '0',
        'lng': posicion?.longitude.toStringAsFixed(5) ?? '0',
      });
      return {
        'latitude': posicion?.latitude ?? 0,
        'longitude': posicion?.longitude ?? 0,
      };
    }
  }
}

class QRValidacionResult {
  final bool valido;
  final String? mensajeError;
  final QRValidado? qrValidado;
  final Map<String, double>? ubicacion;

  const QRValidacionResult._({
    required this.valido,
    this.mensajeError,
    this.qrValidado,
    this.ubicacion,
  });

  factory QRValidacionResult.exito({
    required QRValidado qrValidado,
    required Map<String, double> ubicacion,
  }) {
    return QRValidacionResult._(
      valido: true,
      qrValidado: qrValidado,
      ubicacion: ubicacion,
    );
  }

  factory QRValidacionResult.error(String mensaje) {
    return QRValidacionResult._(valido: false, mensajeError: mensaje);
  }
}

class QRValidado {
  final String token;
  final String idSede;
  final String nombreSede;
  final String idTienda;
  final String nombreTienda;
  final String direccion;

  const QRValidado({
    required this.token,
    required this.idSede,
    required this.nombreSede,
    required this.idTienda,
    required this.nombreTienda,
    required this.direccion,
  });
}
