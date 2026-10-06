import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../features/habits/habit_schema.dart';

/// One database for app-owned records; never a mirror of Health Connect.
class AppDatabase {
  AppDatabase({DatabaseFactory? factory})
    : _factory = factory ?? databaseFactory;
  final DatabaseFactory _factory;
  Future<Database>? _opening;
  Future<Database> open({String? databasePath}) =>
      _opening ??= _open(databasePath);
  Future<Database> _open(String? databasePath) async {
    try {
      return await _factory.openDatabase(
        databasePath ??
            path.join(await _factory.getDatabasesPath(), 'app_fit.db'),
        options: OpenDatabaseOptions(
          version: 2,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, version) => _migrate(db, 0, version),
          onUpgrade: _migrate,
        ),
      );
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<void> _migrate(Database db, int from, int to) async {
    if (from < 1) {
      await db.execute(
        'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await db.insert('app_metadata', {
        'key': 'created_at',
        'value': DateTime.now().toUtc().toIso8601String(),
      });
    }
    if (from < 2 && to >= 2) {
      await createHabitSchema(db);
    }
  }

  Future<void> close() async {
    final pending = _opening;
    _opening = null;
    if (pending != null) await (await pending).close();
  }
}
