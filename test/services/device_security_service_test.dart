import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:trabajador_app/services/device_security_service.dart';

class _FakeLocalAuthPlatform extends LocalAuthPlatform {
  _FakeLocalAuthPlatform({
    required this.supported,
    this.authenticated = true,
    this.error,
  });

  final bool supported;
  final bool authenticated;
  final LocalAuthException? error;

  int authenticationAttempts = 0;
  AuthenticationOptions? receivedOptions;

  @override
  Future<bool> isDeviceSupported() async => supported;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authenticationAttempts++;
    receivedOptions = options;
    if (error case final authError?) {
      throw authError;
    }
    return authenticated;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceSecurityService.autenticar', () {
    test(
      'continua sin reto cuando el telefono no tiene proteccion local',
      () async {
        final platform = _FakeLocalAuthPlatform(supported: false);
        LocalAuthPlatform.instance = platform;

        await DeviceSecurityService().autenticar(motivo: 'Confirmar marca');

        expect(platform.authenticationAttempts, 0);
      },
    );

    test('acepta biometria o credencial del dispositivo', () async {
      final platform = _FakeLocalAuthPlatform(supported: true);
      LocalAuthPlatform.instance = platform;

      await DeviceSecurityService().autenticar(motivo: 'Confirmar marca');

      expect(platform.authenticationAttempts, 1);
      expect(platform.receivedOptions?.biometricOnly, isFalse);
      expect(platform.receivedOptions?.stickyAuth, isTrue);
    });

    test('continua si Android confirma que no hay credenciales', () async {
      final platform = _FakeLocalAuthPlatform(
        supported: true,
        error: const LocalAuthException(
          code: LocalAuthExceptionCode.noCredentialsSet,
        ),
      );
      LocalAuthPlatform.instance = platform;

      await DeviceSecurityService().autenticar(motivo: 'Confirmar marca');

      expect(platform.authenticationAttempts, 1);
    });

    test('no permite continuar cuando el usuario cancela', () async {
      final platform = _FakeLocalAuthPlatform(
        supported: true,
        authenticated: false,
      );
      LocalAuthPlatform.instance = platform;

      expect(
        () => DeviceSecurityService().autenticar(motivo: 'Confirmar marca'),
        throwsA(isA<DeviceSecurityException>()),
      );
    });
  });
}
