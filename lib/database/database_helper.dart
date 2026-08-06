import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/hebrew_date.dart';
import '../models/memorial.dart';

/// עוטף גישה גולמית ל-SQLite.
///
/// **חשוב:** אף שכבה מלבד ה-Repository אינה ניגשת ישירות למחלקה זו.
/// כאן מוגדרת סכימת הטבלה [memorials] והמרות מ/אל [Memorial].
class DatabaseHelper {
  static const _databaseName = 'azkarot.db';

  /// 1 -> 2: נוסף last_notified_at, כדי לדעת אילו תזכורות כבר טופלו ולא
  /// להציג שוב את אותה שנה בכל פתיחה.
  /// 2 -> 3: מיקום קבר (cemetery, plot), תמונה (photo_path), ומועד התזכורת
  /// הניתן להגדרה (reminder_mode, reminder_value).
  static const _databaseVersion = 3;

  static const table = 'memorials';

  DatabaseHelper._privateConstructor();
  static final DatabaseHelper instance =
      DatabaseHelper._privateConstructor();

  static Database? _database;

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _databaseName);
    return openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// שדרוג סכימה. חייב להיות אינקרמנטלי – התקנות קיימות מכילות נתונים.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE $table ADD COLUMN last_notified_at TEXT',
      );
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE $table ADD COLUMN cemetery TEXT');
      await db.execute('ALTER TABLE $table ADD COLUMN plot TEXT');
      await db.execute('ALTER TABLE $table ADD COLUMN photo_path TEXT');
      // ברירת המחדל שומרת על ההתנהגות הקיימת: יום שלישי של השבוע שלפני.
      await db.execute(
        "ALTER TABLE $table ADD COLUMN reminder_mode TEXT NOT NULL "
        "DEFAULT '${ReminderMode.weekdayOfPreviousWeek.dbValue}'",
      );
      await db.execute(
        'ALTER TABLE $table ADD COLUMN reminder_value INTEGER NOT NULL '
        'DEFAULT ${Memorial.defaultReminderWeekday}',
      );
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        hebrew_day INTEGER NOT NULL,
        hebrew_month INTEGER NOT NULL,
        adar_type TEXT NOT NULL DEFAULT 'none',
        notification_hour INTEGER NOT NULL,
        notification_minute INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        notes TEXT,
        created_at TEXT NOT NULL,
        last_notified_at TEXT,
        cemetery TEXT,
        plot TEXT,
        photo_path TEXT,
        reminder_mode TEXT NOT NULL DEFAULT '${ReminderMode.weekdayOfPreviousWeek.dbValue}',
        reminder_value INTEGER NOT NULL DEFAULT ${Memorial.defaultReminderWeekday}
      )
    ''');
  }

  // ---- פעולות CRUD גולמיות (נקראות רק מה-Repository) ----

  Future<int> insert(Memorial memorial) async {
    final db = await database;
    final map = memorial.toMap()..remove('id');
    return db.insert(table, map);
  }

  Future<int> update(Memorial memorial) async {
    final db = await database;
    return db.update(
      table,
      memorial.toMap(),
      where: 'id = ?',
      whereArgs: [memorial.id],
    );
  }

  Future<int> delete(int id) async {
    final db = await database;
    return db.delete(table, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Memorial>> getAll() async {
    final db = await database;
    final rows = await db.query(table, orderBy: 'created_at DESC');
    return rows.map((r) => Memorial.fromMap(r)).toList();
  }

  Future<Memorial?> getById(int id) async {
    final db = await database;
    final rows =
        await db.query(table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Memorial.fromMap(rows.first);
  }

  /// מוחק את כל הרשומות ומכניס רשימה חדשה (לשימוש בייבוא).
  Future<void> replaceAll(List<Memorial> memorials) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(table);
      for (final m in memorials) {
        final map = m.toMap()..remove('id');
        await txn.insert(table, map);
      }
    });
  }
}
