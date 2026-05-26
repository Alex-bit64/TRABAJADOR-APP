import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';

class FirestoreService {
  final _db = FirebaseFirestore.instance;
  bool _autenticando = false;

  Future<DocumentSnapshot<Map<String, dynamic>>?> _buscarDocumentoTrabajador(
    String idTrabajador,
  ) async {
    try {
      final directo = await _db
          .collection('trabajador')
          .doc(idTrabajador)
          .get();
      if (directo.exists) {
        return directo;
      }

      const campos = ['id_trabajador', 'codigo', 'dni', 'correo'];
      for (final campo in campos) {
        final query = await _db
            .collection('trabajador')
            .where(campo, isEqualTo: idTrabajador)
            .limit(1)
            .get();

        if (query.docs.isNotEmpty) {
          return query.docs.first;
        }
      }

      return null;
    } catch (e, st) {
      debugPrint('FirestoreService._buscarDocumentoTrabajador error: $e');
      debugPrint('$st');
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> buscarUsuario(String idTrabajador) async {
    final doc = await _buscarDocumentoTrabajador(idTrabajador);
    if (doc == null) {
      return null;
    }

    final data = Map<String, dynamic>.from(doc.data() ?? {});
    data['id_trabajador'] = data['id_trabajador']?.toString() ?? doc.id;
    data['codigo'] = data['codigo']?.toString() ?? data['id_trabajador'];
    data['__document_path'] = doc.reference.path;
    data['biometria_registrada'] = _biometriaRegistrada(data);
    return data;
  }

  Future<Map<String, dynamic>?> buscarUsuarioPorCredenciales(
    String correo,
    String password,
  ) async {
    try {
      final q = await _db
          .collection('trabajador')
          .where('correo', isEqualTo: correo)
          .limit(1)
          .get();

      if (q.docs.isEmpty) {
        return null;
      }

      final doc = q.docs.first;
      final data = Map<String, dynamic>.from(doc.data());
      final pass1 = data['contrasena']?.toString();
      final pass2 = data['password']?.toString();
      final coincidePassword =
          (pass1 != null && pass1 == password) ||
          (pass2 != null && pass2 == password);

      if (!coincidePassword || data['activo'] == false) {
        return null;
      }

      data['__document_path'] = doc.reference.path;
      data['id_trabajador'] = data['id_trabajador']?.toString() ?? doc.id;
      data['codigo'] = data['codigo']?.toString() ?? data['id_trabajador'];
      data['biometria_registrada'] = _biometriaRegistrada(data);
      return data;
    } catch (e, st) {
      debugPrint('FirestoreService.buscarUsuarioPorCredenciales error: $e');
      debugPrint('$st');
      rethrow;
    }
  }

  Future<DocumentReference<Map<String, dynamic>>?> _referenciaUsuario(
    String idTrabajador,
  ) async {
    final doc = await _buscarDocumentoTrabajador(idTrabajador);
    return doc?.reference;
  }

  bool _biometriaRegistrada(Map<String, dynamic> usuario) {
    return usuario['biometria_registrada'] == true ||
        usuario['registro_huella'] == true;
  }

  Future<void> guardarDeviceId(String idTrabajador, String deviceId) async {
    final ref = await _referenciaUsuario(idTrabajador);
    if (ref == null) {
      throw Exception('Usuario no encontrado para actualizar biometria');
    }

    // Verificar que este deviceId no esté vinculado a otro trabajador distinto.
    final q = await _db
        .collection('trabajador')
        .where('devices.$deviceId', isNotEqualTo: null)
        .limit(1)
        .get();
    if (q.docs.isNotEmpty) {
      final other = q.docs.first;
      final otherId = other.data()['id_trabajador']?.toString() ?? other.id;
      if (otherId != idTrabajador) {
        throw Exception(
          'Este dispositivo ya está vinculado a otro trabajador. Registra la huella en tu propio dispositivo.',
        );
      }
    }

    await ref.update({
      'devices.$deviceId': {'registered_at': FieldValue.serverTimestamp()},
      'registro_huella': true,
      'biometria_registrada': true,
    });
  }

  Future<void> desvincularDeviceId(String idTrabajador, String deviceId) async {
    final ref = await _referenciaUsuario(idTrabajador);
    if (ref == null) {
      throw Exception('Usuario no encontrado para desvincular dispositivo');
    }

    await ref.update({
      'devices.$deviceId': FieldValue.delete(),
      'registro_huella': false,
      'biometria_registrada': false,
    });
  }

  Future<void> marcarHuellaRegistrada(String idTrabajador) async {
    final ref = await _referenciaUsuario(idTrabajador);
    if (ref == null) {
      throw Exception('Usuario no encontrado para actualizar biometria');
    }

    await ref.update({'registro_huella': true, 'biometria_registrada': true});
  }

  Future<bool> verificarBiometriaLogin(Map<String, dynamic> usuario) async {
    if (!_biometriaRegistrada(usuario)) {
      return false;
    }

    final auth = LocalAuthentication();
    if (_autenticando) {
      return false;
    }

    _autenticando = true;

    try {
      final autenticado = await auth.authenticate(
        localizedReason: 'Verifica tu identidad',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );

      if (!autenticado) {
        return false;
      }
    } on PlatformException catch (e) {
      if (e.code == 'LockedOut') {
        throw Exception('Demasiados intentos fallidos. Espera unos segundos.');
      }
      if (e.code == 'PermanentlyLockedOut') {
        throw Exception('Biometria bloqueada. Desbloquea el telefono.');
      }
      throw Exception('Error de biometria: ${e.message}');
    } finally {
      _autenticando = false;
    }

    return true;
  }

  Future<String> obtenerDeviceIdActual() async {
    final info = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      return android.id;
    }

    if (Platform.isIOS) {
      final ios = await info.iosInfo;
      return ios.identifierForVendor ?? 'ios-desconocido';
    }

    return 'unknown';
  }

  Future<Map<String, dynamic>?> obtenerAsistenciaHoy(
    String idTrabajador, {
    String? idSede,
  }) async {
    final hoyKey = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final docs = await _buscarDocumentosDiaTrabajador(
      idTrabajador,
      idSede: idSede,
      diaId: hoyKey,
    );

    if (docs.isEmpty) {
      return null;
    }

    final data = docs.first.data();
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  Future<List<Map<String, dynamic>>> obtenerHistorialAsistenciasMes(
    String idTrabajador,
    DateTime fechaMes, {
    String? idSede,
  }) async {
    final inicioMes = DateTime(fechaMes.year, fechaMes.month, 1);
    final finMes = DateTime(
      fechaMes.year,
      fechaMes.month + 1,
      1,
    ).subtract(const Duration(days: 1));

    final historial = <Map<String, dynamic>>[];
    final docs = await _buscarDocumentosDiaTrabajador(
      idTrabajador,
      idSede: idSede,
    );

    for (final doc in docs) {
      final data = doc.data();
      if (data == null) {
        continue;
      }

      DateTime? fecha;
      try {
        fecha = DateTime.parse(doc.id);
      } catch (_) {
        continue;
      }

      if (fecha.isBefore(inicioMes) || fecha.isAfter(finMes)) {
        continue;
      }

      final registro = Map<String, dynamic>.from(data);
      registro['__fecha'] = fecha;
      historial.add(registro);
    }

    historial.sort((a, b) {
      final aFecha = a['__fecha'] as DateTime;
      final bFecha = b['__fecha'] as DateTime;
      return bFecha.compareTo(aFecha);
    });

    return historial;
  }

  Future<String> registrarMarcacion(
    Map<String, dynamic> usuario,
    QRValidado qrValidado, {
    required Map<String, double> ubicacion,
  }) async {
    final idTrabajador = usuario['id_trabajador']?.toString() ?? '';
    final idSede = qrValidado.idSede;
    final correo = usuario['correo']?.toString() ?? '';

    if (idTrabajador.isEmpty || idSede.isEmpty || correo.isEmpty) {
      throw Exception(
        'Faltan datos del trabajador para registrar la asistencia.',
      );
    }

    final trabajador = await buscarUsuario(idTrabajador);
    if (trabajador == null) {
      throw Exception('No se encontro el trabajador en Firestore.');
    }

    if (trabajador['correo']?.toString() != correo) {
      throw Exception('El trabajador autenticado no coincide con el registro.');
    }

    final trabajadorRef = _db
        .collection('asistencias')
        .doc(idSede)
        .collection('trabajadores')
        .doc(idTrabajador);

    final fechaServidor = await _obtenerFechaServidor(trabajadorRef);
    final hoyKey = DateFormat('yyyy-MM-dd').format(fechaServidor);
    final horaServidor = DateFormat('HH:mm').format(fechaServidor);
    final diaSemana = _nombreDia(fechaServidor.weekday);
    final horarioDia = Map<String, dynamic>.from(
      ((trabajador['horario'] as Map<String, dynamic>?)?[diaSemana]
              as Map<String, dynamic>?) ??
          const {},
    );

    final diaRef = trabajadorRef.collection('dias').doc(hoyKey);
    final snapshot = await diaRef.get();
    final dayMap = Map<String, dynamic>.from(snapshot.data() ?? {});

    dayMap['horario'] = horarioDia;
    dayMap.putIfAbsent('entrada', () => null);
    dayMap.putIfAbsent('refrigerio_inicio', () => null);
    dayMap.putIfAbsent('refrigerio_fin', () => null);
    dayMap.putIfAbsent('salida', () => null);

    final tipoMarcacion = _siguienteMarcacion(dayMap);
    if (tipoMarcacion == null) {
      return 'Ya completaste todas las marcaciones de hoy';
    }

    dayMap['actualizado_en'] = FieldValue.serverTimestamp();
    dayMap[tipoMarcacion] = {
      'direccion_qr': qrValidado.direccion,
      'estado': 'registrado',
      'hora': horaServidor,
      'id_sede': qrValidado.idSede,
      'id_tienda': qrValidado.idTienda,
      'marca': FieldValue.serverTimestamp(),
      'nombre_sede': qrValidado.nombreSede,
      'nombre_tienda': qrValidado.nombreTienda,
      'token_qr': qrValidado.token,
      'ubicacion': ubicacion,
    };

    await trabajadorRef.set({
      'id_trabajador': idTrabajador,
      'correo': correo,
      'nombre_trabajador': trabajador['nombre_trabajador']?.toString() ?? '',
      'id_sede': idSede,
      'ultima_marca': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await diaRef.set(dayMap, SetOptions(merge: true));
    return tipoMarcacion;
  }

  Future<DateTime> _obtenerFechaServidor(
    DocumentReference<Map<String, dynamic>> trabajadorRef,
  ) async {
    await trabajadorRef.set({
      'ultima_marca': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    final snapshot = await trabajadorRef.get();
    final timestamp = snapshot.data()?['ultima_marca'] as Timestamp?;

    if (timestamp == null) {
      throw Exception('No se pudo obtener la hora del servidor.');
    }

    return timestamp.toDate();
  }

  String? _siguienteMarcacion(Map<String, dynamic> dayMap) {
    const orden = ['entrada', 'refrigerio_inicio', 'refrigerio_fin', 'salida'];

    for (final clave in orden) {
      if (dayMap[clave] == null) {
        return clave;
      }
    }

    return null;
  }

  String _nombreDia(int weekday) {
    const dias = [
      'lunes',
      'martes',
      'miercoles',
      'jueves',
      'viernes',
      'sabado',
      'domingo',
    ];
    return dias[weekday - 1];
  }

  Future<List<DocumentSnapshot<Map<String, dynamic>>>>
  _buscarDocumentosDiaTrabajador(
    String idTrabajador, {
    String? idSede,
    String? diaId,
  }) async {
    final refs = await _buscarReferenciasTrabajador(
      idTrabajador,
      idSede: idSede,
    );
    final docs = <DocumentSnapshot<Map<String, dynamic>>>[];

    for (final ref in refs) {
      if (diaId != null) {
        final doc = await ref.collection('dias').doc(diaId).get();
        if (doc.exists) {
          docs.add(doc);
        }
        continue;
      }

      final snap = await ref.collection('dias').get();
      docs.addAll(snap.docs);
    }

    return docs;
  }

  Future<List<DocumentReference<Map<String, dynamic>>>>
  _buscarReferenciasTrabajador(String idTrabajador, {String? idSede}) async {
    if (idSede != null && idSede.isNotEmpty) {
      final ref = _db
          .collection('asistencias')
          .doc(idSede)
          .collection('trabajadores')
          .doc(idTrabajador);
      final doc = await ref.get();
      if (doc.exists) {
        return [ref];
      }
    }

    final sedes = await _db.collection('asistencias').get();
    final encontrados = <DocumentReference<Map<String, dynamic>>>[];

    for (final sede in sedes.docs) {
      final ref = sede.reference.collection('trabajadores').doc(idTrabajador);
      final doc = await ref.get();
      if (doc.exists) {
        encontrados.add(ref);
      }
    }

    return encontrados;
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
