import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class BiometricStore {
  static const _prefix = 'profile_';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> canCheckBiometrics() async {
    try {
      return await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  Future<void> saveProfile({
    required String idTrabajador,
    required String correo,
    required String password,
  }) async {
    final key = '$_prefix$idTrabajador';
    final payload = json.encode({
      'id_trabajador': idTrabajador,
      'correo': correo,
      'password': password,
    });

    await _storage.write(key: key, value: payload);
  }

  Future<List<String>> getSavedProfilesKeys() async {
    final all = await _storage.readAll();
    return all.keys.where((k) => k.startsWith(_prefix)).toList();
  }

  Future<Map<String, String>?> readProfileWithBiometrics(
    String key, {
    String reason = 'Autentícate para usar este perfil',
  }) async {
    try {
      final didAuth = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );

      if (!didAuth) return null;

      final raw = await _storage.read(key: key);
      if (raw == null) return null;
      final Map<String, dynamic> data = json.decode(raw);
      return {
        'id_trabajador': data['id_trabajador']?.toString() ?? '',
        'correo': data['correo']?.toString() ?? '',
        'password': data['password']?.toString() ?? '',
      };
    } on PlatformException {
      return null;
    }
  }

  Future<void> deleteProfile(String key) async {
    await _storage.delete(key: key);
  }

  Future<void> deleteProfileForId(String idTrabajador) async {
    final key = '$_prefix$idTrabajador';
    await deleteProfile(key);
  }
}
