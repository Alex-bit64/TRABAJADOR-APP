import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:uuid/uuid.dart';

import 'app_logger.dart';

class DeviceCredentials {
  final String deviceId;
  final String secret;

  const DeviceCredentials({required this.deviceId, required this.secret});
}

class DeviceSecurityException implements Exception {
  final String message;

  const DeviceSecurityException(this.message);

  @override
  String toString() => message;
}

class DeviceSecurityService {
  DeviceSecurityService({
    LocalAuthentication? localAuthentication,
    FlutterSecureStorage? secureStorage,
  }) : _localAuthentication = localAuthentication ?? LocalAuthentication(),
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _deviceIdKey = 'trabajador_device_id_v1';
  static const _deviceSecretKey = 'trabajador_device_secret_v1';
  static const _boundDniKey = 'trabajador_device_bound_dni_v1';

  final LocalAuthentication _localAuthentication;
  final FlutterSecureStorage _secureStorage;

  Future<void> autenticar({required String motivo}) async {
    try {
      // isDeviceSupported incluye tanto biometria como la credencial local del
      // telefono (PIN, patron o contrasena). Si no existe ninguna, el flujo de
      // marcacion puede continuar sin autenticacion local.
      final tieneProteccionLocal = await _localAuthentication
          .isDeviceSupported();
      if (!tieneProteccionLocal) {
        AppLogger.warning(
          'DeviceSecurity',
          'Dispositivo sin biometria ni credencial local; se continua sin reto',
        );
        return;
      }

      final autenticado = await _localAuthentication.authenticate(
        localizedReason: motivo,
        // Permite huella/rostro y, si no estan disponibles, el PIN, patron o
        // contrasena configurados en Android.
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      if (!autenticado) {
        throw const DeviceSecurityException(
          'La validacion del dispositivo fue cancelada o no pudo confirmarse.',
        );
      }
    } on DeviceSecurityException {
      rethrow;
    } on LocalAuthException catch (e, st) {
      AppLogger.error('DeviceSecurity', 'Error de autenticacion local', e, st, {
        'code': e.code.name,
      });
      if (e.code == LocalAuthExceptionCode.noCredentialsSet) {
        AppLogger.warning(
          'DeviceSecurity',
          'El sistema confirmo que no hay credenciales locales; se continua sin reto',
        );
        return;
      }
      if (e.code == LocalAuthExceptionCode.temporaryLockout ||
          e.code == LocalAuthExceptionCode.biometricLockout) {
        throw const DeviceSecurityException(
          'La validacion esta bloqueada por varios intentos. Desbloquea el celular con tu patron, PIN o contrasena e intenta nuevamente.',
        );
      }
      throw const DeviceSecurityException(
        'No se pudo validar la huella, rostro, patron, PIN o contrasena del dispositivo.',
      );
    } catch (e, st) {
      AppLogger.error(
        'DeviceSecurity',
        'Fallo inesperado validando biometria',
        e,
        st,
      );
      throw const DeviceSecurityException(
        'No se pudo iniciar la validacion del dispositivo.',
      );
    }
  }

  Future<DeviceCredentials> obtenerCredenciales({
    bool crearSiFaltan = true,
  }) async {
    var deviceId = await _secureStorage.read(key: _deviceIdKey);
    var secret = await _secureStorage.read(key: _deviceSecretKey);
    if ((deviceId == null ||
            deviceId.isEmpty ||
            secret == null ||
            secret.isEmpty) &&
        !crearSiFaltan) {
      throw const DeviceSecurityException(
        'Este dispositivo todavia no esta vinculado al trabajador.',
      );
    }

    if (deviceId == null || deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await _secureStorage.write(key: _deviceIdKey, value: deviceId);
    }
    if (secret == null || secret.isEmpty) {
      secret = '${const Uuid().v4()}${const Uuid().v4()}';
      await _secureStorage.write(key: _deviceSecretKey, value: secret);
    }
    return DeviceCredentials(deviceId: deviceId, secret: secret);
  }

  Future<void> guardarDniVinculado(String dni) async {
    await _secureStorage.write(key: _boundDniKey, value: dni.trim());
  }

  Future<bool> estaVinculadoLocalmente(String dni) async {
    final vinculado = await _secureStorage.read(key: _boundDniKey);
    return vinculado?.trim() == dni.trim() && dni.trim().isNotEmpty;
  }
}
