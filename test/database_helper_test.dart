/// Exercises the real SQLite layer. `sqflite_common_ffi` runs the same sqflite
/// API against a native sqlite on the test VM, so the schema in
/// [DatabaseHelper] and every CRUD path actually execute here — no Android
/// device and no in-memory stand-in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:events_app/database/database_helper.dart';
import 'package:events_app/models/event_date.dart';
import 'package:events_app/models/event.dart';
import 'package:events_app/repository/event_repository.dart';

Event _event({
  required String name,
  int day = 14,
  HebrewMonth month = HebrewMonth.cheshvan,
  CalendarSystem calendar = CalendarSystem.hebrew,
  int gregorianMonth = 11,
  EventKind kind = EventKind.birthday,
  int? startYear,
  int hour = 9,
  int minute = 0,
  bool enabled = true,
  String? notes,
  DateTime? createdAt,
}) {
  final storage = month.toStorage();
  final hebrew = calendar == CalendarSystem.hebrew;
  return Event(
    name: name,
    kind: kind,
    calendar: calendar,
    day: day,
    month: hebrew ? storage.baseMonth : gregorianMonth,
    adarType: hebrew ? storage.adarType : AdarType.none,
    startYear: startYear,
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
    final id = await db.insert(_event(name: 'דנה'));
    expect(id, greaterThan(0));

    final loaded = await db.getById(id);
    expect(loaded, isNotNull);
    expect(loaded!.name, 'דנה');
    expect(loaded.id, id);
  });

  test('every field survives a write/read round trip', () async {
    final original = _event(
      name: 'אנחנו',
      day: 3,
      month: HebrewMonth.nisan,
      hour: 7,
      minute: 45,
      enabled: false,
      notes: 'להזמין מסעדה',
      createdAt: DateTime(2023, 5, 6, 7, 8, 9),
    );

    final id = await db.insert(original);
    final loaded = (await db.getById(id))!;

    expect(loaded.name, original.name);
    expect(loaded.day, original.day);
    expect(loaded.month, original.month);
    expect(loaded.adarType, original.adarType);
    expect(loaded.notificationHour, 7);
    expect(loaded.notificationMinute, 45);
    expect(loaded.enabled, isFalse);
    expect(loaded.notes, 'להזמין מסעדה');
    expect(loaded.createdAt, original.createdAt);
    expect(loaded.hebrewMonth, HebrewMonth.nisan);
  });

  test('null notes stay null rather than becoming an empty string', () async {
    final id = await db.insert(_event(name: 'ללא הערות'));
    expect((await db.getById(id))!.notes, isNull);
  });

  test('each Adar variant persists distinctly', () async {
    for (final month in [
      HebrewMonth.adar,
      HebrewMonth.adarA,
      HebrewMonth.adarB,
    ]) {
      final id = await db.insert(_event(name: 'x', day: 10, month: month));
      final loaded = (await db.getById(id))!;
      expect(loaded.hebrewMonth, month, reason: 'failed for $month');
      expect(loaded.month, HebrewMonth.adar.index);
    }
  });

  test('insert ignores any id on the model and lets sqlite assign one',
      () async {
    final first = await db.insert(_event(name: 'a'));
    final second = await db.insert(_event(name: 'b'));
    expect(second, isNot(equals(first)));
  });

  test('getAll returns newest-created first', () async {
    await db.insert(_event(name: 'ישן', createdAt: DateTime(2020, 1, 1)));
    await db.insert(_event(name: 'חדש', createdAt: DateTime(2026, 1, 1)));
    await db.insert(_event(name: 'אמצע', createdAt: DateTime(2023, 1, 1)));

    final all = await db.getAll();
    expect(all.map((m) => m.name).toList(), ['חדש', 'אמצע', 'ישן']);
  });

  test('update writes the change back', () async {
    final id = await db.insert(_event(name: 'לפני', enabled: true));
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
    final id = await db.insert(_event(name: 'x', notes: 'להסיר'));
    final loaded = (await db.getById(id))!;

    await db.update(loaded.copyWith(clearNotes: true));
    expect((await db.getById(id))!.notes, isNull);
  });

  test('delete removes only the requested row', () async {
    final keep = await db.insert(_event(name: 'נשאר'));
    final drop = await db.insert(_event(name: 'נמחק'));

    expect(await db.delete(drop), 1);
    expect(await db.getById(drop), isNull);
    expect(await db.getById(keep), isNotNull);
    expect(await db.getAll(), hasLength(1));
  });

  test('deleting a missing id is a no-op, not an error', () async {
    expect(await db.delete(999999), 0);
  });

  test('replaceAll swaps the whole table inside one transaction', () async {
    await db.insert(_event(name: 'ישן א'));
    await db.insert(_event(name: 'ישן ב'));

    await db.replaceAll([
      _event(name: 'חדש א', createdAt: DateTime(2025, 1, 1)),
      _event(name: 'חדש ב', createdAt: DateTime(2024, 1, 1)),
    ]);

    final all = await db.getAll();
    expect(all.map((m) => m.name).toList(), ['חדש א', 'חדש ב']);
    // Fresh ids, so previously scheduled notification ids cannot collide.
    expect(all.every((m) => m.id != null), isTrue);
  });

  test('replaceAll with an empty list empties the table', () async {
    await db.insert(_event(name: 'x'));
    await db.replaceAll(const []);
    expect(await db.getAll(), isEmpty);
  });

  group('the reminder rule', () {
    test('defaults preserve the intended behaviour', () async {
      final id = await db.insert(_event(name: 'ברירות מחדל'));
      final loaded = (await db.getById(id))!;

      expect(loaded.reminderMode, ReminderMode.weekdayOfPreviousWeek);
      expect(loaded.reminderValue, DateTime.tuesday,
          reason: 'the default must remain Tuesday of the week before');
      expect(loaded.calendar, CalendarSystem.hebrew,
          reason: 'Hebrew is the default calendar, by design');
      expect(loaded.startYear, isNull,
          reason: '"unknown" has to stay a legitimate value');
    });

    test('a fixed interval round-trips', () async {
      final id = await db.insert(_event(name: 'מלא'));
      final original = (await db.getById(id))!;

      await db.update(original.copyWith(
        reminderMode: ReminderMode.fixedDaysBefore,
        reminderValue: 14,
      ));

      final loaded = (await db.getById(id))!;
      expect(loaded.reminderMode, ReminderMode.fixedDaysBefore);
      expect(loaded.reminderValue, 14);
    });

    test('a backup without the reminder keys parses with defaults', () {
      // The keys are what an older or hand-edited file may be missing, and a
      // missing reminder rule must not take the import down with it.
      final e = Event.fromJson({
        'id': 1,
        'name': 'גיבוי חסר',
        'day': 14,
        'month': HebrewMonth.cheshvan.index,
        'adar_type': 'none',
        'notification_hour': 9,
        'notification_minute': 0,
        'enabled': 1,
        'notes': null,
        'created_at': DateTime(2024).toIso8601String(),
        // no reminder_* keys, no kind, no calendar
      });
      expect(e.reminderMode, ReminderMode.weekdayOfPreviousWeek);
      expect(e.reminderValue, DateTime.tuesday);
      expect(e.calendar, CalendarSystem.hebrew);
      expect(e.kind, EventKind.other);
    });
  });

  group('a Gregorian event is stored beside a Hebrew one', () {
    test('both round-trip, and the calendar comes back with them', () async {
      final hebrewId = await db.insert(_event(
        name: 'אנחנו',
        day: 14,
        month: HebrewMonth.cheshvan,
      ));
      final gregorianId = await db.insert(_event(
        name: 'דנה',
        calendar: CalendarSystem.gregorian,
        day: 29,
        gregorianMonth: 2,
        startYear: 1996,
      ));

      final hebrew = (await db.getById(hebrewId))!;
      final gregorian = (await db.getById(gregorianId))!;

      expect(hebrew.calendar, CalendarSystem.hebrew);
      expect(hebrew.hebrewMonth, HebrewMonth.cheshvan);
      expect(gregorian.calendar, CalendarSystem.gregorian);
      expect(gregorian.isHebrew, isFalse);
      // The same column holds a Hebrew month index and a Gregorian month
      // number, and only the calendar says which reading is right.
      expect(gregorian.month, 2);
      expect(gregorian.day, 29);
      expect(gregorian.startYear, 1996);
    });

    test('the calendar is part of what identifies an event', () async {
      // 14 בחשוון ו-14 בנובמבר הם שני תאריכים שונים לגמרי, ולכן שתי שורות
      // באותו שם ובאותם מספרים אינן אותו אירוע.
      final hebrew = _event(name: 'דנה', day: 14, month: HebrewMonth.cheshvan);
      final gregorian = _event(
        name: 'דנה',
        calendar: CalendarSystem.gregorian,
        day: 14,
        gregorianMonth: HebrewMonth.cheshvan.index,
      );
      expect(hebrew.identityKey, isNot(gregorian.identityKey));

      final result = await db.mergeAll([hebrew, gregorian]);
      expect(result.added, 2);
      expect(result.skipped, 0);
    });
  });

  group('a damaged backup loses a field, not the import', () {
    test('an unparsable last_notified_at reads as null', () {
      // parse, not tryParse, used to sit here - while the sibling field one
      // line above used tryParse. One corrupt value in one row took the whole
      // file down, for a marker the next sync recomputes anyway.
      final m = Event.fromJson({
        'id': 1,
        'name': 'גיבוי פגום',
        'day': 14,
        'month': HebrewMonth.cheshvan.index,
        'adar_type': 'none',
        'notification_hour': 9,
        'notification_minute': 0,
        'enabled': 1,
        'created_at': DateTime(2024).toIso8601String(),
        'last_notified_at': 'לא תאריך',
        'postponed_reminder_at': 'גם לא',
      });
      expect(m.lastNotifiedAt, isNull);
      expect(m.postponedReminderAt, isNull);
      expect(m.name, 'גיבוי פגום', reason: 'the row itself must survive');
    });
  });

  group('the kind of event', () {
    test('a row written without one reads back as the generic kind',
        () async {
      final database = await db.database;
      await database.rawInsert(
        'INSERT INTO ${DatabaseHelper.table} '
        '(name, day, month, adar_type, notification_hour, '
        'notification_minute, enabled, created_at) VALUES (?,?,?,?,?,?,?,?)',
        [
          'ללא סוג',
          14,
          HebrewMonth.cheshvan.index,
          'none',
          9,
          0,
          1,
          DateTime(2024).toIso8601String(),
        ],
      );

      // The column carries a SQL default, so a row inserted without it is
      // still readable - and lands on the generic kind rather than claiming
      // to be a birthday.
      final loaded = (await db.getAll()).firstWhere((e) => e.name == 'ללא סוג');
      expect(loaded.kind, EventKind.other);
    });

    test('every kind round-trips through real sqlite', () async {
      for (final kind in EventKind.values) {
        final id = await db.insert(_event(name: 'x-${kind.name}', kind: kind));
        expect((await db.getById(id))!.kind, kind, reason: 'failed for $kind');
      }
    });
  });

  group('the year it all started', () {
    test('defaults to null and round-trips', () async {
      final id = await db.insert(_event(name: 'ללא שנה'));
      expect((await db.getById(id))!.startYear, isNull);

      await db.update((await db.getById(id))!.copyWith(startYear: 5784));
      expect((await db.getById(id))!.startYear, 5784);
    });

    test('clearStartYear nulls the column', () async {
      final id = await db.insert(_event(name: 'x'));
      await db.update((await db.getById(id))!.copyWith(startYear: 5780));
      expect((await db.getById(id))!.startYear, 5780);

      await db.update((await db.getById(id))!.copyWith(clearStartYear: true));
      expect((await db.getById(id))!.startYear, isNull);
    });

    test('a Gregorian year is stored as written, not converted', () async {
      // The year is kept in the event's own calendar, which is what makes it
      // subtractable from the occurrence year. Converting it on the way in
      // would make "the 25th anniversary" arithmetic across two calendars.
      final id = await db.insert(_event(
        name: 'אנחנו',
        calendar: CalendarSystem.gregorian,
        day: 14,
        gregorianMonth: 11,
        startYear: 2001,
      ));
      expect((await db.getById(id))!.startYear, 2001);
    });

    test('a backup without the year imports with none', () {
      final e = Event.fromJson({
        'id': 1,
        'name': 'גיבוי',
        'day': 14,
        'month': HebrewMonth.cheshvan.index,
        'adar_type': 'none',
        'notification_hour': 9,
        'notification_minute': 0,
        'enabled': 1,
        'created_at': DateTime(2024).toIso8601String(),
      });
      expect(e.startYear, isNull);
    });
  });

  // Everything above drives DatabaseHelper directly. The app never does —
  // it always goes through EventRepository, so exercise that seam too,
  // against the same real database.
  group('merge adds only what is missing', () {
    // Against the real database, because the whole point is the SQL: the
    // in-memory fake would only be testing itself.
    test('an identical event is skipped, a new one is added', () async {
      await db.insert(_event(name: 'דנה'));

      final result = await db.mergeAll([
        _event(name: 'דנה'),
        _event(name: 'אנחנו'),
      ]);

      expect(result.added, 1);
      expect(result.skipped, 1);
      expect((await db.getAll()).map((m) => m.name),
          containsAll(['דנה', 'אנחנו']));
      expect(await db.getAll(), hasLength(2));
    });

    test('the same name on another date is a different person', () async {
      await db.insert(_event(name: 'דנה', day: 27));

      final result = await db.mergeAll([_event(name: 'דנה', day: 3)]);

      expect(result.added, 1);
      expect(await db.getAll(), hasLength(2));
    });

    test('spacing in the name does not create a duplicate', () async {
      await db.insert(_event(name: 'דנה'));

      final result = await db.mergeAll([_event(name: '  דנה  ')]);

      expect(result.skipped, 1, reason: 'typing differences are not identity');
      expect(await db.getAll(), hasLength(1));
    });

    test('a file that repeats an event inside itself adds it once',
        () async {
      final result = await db.mergeAll([
        _event(name: 'דנה'),
        _event(name: 'דנה'),
      ]);

      expect(result.added, 1);
      expect(result.skipped, 1);
    });

    test('nothing existing is touched', () async {
      final id = await db.insert(_event(name: 'דנה'));
      await db.mergeAll([_event(name: 'אנחנו')]);

      final kept = await db.getById(id);
      expect(kept, isNotNull, reason: 'merge never deletes');
      expect(kept!.name, 'דנה');
    });
  });

  group('the merge plan separates the obvious from the doubtful', () {
    final repo = EventRepository();

    test('same name and date is identical; a new date is simply added',
        () async {
      await db.insert(_event(name: 'דנה', day: 27));

      final plan = await repo.planMerge([
        _event(name: 'דנה', day: 27),
        _event(name: 'אנחנו', day: 3),
      ]);

      expect(plan.identical, 1);
      expect(plan.toAdd.map((m) => m.name), ['אנחנו']);
      expect(plan.candidates, isEmpty);
    });

    test('the same date under another name is asked about, not decided',
        () async {
      // The Hebrew date is precise and rarely collides, so this is almost
      // always one person written two ways - but almost is not always.
      await db.insert(_event(name: 'דנה', day: 27));

      final plan = await repo.planMerge([_event(name: 'יעקב כהן', day: 27)]);

      expect(plan.needsDecision, isTrue);
      expect(plan.candidates.single.incoming.name, 'יעקב כהן');
      expect(plan.candidates.single.existing.name, 'דנה');
      expect(plan.toAdd, isEmpty, reason: 'nothing is added behind the ask');
    });

    test('the same name on another date is not a candidate', () async {
      // Two people can share a name; guessing on names would be noise.
      await db.insert(_event(name: 'דנה', day: 27));

      final plan = await repo.planMerge([_event(name: 'דנה', day: 3)]);

      expect(plan.candidates, isEmpty);
      expect(plan.toAdd, hasLength(1));
    });

    test('planning changes nothing on its own', () async {
      await db.insert(_event(name: 'דנה', day: 27));
      await repo.planMerge([_event(name: 'יעקב כהן', day: 27)]);

      expect(await db.getAll(), hasLength(1),
          reason: 'the ask comes before the data is touched');
    });
  });

  group('filling from a merged twin never overwrites', () {
    test('only the empty fields are taken', () async {
      final existing = _event(name: 'דנה', notes: 'הערה קיימת');
      final incoming = _event(
        name: 'דנה כהן',
        notes: 'הערה מהקובץ',
        startYear: 5784,
        kind: EventKind.anniversary,
      );

      final filled = existing.filledFrom(incoming);

      expect(filled.notes, 'הערה קיימת', reason: 'what is here stays');
      expect(filled.startYear, 5784, reason: 'what was missing is taken');
      expect(filled.name, 'דנה',
          reason: 'the kept record keeps its own name and date');
      expect(filled.kind, existing.kind,
          reason: 'a merge may not reclassify an event');
    });
  });

  group('EventRepository over real sqlite', () {
    final repo = EventRepository();

    test('delegates the full CRUD cycle', () async {
      final id = await repo.insert(_event(name: 'דרך ה-repository'));
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
      await repo.insert(_event(name: 'ישן'));
      await repo.replaceAll([_event(name: 'חדש')]);

      final all = await repo.getAll();
      expect(all, hasLength(1));
      expect(all.single.name, 'חדש');
      // And the same rows are visible through the layer underneath.
      expect((await db.getAll()).single.name, 'חדש');
    });
  });

  group('schema v2: last_notified_at', () {
    test('defaults to null and round-trips a value', () async {
      final id = await db.insert(_event(name: 'טרם הוצג'));
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
        '(name, day, month, adar_type, notification_hour, '
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
        'day': 14,
        'month': HebrewMonth.cheshvan.index,
        'adar_type': 'none',
        'notification_hour': 9,
        'notification_minute': 0,
        'enabled': 1,
        'notes': null,
        'created_at': DateTime(2024).toIso8601String(),
        // no last_notified_at at all
      };
      final m = Event.fromJson(json);
      expect(m.lastNotifiedAt, isNull);
      expect(m.name, 'מגיבוי ישן');
    });
  });

  test('the JSON export/import shape survives a trip through sqlite',
      () async {
    final id = await db.insert(_event(
      name: 'דוד משה',
      day: 10,
      month: HebrewMonth.adarB,
      notes: 'הערה',
    ));
    final fromDb = (await db.getById(id))!;

    // What settings_screen writes out and reads back in.
    final restored = Event.fromJson(fromDb.toJson());
    expect(restored.name, fromDb.name);
    expect(restored.adarType, AdarType.adarB);
    expect(restored.hebrewMonth, HebrewMonth.adarB);
    expect(restored.enabled, fromDb.enabled);
    expect(restored.createdAt, fromDb.createdAt);
    expect(restored.calendar, fromDb.calendar);
    expect(restored.kind, fromDb.kind);
  });

  test('a backup from the memorial app is refused, not half-imported', () {
    // Its columns were hebrew_day / hebrew_month, so nothing here can read
    // it. The settings screen turns this throw into one sentence instead of
    // a TypeError - and it is a refusal on purpose: importing yahrzeits as
    // happy events would be a change of meaning, not an import.
    expect(
      () => Event.fromJson({
        'id': 1,
        'name': 'סבא יעקב',
        'hebrew_day': 14,
        'hebrew_month': 1,
        'adar_type': 'none',
        'notification_hour': 9,
        'notification_minute': 0,
        'enabled': 1,
        'created_at': DateTime(2024).toIso8601String(),
      }),
      throwsA(isA<TypeError>()),
    );
  });
}
