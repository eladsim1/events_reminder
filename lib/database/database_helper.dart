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
  /// 3 -> 4: שנת הפטירה העברית (death_hebrew_year), אופציונלית.
  /// 4 -> 5: postponed_reminder_at – דחייה חד-פעמית שהמשתמש ביקש מההתראה.
  /// 5 -> 6: טבלת app_state – נעילת סנכרון ומצב העבודה שרצה ברקע.
  static const _databaseVersion = 6;

  static const table = 'memorials';

  /// מפתח/ערך לענייני תשתית. קיימת בגלל שני צרכים שאין להם מקום אחר:
  /// נעילה שמשותפת ל-isolates, ומצב הריצה של העבודה ברקע.
  static const stateTable = 'app_state';

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
    // בסדר עולה. הבלוקים כאן עצמאיים זה מזה, אבל סדר יורד מזמין מיגרציה
    // עתידית שתסתמך על קודמתה ותרוץ לפניה.
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
    if (oldVersion < 4) {
      // ללא DEFAULT: היעדר ידיעה הוא מצב לגיטימי, ו-null מבטא אותו.
      await db.execute(
        'ALTER TABLE $table ADD COLUMN death_hebrew_year INTEGER',
      );
    }
    if (oldVersion < 5) {
      await db.execute(
        'ALTER TABLE $table ADD COLUMN postponed_reminder_at TEXT',
      );
    }
    if (oldVersion < 6) {
      await _createStateTable(db);
    }
  }

  /// תופס את נעילת הסנכרון, או מדווח שהיא תפוסה.
  ///
  /// **נעילה בתוך המסד ולא בזיכרון, כי שני isolates מעורבים**: המסך רץ
  /// באחד והעבודה השבועית באחר, לכל אחד עותק משלו של כל משתנה סטטי. בלי
  /// הנעילה שניהם קוראים את אותו lastNotifiedAt, שניהם מסיקים שהתזכורת
  /// הוחמצה ושניהם מציגים אותה – וגם עלולים לשזור ביטול ותזמון זה בזה,
  /// כי rescheduleAll מבטל לפני שהוא מתזמן.
  ///
  /// [staleAfter] הוא שסתום הביטחון: תהליך שנהרג באמצע לא משחרר דבר, ובלי
  /// תפוגה הסנכרון היה מושבת לנצח.
  Future<bool> claimSyncLock(String owner, Duration staleAfter) async {
    final db = await database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(stateTable,
          where: 'key = ?', whereArgs: [_syncLockKey]);
      final now = DateTime.now();

      if (rows.isNotEmpty) {
        final raw = rows.first['value'] as String?;
        final held = DateTime.tryParse((raw ?? '').split('|').first);
        if (held != null && now.difference(held) < staleAfter) return false;
      }

      await txn.insert(
        stateTable,
        {'key': _syncLockKey, 'value': '${now.toIso8601String()}|$owner'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  Future<void> releaseSyncLock() async {
    final db = await database;
    await db.delete(stateTable, where: 'key = ?', whereArgs: [_syncLockKey]);
  }

  static const _syncLockKey = 'sync_lock';
  static const _backgroundRunKey = 'background_last_run';
  static const _backgroundErrorKey = 'background_last_error';

  /// רושם את תוצאת הריצה של העבודה ברקע.
  ///
  /// היא רצה ב-isolate אחר, ולכן שדה בזיכרון לעולם לא יגיע למסך: כשל שבועי
  /// היה נשאר בלתי נראה לגמרי.
  Future<void> recordBackgroundRun(DateTime at, String? error) async {
    final db = await database;
    await db.insert(
      stateTable,
      {'key': _backgroundRunKey, 'value': at.toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      stateTable,
      {'key': _backgroundErrorKey, 'value': error ?? ''},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<({DateTime? lastRun, String? lastError})> backgroundStatus() async {
    final db = await database;
    final rows = await db.query(stateTable,
        where: 'key IN (?, ?)',
        whereArgs: [_backgroundRunKey, _backgroundErrorKey]);

    DateTime? lastRun;
    String? lastError;
    for (final r in rows) {
      final value = r['value'] as String? ?? '';
      if (r['key'] == _backgroundRunKey) {
        lastRun = DateTime.tryParse(value);
      } else if (value.isNotEmpty) {
        lastError = value;
      }
    }
    return (lastRun: lastRun, lastError: lastError);
  }

  Future<void> _createStateTable(Database db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS $stateTable ('
      'key TEXT PRIMARY KEY, value TEXT)',
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createStateTable(db);
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
        postponed_reminder_at TEXT,
        cemetery TEXT,
        plot TEXT,
        photo_path TEXT,
        reminder_mode TEXT NOT NULL DEFAULT '${ReminderMode.weekdayOfPreviousWeek.dbValue}',
        death_hebrew_year INTEGER,
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
