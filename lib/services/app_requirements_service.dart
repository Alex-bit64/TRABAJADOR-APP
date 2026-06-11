import 'dart:async';
import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'app_logger.dart';

enum AppRequirementType {
  internet,
  locationService,
  locationPermission,
  cameraPermission,
}

class AppRequirementStatus {
  final AppRequirementType type;
  final String title;
  final String message;
  final bool resolved;
  final bool blocked;

  const AppRequirementStatus({
    required this.type,
    required this.title,
    required this.message,
    required this.resolved,
    this.blocked = false,
  });
}

class AppRequirementsResult {
  final List<AppRequirementStatus> statuses;

  const AppRequirementsResult(this.statuses);

  bool get ready => statuses.every((item) => item.resolved);

  List<AppRequirementStatus> get pending =>
      statuses.where((item) => !item.resolved).toList();

  bool get hasBlockedPending => pending.any(
    (item) => item.blocked || item.type == AppRequirementType.locationService,
  );
}

class AppRequirementsService {
  Future<AppRequirementsResult> check({bool requestPermissions = false}) async {
    final statuses = <AppRequirementStatus>[];

    statuses.add(
      AppRequirementStatus(
        type: AppRequirementType.internet,
        title: 'Internet',
        message: 'Conectate a internet para iniciar y sincronizar marcaciones.',
        resolved: await _hasInternet(),
      ),
    );

    final locationServiceEnabled = await Geolocator.isLocationServiceEnabled();
    statuses.add(
      AppRequirementStatus(
        type: AppRequirementType.locationService,
        title: 'GPS activo',
        message: 'Activa la ubicacion del dispositivo para validar cada QR.',
        resolved: locationServiceEnabled,
        blocked: !locationServiceEnabled,
      ),
    );

    var locationPermission = await Geolocator.checkPermission();
    if (requestPermissions && locationPermission == LocationPermission.denied) {
      locationPermission = await Geolocator.requestPermission();
    }

    statuses.add(
      AppRequirementStatus(
        type: AppRequirementType.locationPermission,
        title: 'Permiso de ubicacion',
        message: locationPermission == LocationPermission.deniedForever
            ? 'Habilita el permiso de ubicacion desde ajustes.'
            : 'Acepta el permiso de ubicacion para registrar tu posicion.',
        resolved:
            locationPermission == LocationPermission.always ||
            locationPermission == LocationPermission.whileInUse,
        blocked: locationPermission == LocationPermission.deniedForever,
      ),
    );

    var cameraPermission = await ph.Permission.camera.status;
    if (requestPermissions && cameraPermission.isDenied) {
      cameraPermission = await ph.Permission.camera.request();
    }

    statuses.add(
      AppRequirementStatus(
        type: AppRequirementType.cameraPermission,
        title: 'Permiso de camara',
        message:
            cameraPermission.isPermanentlyDenied ||
                cameraPermission.isRestricted
            ? 'Habilita la camara desde ajustes para escanear el QR.'
            : 'Acepta el permiso de camara para escanear el QR de asistencia.',
        resolved: cameraPermission.isGranted || cameraPermission.isLimited,
        blocked:
            cameraPermission.isPermanentlyDenied ||
            cameraPermission.isRestricted,
      ),
    );

    final result = AppRequirementsResult(statuses);
    AppLogger.info('AppRequirements', 'Revision de requisitos', {
      'ready': result.ready,
      'pending': result.pending.map((item) => item.title).join(','),
    });
    return result;
  }

  Future<void> openRelevantSettings(AppRequirementsResult? result) async {
    final pending = result?.pending ?? const <AppRequirementStatus>[];
    if (pending.any(
      (item) => item.type == AppRequirementType.locationService,
    )) {
      await Geolocator.openLocationSettings();
      return;
    }

    if (pending.any((item) => item.blocked)) {
      await ph.openAppSettings();
    }
  }

  Future<bool> _hasInternet() async {
    try {
      final lookup = await InternetAddress.lookup(
        'supabase.co',
      ).timeout(const Duration(seconds: 4));
      return lookup.any((address) => address.rawAddress.isNotEmpty);
    } on SocketException catch (e, st) {
      AppLogger.warning('AppRequirements', 'Sin internet', {
        'error': e.message,
      });
      AppLogger.error('AppRequirements', 'Detalle internet', e, st);
      return false;
    } on TimeoutException catch (e, st) {
      AppLogger.warning('AppRequirements', 'Timeout verificando internet');
      AppLogger.error('AppRequirements', 'Detalle timeout internet', e, st);
      return false;
    }
  }
}
