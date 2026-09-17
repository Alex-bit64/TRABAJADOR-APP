import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trabajador_app/services/horario_dia_service.dart';

void main() {
  const asignado = {'horario_entrada': '08:00:00'};
  HorarioDiaService loader({
    required Future<Horario?> Function() consultar,
    Horario? cache,
    Future<void> Function(Horario)? guardar,
    Future<void> Function()? limpiar,
    Duration timeout = const Duration(seconds: 1),
  }) => HorarioDiaService(
    consultar: consultar,
    leerCache: () async => cache,
    guardarCache: guardar ?? (_) async {},
    limpiarCache: limpiar ?? () async {},
    esperaReintento: Duration.zero,
    timeout: timeout,
  );

  test('espera la respuesta lenta sin declarar ausencia de horario', () async {
    final respuesta = Completer<Horario?>();
    var termino = false;
    final futuro = loader(consultar: () => respuesta.future).cargar()
      ..then((_) => termino = true);
    await Future<void>.delayed(Duration.zero);
    expect(termino, isFalse);
    respuesta.complete(asignado);
    final resultado = await futuro;
    expect(resultado.horario, asignado);
    expect(resultado.confirmado, isTrue);
    expect(resultado.sinHorarioConfirmado, isFalse);
  });

  test('reintenta un error transitorio y obtiene el horario', () async {
    var consultas = 0;
    final resultado = await loader(
      consultar: () async {
        if (++consultas == 1) throw StateError('sin conexión');
        return asignado;
      },
    ).cargar();
    expect(consultas, 2);
    expect(resultado.horario, asignado);
    expect(resultado.confirmado, isTrue);
  });

  test('los errores de conexión no significan sin horario', () async {
    final resultado = await loader(
      consultar: () async {
        throw StateError('sin conexión');
      },
    ).cargar();
    expect(resultado.confirmado, isFalse);
    expect(resultado.sinHorarioConfirmado, isFalse);
  });

  test('un timeout tampoco significa sin horario', () async {
    final resultado = await loader(
      consultar: () => Completer<Horario?>().future,
      timeout: const Duration(milliseconds: 1),
    ).cargar();
    expect(resultado.confirmado, isFalse);
    expect(resultado.sinHorarioConfirmado, isFalse);
  });

  test(
    'muestra cache antes de consultar y lo conserva si falla la red',
    () async {
      Horario? visible;
      final resultado = await loader(
        cache: asignado,
        consultar: () async {
          expect(visible, asignado);
          throw StateError('sin conexión');
        },
      ).cargar(alLeerCache: (horario) => visible = horario);
      expect(resultado.horario, asignado);
      expect(resultado.desdeCache, isTrue);
      expect(resultado.sinHorarioConfirmado, isFalse);
    },
  );

  test('el horario remoto actualizado sustituye el cache', () async {
    const nuevo = {'horario_entrada': '09:00:00'};
    Horario? guardado;
    final resultado = await loader(
      cache: asignado,
      consultar: () async => nuevo,
      guardar: (horario) async => guardado = horario,
    ).cargar();
    expect(resultado.horario, nuevo);
    expect(guardado, nuevo);
    expect(resultado.desdeCache, isFalse);
  });

  test('ausencia confirmada elimina cache obsoleto', () async {
    var limpio = false;
    final resultado = await loader(
      cache: asignado,
      consultar: () async => null,
      limpiar: () async => limpio = true,
    ).cargar();
    expect(limpio, isTrue);
    expect(resultado.sinHorarioConfirmado, isTrue);
    expect(resultado.horario, isNull);
  });

  test('fallo del almacenamiento no invalida el horario remoto', () async {
    final resultado = await loader(
      consultar: () async => asignado,
      guardar: (_) async => throw StateError('almacenamiento'),
    ).cargar();
    expect(resultado.horario, asignado);
    expect(resultado.confirmado, isTrue);
  });

  test('nombre de día coincide con el formato de la base de datos', () {
    expect(HorarioDiaService.diaSemana(DateTime(2026, 9, 17)), 'jueves');
    expect(HorarioDiaService.diaSemana(DateTime(2026, 9, 20)), 'domingo');
  });
}
