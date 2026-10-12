/// Runs the real app without an Android device: renders every screen against an
/// in-memory repository and a recording notification stub, and drives the
/// add-event and toggle flows end to end through the provider layer.
///
/// The rendered screens show "days until the reminder", so the calendar
/// service is pumped with a pinned clock ([_fixedNow]) — otherwise every
/// golden would fail a day later. Refresh them with:
///   flutter test test/ui_test.dart --update-goldens
library;

import 'dart:async';
import 'dart:io';


import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show
        NotificationResponse,
        NotificationResponseType,
        PendingNotificationRequest;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:events_app/app.dart';
import 'package:events_app/models/event_date.dart';
import 'package:events_app/models/event.dart';
import 'package:events_app/models/event_filter.dart';
import 'package:events_app/models/theme_seed.dart';
import 'package:events_app/providers/event_provider.dart';
import 'package:events_app/repository/event_repository.dart';
import 'package:events_app/screens/edit_event_screen.dart';
import 'package:events_app/screens/home_screen.dart';
import 'package:events_app/screens/settings_screen.dart';
import 'package:events_app/screens/splash_screen.dart';
import 'package:events_app/services/event_calendar_service.dart';
import 'package:events_app/services/background_refresh.dart';
import 'package:events_app/services/delivery_checks.dart';
import 'package:events_app/services/phone_launcher.dart';
import 'package:events_app/services/notification_service.dart';
import 'package:events_app/services/reminder_sync.dart';
import 'package:events_app/widgets/import_selection_dialog.dart';
import 'package:events_app/widgets/event_date_picker.dart';
import 'package:events_app/widgets/event_card.dart';
import 'package:events_app/widgets/event_form.dart';
import 'package:events_app/widgets/wedding_rings.dart';

/// Replaces SQLite so the real repository contract runs on the test VM.
/// מביא את הלוגו למטמון התמונות לפני צילום golden.
///
/// פענוח נכס הוא עבודה אמיתית של המנוע ואינו מסתיים תחת השעון המזויף של
/// testWidgets. התוצאה הייתה golden שתלוי בסדר: בסבב מלא בדיקה קודמת כבר
/// חיממה את המטמון והלוגו צויר, ובריצה של הקבוצה לבדה הוא נעדר – 2.2%
/// פיקסלים הפרש, בלי ששום דבר בקוד השתנה.
Future<void> _warmLogo(WidgetTester tester) async {
  await tester.runAsync(() async {
    const asset = AssetImage('assets/app_icon.png');
    final done = Completer<void>();
    asset.resolve(ImageConfiguration.empty).addListener(
          ImageStreamListener(
            (_, __) => done.isCompleted ? null : done.complete(),
            onError: (_, __) => done.isCompleted ? null : done.complete(),
          ),
        );
    await done.future;
  });
}

/// מאגר שהטעינה שלו לעולם אינה מסתיימת, ולכן המסך נשאר על ה-Splash.
///
/// קיים בשביל צילום ה-Splash בלבד. עם מאגר רגיל הצילום היה מרוץ: הטעינה
/// מסתיימת אחרי מספר לא מוגדר של תורים, ולכן הצילום תפס פעם את מסך הפתיחה
/// ופעם את המסך הראשי – תלוי בסדר שבו רצו הבדיקות. תוצאה של golden חייבת
/// להיות תלויה במסך ולא בתזמון.
class _NeverLoadsRepo extends _InMemoryRepo {
  @override
  Future<List<Event>> getAll() => Completer<List<Event>>().future;
}

/// נכשל בתפיסה הראשונה ומצליח בשנייה, כמו התנגשות כתיבה אמיתית.
class _ThrowsThenClaims extends _InMemoryRepo {
  int attempts = 0;

  @override
  Future<bool> claimSyncLock(String owner,
      {Duration staleAfter = const Duration(minutes: 10)}) async {
    attempts++;
    if (attempts == 1) throw Exception('database is locked');
    return true;
  }
}

class _InMemoryRepo extends EventRepository {
  final List<Event> items = [];

  /// app_state, ללא מסד. בלעדיו כל קריאת הגדרה מגיעה ל-sqflite האמיתי
  /// ונופלת על ערוץ פלטפורמה שאינו קיים בבדיקה.
  final Map<String, String> settings = {};

  @override
  Future<String?> readSetting(String key) async => settings[key];

  @override
  Future<void> writeSetting(String key, String value) async =>
      settings[key] = value;
  int _nextId = 1;

  @override
  Future<int> insert(Event event) async {
    final id = _nextId++;
    items.add(event.copyWith(id: id));
    return id;
  }

  @override
  Future<int> update(Event event) async {
    final i = items.indexWhere((e) => e.id == event.id);
    if (i >= 0) items[i] = event;
    return 1;
  }

  @override
  Future<int> delete(int id) async {
    items.removeWhere((e) => e.id == id);
    return 1;
  }

  @override
  Future<List<Event>> getAll() async => List<Event>.of(items);

  @override
  Future<Event?> getById(int id) async {
    for (final m in items) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// In the real repository the lock is a database row - the one place two
  /// isolates can both see. In memory it is free unless a test holds it.
  bool syncLockHeld = false;
  final List<String> lockOwners = [];

  @override
  Future<bool> claimSyncLock(
    String owner, {
    Duration staleAfter = const Duration(minutes: 10),
  }) async {
    if (syncLockHeld) return false;
    syncLockHeld = true;
    lockOwners.add(owner);
    return true;
  }

  @override
  Future<void> releaseSyncLock() async {
    syncLockHeld = false;
  }

  DateTime? backgroundRunAt;
  String? backgroundError;

  @override
  Future<void> recordBackgroundRun(DateTime at, String? error) async {
    backgroundRunAt = at;
    backgroundError = error;
  }

  @override
  Future<({DateTime? lastRun, String? lastError})> backgroundStatus() async =>
      (lastRun: backgroundRunAt, lastError: backgroundError);

  @override
  Future<void> replaceAll(List<Event> events) async {
    items
      ..clear()
      ..addAll(events);
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
  Future<DateTime?> scheduleForEvent(
    Event event, {
    List<Event> among = const [],
    int? quota,
    List<PendingNotificationRequest>? pending,
  }) async {
    schedulingStarted = true;
    await _maybeBlock();
    if (event.id == null) return null;
    log.add('cancel:${event.id}');
    if (!event.enabled) return null;
    log.add('schedule:${event.name}');
    return nearestScheduled;
  }

  @override
  Future<void> cancelForEvent(
    int eventId, {
    List<PendingNotificationRequest>? pending,
  }) async {
    await _maybeBlock();
    log.add('cancel:$eventId');
  }

  /// Set by a test to make the scheduling step blow up.
  bool failScheduling = false;

  @override
  Future<Map<int, DateTime>> rescheduleAll(List<Event> events) async {
    if (failScheduling) throw Exception('scheduling refused');
    // Recorded even for an empty list: the orphan sweep lives here, and a
    // caller that skips it leaves stray alarms firing forever.
    log.add('rescheduleAll:${events.length}');
    final out = <int, DateTime>{};
    for (final m in events) {
      final at = await scheduleForEvent(m);
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

  // Faithful to Android: the launch details never clear themselves, so this
  // keeps answering for as long as the process lives. A fake that consumed
  // the request would hide the very bug the caller has to guard against.
  @override
  Future<ReminderChoiceRequest?> pendingChoiceRequest() async => pendingChoice;

  /// What the settings screen should display. Empty unless a test says
  /// otherwise - the real call would reach the platform.
  PendingReport report =
      const PendingReport(rows: [], total: 0, orphans: 0);

  @override
  Future<PendingReport> pendingReport(
    List<Event> events, {
    bool batteryExempt = true,
  }) async =>
      report;

  @override
  Future<DateTime?> rescheduleReminder({
    required ReminderChoiceRequest request,
    required int daysBefore,
  }) async {
    log.add('reschedule:$daysBefore');
    return DateTime(request.eventDate.year, request.eventDate.month,
        request.eventDate.day - daysBefore, 9);
  }

  /// Set by a test to simulate a reminder that was missed and needs delivering.
  /// Left null, this is a no-op — which is what every other test wants.
  DateTime? missedToDeliver;

  // The provider asks in one batch; the per-event rule below stays the
  // single source of truth for what a fake delivery does.
  @override
  Future<Map<int, DateTime>> deliverMissedReminders(
      List<Event> events) async {
    final out = <int, DateTime>{};
    for (final m in events) {
      final at = await deliverMissedReminder(m);
      if (at != null && m.id != null) out[m.id!] = at;
    }
    return out;
  }

  @override
  Future<DateTime?> deliverMissedReminder(Event event) async {
    final missed = missedToDeliver;
    if (missed == null || !event.enabled) return null;
    // Mirrors EventCalendarService.missedReminderDate: a reminder already
    // accounted for is never delivered a second time.
    final last = event.lastNotifiedAt;
    if (last != null && !last.isBefore(missed)) return null;
    // A real delivery crosses the platform channel. Yielding here is what
    // lets a second, concurrent sync interleave - which is the whole bug.
    await Future<void>.delayed(Duration.zero);
    log.add('missed:${event.name}');
    return missed;
  }
}

/// A calendar that reports no upcoming reminders for one event, so the
/// ordering rule for "nothing to schedule" can be exercised.
class _NoUpcomingFor extends EventCalendarService {
  final int barrenId;
  _NoUpcomingFor(this.barrenId, {super.now});

  @override
  List<DateTime> futureReminderDates(
    Event event, {
    DateTime? from,
    int years = EventCalendarService.scheduleHorizonYears,
  }) =>
      event.id == barrenId
          ? const []
          : super.futureReminderDates(event, from: from, years: years);
}

/// Records what would have been dialled. The real one reaches url_launcher,
/// which in a widget test resolves nothing.
class _FakeLauncher implements PhoneLauncher {
  final List<String> dialled = [];
  bool succeeds = true;

  @override
  Future<bool> dial(String phone) async {
    dialled.add(phone);
    return succeeds;
  }
}

/// The real one talks to a platform channel, which a widget test has no
/// business waiting on - and whose timing decided whether the banner had
/// rendered yet.
class _FakeChecks implements DeliveryChecks {
  _FakeChecks({
    this.exempt = true,
    this.channelOn = true,
    this.iconPresent = true,
    this.canaryAt,
  });

  bool exempt;
  bool channelOn;
  bool iconPresent;
  DateTime? canaryAt;
  int requests = 0;
  int armed = 0;

  @override
  Future<bool> batteryExempt() async => exempt;

  @override
  Future<void> requestBatteryExemption() async {
    requests++;
    exempt = true;
  }

  @override
  Future<bool> channelEnabled(String channelId) async => channelOn;

  @override
  Future<bool> hasNotificationIcon() async => iconPresent;

  @override
  Future<void> armCanary() async => armed++;

  @override
  Future<DateTime?> canaryLastFired() async => canaryAt;
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

/// שבב הקטגוריה של כרטיס מסוים.
///
/// ממוקד לכרטיס ולפי מפתח: השבב יושב בתוך ה-InkWell של הכרטיס, וחיפוש לפי
/// טקסט מחזיר את שניהם.
Finder _kindChipOf(String name) => find.descendant(
      of: find.ancestor(
          of: find.text(name), matching: find.byType(EventCard)),
      matching: find.byKey(EventCard.kindChipKey),
    );

/// Builds an event. Hebrew by default — the app's own default — with
/// [calendar] plus [gregorianMonth] for the Gregorian half.
Event _seed({
  required int id,
  required String name,
  required int day,
  HebrewMonth month = HebrewMonth.tishrei,
  CalendarSystem calendar = CalendarSystem.hebrew,
  int gregorianMonth = 1,
  bool enabled = true,
  String? notes,
  EventKind kind = EventKind.birthday,
  ReminderMode reminderMode = ReminderMode.weekdayOfPreviousWeek,
  int reminderValue = Event.defaultReminderWeekday,
  int? startYear,
}) {
  final storage = month.toStorage();
  final hebrew = calendar == CalendarSystem.hebrew;
  return Event(
    id: id,
    name: name,
    kind: kind,
    calendar: calendar,
    day: day,
    month: hebrew ? storage.baseMonth : gregorianMonth,
    adarType: hebrew ? storage.adarType : AdarType.none,
    notificationHour: 9,
    notificationMinute: 0,
    enabled: enabled,
    notes: notes,
    reminderMode: reminderMode,
    reminderValue: reminderValue,
    startYear: startYear,
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

/// Brings [target] on screen inside the event form and settles.
///
/// `ensureVisible` alone is not enough: the form is a lazy `ListView`, so a
/// control far down it is not built at all and `ensureVisible` throws
/// "No element". Scroll the form's own Scrollable — not `find.byType(Scrollable)`,
/// which would also match the date picker's wheels.
Future<void> _revealInForm(WidgetTester tester, Finder target) async {
  // Scoped to EventForm on purpose: the home screen stays mounted beneath
  // the pushed route, so a bare find.byType(ListView) can grab *its* list and
  // scroll the wrong thing.
  final scrollable = find
      .descendant(
        of: find.descendant(
          of: find.byType(EventForm),
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
/// Pumps until nothing is animating any more.
///
/// [_pumpUntilFound] returns the moment the target exists, which is partway
/// through the page transition - measured, the screen was still 0.7px to the
/// side of where it ends up. That is invisible to most assertions and fatal to
/// one that compares a rect. `pumpAndSettle` would do the same job, but it
/// throws on a screen that animates forever and this file has one, so the wait
/// is bounded instead.
Future<void> _settleRoute(WidgetTester tester) async {
  for (var i = 0; i < 60 && tester.binding.transientCallbackCount > 0; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump();
}

final DateTime _fixedNow = DateTime(2026, 7, 31, 12);

/// The launcher of the app most recently pumped, for tests that tap a link.
_FakeLauncher? _lastLauncher;

Future<(_InMemoryRepo, _FakeNotifications)> _pumpApp(
  WidgetTester tester, {
  List<Event> seeded = const [],
  DateTime? now,
  bool notificationsEnabled = true,
  bool exactAlarmsAllowed = true,
  bool batteryExempt = true,
  bool channelEnabled = true,
  bool hasNotificationIcon = true,
  DateTime? canaryLastFired,
  ReminderChoiceRequest? pendingChoice,
}) async {
  final launcher = _FakeLauncher();
  _lastLauncher = launcher;
  final checks = _FakeChecks(
    exempt: batteryExempt,
    channelOn: channelEnabled,
    iconPresent: hasNotificationIcon,
    canaryAt: canaryLastFired,
  );
  final repo = _InMemoryRepo()..items.addAll(seeded);
  final notif = _FakeNotifications()
    ..notificationsEnabled = notificationsEnabled
    ..exactAlarmsAllowed = exactAlarmsAllowed
    ..pendingChoice = pendingChoice;
  final clock = now ?? _fixedNow;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        eventRepositoryProvider.overrideWithValue(repo),
        notificationServiceProvider.overrideWithValue(notif),
        deliveryChecksProvider.overrideWithValue(checks),
        phoneLauncherProvider.overrideWithValue(launcher),
        calendarServiceProvider.overrideWithValue(
          EventCalendarService(now: () => clock),
        ),
      ],
      child: const EventsApp(),
    ),
  );
  await _pumpUntilFound(tester, find.byType(HomeScreen), 'HomeScreen');
  // HomeScreen appearing is not enough: loadAndReschedule also delivers missed
  // reminders, so the list can still be in AsyncLoading with no cards yet.
  // Wait for real content — a card, or the empty state.
  await _pumpUntilFound(
    tester,
    seeded.isEmpty ? find.text('אין עדיין אירועים ברשימה') : find.byType(EventCard),
    seeded.isEmpty ? 'the empty state' : 'the event list',
  );
  return (repo, notif);
}

void main() {
  setUpAll(_loadHebrewFont);

  group('nextOccurrenceDate honours `from`', () {
    test('the starting Hebrew year comes from `from`, not the wall clock', () {
      final calendar = EventCalendarService();
      final m = _seed(id: 1, name: 'x', day: 10, month: HebrewMonth.tishrei);

      // Deep in the past. Before the fix this returned a date near the real
      // present, because the year came from DateTime.now().
      final from = DateTime(2010, 1, 1);
      final next = calendar.nextOccurrenceDate(m, from: from);

      expect(next.isBefore(from), isFalse);
      expect(next.difference(from).inDays, lessThan(400),
          reason: 'must resolve within a year of `from`, got $next');
    });

    test('passing `from: null` is identical to passing today', () {
      final calendar = EventCalendarService();
      for (final month in HebrewMonth.values) {
        final m = _seed(id: 1, name: 'x', day: 10, month: month);
        expect(
          calendar.nextOccurrenceDate(m),
          equals(calendar.nextOccurrenceDate(m, from: DateTime.now())),
          reason: 'production behaviour changed for $month',
        );
      }
    });

    test('Adar I and Adar II differ once `from` lands on a leap year', () {
      final calendar = EventCalendarService();
      final adarA = _seed(id: 1, name: 'a', day: 10, month: HebrewMonth.adarA);
      final adarB = _seed(id: 2, name: 'b', day: 10, month: HebrewMonth.adarB);

      final from = DateTime(2023, 12, 1); // inside 5784, a leap year
      expect(calendar.isLeapYear(5784), isTrue);

      final a = calendar.nextOccurrenceDate(adarA, from: from);
      final b = calendar.nextOccurrenceDate(adarB, from: from);

      expect(a, isNot(equals(b)));
      expect(a.isBefore(b), isTrue, reason: 'Adar I precedes Adar II');
    });

    test('plain Adar still falls on Adar II in a leap year', () {
      final calendar = EventCalendarService();
      final plain = _seed(id: 1, name: 'a', day: 10, month: HebrewMonth.adar);
      final adarB = _seed(id: 2, name: 'b', day: 10, month: HebrewMonth.adarB);

      final from = DateTime(2023, 12, 1);
      expect(
        calendar.nextOccurrenceDate(plain, from: from),
        equals(calendar.nextOccurrenceDate(adarB, from: from)),
      );
    });
  });

  group('tuesdayBeforeWeekOf survives DST', () {
    // The pre-existing suite only scanned 60 days from 2027-01-01, so it never
    // reached a daylight-saving transition. Week arithmetic done with Duration
    // shifts across one and lands on the wrong day.
    test('always a Tuesday across four full years', () {
      final calendar = EventCalendarService();
      for (var year = 2026; year <= 2029; year++) {
        for (var day = 0; day < 365; day++) {
          final d = DateTime(year, 1, 1 + day);
          final reminder = calendar.tuesdayBeforeWeekOf(d);
          expect(reminder.weekday, DateTime.tuesday, reason: 'failed for $d');
          // 5..11 calendar days before the event, never after it. Measured
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
      final calendar = EventCalendarService();
      // Israel moves to DST on the Friday before the last Sunday of March.
      for (final eventDate in [
        DateTime(2027, 3, 28),
        DateTime(2027, 3, 29),
        DateTime(2027, 3, 26),
        DateTime(2026, 3, 29),
        DateTime(2026, 10, 25),
      ]) {
        final reminder = calendar.tuesdayBeforeWeekOf(eventDate);
        expect(reminder.weekday, DateTime.tuesday,
            reason: 'event on $eventDate gave $reminder');
      }
      // The exact case that used to return Monday 2027-03-22.
      expect(calendar.tuesdayBeforeWeekOf(DateTime(2027, 3, 28)),
          DateTime(2027, 3, 23));
    });
  });

  group('the reminder for the nearest event can already be past', () {
    // reminderDate lands 5-11 days before the event, so for every event
    // there is a yearly window where it is behind us but the event is not.
    (Event, DateTime, DateTime)? findInWindow(EventCalendarService cal) {
      final now = _fixedNow;
      for (final month in HebrewMonth.values) {
        for (var day = 1; day <= 29; day++) {
          final m = _seed(id: 1, name: 'x', day: day, month: month);
          final eventDate = cal.nextOccurrenceDate(m, from: now);
          final reminder = cal.reminderDate(m, from: now);
          if (reminder.isBefore(now) && !eventDate.isBefore(now)) {
            return (m, eventDate, reminder);
          }
        }
      }
      return null;
    }

    test('such a window exists, and daysUntilReminder goes negative', () {
      final cal = EventCalendarService();
      final hit = findInWindow(cal);
      expect(hit, isNotNull,
          reason: 'expected at least one event inside the dead window');

      final (m, eventDate, reminder) = hit!;
      expect(reminder.isBefore(eventDate), isTrue);
      expect(cal.daysUntilReminder(m, from: _fixedNow),
          lessThan(0));
    });

    test('nextFutureReminderDate still returns something schedulable', () {
      final cal = EventCalendarService();
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
      final cal = EventCalendarService();
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
      final cal = EventCalendarService();
      final m = _seed(id: 1, name: 'x', day: 26, month: HebrewMonth.av);

      final occurrence = cal.nextOccurrence(m, from: _fixedNow);
      expect(occurrence, isNotNull);
      final text = cal.formatNextOccurrence(m, from: _fixedNow)!;
      // ignore: avoid_print
      print('  ${occurrence!.gregorian} -> "$text" '
          '(hebrew year ${occurrence.year})');

      expect(text, startsWith('כ"ו באב '));
      // A gematria year, not digits.
      expect(text, isNot(matches(RegExp(r'\d'))));
      expect(text.split(' ').last, isNotEmpty);
    });

    test('a plain-Adar event reads as Adar II in a leap year', () {
      final cal = EventCalendarService();
      final m = _seed(id: 1, name: 'x', day: 10, month: HebrewMonth.adar);

      // 5787 is a leap year; aim `from` just inside 5786 so 5787 is next.
      final text = cal.formatNextOccurrence(
        m,
        from: DateTime(2026, 7, 31),
      )!;
      // ignore: avoid_print
      print('  plain Adar -> "$text"');
      expect(text, contains("אדר ב'"));
    });

    test('never contains digits for any month/day', () {
      final cal = EventCalendarService();
      for (final month in HebrewMonth.values) {
        for (var day = 1; day <= 29; day++) {
          final m = _seed(id: 1, name: 'x', day: day, month: month);
          final text = cal.formatNextOccurrence(m, from: _fixedNow);
          expect(text, isNotNull, reason: '$day $month');
          expect(text, isNot(matches(RegExp(r'\d'))), reason: '$day $month');
        }
      }
    });
  });

  group('reminders recur for years without reopening the app', () {
    test('enumerates one reminder per year, all Tuesdays, in order', () {
      final cal = EventCalendarService();
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

    test('a date absent in some years falls back instead of vanishing', () {
      final cal = EventCalendarService();
      // Cheshvan and Kislev are 29 or 30 days depending on the year, so
      // ל' בהם is genuinely absent in some of them. Those years used to be
      // dropped outright - measured at 5 reminders out of 11 for 30 Cheshvan
      // and 8 for 30 Kislev. A event with no reminder at all is a worse
      // answer than one on the adjacent day.
      final absent = _seed(id: 1, name: 'x', day: 30, month: HebrewMonth.kislev);
      final ordinary =
          _seed(id: 2, name: 'y', day: 15, month: HebrewMonth.kislev);

      final dates = cal.futureReminderDates(absent, from: _fixedNow, years: 19);
      expect(dates.length,
          cal.futureReminderDates(ordinary, from: _fixedNow, years: 19).length,
          reason: 'as many reminders as any ordinary date');
      for (final d in dates) {
        expect(d.weekday, DateTime.tuesday);
      }
    });

    test('Adar I falls back onto the single Adar in non-leap years', () {
      final cal = EventCalendarService();
      final m = _seed(id: 1, name: 'x', day: 10, month: HebrewMonth.adarA);
      final dates = cal.futureReminderDates(m, from: _fixedNow, years: 19);
      expect(dates.length, greaterThanOrEqualTo(19),
          reason: 'must produce a reminder every year, leap or not');
    });

    test('id ranges never bleed into a neighbouring event', () {
      // A mistake here would cancel a different event's notifications.
      for (final eventId in [1, 2, 7, 42, 1000]) {
        final base = Event.notificationIdBase(eventId);
        final last = base + Event.notificationIdsPerEvent - 1;

        expect(Event.ownsNotificationId(base, eventId), isTrue);
        expect(Event.ownsNotificationId(last, eventId), isTrue);
        expect(Event.ownsNotificationId(base - 1, eventId), isFalse,
            reason: 'id just below the block leaked in');
        expect(Event.ownsNotificationId(last + 1, eventId), isFalse,
            reason: 'id just above the block leaked in');

        // And it belongs to exactly one event.
        for (final other in [1, 2, 7, 42, 1000]) {
          if (other == eventId) continue;
          expect(Event.ownsNotificationId(base, other), isFalse);
          expect(Event.ownsNotificationId(last, other), isFalse);
        }
      }
    });

    test('legacy raw ids fall in block 0, which no event can own', () {
      // Before the multi-year scheme the notification id was the raw event
      // id. Those survivors must be identifiable so an upgrade can clear them
      // instead of firing a duplicate alongside the new schedule.
      for (final legacyId in [1, 2, 7, 42, 99]) {
        expect(legacyId, lessThan(Event.notificationIdsPerEvent));
        // SQLite AUTOINCREMENT starts at 1, so no event owns block 0.
        for (final eventId in [1, 2, 7, 42]) {
          expect(Event.ownsNotificationId(legacyId, eventId), isFalse,
              reason: 'legacy id $legacyId collided with event $eventId');
        }
      }
      // The first real block starts above every legacy id.
      expect(Event.notificationIdBase(1),
          greaterThanOrEqualTo(Event.notificationIdsPerEvent));
    });

    test('a full 20-year block stays inside the event range', () {
      final m = _seed(id: 7, name: 'x', day: 1, month: HebrewMonth.tishrei);
      for (var i = 0; i <= EventCalendarService.scheduleHorizonYears; i++) {
        expect(Event.ownsNotificationId(m.notificationIdForOccurrence(i), 7),
            isTrue,
            reason: 'occurrence $i escaped the block');
      }
      expect(EventCalendarService.scheduleHorizonYears,
          lessThan(Event.notificationIdsPerEvent),
          reason: 'the horizon must fit inside one id block');
    });

    test('notification ids are unique per event and per occurrence', () {
      final a = _seed(id: 1, name: 'a', day: 1, month: HebrewMonth.tishrei);
      final b = _seed(id: 2, name: 'b', day: 1, month: HebrewMonth.tishrei);

      final ids = <int>{};
      for (var i = 0; i < Event.notificationIdsPerEvent; i++) {
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
    // The window where the reminder Tuesday has passed but the event has
    // not — 5 to 11 days wide, every year, for every event.
    (Event, DateTime) inWindow(EventCalendarService cal, DateTime now) {
      for (final month in HebrewMonth.values) {
        for (var day = 1; day <= 29; day++) {
          final m = _seed(id: 1, name: 'x', day: day, month: month);
          final eventDate = cal.nextOccurrenceDate(m, from: now);
          final reminder = cal.reminderDate(m, from: now);
          if (reminder.isBefore(now) && !eventDate.isBefore(now)) {
            return (m, reminder);
          }
        }
      }
      throw StateError('no event inside the dead window');
    }

    test('reports a reminder that already passed and was never shown', () {
      final cal = EventCalendarService();
      final (m, reminder) = inWindow(cal, _fixedNow);

      final missed = cal.missedReminderDate(m, from: _fixedNow);
      expect(missed, isNotNull, reason: 'the reminder must not be dropped');
      expect(missed, equals(reminder));
      expect(missed!.isBefore(_fixedNow), isTrue);
    });

    test('reports nothing once it has been delivered', () {
      final cal = EventCalendarService();
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
      final cal = EventCalendarService();
      final (m, reminder) = inWindow(cal, _fixedNow);

      final asScheduled = m.copyWith(lastNotifiedAt: reminder);
      for (final minutesLater in [1, 60, 60 * 24]) {
        final after = reminder.add(Duration(minutes: minutesLater));
        expect(cal.missedReminderDate(asScheduled, from: after), isNull,
            reason: 'duplicate $minutesLater minutes after firing');
      }
    });

    test('an older delivery does not suppress this year', () {
      final cal = EventCalendarService();
      final (m, reminder) = inWindow(cal, _fixedNow);

      final lastYear =
          m.copyWith(lastNotifiedAt: reminder.subtract(const Duration(days: 365)));
      expect(cal.missedReminderDate(lastYear, from: _fixedNow),
          equals(reminder));
    });

    test('reports nothing when the reminder is still ahead', () {
      final cal = EventCalendarService();
      // Far from the window: a reminder comfortably in the future.
      final m = _seed(id: 1, name: 'x', day: 3, month: HebrewMonth.nisan);
      final reminder = cal.reminderDate(m, from: _fixedNow);
      expect(reminder.isAfter(_fixedNow), isTrue, reason: 'bad fixture');
      expect(cal.missedReminderDate(m, from: _fixedNow), isNull);
    });

    test('a disabled event is still reported by the calendar layer', () {
      // Suppression of disabled events belongs to NotificationService, so
      // the calendar must stay honest about the date itself.
      final cal = EventCalendarService();
      final (m, reminder) = inWindow(cal, _fixedNow);
      final off = m.copyWith(enabled: false);
      expect(cal.missedReminderDate(off, from: _fixedNow), equals(reminder));
    });
  });

  group('the list is ordered by the upcoming event date', () {
    /// Reads the card titles top to bottom.
    List<String> cardOrder(WidgetTester tester) => tester
        .widgetList<EventCard>(find.byType(EventCard))
        .map((c) => c.event.name)
        .toList();

    testWidgets('nearest event first, regardless of reminder offset',
        (tester) async {
      _phoneViewport(tester);
      final cal = EventCalendarService(now: () => _fixedNow);

      final seeds = [
        _seed(id: 1, name: 'רחוק', day: 3, month: HebrewMonth.nisan),
        _seed(id: 2, name: 'קרוב', day: 27, month: HebrewMonth.av),
        _seed(id: 3, name: 'אמצע', day: 14, month: HebrewMonth.cheshvan),
      ];
      await _pumpApp(tester, seeded: seeds);

      final expected = [...seeds]..sort((a, b) => cal
          .nextOccurrenceDate(a, from: _fixedNow)
          .compareTo(cal.nextOccurrenceDate(b, from: _fixedNow)));

      final actual = cardOrder(tester);
      // ignore: avoid_print
      for (final m in expected) {
        // ignore: avoid_print
        print('  ${cal.nextOccurrenceDate(m, from: _fixedNow)}  ${m.name}');
      }
      expect(actual, expected.map((m) => m.name).toList());
      expect(actual.first, 'קרוב');
      expect(actual.last, 'רחוק');
    });

    testWidgets('an event whose reminder already passed does not jump first',
        (tester) async {
      _phoneViewport(tester);
      // Inside the dead window for כ"ז באב: its reminder Tuesday (4/8) has
      // gone by, but the event itself (10/8) has not.
      final now = DateTime(2026, 8, 6, 12);
      final cal = EventCalendarService(now: () => now);

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
              .nextOccurrenceDate(inWindow, from: now)
              .isBefore(cal.nextOccurrenceDate(later, from: now)),
          isTrue,
          reason: 'fixture: חלון must genuinely fall first');

      await _pumpApp(tester, seeded: [later, inWindow], now: now);

      // Ordered by event date, so the window one leads on its own merit.
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
        .widgetList<EventCard>(find.byType(EventCard))
        .map((c) => c.event.name)
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
      expect(find.textContaining('לא נמצא אירוע בשם'), findsOneWidget);
      expect(find.text('אין עדיין אירועים ברשימה'), findsNothing);
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
      final cal = EventCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      final reminder = cal.futureReminderDates(m, from: _fixedNow).first;
      final eventDate = cal.eventDateForReminder(m, reminder)!;
      final text =
          cal.describeEventForReminder(m, reminder, eventDate);

      // ignore: avoid_print
      print('  reminder $reminder -> "$text" (event $eventDate)');
      expect(text, startsWith('יום '));
      expect(text, contains('/'));
      expect(text, contains('בעוד'));
    });

    test('the countdown is measured from the firing date, not from today', () {
      final cal = EventCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      // The furthest occurrence scheduled - not a fixed index, which broke
      // the moment the horizon shrank. If "today" leaked in, the number
      // would be in the hundreds instead of the 5..11 the rule produces.
      final reminders = cal.futureReminderDates(m, from: _fixedNow);
      final late = reminders.last;
      final eventDate = cal.eventDateForReminder(m, late)!;
      final text = cal.describeEventForReminder(m, late, eventDate);

      final days = int.parse(RegExp(r'(\d+) ימים').firstMatch(text)!.group(1)!);
      expect(days, inInclusiveRange(5, 11), reason: text);
    });

    test('every weekday name resolves, including Shabbat', () {
      // The event can fall on any day; only the *reminder* excludes it.
      for (var wd = 1; wd <= 7; wd++) {
        expect(hebrewWeekdayNames[wd], isNotNull, reason: 'weekday $wd');
      }
      expect(hebrewWeekdayNames[DateTime.saturday], 'שבת');
      expect(reminderWeekdayChoices, isNot(contains(DateTime.saturday)));
      expect(reminderWeekdayChoices, hasLength(6));
    });

    test('the occurrence ids and the catch-up slot never collide', () {
      final m = _seed(id: 3, name: 'x', day: 1, month: HebrewMonth.tishrei);

      final occurrences = [
        for (var i = 0; i <= EventCalendarService.scheduleHorizonYears; i++)
          m.notificationIdForOccurrence(i)
      ];
      final catchUp = m.notificationIdForOccurrence(Event.catchUpIndex);

      expect(occurrences, isNot(contains(catchUp)));
      // Everything stays inside this event's block, or cancelling one
      // event would silence another.
      for (final id in [...occurrences, catchUp]) {
        expect(Event.ownsNotificationId(id, 3), isTrue);
      }
    });
  });

  group('the year it started, and which anniversary this is', () {
    test('no year means no count', () {
      final cal = EventCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      expect(m.startYear, isNull);
      expect(cal.anniversaryNumber(m, from: _fixedNow), isNull);
    });

    test('counts from the start year to the upcoming occurrence', () {
      final cal = EventCalendarService(now: () => _fixedNow);
      // כ"ז באב falls in 5786 on _fixedNow.
      final occurrenceYear = cal
          .nextOccurrence(
            _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av),
            from: _fixedNow,
          )!
          .year;

      for (final n in [1, 2, 5, 20]) {
        final m = _seed(
          id: 1,
          name: 'x',
          day: 27,
          month: HebrewMonth.av,
          startYear: occurrenceYear - n,
        );
        expect(cal.anniversaryNumber(m, from: _fixedNow), n);
      }
    });

    test('a start year at or after the occurrence yields nothing', () {
      final cal = EventCalendarService(now: () => _fixedNow);
      final occurrenceYear = cal
          .nextOccurrence(
            _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av),
            from: _fixedNow,
          )!
          .year;

      for (final year in [occurrenceYear, occurrenceYear + 1]) {
        final m = _seed(
          id: 1,
          name: 'x',
          day: 27,
          month: HebrewMonth.av,
          startYear: year,
        );
        expect(cal.anniversaryNumber(m, from: _fixedNow), isNull,
            reason: 'a nonsensical count must not be shown');
      }
    });

    test('a Gregorian event counts in Gregorian years', () {
      // The year is stored in the event's own calendar, and this is why:
      // subtracting a Hebrew year from a Gregorian occurrence would give a
      // number around -3760 instead of an anniversary.
      final cal = EventCalendarService(now: () => _fixedNow);
      final m = _seed(
        id: 1,
        name: 'אנחנו',
        calendar: CalendarSystem.gregorian,
        day: 14,
        gregorianMonth: 11,
        startYear: 2001,
      );

      final occurrence = cal.nextOccurrence(m, from: _fixedNow)!;
      expect(occurrence.year, 2026, reason: '14/11/2026 is still ahead');
      expect(cal.anniversaryNumber(m, from: _fixedNow), 25);
    });

    test('each occurrence carries its own number', () {
      // The notification text is baked years in advance, so the number has
      // to come from the occurrence being scheduled - not from the next one.
      final cal = EventCalendarService(now: () => _fixedNow);
      final m = _seed(
        id: 1,
        name: 'אנחנו',
        calendar: CalendarSystem.gregorian,
        day: 14,
        gregorianMonth: 11,
        startYear: 2001,
      );

      expect(cal.anniversaryNumberFor(m, DateTime(2026, 11, 14)), 25);
      expect(cal.anniversaryNumberFor(m, DateTime(2027, 11, 14)), 26);
      expect(cal.anniversaryNumberFor(m, DateTime(2028, 11, 14)), 27);
    });

    test('the picker offers only past years, newest first', () {
      final cal = EventCalendarService(now: () => _fixedNow);
      final years = cal.startYearChoices(CalendarSystem.hebrew, span: 10);

      expect(years, hasLength(10));
      expect(years.first, greaterThan(years.last));
      expect(years.first, cal.currentHebrewYear());
      // In gematria, never digits.
      expect(cal.formatHebrewYear(years.first), isNot(matches(RegExp(r'\d'))));
    });

    test('and plain digits for a Gregorian event', () {
      // Gematria for 1996 would be a riddle, not a date.
      final cal = EventCalendarService(now: () => _fixedNow);
      final years = cal.startYearChoices(CalendarSystem.gregorian, span: 5);

      expect(years.first, _fixedNow.year);
      expect(cal.formatYear(CalendarSystem.gregorian, years.first),
          _fixedNow.year.toString());
    });

    testWidgets('the card says which anniversary it is, in the kind\'s own'
        ' words', (tester) async {
      _phoneViewport(tester);
      final cal = EventCalendarService(now: () => _fixedNow);
      final occurrenceYear = cal
          .nextOccurrence(
            _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av),
            from: _fixedNow,
          )!
          .year;

      await _pumpApp(tester, seeded: [
        _seed(
          id: 1,
          name: 'עם שנה',
          day: 27,
          month: HebrewMonth.av,
          kind: EventKind.anniversary,
          startYear: occurrenceYear - 3,
        ),
        _seed(id: 2, name: 'בלי שנה', day: 3, month: HebrewMonth.nisan),
      ]);

      // "יום הנישואין ה-3" and not a bare "3": the number means nothing
      // without the noun, and the noun differs per kind.
      expect(find.text(EventKind.anniversary.ordinal(3)), findsOneWidget);
      // The event without a year shows no such row at all.
      expect(find.text('מספר השנה: '), findsOneWidget);
    });
  });

  group('filter by how soon the event falls', () {
    List<String> cards(WidgetTester tester) => tester
        .widgetList<EventCard>(find.byType(EventCard))
        .map((c) => c.event.name)
        .toList();

    // Chosen against _fixedNow (2026-07-31) so the windows are unambiguous.
    List<Event> seeds(EventCalendarService cal) => [
          // כ"ז באב -> 10/08/2026, 10 days out: inside the month, not the week.
          _seed(id: 1, name: 'בחודש', day: 27, month: HebrewMonth.av),
          // י"ד בחשוון -> 25/10/2026: outside both.
          _seed(id: 2, name: 'רחוק', day: 14, month: HebrewMonth.cheshvan),
        ];

    test('the fixtures land where the test assumes', () {
      final cal = EventCalendarService(now: () => _fixedNow);
      final all = seeds(cal);
      expect(cal.daysUntilEvent(all[0], from: _fixedNow), 10);
      expect(cal.daysUntilEvent(all[1], from: _fixedNow),
          greaterThan(30));
    });

    test('isEventWithin is inclusive of the boundary', () {
      final cal = EventCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);
      final days = cal.daysUntilEvent(m, from: _fixedNow);

      expect(cal.isEventWithin(m, days, from: _fixedNow), isTrue,
          reason: 'exactly N days away must count as within N');
      expect(cal.isEventWithin(m, days - 1, from: _fixedNow), isFalse);
    });

    // Scoped to the chip: the empty-state hint text also contains "הכל",
    // which makes a bare textContaining finder ambiguous.
    Finder chipFor(EventFilter f) => find.ancestor(
          of: find.textContaining(f.label),
          matching: find.byType(FilterChip),
        );

    testWidgets('all / week / month narrow the list', (tester) async {
      _phoneViewport(tester);
      final cal = EventCalendarService(now: () => _fixedNow);
      await _pumpApp(tester, seeded: seeds(cal));

      // Default is unfiltered.
      expect(cards(tester), ['בחודש', 'רחוק']);

      await tester.tap(chipFor(EventFilter.month));
      await tester.pump(const Duration(milliseconds: 300));
      expect(cards(tester), ['בחודש']);

      await tester.tap(chipFor(EventFilter.week));
      await tester.pump(const Duration(milliseconds: 300));
      expect(cards(tester), isEmpty);
      expect(find.text('אין אירועים בשבוע הקרוב'), findsOneWidget);
      // The empty state must not claim there are no events at all.
      expect(find.text('אין עדיין אירועים ברשימה'), findsNothing);
      // And the filter bar must stay reachable, or the user is stuck.
      expect(chipFor(EventFilter.all), findsOneWidget);

      await tester.tap(chipFor(EventFilter.all));
      await tester.pump(const Duration(milliseconds: 300));
      expect(cards(tester), ['בחודש', 'רחוק']);
    });

    testWidgets('each chip shows how many fall in its window', (tester) async {
      _phoneViewport(tester);
      final cal = EventCalendarService(now: () => _fixedNow);
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
      expect(find.text('אין עדיין אירועים ברשימה'), findsOneWidget);
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

    testWidgets('warns when battery management can stop the app',
        (tester) async {
      // The one failure that takes the alarms with it: Android is allowed to
      // stop an unexempt app and clear its scheduled alarms, including ones
      // set long before.
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: seed, batteryExempt: false);

      expect(find.textContaining('ניהול הסוללה'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'תיקון'), findsOneWidget);
    });

    testWidgets('a blocked channel is caught, and named', (tester) async {
      // The silent total failure: areNotificationsEnabled is app-level, so a
      // channel blocked on its own passes every check the app used to make
      // while nothing ever arrives.
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: seed, channelEnabled: false);

      expect(find.textContaining('ערוץ'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'תיקון'), findsNothing,
          reason: 'only system settings can undo it; a dead button is worse '
              'than none');
    });

    testWidgets('a stripped notification icon is caught', (tester) async {
      // It has happened here: the shrinker removed the drawable from a
      // release build, because the only reference to it is a Dart string, and
      // every notification then failed silently at fire time.
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: seed, hasNotificationIcon: false);

      expect(find.textContaining('אייקון ההתראה חסר'), findsOneWidget);
    });

    testWidgets('a missing notification permission is named first',
        (tester) async {
      // Ranked by severity: without it nothing shows at all, so saying
      // "battery management" there would send the user to the wrong screen.
      _phoneViewport(tester);
      await _pumpApp(tester,
          seeded: seed, notificationsEnabled: false, batteryExempt: false);

      expect(find.textContaining('ההתראות כבויות'), findsOneWidget);
      expect(find.textContaining('ניהול הסוללה'), findsNothing);
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
    testWidgets('scheduling records the nearest reminder on the event',
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
            eventRepositoryProvider.overrideWithValue(repo),
            notificationServiceProvider.overrideWithValue(notif),
            calendarServiceProvider.overrideWithValue(
              EventCalendarService(now: () => _fixedNow),
            ),
          ],
          child: const EventsApp(),
        ),
      );
      await _pumpUntilFound(
          tester, find.byType(EventCard), 'the event list');

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
            eventRepositoryProvider.overrideWithValue(repo),
            notificationServiceProvider.overrideWithValue(notif),
            calendarServiceProvider.overrideWithValue(
              EventCalendarService(now: () => nearest.add(const Duration(minutes: 1))),
            ),
          ],
          child: const EventsApp(),
        ),
      );
      await _pumpUntilFound(
          tester, find.byType(EventCard), 'the event list');

      expect(notif.log.where((e) => e.startsWith('missed:')), isEmpty,
          reason: 'no catch-up notification may be delivered');
    });
  });

  group('configurable reminder timing', () {
    test('the default is still Tuesday of the week before', () {
      final cal = EventCalendarService();
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      expect(m.reminderMode, ReminderMode.weekdayOfPreviousWeek);
      expect(m.reminderValue, DateTime.tuesday);
      expect(cal.reminderDate(m, from: _fixedNow).weekday, DateTime.tuesday);
    });

    test('every weekday choice lands on that weekday, a week earlier', () {
      final cal = EventCalendarService();
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

        final eventDate = cal.nextOccurrenceDate(m, from: _fixedNow);
        expect(reminder.isBefore(eventDate), isTrue,
            reason: 'reminder must precede the event');
      }
    });

    test('fixedDaysBefore gives exactly that many calendar days', () {
      final cal = EventCalendarService();
      for (final days in const [1, 3, 7, 14, 30]) {
        final m = _seed(
          id: 1,
          name: 'x',
          day: 27,
          month: HebrewMonth.av,
          reminderMode: ReminderMode.fixedDaysBefore,
          reminderValue: days,
        );
        final eventDate = cal.nextOccurrenceDate(m, from: _fixedNow);
        final reminder = cal.reminderDate(m, from: _fixedNow);

        final gap = DateTime.utc(
                eventDate.year, eventDate.month, eventDate.day)
            .difference(
                DateTime.utc(reminder.year, reminder.month, reminder.day))
            .inDays;
        expect(gap, days, reason: 'asked for $days days before');
      }
    });

    test('fixedDaysBefore survives DST and month boundaries', () {
      final cal = EventCalendarService();
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

  group('a month that is 29 days in some years and 30 in others', () {
    // The calendar was taught to fall back to the last day of the month
    // rather than skip the year - but the picker and the validator still
    // asked the CURRENT year, so in a short year the date could not be
    // entered at all, and editing an existing one silently rolled it back
    // to the 29th.
    final calendar = EventCalendarService(now: () => _fixedNow);

    test('Cheshvan and Kislev can reach 30, Iyar never can', () {
      for (final month in [HebrewMonth.cheshvan, HebrewMonth.kislev]) {
        expect(
          calendar.maxDaysInMonth(
              calendar: CalendarSystem.hebrew,
              month: month.toStorage().baseMonth,
              adarType: month.toStorage().adarType),
          30,
          reason: '$month runs to thirty in some years',
        );
      }
      // The other half of the rule, and the part that makes it falsifiable:
      // a date that exists in no year at all must still be refused.
      expect(
        calendar.maxDaysInMonth(
            calendar: CalendarSystem.hebrew,
            month: HebrewMonth.iyar.index,
            adarType: AdarType.none),
        29,
      );
    });

    test('the thirtieth is accepted in Cheshvan and refused in Iyar', () {
      expect(
        calendar.isDateEverValid(
            calendar: CalendarSystem.hebrew,
            day: 30,
            month: HebrewMonth.cheshvan.index,
            adarType: AdarType.none),
        isTrue,
      );
      expect(
        calendar.isDateEverValid(
            calendar: CalendarSystem.hebrew,
            day: 30,
            month: HebrewMonth.iyar.index,
            adarType: AdarType.none),
        isFalse,
      );
    });

    test('a short year reports the day it actually falls on', () {
      // The occurrence line carries a year and sits directly under the
      // Gregorian date, so it must agree with it. It used to print the
      // STORED day: "ל' בחשוון תשפ״ט" beside 18/11/2028, which is כ"ט.
      final m = _seed(
          id: 1, name: 'ל בחשוון', day: 30, month: HebrewMonth.cheshvan);

      // תשפ״ט - Cheshvan runs to 29 days.
      final short = EventCalendarService(now: () => DateTime(2028, 1, 1));
      expect(short.formatNextOccurrence(m), contains("כ\"ט בחשוון"));
      expect(short.formatNextOccurrence(m), isNot(contains("ל' בחשוון")));

      // תשפ״ח - Cheshvan runs to 30, and nothing moves.
      final full = EventCalendarService(now: () => DateTime(2027, 1, 1));
      expect(full.formatNextOccurrence(m), contains("ל' בחשוון"));

      // The recurring anniversary keeps its own name in both: that line is
      // what the event IS, and it carries no year.
      expect(short.formatEventDate(m), "ל' בחשוון");
    });

    test('a service that has answered other questions answers the same', () {
      // The Hebrew conversion is memoised, which is only safe because it is
      // pure - the result depends on day, month, adar type and the Hebrew
      // year, and on nothing else. This is the property that says so: one
      // service asked about everything must agree with a fresh service asked
      // about one thing.
      final shared = EventCalendarService(now: () => _fixedNow);

      final dates = <Event>[
        for (final month in HebrewMonth.values)
          for (final day in [1, 14, 29, 30])
            _seed(id: 1, name: 'x', day: day, month: month),
      ];

      // Warm it on everything first, so every later answer is a cache hit.
      for (final m in dates) {
        shared.nextOccurrenceDate(m);
      }

      for (final m in dates) {
        final fresh = EventCalendarService(now: () => _fixedNow);
        expect(shared.nextOccurrenceDate(m), fresh.nextOccurrenceDate(m),
            reason: 'day ${m.day} of ${m.hebrewMonth}');
        expect(shared.formatNextOccurrence(m),
            fresh.formatNextOccurrence(m));
      }
    });

    test('the fields outside the key really are outside it', () {
      // Two events that differ in everything EXCEPT the Hebrew date must
      // share a cache entry and still be right - and one that differs in the
      // date must not.
      final c = EventCalendarService(now: () => _fixedNow);

      final a = _seed(id: 1, name: 'א', day: 14, month: HebrewMonth.cheshvan);
      final b = _seed(
        id: 2,
        name: 'ב',
        day: 14,
        month: HebrewMonth.cheshvan,
        enabled: false,
        reminderMode: ReminderMode.fixedDaysBefore,
        reminderValue: 3,
        startYear: 5780,
      );
      final other =
          _seed(id: 3, name: 'ג', day: 15, month: HebrewMonth.cheshvan);

      expect(c.nextOccurrenceDate(b), c.nextOccurrenceDate(a));
      expect(c.nextOccurrenceDate(other), isNot(c.nextOccurrenceDate(a)));
    });

    test('a short year says so, and only a short year does', () {
      final m = _seed(
          id: 1, name: 'ל בחשוון', day: 30, month: HebrewMonth.cheshvan);

      // תשפ״ט - Cheshvan is 29 days, so the note has to explain itself.
      final note = EventCalendarService(now: () => DateTime(2028, 1, 1))
          .adjustedDayNote(m);
      expect(note, isNotNull);
      expect(note, contains("ל' בחשוון"));
      expect(note, contains('אינו קיים'));
      expect(note, contains("כ\"ט"));

      // תשפ״ח - the day exists, so there is nothing to explain and the card
      // must stay quiet. A note that always shows is noise, not help.
      expect(
        EventCalendarService(now: () => DateTime(2027, 1, 1))
            .adjustedDayNote(m),
        isNull,
      );

      // An ordinary date never triggers it in any year.
      final ordinary = _seed(
          id: 2, name: 'רגיל', day: 14, month: HebrewMonth.cheshvan);
      expect(
        EventCalendarService(now: () => DateTime(2028, 1, 1))
            .adjustedDayNote(ordinary),
        isNull,
      );
    });

    testWidgets('the card explains the day it moved to', (tester) async {
      _phoneViewport(tester);
      // A clock inside תשפ״ט, where Cheshvan runs to 29 days.
      await _pumpApp(
        tester,
        seeded: [
          _seed(id: 1, name: 'סבא יעקב', day: 30, month: HebrewMonth.cheshvan),
        ],
        now: DateTime(2028, 1, 1),
      );

      expect(find.textContaining('אינו קיים'), findsOneWidget);
      expect(find.textContaining("כ\"ט"), findsWidgets);
    });

    testWidgets('the wheel offers thirty days in Cheshvan', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventDatePicker(
            calendar: CalendarSystem.hebrew,
            initialDay: 30,
            initialMonth: HebrewMonth.cheshvan.index,
            onChanged: (_, __, ___) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // The day survives being shown. Before this, initState clamped it to
      // the current year's length - so opening the edit screen in a short
      // year quietly changed the event's date on the next save.
      expect(find.text("ל' בחשוון"), findsWidgets);
    });

    testWidgets('the form saves it instead of rejecting it', (tester) async {
      EventFormResult? submitted;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventForm(
            initial: _seed(
              id: 1,
              name: 'ל בחשוון',
              day: 30,
              month: HebrewMonth.cheshvan,
            ),
            defaultHour: 9,
            defaultMinute: 0,
            onSubmit: (r) => submitted = r,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final save = find.widgetWithText(FilledButton, 'שמירה');
      await _revealInForm(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(find.textContaining('אינו קיים'), findsNothing,
          reason: 'the calendar schedules this date; the form must accept it');
      expect(submitted?.day, 30);
      // The form hands back the storage shape, so no caller has to convert.
      expect(submitted?.month, HebrewMonth.cheshvan.index);
      expect(submitted?.calendar, CalendarSystem.hebrew);
    });
  });

  group('an event that follows the Gregorian calendar', () {
    final cal = EventCalendarService(now: () => _fixedNow);

    Event gregorian({
      int day = 14,
      int month = 11,
      int? startYear,
      EventKind kind = EventKind.anniversary,
      ReminderMode reminderMode = ReminderMode.weekdayOfPreviousWeek,
      int reminderValue = Event.defaultReminderWeekday,
    }) =>
        _seed(
          id: 1,
          name: 'אנחנו',
          calendar: CalendarSystem.gregorian,
          day: day,
          gregorianMonth: month,
          kind: kind,
          startYear: startYear,
          reminderMode: reminderMode,
          reminderValue: reminderValue,
        );

    test('recurs on the same day and month, every year', () {
      // _fixedNow is 31/07/2026, so 14/11 is still ahead this year.
      expect(cal.nextOccurrenceDate(gregorian(), from: _fixedNow),
          DateTime(2026, 11, 14));

      // And the day after it passes, the next one is a year later - the
      // same rollover the Hebrew half does, counted in Gregorian years.
      expect(
        cal.nextOccurrenceDate(gregorian(), from: DateTime(2026, 11, 15)),
        DateTime(2027, 11, 14),
      );
    });

    test('the occurrence on the day itself is today, not next year', () {
      expect(
        cal.nextOccurrenceDate(gregorian(), from: DateTime(2026, 11, 14, 23)),
        DateTime(2026, 11, 14),
        reason: 'an event is not over until the day is',
      );
    });

    test('the reminder rule is the same rule', () {
      // 14/11/2026 is a Saturday. Its week starts Sunday 08/11, so the week
      // before starts 01/11 and its Tuesday is the 3rd.
      final reminder = cal.reminderDate(gregorian(), from: _fixedNow);
      expect(reminder, DateTime(2026, 11, 3, 9));
      expect(reminder.weekday, DateTime.tuesday);

      // And the fixed-interval mode counts plain days, as ever.
      expect(
        cal.reminderDate(
            gregorian(
              reminderMode: ReminderMode.fixedDaysBefore,
              reminderValue: 10,
            ),
            from: _fixedNow),
        DateTime(2026, 11, 4, 9),
      );
    });

    test('the window is filled a fixed number of years ahead', () {
      final dates = cal.futureReminderDates(gregorian(), from: _fixedNow);

      expect(dates, hasLength(EventCalendarService.scheduleHorizonYears + 1));
      expect(dates.first, DateTime(2026, 11, 3, 9));
      // One per year, in order, each one a Tuesday.
      expect(dates.map((d) => d.year).toList(), [2026, 2027, 2028]);
      expect(dates.every((d) => d.weekday == DateTime.tuesday), isTrue);
      for (var i = 1; i < dates.length; i++) {
        expect(dates[i].isAfter(dates[i - 1]), isTrue);
      }
    });

    group('the 29th of February', () {
      Event leapDay() => gregorian(day: 29, month: 2);

      test('falls on the 28th in a year that has no 29th', () {
        // **Not the 1st of March.** DateTime(2027, 2, 29) does not fail - it
        // silently rolls over - which would move the event to another month.
        expect(cal.nextOccurrenceDate(leapDay(), from: DateTime(2027, 1, 1)),
            DateTime(2027, 2, 28));
        expect(cal.nextOccurrenceDate(leapDay(), from: DateTime(2026, 8, 1)),
            DateTime(2027, 2, 28));
      });

      test('and on the 29th in a leap year', () {
        expect(cal.nextOccurrenceDate(leapDay(), from: DateTime(2028, 1, 1)),
            DateTime(2028, 2, 29));
      });

      test('never skips a year', () {
        // The Hebrew half learned this the hard way: skipping the years a
        // date does not exist in left an event with no reminder at all.
        final years = [
          for (var y = 2027; y <= 2031; y++)
            cal
                .futureReminderDates(leapDay(),
                    from: DateTime(y, 1, 1), years: 0)
                .length,
        ];
        expect(years, everyElement(1));
      });

      test('the card says why the day moved', () {
        final note = cal.adjustedDayNote(leapDay(), from: DateTime(2027, 1, 1));
        expect(note, '29 בפברואר אינו קיים ב-2027, ולכן האירוע ב-28');

        // And stays quiet in a year where nothing moved.
        expect(cal.adjustedDayNote(leapDay(), from: DateTime(2028, 1, 1)),
            isNull);
      });

      test('the input accepts it, and refuses the 30th', () {
        expect(
          cal.isDateEverValid(
              calendar: CalendarSystem.gregorian, day: 29, month: 2),
          isTrue,
          reason: 'it exists every fourth year',
        );
        // The other half of the rule, and the part that makes it falsifiable.
        expect(
          cal.isDateEverValid(
              calendar: CalendarSystem.gregorian, day: 30, month: 2),
          isFalse,
        );
        expect(
          cal.isDateEverValid(
              calendar: CalendarSystem.gregorian, day: 31, month: 4),
          isFalse,
          reason: 'April has thirty days in every year there is',
        );
      });
    });

    test('the date reads in Hebrew words, not in digits', () {
      expect(cal.formatEventDate(gregorian()), '14 בנובמבר');
      expect(cal.formatNextOccurrence(gregorian(), from: _fixedNow),
          '14 בנובמבר 2026');
    });

    testWidgets('the card marks it as Gregorian, and the Hebrew one is not'
        ' marked', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        gregorian(),
        _seed(id: 2, name: 'דנה', day: 14, month: HebrewMonth.cheshvan),
      ]);

      // Hebrew is the default, so a tag on every card would mark nothing.
      expect(find.text(CalendarSystem.gregorian.label), findsOneWidget);
      expect(find.text(CalendarSystem.hebrew.label), findsNothing);

      // The recurring date, in each calendar's own words.
      expect(find.text('14 בנובמבר'), findsOneWidget);
      expect(find.text('י"ד בחשוון'), findsOneWidget);
    });

    testWidgets('both calendars share one list, one sort and one budget',
        (tester) async {
      _phoneViewport(tester);
      // 14/11/2026 (Gregorian) comes before י"ד בחשוון -> 25/10/2026? No:
      // the Hebrew one is the 25th of October, so it is nearer.
      await _pumpApp(tester, seeded: [
        gregorian(),
        _seed(id: 2, name: 'דנה', day: 14, month: HebrewMonth.cheshvan),
      ]);

      final names = tester
          .widgetList<EventCard>(find.byType(EventCard))
          .map((c) => c.event.name)
          .toList();
      expect(names, ['דנה', 'אנחנו'],
          reason: 'sorted by the upcoming date, whatever calendar it is in');

      // And the alarm budget treats them as one pool, because Android's
      // ceiling counts alarms and not calendars.
      final budget = NotificationService.allocateBudget(
        [gregorian(), _seed(id: 2, name: 'דנה', day: 14)],
        cal,
        budget: 4,
      );
      expect(budget[1]! + budget[2]!, 4);
    });

    test('the reminder text names the Gregorian date', () async {
      // The body is baked at schedule time, and this is what it says.
      final service = NotificationService(calendar: cal);
      final body = service.bodyFor(
        gregorian(startYear: 2001),
        DateTime(2026, 11, 3, 9),
        DateTime(2026, 11, 14),
      );

      expect(body, contains('יום הנישואין ה-25 של אנחנו'));
      expect(body, contains('14 בנובמבר'));
      expect(body, contains('יום שבת 14/11/2026'));
    });
  });

  group('switching an event between the calendars', () {
    final cal = EventCalendarService(now: () => _fixedNow);

    test('the conversion lands on the same actual day', () {
      // The strongest thing to assert, and it needs no hardcoded gematria:
      // take a Gregorian date, convert it to Hebrew in a given year, and the
      // Hebrew date's occurrence in that same year must be the day we
      // started from.
      final converted = cal.convertDate(
        from: CalendarSystem.gregorian,
        to: CalendarSystem.hebrew,
        day: 14,
        month: 11,
        referenceYear: 2001,
      )!;

      final asHebrew = Event(
        name: 'x',
        calendar: CalendarSystem.hebrew,
        day: converted.day,
        month: converted.month,
        adarType: converted.adarType,
        notificationHour: 9,
        notificationMinute: 0,
        createdAt: DateTime(2024),
      );

      expect(
        cal.nextOccurrenceDate(asHebrew, from: DateTime(2001, 1, 1)),
        DateTime(2001, 11, 14),
      );
    });

    test('and back again', () {
      final toHebrew = cal.convertDate(
        from: CalendarSystem.gregorian,
        to: CalendarSystem.hebrew,
        day: 14,
        month: 11,
        referenceYear: 2001,
      )!;
      final back = cal.convertDate(
        from: CalendarSystem.hebrew,
        to: CalendarSystem.gregorian,
        day: toHebrew.day,
        month: toHebrew.month,
        adarType: toHebrew.adarType,
        referenceYear: toHebrew.year,
      )!;

      expect((back.day, back.month), (14, 11));
    });

    test('the anniversary count survives the switch', () {
      // What the user sees on the card must not change because they picked a
      // different calendar for the same wedding.
      final gregorian = _seed(
        id: 1,
        name: 'אנחנו',
        calendar: CalendarSystem.gregorian,
        day: 14,
        gregorianMonth: 11,
        kind: EventKind.anniversary,
        startYear: 2001,
      );
      expect(cal.anniversaryNumber(gregorian, from: _fixedNow), 25);

      final converted = cal.convertDate(
        from: CalendarSystem.gregorian,
        to: CalendarSystem.hebrew,
        day: gregorian.day,
        month: gregorian.month,
        referenceYear: gregorian.startYear,
      )!;
      final hebrew = gregorian.copyWith(
        calendar: CalendarSystem.hebrew,
        day: converted.day,
        month: converted.month,
        adarType: converted.adarType,
        startYear: converted.year,
      );

      expect(cal.anniversaryNumber(hebrew, from: _fixedNow), 25,
          reason: 'the year has to be converted along with the date');
    });

    testWidgets('the form converts the date instead of relabelling it',
        (tester) async {
      EventFormResult? submitted;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventForm(
            initial: _seed(
              id: 1,
              name: 'אנחנו',
              day: 14,
              month: HebrewMonth.cheshvan,
              kind: EventKind.anniversary,
            ),
            defaultHour: 9,
            defaultMinute: 0,
            onSubmit: (r) => submitted = r,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final toGregorian = find.text(CalendarSystem.gregorian.label);
      await _revealInForm(tester, toGregorian);
      await tester.tap(toGregorian);
      await tester.pumpAndSettle();
      // The conversion announces itself in a SnackBar, which on a phone
      // viewport sits right over the save button - so let it go first.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      final save = find.widgetWithText(FilledButton, 'שמירה');
      await _revealInForm(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(submitted?.calendar, CalendarSystem.gregorian);
      // **Not 14 בנובמבר.** Keeping the numbers would silently move the
      // event to a different day - the same class of bug as the picker that
      // used to roll the 30th down to the 29th without saying so.
      final asSaved = Event(
        name: 'x',
        calendar: CalendarSystem.gregorian,
        day: submitted!.day,
        month: submitted!.month,
        adarType: submitted!.adarType,
        notificationHour: 9,
        notificationMinute: 0,
        createdAt: DateTime(2024),
      );
      final hebrewOriginal =
          _seed(id: 1, name: 'x', day: 14, month: HebrewMonth.cheshvan);
      expect(
        cal.nextOccurrenceDate(asSaved, from: _fixedNow),
        cal.nextOccurrenceDate(hebrewOriginal, from: _fixedNow),
        reason: 'the converted date must fall on the very same day',
      );
    });

    testWidgets('and says so, because a silent change is the bug',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventForm(
            initial: _seed(
                id: 1, name: 'אנחנו', day: 14, month: HebrewMonth.cheshvan),
            defaultHour: 9,
            defaultMinute: 0,
            onSubmit: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final toGregorian = find.text(CalendarSystem.gregorian.label);
      await _revealInForm(tester, toGregorian);
      await tester.tap(toGregorian);
      await tester.pumpAndSettle();

      expect(find.textContaining('התאריך הומר ל'), findsOneWidget);
    });

    testWidgets('the wheel then offers Gregorian months', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventForm(
            initial: _seed(
              id: 1,
              name: 'דנה',
              calendar: CalendarSystem.gregorian,
              day: 14,
              gregorianMonth: 11,
            ),
            defaultHour: 9,
            defaultMinute: 0,
            onSubmit: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await _revealInForm(tester, find.byType(EventDatePicker));
      // The preview says what is selected, and the wheel is in Hebrew words.
      expect(find.text('14 בנובמבר'), findsWidgets);
      expect(find.text('נובמבר'), findsWidgets);
      expect(find.text('חשוון'), findsNothing);
    });

    test('a Gregorian year is offered as digits, a Hebrew one in gematria',
        () {
      expect(cal.formatYear(CalendarSystem.gregorian, 1998), '1998');
      expect(cal.formatYear(CalendarSystem.hebrew, 5758),
          isNot(matches(RegExp(r'\d'))));
      // The typed-year dialog reads both, which is what lets one dialog
      // serve both calendars.
      expect(cal.parseHebrewYear('1998'), 1998);
      expect(cal.parseHebrewYear('תשנ"ח'), 5758);
    });
  });

  group('the colour of the app', () {
    test('an unknown value falls back rather than throwing', () {
      // A backup from a newer build, or a corrupted row. A theme is a
      // preference, never a reason to fail to start.
      expect(ThemeSeed.fromDb(null), ThemeSeed.fallback);
      expect(ThemeSeed.fromDb('chartreuse'), ThemeSeed.fallback);
      expect(ThemeSeed.fromDb(ThemeSeed.turquoise.dbValue), ThemeSeed.turquoise);
    });

    test('the default is one of the bright ones', () {
      // An app about birthdays should look like one the moment it opens, so
      // the default is a saturated hue and not the muted purple this screen
      // inherited from the memorial version.
      expect(ThemeSeed.fallback, ThemeSeed.rose);
      expect(ThemeSeed.values.map((s) => s.color).toSet(),
          hasLength(ThemeSeed.values.length),
          reason: 'two swatches that look alike are not a choice');
    });

    testWidgets('choosing one repaints the app and stores it', (tester) async {
      _phoneViewport(tester);
      final (repo, _) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.byType(SettingsScreen), 'SettingsScreen');

      final before = Theme.of(
              tester.element(find.byType(SettingsScreen)))
          .colorScheme
          .primary;

      final swatch = find.byKey(const ValueKey('seed-turquoise'));
      await tester.scrollUntilVisible(swatch, 120,
          scrollable: find
              .descendant(
                of: find.byType(SettingsScreen),
                matching: find.byType(Scrollable),
              )
              .first);
      await tester.tap(swatch);
      await tester.pumpAndSettle();

      final after = Theme.of(
              tester.element(find.byType(SettingsScreen)))
          .colorScheme
          .primary;
      expect(after, isNot(before), reason: 'the whole theme is derived');

      // Stored, or it would be back to the default on the next launch -
      // which is the whole point of a preference.
      expect(await repo.readSetting(ThemeSeedNotifier.storageKey),
          ThemeSeed.turquoise.dbValue);
    });
  });

  group('the kind of event', () {
    List<Event> threeKinds() => [
          _seed(
            id: 1,
            name: 'דנה',
            day: 14,
            month: HebrewMonth.cheshvan,
            kind: EventKind.birthday,
          ),
          _seed(
            id: 2,
            name: 'אנחנו',
            day: 3,
            month: HebrewMonth.nisan,
            kind: EventKind.anniversary,
          ),
          _seed(
            id: 3,
            name: 'משהו אחר',
            day: 10,
            month: HebrewMonth.av,
            kind: EventKind.other,
          ),
        ];

    testWidgets('each kind carries its own mark and name', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: threeKinds());

      // The mark is what identifies the row at a glance; the name beside it
      // means no legend is needed to read one. Drawn and never an emoji —
      // see EventCard.kindMark for why.
      expect(
        find.descendant(
          of: find.byType(EventCard),
          matching: find.byIcon(Icons.cake),
        ),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: find.byType(EventCard),
          matching: find.byType(WeddingRings),
        ),
        findsWidgets,
        reason: 'Material has no wedding rings, so they are painted',
      );
      expect(
        find.descendant(
          of: find.byType(EventCard),
          matching: find.byIcon(Icons.celebration),
        ),
        findsWidgets,
      );
      for (final kind in [
        EventKind.birthday,
        EventKind.anniversary,
        EventKind.other,
      ]) {
        expect(find.text(kind.label), findsWidgets);
      }
      expect(find.byType(EventCard), findsNWidgets(3));
    });

    testWidgets('every kind has a colour of its own', (tester) async {
      // The colour is what tells a birthday from an anniversary before a
      // single word is read, so two kinds sharing one would be a silent
      // regression.
      final colours = {
        for (final k in EventKind.values) EventCard.kindColor(k),
      };
      expect(colours.length, EventKind.values.length);
    });

    testWidgets('the list can be narrowed to one kind', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: threeKinds());

      expect(find.byType(EventCard), findsNWidgets(3));

      final chip =
          find.widgetWithText(FilterChip, '${EventKind.anniversary.label} (1)');
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();

      expect(find.byType(EventCard), findsOneWidget);
      expect(find.text('אנחנו'), findsOneWidget);
      expect(find.text('דנה'), findsNothing);

      // Tapping the same chip again clears it - a filter you cannot undo
      // from the chip you set it with is a trap.
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.byType(EventCard), findsNWidgets(3));
    });

    testWidgets('the kind row is always there', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'דנה', day: 10, month: HebrewMonth.av),
      ]);

      // The memorial version of this screen hid the row until something was
      // marked, because most rows were unmarked and it was permanent noise.
      // Here every event HAS a kind, so the row is always a filter whose
      // meaning is clear.
      expect(find.textContaining('כל הסוגים'), findsOneWidget);
    });

    testWidgets('an empty kind says which one, not just "empty"',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: [
        _seed(
          id: 1,
          name: 'דנה',
          day: 14,
          month: HebrewMonth.cheshvan,
          kind: EventKind.birthday,
        ),
      ]);

      final empty =
          find.widgetWithText(FilterChip, '${EventKind.engagement.label} (0)');
      await tester.ensureVisible(empty);
      await tester.pumpAndSettle();
      await tester.tap(empty);
      await tester.pumpAndSettle();

      expect(find.text('אין אירועים מסוג "${EventKind.engagement.label}"'),
          findsOneWidget);
      expect(find.byType(EventCard), findsNothing);
    });

    testWidgets('the kind can be changed from the list itself',
        (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester, seeded: threeKinds());
      notif.log.clear();

      // The chip on the card is the handle.
      await tester.tap(_kindChipOf('דנה'));
      await tester.pumpAndSettle();

      // The sheet says which event, and marks where it stands now.
      expect(find.text('דנה'), findsWidgets);
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester
          .tap(find.widgetWithText(ListTile, EventKind.anniversary.label));
      await tester.pumpAndSettle();

      expect(repo.items.firstWhere((m) => m.id == 1).kind,
          EventKind.anniversary);
      // And it says so, because with a kind filter on the card would vanish
      // from the list the moment it changes.
      expect(
        find.descendant(
            of: find.byType(SnackBar),
            matching: find.textContaining(EventKind.anniversary.label)),
        findsOneWidget,
      );
    });

    testWidgets('pressing the chip does not also open the edit screen',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: threeKinds());

      await tester.tap(_kindChipOf('דנה'));
      await tester.pumpAndSettle();

      // The card's own InkWell wraps the whole thing, so without the nested
      // one swallowing the tap this would have done both.
      expect(find.byType(EditEventScreen), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('changing the kind reschedules the alarms', (tester) async {
      _phoneViewport(tester);
      final (_, notif) = await _pumpApp(tester, seeded: threeKinds());
      notif.log.clear();

      await tester.tap(_kindChipOf('דנה'));
      await tester.pumpAndSettle();
      await tester
          .tap(find.widgetWithText(ListTile, EventKind.anniversary.label));
      await tester.pumpAndSettle();

      // **The opposite of the memorial version**, and for a concrete reason:
      // there the category was a visual label and rescheduling would have
      // been pointless work on the notification store. Here the kind is part
      // of the content baked into the notification - the title
      // ("🎂 יום הולדת") and the opening words ("יום ההולדת של דנה") both
      // come from it - so a change that did not reschedule would leave
      // notifications announcing the old kind until the event was edited for
      // some other reason.
      expect(notif.log, isNotEmpty);
      expect(
        notif.log.where((e) => e.startsWith('schedule')),
        isNotEmpty,
        reason: 'the queued text still names the previous kind',
      );
    });

    testWidgets('the keyboard does not come back after choosing',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: threeKinds());

      // Searching is how you reach one event out of many, so this is the
      // ordinary way into the kind sheet - and the search field is the only
      // text field on the screen.
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'דנה');
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue,
          reason: 'the search field legitimately raises it');

      await tester.tap(_kindChipOf('דנה'));
      await tester.pumpAndSettle();
      await tester
          .tap(find.widgetWithText(ListTile, EventKind.anniversary.label));
      await tester.pumpAndSettle();

      // A modal route restores focus to whatever held it when it opened, and
      // that was the search field - so closing the sheet pulled the keyboard
      // straight back up over a list the user was trying to look at.
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('nor after opening and leaving the edit screen',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester, seeded: threeKinds());

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'דנה');
      await tester.pumpAndSettle();

      // Same cause, different route: any pushed screen restores focus on the
      // way back, so the fix has to sit where the list leaves itself.
      // Scoped to the card: with the search field holding the same text,
      // a bare find.text would also match what was typed into it.
      await tester.tap(find.descendant(
          of: find.byType(EventCard), matching: find.text('דנה')));
      await tester.pumpAndSettle();
      expect(find.byType(EditEventScreen), findsOneWidget);

      // pageBack מחפש כפתור חזרה של Cupertino; האפליקציה היא Material,
      // ותווית הכפתור בעברית, אז הסוג הוא מה שיציב כאן.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('picking one in the form saves it', (tester) async {
      EventFormResult? submitted;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventForm(
            defaultHour: 9,
            defaultMinute: 0,
            onSubmit: (r) => submitted = r,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'אנחנו');

      final choice = find.byKey(const ValueKey('kind-anniversary'));
      await _revealInForm(tester, choice);
      await tester.ensureVisible(choice);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pumpAndSettle();

      final save = find.widgetWithText(FilledButton, 'שמירה');
      await _revealInForm(tester, save);
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(submitted?.kind, EventKind.anniversary);
    });

    testWidgets('an existing kind opens already chosen', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventForm(
            initial: _seed(
              id: 1,
              name: 'אנחנו',
              day: 14,
              month: HebrewMonth.cheshvan,
              kind: EventKind.anniversary,
            ),
            defaultHour: 9,
            defaultMinute: 0,
            onSubmit: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final chip = find.byKey(const ValueKey('kind-anniversary'));
      await _revealInForm(tester, chip);
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('kind-birthday')))
            .selected,
        isFalse,
      );
    });

    testWidgets('every mark is drawn the same way every time', (tester) async {
      // One golden per kind, at a size where the shape is actually visible.
      // This is the only place the marks can be inspected: on a card they are
      // 18px, and inside a filter chip 16. It also pins the pairing of shape
      // and colour, which is what identifies a kind at a glance.
      for (final kind in EventKind.values) {
        const key = ValueKey('mark');
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 128,
                height: 128,
                child: Center(child: EventCard.kindMark(kind, size: 96)),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        await expectLater(
          find.byKey(key),
          matchesGoldenFile('goldens/mark_${kind.name}.png'),
        );
      }
    });

    test('an unknown kind degrades instead of throwing', () {
      // A backup from a newer build, or a corrupt field. An event always has
      // a kind, so there is nothing to represent "unset" - the generic one
      // is the honest fallback.
      expect(EventKind.fromDb('something_else'), EventKind.other);
      expect(EventKind.fromDb(null), EventKind.other);
    });

    test('a kind travels in the backup', () {
      final e = _seed(
        id: 1,
        name: 'אנחנו',
        day: 3,
        month: HebrewMonth.nisan,
        kind: EventKind.anniversary,
      );
      expect(Event.fromJson(e.toJson()).kind, EventKind.anniversary);
    });

    test('merging never reclassifies an event', () {
      final mine = _seed(
        id: 1, name: 'x', day: 1, month: HebrewMonth.tishrei,
        kind: EventKind.birthday,
      );
      final theirs = _seed(
        id: 2, name: 'x', day: 1, month: HebrewMonth.tishrei,
        kind: EventKind.anniversary,
      );

      // Unlike the memorial version, the kind is not in filledFrom at all:
      // every event has one, so there is no way to tell "never asked" from
      // "chosen deliberately" - and a merge is no place to guess.
      expect(mine.filledFrom(theirs).kind, EventKind.birthday);
    });

    test('each kind words the reminder in its own voice', () {
      // What the notification actually says comes from here, and "יום
      // ההולדת של דנה" versus "יום הנישואין של דנה" is the whole point of
      // the field.
      expect(EventKind.birthday.reminderPrefix, 'יום ההולדת של');
      expect(EventKind.anniversary.reminderPrefix, 'יום הנישואין של');
      expect(EventKind.engagement.reminderPrefix, 'יום האירוסין של');
      expect(EventKind.firstMet.reminderPrefix, 'יום ההיכרות של');
      expect(EventKind.birthday.ordinal(30), 'יום ההולדת ה-30');
      expect(EventKind.anniversary.ordinal(25), 'יום הנישואין ה-25');
      // The title is read first in the drawer, so it carries the mark.
      expect(EventKind.birthday.notificationTitle, '🎂 יום הולדת');
    });
  });

  group('a year that is not in the list', () {
    final calendar = EventCalendarService(now: () => _fixedNow);

    test('gematria and digits both read as the same year', () {
      // The list shows gematria, so that is what comes to hand - but someone
      // holding the number should not have to translate it in their head.
      for (final typed in [
        'תשפ״ו',
        'תשפו',
        'התשפ״ו',
        'ה׳תשפ״ו',
        "ה'תשפ\"ו",
        '5786',
        '  תשפ״ו  ',
      ]) {
        expect(calendar.parseHebrewYear(typed), 5786, reason: typed);
      }
    });

    test('the leading he is thousands, not five', () {
      // Summing it as a letter gives 791, and then the missing-thousand rule
      // turns that into 5791 - a wrong year that looks perfectly valid.
      expect(calendar.parseHebrewYear('התשפ״ו'),
          calendar.parseHebrewYear('תשפ״ו'));
      expect(calendar.parseHebrewYear('התר״ם'), 5640);
      expect(calendar.parseHebrewYear('תר״ם'), 5640);
    });

    test('what cannot be read comes back null, not a guess', () {
      for (final junk in [null, '', '   ', 'abc', '!!!', '???']) {
        expect(calendar.parseHebrewYear(junk), isNull, reason: '$junk');
      }
    });

    test('a year already below the thousand is left alone', () {
      // Four hundreds are past a thousand, so nothing is completed.
      expect(calendar.parseHebrewYear('תתתת'), 1600);
    });

    testWidgets('a year outside the range no longer breaks the edit screen',
        (tester) async {
      // This threw before the list learned to carry the chosen year: the
      // dropdown asserts that its value is among its items, and an event
      // imported with a year more than 120 years back took the whole form
      // down with it.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventForm(
            initial: _seed(
              id: 1,
              name: 'סבא רבא',
              day: 14,
              month: HebrewMonth.cheshvan,
              startYear: 5640,
            ),
            defaultHour: 9,
            defaultMinute: 0,
            onSubmit: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await _revealInForm(tester, find.byType(DropdownButtonFormField<int?>));
      expect(find.text('תר״מ'), findsWidgets,
          reason: 'the year it already holds must be offered, or it throws');
    });

    // Driving onChanged directly rather than opening the menu: the list holds
    // a hundred and twenty-odd items, so the escape hatch at its end is not
    // reliably built, and fighting that would test Flutter's menu rather than
    // this form. What the item IS gets its own assertion below.
    /// The items, read off the DropdownButton the form field builds - the
    /// form field itself keeps them in its closure and exposes nothing.
    List<DropdownMenuItem<int?>> yearItems(WidgetTester tester) =>
        tester
            .widget<DropdownButton<int?>>(find.descendant(
              of: find.byType(DropdownButtonFormField<int?>),
              matching: find.byType(DropdownButton<int?>),
            ))
            .items!;

    /// Exactly what a real tap does: the menu is wired straight to
    /// state.didChange, which sets the internal value AND calls onChanged.
    Future<void> choose(WidgetTester tester, int? value) async {
      tester
          .state<FormFieldState<int?>>(
              find.byType(DropdownButtonFormField<int?>))
          .didChange(value);
      await tester.pumpAndSettle();
    }

    Future<void> openForm(WidgetTester tester, {Event? initial,
        void Function(EventFormResult)? onSubmit}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventForm(
            initial: initial,
            defaultHour: 9,
            defaultMinute: 0,
            onSubmit: onSubmit ?? (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await _revealInForm(
          tester, find.byType(DropdownButtonFormField<int?>));
    }

    testWidgets('the escape hatch is offered, at the end of the list',
        (tester) async {
      await openForm(tester);
      final items = yearItems(tester);

      expect(items.last.value, -1,
          reason: 'last, not first - it is an escape hatch, not the norm');
      expect((items.last.child as Text).data, 'שנה אחרת…');
      // And the ordinary path is untouched: unknown still leads.
      expect(items.first.value, isNull);
    });

    testWidgets('typing a year puts it on the form', (tester) async {
      EventFormResult? submitted;
      await openForm(tester, onSubmit: (r) => submitted = r);

      await tester.enterText(find.byType(TextFormField).first, 'סבא רבא');
      await choose(tester, -1);

      await tester.enterText(find.byType(TextField).last, 'תר״ם');
      await tester.pumpAndSettle();
      // The dialog echoes what it understood, so a mistyped gematria is
      // visible before it is committed rather than after it is saved.
      expect(find.textContaining('5640'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'אישור'));
      await tester.pumpAndSettle();

      final save = find.widgetWithText(FilledButton, 'שמירה');
      await _revealInForm(tester, save);
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(submitted?.startYear, 5640);
    });

    testWidgets('cancelling leaves the field where it was', (tester) async {
      // The dropdown holds a value of its own and didUpdateWidget syncs it
      // only when initialValue changes - which a cancel does not do. Without
      // putting it back by hand the field stayed on the sentinel.
      await openForm(
        tester,
        initial: _seed(
          id: 1,
          name: 'x',
          day: 14,
          month: HebrewMonth.cheshvan,
          startYear: 5780,
        ),
      );

      await choose(tester, -1);
      await tester.tap(find.widgetWithText(TextButton, 'ביטול'));
      await tester.pumpAndSettle();

      final state = tester.state<FormFieldState<int?>>(
          find.byType(DropdownButtonFormField<int?>));
      expect(state.value, 5780, reason: 'the sentinel must not survive');
      expect(find.text('שנה אחרת…'), findsNothing);
    });

    testWidgets('a year that has not arrived yet is refused', (tester) async {
      await openForm(tester);
      await choose(tester, -1);

      await tester.enterText(find.byType(TextField).last, '9999');
      await tester.tap(find.widgetWithText(FilledButton, 'אישור'));
      await tester.pumpAndSettle();

      // Still open, and saying why - the same rule the list itself obeys.
      expect(find.text('השנה עדיין לא הגיעה'), findsOneWidget);
    });

    testWidgets('what cannot be read is refused too', (tester) async {
      await openForm(tester);
      await choose(tester, -1);

      // Latin, not Hebrew gibberish: "זזז" is perfectly good gematria (21,
      // completed to 5021). Nonsense Hebrew letters produce a nonsense year
      // on purpose - which is exactly what the echo line under the field is
      // there to expose, the same bargain the coordinates field makes.
      await tester.enterText(find.byType(TextField).last, 'abc');
      await tester.tap(find.widgetWithText(FilledButton, 'אישור'));
      await tester.pumpAndSettle();

      expect(find.text('לא הצלחתי לקרוא את השנה'), findsOneWidget);
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
          tester, find.byType(EventDatePicker), 'the add screen');

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
          tester, find.byType(EditEventScreen), 'EditEventScreen');
      await tester.tap(find.byIcon(Icons.delete_outline));
      await _pumpUntilFound(
          tester, find.text('מחיקת אירוע'), 'the delete confirmation');
      await tester.tap(find.widgetWithText(FilledButton, 'מחיקה'));

      await _pumpUntilFound(tester, find.byType(HomeScreen), 'HomeScreen');
      expect(await repo.getAll(), isEmpty);

      notif.releaseScheduling();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('the reminder offers a choice of how long before the event', () {
    final event = DateTime(2026, 8, 20, 0, 0);

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
      // Past the maximum interval the app can ever schedule.
      expect(NotificationService.daysBeforeFromActionId('reschedule:99'), isNull);
      expect(NotificationService.daysBeforeFromActionId('reschedule:x'), isNull);
    });

    test('labels read naturally in Hebrew', () {
      expect(NotificationService.snoozeChoiceLabel(1), 'יום לפני');
      expect(NotificationService.snoozeChoiceLabel(2), 'יומיים לפני');
      expect(NotificationService.snoozeChoiceLabel(7), '7 ימים לפני');
      expect(NotificationService.snoozeChoiceLabel(3), '3 ימים לפני');
    });

    test('every offered choice lands before the event and in the future',
        () {
      for (final daysOut in [1, 2, 5, 12, 40]) {
        final now = DateTime(
            event.year, event.month, event.day - daysOut, 8);
        final choices = NotificationService.choicesBefore(event, now);

        for (final d in choices) {
          final when = DateTime(event.year, event.month,
              event.day - d, EventCalendarService.rescheduledReminderHour);
          expect(when.isAfter(now), isTrue,
              reason: '$d days before is already in the past');
          // "Up to the day of the event, and not after" - the morning of
          // the event itself counts, a later day never does.
          expect(DateTime(when.year, when.month, when.day)
              .isAfter(DateTime(event.year, event.month, event.day)),
              isFalse,
              reason: '$d days before overshoots the event');
        }
      }
    });

    test('the list shrinks as the event approaches, then empties', () {
      List<int> at(int daysOut) => NotificationService.choicesBefore(
            event,
            DateTime(event.year, event.month, event.day - daysOut, 8),
          );

      expect(at(40).length, greaterThan(at(12).length));
      expect(at(12).length, greaterThan(at(5).length));
      // 5 is still offered at five days out: the target is 09:00 and "now"
      // here is 08:00, so it is an hour away, not in the past.
      expect(at(5), [0, 1, 2, 3, 4, 5], reason: 'four is not skipped');
      expect(at(2), [0, 1, 2]);
      // The morning of the event is still ahead at 08:00, so it stands as
      // the last thing left to choose.
      expect(at(0), [0]);
    });

    test('the payload carries the event date through the isolate', () {
      // The background isolate has no database, so without this it could not
      // work out what "3 days before" means.
      const body = 'יום ההולדת של דנה';
      final encoded = NotificationService.encodePayload(event, body);
      final decoded = NotificationService.decodePayload(encoded)!;

      expect(decoded.eventDate, event);
      expect(decoded.body, body);
    });

    test('a body containing a pipe survives decoding', () {
      const body = 'יום ההולדת של א|ב – כ"ז באב';
      final decoded = NotificationService.decodePayload(
          NotificationService.encodePayload(event, body))!;
      expect(decoded.body, body, reason: 'split on the first separator only');
    });

    test('a payload from an older build still yields its text', () {
      final decoded = NotificationService.decodePayload('plain old body')!;
      expect(decoded.eventDate, isNull);
      expect(decoded.body, 'plain old body');
    });

    test('the unversioned format from the previous build still decodes', () {
      // Those notifications are still queued on an upgraded install.
      final decoded = NotificationService.decodePayload(
          '${event.millisecondsSinceEpoch}|body')!;
      expect(decoded.eventDate, event);
      expect(decoded.body, 'body');
    });

    test('only the current version counts as current', () {
      const body = 'יום ההולדת של דנה';
      expect(
          NotificationService.isCurrentPayload(
              NotificationService.encodePayload(event, body)),
          isTrue);
      // This is what makes an upgrade reach notifications already queued:
      // their content was baked in when they were scheduled.
      expect(
          NotificationService.isCurrentPayload(
              '${event.millisecondsSinceEpoch}|$body'),
          isFalse);
      // A version that is not this one - the case a future bump creates.
      expect(
          NotificationService.isCurrentPayload(
              'v${NotificationService.payloadVersion + 1}|0|0|$body'),
          isFalse);
      expect(NotificationService.isCurrentPayload(null), isFalse);
    });

    test('a body that opens like a version marker is not eaten', () {
      const body = 'v9|not a version';
      final decoded = NotificationService.decodePayload(
          NotificationService.encodePayload(event, body))!;
      expect(decoded.body, body);
      expect(decoded.eventDate, event);
    });
  });

  group('the notification hands the full list to the app', () {
    final event = DateTime(2026, 8, 20);

    test('the ladder runs from the event day to the maximum, unbroken', () {
      final ladder = NotificationService.snoozeChoiceLadder;
      expect(ladder.first, 0, reason: 'the morning of the event itself');
      expect(ladder.last, maxDaysBeforeChoice);
      for (var i = 0; i < ladder.length; i++) {
        expect(ladder[i], i, reason: 'a number was skipped');
      }
    });

    test('every valid interval is offered, however many there are', () {
      // Forty days out the whole run is still ahead, and all of it has to
      // reach the user - which is exactly why it cannot live in the
      // notification, where Android renders three actions at most.
      final options = NotificationService.choicesBefore(
          event, DateTime(2026, 7, 11, 8));
      expect(options.length, maxDaysBeforeChoice + 1);
      for (var i = 0; i < options.length; i++) {
        expect(options[i], i, reason: 'a number was skipped');
      }
    });

    test('the response carries everything the screen needs', () {
      const body = 'יום ההולדת של דנה';
      final request = NotificationService.choiceRequestFrom(NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        id: 142,
        actionId: NotificationService.snoozeActionId,
        payload: NotificationService.encodePayload(event, body),
      ))!;

      expect(request.notificationId, 142);
      expect(request.eventDate, event);
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
            payload: NotificationService.encodePayload(event, 'x'),
          )),
          isNull);
    });
  });

  group('choosing a reminder time on screen', () {
    // The dialog builds its list against the real clock, not the pinned one,
    // so the event is placed far enough ahead that the whole ladder is
    // valid whenever the suite runs.
    ReminderChoiceRequest farOffRequest() {
      final now = DateTime.now();
      return ReminderChoiceRequest(
        notificationId: 142,
        eventDate: DateTime(now.year, now.month, now.day + 60),
        body: 'יום ההולדת של דנה',
      );
    }

    /// The row as the screen renders it: the interval, then the day it lands
    /// on. Composed with the same helpers the screen uses, so this agrees
    /// with a screen that has drifted — the literal-Hebrew test below is
    /// what pins the actual values.
    String rowLabel(ReminderChoiceRequest request, int d) {
      final at = NotificationService.snoozeTargetFor(request.eventDate, d);
      final label = NotificationService.snoozeChoiceLabel(d);
      return d == 0
          ? '$label, ${hebrewWeekdayLabel(at)}'
          : '$label ב${hebrewWeekdayLabel(at)}';
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

      expect(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(ListTile)),
          findsNWidgets(NotificationService.snoozeChoiceLadder.length),
          reason: 'this is the point of the screen - the notification cannot '
              'show more than three');
      // Longest lead time first, and the event day itself is last.
      final request = farOffRequest();
      expect(find.text(rowLabel(request, 30)), findsOneWidget);
      expect(find.text(rowLabel(request, 0)), findsOneWidget);
    });

    testWidgets('turning reminders off from the notification', (tester) async {
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      notif.onChooseReminder!(farOffRequest());
      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');
      await tester.tap(find.text(NotificationService.stopRemindingLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(repo.items.single.enabled, isFalse,
          reason: 'the event the notification belongs to is switched off');
      expect(find.textContaining('כובו'), findsOneWidget,
          reason: 'a silent switch-off would look like the app losing data');
    });

    testWidgets('the option stands even when no date is left', (tester) async {
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      // The event has passed, so every "days before" target is behind us.
      final now = DateTime.now();
      notif.onChooseReminder!(ReminderChoiceRequest(
        notificationId: 142,
        eventDate: DateTime(now.year, now.month, now.day - 1),
        body: 'יום ההולדת של דנה',
      ));
      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');

      expect(find.text('לא נותרו מועדים לפני האירוע'), findsOneWidget);
      await tester.tap(find.text(NotificationService.stopRemindingLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(repo.items.single.enabled, isFalse);
    });

    testWidgets('the chosen option is what gets rescheduled', (tester) async {
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      final request = farOffRequest();
      notif.onChooseReminder!(request);
      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');
      // The top of the list: with the whole run on offer the dialog scrolls,
      // and a tap further down would land off-screen.
      await tester.tap(find.text(rowLabel(request, 30)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(notif.log, contains('reschedule:30'));

      // The confirmation names the date that was SCHEDULED, read back from
      // what rescheduleReminder returned — not from the label that was
      // tapped. A message built from the label cannot contradict what was
      // scheduled, because it never knew it.
      final at = NotificationService.snoozeTargetFor(request.eventDate, 30);
      expect(
        find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('התזכורת נדחתה ל${hebrewDayAndDate(at)}')),
        findsOneWidget,
      );
    });

    testWidgets('the row names the real day, in literal Hebrew',
        (tester) async {
      // Every other assertion here composes its expectation with the same
      // helpers the screen uses, so a helper that was wrong in both places
      // would agree with itself. These strings were computed independently
      // and typed in: 12/08/2030 IS a Monday, and 30 days before it IS
      // Saturday 13/07. If the weekday were derived wrongly, nothing about
      // this test would still line up.
      _phoneViewport(tester); // 412dp — the width the row has to fit
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'דנה', day: 27, month: HebrewMonth.av),
      ]);

      notif.onChooseReminder!(ReminderChoiceRequest(
        notificationId: 142,
        eventDate: DateTime(2030, 8, 12),
        body: 'יום ההולדת של דנה',
      ));
      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');

      expect(find.text('30 ימים לפני ביום שבת'), findsOneWidget);
      expect(find.text('יום לפני ביום ראשון'), findsOneWidget);
      // The event day itself takes a comma: its label already opens with
      // 'ביום', and 'ביום האירוע ביום שני' stutters.
      expect(find.text('ביום האירוע, יום שני'), findsOneWidget);

      // And it fits: the longest row must not wrap or overflow at phone width.
      expect(tester.takeException(), isNull);
      final row = tester.widget<Text>(find.text('30 ימים לפני ביום שבת'));
      expect(row.maxLines, isNull,
          reason: 'ListTile does not cap the title — growth would be silent');
      final size = tester.getSize(find.text('30 ימים לפני ביום שבת'));
      expect(size.height, lessThan(40),
          reason: 'one line at 412dp; two lines would mean it wrapped');
    });

    testWidgets('choosing the event day itself reads as Hebrew',
        (tester) async {
      // This option produced 'התזכורת נדחתה לביום האירוע' — the ל of the
      // sentence on top of the ב of 'ביום'. It is the one choice whose label
      // begins with a preposition, so the other thirty hid it.
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'דנה', day: 27, month: HebrewMonth.av),
      ]);

      final request = farOffRequest();
      notif.onChooseReminder!(request);
      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');

      // Last in the list, so it needs bringing into view — the dialog builds
      // every row, but a tap still has to land on screen.
      final row = find.text(rowLabel(request, 0));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(notif.log, contains('reschedule:0'));
      expect(find.textContaining('לביום'), findsNothing,
          reason: 'the doubled preposition is what this test exists for');
      expect(
        find.descendant(
            of: find.byType(SnackBar),
            matching: find.textContaining('התזכורת נדחתה ליום ')),
        findsOneWidget,
      );
    });

    testWidgets('coming back to the app does not ask all over again',
        (tester) async {
      // The launch details do not clear themselves, and the home screen asks
      // on every resume. Without a guard the app offered to postpone a
      // reminder that had already been postponed, over and over.
      await _pumpApp(
        tester,
        seeded: [_seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av)],
        pendingChoice: farOffRequest(),
      );
      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');
      await tester.tap(find.textContaining('30 ימים לפני'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('מתי להזכיר?'), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('מתי להזכיר?'), findsNothing,
          reason: 'the postponement was already chosen');
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
      expect(notif.log, isNot(contains('reschedule:30')),
          reason: 'nothing moves until the user picks');
    });
  });

  group('an alarm that never fired is recovered', () {
    final event = DateTime(2026, 8, 20);
    const body = 'יום ההולדת של דנה';

    test('the payload carries when it was due', () {
      // That is the whole signal: a notification the plugin still lists as
      // pending, whose time has passed, was never delivered.
      final firesAt = DateTime(2026, 8, 13, 9);
      final decoded = NotificationService.decodePayload(
          NotificationService.encodePayload(event, body,
              firesAt: firesAt))!;

      expect(decoded.firesAt, firesAt);
      expect(decoded.eventDate, event);
      expect(decoded.body, body);
    });

    test('a body containing separators still survives', () {
      const awkward = 'יום ההולדת של א|ב – כ"ז באב';
      final decoded = NotificationService.decodePayload(
          NotificationService.encodePayload(event, awkward,
              firesAt: DateTime(2026, 8, 13, 9)))!;
      expect(decoded.body, awkward);
    });

    test('a payload with no firing time reads as having none', () {
      // The shape a version before this field would have: the body straight
      // after the event date. Reading a firing time out of it would tear the
      // text apart, so the parser only reads one when it parses as a number.
      final decoded = NotificationService.decodePayload(
          '${event.millisecondsSinceEpoch}|$body')!;

      expect(decoded.firesAt, isNull);
      expect(decoded.body, body, reason: 'the body must not be cut in half');
      expect(decoded.eventDate, event);
    });

    test('and so does one from before versions existed', () {
      final decoded = NotificationService.decodePayload('plain old body')!;
      expect(decoded.firesAt, isNull);
      expect(decoded.body, 'plain old body');
    });
  });

  group('a postponement is remembered, not just fired', () {
    final cal = EventCalendarService(now: () => _fixedNow);
    final base = _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av);

    Event postponedTo(DateTime at) =>
        base.copyWith(postponedReminderAt: at);

    test('it counts as the reminder date', () {
      final natural = cal.reminderDate(base, from: _fixedNow);
      final later = natural.add(const Duration(days: 3));

      expect(cal.activePostponement(postponedTo(later), from: _fixedNow),
          later);
      expect(cal.daysUntilReminder(postponedTo(later), from: _fixedNow),
          cal.daysUntilReminder(base, from: _fixedNow) + 3,
          reason: 'the card counts to where the reminder will actually land');
    });

    test('it replaces the coming occurrence instead of joining it', () {
      // Without the removal a reminder postponed before its original time
      // would arrive twice for the same event.
      final natural = cal.reminderDate(base, from: _fixedNow);
      final later = natural.add(const Duration(days: 1));
      final dates =
          cal.futureReminderDates(postponedTo(later), from: _fixedNow);

      expect(dates.first, later);
      final eventDate = cal.nextOccurrenceDate(base, from: _fixedNow);
      expect(dates.where((d) => d.isBefore(eventDate)).length, 1,
          reason: 'exactly one reminder for the coming event');
    });

    test('it expires on its own once it has passed', () {
      // No clean-up anywhere, so it has to stop applying by itself.
      final past = _fixedNow.subtract(const Duration(days: 1));
      expect(cal.activePostponement(postponedTo(past), from: _fixedNow),
          isNull);
    });

    test('it is refused past the event itself', () {
      final eventDate = cal.nextOccurrenceDate(base, from: _fixedNow);
      final tooLate = eventDate.add(const Duration(days: 1));
      expect(cal.activePostponement(postponedTo(tooLate), from: _fixedNow),
          isNull);

      // The morning of the event is still allowed - it is the last thing
      // the postponement list offers.
      final onTheDay = DateTime(eventDate.year, eventDate.month,
          eventDate.day, EventCalendarService.rescheduledReminderHour);
      expect(cal.activePostponement(postponedTo(onTheDay), from: _fixedNow),
          onTheDay);
    });

    test('it survives the database round trip', () {
      final at = DateTime(2027, 8, 25, 9);
      final restored = Event.fromMap(postponedTo(at).toMap());
      expect(restored.postponedReminderAt, at);
    });

    testWidgets('the card says it was postponed', (tester) async {
      // Seeded already postponed: the dialog builds its list against the real
      // clock while the card runs on the pinned one, so driving both in a
      // single test would only be testing the fixture.
      final natural = cal.reminderDate(base, from: _fixedNow);
      await _pumpApp(tester, seeded: [
        base.copyWith(
            postponedReminderAt: natural.add(const Duration(days: 3))),
      ]);

      expect(find.textContaining('נדחתה לעוד'), findsOneWidget);
    });

    testWidgets('choosing one writes it to the event', (tester) async {
      // Only the alarm knew about it before, and the next reschedule wiped it.
      final now = DateTime.now();
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      notif.onChooseReminder!(ReminderChoiceRequest(
        notificationId: 142,
        eventDate: DateTime(now.year, now.month, now.day + 60),
        body: 'יום ההולדת של דנה',
      ));
      await _pumpUntilFound(
          tester, find.text('מתי להזכיר?'), 'the choice dialog');
      await tester.tap(find.textContaining('30 ימים לפני'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(repo.items.single.postponedReminderAt, isNotNull);
      expect(repo.items.single.lastNotifiedAt,
          repo.items.single.postponedReminderAt,
          reason: 'otherwise the catch-up would call it a missed reminder');
    });
  });

  group('scheduling runs in date order, not id order', () {
    final cal = EventCalendarService(now: () => _fixedNow);

    test('the nearest reminder is scheduled first', () {
      // Ids ascending, reminders descending: if the loop followed ids, the
      // event due first would be scheduled last - and would be the one to
      // fall off if the platform started refusing alarms.
      final list = [
        _seed(id: 1, name: 'רחוק', day: 1, month: HebrewMonth.av),
        _seed(id: 2, name: 'בינוני', day: 1, month: HebrewMonth.iyar),
        _seed(id: 3, name: 'קרוב', day: 1, month: HebrewMonth.tishrei),
      ];

      final ordered = NotificationService.inReminderOrder(list, cal);
      final dates = [
        for (final m in ordered) cal.futureReminderDates(m).first,
      ];
      final sorted = [...dates]..sort();
      expect(dates, sorted, reason: 'nearest first, whatever the ids');
    });

    test('every event is still there, exactly once', () {
      final list = [
        for (var i = 0; i < 20; i++)
          _seed(
            id: i + 1,
            name: 'מנוח $i',
            day: (i % 29) + 1,
            month: HebrewMonth.values[i % HebrewMonth.values.length],
          ),
      ];

      final ordered = NotificationService.inReminderOrder(list, cal);
      expect(ordered.length, list.length);
      expect(ordered.map((m) => m.id).toSet(), list.map((m) => m.id).toSet());
    });

    test('an event with nothing upcoming sinks to the end', () {
      // It has no claim on the budget, so it must not sit in front of one
      // that does.
      final live = _seed(id: 1, name: 'חי', day: 1, month: HebrewMonth.av);
      final none = _seed(id: 2, name: 'כבוי', day: 1, month: HebrewMonth.av);

      final ordered = NotificationService.inReminderOrder(
        [none, live],
        _NoUpcomingFor(none.id!, now: () => _fixedNow),
      );
      expect(ordered.first.id, live.id);
      expect(ordered.last.id, none.id);
    });
  });

  group('the alarm budget is shared out across every event', () {
    final cal = EventCalendarService(now: () => _fixedNow);

    List<Event> names(int count) => [
          for (var i = 0; i < count; i++)
            _seed(
              id: i + 1,
              name: 'מנוח $i',
              day: (i % 29) + 1,
              month: HebrewMonth.values[i % HebrewMonth.values.length],
            ),
        ];

    int total(Map<int, int> allocation) =>
        allocation.values.fold(0, (sum, q) => sum + q);

    test('three hundred names fit, which is the whole point', () {
      // The old rule handed every event a fixed number of years, which
      // measures the wrong thing: Android caps the total, so that broke
      // silently at about 84 names and left events with nothing queued.
      final allocation =
          NotificationService.allocateBudget(names(300), cal);

      expect(total(allocation), NotificationService.maxScheduledAlarms,
          reason: 'the budget is spent, not exceeded');
      expect(allocation, isNotEmpty);
    });

    test('the ceiling holds at every size', () {
      for (final count in [1, 10, 50, 84, 300, 1000]) {
        expect(total(NotificationService.allocateBudget(names(count), cal)),
            lessThanOrEqualTo(NotificationService.maxScheduledAlarms),
            reason: '$count names');
      }
    });

    test('a short list still gets every occurrence in the horizon', () {
      final list = names(10);
      final allocation = NotificationService.allocateBudget(list, cal);

      for (final m in list) {
        expect(allocation[m.id!], cal.futureReminderDates(m).length,
            reason: '${m.name} keeps every occurrence in the horizon');
      }
    });

    test('nobody is allocated more occurrences than exist', () {
      final list = names(300);
      final allocation = NotificationService.allocateBudget(list, cal);

      for (final m in list) {
        final share = allocation[m.id!];
        if (share == null) continue;
        expect(share, lessThanOrEqualTo(cal.futureReminderDates(m).length));
      }
    });

    test('an event that is switched off takes no budget', () {
      final list = [
        ...names(3),
        _seed(
            id: 99,
            name: 'כבוי',
            day: 5,
            month: HebrewMonth.tishrei,
            enabled: false),
      ];
      expect(NotificationService.allocateBudget(list, cal)[99], isNull);
    });

    test('a tight budget goes to the soonest reminders', () {
      // Two names, and room for two alarms. Both must go to whichever
      // reminder comes first, not one each by position in the list.
      final list = names(2);
      final allocation =
          NotificationService.allocateBudget(list, cal, budget: 2);

      expect(total(allocation), 2);
      final first = [
        for (final m in list)
          (id: m.id!, when: cal.futureReminderDates(m).first),
      ]..sort((a, b) => a.when.compareTo(b.when));
      expect(allocation[first.first.id], isNotNull,
          reason: 'the nearest reminder of all must be scheduled');
    });
  });

  group('nothing is left scheduled for an event that is gone', () {
    final live = [
      _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      _seed(id: 4, name: 'סבתא רחל', day: 3, month: HebrewMonth.tishrei),
    ];

    test('a block belonging to no event is a leftover', () {
      // Deletion cancels in the background and is not awaited, so a kill at
      // the wrong moment strands a whole block. Nothing else notices: it is
      // counted neither in what is wanted nor in what an event already has.
      expect(NotificationService.isOrphanId(700, live), isTrue,
          reason: 'event 7 no longer exists');
      expect(NotificationService.isOrphanId(755, live), isTrue);
    });

    test('the old id scheme is a leftover too', () {
      // Before the blocks, the id was the raw event id. SQLite ids start
      // at 1, so block 0 is never legitimately owned.
      expect(NotificationService.isOrphanId(1, live), isTrue);
      expect(NotificationService.isOrphanId(99, live), isTrue);
    });

    test('a living event keeps its whole block', () {
      for (final slot in [0, 20, 50, 70, 99]) {
        expect(NotificationService.isOrphanId(100 + slot, live), isFalse,
            reason: 'slot $slot of event 1');
        expect(NotificationService.isOrphanId(400 + slot, live), isFalse,
            reason: 'slot $slot of event 4');
      }
    });
  });

  group('the settings screen shows what is actually scheduled', () {
    testWidgets('the rows read as a schedule, soonest first', (tester) async {
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);
      notif.report = PendingReport(
        rows: [
          PendingRow(
              name: 'סבתא רחל',
              scheduled: 2,
              expected: 2,
              stale: 0,
              nextReminder: DateTime(2026, 10, 6, 9)),
          PendingRow(
              name: 'סבא יעקב',
              scheduled: 3,
              expected: 3,
              stale: 1,
              nextReminder: DateTime(2027, 8, 24, 9)),
        ],
        total: 5,
        orphans: 0,
      );

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.text('מועדי התזכורות המתוזמנות'), 'the scheduled section');

      // Date first, because the rows are sorted by it - that is the only
      // place the allocation's choice is visible at all.
      expect(find.textContaining('06/10/26 · סבתא רחל (2)'), findsOneWidget);
      expect(find.textContaining('24/08/27 · סבא יעקב (3) · 1 לרענון'),
          findsOneWidget);
      expect(find.textContaining('סה"כ 5'), findsOneWidget);
    });

    testWidgets('a scheduling failure is named, not swallowed', (tester) async {
      // scheduleForEvent cancels before it schedules, so a throw leaves the
      // event with nothing queued at all. The only symptom is "the reminder
      // never fires, only when I open the app" - the catch-up. Without the
      // error on screen there is no way to tell that from a delivery problem.
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);
      notif.report = const PendingReport(
        rows: [
          PendingRow(
              name: 'סבא יעקב', scheduled: 0, expected: 0, stale: 0),
        ],
        total: 0,
        orphans: 0,
        lastError: 'כשל בתזמון — PlatformException(exact_alarms_not_permitted)',
        exactAlarmsAllowed: false,
      );

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.text('מועדי התזכורות המתוזמנות'), 'the scheduled section');

      expect(find.textContaining('כשל בתזמון'), findsOneWidget);
      expect(find.textContaining('exact_alarms_not_permitted'), findsOneWidget);
      expect(find.textContaining('הרשאת אזעקה מדויקת חסרה'), findsOneWidget);
    });

    testWidgets('a queue that does not match the plan is flagged in red',
        (tester) async {
      // Sorting cannot reveal anything - the rows are sorted by this code. The
      // check that means something is scheduled-versus-allocated: an event
      // due soon with no alarm, or leftovers from an earlier configuration.
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);
      notif.report = PendingReport(
        rows: [
          PendingRow(
              name: 'סבא יעקב',
              scheduled: 1,
              expected: 3,
              stale: 0,
              nextReminder: DateTime(2027, 8, 24, 9)),
        ],
        total: 1,
        orphans: 0,
      );

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.text('מועדי התזכורות המתוזמנות'), 'the scheduled section');

      // The gap is named, not just coloured - red alone says something is
      // wrong without saying what.
      expect(find.textContaining('1 מתוך 3'), findsOneWidget);
      final text = tester.widget<Text>(find.textContaining('1 מתוך 3'));
      expect(
          text.style?.color,
          Theme.of(tester.element(find.byType(SettingsScreen)))
              .colorScheme
              .error);
      expect(find.byIcon(Icons.refresh), findsOneWidget,
          reason: 'and there is a way to put it right');
    });

    testWidgets('a canary that has not fired for days is flagged',
        (tester) async {
      // Everything else asks the plugin what it believes is scheduled. This
      // one observes what Android actually did.
      await _pumpApp(
        tester,
        seeded: [_seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av)],
        canaryLastFired: DateTime.now().subtract(const Duration(days: 6)),
      );

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.byType(SettingsScreen), 'SettingsScreen');
      // The settings body is a lazy ListView, so a row below the fold is not
      // built at all - it has to be scrolled to, not merely searched for.
      await tester.scrollUntilVisible(
          find.text('מנגנון האזעקות'), 120,
          // Scoped to SettingsScreen: the home screen stays mounted beneath
          // the pushed route, and since the filter bar scrolls horizontally
          // *its* Scrollable is now the first one in the tree. A bare .first
          // dragged the wrong thing sideways and found nothing.
          scrollable: find.descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          ).first);

      expect(find.textContaining('לא פעל 6 ימים'), findsOneWidget);
    });

    testWidgets('a canary that fired today is not flagged', (tester) async {
      await _pumpApp(
        tester,
        seeded: [_seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av)],
        canaryLastFired: DateTime.now(),
      );

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.byType(SettingsScreen), 'SettingsScreen');
      // The settings body is a lazy ListView, so a row below the fold is not
      // built at all - it has to be scrolled to, not merely searched for.
      await tester.scrollUntilVisible(
          find.text('מנגנון האזעקות'), 120,
          // Scoped to SettingsScreen: the home screen stays mounted beneath
          // the pushed route, and since the filter bar scrolls horizontally
          // *its* Scrollable is now the first one in the tree. A bare .first
          // dragged the wrong thing sideways and found nothing.
          scrollable: find.descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          ).first);

      expect(find.textContaining('פעל היום'), findsOneWidget);
    });

    testWidgets('a queue that matches shows no refresh button', (tester) async {
      // A button that is always there invites taps that do nothing: the sync
      // runs on every launch anyway.
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);
      notif.report = PendingReport(
        rows: [
          PendingRow(
              name: 'סבא יעקב',
              scheduled: 3,
              expected: 3,
              stale: 0,
              nextReminder: DateTime(2027, 8, 24, 9)),
        ],
        total: 3,
        orphans: 0,
      );

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.text('מועדי התזכורות המתוזמנות'), 'the scheduled section');

      expect(find.byIcon(Icons.refresh), findsNothing);
    });

    testWidgets('leftovers with no event are called out', (tester) async {
      final (_, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);
      notif.report = const PendingReport(
        rows: [
          PendingRow(
              name: 'סבא יעקב', scheduled: 21, expected: 21, stale: 0),
        ],
        total: 63,
        orphans: 42,
      );

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.text('מועדי התזכורות המתוזמנות'), 'the scheduled section');

      expect(find.textContaining('ללא אירוע: 42'), findsOneWidget);
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
      // Rescheduling costs tens of platform calls per event, and the
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
      // throws, so an existing event must never fall outside this list.
      for (final d in const [1, 2, 3, 5, 7, 10, 14, 21, 30]) {
        expect(daysBeforeChoices, contains(d), reason: '$d days');
      }
    });
  });

  group('the weekly job does the same work as opening the app', () {
    test('missed reminders are delivered, and only then rescheduled',
        () async {
      // The background job used to reschedule and nothing else, so a reminder
      // whose alarm had been killed sat waiting for someone to open the app.
      final repo = _InMemoryRepo()
        ..items.add(
            _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av));
      final notif = _FakeNotifications()
        ..missedToDeliver = DateTime(2026, 8, 4, 9)
        ..nearestScheduled = DateTime(2027, 8, 24, 9);

      await syncReminders(repo, notif);

      final missed = notif.log.indexOf('missed:סבא יעקב');
      final scheduled = notif.log.indexOf('schedule:סבא יעקב');
      expect(missed, isNonNegative, reason: 'the missed reminder is shown');
      expect(scheduled, isNonNegative, reason: 'and the window is refilled');
      expect(missed, lessThan(scheduled),
          reason: 'rescheduling writes lastNotifiedAt forward, so running it '
              'first would bury the missed reminder for good');
    });

    test('what was handled is written down', () async {
      // Without it the same reminder is delivered again on the next launch.
      final repo = _InMemoryRepo()
        ..items.add(
            _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av));
      final notif = _FakeNotifications()
        ..nearestScheduled = DateTime(2027, 8, 24, 9);

      await syncReminders(repo, notif);

      expect(repo.items.single.lastNotifiedAt, DateTime(2027, 8, 24, 9));
    });

    test('an empty list is still work, because of what may be left over',
        () async {
      // This used to assert the opposite - that an empty list is skipped -
      // and that assertion WAS the bug. Deleting the last event leaves
      // alarms that belong to no event (a background cancel that never
      // finished, or the pre-block id scheme), and the sweep that removes
      // them lives inside rescheduleAll. Skipping meant nothing would ever
      // sweep them, and they would go on firing the text baked into them.
      final notif = _FakeNotifications();
      await syncReminders(_InMemoryRepo(), notif);
      expect(notif.log, contains('rescheduleAll:0'));
    });
  });

  group('the app and the background job cannot run at once', () {
    _InMemoryRepo seeded() => _InMemoryRepo()
      ..items
          .add(_seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av));

    test('a sync backs off while another holds the lock', () async {
      // The guard on the screen is a field in memory, and the background job
      // has its own copy of every static - so without a lock in the database
      // both can run, both read the same lastNotifiedAt, and both deliver.
      final repo = seeded()..syncLockHeld = true;
      final notif = _FakeNotifications()
        ..missedToDeliver = DateTime(2026, 8, 4, 9);

      await syncReminders(repo, notif, owner: 'background');

      expect(notif.log, isEmpty, reason: 'no work while someone else holds it');
    });

    test('and runs once the lock is free', () async {
      final repo = seeded();
      final notif = _FakeNotifications()
        ..nearestScheduled = DateTime(2027, 8, 24, 9);

      await syncReminders(repo, notif, owner: 'background');

      expect(notif.log, isNotEmpty);
      expect(repo.lockOwners, ['background']);
      expect(repo.syncLockHeld, isFalse, reason: 'and hands it back');
    });

    test('a caller that must not skip waits for the lock', () async {
      // Import is the one caller that cannot back off: it has just replaced
      // every event, and skipping would leave the user with nothing
      // scheduled right after being told the import succeeded.
      final repo = seeded()..syncLockHeld = true;
      final notif = _FakeNotifications()
        ..nearestScheduled = DateTime(2027, 8, 24, 9);

      unawaited(Future<void>.delayed(const Duration(milliseconds: 300), () {
        repo.syncLockHeld = false;
      }));

      await syncReminders(repo, notif,
          owner: 'import', waitForLock: const Duration(seconds: 5));

      expect(notif.log, isNotEmpty, reason: 'it waited rather than skipping');
    });

    test('but it does not wait forever', () async {
      final repo = seeded()..syncLockHeld = true;
      final notif = _FakeNotifications();

      await syncReminders(repo, notif,
          owner: 'import', waitForLock: const Duration(milliseconds: 300));

      expect(notif.log, isEmpty);
      expect(repo.syncLockHeld, isTrue, reason: 'the holder keeps it');
    });

    test('the lock is handed back even when the work throws', () async {
      // A lock that is never released would disable syncing until it goes
      // stale - ten minutes of no reminders being scheduled at all.
      final repo = seeded();
      final notif = _FakeNotifications()..failScheduling = true;

      await expectLater(syncReminders(repo, notif), throwsException);
      expect(repo.syncLockHeld, isFalse);
    });
  });

  group('every write to the notification store is locked', () {
    // The plugin keeps all scheduled notifications in one JSON blob and
    // rewrites the whole thing on each call, so two concurrent writers lose
    // one of the two - even with completely disjoint ids. The earlier fix
    // covered the two sync paths and left add, edit and delete unguarded.
    ProviderContainer containerFor(
        _InMemoryRepo repo, _FakeNotifications notif) {
      final c = ProviderContainer(overrides: [
        eventRepositoryProvider.overrideWithValue(repo),
        notificationServiceProvider.overrideWithValue(notif),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('adding one takes the lock and gives it back', () async {
      final repo = _InMemoryRepo();
      final notif = _FakeNotifications()
        ..nearestScheduled = DateTime(2027, 8, 24, 9);
      final notifier = containerFor(repo, notif)
          .read(eventListProvider.notifier);
      await notifier.load();

      await notifier.addEvent(
          _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av));
      // The scheduling is fire-and-forget; let it run.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(repo.lockOwners, contains('edit'));
      expect(repo.syncLockHeld, isFalse);
      expect(notif.log, contains('schedule:סבא יעקב'));
    });

    test('deleting one takes it too', () async {
      final repo = _InMemoryRepo();
      final notif = _FakeNotifications();
      final notifier = containerFor(repo, notif)
          .read(eventListProvider.notifier);
      await notifier.load();
      await notifier.addEvent(
          _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      repo.lockOwners.clear();

      await notifier.deleteEvent(repo.items.single);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(repo.lockOwners, contains('delete'));
      expect(repo.syncLockHeld, isFalse);
    });
  });

  group('import schedules without a gap', () {
    test('nothing is cancelled up front', () async {
      // replaceAll deletes and re-inserts, so the ids change and the old
      // notifications become orphans - rescheduleAll sweeps them anyway. A
      // cancelAll first only opened a window where everything was cancelled
      // and nothing was scheduled yet.
      final repo = _InMemoryRepo();
      final notif = _FakeNotifications()
        ..nearestScheduled = DateTime(2027, 8, 24, 9);
      final container = ProviderContainer(overrides: [
        eventRepositoryProvider.overrideWithValue(repo),
        notificationServiceProvider.overrideWithValue(notif),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(eventListProvider.notifier);
      await notifier.load();
      await notifier.importEvents([
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      expect(notif.log, isNot(contains('cancelAll')));
      expect(notif.log, contains('schedule:סבא יעקב'),
          reason: 'and the imported event is scheduled straight away');
    });
  });

  group('the background job leaves a trace', () {
    _InMemoryRepo seeded() => _InMemoryRepo()
      ..items
          .add(_seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av));

    test('a good run is written down', () async {
      final repo = seeded();
      final notif = _FakeNotifications()
        ..nearestScheduled = DateTime(2027, 8, 24, 9);

      expect(await BackgroundRefresh.run(repo: repo, notifications: notif),
          isTrue);
      expect(repo.backgroundRunAt, isNotNull);
      expect(repo.backgroundError, isNull);
    });

    test('so is a failure, and why', () async {
      // It runs in another isolate, so a field in memory never reaches the
      // screen: a job failing every week would be completely invisible.
      final repo = seeded();
      final notif = _FakeNotifications()..failScheduling = true;

      expect(await BackgroundRefresh.run(repo: repo, notifications: notif),
          isFalse);
      expect(repo.backgroundError, contains('scheduling refused'));
      expect(repo.syncLockHeld, isFalse);
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
        eventRepositoryProvider.overrideWithValue(repo),
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
      final notifier = container.read(eventListProvider.notifier);
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
      final notifier = container.read(eventListProvider.notifier);
      await notifier.load();

      await notifier.syncNotifications();
      final before = notif.log.length;
      await notifier.syncNotifications();

      expect(notif.log.length, greaterThan(before),
          reason: 'the guard must not latch and block every later sync');
    });
  });

  group('"do not remind again" on a cold launch', () {
    test('the event is found even before the list has loaded', () async {
      // The screen used to read the provider's cached list, which on a cold
      // launch from the notification button is still empty - so it reported
      // "האירוע לא נמצא" about an event that plainly exists.
      final repo = _InMemoryRepo()
        ..items.add(
            _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av));

      final container = ProviderContainer(overrides: [
        eventRepositoryProvider.overrideWithValue(repo),
        notificationServiceProvider.overrideWithValue(_FakeNotifications()),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(eventListProvider.notifier);
      // Deliberately not awaiting the load first: that is the state the bug
      // lived in.
      final name = await notifier.setEnabledById(1, false);

      expect(name, 'סבא יעקב');
      expect(repo.items.single.enabled, isFalse);
    });

    test('an id that belongs to nothing still reports honestly', () async {
      final container = ProviderContainer(overrides: [
        eventRepositoryProvider.overrideWithValue(_InMemoryRepo()),
        notificationServiceProvider.overrideWithValue(_FakeNotifications()),
      ]);
      addTearDown(container.dispose);

      expect(
        await container.read(eventListProvider.notifier)
            .setEnabledById(99, false),
        isNull,
      );
    });
  });

  group('the sync survives the awkward states', () {
    test('a lock that throws counts as taken, and the wait goes on', () async {
      // Two isolates hitting the same row get SQLITE_BUSY, which is an
      // exception rather than a false. Uncaught, it aborted the whole wait
      // loop - in the one caller that must not skip, the import.
      final repo = _ThrowsThenClaims();

      final got = await withSyncLock(repo, 'import', () async {},
          waitFor: const Duration(seconds: 5));

      expect(got, isTrue);
      expect(repo.attempts, greaterThan(1),
          reason: 'the first attempt threw; the loop had to try again');
    });
  });

  group('choosing what to import', () {
    final cal = EventCalendarService(now: () => _fixedNow);
    final file = [
      _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      _seed(id: 2, name: 'סבתא רחל', day: 3, month: HebrewMonth.tishrei),
      _seed(id: 3, name: 'דוד משה', day: 11, month: HebrewMonth.adar),
    ];

    // Held outside the helper: the dialog is still open when open() returns,
    // so a value returned from there is always null and a test reading it
    // would assert nothing.
    ImportChoice? result;

    setUp(() => result = null);

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('he'),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<ImportChoice>(
                context: context,
                builder: (_) =>
                    ImportSelectionDialog(events: file, calendar: cal),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('everything starts selected', (tester) async {
      // Importing the whole file is the normal case; a list that starts empty
      // would make the expected behaviour the one that costs work.
      await open(tester);

      final boxes = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .toList();
      // One per event plus the "all" row.
      expect(boxes, hasLength(file.length + 1));
      expect(boxes.every((b) => b.value == true), isTrue);
    });

    testWidgets('only what was ticked comes back', (tester) async {
      await open(tester);

      await tester.tap(find.text('סבתא רחל'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('הוספה'));
      await tester.pumpAndSettle();

      // What is dropped here is never compared against anything later, which
      // is the whole point of asking before the analysis.
      expect(result, isNotNull);
      expect(result!.mode, ImportMode.merge);
      expect(result!.selected.map((m) => m.name),
          ['סבא יעקב', 'דוד משה']);
    });

    testWidgets('replace carries the same selection', (tester) async {
      await open(tester);
      await tester.tap(find.text('דוד משה'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('החלפה (מוחק הכול)'));
      await tester.pumpAndSettle();

      expect(result!.mode, ImportMode.replace);
      expect(result!.selected, hasLength(2));
    });

    testWidgets('cancelling returns nothing at all', (tester) async {
      await open(tester);
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('unticking everything disables both actions', (tester) async {
      await open(tester);

      await tester.tap(find.text('הכול'));
      await tester.pumpAndSettle();

      final add = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'הוספה'));
      final replace = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'החלפה (מוחק הכול)'));
      expect(add.onPressed, isNull, reason: 'nothing to import');
      expect(replace.onPressed, isNull,
          reason: 'and replacing with nothing would just wipe the list');
    });

    testWidgets('the all row toggles back on', (tester) async {
      await open(tester);
      await tester.tap(find.text('הכול'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('הכול'));
      await tester.pumpAndSettle();

      final boxes =
          tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile));
      expect(boxes.every((b) => b.value == true), isTrue);
    });
  });

  group('sharing and exporting produce the same file', () {
    testWidgets('both rows are offered', (tester) async {
      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.text('ייצוא הנתונים'), 'the export row');

      // Two different jobs: export saves a copy the user keeps, share hands
      // the file to another app.
      expect(find.text('שיתוף הנתונים'), findsOneWidget);
      expect(find.textContaining('וואטסאפ'), findsOneWidget);
    });

    test('the backup content is built in one place', () {
      // Two separate builders would drift apart silently the moment one of
      // them changed, and the difference would only show up in a restore.
      final source = File('lib/screens/settings_screen.dart').readAsStringSync();
      expect('_buildBackup('.allMatches(source).length, 3,
          reason: 'one declaration, one call from export, one from share');
    });
  });

  group('feedback details', () {
    testWidgets('the settings screen carries them, and dials', (tester) async {
      await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av),
      ]);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await _pumpUntilFound(
          tester, find.text('הערות והארות'), 'the feedback row');

      expect(find.textContaining('אלעד שמחי'), findsOneWidget);
      expect(find.textContaining('054-490-8008'), findsOneWidget);

      await tester.tap(find.text('הערות והארות'));
      await tester.pump();
      expect(_lastLauncher!.dialled, ['0544908008'],
          reason: 'the dialler gets the digits, not the display form');
    });

    test('tel: is declared, or canLaunchUrl refuses it', () {
      // The same trap as geo: on Android 11+, and it fails silently - the row
      // would simply do nothing.
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:scheme="tel"'));
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

    test('one activity instance, however the app is opened', () {
      // The plugin replaces the action on its launch intent, so it no longer
      // matches the task's root intent and singleTop lets another instance
      // stack up on every notification tap.
      expect(manifest, contains('android:launchMode="singleTask"'));
      // And an empty affinity defeats that on its own: the launch intent
      // carries FLAG_ACTIVITY_NEW_TASK, Android finds an existing task by
      // affinity, and an empty one matches nothing - so a fresh task every
      // time, singleTask or not. Flutter's template ships it; this app cannot
      // keep it.
      expect(manifest, isNot(contains('android:taskAffinity=""')));
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

  group('a 32-bit phone can still install this', () {
    final gradle =
        File('android/app/build.gradle.kts').readAsStringSync();

    test('both ARM architectures ship by default', () {
      // One file that installs on a 32-bit phone and on a 64-bit one. A
      // 64-bit-only device (Pixel 7 and later) cannot run the 32-bit slice,
      // and a 32-bit Android build has no arm64 in its list, so dropping
      // either one leaves a phone that refuses the APK as incompatible.
      expect(gradle, contains('listOf("armeabi-v7a", "arm64-v8a")'));
    });

    test('one list decides which ABIs ship, in both places', () {
      // `ndk.abiFilters` governs code built here and NOT the prebuilt `.so`
      // a plugin ships inside its AAR. Narrowing through it alone leaves
      // `lib/<abi>/` holding a plugin library with no `libflutter.so` —
      // Android then advertises that ABI, a device picks it, and the app
      // crashes on launch. That is worse than "incompatible", because it
      // surfaces after the install rather than before it.
      //
      // So the exclude list must be derived from the same source as the
      // filter, and never typed out beside it.
      expect(gradle, contains('abiFilters += keptAbis'));
      expect(gradle, contains('ALL_ABIS.filterNot { keptAbis.contains(it) }'),
          reason: 'the jniLibs excludes must come from the same list');

      // Verify the artifact too, which this cannot — every surviving lib/
      // directory has to hold libflutter.so:
      //   unzip -l build/app/outputs/flutter-apk/app-release.apk | grep lib/
    });

    test('minSdk follows Flutter rather than being pinned higher', () {
      // 24 today, and the floor is not ours to lower: flutter_local
      // notifications 22 declares minSdkVersion 24 in its own manifest, and
      // it is the plugin the whole app exists for. Overriding it with
      // tools:overrideLibrary would trade an install failure for a runtime
      // one, on the delivery path.
      expect(gradle, contains('minSdk = flutter.minSdkVersion'),
          reason: 'a hardcoded higher minSdk would lock out old phones');
    });
  });

  group('the reminder text counts down to the event', () {
    test('never says "this week"; always days, tomorrow, or today', () {
      final cal = EventCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);

      for (final when in cal.futureReminderDates(m, from: _fixedNow, years: 5)) {
        final eventDate = cal.eventDateForReminder(m, when)!;
        final text =
            cal.describeEventForReminder(m, when, eventDate);

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
      final cal = EventCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'x', day: 27, month: HebrewMonth.av);
      final eventDate = cal.nextOccurrenceDate(m, from: _fixedNow);

      final dayBefore = DateTime(
          eventDate.year, eventDate.month, eventDate.day - 1, 9);
      expect(cal.describeEventForReminder(m, dayBefore, eventDate),
          contains('מחר'));

      expect(
          cal.describeEventForReminder(m, eventDate, eventDate),
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
    // 1648 physical / dpr 2. The Scaffold has no bottom bar, so its body runs
    // to the bottom of the window and that is what the action row has to
    // clear.
    const screenHeight = 824.0;

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
          tester, find.byType(EventDatePicker), 'the add screen');

      // Asserted on where the button lands rather than on a padding value:
      // the inset used to be the list's bottom padding and now belongs to
      // the pinned row, and neither of those is the thing that matters.
      final save = find.widgetWithText(FilledButton, 'שמירה');
      expect(screenHeight - tester.getBottomLeft(save).dy,
          greaterThanOrEqualTo(48.0),
          reason: 'the save button sits under the navigation bar');
    });

    testWidgets('no wasted gap when there is no inset', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);
      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(EventDatePicker), 'the add screen');

      final save = find.widgetWithText(FilledButton, 'שמירה');
      expect(screenHeight - tester.getBottomLeft(save).dy, lessThan(48.0),
          reason: 'a gap opened even without a navigation bar');
    });
  });

  group('the form keeps save and cancel in reach', () {
    // The form is long - name, kind, calendar, the date wheels, the year,
    // reminder timing, the hour and notes - and the row used to be its last
    // item, so saving an edit meant scrolling to the end of all of it.
    testWidgets('they are on screen before anything is scrolled',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);
      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(EventDatePicker), 'the add screen');

      // The rect, not merely the finder: a widget parked off screen is still
      // found, and "found" was never the question.
      for (final button in [
        find.widgetWithText(FilledButton, 'שמירה'),
        find.widgetWithText(OutlinedButton, 'ביטול'),
      ]) {
        expect(button, findsOneWidget);
        final box = tester.getRect(button);
        expect(box.bottom, lessThanOrEqualTo(824.0), reason: 'below the fold');
        expect(box.top, greaterThanOrEqualTo(0.0), reason: 'above the screen');
      }
    });

    testWidgets('and they do not move when the form scrolls', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);
      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(EventDatePicker), 'the add screen');
      await _settleRoute(tester);

      final save = find.widgetWithText(FilledButton, 'שמירה');
      final before = tester.getRect(save);

      final scrollable = find
          .descendant(
            of: find.descendant(
              of: find.byType(EventForm),
              matching: find.byType(ListView),
            ),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 200));

      expect(position.pixels, greaterThan(0.0),
          reason: 'the form never scrolled, so this proves nothing');
      expect(tester.getRect(save), before,
          reason: 'the action row scrolled away with the content');
    });

    testWidgets('and the keyboard pushes them up rather than over them',
        (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);
      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(EventDatePicker), 'the add screen');
      await _settleRoute(tester);

      // A row pinned to the bottom of a Column is the one arrangement a
      // keyboard can break outright: too little room left and the Column
      // overflows, which on a device is the striped banner.
      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull, reason: 'the form overflowed');

      final save = find.widgetWithText(FilledButton, 'שמירה');
      // 824 logical minus 300 of keyboard: the row has to be above it.
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(524.0),
          reason: 'the save button is behind the keyboard');
    });
  });

  group('the project logo on the splash screen', () {
    testWidgets('appears alongside the confetti, not instead of it',
        (tester) async {
      _phoneViewport(tester);
      final repo = _InMemoryRepo();
      final notif = _FakeNotifications();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            eventRepositoryProvider.overrideWithValue(repo),
            notificationServiceProvider.overrideWithValue(notif),
            calendarServiceProvider.overrideWithValue(
              EventCalendarService(now: () => _fixedNow),
            ),
          ],
          child: const EventsApp(),
        ),
      );
      await tester.pump();

      expect(find.byType(SplashScreen), findsOneWidget);
      expect(
          find.descendant(
            of: find.byType(SplashScreen),
            matching: find.byIcon(Icons.celebration),
          ),
          findsOneWidget,
          reason: 'the mark must stay');
      expect(find.text('תזכורת אירועים'), findsOneWidget);

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
    test('the notification icon is its own drawable', () {
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

  group('the card states the weekday and the countdown to the event', () {
    testWidgets('both are visible without waiting for a notification',
        (tester) async {
      _phoneViewport(tester);
      final cal = EventCalendarService(now: () => _fixedNow);
      final m = _seed(id: 1, name: 'סבא יעקב', day: 27, month: HebrewMonth.av);

      await _pumpApp(tester, seeded: [m]);

      final date = cal.nextOccurrenceDate(m, from: _fixedNow);
      final weekday = hebrewWeekdayNames[date.weekday]!;
      final days = cal.daysUntilEvent(m, from: _fixedNow);

      // The weekday of the event itself.
      expect(find.textContaining('יום $weekday'), findsOneWidget);
      // And how long until the event — distinct from the reminder count.
      expect(find.textContaining('האירוע בעוד $days ימים'), findsOneWidget);
      // The reminder countdown is still its own separate row.
      expect(find.textContaining('התזכורת'), findsWidgets);
    });

    testWidgets('reads naturally when the event is imminent',
        (tester) async {
      _phoneViewport(tester);
      final cal = EventCalendarService(now: () => _fixedNow);

      // Find an event falling tomorrow relative to the pinned clock.
      Event? tomorrow;
      for (final month in HebrewMonth.values) {
        for (var day = 1; day <= 29 && tomorrow == null; day++) {
          final c = _seed(id: 1, name: 'x', day: day, month: month);
          if (cal.daysUntilEvent(c, from: _fixedNow) == 1) tomorrow = c;
        }
      }
      expect(tomorrow, isNotNull, reason: 'no fixture falls tomorrow');

      await _pumpApp(tester, seeded: [tomorrow!]);
      expect(find.text('זמן שנותר: '), findsOneWidget);
      expect(find.text('האירוע מחר'), findsOneWidget);
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
            eventRepositoryProvider.overrideWithValue(repo),
            notificationServiceProvider.overrideWithValue(notif),
            calendarServiceProvider.overrideWithValue(
              EventCalendarService(now: () => _fixedNow),
            ),
          ],
          child: const EventsApp(),
        ),
      );

      // The splash must hand over as soon as SQLite answers. If scheduling
      // were still awaited here, this would sit on the splash instead.
      await _pumpUntilFound(
          tester, find.byType(EventCard), 'the event list');
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
      expect(find.text('תזכורת אירועים'), findsOneWidget);
      // RTL: the mark leads (right), the signature trails (left).
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.celebration),
        ),
        findsOneWidget,
      );
      expect(tester.getCenter(inBar).dx,
          lessThan(tester.getCenter(find.text('תזכורת אירועים')).dx),
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
            eventRepositoryProvider.overrideWithValue(_NeverLoadsRepo()),
            notificationServiceProvider.overrideWithValue(_FakeNotifications()),
            calendarServiceProvider.overrideWithValue(
              EventCalendarService(now: () => _fixedNow),
            ),
          ],
          child: const EventsApp(),
        ),
      );
      // הטעינה לעולם אינה מסתיימת כאן, ולכן המסך אינו מחליף את עצמו תוך כדי.
      await tester.pump();
      await _warmLogo(tester);
      await tester.pump();

      // שהצילום באמת של מסך הפתיחה, ולא של מה שבא אחריו: כשזה השתנה,
      // ההבדל הופיע כפער פיקסלים ולא כשגיאה שאומרת מה קרה.
      expect(find.byType(SplashScreen), findsOneWidget);

      await expectLater(
        find.byType(EventsApp),
        matchesGoldenFile('goldens/07_splash.png'),
      );
      // אין כאן המתנה למסך הראשי: המאגר הזה לעולם אינו נטען, וזו בדיוק
      // הנקודה. שהאפליקציה מגיעה למסך הראשי נבדק במקום אחר.
    });

    testWidgets('home with data (light)', (tester) async {
      _phoneViewport(tester);
      // A mix on purpose: the screenshot is the one place the per-kind
      // colour, the Gregorian tag and the anniversary count all have to be
      // visible at once.
      await _pumpApp(tester, seeded: [
        _seed(
          id: 1,
          name: 'דנה',
          day: 14,
          month: HebrewMonth.cheshvan,
          kind: EventKind.birthday,
          startYear: 5756,
        ),
        _seed(
          id: 2,
          name: 'אנחנו',
          day: 3,
          month: HebrewMonth.nisan,
          kind: EventKind.anniversary,
          startYear: 5761,
        ),
        _seed(
          id: 3,
          name: 'היום שנפגשנו',
          calendar: CalendarSystem.gregorian,
          day: 20,
          gregorianMonth: 9,
          kind: EventKind.firstMet,
        ),
        _seed(
          id: 4,
          name: 'אמא',
          day: 10,
          month: HebrewMonth.adar,
          kind: EventKind.birthday,
          enabled: false,
        ),
      ]);
      await expectLater(
        find.byType(EventsApp),
        matchesGoldenFile('goldens/01_home_light.png'),
      );
    });

    testWidgets('home with data (dark)', (tester) async {
      _phoneViewport(tester);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      await _pumpApp(tester, seeded: [
        _seed(
          id: 1,
          name: 'דנה',
          day: 14,
          month: HebrewMonth.cheshvan,
          kind: EventKind.birthday,
          startYear: 5756,
        ),
        _seed(
          id: 2,
          name: 'אנחנו',
          day: 3,
          month: HebrewMonth.nisan,
          kind: EventKind.anniversary,
          startYear: 5761,
        ),
      ]);
      await expectLater(
        find.byType(EventsApp),
        matchesGoldenFile('goldens/02_home_dark.png'),
      );
    });

    testWidgets('empty state', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);
      expect(find.text('אין עדיין אירועים ברשימה'), findsOneWidget);
      await expectLater(
        find.byType(EventsApp),
        matchesGoldenFile('goldens/03_empty.png'),
      );
    });

    testWidgets('add screen with the Hebrew wheel picker', (tester) async {
      _phoneViewport(tester);
      await _pumpApp(tester);

      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(EventDatePicker), 'the add screen');

      expect(find.byType(CupertinoPicker), findsNWidgets(2));
      await expectLater(
        find.byType(EventsApp),
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
        find.byType(EventsApp),
        matchesGoldenFile('goldens/05_settings.png'),
      );
    });
  });

  group('drive the app', () {
    testWidgets('add an event end to end, and it gets scheduled',
        (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester);

      expect(find.text('אין עדיין אירועים ברשימה'), findsOneWidget);
      notif.log.clear();

      await tester.tap(find.text('הוספה'));
      await _pumpUntilFound(
          tester, find.byType(EventDatePicker), 'the add screen');

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
      expect(saved.single.day, 1);
      expect(saved.single.hebrewMonth, HebrewMonth.tishrei);

      // And the notification chain fired for it.
      expect(notif.log.where((e) => e.startsWith('schedule:')).toList(),
          contains('schedule:סבתא מרים'));

      // Let the pop transition finish, otherwise the add route is still
      // mounted and its picker preview double-counts the date text.
      for (var i = 0;
          i < 40 && find.byType(EventDatePicker).evaluate().isNotEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Back on the list, showing the formatted Hebrew date.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(EventDatePicker), findsNothing);
      expect(find.text("א' בתשרי"), findsOneWidget);

      // Same trap as the splash golden: the app-bar logo is an asset, and
      // its decode does not finish under the fake clock unless an earlier
      // test happened to warm the image cache - so the capture depended on
      // the run order rather than on the screen.
      await _warmLogo(tester);
      await tester.pump();

      await expectLater(
        find.byType(EventsApp),
        matchesGoldenFile('goldens/06_after_add.png'),
      );
    });

    testWidgets('editing an event saves and reschedules it', (tester) async {
      _phoneViewport(tester);
      final (repo, notif) = await _pumpApp(tester, seeded: [
        _seed(id: 1, name: 'סבא יעקב', day: 14, month: HebrewMonth.cheshvan),
      ]);
      notif.log.clear();

      await tester.tap(find.text('סבא יעקב'));
      await _pumpUntilFound(
          tester, find.byType(EditEventScreen), 'EditEventScreen');

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
      expect(saved.single.day, 14);
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
          tester, find.byType(EditEventScreen), 'EditEventScreen');

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
          reason: 'an event saved as disabled must not be scheduled');
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
          tester, find.byType(EditEventScreen), 'EditEventScreen');

      await tester.tap(find.byIcon(Icons.delete_outline));
      await _pumpUntilFound(
          tester, find.text('מחיקת אירוע'), 'the delete confirmation');
      expect(find.text('למחוק את האירוע של סבא יעקב?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'מחיקה'));
      await _pumpUntilFound(tester, find.byType(HomeScreen), 'HomeScreen');
      for (var i = 0;
          i < 40 && find.byType(EditEventScreen).evaluate().isNotEmpty;
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
          tester, find.byType(EditEventScreen), 'EditEventScreen');

      await tester.tap(find.byIcon(Icons.delete_outline));
      await _pumpUntilFound(
          tester, find.text('מחיקת אירוע'), 'the delete confirmation');

      await tester.tap(find.widgetWithText(TextButton, 'ביטול'));
      await _pumpUntilGone(
          tester, find.text('מחיקת אירוע'), 'the delete confirmation');

      expect(await repo.getAll(), hasLength(1));
      expect(notif.log, isEmpty, reason: 'cancelling must touch nothing');
      // Dismissed the dialog, not the screen.
      expect(find.byType(EditEventScreen), findsOneWidget);
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
          reason: 'a disabled event must not be rescheduled');
    });
  });
}
