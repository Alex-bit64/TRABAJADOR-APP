import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trabajador_app/screens/app_update_gate.dart';
import 'package:trabajador_app/services/app_update_download_service.dart';
import 'package:trabajador_app/services/app_version_service.dart';

class _FakeDownloader extends AppUpdateDownloadService {
  bool fail = false;
  int downloads = 0;
  int installs = 0;
  Completer<File>? pending;
  UpdateInstallStatus status = UpdateInstallStatus.permissionRequired;
  @override
  Future<File> download(
    AppReleaseInfo release, {
    required void Function(UpdateDownloadProgress) onProgress,
  }) async {
    downloads++;
    if (fail) {
      throw const UpdateDownloadException('La descarga dejó de responder.');
    }
    if (pending != null) return pending!.future;
    return File('update.apk');
  }

  @override
  Future<UpdateInstallStatus> install(File apk, int expectedBuild) async {
    installs++;
    return status;
  }

  @override
  void cancel() {
    if (pending != null && !pending!.isCompleted) {
      pending!.completeError(UpdateDownloadCancelled());
    }
  }
}

void main() {
  final release = AppReleaseInfo(
    version: '1.2.3',
    buildNumber: 7,
    downloadUrl: Uri.parse('https://example.com/update.apk'),
    message: 'Actualiza',
    mandatory: true,
    sha256: '0' * 64,
  );

  testWidgets('volver de biometría no reinicia ni desmonta el login', (
    tester,
  ) async {
    var consultas = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppUpdateGate(
          verificarVersion: () async {
            consultas++;
            return null;
          },
          child: const Text('Login'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(consultas, 1);
    expect(find.text('Login'), findsOneWidget);
  });

  testWidgets('Cancelar libera una descarga detenida sin abrir el instalador', (
    tester,
  ) async {
    final downloader = _FakeDownloader()..pending = Completer<File>();
    await tester.pumpWidget(
      MaterialApp(
        home: AppUpdateGate(
          verificarVersion: () async => release,
          esAndroid: true,
          downloadService: downloader,
          child: const Text('Aplicación'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Actualizar ahora'));
    await tester.pump();
    expect(find.text('Conectando con el servidor…'), findsOneWidget);
    await tester.tap(find.text('Cancelar descarga'));
    await tester.pumpAndSettle();
    expect(find.text('Descarga cancelada. Puedes reintentar.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(downloader.installs, 0);
    expect(find.text('Actualizar ahora'), findsOneWidget);
  });

  testWidgets('no queda congelado si falla la comprobación inicial', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppUpdateGate(
          verificarVersion: () => Completer<AppReleaseInfo?>().future,
          checkingTimeout: const Duration(milliseconds: 100),
          child: const Text('Aplicación'),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Aplicación'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('volver de permisos no descarga de nuevo ni deja un spinner', (
    tester,
  ) async {
    final downloader = _FakeDownloader();
    await tester.pumpWidget(
      MaterialApp(
        home: AppUpdateGate(
          verificarVersion: () async => release,
          esAndroid: true,
          downloadService: downloader,
          child: const Text('Aplicación'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Actualizar ahora'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Permitir desde esta fuente'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    downloader.status = UpdateInstallStatus.installerOpened;
    await tester.tap(find.text('Instalar actualización'));
    await tester.pumpAndSettle();
    expect(downloader.downloads, 1);
    expect(downloader.installs, 2);
    expect(find.textContaining('Confirma la actualización'), findsOneWidget);
  });

  testWidgets('un error de descarga vuelve a habilitar Actualizar', (
    tester,
  ) async {
    final downloader = _FakeDownloader()..fail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: AppUpdateGate(
          verificarVersion: () async => release,
          esAndroid: true,
          downloadService: downloader,
          child: const Text('Aplicación'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Actualizar ahora'));
    await tester.pumpAndSettle();
    expect(find.text('La descarga dejó de responder.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    downloader.fail = false;
    await tester.tap(find.text('Actualizar ahora'));
    await tester.pumpAndSettle();
    expect(downloader.downloads, 2);
    expect(downloader.installs, 1);
  });
}
