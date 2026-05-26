import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'firestore_service.dart';

class QRService {
  Future<QRValidacionResult> validarQR(
    String qrRaw,
    Map<String, dynamic> usuario,
  ) async {
    try {
      final qrData = _parsearQR(qrRaw);
      final tokenQR = qrData['token']?.toString();

      if (tokenQR == null || tokenQR.isEmpty) {
        return QRValidacionResult.error('El QR no contiene un token valido.');
      }

      final qrDoc = await _buscarDocumentoQR(qrData, tokenQR);
      if (qrDoc == null || !qrDoc.exists) {
        return QRValidacionResult.error(
          'No se encontro el QR activo en Firebase.',
        );
      }

      final qrFirebase = qrDoc.data() ?? {};
      final tokenFirebase = qrFirebase['token']?.toString() ?? '';
      final idSedeQR = qrFirebase['id_sede']?.toString() ?? '';
      final activo = qrFirebase['activo'] == true;

      if (!activo) {
        return QRValidacionResult.error('El QR se encuentra inactivo.');
      }

      if (tokenFirebase != tokenQR) {
        return QRValidacionResult.error(
          'El token del QR no coincide con Firebase.',
        );
      }

      final nombreSede = qrFirebase['nombre_sede']?.toString() ?? '';
      final idTienda = qrFirebase['id_tienda']?.toString() ?? qrDoc.id;
      final nombreTienda = qrFirebase['nombre_tienda']?.toString() ?? '';
      final direccion = qrFirebase['direccion']?.toString() ?? '';

      final ubicacion = await _obtenerUbicacion();

      return QRValidacionResult.exito(
        qrValidado: QRValidado(
          token: tokenFirebase,
          idSede: idSedeQR,
          nombreSede: nombreSede,
          idTienda: idTienda,
          nombreTienda: nombreTienda,
          direccion: direccion,
        ),
        ubicacion: ubicacion,
      );
    } catch (e, st) {
      debugPrint('QRService.validarQR error: $e');
      debugPrint('$st');
      final rawMensaje = e.toString();
      if (rawMensaje.contains('Activa la ubicacion') ||
          rawMensaje.contains('permiso de ubicacion') ||
          rawMensaje.contains('bloqueado')) {
        return QRValidacionResult.error(
          rawMensaje.replaceAll('Exception: ', ''),
        );
      }
      return QRValidacionResult.error(
        'No se pudo validar el QR. Revisa tu conexión e intenta de nuevo.',
      );
    }
  }

  Map<String, dynamic> _parsearQR(String qrRaw) {
    try {
      final data = jsonDecode(qrRaw);
      if (data is Map<String, dynamic>) {
        return data;
      }
      throw const FormatException();
    } catch (_) {
      return {'token': qrRaw.trim()};
    }
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _buscarDocumentoQR(
    Map<String, dynamic> qrData,
    String tokenQR,
  ) async {
    final db = FirebaseFirestore.instance;
    final posiblesIds = [
      qrData['id_tienda']?.toString(),
      qrData['id_sede']?.toString(),
    ].whereType<String>().where((id) => id.isNotEmpty);

    for (final id in posiblesIds) {
      final doc = await db.collection('qr_activos').doc(id).get();
      if (doc.exists) {
        return doc;
      }
    }

    final porToken = await db
        .collection('qr_activos')
        .where('token', isEqualTo: tokenQR)
        .limit(1)
        .get();

    if (porToken.docs.isNotEmpty) {
      return porToken.docs.first;
    }

    return null;
  }

  Future<Map<String, double>> _obtenerUbicacion() async {
    final servicioActivo = await Geolocator.isLocationServiceEnabled();
    if (!servicioActivo) {
      throw Exception('Activa la ubicacion del dispositivo para continuar.');
    }

    var permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
    }

    if (permiso == LocationPermission.denied) {
      throw Exception('Debes aceptar el permiso de ubicacion para marcar.');
    }

    if (permiso == LocationPermission.deniedForever) {
      throw Exception(
        'El permiso de ubicacion esta bloqueado. Habilitalo desde ajustes.',
      );
    }

    try {
      final posicion = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      return {'latitude': posicion.latitude, 'longitude': posicion.longitude};
    } catch (_) {
      final posicion = await Geolocator.getLastKnownPosition();
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
