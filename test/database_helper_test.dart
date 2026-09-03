/// Exercises the real SQLite layer. `sqflite_common_ffi` runs the same sqflite
/// API against a native sqlite on the test VM, so the schema in
/// [DatabaseHelper] and every CRUD path actually execute here — no Android
/// device and no in-memory stand-in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:azkarot_app/database/database_helper.dart';
import 'package:azkarot_app/models/hebrew_date.dart';
import 'package:azkarot_app/models/memorial.dart';
import 'package:azkarot_app/repository/memorial_repository.dart';

Memorial _memorial({
  required String name,
  int day = 14,
  HebrewMonth month = HebrewMonth.cheshvan,
  int hour = 9,
  int minute = 0,
  bool enabled = true,
  String? notes,
  DateTime? createdAt,
}) {
  final storage = month.toStorage();
  return Memorial(
    name: name,
    hebrewDay: day,
    hebrewMonth: storage.baseMonth,
    adarType: storage.adarType,
    notificationHour: hour,
    notificationMinute: minute,
    enabled: enabled,
    notes: notes,
    createdAt: createdAt ?? DateTime(2024, 1, 1),
  );
}

void main() {
  final db = DatabaseHelper.instance;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // DatabaseHelper caches one connection in a static field, so the table is
  // truncated between tests rather than reopened.
  setUp(() async {
    await db.replaceAll(const []);
  });

  test('the schema really is created and accepts a row', () async {
    final id = await db.insert(_memorial(name: 'סבא יעקב'));
    expect(id, greaterThan(0));

    final loaded = await db.getById(id);
    expect(loaded, isNotNull);
    expect(loaded!.name, 'סבא יעקב');
    expect(loaded.id, id);
  });

  test('every field survives a write/read round trip', () async {
    final original = _memorial(
      name: 'סבתא רחל',
      day: 3,
      month: HebrewMonth.nisan,
      hour: 7,
      minute: 45,
      enabled: false,
      notes: 'בית עלמין ירקון, חלקה 12',
      createdAt: DateTime(2023, 5, 6, 7, 8, 9),
    );

    final id = await db.insert(original);
    final loaded = (await db.getById(id))!;

    expect(loaded.name, original.name);
    expect(loaded.hebrewDay, original.hebrewDay);
    expect(loaded.hebrewMonth, original.hebrewMonth);
    expect(loaded.adarType, original.adarType);
    expect(loaded.notificationHour, 7);
    expect(loaded.notificationMinute, 45);
    expect(loaded.enabled, isFalse);
    expect(loaded.notes, 'בית עלמין ירקון, חלקה 12');
    expect(loaded.createdAt, original.createdAt);
    expect(loaded.selectedMonth, HebrewMonth.nisan);
  });

  test('null notes stay null rather than becoming an empty string', () async {
    final id = await db.insert(_memorial(name: 'ללא הערות'));
    expect((await db.getById(id))!.notes, isNull);
  });

  test('each Adar variant persists distinctly', () async {
    for (final month in [
      HebrewMonth.adar,
      HebrewMonth.adarA,
      HebrewMonth.adarB,
    ]) {
      final id = await db.insert(_memorial(name: 'x', day: 10, month: month));
      final loaded = (await db.getById(id))!;
      expect(loaded.selectedMonth, month, reason: 'failed for $month');
      expect(loaded.hebrewMonth, HebrewMonth.adar.index);
    }
  });

  test('insert ignores any id on the model and lets sqlite assign one',
      () async {
    final first = await db.insert(_memorial(name: 'a'));
    final second = await db.insert(_memorial(name: 'b'));
    expect(second, isNot(equals(first)));
  });

  test('getAll returns newest-created first', () async {
    await db.insert(_memorial(name: 'ישן', createdAt: DateTime(2020, 1, 1)));
    await db.insert(_memorial(name: 'חדש', createdAt: DateTime(2026, 1, 1)));
    await db.insert(_memorial(name: 'אמצע', createdAt: DateTime(2023, 1, 1)));

    final all = await db.getAll();
    expect(all.map((m) => m.name).toList(), ['חדש', 'אמצע', 'ישן']);
  });

  test('update writes the change back', () async {
    final id = await db.insert(_memorial(name: 'לפני', enabled: true));
    final loaded = (await db.getById(id))!;

    final rows = await db.update(
      loaded.copyWith(name: 'אחרי', enabled: false, notificationHour: 20),
    );
    expect(rows, 1);

    final reloaded = (await db.getById(id))!;
    expect(reloaded.name, 'אחרי');
    expect(reloaded.enabled, isFalse);
    expect(reloaded.notificationHour, 20);
  });

  test('copyWith(clearNotes: true) actually nulls the column', () async {
    final id = await db.insert(_memorial(name: 'x', notes: 'להסיר'));
    final loaded = (await db.getById(id))!;

    await db.update(loaded.copyWith(clearNotes: true));
    expect((await db.getById(id))!.notes, isNull);
  });

  test('delete removes only the requested row', () async {
    final keep = await db.insert(_memorial(name: 'נשאר'));
    final drop = await db.insert(_memorial(name: 'נמחק'));

    expect(await db.delete(drop), 1);
    expect(await db.getById(drop), isNull);
    expect(await db.getById(keep), isNotNull);
    expect(await db.getAll(), hasLength(1));
  });

  test('deleting a missing id is a no-op, not an error', () async {
    expect(await db.delete(999999), 0);
  });

  test('replaceAll swaps the whole table inside one transaction', () async {
    await db.insert(_memorial(name: 'ישן א'));
    await db.insert(_memorial(name: 'ישן ב'));

    await db.replaceAll([
      _memorial(name: 'חדש א', createdAt: DateTime(2025, 1, 1)),
      _memorial(name: 'חדש ב', createdAt: DateTime(2024, 1, 1)),
    ]);

    final all = await db.getAll();
    expect(all.map((m) => m.name).toList(), ['חדש א', 'חדש ב']);
    // Fresh ids, so previously scheduled notification ids cannot collide.
    expect(all.every((m) => m.id != null), isTrue);
  });

  test('replaceAll with an empty list empties the table', () async {
    await db.insert(_memorial(name: 'x'));
    await db.replaceAll(const []);
    expect(await db.getAll(), isEmpty);
  });

  group('schema v3: burial place, photo, reminder rule', () {
    test('defaults preserve the existing behaviour', () async {
      final id = await db.insert(_memorial(name: 'ברירות מחדל'));
      final loaded = (await db.getById(id))!;

      expect(loaded.cemetery, isNull);
      expect(loaded.plot, isNull);
      expect(loaded.photoPath, isNull);
      expect(loaded.reminderMode, ReminderMode.weekdayOfPreviousWeek);
      expect(loaded.reminderValue, DateTime.tuesday,
          reason: 'the default must remain Tuesday of the week before');
    });

    test('all new fields round-trip', () async {
      final id = await db.insert(_memorial(name: 'מלא'));
      final original = (await db.getById(id))!;

      await db.update(original.copyWith(
        cemetery: 'ירקון',
        plot: "גוש ה', חלקה 12, שורה 4",
        photoPath: '/data/user/0/app/photos/x.jpg',
        reminderMode: ReminderMode.fixedDaysBefore,
        reminderValue: 14,
      ));

      final loaded = (await db.getById(id))!;
      expect(loaded.cemetery, 'ירקון');
      expect(loaded.plot, "גוש ה', חלקה 12, שורה 4");
      expect(loaded.photoPath, '/data/user/0/app/photos/x.jpg');
      expect(loaded.reminderMode, ReminderMode.fixedDaysBefore);
      expect(loaded.reminderValue, 14);
      expect(loaded.burialSearchQuery, "ירקון, גוש ה', חלקה 12, שורה 4");
    });

    test('clearPhoto nulls the column', () async {
      final id = await db.insert(_memorial(name: 'x'));
      await db.update((await db.getById(id))!.copyWith(photoPath: '/a/b.jpg'));
      expect((await db.getById(id))!.photoPath, '/a/b.jpg');

      await db.update((await db.getById(id))!.copyWith(clearPhoto: true));
      expect((await db.getById(id))!.photoPath, isNull);
    });

    test('a row written before v3 reads back with safe defaults', () async {
      final database = await db.database;
      await database.rawInsert(
        'INSERT INTO ${DatabaseHelper.table} '
        '(name, hebrew_day, hebrew_month, adar_type, notification_hour, '
        'notification_minute, enabled, created_at) VALUES (?,?,?,?,?,?,?,?)',
        ['לפני v3', 14, HebrewMonth.cheshvan.index, 'none', 9, 0, 1,
          DateTime(2024).toIso8601String()],
      );

      final loaded = (await db.getAll()).firstWhere((m) => m.name == 'לפני v3');
      expect(loaded.cemetery, isNull);
      expect(loaded.photoPath, isNull);
      // The column defaults are what keep upgraded installs behaving the same.
      expect(loaded.reminderMode, ReminderMode.weekdayOfPreviousWeek);
      expect(loaded.reminderValue, DateTime.tuesday);
    });

    test('importing a pre-v3 backup parses with defaults', () {
      final m = Memorial.fromJson({
        'id': 1,
        'name': 'גיבוי ישן',
        'hebrew_day': 14,
        'hebrew_month': HebrewMonth.cheshvan.index,
        'adar_type': 'none',
        'notification_hour': 9,
        'notification_minute': 0,
        'enabled': 1,
        'notes': null,
        'created_at': DateTime(2024).toIso8601String(),
        // no cemetery / plot / photo_path / reminder_* keys at all
      });
      expect(m.reminderMode, ReminderMode.weekdayOfPreviousWeek);
      expect(m.reminderValue, DateTime.tuesday);
      expect(m.burialSearchQuery, isNull);
    });
  });

  group('schema v4: death_hebrew_year', () {
    test('defaults to null and round-trips', () async {
      final id = await db.insert(_memorial(name: 'ללא שנה'));
      expect((await db.getById(id))!.deathHebrewYear, isNull);

      await db.update((await db.getById(id))!.copyWith(deathHebrewYear: 5784));
      expect((await db.getById(id))!.deathHebrewYear, 5784);
    });

    test('clearDeathYear nulls the column', () async {
      final id = await db.insert(_memorial(name: 'x'));
      await db.update((await db.getById(id))!.copyWith(deathHebrewYear: 5780));
      expect((await db.getById(id))!.deathHebrewYear, 5780);

      await db.update((await db.getById(id))!.copyWith(clearDeathYear: true));
      expect((await db.getById(id))!.deathHebrewYear, isNull);
    });

    test('a row written before v4 reads back with null', () async {
      final database = await db.database;
      await database.rawInsert(
        'INSERT INTO ${DatabaseHelper.table} '
        '(name, hebrew_day, hebrew_month, adar_type, notification_hour, '
        'notification_minute, enabled, created_at) VALUES (?,?,?,?,?,?,?,?)',
        ['לפני v4', 14, HebrewMonth.cheshvan.index, 'none', 9, 0, 1,
          DateTime(2024).toIso8601String()],
      );

      final loaded = (await db.getAll()).firstWhere((m) => m.name == 'לפני v4');
      expect(loaded.deathHebrewYear, isNull);
      // And the v3 defaults are still intact alongside it.
      expect(loaded.reminderValue, DateTime.tuesday);
    });

    test('a pre-v4 backup imports with no year', () {
      final m = Memorial.fromJson({
        'id': 1,
        'name': 'גיבוי',
        'hebrew_day': 14,
        'hebrew_month': HebrewMonth.cheshvan.index,
        'adar_type': 'none',
        'notification_hour': 9,
        'notification_minute': 0,
        'enabled': 1,
        'created_at': DateTime(2024).toIso8601String(),
      });
      expect(m.deathHebrewYear, isNull);
    });
  });

  // Everything above drives DatabaseHelper directly. The app never does —
  // it always goes through MemorialRepository, so exercise that seam too,
  // against the same real database.
  group('merge adds only what is missing', () {
    // Against the real database, because the whole point is the SQL: the
    // in-memory fake would only be testing itself.
    test('an identical memorial is skipped, a new one is added', () async {
      await db.insert(_memorial(name: 'סבא יעקב'));

      final result = await db.mergeAll([
        _memorial(name: 'סבא יעקב'),
        _memorial(name: 'סבתא רחל'),
      ]);

      expect(result.added, 1);
      expect(result.skipped, 1);
      expect((await db.getAll()).map((m) => m.name),
          containsAll(['סבא יעקב', 'סבתא רחל']));
      expect(await db.getAll(), hasLength(2));
    });

    test('the same name on another date is a different person', () async {
      await db.insert(_memorial(name: 'סבא יעקב', day: 27));

      final result = await db.mergeAll([_memorial(name: 'סבא יעקב', day: 3)]);

      expect(result.added, 1);
      expect(await db.getAll(), hasLength(2));
    });

    test('spacing in the name does not create a duplicate', () async {
      await db.insert(_memorial(name: 'סבא יעקב'));

      final result = await db.mergeAll([_memorial(name: '  סבא   יעקב ')]);

      expect(result.skipped, 1, reason: 'typing differences are not identity');
      expect(await db.getAll(), hasLength(1));
    });

    test('a file that repeats a memorial inside itself adds it once',
        () async {
      final result = await db.mergeAll([
        _memorial(name: 'סבא יעקב'),
        _memorial(name: 'סבא יעקב'),
      ]);

      expect(result.added, 1);
      expect(result.skipped, 1);
    });

    test('nothing existing is touched', () async {
      final id = await db.insert(_memorial(name: 'סבא יעקב'));
      await db.mergeAll([_memorial(name: 'סבתא רחל')]);

      final kept = await db.getById(id);
      expect(kept, isNotNull, reason: 'merge never deletes');
      expect(kept!.name, 'סבא יעקב');
    });
  });

  group('MemorialRepository over real sqlite', () {
    final repo = MemorialRepository();

    test('delegates the full CRUD cycle', () async {
      final id = await repo.insert(_memorial(name: 'דרך ה-repository'));
      expect(id, greaterThan(0));

      final loaded = await repo.getById(id);
      expect(loaded!.name, 'דרך ה-repository');

      expect(await repo.update(loaded.copyWith(name: 'שונה')), 1);
      expect((await repo.getById(id))!.name, 'שונה');

      expect(await repo.getAll(), hasLength(1));

      expect(await repo.delete(id), 1);
      expect(await repo.getById(id), isNull);
      expect(await repo.getAll(), isEmpty);
    });

    test('getById returns null for an unknown id', () async {
      expect(await repo.getById(424242), isNull);
    });

    test('replaceAll goes through to the database', () async {
      await repo.insert(_memorial(name: 'ישן'));
      await repo.replaceAll([_memorial(name: 'חדש')]);

      final all = await repo.getAll();
      expect(all, hasLength(1));
      expect(all.single.name, 'חדש');
      // And the same rows are visible through the layer underneath.
      expect((await db.getAll()).single.name, 'חדש');
    });
  });

  group('schema v2: last_notified_at', () {
    test('defaults to null and round-trips a value', () async {
      final id = await db.insert(_memorial(name: 'טרם הוצג'));
      expect((await db.getById(id))!.lastNotifiedAt, isNull);

      final stamp = DateTime(2026, 8, 4, 9);
      await db.update((await db.getById(id))!.copyWith(lastNotifiedAt: stamp));
      expect((await db.getById(id))!.lastNotifiedAt, stamp);
    });

    test('an upgraded v1 row reads back with a null stamp', () async {
      // Simulates a row written before the column existed.
      final database = await db.database;
      await database.rawInsert(
        'INSERT INTO ${DatabaseHelper.table} '
        '(name, hebrew_day, hebrew_month, adar_type, notification_hour, '
        'notification_minute, enabled, notes, created_at) '
        'VALUES (?,?,?,?,?,?,?,?,?)',
        ['ישן', 14, HebrewMonth.cheshvan.index, 'none', 9, 0, 1, null,
          DateTime(2024).toIso8601String()],
      );

      final loaded = (await db.getAll()).firstWhere((m) => m.name == 'ישן');
      expect(loaded.lastNotifiedAt, isNull);
      expect(loaded.name, 'ישן');
    });

    test('importing a pre-v2 backup (no such key) still parses', () {
      final json = {
        'id': 1,
        'name': 'מגיבוי ישן',
        'hebrew_day': 14,
        'hebrew_month': HebrewMonth.cheshvan.index,
        'adar_type': 'none',
        'notification_hour': 9,
        'notification_minute': 0,
        'enabled': 1,
        'notes': null,
        'created_at': DateTime(2024).toIso8601String(),
        // no last_notified_at at all
      };
      final m = Memorial.fromJson(json);
      expect(m.lastNotifiedAt, isNull);
      expect(m.name, 'מגיבוי ישן');
    });
  });

  test('the JSON export/import shape survives a trip through sqlite',
      () async {
    final id = await db.insert(_memorial(
      name: 'דוד משה',
      day: 10,
      month: HebrewMonth.adarB,
      notes: 'הערה',
    ));
    final fromDb = (await db.getById(id))!;

    // What settings_screen writes out and reads back in.
    final restored = Memorial.fromJson(fromDb.toJson());
    expect(restored.name, fromDb.name);
    expect(restored.adarType, AdarType.adarB);
    expect(restored.selectedMonth, HebrewMonth.adarB);
    expect(restored.enabled, fromDb.enabled);
    expect(restored.createdAt, fromDb.createdAt);
  });
}
