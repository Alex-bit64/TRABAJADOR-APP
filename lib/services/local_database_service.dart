import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'app_logger.dart';

class MarcacionPendiente {
  final String id;
  final String dni;
  final String fecha;
  final String tipoMarcacion;
  final DateTime marcadoEn;
  final Map<String, dynamic> usuario;
  final Map<String, dynamic> qr;
  final Map<String, double> ubicacion;
  final Map<String, dynamic>? horarioManual;
  final Map<String, dynamic>? horarioDia;
  final int intentos;
  final String? ultimoError;

  const MarcacionPendiente({
    required this.id,
    required this.dni,
    required this.fecha,
    required this.tipoMarcacion,
    required this.marcadoEn,
    required this.usuario,
    required this.qr,
    required this.ubicacion,
    this.horarioManual,
    this.horarioDia,
    this.intentos = 0,
    this.ultimoError,
  });

  factory MarcacionPendiente.fromDatabase(Map<String, Object?> row) {
    Map<String, dynamic>? decodeOptional(Object? raw) {
      if (raw == null || raw.toString().trim().isEmpty) {
        return null;
      }
      return Map<String, dynamic>.from(jsonDecode(raw.toString()) as Map);
    }

    final ubicacionRaw = Map<String, dynamic>.from(
      jsonDecode(row['ubicacion_json'].toString()) as Map,
    );
    return MarcacionPendiente(
      id: row['id'].toString(),
      dni: row['dni'].toString(),
      fecha: row['fecha'].toString(),
      tipoMarcacion: row['tipo_marcacion'].toString(),
      marcadoEn: DateTime.parse(row['marcado_en'].toString()),
      usuario: Map<String, dynamic>.from(
        jsonDecode(row['usuario_json'].toString()) as Map,
      ),
      qr: Map<String, dynamic>.from(
        jsonDecode(row['qr_json'].toString()) as Map,
      ),
      ubicacion: ubicacionRaw.map(
        (key, value) => MapEntry(key, (value as num).toDouble()),
      ),
      horarioManual: decodeOptional(row['horario_manual_json']),
      horarioDia: decodeOptional(row['horario_dia_json']),
      intentos: (row['intentos'] as num?)?.toInt() ?? 0,
      ultimoError: row['ultimo_error']?.toString(),
    );
  }

  Map<String, Object?> toDatabase() {
    return {
      'id': id,
      'dni': dni,
      'fecha': fecha,
      'tipo_marcacion': tipoMarcacion,
      'marcado_en': marcadoEn.toIso8601String(),
      'usuario_json': jsonEncode(usuario),
      'qr_json': jsonEncode(qr),
      'ubicacion_json': jsonEncode(ubicacion),
      'horario_manual_json': horarioManual == null
          ? null
          : jsonEncode(horarioManual),
      'horario_dia_json': horarioDia == null ? null : jsonEncode(horarioDia),
      'intentos': intentos,
      'ultimo_error': ultimoError,
      'creado_en': DateTime.now().toUtc().toIso8601String(),
    };
  }
}

class LocalDatabaseService {
  LocalDatabaseService._();

  static final LocalDatabaseService instance = LocalDatabaseService._();
  static const _databaseName = 'trabajador_offline.db';
  static const _databaseVersion = 1;
  Database? _database;

  Future<Database> get _db async {
    final current = _database;
    if (current != null) {
      return current;
    }

    final databasesPath = await getDatabasesPath();
    final database = await openDatabase(
      path.join(databasesPath, _databaseName),
      version: _databaseVersion,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE asistencia_cache (
            dni TEXT NOT NULL,
            fecha TEXT NOT NULL,
            data_json TEXT NOT NULL,
            actualizado_en TEXT NOT NULL,
            PRIMARY KEY (dni, fecha)
          )
        ''');
        await db.execute('''
          CREATE TABLE qr_cache (
            token TEXT PRIMARY KEY,
            data_json TEXT NOT NULL,
            actualizado_en TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE marcacion_pendiente (
            id TEXT PRIMARY KEY,
            dni TEXT NOT NULL,
            fecha TEXT NOT NULL,
            tipo_marcacion TEXT NOT NULL,
            marcado_en TEXT NOT NULL,
            usuario_json TEXT NOT NULL,
            qr_json TEXT NOT NULL,
            ubicacion_json TEXT NOT NULL,
            horario_manual_json TEXT,
            horario_dia_json TEXT,
            intentos INTEGER NOT NULL DEFAULT 0,
            ultimo_error TEXT,
            creado_en TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_marcacion_pendiente_dni_fecha
          ON marcacion_pendiente (dni, fecha, marcado_en)
        ''');
      },
    );
    _database = database;
    return database;
  }

  Future<void> inicializar() async {
    await _db;
  }

  Future<void> guardarAsistencia(Map<String, dynamic> asistencia) async {
    final dni = _dniDe(asistencia);
    final fecha = _fechaDe(asistencia);
    if (dni.isEmpty || fecha.isEmpty) {
      return;
    }

    final db = await _db;
    await db.insert('asistencia_cache', {
      'dni': dni,
      'fecha': fecha,
      'data_json': jsonEncode(asistencia),
      'actualizado_en': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> guardarHistorial(
    String dni,
    Iterable<Map<String, dynamic>> registros,
  ) async {
    final dniLimpio = dni.trim();
    if (dniLimpio.isEmpty) {
      return;
    }

    final db = await _db;
    final batch = db.batch();
    final ahora = DateTime.now().toUtc().toIso8601String();
    for (final registro in registros) {
      final fecha = _fechaDe(registro);
      if (fecha.isEmpty) {
        continue;
      }
      final data = <String, dynamic>{...registro};
      data.putIfAbsent('dni_trabajador', () => dniLimpio);
      batch.insert('asistencia_cache', {
        'dni': dniLimpio,
        'fecha': fecha,
        'data_json': jsonEncode(data),
        'actualizado_en': ahora,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<Map<String, dynamic>?> obtenerAsistencia(
    String dni,
    DateTime fecha,
  ) async {
    final db = await _db;
    final rows = await db.query(
      'asistencia_cache',
      columns: ['data_json'],
      where: 'dni = ? AND fecha = ?',
      whereArgs: [dni.trim(), _dateKey(fecha)],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Map<String, dynamic>.from(
      jsonDecode(rows.first['data_json'].toString()) as Map,
    );
  }

  Future<List<Map<String, dynamic>>> obtenerHistorialMes(
    String dni,
    DateTime mes,
  ) async {
    final inicio = _dateKey(DateTime(mes.year, mes.month));
    final fin = _dateKey(DateTime(mes.year, mes.month + 1));
    final db = await _db;
    final rows = await db.query(
      'asistencia_cache',
      columns: ['data_json'],
      where: 'dni = ? AND fecha >= ? AND fecha < ?',
      whereArgs: [dni.trim(), inicio, fin],
      orderBy: 'fecha DESC',
    );
    return rows
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['data_json'].toString()) as Map,
          ),
        )
        .toList();
  }

  Future<void> guardarQr(Map<String, dynamic> qr) async {
    final token = qr['token']?.toString().trim() ?? '';
    if (token.isEmpty || token.startsWith('app-qr-dinamico://')) {
      return;
    }
    final db = await _db;
    await db.insert('qr_cache', {
      'token': token,
      'data_json': jsonEncode(qr),
      'actualizado_en': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> obtenerQr(String token) async {
    final db = await _db;
    final rows = await db.query(
      'qr_cache',
      columns: ['data_json'],
      where: 'token = ?',
      whereArgs: [token.trim()],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Map<String, dynamic>.from(
      jsonDecode(rows.first['data_json'].toString()) as Map,
    );
  }

  Future<void> encolarMarcacion(MarcacionPendiente pendiente) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert(
        'marcacion_pendiente',
        pendiente.toDatabase(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      final cached = await txn.query(
        'asistencia_cache',
        columns: ['data_json'],
        where: 'dni = ? AND fecha = ?',
        whereArgs: [pendiente.dni, pendiente.fecha],
        limit: 1,
      );
      final asistencia = cached.isEmpty
          ? <String, dynamic>{
              'dni_trabajador': pendiente.dni,
              'fecha': pendiente.fecha,
              'horario_entrada': null,
              'horario_inicio_receso': null,
              'horario_fin_receso': null,
              'horario_salida': null,
              'justificado': pendiente.horarioManual == null,
            }
          : Map<String, dynamic>.from(
              jsonDecode(cached.first['data_json'].toString()) as Map,
            );
      asistencia[pendiente.tipoMarcacion] = pendiente.marcadoEn
          .toIso8601String();
      await txn.insert('asistencia_cache', {
        'dni': pendiente.dni,
        'fecha': pendiente.fecha,
        'data_json': jsonEncode(asistencia),
        'actualizado_en': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });

    AppLogger.info('LocalDatabase', 'Marcacion guardada para sincronizar', {
      'dni': AppLogger.shortId(pendiente.dni),
      'fecha': pendiente.fecha,
      'tipo': pendiente.tipoMarcacion,
    });
  }

  Future<List<MarcacionPendiente>> obtenerMarcacionesPendientes({
    String? dni,
  }) async {
    final db = await _db;
    final rows = await db.query(
      'marcacion_pendiente',
      where: dni == null ? null : 'dni = ?',
      whereArgs: dni == null ? null : [dni.trim()],
      orderBy: 'marcado_en ASC',
    );
    return rows.map(MarcacionPendiente.fromDatabase).toList();
  }

  Future<Set<String>> obtenerTiposPendientes(String dni, DateTime fecha) async {
    final db = await _db;
    final rows = await db.query(
      'marcacion_pendiente',
      columns: ['tipo_marcacion'],
      where: 'dni = ? AND fecha = ?',
      whereArgs: [dni.trim(), _dateKey(fecha)],
    );
    return rows.map((row) => row['tipo_marcacion'].toString()).toSet();
  }

  Future<int> contarPendientes({String? dni}) async {
    final db = await _db;
    final rows = await db.rawQuery(
      dni == null
          ? 'SELECT COUNT(*) AS total FROM marcacion_pendiente'
          : 'SELECT COUNT(*) AS total FROM marcacion_pendiente WHERE dni = ?',
      dni == null ? null : [dni.trim()],
    );
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<void> registrarIntento(String id, Object error) async {
    final db = await _db;
    await db.rawUpdate(
      '''
        UPDATE marcacion_pendiente
        SET intentos = intentos + 1, ultimo_error = ?
        WHERE id = ?
      ''',
      [error.toString(), id],
    );
  }

  Future<void> eliminarPendiente(String id) async {
    final db = await _db;
    await db.delete('marcacion_pendiente', where: 'id = ?', whereArgs: [id]);
  }

  String _dniDe(Map<String, dynamic> asistencia) {
    return asistencia['dni_trabajador']?.toString().trim() ??
        asistencia['dni']?.toString().trim() ??
        '';
  }

  String _fechaDe(Map<String, dynamic> asistencia) {
    final raw = asistencia['fecha'] ?? asistencia['fecha_asistencia'];
    if (raw is DateTime) {
      return _dateKey(raw);
    }
    final text = raw?.toString().trim() ?? '';
    if (text.length >= 10) {
      return text.substring(0, 10);
    }
    return '';
  }

  String _dateKey(DateTime value) {
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
