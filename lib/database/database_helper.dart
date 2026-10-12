import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/event.dart';
import '../models/event_date.dart';

/// עוטף גישה גולמית ל-SQLite.
///
/// **חשוב:** אף שכבה מלבד ה-Repository אינה ניגשת ישירות למחלקה זו.
/// כאן מוגדרת סכימת הטבלה [table] וההמרות מ/אל [Event].
class DatabaseHelper {
  static const _databaseName = 'events.db';

  /// גרסה 1: הסכימה נולדה שלמה.
  ///
  /// **לא המשך של סכימת האזכרות.** האפליקציה הזו היא אפליקציה אחרת, עם
  /// מזהה חבילה משלה ועם קובץ מסד משלה, ולכן אין התקנה קיימת לשדרג ממנה –
  /// ושדרוג כזה גם לא היה נכון: יום שנה לפטירה אינו אירוע משמח, והמרה
  /// אוטומטית בין השניים הייתה שינוי משמעות ולא מיגרציה.
  ///
  /// [_onUpgrade] נשאר כאן בשביל מה שיבוא: כל שינוי סכימה עתידי חייב
  /// להיות אינקרמנטלי ובסדר עולה, כי אז כבר יהיו התקנות עם נתונים.
  static const _databaseVersion = 1;

  static const table = 'events';

  /// מפתח/ערך לענייני תשתית. קיימת בגלל שני צרכים שאין להם מקום אחר:
  /// נעילה שמשותפת ל-isolates, ומצב הריצה של העבודה ברקע.
  static const stateTable = 'app_state';

  DatabaseHelper._privateConstructor();
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();

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

  /// שדרוג סכימה. חייב להיות אינקרמנטלי ובסדר עולה – התקנות קיימות מכילות
  /// נתונים, ובלוק שרץ בסדר יורד מזמין מיגרציה עתידית שתסתמך על קודמתה
  /// ותרוץ לפניה.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // אין עדיין גרסאות קודמות.
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
    // exclusive: הטרנזקציה נפתחת ב-BEGIN IMMEDIATE ותופסת את נעילת הכתיבה
    // מיד. בלעדיה שני ה-isolates קוראים תחילה, שניהם רואים "פנוי", ורק אז
    // כותבים – והשני מקבל SQLITE_BUSY אחרי שכבר החליט שהנעילה שלו.
    return db.transaction<bool>(exclusive: true, (txn) async {
      final rows = await txn
          .query(stateTable, where: 'key = ?', whereArgs: [_syncLockKey]);
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

  /// קורא הגדרה מטבלת app_state, או null אם אינה קיימת.
  ///
  /// אותה טבלה שמחזיקה את הנעילה ואת מצב העבודה ברקע – היא נוצרה בדיוק
  /// בשביל ערכים שאין להם מקום בשורת אירוע.
  Future<String?> readSetting(String key) async {
    final db = await database;
    final rows = await db
        .query(stateTable, where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> writeSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      stateTable,
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
        kind TEXT NOT NULL DEFAULT '${EventKind.other.dbValue}',
        calendar TEXT NOT NULL DEFAULT '${CalendarSystem.hebrew.dbValue}',
        day INTEGER NOT NULL,
        month INTEGER NOT NULL,
        adar_type TEXT NOT NULL DEFAULT 'none',
        start_year INTEGER,
        notification_hour INTEGER NOT NULL,
        notification_minute INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        notes TEXT,
        created_at TEXT NOT NULL,
        last_notified_at TEXT,
        postponed_reminder_at TEXT,
        reminder_mode TEXT NOT NULL DEFAULT '${ReminderMode.weekdayOfPreviousWeek.dbValue}',
        reminder_value INTEGER NOT NULL DEFAULT ${Event.defaultReminderWeekday}
      )
    ''');
  }

  // ---- פעולות CRUD גולמיות (נקראות רק מה-Repository) ----

  Future<int> insert(Event event) async {
    final db = await database;
    final map = event.toMap()..remove('id');
    return db.insert(table, map);
  }

  Future<int> update(Event event) async {
    final db = await database;
    return db.update(
      table,
      event.toMap(),
      where: 'id = ?',
      whereArgs: [event.id],
    );
  }

  Future<int> delete(int id) async {
    final db = await database;
    return db.delete(table, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Event>> getAll() async {
    final db = await database;
    final rows = await db.query(table, orderBy: 'created_at DESC');
    return rows.map((r) => Event.fromMap(r)).toList();
  }

  Future<Event?> getById(int id) async {
    final db = await database;
    final rows =
        await db.query(table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Event.fromMap(rows.first);
  }

  /// מוסיף רק אירועים שאינם קיימים. מחזיר כמה נוספו וכמה דולגו.
  ///
  /// ההשוואה על [Event.identityKey] ולא על המזהה: המזהה של קובץ גיבוי
  /// שייך למכשיר אחר ואינו אומר דבר כאן.
  Future<({int added, int skipped})> mergeAll(List<Event> incoming) async {
    final db = await database;
    final existing = {for (final e in await getAll()) e.identityKey};

    var added = 0;
    var skipped = 0;
    await db.transaction((txn) async {
      for (final e in incoming) {
        // גם מול מה שנוסף באותה ריצה: קובץ יכול להכיל כפילות בתוכו.
        if (!existing.add(e.identityKey)) {
          skipped++;
          continue;
        }
        await txn.insert(table, e.toMap()..remove('id'));
        added++;
      }
    });
    return (added: added, skipped: skipped);
  }

  /// מוחק את כל הרשומות ומכניס רשימה חדשה (לשימוש בייבוא).
  Future<void> replaceAll(List<Event> events) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(table);
      for (final e in events) {
        final map = e.toMap()..remove('id');
        await txn.insert(table, map);
      }
    });
  }
}
