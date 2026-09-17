import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trabajador_app/services/app_update_download_service.dart';
import 'package:trabajador_app/services/app_version_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  late Future<void> Function(HttpRequest) handler;
  final bytes = List<int>.generate(4096, (index) => index % 256);
  var requests = 0;

  AppReleaseInfo release({String? digest}) => AppReleaseInfo(
    version: '1.2.3',
    buildNumber: 7,
    downloadUrl: Uri.parse('http://127.0.0.1:${server.port}/update.apk'),
    message: 'Actualiza',
    mandatory: true,
    sha256: digest ?? sha256.convert(bytes).toString(),
  );

  AppUpdateDownloadService downloader({
    Duration inactivity = const Duration(seconds: 3),
    Duration maximum = const Duration(seconds: 10),
    int maximumBytes = 150 * 1024 * 1024,
  }) => AppUpdateDownloadService(
    directoryProvider: () async => directory,
    inactivityTimeout: inactivity,
    maximumDuration: maximum,
    maximumBytes: maximumBytes,
  );

  setUp(() async {
    // Flutter bloquea la red por defecto; aquí probamos HTTP local real.
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp(
      'trabajador-update-test-',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = 0;
    handler = (request) async {
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    };
    server.listen((request) {
      requests++;
      unawaited(handler(request).catchError((Object _) {}));
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('trabajador_app/platform'),
          null,
        );
  });

  test(
    'descarga, verifica y finaliza sin conservar archivos parciales',
    () async {
      final phases = <UpdateDownloadPhase>[];
      final file = await downloader().download(
        release(),
        onProgress: (progress) => phases.add(progress.phase),
      );
      expect(await file.readAsBytes(), bytes);
      expect(phases, contains(UpdateDownloadPhase.verifying));
      expect(await File('${file.path}.part').exists(), isFalse);
    },
  );

  test('reutiliza un APK verificado al volver desde los permisos', () async {
    final service = downloader();
    final first = await service.download(release(), onProgress: (_) {});
    final second = await service.download(release(), onProgress: (_) {});
    expect(second.path, first.path);
    expect(requests, 1);
  });

  test(
    'una descarga sin Content-Length también termina y se verifica',
    () async {
      handler = (request) async {
        request.response.bufferOutput = false;
        request.response.add(bytes);
        await request.response.flush();
        await request.response.close();
      };
      final file = await downloader().download(release(), onProgress: (_) {});
      expect(await file.readAsBytes(), bytes);
    },
  );

  test(
    'limpia solo APKs temporales antiguos sin borrar otros archivos',
    () async {
      final oldApk = File('${directory.path}/marcador-6.apk');
      final unrelated = File('${directory.path}/otro_archivo.txt');
      await oldApk.writeAsBytes([1, 2, 3]);
      await unrelated.writeAsString('conservar');
      await downloader().download(release(), onProgress: (_) {});
      expect(await oldApk.exists(), isFalse);
      expect(await unrelated.readAsString(), 'conservar');
    },
  );

  test(
    'un APK en cache corrupto se reemplaza por la descarga correcta',
    () async {
      final bad = File('${directory.path}/marcador-7.apk');
      await bad.writeAsBytes([1, 2, 3]);
      final good = await downloader().download(release(), onProgress: (_) {});
      expect(await good.readAsBytes(), bytes);
      expect(requests, 1);
    },
  );

  test('rechaza archivos alterados y permite descargar otra vez', () async {
    final service = downloader();
    await expectLater(
      service.download(release(digest: '0' * 64), onProgress: (_) {}),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(await directory.list().toList(), isEmpty);
    expect(
      await (await service.download(
        release(),
        onProgress: (_) {},
      )).readAsBytes(),
      bytes,
    );
  });

  test('rechaza una respuesta HTTP de error y borra el parcial', () async {
    handler = (request) async {
      request.response.statusCode = 404;
      await request.response.close();
    };
    await expectLater(
      downloader().download(release(), onProgress: (_) {}),
      throwsA(
        isA<UpdateDownloadException>().having(
          (error) => error.message,
          'mensaje',
          contains('404'),
        ),
      ),
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('una descarga detenida no queda esperando indefinidamente', () async {
    handler = (request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = bytes.length * 2;
      request.response.add(bytes);
      await request.response.flush();
      // Simula un servidor que nunca entrega el resto ni cierra la respuesta.
    };
    await expectLater(
      downloader(
        inactivity: const Duration(milliseconds: 250),
      ).download(release(), onProgress: (_) {}),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('cancelar una transferencia desbloquea el siguiente intento', () async {
    final connected = Completer<void>();
    handler = (request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = bytes.length * 2;
      request.response.add(bytes);
      await request.response.flush();
      connected.complete();
    };
    final service = downloader();
    final future = service.download(release(), onProgress: (_) {});
    final cancelled = expectLater(
      future,
      throwsA(isA<UpdateDownloadCancelled>()),
    );
    await connected.future;
    service.cancel();
    await cancelled;
    handler = (request) async {
      request.response.add(bytes);
      await request.response.close();
    };
    final file = await service.download(release(), onProgress: (_) {});
    expect(await file.readAsBytes(), bytes);
  });

  test(
    'rechaza descargas sin hash antes de iniciar la transferencia',
    () async {
      await expectLater(
        downloader().download(release(digest: ''), onProgress: (_) {}),
        throwsA(isA<UpdateDownloadException>()),
      );
      expect(requests, 0);
    },
  );

  test('controla el tamaño antes de llenar el almacenamiento', () async {
    await expectLater(
      downloader(maximumBytes: 1024).download(release(), onProgress: (_) {}),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'el límite total termina incluso una conexión que sigue enviando datos',
    () async {
      handler = (request) async {
        request.response.bufferOutput = false;
        for (var i = 0; i < 50; i++) {
          request.response.add([i]);
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await request.response.close();
      };
      await expectLater(
        downloader(
          maximum: const Duration(milliseconds: 250),
        ).download(release(), onProgress: (_) {}),
        throwsA(isA<UpdateDownloadException>()),
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('no permite dos descargas simultáneas', () async {
    final connected = Completer<void>();
    handler = (request) async {
      request.response.bufferOutput = false;
      request.response.add([1]);
      await request.response.flush();
      connected.complete();
    };
    final service = downloader();
    final first = service.download(release(), onProgress: (_) {});
    final cancelled = expectLater(
      first,
      throwsA(isA<UpdateDownloadCancelled>()),
    );
    await connected.future;
    await expectLater(
      service.download(release(), onProgress: (_) {}),
      throwsA(isA<UpdateDownloadException>()),
    );
    service.cancel();
    await cancelled;
  });

  test('distingue permiso pendiente de instalador abierto', () async {
    var status = 'permission_required';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('trabajador_app/platform'),
          (call) async {
            expect(call.method, 'installUpdate');
            expect(call.arguments['expectedBuild'], 7);
            return status;
          },
        );
    final service = downloader();
    expect(
      await service.install(File('update.apk'), 7),
      UpdateInstallStatus.permissionRequired,
    );
    status = 'installer_opened';
    expect(
      await service.install(File('update.apk'), 7),
      UpdateInstallStatus.installerOpened,
    );
  });
}
