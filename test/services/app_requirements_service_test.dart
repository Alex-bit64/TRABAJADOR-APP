import 'package:flutter_test/flutter_test.dart';
import 'package:trabajador_app/services/app_requirements_service.dart';

void main() {
  const internetOffline = AppRequirementStatus(
    type: AppRequirementType.internet,
    title: 'Internet',
    message: 'Sin internet',
    resolved: false,
  );
  const gpsReady = AppRequirementStatus(
    type: AppRequirementType.locationService,
    title: 'GPS',
    message: 'GPS listo',
    resolved: true,
  );
  const locationReady = AppRequirementStatus(
    type: AppRequirementType.locationPermission,
    title: 'Ubicacion',
    message: 'Permiso listo',
    resolved: true,
  );
  const cameraReady = AppRequirementStatus(
    type: AppRequirementType.cameraPermission,
    title: 'Camara',
    message: 'Permiso listo',
    resolved: true,
  );

  test('permite entrar sin internet cuando GPS y camara estan listos', () {
    const result = AppRequirementsResult([
      internetOffline,
      gpsReady,
      locationReady,
      cameraReady,
    ]);

    expect(result.ready, isTrue);
    expect(result.hasInternet, isFalse);
    expect(result.pending, contains(internetOffline));
  });

  test('mantiene bloqueado el flujo si falta un requisito fisico', () {
    const gpsDisabled = AppRequirementStatus(
      type: AppRequirementType.locationService,
      title: 'GPS',
      message: 'GPS apagado',
      resolved: false,
      blocked: true,
    );
    const result = AppRequirementsResult([
      internetOffline,
      gpsDisabled,
      locationReady,
      cameraReady,
    ]);

    expect(result.ready, isFalse);
    expect(result.hasBlockedPending, isTrue);
  });
}
