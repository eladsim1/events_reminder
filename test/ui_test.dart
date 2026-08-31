/// Runs the real app without an Android device: renders every screen against an
/// in-memory repository and a recording notification stub, and drives the
/// add-memorial and toggle flows end to end through the provider layer.
///
/// The rendered screens show "days until the reminder", so the calendar
/// service is pumped with a pinned clock ([_fixedNow]) — otherwise every
/// golden would fail a day later. Refresh them with:
///   flutter test test/ui_test.dart --update-goldens
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show NotificationResponse, NotificationResponseType;
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
import 'package:azkarot_app/screens/splash_screen.dart';
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

  /// When true, scheduling and cancellation hang until released — used to
  /// prove the UI does not await them.
  bool blockScheduling = false;
  bool schedulingStarted = false;
  Completer<void>? _gate;

  Future<void> _maybeBlock() async {
    if (!blockScheduling) return;
    _gate ??= Completer<void>();
    await _gate!.future;
  }

  void releaseScheduling() {
    if (_gate != null && !_gate!.isCompleted) _gate!.complete();
    blockScheduling = false;
  }

  /// The nearest reminder the fake claims to have scheduled. Tests that care
  /// about the duplicate-notification guard set this.
  DateTime? nearestScheduled;

  @override
  Future<DateTime?> scheduleForMemorial(Memorial memorial) async {
    schedulingStarted = true;
    await _maybeBlock();
    if (memorial.id == null) return null;
    log.add('cancel:${memorial.id}');
    if (!memorial.enabled) return null;
    log.add('schedule:${memorial.name}');
    return nearestScheduled;
  }

  @override
  Future<void> cancelForMemorial(int memorialId) async {
    await _maybeBlock();
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

  /// Set by a test to simulate the app being launched by "more options".
  ReminderChoiceRequest? pendingChoice;

  @override
  Future<ReminderChoiceRequest?> pendingChoiceRequest() async => pendingChoice;

  @override
  Future<bool> rescheduleReminder({
    required ReminderChoiceRequest request,
    required int daysBefore,
  }) async {
    log.add('reschedule:$daysBefore');
    return true;
  }

  /// Set by a test to simulate a reminder that was missed and needs delivering.
  /// Left null, this is a no-op — which is what every other test wants.
  DateTime? missedToDeliver;

  @override
  Future<DateTime?> deliverMissedReminder(Memorial memorial) async {
    final missed = missedToDeliver;
    if (missed == null || !memorial.enabled) return null;
    // Mirrors HebrewCalendarService.missedReminderDate: a reminder already
    // accounted for is never delivered a second time.
    final last = memorial.lastNotifiedAt;
    if (last != null && !last.isBefore(missed)) return null;
    // A real delivery crosses the platform channel. Yielding here is what
    // lets a second, concurrent sync interleave - which is the whole bug.
    await Future<void>.delayed(Duration.zero);
    log.add('missed:${memorial.name}');
    return missed;
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
  int? deathHebrewYear,
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
    deathHebrewYear: deathHebrewYear,
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
  ReminderChoiceRequest? pendingChoice,
}) async {
  final repo = _InMemoryRepo()..items.addAll(seeded);
  final notif = _FakeNotifications()
    ..notificationsEnabled = notificationsEnabled
    ..exactAlarmsAllowed = exactAlarmsAllowed
    ..pendingChoice = pendingChoice;
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

  group('search by name', () {
    List<String> cards(WidgetTester tester) => tester
        .widgetList<MemorialCard>(find.byType(MemorialCard))
        .map((c) => c.memorial.name)
        .toList();

    Future<void> search(WidgetTester tester, String q) async {
      await tester.enterText(find.byType(TextField).first, q);
      await tester.pump(const Duration(milliseconds: 300));
    }

    test('matching is partial, trimmed, and empty matches everything', () {
      final m = _seed(id: 1, name: 'סבא יעקב', day: 1,
          month: HebrewMonth.tishrei);

      expect(m.matchesQuery(''), isTrue, reason: 'empty must not hide rows');
      expect(m.matchesQuery('   '), isTrue);
      expect(m.matchesQuery('יעקב'), isTrue);
      expect(m.matchesQuery('סבא'), isTrue);
      expect(m.matchesQuery('  יעקב  '), isTrue, reason: 'must trim');
      expect(m.matchesQuery('בא יע'), isTrue, reason: 'substring, not prefix');
      expect(m.matchesQuery('רחל'), isFalse);
    });

    test('latin names ignore case', () {
      final m = _seed(id: 1, name: 'Jacob', day: 1, month: HebrewMonth.tishrei);
      expect(m.matchesQuery('jacob'), isTrue);
      expect(m.matchesQuery('JAC'), isTrue);
    });

    testWidgets('the search field filters the list and clears again',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
        _seed(id: 2, name: 'סבתא רחל', day: 3, month: HebrewMonth.nisan),
        _seed(id: 3, name: 'דוד משה', day: 14, month: HebrewMonth.cheshvan),
      ]);
      expect(cards(tester), hasLength(3));

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump(const Duration(milliseconds: 300));

      await search(tester, 'סב');
      expect(cards(tester), ['סבא יעקב', 'סבתא רחל']);

      await search(tester, 'רחל');
      expect(cards(tester), ['סבתא רחל']);

      // Closing search restores the full list.
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await tester.pump(const Duration(milliseconds: 300));
      expect(cards(tester), hasLength(3));
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('a miss says so, and does not claim the list is empty',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump(const Duration(milliseconds: 300));
      await search(tester, 'זזזז');

      expect(cards(tester), isEmpty);
      expect(find.textContaining('לא נמצאה אזכרה בשם'), findsOneWidget);
      expect(find.text('אין אזכרות עדיין'), findsNothing);
    });

    testWidgets('the chip counts follow the search', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
        _seed(id: 2, name: 'סבתא רחל', day: 3, month: HebrewMonth.nisan),
      ]);
      expect(find.text('הכל (2)'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump(const Duration(milliseconds: 300));
      await search(tester, 'רחל');

      // Otherwise "הכל (2)" beside a single visible row reads as a bug.
      expect(find.text('הכל (1)'), findsOneWidget);
    });
  });

  group('reminder text and the day-before reminder', () {
    test('the description names the weekday, date and countdown', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      final reminder = cal.futureReminderDates(m, from: _fixedNow).first;
      final memorialDate = cal.memorialDateForReminder(m, reminder)!;
      final text =
          cal.describeMemorialForReminder(m, reminder, memorialDate);

      // ignore: avoid_print
      print('  reminder $reminder -> "$text" (memorial $memorialDate)');
      expect(text, startsWith('יום '));
      expect(text, contains('/'));
      expect(text, contains('בעוד'));
    });

    test('the countdown is measured from the firing date, not from today', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      // A far-future occurrence: if "today" leaked in, the number would be
      // in the hundreds instead of the 5..11 the rule produces.
      final reminders = cal.futureReminderDates(m, from: _fixedNow);
      final late = reminders[5];
      final memorialDate = cal.memorialDateForReminder(m, late)!;
      final text = cal.describeMemorialForReminder(m, late, memorialDate);

      final days = int.parse(RegExp(r'(\d+) ימים').firstMatch(text)!.group(1)!);
      expect(days, inInclusiveRange(5, 11), reason: text);
    });

    test('every weekday name resolves, including Shabbat', () {
      // The memorial can fall on any day; only the *reminder* excludes it.
      for (var wd = 1; wd <= 7; wd++) {
        expect(hebrewWeekdayNames[wd], isNotNull, reason: 'weekday $wd');
      }
      expect(hebrewWeekdayNames[DateTime.saturday], 'שבת');
      expect(reminderWeekdayChoices, isNot(contains(DateTime.saturday)));
      expect(reminderWeekdayChoices, hasLength(6));
    });

    test('day-before dates are one day before, at 09:00', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      final dates = cal.dayBeforeMemorialDates(m, from: _fixedNow, years: 20);
      expect(dates, isNotEmpty);

      for (final d in dates) {
        expect(d.hour, HebrewCalendarService.dayBeforeReminderHour);
        expect(d.minute, 0);
        expect(d.isAfter(_fixedNow), isTrue);

        final memorialDate = cal.memorialDateForReminder(m, d)!;
        // Exactly one calendar day, measured in UTC so DST cannot shave it.
        final gap = DateTime.utc(
                memorialDate.year, memorialDate.month, memorialDate.day)
            .difference(DateTime.utc(d.year, d.month, d.day))
            .inDays;
        expect(gap, 1, reason: 'reminder $d vs memorial $memorialDate');
      }
    });

    test('the day-before text reads as tomorrow', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      final d = cal.dayBeforeMemorialDates(m, from: _fixedNow).first;
      final memorialDate = cal.memorialDateForReminder(m, d)!;
      expect(cal.describeMemorialForReminder(m, d, memorialDate),
          contains('מחר'));
    });

    test('the two series occupy separate id ranges', () {
      final m = _seed(id: 3, name: 'x', day: 1, month: HebrewMonth.tishrei);

      final main = [
        for (var i = 0; i <= HebrewCalendarService.scheduleHorizonYears; i++)
          m.notificationIdForOccurrence(i)
      ];
      final dayBefore = [
        for (var i = 0; i <= HebrewCalendarService.scheduleHorizonYears; i++)
          m.notificationIdForDayBefore(i)
      ];

      // No overlap — otherwise one series would silently overwrite the other.
      expect(main.toSet().intersection(dayBefore.toSet()), isEmpty);
      // And neither collides with the catch-up slot.
      final catchUp = m.notificationIdForOccurrence(Memorial.catchUpIndex);
      expect(main, isNot(contains(catchUp)));
      expect(dayBefore, isNot(contains(catchUp)));
      // Everything stays inside this memorial's block.
      for (final id in [...main, ...dayBefore, catchUp]) {
        expect(Memorial.ownsNotificationId(id, 3), isTrue);
      }
    });
  });

  group('year of death', () {
    test('is optional and reports no yahrzeit number without it', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      expect(m.deathHebrewYear, isNull);
      expect(cal.yahrzeitNumber(m, from: _fixedNow), isNull);
    });

    test('counts from the death year to the upcoming occurrence', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      // כ"ז באב falls in 5786 on _fixedNow.
      final occurrenceYear = cal
          .nextMemorialOccurrence(
            _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av),
            from: _fixedNow,
          )!
          .hebrewYear;

      for (final n in [1, 2, 5, 20]) {
        final m = _seed(
          id: 1,
          name: 'x',
          day: 27,
          month: HebrewMonth.av,
          deathHebrewYear: occurrenceYear - n,
        );
        expect(cal.yahrzeitNumber(m, from: _fixedNow), n);
      }
    });

    test('a death year at or after the occurrence yields nothing', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final occurrenceYear = cal
          .nextMemorialOccurrence(
            _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av),
            from: _fixedNow,
          )!
          .hebrewYear;

      for (final year in [occurrenceYear, occurrenceYear + 1]) {
        final m = _seed(
          id: 1,
          name: 'x',
          day: 27,
          month: HebrewMonth.av,
          deathHebrewYear: year,
        );
        expect(cal.yahrzeitNumber(m, from: _fixedNow), isNull,
            reason: 'a nonsensical count must not be shown');
      }
    });

    test('the picker offers only past years, newest first', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final years = cal.deathYearChoices(span: 10);

      expect(years, hasLength(10));
      expect(years.first, greaterThan(years.last));
      expect(years.first, cal.currentHebrewYear());
      // In gematria, never digits.
      expect(cal.formatHebrewYear(years.first), isNot(matches(RegExp(r'\d'))));
    });

    testWidgets('the card shows the year and which yahrzeit it is',
        (tester) async {
      _phoneViewport(tester);
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final occurrenceYear = cal
          .nextMemorialOccurrence(
            _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av),
            from: _fixedNow,
          )!
          .hebrewYear;

      await _pumpApp(tester, seeded: [
        _seed(
          id: 1,
          name: 'עם שנה',
          day: 27,
          month: HebrewMonth.av,
          deathHebrewYear: occurrenceYear - 3,
        ),
        _seed(id: 2, name: 'בלי שנה', day: 3, month: HebrewMonth.nisan),
      ]);

      expect(find.text('האזכרה השלישית'), findsOneWidget);
      expect(
          find.textContaining(
              'נפטר בשנת ${cal.formatHebrewYear(occurrenceYear - 3)}'),
          findsOneWidget);
      // The memorial without a year must show neither.
      expect(find.textContaining('נפטר בשנת'), findsOneWidget);
      expect(find.text('מספר האזכרה: '), findsOneWidget);
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
      for (final weekday in reminderWeekdayChoices) {
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
      // Scoped to the card: the app bar carries a candle of its own.
      expect(
        find.descendant(
          of: find.byType(MemorialCard),
          matching: find.text('🕯'),
        ),
        findsOneWidget,
      );
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

  group('saving never waits on notification scheduling', () {
    testWidgets('the add screen closes before scheduling finishes',
        (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester);

      // A fake whose scheduling never completes. If saving awaited it, the
      // add screen would stay open forever — which is the 15s freeze the
      // user hit, only unbounded.
      notif.blockScheduling = true;

      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(HebrewDatePicker), 'the add screen');

      await tester.enterText(find.byType(TextFormField).first, 'סבתא מרים');
      await tester.pump(const Duration(milliseconds: 100));

      final save = find.widgetWithText(FilledButton, 'שמירה');
      await _revealInForm(tester, save);
      await tester.tap(save);

      // The row is already persisted and the list is already showing it.
      await _pumpUntilFound(
          tester, find.text('סבתא מרים'), 'the saved card on the list');
      expect((await repo.getAll()).single.name, 'סבתא מרים');
      expect(notif.schedulingStarted, isTrue,
          reason: 'scheduling should have been kicked off, just not awaited');

      notif.releaseScheduling();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('deleting closes before cancellation finishes',
        (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);
      notif.blockScheduling = true;

      await tester.tap(find.text('סבא יעקב'));
      await _pumpUntilFound(
          tester, find.byType(EditMemorialScreen), 'EditMemorialScreen');
      await tester.tap(find.byIcon(Icons.delete_outline));
      await _pumpUntilFound(
          tester, find.text('מחיקת אזכרה'), 'the delete confirmation');
      await tester.tap(find.widgetWithText(FilledButton, 'מחיקה'));

      await _pumpUntilFound(tester, find.byType(HomeScreen), 'HomeScreen');
      expect(await repo.getAll(), isEmpty);

      notif.releaseScheduling();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('the reminder offers a choice of how long before the memorial', () {
    final memorial = DateTime(2026, 8, 20, 0, 0);

    test('an action id round-trips to its number of days', () {
      for (final d in NotificationService.snoozeChoiceLadder) {
        final id = NotificationService.rescheduleActionIdFor(d);
        expect(NotificationService.daysBeforeFromActionId(id), d, reason: id);
      }
      expect(NotificationService.daysBeforeFromActionId(null), isNull);
      // A plain tap on the notification body carries no action id, and an
      // unknown one must not be mistaken for a choice.
      expect(NotificationService.daysBeforeFromActionId(''), isNull);
      expect(NotificationService.daysBeforeFromActionId('snooze'), isNull);
      // Off the ladder: a value the notification never offered.
      expect(NotificationService.daysBeforeFromActionId('reschedule:4'), isNull);
      expect(NotificationService.daysBeforeFromActionId('reschedule:x'), isNull);
    });

    test('labels read naturally in Hebrew', () {
      expect(NotificationService.snoozeChoiceLabel(1), 'יום לפני');
      expect(NotificationService.snoozeChoiceLabel(2), 'יומיים לפני');
      expect(NotificationService.snoozeChoiceLabel(7), 'שבוע לפני');
      expect(NotificationService.snoozeChoiceLabel(3), '3 ימים לפני');
    });

    test('every offered choice lands before the memorial and in the future',
        () {
      for (final daysOut in [1, 2, 5, 12, 40]) {
        final now = DateTime(
            memorial.year, memorial.month, memorial.day - daysOut, 8);
        final choices = NotificationService.choicesBefore(memorial, now);

        for (final d in choices) {
          final when = DateTime(memorial.year, memorial.month,
              memorial.day - d, HebrewCalendarService.dayBeforeReminderHour);
          expect(when.isAfter(now), isTrue,
              reason: '$d days before is already in the past');
          // "Up to the day of the memorial, and not after" - the morning of
          // the memorial itself counts, a later day never does.
          expect(DateTime(when.year, when.month, when.day)
              .isAfter(DateTime(memorial.year, memorial.month, memorial.day)),
              isFalse,
              reason: '$d days before overshoots the memorial');
        }
      }
    });

    test('the list shrinks as the memorial approaches, then empties', () {
      List<int> at(int daysOut) => NotificationService.choicesBefore(
            memorial,
            DateTime(memorial.year, memorial.month, memorial.day - daysOut, 8),
          );

      expect(at(40).length, greaterThan(at(12).length));
      expect(at(12).length, greaterThan(at(5).length));
      // 5 is still offered at five days out: the target is 09:00 and "now"
      // here is 08:00, so it is an hour away, not in the past.
      expect(at(5), [0, 1, 2, 3, 5]);
      expect(at(2), [0, 1, 2]);
      // The morning of the memorial is still ahead at 08:00, so it stands as
      // the last thing left to choose.
      expect(at(0), [0]);
    });

    test('the payload carries the memorial date through the isolate', () {
      // The background isolate has no database, so without this it could not
      // work out what "3 days before" means.
      const body = 'אזכרתו של סבא יעקב';
      final encoded = NotificationService.encodePayload(memorial, body);
      final decoded = NotificationService.decodePayload(encoded)!;

      expect(decoded.memorialDate, memorial);
      expect(decoded.body, body);
    });

    test('a body containing a pipe survives decoding', () {
      const body = 'אזכרתו של א|ב – כ"ז באב';
      final decoded = NotificationService.decodePayload(
          NotificationService.encodePayload(memorial, body))!;
      expect(decoded.body, body, reason: 'split on the first separator only');
    });

    test('a payload from an older build still yields its text', () {
      final decoded = NotificationService.decodePayload('plain old body')!;
      expect(decoded.memorialDate, isNull);
      expect(decoded.body, 'plain old body');
    });

    test('the unversioned format from the previous build still decodes', () {
      // Those notifications are still queued on an upgraded install.
      final decoded = NotificationService.decodePayload(
          '${memorial.millisecondsSinceEpoch}|body')!;
      expect(decoded.memorialDate, memorial);
      expect(decoded.body, 'body');
    });

    test('only the current version counts as current', () {
      const body = 'אזכרתו של סבא יעקב';
      expect(
          NotificationService.isCurrentPayload(
              NotificationService.encodePayload(memorial, body)),
          isTrue);
      // This is what makes an upgrade reach notifications already queued:
      // their content was baked in when they were scheduled.
      expect(
          NotificationService.isCurrentPayload(
              '${memorial.millisecondsSinceEpoch}|$body'),
          isFalse);
      expect(NotificationService.isCurrentPayload('v1|0|$body'), isFalse);
      expect(NotificationService.isCurrentPayload(null), isFalse);
    });

    test('a body that opens like a version marker is not eaten', () {
      const body = 'v9|not a version';
      final decoded = NotificationService.decodePayload(
          NotificationService.encodePayload(memorial, body))!;
      expect(decoded.body, body);
      expect(decoded.memorialDate, memorial);
    });
  });

  group('the buttons offered fit what a notification can show', () {
    final memorial = DateTime(2026, 8, 20, 0, 0);

    List<int> at(int daysOut) => NotificationService.quickChoices(
          memorial,
          DateTime(memorial.year, memorial.month, memorial.day - daysOut, 8),
        );

    test('never more than Android will render, and never fewer than exist',
        () {
      for (final daysOut in [0, 1, 2, 3, 5, 8, 12, 40]) {
        final now =
            DateTime(memorial.year, memorial.month, memorial.day - daysOut, 8);
        final valid = NotificationService.choicesBefore(memorial, now);
        final shown = NotificationService.quickChoices(memorial, now);

        expect(shown.length,
            lessThanOrEqualTo(NotificationService.maxRescheduleActions),
            reason: 'Android drops actions past the third');
        expect(shown.length, valid.length > 3 ? 3 : valid.length,
            reason: 'no option is dropped while a slot is free');
        expect(valid, containsAll(shown),
            reason: 'every button shown must be a valid choice');
        expect(shown.toSet().length, shown.length, reason: 'no duplicates');
      }
    });

    test('reads from the longest lead time to the shortest', () {
      for (final daysOut in [2, 5, 12, 40]) {
        final shown = at(daysOut);
        final descending = [...shown]..sort((a, b) => b.compareTo(a));
        expect(shown, descending, reason: 'at $daysOut days out');
      }
    });

    test('keeps a spread rather than three options that sit together', () {
      // Far out, the whole ladder is valid and the three chosen must span it.
      expect(at(40), [7, 3, 1]);
      // Once a week before has passed, its slot goes to the longest option
      // still available - otherwise only same-week reminders would be left.
      expect(at(5), [5, 3, 1]);
      expect(at(3), [3, 2, 1]);
      expect(at(2), [2, 1, 0]);
      // On the memorial day only its own morning is left.
      expect(at(0), [0]);
    });
  });

  group('the notification hands the full list to the app', () {
    final memorial = DateTime(2026, 8, 20);

    test('three options or fewer stay inside the notification', () {
      final plan = NotificationService.actionPlan(
          memorial, DateTime(2026, 8, 18, 8));
      expect(plan.quick, [2, 1, 0]);
      expect(plan.moreOptions, isFalse,
          reason: 'nothing is hidden, so there is nothing to open a screen for');
    });

    test('more than three keeps two buttons and moves the rest to a screen',
        () {
      final plan = NotificationService.actionPlan(
          memorial, DateTime(2026, 7, 11, 8));
      expect(plan.quick.length, NotificationService.quickButtonCount);
      expect(plan.moreOptions, isTrue);
      // Android renders three actions at most, so two plus the opener is
      // exactly the ceiling - a third quick button would push it off.
      expect(plan.quick.length + 1, NotificationService.maxRescheduleActions);
    });

    test('the response carries everything the screen needs', () {
      const body = 'אזכרתו של סבא יעקב';
      final request = NotificationService.choiceRequestFrom(NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        id: 142,
        actionId: NotificationService.moreOptionsActionId,
        payload: NotificationService.encodePayload(memorial, body),
      ))!;

      expect(request.notificationId, 142);
      expect(request.memorialDate, memorial);
      expect(request.body, body,
          reason: 'the reminder is rewritten with its own text');
    });

    test('a plain snooze button is not mistaken for the opener', () {
      expect(
          NotificationService.choiceRequestFrom(NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
            id: 1,
            actionId: NotificationService.rescheduleActionIdFor(3),
            payload: NotificationService.encodePayload(memorial, 'x'),
          )),
          isNull);
    });
  });

  group('choosing a reminder time on screen', () {
    // The dialog builds its list against the real clock, not the pinned one,
    // so the memorial is placed far enough ahead that the whole ladder is
    // valid whenever the suite runs.
    ReminderChoiceRequest farOffRequest() {
      final now = DateTime.now();
      return ReminderChoiceRequest(
        notificationId: 142,
        memorialDate: DateTime(now.year, now.month, now.day + 60),
        body: 'אזכרתו של סבא יעקב',
      );
    }

    testWidgets('every remaining option is offered, not just three',
        (tester) async {
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      expect(notif.onChooseReminder, isNotNull,
          reason: 'the screen must register itself for the notification');
      notif.onChooseReminder!(farOffRequest());
      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');

      expect(find.byType(SimpleDialogOption),
          findsNWidgets(NotificationService.snoozeChoiceLadder.length),
          reason: 'this is the point of the screen - the notification cannot '
              'show more than three');
      // Longest lead time first, and the memorial day itself is last.
      expect(find.text('30 ימים לפני'), findsOneWidget);
      expect(find.text('ביום האזכרה'), findsOneWidget);
    });

    testWidgets('the chosen option is what gets rescheduled', (tester) async {
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      notif.onChooseReminder!(farOffRequest());
      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');
      await tester.tap(find.text('שבוע לפני'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(notif.log, contains('reschedule:7'));
    });

    testWidgets('a cold start from the notification opens the same list',
        (tester) async {
      // The app was not running when the button was tapped, so the request
      // arrives through the launch details instead of the callback.
      final (_, notif) = await _pumpApp(
        tester,
        seeded: [_seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av)],
        pendingChoice: farOffRequest(),
      );

      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');
      expect(notif.log, isNot(contains('reschedule:7')),
          reason: 'nothing moves until the user picks');
    });
  });

  group('a queue holding more than it should is rebuilt', () {
    bool needs(int pending, int wanted, {bool stale = false}) =>
        NotificationService.needsReschedule(
          pendingCount: pending,
          wantedCount: wanted,
          stalePayload: stale,
        );

    test('leftovers from an earlier configuration are not left alone', () {
      // Switching to "one day before" makes the day-before series redundant,
      // so 42 scheduled against 21 wanted. The old test was "at least as many
      // as wanted", which read that as a full queue and skipped it - and the
      // reminder kept arriving twice, upgrade after upgrade.
      expect(needs(42, 21), isTrue);
    });

    test('a queue that has drained is refilled', () {
      expect(needs(20, 21), isTrue);
    });

    test('an exact match is left alone', () {
      // Rescheduling costs tens of platform calls per memorial, and the
      // plugin rewrites its whole store on each one.
      expect(needs(21, 21), isFalse);
    });

    test('a stale payload rebuilds even when the count matches', () {
      expect(needs(21, 21, stale: true), isTrue);
    });
  });

  group('the days-before picker skips nothing', () {
    test('every number from one to the maximum is there, in order', () {
      expect(daysBeforeChoices.length, maxDaysBeforeChoice);
      for (var i = 0; i < daysBeforeChoices.length; i++) {
        expect(daysBeforeChoices[i], i + 1, reason: 'a number was skipped');
      }
    });

    test('one and two read as Hebrew rather than as counts', () {
      expect(daysBeforeLabel(1), 'יום אחד');
      expect(daysBeforeLabel(2), 'יומיים');
      expect(daysBeforeLabel(4), '4 ימים');
    });

    test('anything the old skipping ladder stored is still selectable', () {
      // A DropdownButtonFormField whose initialValue is absent from its items
      // throws, so an existing memorial must never fall outside this list.
      for (final d in const [1, 2, 3, 5, 7, 10, 14, 21, 30]) {
        expect(daysBeforeChoices, contains(d), reason: '$d days');
      }
    });
  });

  group('the day-before reminder never repeats the main one', () {
    final cal = HebrewCalendarService(now: () => _fixedNow);

    List<DateTime> dayBefore(Memorial m) =>
        cal.dayBeforeMemorialDates(m, from: _fixedNow);

    test('a main reminder set to one day before leaves no second series', () {
      // Both series then land on the same day, and at 09:00 on the same
      // minute: two identical notifications for one memorial. That is what
      // "every reminder arrives twice" looks like from the outside.
      expect(
          dayBefore(_seed(
            id: 1,
            name: 'סבא יעקב',
            day: 27,
            month: HebrewMonth.av,
            reminderMode: ReminderMode.fixedDaysBefore,
            reminderValue: 1,
          )),
          isEmpty);
    });

    test('a two-day gap still keeps the day-before reminder', () {
      expect(
          dayBefore(_seed(
            id: 1,
            name: 'סבא יעקב',
            day: 27,
            month: HebrewMonth.av,
            reminderMode: ReminderMode.fixedDaysBefore,
            reminderValue: 2,
          )),
          isNotEmpty);
    });

    test('the default weekday reminder shares no day with the second series',
        () {
      final m =
          _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av);
      final second = dayBefore(m);
      expect(second, isNotEmpty, reason: 'the series must still exist');

      final mainDays = cal
          .futureReminderDates(m, from: _fixedNow)
          .map((d) => DateTime(d.year, d.month, d.day))
          .toSet();
      for (final d in second) {
        expect(mainDays.contains(DateTime(d.year, d.month, d.day)), isFalse,
            reason: 'a memorial must never be announced twice in one day');
      }
    });
  });

  group('notification work never runs twice at once', () {
    late _InMemoryRepo repo;
    late _FakeNotifications notif;
    late ProviderContainer container;

    setUp(() {
      repo = _InMemoryRepo();
      notif = _FakeNotifications();
      container = ProviderContainer(overrides: [
        memorialRepositoryProvider.overrideWithValue(repo),
        notificationServiceProvider.overrideWithValue(notif),
      ]);
      addTearDown(container.dispose);
    });

    test('two overlapping syncs deliver a missed reminder only once', () async {
      // The home screen starts one sync after its first frame and another
      // from didChangeAppLifecycleState; opening the app from a notification
      // fires both within the same moment.
      await repo.insert(_seed(id: 1, name: 'סבא יעקב', day: 27,
          month: HebrewMonth.av));
      notif.missedToDeliver = DateTime(2026, 8, 4, 9);
      final notifier = container.read(memorialListProvider.notifier);
      await notifier.load();

      final first = notifier.syncNotifications();
      final second = notifier.syncNotifications();
      await Future.wait([first, second]);

      expect(notif.log.where((e) => e.startsWith('missed:')).length, 1,
          reason: 'the second sync must join the first, not repeat it');
    });

    test('a later sync still runs once the first has finished', () async {
      await repo.insert(_seed(id: 1, name: 'סבא יעקב', day: 27,
          month: HebrewMonth.av));
      final notifier = container.read(memorialListProvider.notifier);
      await notifier.load();

      await notifier.syncNotifications();
      final before = notif.log.length;
      await notifier.syncNotifications();

      expect(notif.log.length, greaterThan(before),
          reason: 'the guard must not latch and block every later sync');
    });
  });

  group('the manifest declares what the notification plugin needs', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    // The plugin declares no receivers of its own, so anything it dispatches
    // through must be declared here or the intent lands on nothing.
    test('the action receiver is declared, or buttons do nothing', () {
      expect(manifest,
          contains('flutterlocalnotifications.ActionBroadcastReceiver'),
          reason: 'without it a tap on a reminder button is silently dropped');
    });

    test('the scheduled and boot receivers are declared', () {
      expect(manifest,
          contains('flutterlocalnotifications.ScheduledNotificationReceiver'));
      expect(
          manifest,
          contains(
              'flutterlocalnotifications.ScheduledNotificationBootReceiver'));
      expect(manifest, contains('android.intent.action.BOOT_COMPLETED'));
      expect(manifest, contains('android.intent.action.MY_PACKAGE_REPLACED'));
    });
  });

  group('the reminder text counts down to the memorial', () {
    test('never says "this week"; always days, tomorrow, or today', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      for (final when in cal.futureReminderDates(m, from: _fixedNow, years: 5)) {
        final memorialDate = cal.memorialDateForReminder(m, when)!;
        final text =
            cal.describeMemorialForReminder(m, when, memorialDate);

        expect(text, isNot(contains('בשבוע')),
            reason: 'vague wording replaced by a real countdown');
        expect(
          text.contains('בעוד') ||
              text.contains('מחר') ||
              text.contains('היום'),
          isTrue,
          reason: text,
        );
      }
    });

    test('reads "מחר" exactly one day out and "היום" on the day', () {
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);
      final memorialDate = cal.nextMemorialDate(m, from: _fixedNow);

      final dayBefore = DateTime(
          memorialDate.year, memorialDate.month, memorialDate.day - 1, 9);
      expect(cal.describeMemorialForReminder(m, dayBefore, memorialDate),
          contains('מחר'));

      expect(
          cal.describeMemorialForReminder(m, memorialDate, memorialDate),
          contains('היום'));
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

  group('the project logo on the splash screen', () {
    testWidgets('appears alongside the candle, not instead of it',
        (tester) async {
      _phoneViewport(tester);
      final repo = _InMemoryRepo();
      final notif = _FakeNotifications();

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
      await tester.pump();

      expect(find.byType(SplashScreen), findsOneWidget);
      expect(find.text('🕯'), findsOneWidget, reason: 'the candle must stay');
      expect(find.text('תזכורת אזכרות'), findsOneWidget);

      final logo = tester.widgetList<Image>(find.byType(Image)).where((i) {
        final p = i.image;
        return p is AssetImage && p.assetName == 'assets/app_icon.png';
      });
      expect(logo, hasLength(1), reason: 'the logo asset must render');
      // A floor rather than an exact number: the point is that the logo
      // reads as a signature, not that it is any particular size.
      expect(logo.first.width, greaterThanOrEqualTo(64.0));

      // Let the bootstrap finish so no timer is left pending at teardown.
      await _pumpUntilFound(tester, find.byType(HomeScreen), 'HomeScreen');
    });

    // A plain test: reading a file inside testWidgets runs under the fake
    // clock and deadlocks.
    test('the notification icon is still the candle drawable', () {
      final source =
          File('lib/services/notification_service.dart').readAsStringSync();
      expect(source, contains("'@drawable/ic_notification'"));
      expect(source, isNot(contains('app_icon')),
          reason: 'the logo must not leak into the notification icon');
      expect(
          File('android/app/src/main/res/drawable/ic_notification.xml')
              .existsSync(),
          isTrue);
    });
  });

  group('the card states the weekday and the countdown to the memorial', () {
    testWidgets('both are visible without waiting for a notification',
        (tester) async {
      _phoneViewport(tester);
      final cal = HebrewCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av);

      await _pumpApp(tester, seeded: [m]);

      final date = cal.nextMemorialDate(m, from: _fixedNow);
      final weekday = hebrewWeekdayNames[date.weekday]!;
      final days = cal.daysUntilMemorial(m, from: _fixedNow);

      // The weekday of the memorial itself.
      expect(find.textContaining('יום $weekday'), findsOneWidget);
      // And how long until the memorial — distinct from the reminder count.
      expect(find.textContaining('האזכרה בעוד $days ימים'), findsOneWidget);
      // The reminder countdown is still its own separate row.
      expect(find.textContaining('התזכורת'), findsWidgets);
    });

    testWidgets('reads naturally when the memorial is imminent',
        (tester) async {
      _phoneViewport(tester);
      final cal = HebrewCalendarService(now: () => _fixedNow);

      // Find a memorial falling tomorrow relative to the pinned clock.
      Memorial? tomorrow;
      for (final month in HebrewMonth.values) {
        for (var day = 1; day <= 29 && tomorrow == null; day++) {
          final c = _seed(id: 1, name: 'x', day: day, month: month);
          if (cal.daysUntilMemorial(c, from: _fixedNow) == 1) tomorrow = c;
        }
      }
      expect(tomorrow, isNotNull, reason: 'no fixture falls tomorrow');

      await _pumpApp(tester, seeded: [tomorrow!]);
      expect(find.text('זמן שנותר: '), findsOneWidget);
      expect(find.text('האזכרה מחר'), findsOneWidget);
    });
  });

  group('the app opens without waiting on notification work', () {
    testWidgets('the list renders before any scheduling happens',
        (tester) async {
      _phoneViewport(tester);
      final repo = _InMemoryRepo()
        ..items.add(
            _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av));
      final notif = _FakeNotifications();

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

      // The splash must hand over as soon as SQLite answers. If scheduling
      // were still awaited here, this would sit on the splash instead.
      await _pumpUntilFound(
          tester, find.byType(MemorialCard), 'the memorial list');
      // The splash lingers for the length of the route transition; what
      // matters is that the list was already built underneath it.
      await _pumpUntilGone(tester, find.byType(SplashScreen), 'the splash');
    });
  });

  group('the logo in the app bar', () {
    testWidgets('sits next to the title, and yields to the search field',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      final inBar = find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(Image),
      );
      expect(inBar, findsOneWidget);
      expect(find.text('תזכורת אזכרות'), findsOneWidget);
      // RTL: the candle leads (right), the signature trails (left).
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('🕯'),
        ),
        findsOneWidget,
      );
      expect(tester.getCenter(inBar).dx,
          lessThan(tester.getCenter(find.text('תזכורת אזכרות')).dx),
          reason: 'the signature must sit left of the title');

      // Searching replaces the title, logo included — the field needs the room.
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump(const Duration(milliseconds: 300));
      expect(inBar, findsNothing);
    });
  });

  group('screenshots', () {
    testWidgets('splash screen', (tester) async {
      _phoneViewport(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memorialRepositoryProvider.overrideWithValue(_InMemoryRepo()),
            notificationServiceProvider.overrideWithValue(_FakeNotifications()),
            hebrewCalendarServiceProvider.overrideWithValue(
              HebrewCalendarService(now: () => _fixedNow),
            ),
          ],
          child: const AzkarotApp(),
        ),
      );
      await tester.pump();

      await expectLater(
        find.byType(AzkarotApp),
        matchesGoldenFile('goldens/07_splash.png'),
      );

      await _pumpUntilFound(tester, find.byType(HomeScreen), 'HomeScreen');
    });

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
