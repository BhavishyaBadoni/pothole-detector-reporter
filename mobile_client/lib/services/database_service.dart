import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;

  DatabaseService._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('alerts.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
CREATE TABLE alerts (
  id INTEGER PRIMARY KEY,
  hazard_id INTEGER NOT NULL,
  last_alerted_at INTEGER NOT NULL
)
''');
  }

  Future<bool> canAlert(int hazardId, bool isRaining) async {
    final db = await instance.database;
    final res = await db.query(
      'alerts',
      where: 'hazard_id = ?',
      whereArgs: [hazardId],
    );

    final now = DateTime.now().millisecondsSinceEpoch;
    
    // 3 mins if raining, 10 mins if dry
    final cooldownMillis = (isRaining ? 3 : 10) * 60 * 1000;

    if (res.isNotEmpty) {
      final lastAlertedAt = res.first['last_alerted_at'] as int;
      if (now - lastAlertedAt < cooldownMillis) {
        return false; // Still in cooldown
      }
    }

    // Record the alert
    if (res.isNotEmpty) {
      await db.update(
        'alerts',
        {'last_alerted_at': now},
        where: 'hazard_id = ?',
        whereArgs: [hazardId],
      );
    } else {
      await db.insert('alerts', {
        'hazard_id': hazardId,
        'last_alerted_at': now,
      });
    }

    return true;
  }
}
