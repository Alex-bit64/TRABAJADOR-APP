import 'package:flutter_test/flutter_test.dart';
import 'package:trabajador_app/services/app_version_service.dart';

void main() {
  group('AppVersionService.requiereActualizacion', () {
    test('requiere actualizar cuando el build publicado es mayor', () {
      expect(
        AppVersionService.requiereActualizacion(
          buildInstalado: 3,
          buildPublicado: 4,
        ),
        isTrue,
      );
    });

    test('no actualiza si el build instalado es igual o superior', () {
      expect(
        AppVersionService.requiereActualizacion(
          buildInstalado: 4,
          buildPublicado: 4,
        ),
        isFalse,
      );
      expect(
        AppVersionService.requiereActualizacion(
          buildInstalado: 5,
          buildPublicado: 4,
        ),
        isFalse,
      );
    });
  });
}
