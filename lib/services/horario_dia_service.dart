import 'dart:async';

import 'app_logger.dart';

typedef Horario = Map<String, dynamic>;

class HorarioDiaResultado {
  final Horario? horario;
  final bool confirmado;
  final bool desdeCache;

  const HorarioDiaResultado({
    required this.horario,
    required this.confirmado,
    this.desdeCache = false,
  });

  bool get sinHorarioConfirmado => confirmado && horario == null;
}

/// Un fallo de red nunca equivale a un día sin horario asignado.
class HorarioDiaService {
  final Future<Horario?> Function() consultar;
  final Future<Horario?> Function() leerCache;
  final Future<void> Function(Horario) guardarCache;
  final Future<void> Function() limpiarCache;
  final Duration timeout;
  final Duration esperaReintento;

  const HorarioDiaService({
    required this.consultar,
    required this.leerCache,
    required this.guardarCache,
    required this.limpiarCache,
    this.timeout = const Duration(seconds: 8),
    this.esperaReintento = const Duration(seconds: 1),
  });

  Future<HorarioDiaResultado> cargar({
    void Function(Horario)? alLeerCache,
  }) async {
    Horario? cache;
    try {
      cache = await leerCache();
      if (cache != null) {
        alLeerCache?.call(cache);
      }
    } catch (e, st) {
      AppLogger.error('HorarioDia', 'No se pudo leer el cache', e, st);
    }

    for (var intento = 0; intento < 2; intento++) {
      try {
        final remoto = await consultar().timeout(timeout);
        try {
          if (remoto == null) {
            await limpiarCache();
          } else {
            await guardarCache(remoto);
          }
        } catch (e, st) {
          // El almacenamiento local no invalida una respuesta del servidor.
          AppLogger.error(
            'HorarioDia',
            'No se pudo actualizar el cache',
            e,
            st,
          );
        }
        return HorarioDiaResultado(horario: remoto, confirmado: true);
      } catch (e, st) {
        AppLogger.error('HorarioDia', 'Consulta de horario fallida', e, st, {
          'intento': intento + 1,
        });
        if (intento == 0) {
          await Future<void>.delayed(esperaReintento);
        }
      }
    }

    return HorarioDiaResultado(
      horario: cache,
      confirmado: false,
      desdeCache: cache != null,
    );
  }

  static String diaSemana(DateTime fecha) => const [
    'lunes',
    'martes',
    'miercoles',
    'jueves',
    'viernes',
    'sabado',
    'domingo',
  ][fecha.weekday - 1];
}
