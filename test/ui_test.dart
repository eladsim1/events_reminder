/// Runs the real app without an Android device: renders every screen against an
/// in-memory repository and a recording notification stub, and drives the
/// add-memorial and toggle flows end to end through the provider layer.
///
/// The rendered screens show "days until the reminder", so the calendar
/// service is pumped with a pinned clock ([_fixedNow]) — otherwise every
/// golden would fail a day later. Refresh them with:
///   flutter test test/ui_test.dart --update-goldens
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:azkarot_app/app.dart';
import 'package:azkarot_app/models/hebrew_date.dart';
import 'package:azkarot_app/models/memorial.dart';
import 'package:azkarot_app/models/memorial_filter.dart';
import 'package:azkarot_app/providers/memorial_provider.dart';
import 'package:azkarot_app/repository/memorial_repository.dart';
import 'package:azkarot_app/screens/edit_memorial_screen.dart';
import 'package:azkarot_app/screens/home_screen.dart';
import 'package:azkarot_app/screens/settings_screen.dart';
import 'package:azkarot_app/services/hebrew_calendar_service.dart';
import 'package:azkarot_app/services/notification_service.dart';
import 'package:azkarot_app/services/photo_store.dart';
import 'package:azkarot_app/widgets/hebrew_date_picker.dart';
import 'package:azkarot_app/widgets/memorial_card.dart';
import 'package:azkarot_app/widgets/memorial_form.dart';

/// Replaces SQLite so the real repository contract runs on the test VM.
class _InMemoryRepo extends MemorialRepository {
  final List<Memorial> items = [];
  int _nextId = 1;

  @override
  Future<int> insert(Memorial memorial) async {
    final id = _nextId++;
    items.add(memorial.copyWith(id: id));
    return id;
  }

  @override
  Future<int> update(Memorial memorial) async {
    final i = items.indexWhere((e) => e.id == memorial.id);
    if (i >= 0) items[i] = memorial;
    return 1;
  }

  @override
  Future<int> delete(int id) async {
    items.removeWhere((e) => e.id == id);
    return 1;
  }

  @override
  Future<List<Memorial>> getAll() async => List<Memorial>.of(items);

  @override
  Future<Memorial?> getById(int id) async {
    for (final m in items) {
      if (m.id == id) return m;
    }
    return null;
  }

  @override
  Future<void> replaceAll(List<Memorial> memorials) async {
    items
      ..clear()
      ..addAll(memorials);
  }
}

/// Records what the app *would* schedule, instead of hitting the platform.
class _FakeNotifications extends NotificationService {
  final List<String> log = [];

  /// Overridden per test to simulate a user who denied a permission.
  bool notificationsEnabled = true;
  bool exactAlarmsAllowed = true;
  int requestMissingCalls = 0;

  @override
  Future<({bool exactAlarmsAllowed, bool notificationsEnabled})>
      permissionStatus() async => (
            notificationsEnabled: notificationsEnabled,
            exactAlarmsAllowed: exactAlarmsAllowed,
          );

  @override
  Future<void> requestMissingPermissions() async {
    requestMissingCalls++;
    notificationsEnabled = true;
    exactAlarmsAllowed = true;
  }

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermissions() async => true;

  /// The nearest reminder the fake claims to have scheduled. Tests that care
  /// about the duplicate-notification guard set this.
  DateTime? nearestScheduled;

  @override
  Future<DateTime?> scheduleForMemorial(Memorial memorial) async {
    if (memorial.id == null) return null;
    log.add('cancel:${memorial.id}');
    if (!memorial.enabled) return null;
    log.add('schedule:${memorial.name}');
    return nearestScheduled;
  }

  @override
  Future<void> cancelForMemorial(int memorialId) async {
    log.add('cancel:$memorialId');
  }

  @override
  Future<Map<int, DateTime>> rescheduleAll(List<Memorial> memorials) async {
    final out = <int, DateTime>{};
    for (final m in memorials) {
      final at = await scheduleForMemorial(m);
      if (at != null && m.id != null) out[m.id!] = at;
    }
    return out;
  }

  @override
  Future<void> cancelAll() async {
    log.add('cancelAll');
  }

  /// Set by a test to simulate a reminder that was missed and needs delivering.
  /// Left null, this is a no-op — which is what every other test wants.
  DateTime? missedToDeliver;

  @override
  Future<DateTime?> deliverMissedReminder(Memorial memorial) async {
    if (missedToDeliver == null || !memorial.enabled) return null;
    log.add('missed:${memorial.name}');
    return missedToDeliver;
  }
}

/// flutter_test ships no real glyphs, so Hebrew renders as boxes in goldens.
/// Register a system font that has Hebrew coverage under the families the
/// Material theme asks for.
Future<void> _loadHebrewFont() async {
  const candidates = [
    r'C:\Windows\Fonts\arial.ttf',
    r'C:\Windows\Fonts\tahoma.ttf',
    r'C:\Windows\Fonts\segoeui.ttf',
  ];
  File? file;
  for (final path in candidates) {
    if (File(path).existsSync()) {
      file = File(path);
      break;
    }
  }
  if (file == null) return;

  final bytes = file.readAsBytesSync();
  for (final family in <String>['Roboto', 'Arial', 'Segoe UI', '.SF UI Text']) {
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  // Without this every Icon() renders as an empty box.
  final icons = File(
    r'C:\Users\elads\flutter\bin\cache\artifacts\material_fonts'
    r'\materialicons-regular.otf',
  );
  if (icons.existsSync()) {
    final iconBytes = icons.readAsBytesSync();
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future<ByteData>.value(ByteData.sublistView(iconBytes)));
    await loader.load();
  }
}

Memorial _seed({
  required int id,
  required String name,
  required int day,
  required HebrewMonth month,
  bool enabled = true,
  String? notes,
  String? cemetery,
  String? plot,
  String? photoPath,
  ReminderMode reminderMode = ReminderMode.weekdayOfPreviousWeek,
  int reminderValue = Memorial.defaultReminderWeekday,
}) {
  final storage = month.toStorage();
  return Memorial(
    id: id,
    name: name,
    hebrewDay: day,
    hebrewMonth: storage.baseMonth,
    adarType: storage.adarType,
    notificationHour: 9,
    notificationMinute: 0,
    enabled: enabled,
    notes: notes,
    cemetery: cemetery,
    plot: plot,
    photoPath: photoPath,
    reminderMode: reminderMode,
    reminderValue: reminderValue,
    createdAt: DateTime(2024, 1, id),
  );
}

void _phoneViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(824, 1648);
  addTearDown(tester.view.reset);
}

/// Pumps in slices until [target] shows up, and reports whether it did.
///
/// Splash spins a CircularProgressIndicator forever, so `pumpAndSettle` would
/// time out. Never interpolates the finder into a message either — that can
/// trip over defunct elements and mask the real failure.
Future<bool> _pumpUntil(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 60 && target.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 300));
  return target.evaluate().isNotEmpty;
}

/// Brings [target] on screen inside the memorial form and settles.
///
/// `ensureVisible` alone is not enough: the form is a lazy `ListView`, so a
/// control far down it is not built at all and `ensureVisible` throws
/// "No element". Scroll the form's own Scrollable — not `find.byType(Scrollable)`,
/// which would also match the date picker's wheels.
Future<void> _revealInForm(WidgetTester tester, Finder target) async {
  // Scoped to MemorialForm on purpose: the home screen stays mounted beneath
  // the pushed route, so a bare find.byType(ListView) can grab *its* list and
  // scroll the wrong thing.
  final scrollable = find
      .descendant(
        of: find.descendant(
          of: find.byType(MemorialForm),
          matching: find.byType(ListView),
        ),
        matching: find.byType(Scrollable),
      )
      .first;
  final position = tester.state<ScrollableState>(scrollable).position;

  // Driving the position directly rather than simulating a drag: a drag starts
  // at the Scrollable's centre, which sits on the date picker's wheels — they
  // swallow it and the date silently changes instead of the form scrolling.
  // Stepping (not jumping to maxScrollExtent) because a lazy ListView only
  // discovers its full extent as it goes.
  var offset = 0.0;
  while (target.evaluate().isEmpty && offset < position.maxScrollExtent) {
    offset = (offset + 300).clamp(0.0, position.maxScrollExtent);
    position.jumpTo(offset);
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(target, findsWidgets, reason: 'never scrolled into view');

  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 200));
}

/// Pumps until [target] disappears — for dismiss animations, where a fixed
/// delay is a guess that silently turns into a flaky assertion.
Future<void> _pumpUntilGone(
  WidgetTester tester,
  Finder target,
  String what,
) async {
  for (var i = 0; i < 60 && target.evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(target, findsNothing, reason: '$what never went away');
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder target,
  String what,
) async {
  final found = await _pumpUntil(tester, target);
  if (!found) {
    // ignore: avoid_print
    print('  !! never reached $what. Visible text on screen:');
    for (final e in find.byType(Text).evaluate()) {
      final data = (e.widget as Text).data;
      if (data != null && data.trim().isNotEmpty) {
        // ignore: avoid_print
        print('       "$data"');
      }
    }
  }
  expect(found, isTrue, reason: 'never reached $what');
}

/// Pinned so the rendered "days until the reminder" never drifts with the
/// wall clock — otherwise every golden fails a day later.
final DateTime _fixedNow = DateTime(2026, 7, 31, 12);

Future<(_InMemoryRepo, _FakeNotifications)> _pumpApp(
  WidgetTester tester, {
  List<Memorial> seeded = const [],
  DateTime? now,
  bool notificationsEnabled = true,
  bool exactAlarmsAllowed = true,
}) async {
  final repo = _InMemoryRepo()..items.addAll(seeded);
  final notif = _FakeNotifications()
    ..notificationsEnabled = notificationsEnabled
    ..exactAlarmsAllowed = exactAlarmsAllowed;
  final clock = now ?? _fixedNow;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        memorialRepositoryProvider.overrideWithValue(repo),
        notificationServiceProvider.overrideWithValue(notif),
        hebrewCalendarServiceProvider.overrideWithValue(
          HebrewCalendarService(now: () => clock),
        ),
      ],
      child: const AzkarotApp(),
    ),
  );
  await _pumpUntilFound(tester, find.byType(HomeScreen), 'HomeScreen');
  // HomeScreen appearing is not enough: loadAndReschedule also delivers missed
  // reminders, so the list can still be in AsyncLoading with no cards yet.
  // Wait for real content — a card, or the empty state.
  await _pumpUntilFound(
    tester,
    seeded.isEmpty ? find.text('אין אזכרות עדיין') : find.byType(MemorialCard),
    seeded.isEmpty ? 'the empty state' : 'the memorial list',
  );
  return (repo, notif);
}

void main() {
  setUpAll(_loadHebrewFont);

  group('nextMemorialDate honours `from`', () {
    test('the starting Hebrew year comes from `from`, not the wall clock', () {
      final calendar = HebrewCalendarService();
      final m = _seed(id: 1, name: 'x', day: 10, month: HebrewMonth.tishrei);

      // Deep in the past. Before the fix this returned a date near the real
      // present, because the year came from DateTime.now().
      final from = DateTime(2010, 1, 1);
      final next = calendar.nextMemorialDate(m, from: from);

      expect(next.isBefore(from), isFalse);
      expect(next.difference(from).inDays, lessThan(400),
          reason: 'must resolve within a year of `from`, got $next');
    });

    test('passing `from: null` is identical to passing today', () {
      final calendar = HebrewCalendarService();
      for (final month in HebrewMonth.values) {
        final m = _seed(id: 1, name: 'x', day: 10, month: month);
        expect(
          calendar.nextMemorialDate(m),
          equals(calendar.nextMemorialDate(m, from: DateTime.now())),
          reason: 'production behaviour changed for $month',
        );
      }
    });

    test('Adar I and Adar II differ once `from` lands on a leap year', () {
      final calendar = HebrewCalendarService();
      final adarA = _seed(id: 1, name: 'a', day: 10, month: HebrewMonth.adarA);
      final adarB = _seed(id: 2, name: 'b', day: 10, month: HebrewMonth.adarB);

      final from = DateTime(2023, 12, 1); // inside 5784, a leap year
      expect(calendar.isLeapYear(5784), isTrue);

      final a = calendar.nextMemorialDate(adarA, from: from);
      final b = calendar.nextMemorialDate(adarB, from: from);

      expect(a, isNot(equals(b)));
      expect(a.isBefore(b), isTrue, reason: 'Adar I precedes Adar II');
    });

    test('plain Adar still falls on Adar II in a leap year', () {
      final calendar = HebrewCalendarService();
      final plain = _seed(id: 1, name: 'a', day: 10, month: HebrewMonth.adar);
      final adarB = _seed(id: 2, name: 'b', day: 10, month: HebrewMonth.adarB);

      final from = DateTime(2023, 12, 1);
      expect(
        calendar.nextMemorialDate(plain, from: from),
        equals(calendar.nextMemorialDate(adarB, from: from)),
      );
    });
  });

  group('tuesdayBeforeWeekOf survives DST', () {
    // The pre-existing suite only scanned 60 days from 2027-01-01, so it never
    // reached a daylight-saving transition. Week arithmetic done with Duration
    // shifts across one and lands on the wrong day.
    test('always a Tuesday across four full years', () {
      final calendar = HebrewCalendarService();
      for (var year = 2026; year <= 2029; year++) {
        for (var day = 0; day < 365; day++) {
          final d = DateTime(year, 1, 1 + day);
          final reminder = calendar.tuesdayBeforeWeekOf(d);
          expect(reminder.weekday, DateTime.tuesday, reason: 'failed for $d');
          // 5..11 calendar days before the memorial, never after it. Measured
          // in UTC — a local-time difference loses an hour across DST and
          // truncates to one day fewer.
          final gap = DateTime.utc(d.year, d.month, d.day)
              .difference(
                  DateTime.utc(reminder.year, reminder.month, reminder.day))
              .inDays;
          expect(gap, inInclusiveRange(5, 11), reason: 'gap $gap for $d');
        }
      }
    });

    test('the Israeli spring-forward week specifically', () {
      final calendar = HebrewCalendarService();
      // Israel moves to DST on the Friday before the last Sunday of March.
      for (final memorialDate in [
        DateTime(2027, 3, 28),
        DateTime(2027, 3, 29),
        DateTime(2027, 3, 26),
        DateTime(2026, 3, 29),
        DateTime(2026, 10, 25),
      ]) {
        final reminder = calendar.tuesdayBeforeWeekOf(memorialDate);
        expect(reminder.weekday, DateTime.tuesday,
            reason: 'memorial on $memorialDate gave $reminder');
      }
      // The exact case that used to return Monday 2027-03-22.
      expect(calendar.tuesdayBeforeWeekOf(DateTime(2027, 3, 28)),
          DateTime(2027, 3, 23));
    });
  });

  group('the reminder for the nearest memorial can already be past', () {
    // reminderDate lands 5-11 days before the memorial, so for every memorial
    // there is a yearly window where it is behind us but the memorial is not.
    (Memorial, DateTime, DateTime)? findInWindow(HebrewCalendarService cal) {
      final now = _fixedNow;
      for (final month in HebrewMonth.values) {
        for (var day = 1; day <= 29; day++) {
          final m = _seed(id: 1, name: 'x', day: day, month: month);
          final memorialDate = cal.nextMemorialDate(m, from: now);
          final reminder = cal.reminderDate(m, from: now);
          if (reminder.isBefore(now) && !memorialDate.isBefore(now)) {
            return (m, memorialDate, reminder);
          }
        }
      }
      return null;
    }

    test('such a window exists, and daysUntilReminder goes negative', () {
      final cal = HebrewCalendarService();
      final hit = findInWindow(cal);
      expect(hit, isNotNull,
          reason: 'expected at least one memorial inside the dead window');

      final (m, memorialDate, reminder) = hit!;
      expect(reminder.isBefore(memorialDate), isTrue);
      expect(cal.daysUntilReminder(m, from: _fixedNow),
          lessThan(0));
    });

    test('nextFutureReminderDate still returns something schedulable', () {
      final cal = HebrewCalendarService();
      final now = _fixedNow;
      final hit = findInWindow(cal);
      final (m, _, _) = hit!;

      final future = cal.nextFutureReminderDate(m, from: now);
      expect(future, isNotNull,
          reason: 'the notification layer would otherwise schedule nothing');
      expect(future!.isAfter(now), isTrue);
      expect(future.weekday, DateTime.tuesday);
      expect(future.hour, m.notificationHour);
      expect(future.minute, m.notificationMinute);
    });

    test('every month/day has a schedulable future reminder', () {
      final cal = HebrewCalendarService();
      final now = _fixedNow;
      for (final month in HebrewMonth.values) {
        for (var day = 1; day <= 29; day++) {
          final m = _seed(id: 1, name: 'x', day: day, month: month);
          final future = cal.nextFutureReminderDate(m, from: now);
          expect(future, isNotNull, reason: 'no reminder for $day $month');
          expect(future!.isAfter(now), isTrue, reason: '$day $month');
          expect(future.weekday, DateTime.tuesday, reason: '$day $month');
        }
      }
    });
  });

  group('Hebrew date of the upcoming occurrence', () {
    test('includes the Hebrew year in gematria', () {
      final cal = HebrewCalendarService();
      final m = _seed(id: 1, name: 'x', day: 26, month: HebrewMonth.av);

      final occurrence = cal.nextMemorialOccurrence(m, from: _fixedNow);
      expect(occurrence, isNotNull);
      final text = cal.formatNextMemorialHebrewDate(m, from: _fixedNow)!;
      // ignore: avoid_print
      print('  ${occurrence!.gregorian} -> "$text" '
          '(hebrew year ${occurrence.hebrewYear})');

      expect(text, startsWith('כ"ו באב '));
      // A gematria year, not digits.
      expect(text, isNot(matches(RegExp(r'\d'))));
      expect(text.split(' ').last, isNotEmpty);
    });

    test('a plain-Adar memorial reads as Adar II in a leap year', () {
      final cal = HebrewCalendarService();
      final m = _seed(id: 1, name: 'x', day: 10, month: HebrewMonth.adar);

      // 5787 is a leap year; aim `from` just inside 5786 so 5787 is next.
      final text = cal.formatNextMemorialHebrewDate(
        m,
        from: DateTime(2026, 7, 31),
      )!;
      // ignore: avoid_print
      print('  plain Adar -> "$text"');
      expect(text, contains("אדר ב'"));
    });

    test('never contains digits for any month/day', () {
      final cal = HebrewCalendarService();
      for (final month in HebrewMonth.values) {
        for (var day = 1; day <= 29; day++) {
          final m = _seed(id: 1, name: 'x', day: day, month: month);
          final text = cal.formatNextMemorialHebrewDate(m, from: _fixedNow);
          expect(text, isNotNull, reason: '$day $month');
          expect(text, isNot(matches(RegExp(r'\d'))), reason: '$day $month');
        }
      }
    });
  });

  group('reminders recur for years without reopening the app', () {
    test('enumerates one reminder per year, all Tuesdays, in order', () {
      final cal = HebrewCalendarService();
      final m = _seed(id: 1, name: 'x', day: 26, month: HebrewMonth.av);

      final dates = cal.futureReminderDates(m, from: _fixedNow, years: 20);
      expect(dates.length, greaterThanOrEqualTo(19),
          reason: 'expected roughly one per year');

      for (final d in dates) {
        expect(d.weekday, DateTime.tuesday, reason: '$d');
        expect(d.isAfter(_fixedNow), isTrue, reason: '$d');
        expect(d.hour, m.notificationHour);
      }
      for (var i = 1; i < dates.length; i++) {
        expect(dates[i].isAfter(dates[i - 1]), isTrue, reason: 'not sorted');
      }
      // Spans two decades, so a user who never reopens the app stays covered.
      expect(dates.last.year - dates.first.year, greaterThanOrEqualTo(18));
    });

    test('skips years where the date does not exist', () {
      final cal = HebrewCalendarService();
      // Kislev has 29 or 30 days depending on the year, so ל' בכסלו is
      // genuinely absent in some of them. (Adar I is NOT such a case: in a
      // non-leap year it resolves onto the single Adar by design.)
      final m = _seed(id: 1, name: 'x', day: 30, month: HebrewMonth.kislev);
      final dates = cal.futureReminderDates(m, from: _fixedNow, years: 19);
      // ignore: avoid_print
      print('  30 Kislev over 19 years -> ${dates.length} reminders');
      expect(dates.length, lessThan(19), reason: 'some years lack the date');
      expect(dates, isNotEmpty);
      for (final d in dates) {
        expect(d.weekday, DateTime.tuesday);
      }
    });

    test('Adar I falls back onto the single Adar in non-leap years', () {
      final cal = HebrewCalendarService();
      final m = _seed(id: 1, name: 'x', day: 10, month: HebrewMonth.adarA);
      final dates = cal.futureReminderDates(m, from: _fixedNow, years: 19);
      expect(dates.length, greaterThanOrEqualTo(19),
          reason: 'must produce a reminder every year, leap or not');
    });

    test('id ranges never bleed into a neighbouring memorial', () {
      // A mistake here would cancel a different memorial's notifications.
      for (final memorialId in [1, 2, 7, 42, 1000]) {
        final base = Memorial.notificationIdBase(memorialId);
        final last = base + Memorial.notificationIdsPerMemorial - 1;

        expect(Memorial.ownsNotificationId(base, memorialId), isTrue);
        expect(Memorial.ownsNotificationId(last, memorialId), isTrue);
        expect(Memorial.ownsNotificationId(base - 1, memorialId), isFalse,
            reason: 'id just below the block leaked in');
        expect(Memorial.ownsNotificationId(last + 1, memorialId), isFalse,
            reason: 'id just above the block leaked in');

        // And it belongs to exactly one memorial.
        for (final other in [1, 2, 7, 42, 1000]) {
          if (other == memorialId) continue;
          expect(Memorial.ownsNotificationId(base, other), isFalse);
          expect(Memorial.ownsNotificationId(last, other), isFalse);
        }
      }
    });

    test('legacy raw ids fall in block 0, which no memorial can own', () {
      // Before the multi-year scheme the notification id was the raw memorial
      // id. Those survivors must be identifiable so an upgrade can clear them
      // instead of firing a duplicate alongside the new schedule.
      for (final legacyId in [1, 2, 7, 42, 99]) {
        expect(legacyId, lessThan(Memorial.notificationIdsPerMemorial));
        // SQLite AUTOINCREMENT starts at 1, so no memorial owns block 0.
        for (final memorialId in [1, 2, 7, 42]) {
          expect(Memorial.ownsNotificationId(legacyId, memorialId), isFalse,
              reason: 'legacy id $legacyId collided with memorial $memorialId');
        }
      }
      // The first real block starts above every legacy id.
      expect(Memorial.notificationIdBase(1),
          greaterThanOrEqualTo(Memorial.notificationIdsPerMemorial));
    });

    test('a full 20-year block stays inside the memorial range', () {
      final m = _seed(id: 7, name: 'x', day: 1, month: HebrewMonth.tishrei);
      for (var i = 0; i <= HebrewCalendarService.scheduleHorizonYears; i++) {
        expect(Memorial.ownsNotificationId(m.notificationIdForOccurrence(i), 7),
            isTrue,
            reason: 'occurrence $i escaped the block');
      }
      expect(HebrewCalendarService.scheduleHorizonYears,
          lessThan(Memorial.notificationIdsPerMemorial),
          reason: 'the horizon must fit inside one id block');
    });

    test('notification ids are unique per memorial and per occurrence', () {
      final a = _seed(id: 1, name: 'a', day: 1, month: HebrewMonth.tishrei);
      final b = _seed(id: 2, name: 'b', day: 1, month: HebrewMonth.tishrei);

      final ids = <int>{};
      for (var i = 0; i < Memorial.notificationIdsPerMemorial; i++) {
        expect(ids.add(a.notificationIdForOccurrence(i)), isTrue);
        expect(ids.add(b.notificationIdForOccurrence(i)), isTrue);
      }
      // The legacy single-shot id must still be the first occurrence.
      expect(a.notificationId, a.notificationIdForOccurrence(0));
      // Ranges must not overlap.
      expect(a.notificationIdForOccurrence(99),
          lessThan(b.notificationIdForOccurrence(0)));
    });
  });

  group('a missed reminder is delivered late, never skipped', () {
    // The window where the reminder Tuesday has passed but the memorial has
    // not — 5 to 11 days wide, every year, for every memorial.
    (Memorial, DateTime) inWindow(HebrewCalendarService cal, DateTime now) {
      for (final month in HebrewMonth.values) {
        for (var day = 1; day <= 29; day++) {
          final m = _seed(id: 1, name: 'x', day: day, month: month);
          final memorialDate = cal.nextMemorialDate(m, from: now);
          final reminder = cal.reminderDate(m, from: now);
          if (reminder.isBefore(now) && !memorialDate.isBefore(now)) {
            return (m, reminder);
          }
        }
      }
      throw StateError('no memorial inside the dead window');
    }

    test('reports a reminder that already passed and was never shown', () {
      final cal = HebrewCalendarService();
      final (m, reminder) = inWindow(cal, _fixedNow);

      final missed = cal.missedReminderDate(m, from: _fixedNow);
      expect(missed, isNotNull, reason: 'the reminder must not be dropped');
      expect(missed, equals(reminder));
      expect(missed!.isBefore(_fixedNow), isTrue);
    });

    test('reports nothing once it has been delivered', () {
      final cal = HebrewCalendarService();
      final (m, reminder) = inWindow(cal, _fixedNow);

      final alreadyShown = m.copyWith(lastNotifiedAt: reminder);
      expect(cal.missedReminderDate(alreadyShown, from: _fixedNow), isNull,
          reason: 'reopening the app must not re-notify');
    });

    test('a scheduled-then-fired reminder is not treated as missed', () {
      // The bug the user hit: the scheduled notification fires at 09:00, the
      // user opens the app at 09:01, and nothing had recorded the delivery —
      // so it looked missed and a duplicate went out. lastNotifiedAt is now
      // written at *schedule* time, which is what closes this.
      final cal = HebrewCalendarService();
      final (m, reminder) = inWindow(cal, _fixedNow);

      final asScheduled = m.copyWith(lastNotifiedAt: reminder);
      for (final minutesLater in [1, 60, 60 * 24]) {
        final after = reminder.add(Duration(minutes: minutesLater));
        expect(cal.missedReminderDate(asScheduled, from: after), isNull,
            reason: 'duplicate $minutesLater minutes after firing');
      }
    });

    test('an older delivery does not suppress this year', () {
      final cal = HebrewCalendarService();
      final (m, reminder) = inWindow(cal, _fixedNow);

      final lastYear =
          m.copyWith(lastNotifiedAt: reminder.subtract(const Duration(days: 365)));
      expect(cal.missedReminderDate(lastYear, from: _fixedNow),
          equals(reminder));
    });

    test('reports nothing when the reminder is still ahead', () {
      final cal = HebrewCalendarService();
      // Far from the window: a reminder comfortably in the future.
      final m = _seed(id: 1, name: 'x', day: 3, month: HebrewMonth.nisan);
      final reminder = cal.reminderDate(m, from: _fixedNow);
      expect(reminder.isAfter(_fixedNow), isTrue, reason: 'bad fixture');
      expect(cal.missedReminderDate(m, from: _fixedNow), isNull);
    });

    test('a disabled memorial is still reported by the calendar layer', () {
      // Suppression of disabled memorials belongs to NotificationService, so
      // the calendar must stay honest about the date itself.
      final cal = HebrewCalendarService();
      final (m, reminder) = inWindow(cal, _fixedNow);
      final off = m.copyWith(enabled: false);
      expect(cal.missedReminderDate(off, from: _fixedNow), equals(reminder));
    });
  });

  group('the list is ordered by the upcoming memorial date', () {
    /// Reads the card titles top to bottom.
    List<String> cardOrder(WidgetTester tester) => tester
        .widgetList<MemorialCard>(find.byType(MemorialCard))
        .map((c) => c.memorial.name)
        .toList();

    testWidgets('nearest memorial first, regardless of reminder offset',
        (tester) async {
      _phoneViewport(tester);
      final cal = HebrewCalendarService(now: () => _fixedNow);

      final seeds = [
        _seed(id: 1, name: 'רחוק', day: 3, month: HebrewMonth.nisan),
        _seed(id: 2, name: 'קרוב', day: 27, month: HebrewMonth.av),
        _seed(id: 3, name: 'אמצע', day: 14, month: HebrewMonth.cheshvan),
      ];
      await _pumpApp(tester, seeded: seeds);

      final expected = [...seeds]..sort((a, b) => cal
          .nextMemorialDate(a, from: _fixedNow)
          .compareTo(cal.nextMemorialDate(b, from: _fixedNow)));

      final actual = cardOrder(tester);
      // ignore: avoid_print
      for (final m in expected) {
        // ignore: avoid_print
        print('  ${cal.nextMemorialDate(m, from: _fixedNow)}  ${m.name}');
      }
      expect(actual, expected.map((m) => m.name).toList());
      expect(actual.first, 'קרוב');
      expect(actual.last, 'רחוק');
    });

    testWidgets('a memorial whose reminder already passed does not jump first',
        (tester) async {
      _phoneViewport(tester);
      // Inside the dead window for כ"ז באב: its reminder Tuesday (4/8) has
      // gone by, but the memorial itself (10/8) has not.
      final now = DateTime(2026, 8, 6, 12);
      final cal = HebrewCalendarService(now: () => now);

      final inWindow =
          _seed(id: 1, name: 'חלון', day: 27, month: HebrewMonth.av);
      expect(cal.daysUntilReminder(inWindow, from: now), lessThan(0),
          reason: 'fixture must be inside the window');

      // Falls later, but its reminder is still ahead — so sorting by reminder
      // would put it *after* the one whose reminder is already negative.
      final later =
          _seed(id: 2, name: 'מאוחר', day: 14, month: HebrewMonth.cheshvan);
      expect(cal.daysUntilReminder(later, from: now), greaterThan(0));
      expect(
          cal
              .nextMemorialDate(inWindow, from: now)
              .isBefore(cal.nextMemorialDate(later, from: now)),
          isTrue,
          reason: 'fixture: חלון must genuinely fall first');

      await _pumpApp(tester, seeded: [later, inWindow], now: now);

      // Ordered by memorial date, so the window one leads on its own merit.
      expect(cardOrder(tester), ['חלון', 'מאוחר']);
    });

    testWidgets('same date falls back to name, so the order is stable',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'ב', day: 14, month: HebrewMonth.cheshvan),
        _seed(id: 2, name: 'א', day: 14, month: HebrewMonth.cheshvan),
      ]);
      expect(cardOrder(tester), ['א', 'ב']);
    });
  });

  group('filter by how soon the memorial falls', () {
    List<String> cards(WidgetTester tester) => tester
        .widgetList<MemorialCard>(find.byType(MemorialCard))
        .map((c) => c.memorial.name)
        .toList();

    // Chosen against _fixedNow (2026-07-31) so the windows are unambiguous.
    List<Memorial> seeds(HebrewCalendarService cal) => [
          // כ"ז באב -> 10/08/2026, 10 days out: inside the month, not the week.
          _seed(id: 1, name: 'בחודש', day: 27, month: HebrewMonth.av),
          // י"ד בחשוון -> 25/10/2026: outside both.
          _seed(id: 2, name: 'רחוק', day: 14, month: HebrewMonth.cheshvan),
        ];

    test('the fixtures land where the test assumes', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final all = seeds(cal);
      expect(cal.daysUntilMemorial(all[0], from: _fixedNow), 10);
      expect(cal.daysUntilMemorial(all[1], from: _fixedNow),
          greaterThan(30));
    });

    test('isMemorialWithin is inclusive of the boundary', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);
      final days = cal.daysUntilMemorial(m, from: _fixedNow);

      expect(cal.isMemorialWithin(m, days, from: _fixedNow), isTrue,
          reason: 'exactly N days away must count as within N');
      expect(cal.isMemorialWithin(m, days - 1, from: _fixedNow), isFalse);
    });

    // Scoped to the chip: the empty-state hint text also contains "הכל",
    // which makes a bare textContaining finder ambiguous.
    Finder chipFor(MemorialFilter f) => find.ancestor(
          of: find.textContaining(f.label),
          matching: find.byType(FilterChip),
        );

    testWidgets('all / week / month narrow the list', (tester) async {
      _phoneViewport(tester);
      final cal = HebrewCalendarService(now: () => _fixedNow);
      await _pumpApp(tester, seeded: seeds(cal));

      // Default is unfiltered.
      expect(cards(tester), ['בחודש', 'רחוק']);

      await tester.tap(chipFor(MemorialFilter.month));
      await tester.pump(const Duration(milliseconds: 300));
      expect(cards(tester), ['בחודש']);

      await tester.tap(chipFor(MemorialFilter.week));
      await tester.pump(const Duration(milliseconds: 300));
      expect(cards(tester), isEmpty);
      expect(find.text('אין אזכרות בשבוע הקרוב'), findsOneWidget);
      // The empty state must not claim there are no memorials at all.
      expect(find.text('אין אזכרות עדיין'), findsNothing);
      // And the filter bar must stay reachable, or the user is stuck.
      expect(chipFor(MemorialFilter.all), findsOneWidget);

      await tester.tap(chipFor(MemorialFilter.all));
      await tester.pump(const Duration(milliseconds: 300));
      expect(cards(tester), ['בחודש', 'רחוק']);
    });

    testWidgets('each chip shows how many fall in its window', (tester) async {
      _phoneViewport(tester);
      final cal = HebrewCalendarService(now: () => _fixedNow);
      await _pumpApp(tester, seeded: seeds(cal));

      expect(find.text('הכל (2)'), findsOneWidget);
      expect(find.text('החודש (1)'), findsOneWidget);
      expect(find.text('השבוע (0)'), findsOneWidget);
    });

    testWidgets('no filter bar when there is nothing to filter',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.text('אין אזכרות עדיין'), findsOneWidget);
    });
  });

  group('a missing permission is never silent', () {
    final seed = [
      _seed(id: 1, name: 'סבא יעקב', day: 14, month: HebrewMonth.cheshvan),
    ];

    testWidgets('no warning when both permissions are granted',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: seed);
      expect(find.textContaining('ההתראות כבויות'), findsNothing);
      expect(find.textContaining('אזעקות מדויקות'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'תיקון'), findsNothing);
    });

    testWidgets('warns when notifications are disabled', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: seed, notificationsEnabled: false);
      expect(find.textContaining('ההתראות כבויות'), findsOneWidget);
      // The list is still usable underneath the banner.
      expect(find.text('סבא יעקב'), findsOneWidget);
    });

    testWidgets('warns when exact alarms are not allowed', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: seed, exactAlarmsAllowed: false);
      expect(find.textContaining('אזעקות מדויקות'), findsOneWidget);
    });

    testWidgets('the fix button requests and the warning clears',
        (tester) async {
      _phoneViewport(tester);
      final (_, notif) =
          await _pumpApp(tester, seeded: seed, notificationsEnabled: false);
      expect(find.textContaining('ההתראות כבויות'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'תיקון'));
      await _pumpUntilGone(
          tester, find.textContaining('ההתראות כבויות'), 'the warning');

      expect(notif.requestMissingCalls, 1);
    });
  });

  group('opening the app never produces a duplicate notification', () {
    testWidgets('scheduling records the nearest reminder on the memorial',
        (tester) async {
      _phoneViewport(tester);
      final nearest = DateTime(2026, 8, 4, 9);

      final repo = _InMemoryRepo()
        ..items.add(
            _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av));
      final notif = _FakeNotifications()..nearestScheduled = nearest;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memorialRepositoryProvider.overrideWithValue(repo),
            notificationServiceProvider.overrideWithValue(notif),
            hebrewCalendarServiceProvider.overrideWithValue(
              HebrewCalendarService(now: () => _fixedNow),
            ),
          ],
          child: const AzkarotApp(),
        ),
      );
      await _pumpUntilFound(
          tester, find.byType(MemorialCard), 'the memorial list');

      // Persisted, so a later open sees the reminder as handled.
      expect((await repo.getAll()).single.lastNotifiedAt, nearest);
    });

    testWidgets('a second open does not deliver a missed reminder',
        (tester) async {
      _phoneViewport(tester);
      final nearest = DateTime(2026, 8, 4, 9);
      final repo = _InMemoryRepo()
        ..items.add(_seed(
          id: 1,
          name: 'סבא יעקב',
          day: 27,
          month: HebrewMonth.av,
        ).copyWith(lastNotifiedAt: nearest));

      // Simulate the user opening the app right after the notification fired.
      final notif = _FakeNotifications()
        ..nearestScheduled = nearest
        ..missedToDeliver = null;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memorialRepositoryProvider.overrideWithValue(repo),
            notificationServiceProvider.overrideWithValue(notif),
            hebrewCalendarServiceProvider.overrideWithValue(
              HebrewCalendarService(now: () => nearest.add(const Duration(minutes: 1))),
            ),
          ],
          child: const AzkarotApp(),
        ),
      );
      await _pumpUntilFound(
          tester, find.byType(MemorialCard), 'the memorial list');

      expect(notif.log.where((e) => e.startsWith('missed:')), isEmpty,
          reason: 'no catch-up notification may be delivered');
    });
  });

  group('configurable reminder timing', () {
    test('the default is still Tuesday of the week before', () {
      final cal = HebrewCalendarService();
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      expect(m.reminderMode, ReminderMode.weekdayOfPreviousWeek);
      expect(m.reminderValue, DateTime.tuesday);
      expect(cal.reminderDate(m, from: _fixedNow).weekday, DateTime.tuesday);
    });

    test('every weekday choice lands on that weekday, a week earlier', () {
      final cal = HebrewCalendarService();
      for (final weekday in hebrewWeekdayNames.keys) {
        final m = _seed(
          id: 1,
          name: 'x',
          day: 27,
          month: HebrewMonth.av,
          reminderValue: weekday,
        );
        final reminder = cal.reminderDate(m, from: _fixedNow);
        expect(reminder.weekday, weekday,
            reason: 'asked for ${hebrewWeekdayNames[weekday]}');

        final memorialDate = cal.nextMemorialDate(m, from: _fixedNow);
        expect(reminder.isBefore(memorialDate), isTrue,
            reason: 'reminder must precede the memorial');
      }
    });

    test('fixedDaysBefore gives exactly that many calendar days', () {
      final cal = HebrewCalendarService();
      for (final days in const [1, 3, 7, 14, 30]) {
        final m = _seed(
          id: 1,
          name: 'x',
          day: 27,
          month: HebrewMonth.av,
          reminderMode: ReminderMode.fixedDaysBefore,
          reminderValue: days,
        );
        final memorialDate = cal.nextMemorialDate(m, from: _fixedNow);
        final reminder = cal.reminderDate(m, from: _fixedNow);

        final gap = DateTime.utc(
                memorialDate.year, memorialDate.month, memorialDate.day)
            .difference(
                DateTime.utc(reminder.year, reminder.month, reminder.day))
            .inDays;
        expect(gap, days, reason: 'asked for $days days before');
      }
    });

    test('fixedDaysBefore survives DST and month boundaries', () {
      final cal = HebrewCalendarService();
      final m = _seed(
        id: 1,
        name: 'x',
        day: 1,
        month: HebrewMonth.nisan,
        reminderMode: ReminderMode.fixedDaysBefore,
        reminderValue: 30,
      );
      // Scan several years so a March transition is included.
      for (final d in cal.futureReminderDates(m, from: _fixedNow, years: 6)) {
        expect(d.hour, m.notificationHour, reason: 'hour drifted at $d');
      }
    });
  });

  group('burial location and photo', () {
    test('burialSearchQuery joins the parts, or is null when empty', () {
      Memorial at({String? cemetery, String? plot}) => _seed(
            id: 1,
            name: 'x',
            day: 1,
            month: HebrewMonth.tishrei,
            cemetery: cemetery,
            plot: plot,
          );

      expect(at(cemetery: 'ירקון', plot: 'חלקה 12').burialSearchQuery,
          'ירקון, חלקה 12');
      expect(at(cemetery: 'ירקון').burialSearchQuery, 'ירקון');
      expect(at(plot: 'חלקה 12').burialSearchQuery, 'חלקה 12');
      expect(at().burialSearchQuery, isNull);
      // Whitespace-only must not produce a query to navigate to.
      expect(at(cemetery: '  ', plot: '  ').burialSearchQuery, isNull);
    });

    testWidgets('the card shows the location with a navigate button',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(
          id: 1,
          name: 'עם מיקום',
          day: 14,
          month: HebrewMonth.cheshvan,
          cemetery: 'ירקון',
          plot: "גוש ה', חלקה 12",
        ),
        _seed(id: 2, name: 'בלי מיקום', day: 3, month: HebrewMonth.nisan),
      ]);

      expect(find.text("ירקון, גוש ה', חלקה 12"), findsOneWidget);
      // Exactly one navigate button: the memorial without a location has none.
      expect(find.byIcon(Icons.navigation_outlined), findsOneWidget);
    });

    testWidgets('a missing photo file falls back to the candle',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(
          id: 1,
          name: 'תמונה חסרה',
          day: 14,
          month: HebrewMonth.cheshvan,
          photoPath: r'C:\definitely\not\here.jpg',
        ),
      ]);
      // Rendering must not throw on a path that no longer exists.
      expect(tester.takeException(), isNull);
      expect(find.text('🕯'), findsOneWidget);
    });
  });

  group('photos survive a backup round trip', () {
    /// A real PNG of [size]x[size], produced through the same engine the app
    /// uses — decoding a hand-rolled byte array would prove nothing.
    Future<Uint8List> makePng(int size) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
        Paint()..color = const Color(0xFF5B4B8A),
      );
      final image =
          await recorder.endRecording().toImage(size, size);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    }

    Future<({int width, int height})> dimensions(Uint8List bytes) async {
      final d = await ui.ImageDescriptor.encoded(
        await ui.ImmutableBuffer.fromUint8List(bytes),
      );
      final result = (width: d.width, height: d.height);
      d.dispose();
      return result;
    }

    // runAsync throughout: image encode/decode is real engine work, and the
    // faked clock inside testWidgets deadlocks waiting on it.
    testWidgets('a large photo is downscaled before storage',
        (tester) async {
      await tester.runAsync(() async {
        const store = PhotoStore();
        final big = await makePng(1200);
        expect((await dimensions(big)).width, 1200);

        final small = await store.downscale(big);
        final dims = await dimensions(small);

        expect(dims.width, PhotoStore.maxDimension);
        expect(dims.height, PhotoStore.maxDimension);
        expect(small.lengthInBytes, lessThan(big.lengthInBytes),
            reason: 'downscaling must actually shrink the payload');
      });
    });

    testWidgets('an already-small photo is left untouched', (tester) async {
      await tester.runAsync(() async {
        const store = PhotoStore();
        final small = await makePng(64);
        final result = await store.downscale(small);
        // Identical bytes: no pointless re-encode.
        expect(identical(result, small), isTrue);
      });
    });

    testWidgets('base64 helpers round-trip and tolerate junk',
        (tester) async {
      await tester.runAsync(() async {
        const store = PhotoStore();

        expect(await store.readAsBase64(null), isNull);
        expect(await store.readAsBase64(''), isNull);
        expect(await store.readAsBase64(r'C:\nope\missing.png'), isNull);

        expect(await store.restoreFromBase64(null), isNull);
        expect(await store.restoreFromBase64(''), isNull);
        // A corrupt backup must not take the whole import down.
        expect(await store.restoreFromBase64('!!!not base64!!!'), isNull);
      });
    });

    test('export strips the local path and carries the image instead', () {
      // The path is meaningless on another device; photo_data is what travels.
      final m = _seed(
        id: 1,
        name: 'x',
        day: 1,
        month: HebrewMonth.tishrei,
        photoPath: r'C:\device\a\b.png',
      );
      final exported = m.toJson()..remove('photo_path');
      exported['photo_data'] = 'AAAA';

      final restored = Memorial.fromJson(exported);
      expect(restored.photoPath, isNull,
          reason: 'a foreign path must never be trusted');
      expect(exported['photo_data'], 'AAAA');
    });
  });

  group('notification snooze action', () {
    test('the actions are declared with the ids the handler understands', () {
      // A mismatch here would make the buttons appear and do nothing.
      expect(NotificationService.snoozeDays.keys,
          containsAll([NotificationService.snooze3Days,
                       NotificationService.snooze7Days]));
      expect(NotificationService.snoozeDays[NotificationService.snooze3Days], 3);
      expect(NotificationService.snoozeDays[NotificationService.snooze7Days], 7);
    });
  });

  group('notes appear on the card', () {
    testWidgets('shown when present, hidden when blank', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(
          id: 1,
          name: 'עם הערה',
          day: 14,
          month: HebrewMonth.cheshvan,
          notes: 'בית עלמין ירקון, חלקה 12',
        ),
        _seed(id: 2, name: 'בלי הערה', day: 3, month: HebrewMonth.nisan),
        _seed(
          id: 3,
          name: 'הערה ריקה',
          day: 10,
          month: HebrewMonth.av,
          notes: '   ',
        ),
      ]);

      expect(find.text('בית עלמין ירקון, חלקה 12'), findsOneWidget);
      // Exactly one notes row: whitespace-only notes must not render one.
      expect(find.text('הערות: '), findsOneWidget);
    });

    testWidgets('a very long note does not overflow the card',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(
          id: 1,
          name: 'הערה ארוכה',
          day: 14,
          month: HebrewMonth.cheshvan,
          notes: 'טקסט ארוך מאוד ' * 40,
        ),
      ]);
      // A RenderFlex overflow would have been thrown during layout.
      expect(tester.takeException(), isNull);
    });
  });

  group('the form clears the system navigation bar', () {
    testWidgets('save and cancel sit above the bottom inset', (tester) async {
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = const Size(824, 1648);
      // A phone with on-screen navigation buttons: 48dp at dpr 2.
      tester.view.viewPadding = const FakeViewPadding(bottom: 96);
      tester.view.padding = const FakeViewPadding(bottom: 96);
      addTearDown(tester.view.reset);

      await _pumpApp(tester);
      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(HebrewDatePicker), 'the add screen');

      // Asserted on the padding rather than by scrolling to the button:
      // the form is a lazy ListView, so scrolling assertions are brittle,
      // while the padding is exactly what the fix changes.
      final list = tester.widget<ListView>(find.byType(ListView));
      // 96 physical px / dpr 2 = 48 logical px of navigation bar, + 24 base.
      expect(list.padding, const EdgeInsets.fromLTRB(16, 16, 16, 24 + 48));
    });

    testWidgets('no wasted gap when there is no inset', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);
      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(HebrewDatePicker), 'the add screen');

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.padding, const EdgeInsets.fromLTRB(16, 16, 16, 24),
          reason: 'padding grew even without a navigation bar');
    });
  });

  group('screenshots', () {
    testWidgets('home with data (light)', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 14, month: HebrewMonth.cheshvan),
        _seed(id: 2, name: 'סבתא רחל', day: 3, month: HebrewMonth.nisan),
        _seed(
          id: 3,
          name: 'דוד משה',
          day: 10,
          month: HebrewMonth.adar,
          enabled: false,
        ),
      ]);
      await expectLater(
        find.byType(AzkarotApp),
        matchesGoldenFile('goldens/01_home_light.png'),
      );
    });

    testWidgets('home with data (dark)', (tester) async {
      _phoneViewport(tester);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 14, month: HebrewMonth.cheshvan),
        _seed(id: 2, name: 'סבתא רחל', day: 3, month: HebrewMonth.nisan),
      ]);
      await expectLater(
        find.byType(AzkarotApp),
        matchesGoldenFile('goldens/02_home_dark.png'),
      );
    });

    testWidgets('empty state', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);
      expect(find.text('אין אזכרות עדיין'), findsOneWidget);
      await expectLater(
        find.byType(AzkarotApp),
        matchesGoldenFile('goldens/03_empty.png'),
      );
    });

    testWidgets('add screen with the Hebrew wheel picker', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);

      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(HebrewDatePicker), 'the add screen');

      expect(find.byType(CupertinoPicker), findsNWidgets(2));
      await expectLater(
        find.byType(AzkarotApp),
        matchesGoldenFile('goldens/04_add_picker.png'),
      );
    });

    testWidgets('settings screen', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.byType(SettingsScreen), 'SettingsScreen');

      await expectLater(
        find.byType(AzkarotApp),
        matchesGoldenFile('goldens/05_settings.png'),
      );
    });
  });

  group('drive the app', () {
    testWidgets('add a memorial end to end, and it gets scheduled',
        (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester);

      expect(find.text('אין אזכרות עדיין'), findsOneWidget);
      notif.log.clear();

      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(HebrewDatePicker), 'the add screen');

      await tester.enterText(
          find.byType(TextFormField).first, 'סבתא מרים');
      await tester.pump(const Duration(milliseconds: 100));

      final save = find.widgetWithText(FilledButton, 'שמירה');
      await _revealInForm(tester, save);
      await tester.tap(save);
      await _pumpUntilFound(
          tester, find.text('סבתא מרים'), 'the saved card on the list');

      // Persisted through the repository contract.
      final saved = await repo.getAll();
      expect(saved, hasLength(1));
      expect(saved.single.name, 'סבתא מרים');
      // Default wheel position is 1 Tishrei.
      expect(saved.single.hebrewDay, 1);
      expect(saved.single.selectedMonth, HebrewMonth.tishrei);

      // And the notification chain fired for it.
      expect(notif.log.where((e) => e.startsWith('schedule:')).toList(),
          contains('schedule:סבתא מרים'));

      // Let the pop transition finish, otherwise the add route is still
      // mounted and its picker preview double-counts the date text.
      for (var i = 0;
          i < 40 && find.byType(HebrewDatePicker).evaluate().isNotEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Back on the list, showing the formatted Hebrew date.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(HebrewDatePicker), findsNothing);
      expect(find.text("א' בתשרי"), findsOneWidget);

      await expectLater(
        find.byType(AzkarotApp),
        matchesGoldenFile('goldens/06_after_add.png'),
      );
    });

    testWidgets('editing a memorial saves and reschedules it', (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 14, month: HebrewMonth.cheshvan),
      ]);
      notif.log.clear();

      await tester.tap(find.text('סבא יעקב'));
      await _pumpUntilFound(
          tester, find.byType(EditMemorialScreen), 'EditMemorialScreen');

      // The form opens populated from the existing record.
      expect(find.widgetWithText(TextFormField, 'סבא יעקב'), findsOneWidget);
      expect(find.text("י\"ד בחשוון"), findsWidgets);

      await tester.enterText(
          find.byType(TextFormField).first, 'סבא יעקב זצ"ל');
      await tester.pump(const Duration(milliseconds: 100));

      final save = find.widgetWithText(FilledButton, 'שמירה');
      await _revealInForm(tester, save);
      await tester.tap(save);
      await _pumpUntilFound(
          tester, find.text('סבא יעקב זצ"ל'), 'the renamed card');

      final saved = await repo.getAll();
      expect(saved, hasLength(1), reason: 'edit must not create a second row');
      expect(saved.single.id, 1, reason: 'the id must be preserved');
      expect(saved.single.name, 'סבא יעקב זצ"ל');
      // The date is unchanged, so the reminder is recomputed for the same day.
      expect(saved.single.hebrewDay, 14);
      expect(notif.log, contains('schedule:סבא יעקב זצ"ל'));
    });

    testWidgets('turning the form switch off saves it disabled and cancels',
        (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 14, month: HebrewMonth.cheshvan),
      ]);
      notif.log.clear();

      await tester.tap(find.text('סבא יעקב'));
      await _pumpUntilFound(
          tester, find.byType(EditMemorialScreen), 'EditMemorialScreen');

      final toggle = find.byType(SwitchListTile);
      await _revealInForm(tester, toggle);
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 300));

      final save = find.widgetWithText(FilledButton, 'שמירה');
      await _revealInForm(tester, save);
      await tester.tap(save);
      await _pumpUntilFound(
          tester, find.text('ההתראה כבויה'), 'the disabled card');

      expect((await repo.getAll()).single.enabled, isFalse);
      expect(notif.log.any((e) => e.startsWith('cancel:')), isTrue);
      expect(notif.log.any((e) => e.startsWith('schedule:')), isFalse,
          reason: 'a memorial saved as disabled must not be scheduled');
    });

    testWidgets('deleting asks first, then removes and cancels',
        (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 14, month: HebrewMonth.cheshvan),
        _seed(id: 2, name: 'סבתא רחל', day: 3, month: HebrewMonth.nisan),
      ]);
      notif.log.clear();

      await tester.tap(find.text('סבא יעקב'));
      await _pumpUntilFound(
          tester, find.byType(EditMemorialScreen), 'EditMemorialScreen');

      await tester.tap(find.byIcon(Icons.delete_outline));
      await _pumpUntilFound(
          tester, find.text('מחיקת אזכרה'), 'the delete confirmation');
      expect(find.text('למחוק את האזכרה של סבא יעקב?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'מחיקה'));
      await _pumpUntilFound(tester, find.byType(HomeScreen), 'HomeScreen');
      for (var i = 0;
          i < 40 && find.byType(EditMemorialScreen).evaluate().isNotEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final left = await repo.getAll();
      expect(left, hasLength(1));
      expect(left.single.name, 'סבתא רחל');
      expect(notif.log, contains('cancel:1'));
      expect(find.text('סבא יעקב'), findsNothing);
      expect(find.text('סבתא רחל'), findsOneWidget);
    });

    testWidgets('cancelling the delete dialog changes nothing', (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 14, month: HebrewMonth.cheshvan),
      ]);
      notif.log.clear();

      await tester.tap(find.text('סבא יעקב'));
      await _pumpUntilFound(
          tester, find.byType(EditMemorialScreen), 'EditMemorialScreen');

      await tester.tap(find.byIcon(Icons.delete_outline));
      await _pumpUntilFound(
          tester, find.text('מחיקת אזכרה'), 'the delete confirmation');

      await tester.tap(find.widgetWithText(TextButton, 'ביטול'));
      await _pumpUntilGone(
          tester, find.text('מחיקת אזכרה'), 'the delete confirmation');

      expect(await repo.getAll(), hasLength(1));
      expect(notif.log, isEmpty, reason: 'cancelling must touch nothing');
      // Dismissed the dialog, not the screen.
      expect(find.byType(EditMemorialScreen), findsOneWidget);
    });

    testWidgets('toggling the switch off cancels and shows it disabled',
        (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 14, month: HebrewMonth.cheshvan),
      ]);
      notif.log.clear();

      await tester.tap(find.byType(Switch));
      await _pumpUntilFound(
          tester, find.text('ההתראה כבויה'), 'the disabled label');

      expect((await repo.getAll()).single.enabled, isFalse);
      expect(notif.log.any((e) => e.startsWith('cancel:')), isTrue);
      expect(notif.log.any((e) => e.startsWith('schedule:')), isFalse,
          reason: 'a disabled memorial must not be rescheduled');
    });
  });
}
