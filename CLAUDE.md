# azkarot_app — build & test notes

## Verified end-to-end on hardware (2026-08-04)

A memorial on כ"ז באב (Gregorian 10/08/2026, a Monday) produced a reminder that
fired on **Tuesday 04/08/2026 at the configured hour**, on a physical Samsung
device, with the app closed. Confirmed by the user. This is the first and so far
only live confirmation that the notification path works at all, and it validates:
the Hebrew→Gregorian conversion via `kosher_dart`, the
Tuesday-of-the-week-before rule, `exactAllowWhileIdle` delivery under Doze, and
the `flutter_local_notifications` 17→22 API migration.

Still unconfirmed on hardware: the 20-year recurrence, the boot-receiver
restore, the missed-reminder catch-up, and the DST edge case (only reachable
around the March transition — covered by unit tests only).

Flutter app (Android-only platform folder) that reminds about Hebrew-calendar
yahrzeits on the **Tuesday of the week before** the memorial week.

## Building for Android

Works as of 2026-08-02. Required environment for every Gradle-touching command:

```powershell
$env:Path = "C:\Users\elads\flutter\bin;$env:Path"
$env:JAVA_HOME = 'C:\Users\elads\jdk17\jdk-17.0.20+8'
$env:ANDROID_HOME = 'C:\Users\elads\android-sdk'
$env:GRADLE_OPTS = '-Djavax.net.ssl.trustStoreType=Windows-ROOT'
$env:JAVA_OPTS  = '-Djavax.net.ssl.trustStoreType=Windows-ROOT'
flutter build apk --release
```

**The `Windows-ROOT` truststore is mandatory on this network.** TLS is
intercepted by a corporate proxy (`CN=AudioCodes LTD - PA`); its root CA is in
the Windows certificate store but not in the JDK's `cacerts`, so every
Java-based tool — `sdkmanager`, Gradle — fails to download while `curl` and
PowerShell succeed. The same setting is in `~/.gradle/gradle.properties` as
`systemProp.javax.net.ssl.trustStoreType`, deliberately not
`org.gradle.jvmargs` (this project sets that key, and the project value wins).

### Pinned version set — do not bump casually

| | version | why |
|---|---|---|
| Gradle | 8.13 | AGP 8.13.2 requires ≥8.13 |
| AGP | 8.13.2 | **not 9.x** — see below |
| Kotlin | 2.1.20 | |
| Java | 17 | AGP 8+ requires it |
| compileSdk | 36 (from Flutter) | forces AGP ≥8.9 |

**AGP 9 does not work with this plugin set.** `file_picker` 11 detects AGP≥9
and deliberately skips applying KGP, expecting AGP 9 built-in Kotlin to build
its `.kt` sources; with `android.builtInKotlin=false` nothing compiles them and
`GeneratedPluginRegistrant` fails on a missing `FilePickerPlugin`. Flipping to
`builtInKotlin=true` then breaks `:flutter_local_notifications` with an NPE
from `kotlin-android`. No value of that flag satisfies both. Staying on AGP
8.13.2 makes both plugins behave as designed. Note `flutter build` re-adds
`android.builtInKotlin=false` / `android.newDsl=false` to
`android/gradle.properties` automatically; harmless on AGP 8.

Flutter warns that Gradle <8.14 and Kotlin <2.2.20 support will be dropped
"soon" — worth revisiting, but only together with an AGP bump.

### Defects the build found that tests and the analyzer could not

Seven, none visible to `flutter analyze` or the 60-test suite:

1. `build.gradle.kts` passed a `java.io.File` to `DirectoryProperty.value()`,
   which only accepts `Directory`/`Provider`. Use `set()`.
2. Gradle 8.4 was below Flutter's 8.7 minimum.
3. AGP 8.3 / Kotlin 1.9.22 / Java 8 were all too old for `compileSdk 36`.
4. `kotlin-android` applied on top of the Flutter plugin, plus
   `android.enableJetifier` (removed in AGP 9).
5. `file_picker` 8.3.7 and `flutter_local_notifications` 17.2.4 both compile
   against SDK 34 and are rejected by `flutter_plugin_android_lifecycle`.
6. `builtInKotlin` conflict described above.
7. `kotlinOptions` inside `android {}` is invalid under Kotlin 2.x — the
   `kotlin { compilerOptions { } }` block is top-level.

### Plugin API migration (2026-08-02)

`flutter_local_notifications` 17.2.4 → 22.2.0 and `file_picker` 8.3.7 → 11.0.3
were forced by the SDK-34 problem, and both broke source compatibility:

- `FilePicker.platform.pickFiles()` → `FilePicker.pickFiles()` (static)
- `initialize(settings)` → `initialize(settings: settings)`
- `zonedSchedule` — all five positional params became named
- `cancel(id)` → `cancel(id: id)`
- `uiLocalNotificationDateInterpretation` was **removed** in v19+. It had been
  added here on 2026-07-31 to fix a compile error against 17.2.4.

The suite still passes, but that proves little about this migration: `ui_test`
stubs `NotificationService` out entirely, so the new `zonedSchedule` call has
never executed against Android.

## Toolchain

There is no Flutter/Android SDK on PATH on this machine. Flutter 3.44.8
(Dart 3.12.2) is installed at `C:\Users\elads\flutter` and is **not** on the
persistent PATH — prefix each invocation:

```powershell
$env:Path = "C:\Users\elads\flutter\bin;$env:Path"
flutter test
```

Not installed: Android SDK, `adb`, Android Studio, JDK 17 (only Java 8 is
present). So `flutter build apk` / `flutter run` on a device or emulator
**cannot work here** without installing those first. Analyzer, tests, and
widget/golden rendering all work with the Flutter SDK alone.

## Test layout and what is actually covered

| file | what it exercises |
|---|---|
| `hebrew_calendar_service_test.dart`, `memorial_model_test.dart` | pure date/model logic |
| `database_helper_test.dart` | the **real** SQLite schema + CRUD, and `MemorialRepository` on top of it, via `sqflite_common_ffi` |
| `ui_test.dart` | every screen rendered, plus add / edit / delete / toggle driven through the provider layer |

`flutter test --coverage` sits at ~79% of `lib/`. The two deliberate holes:

- `notification_service.dart` (~5%) — replaced by a recording stub in
  `ui_test.dart`, because `zonedSchedule` needs a real platform. **Nothing here
  proves a notification actually fires at the right time.**
- `settings_screen.dart` (~20%) — export/import go through `path_provider` and
  `file_picker` platform channels. The data shape they move is covered by the
  JSON round-trip test in `database_helper_test.dart`, but the file I/O is not.

`sqflite_common_ffi` needs no extra setup on this machine — sqlite resolves
without a DLL override. Note that `DatabaseHelper` caches its connection in a
static field, so the tests truncate the table in `setUp` rather than reopening.

## Running the UI without a device

`test/ui_test.dart` is the entry point: it renders every screen and drives the
add-memorial and toggle flows through the real provider layer.

The cards show "days until the reminder", so the goldens would fail a day after
being generated. `HebrewCalendarService` therefore takes an injectable clock
(`HebrewCalendarService({DateTime Function()? now})`, defaulting to
`DateTime.now`), and the test overrides `hebrewCalendarServiceProvider` with a
pinned one. Note that `MemorialForm` and `HebrewDatePicker` construct the
service directly rather than reading the provider, so a pinned clock does not
reach them — fine today, since neither renders anything clock-dependent.

`flutter test` renders real widgets on the Dart VM, so the actual screens can
be driven and screenshotted with no Android involved. Two things are required:

- Override `memorialRepositoryProvider` and `notificationServiceProvider` with
  subclasses — the concrete `MemorialRepository` / `NotificationService` are
  injectable, and `DatabaseHelper.instance` is lazy so constructing it never
  opens SQLite.
- Load a real font via `FontLoader`, otherwise all text renders as boxes.
  Hebrew glyphs: `C:\Windows\Fonts\arial.ttf` registered as family `Roboto`.
  Icons: `<flutter>\bin\cache\artifacts\material_fonts\materialicons-regular.otf`
  registered as `MaterialIcons`.

Splash spins a `CircularProgressIndicator` forever, so `pumpAndSettle` times
out — pump in fixed slices until the target screen appears instead.

## Gotchas hit and fixed (2026-07-31)

- `flutter_lints ^4.0.0` could not resolve: it pins `lints ^4.0.0`, while
  `kosher_dart` >=2.0.19 needs `lints ^6.1.0`, and older `kosher_dart` needs
  `intl ^0.19.0` which conflicts with the `intl 0.20.2` that
  `flutter_localizations` pins. Bumped to `flutter_lints ^6.0.0`.
- `zonedSchedule` in `flutter_local_notifications` 17.2.4 requires
  `uiLocalNotificationDateInterpretation`. It was missing, which was a hard
  compile error — the app did not build at all before this.

- `HebrewCalendarService.nextMemorialDate` accepted a `from` parameter but used
  it only for the "is this in the past" comparison — the starting Hebrew year
  came from `_currentHebrewYear()`, i.e. the real `DateTime.now()`. So `from`
  could not steer the search: `from: 2010-01-01` returned 2025-10-02. That made
  the Adar I / Adar II test fail, because it aims at leap year 5784 but the
  loop started at the real year 5786 (non-leap), where both collapse onto the
  single Adar. Fixed by deriving the start year from `from` via
  `_hebrewYearOf`. No production behaviour change — every caller passes
  `from == null`, and `test/ui_test.dart` pins that equivalence across all 14
  months.

## Date arithmetic: never use Duration for whole days

`DateTime.add`/`subtract` operate on **absolute** time, so any span crossing an
Israeli DST transition is 167h or 169h rather than 168h. Two separate bugs came
from this and both are fixed; keep the rule when touching date code.

- `tuesdayBeforeWeekOf` built the week offset with `Duration(days: 7)` and
  returned the result unnormalised. For a memorial on 2027-03-28 it returned
  **Monday** 2027-03-22 23:00, so the reminder fired a day early. Now the
  arithmetic is on date components: `DateTime(y, m, sunday.day - 5)`, which
  normalises overflow and is DST-immune.
- `daysUntilReminder` subtracted two local midnights and called `.inDays`,
  truncating to one day fewer across a transition. Now both sides are built
  with `DateTime.utc` before differencing.

The pre-existing "ההתראה תמיד ביום שלישי" test only scanned 60 days from
2027-01-01, so it never reached March and never saw this. `test/ui_test.dart`
now scans four full years plus the specific spring-forward weeks.

## Export must go through the system save dialog

`getApplicationDocumentsDirectory()` maps to `PathUtils.getDataDirectory` on
Android — the app's **private** folder (`/data/user/0/<pkg>/app_flutter`). The
system file picker cannot browse it, so an export written there was invisible:
not findable, not shareable, not importable, and deleted on uninstall. Export
now uses `FilePicker.saveFile(bytes: ...)`, which opens the SAF dialog and lets
the user choose a real destination. `path_provider` was dropped as a
dependency along with it.

Import uses `FileType.any`, not `FileType.custom` + `allowedExtensions`. On
Android the extension filter becomes a MIME filter, and many file providers do
not report `application/json`, which greys the backups out. The `.json` check
is done in Dart instead.

## Features added 2026-08-04

- **Burial location** as two fields (`cemetery`, `plot`), joined by
  `Memorial.burialSearchQuery` and opened via `NavigationLauncher` with a
  `geo:0,0?q=` URI so Android offers a chooser (Waze, Maps, …) rather than
  hard-coding one provider. Requires the `geo` and `https` `<intent>` entries in
  the manifest's `<queries>` — without them `canLaunchUrl` returns false on
  Android 11+ even when Waze is installed.
- **Photo** (`photo_path`), downscaled to `PhotoStore.maxDimension` (256px) and
  written into app support storage. Two reasons the copy is mandatory: the
  picker returns a **cache** path Android later deletes, and a full-size phone
  photo is megabytes for a 48px avatar. Downscaling with `dart:ui`
  (`ImageDescriptor` + `instantiateCodec`) avoids an image package.
  `_Portrait` checks `File.existsSync()` and falls back to the candle.
- **Photos are included in the JSON backup** as base64 under `photo_data`;
  `photo_path` is stripped on export because a path from another device is
  meaningless. This only stays practical because of the downscale — embedding
  originals would produce tens of MB per backup. Import restores each image to
  local storage and rewrites `photoPath`. A corrupt `photo_data` is skipped, not
  fatal to the whole import.
- **Snooze actions** on the notification (3 days / 7 days). The handler runs in
  a background isolate with no `ProviderScope` and no database, so the body text
  travels in the notification `payload`, and timezones are re-initialised there.
  `notificationTapBackground` must stay a top-level function annotated
  `@pragma('vm:entry-point')` or R8 removes it.
- **Configurable reminder timing** (`reminder_mode`, `reminder_value`), default
  unchanged: `weekdayOfPreviousWeek` + Tuesday. `fixedDaysBefore` gives a
  consistent gap instead of the 5–11 day spread.

- **Year of death** (`death_hebrew_year`, v4) — **nullable on purpose**: many
  yahrzeits are kept by the anniversary alone, so "unknown" has to stay a
  legitimate value rather than collapse into a wrong default. Its point is
  `HebrewCalendarService.yahrzeitNumber`, which reports whether the coming
  occurrence is the first, third, and so on. It returns null when the death
  year is at or after the occurrence, so a nonsensical count is never shown.

Schema is now **v4**; `_onUpgrade` is incremental and the v3 columns carry SQL
defaults so upgraded installs keep behaving identically.

### Test harness notes for the form

`MemorialForm` is a lazy `ListView`, and it is now tall enough that the save
button is not built until scrolled to — `ensureVisible` throws "No element".
`_revealInForm` drives `ScrollPosition.jumpTo` directly instead of simulating a
drag, because a drag starts at the Scrollable's centre, which lands on the date
picker's wheels and silently changes the date. The finder is scoped to
`MemorialForm`: the home screen stays mounted beneath the pushed route, so a
bare `find.byType(ListView)` can grab the wrong list.

Also inject the photo picker (`MemorialForm.photoPicker`) rather than calling
`PhotoStore` directly, so the form stays testable without plugins.

## Resources referenced only from Dart get shrunk away

Flutter's Gradle plugin sets `isMinifyEnabled` **and** `isShrinkResources` for
release builds. Any Android resource whose only reference is a string in Dart
— `AndroidInitializationSettings('@drawable/ic_notification')` — is invisible to
the shrinker and gets deleted from the release APK while debug builds look fine.
`android/app/src/main/res/raw/keep.xml` declares `tools:keep` for the
notification icon. Add to it when introducing another Dart-referenced resource.

Verify after any change with:

```powershell
aapt2 dump resources build\app\outputs\flutter-apk\app-release.apk | Select-String ic_notification
```

The notification icon itself must be **white on transparent** — Android renders
notification small icons as a silhouette from the alpha channel, so the
launcher icon (used previously) showed up as a white blob.

## Delivery is best-effort, never skipped

The product requirement is "on time, and never missed". Timing accuracy and
miss-resistance are handled by separate mechanisms — do not trade one for the
other:

1. **`exactAllowWhileIdle`** for the timing itself, with
   `SCHEDULE_EXACT_ALARM` + `USE_EXACT_ALARM` declared. Caveat for publishing:
   `USE_EXACT_ALARM` is a Play Store *restricted* permission granted only to
   alarm-clock and calendar apps. If the app is ever submitted, expect to drop
   it and rely on `SCHEDULE_EXACT_ALARM` (user-granted at runtime) alone —
   delivery still survives that, only punctuality degrades.
2. **Boot / package-replace**: the plugin's `rescheduleNotifications` re-registers
   everything on `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`, and an alarm whose
   time already passed fires immediately. So a phone that was off is covered.
3. **Catch-up on open**: if a reminder time passed without ever being scheduled
   — a memorial added *after* its Tuesday went by —
   `HebrewCalendarService.missedReminderDate` detects it and
   `deliverMissedReminder` shows it immediately.

### lastNotifiedAt must be written at SCHEDULE time, not only on delivery

`flutter_local_notifications` has no delivery callback (only a tap callback), so
the app cannot observe that a scheduled notification fired. The first version
wrote `lastNotifiedAt` only when the catch-up itself delivered, which produced a
**duplicate notification for every normal delivery**: the alarm fired at 09:00,
the user opened the app at 09:01, `missedReminderDate` saw "reminder passed,
memorial ahead, nothing recorded" and fired a second one. Reported from the
device on 2026-08-04, and the fix confirmed on the device the same day — the
duplicate no longer appears when reopening the app after a delivery.

So `scheduleForMemorial` returns the nearest reminder it scheduled,
`rescheduleAll` returns a `{memorialId: nearestReminder}` map, and
`MemorialNotifier` persists them. The field therefore means "the latest reminder
**accounted for**", not "delivered" — keep it that way.

Known trade-off: a force-stop between scheduling and firing loses that year's
reminder, because the schedule record makes it look handled. The boot receiver
covers the far more common phone-was-off case, so this is the right side to err
on — a guaranteed duplicate every year is worse than a rare miss.

### Notification id scheme changed — legacy ids must be swept

Before the multi-year work the id was the raw memorial id; it is now
`memorialId * 100 + occurrenceIndex`. An upgraded install therefore has orphaned
alarms the new code cannot match, which would fire *alongside* the new schedule.
`rescheduleAll` cancels any pending id below `notificationIdsPerMemorial` —
SQLite ids start at 1, so block 0 is never legitimately owned.

## Reminders are scheduled many years ahead, deliberately

`zonedSchedule` is one-shot, and Android offers no yearly repeat that tracks the
Hebrew calendar — `matchDateTimeComponents` only repeats weekly, monthly, or
annually on a **fixed Gregorian date**, while a Hebrew anniversary drifts. So
`NotificationService.scheduleForMemorial` enumerates
`HebrewCalendarService.futureReminderDates` (horizon:
`scheduleHorizonYears`, currently 20) and schedules every occurrence. Each app
launch and resume refills the window via `loadAndReschedule`.

Two consequences to preserve when touching this:

- Every memorial owns a contiguous block of `Memorial.notificationIdsPerMemorial`
  (100) notification ids — `id * 100 + occurrenceIndex`. Without the block, each
  year would overwrite the previous one.
- `cancelForMemorial` must cancel the whole block. Cancelling only the base id
  would leave 19 future-year notifications alive after a delete or a toggle-off.

Not covered: a user who never opens the app for 20 years. There is no way to fix
that with local alarms alone, and aggressive OEM battery management (Samsung in
particular) can drop alarms regardless.

### Scheduling is quadratic — never loop blindly over ids

`flutter_local_notifications` keeps **every** scheduled notification in a single
JSON blob in SharedPreferences, and `saveScheduledNotification` does a full
load → filter → save on *each* `zonedSchedule` and each `cancel`. Scheduling N
occurrences is therefore O(N²), and every call is a platform-channel round trip.

Two rules follow, both already encoded here:

- `cancelForMemorial` asks `pendingNotificationRequests()` what actually exists
  and cancels only those. An earlier version swept all 100 ids in the block,
  which cost 100 round trips per memorial.
- `rescheduleAll` compares the pending count against
  `futureReminderDates().length` and **skips memorials whose window is already
  full**. Hebrew dates are deterministic, so there is nothing to recompute.
  Without the skip, every foreground resume re-cancelled and re-scheduled
  everything — roughly 1,200 platform calls with ten memorials, enough to hang
  startup.

`Memorial.ownsNotificationId` owns the block-boundary check and is unit-tested;
an off-by-one there silently cancels a *different* memorial's notifications.

## The reminder can legitimately be in the past

`reminderDate` is 5–11 days before the memorial, so every year there is a
window where the reminder Tuesday has passed but the memorial has not.
`NotificationService` must therefore schedule from `nextFutureReminderDate`,
which rolls on to the next Hebrew year; the old code called `reminderDate`,
saw a past date, and returned without scheduling anything — commented as a
"rare edge case" when it actually happens annually for every memorial. A
memorial added inside that window got no notification at all, that year or the
next. `MemorialCard` also renders the negative day count as
"התזכורת לשנה זו כבר עברה" rather than "בעוד ‎-3 ימים".

## Network

`flutter pub get` / the first-run bootstrap can hang indefinitely on a stalled
TLS connection to `storage.googleapis.com` (established socket, no bytes, near
zero CPU). The pub cache is preserved, so killing the `dart` process and
retrying resumes and succeeds.

## One activity instance, or a notification opens the app again and again

Two attributes, and **either one alone leaves the bug in place**:

- `launchMode` is `singleTask`, not the Flutter template's `singleTop`. The
  plugin builds its launch intent from `getLaunchIntentForPackage` and then
  **replaces the action**, so the intent no longer matches the task's root
  intent; `singleTop` only prevents a second instance when the activity happens
  to be on top.
- **`android:taskAffinity=""` is removed.** The launch intent carries
  `FLAG_ACTIVITY_NEW_TASK`, and Android locates a task to reuse by affinity — an
  empty affinity matches nothing, so a fresh task is created every time whatever
  the launch mode says. Shipping `singleTask` while leaving the empty affinity
  in place changed nothing on the device, which is how this was found.

The cost is the mitigation Flutter's template was buying: with the affinity back
to the package name, a malicious app declaring the same affinity can insert
itself into the task (StrandHogg). Against a fault that happens on every single
tap, that is a deliberate trade, not an oversight.

Note for testing a fix: **task instances already in Recents do not disappear**
when the manifest changes. Swipe them all away once after installing, or the
old ones look like the bug persisting.

## Settings shows what is actually scheduled

`pendingReport` counts the queued notifications per memorial, split by series,
plus anything whose block belongs to no memorial at all. It is surfaced in the
settings screen on purpose: when a reminder arrives twice there is otherwise no
way to tell a queue holding two series from the system re-alerting one, and
**four separate fixes were shipped blind before this existed**. Treat it as the
first thing to read when a notification misbehaves.

### Android caps an app at 500 concurrent alarms

`AlarmManager.setExactAndAllowWhileIdle` throws once the app holds 500 alarms,
and the failure arrives as a `Parcel.readException` out of `IAlarmManager.set`.
Twenty years across two series is 42 alarms per memorial, so the ceiling is
breached at about a dozen memorials — and because `scheduleForMemorial` cancels
before it reschedules, the memorial that hits it is left with **nothing**
queued. The user sees a reminder that never fires and only appears on opening
the app, which is the catch-up.

`horizonYearsFor` shrinks the horizon as memorials are added so the total stays
under `maxScheduledAlarms` (400, deliberately short of the real limit), with a
floor of `minHorizonYears` so reminders never vanish outright for someone with
a very large list. Anything that schedules has to pass the memorial count in;
the provider reads it from the current list.

And when exact scheduling is refused anyway — a missing `SCHEDULE_EXACT_ALARM`
grant does the same thing — scheduling **retries once in
`inexactAllowWhileIdle`** rather than giving up. Punctuality and delivery are
separate requirements here, and delivery is the one that matters: a reminder a
few minutes late beats no reminder. The settings row still names what happened.

**`scheduleForMemorial` cancels before it schedules**, so a throw inside
`_scheduleAll` leaves the memorial with *nothing* queued — and the only symptom
is "the reminder never fires, it only appears when I open the app", because all
that is left is the catch-up. The `on Exception` there used to be silent, which
made a scheduling failure indistinguishable from a delivery failure without a
cable. It now records `lastScheduleError`, and the settings row shows it in red
along with the two permissions that gate delivery. Read that row first.

Record the **first line only** (`firstLineOf`). A `PlatformException`'s
`toString` drags its whole stack along, and the first attempt filled the screen
with frames while the reason itself scrolled out of view.

`rescheduleAll` also sweeps every pending id that belongs to no current
memorial. Two things strand a whole block: the pre-block id scheme, and a
deletion whose cancel never ran — it is fire-and-forget, so a kill at the wrong
moment leaves it behind. Nothing else notices a leftover, since it is counted
neither in what is wanted nor in what a memorial already holds, and it goes on
firing the text baked into it years ago.

## Two reminder series, two id ranges

Each memorial now schedules **two** independent series, and the id block is
partitioned so one cannot overwrite the other (`Memorial`):

```
0..49   main reminder (weekday-of-previous-week / fixed days before)
50..98  day-before reminder, fixed 09:00 (dayBeforeSeriesOffset)
99      missed-reminder catch-up (catchUpIndex)
```

`rescheduleAll` compares the pending count against **both** series. Counting
only the main one made the queue look full, so the day-before series would
never have been scheduled at all.

The notification body carries the weekday, the Gregorian date and a countdown.
Those are computed against the **firing** date via
`memorialDateForReminder` + `describeMemorialForReminder`, not against "now" —
the text is baked in at schedule time, up to 20 years ahead, so anything
derived from the current clock would be wrong by the time it fires.

`hebrewWeekdayNames` includes שבת because a memorial can fall on any day;
`reminderWeekdayChoices` is the six-day subset offered in the reminder picker.

`daysBeforeChoices` is a full 1..`maxDaysBeforeChoice` run with no gaps, and
`NotificationService.snoozeChoiceLadder` is the same run starting at 0. It used
to be a rounded ladder (1, 2, 3, 5, 7, 10, …) that hid the numbers people
actually ask for — four days, six, nine. Anything the old ladder could have
stored has to stay inside the list: `DropdownButtonFormField` throws when its
`initialValue` is not among its items, so narrowing the range would crash the
edit screen for an existing memorial.

## The reminder offers a choice of how long before the memorial

Up to three plain action buttons, labelled by how long **before the memorial**
they land: `quickChoices` filters the ladder to targets later than now and
earlier than the memorial, so the list shrinks as the date approaches and the
buttons disappear on the day itself.

**Do not put the options behind an `AndroidNotificationActionInput` with
`choices`.** That version shipped and produced no snooze at all on the device.
A `RemoteInput` whose `allowFreeFormInput` is false gives the shade nothing to
open — Android only raises the inline input when free-form text is allowed —
and whether the choices render as chips instead is up to the OEM's shade. A
plain action, by contrast, is rendered everywhere. Android shows at most three,
hence `maxRescheduleActions`; `quickChoices` prefers 7 / 3 / 1 days because
they span the range, and backfills the longest remaining option when one of
them has passed, so an early reminder is always among the offers.

The **payload carries the memorial date** — `encodePayload` / `decodePayload`
write `v<version>|<millis>|<body>`, splitting on the first separator so a body
may itself contain one. The background isolate has no database and cannot
re-derive that date, and without it "three days before" has no meaning there.

Boundary worth remembering: the target hour is 09:00, so at N days out the
"N days before" option is still offered until that hour passes. Two test
expectations were written without accounting for it and had to be corrected.

### `ReminderMode.fixedDaysBefore` with a value of 1 broke both of these

Confirmed by the user on 2026-08-31: their reminder was set to "one day
before", and that single setting produced **both** reported symptoms, which is
why neither could be found by reasoning about the default configuration.

- the main reminder lands on `memorial - 1 day` at 09:00, exactly where the
  day-before series already sits, so every reminder arrived twice, one minute
  apart in text only (`אזכרתו של…` and `מחר אזכרתו של…`);
- and at that moment every snooze option pointed at that same instant or
  earlier, so the notification carried no buttons at all.

**Reproduce a notification defect in the user's configuration, not the
default.** Two fixes were built, shipped and disproved on the device before
that setting was asked about; asking took one question.

### The notification carries one action; the list lives on a screen

Android renders at most three actions, so quick buttons could only ever offer
three intervals out of a continuous run — and the interval left out is exactly
the one being asked for. The notification therefore carries a single action,
`דחיית תזכורת`, the only one with `showsUserInterface: true`; it opens the app,
which shows every valid interval in a dialog. No action at all when nothing is
left to choose.

`snoozeChoiceLadder` is a full run, 0..`maxDaysBeforeChoice`, with nothing
skipped; `choicesBefore` trims it to what is still ahead and still before the
memorial. Only 0, 1 and 2 get worded labels — a "שבוע לפני" wedged between
"6 ימים לפני" and "8 ימים לפני" breaks the eye going down a continuous list.

The request reaches the screen by two different paths, and **both are
required**:

- the app is already running → `NotificationService.onChooseReminder`, which
  `HomeScreen` registers from its post-frame callback;
- the app was closed → `getNotificationAppLaunchDetails()`, read by
  `pendingChoiceRequest()`. Without this one, tapping the button on a closed
  app opens the screen and shows nothing.

**Ask for the launch details exactly once per process.** They never clear:
Android answers with the same response for as long as the process lives. Since
`HomeScreen` syncs on every resume, the unguarded version re-offered a
postponement that had already been made, every time the app came back —
endlessly. The guard is in `HomeScreen`, not in the service, for a reason worth
keeping: the service cannot be exercised by a test at all (its plugin is a
private field with no public constructor to subclass), so a guard hidden there
would be untestable, and the fake would have to be written to hide the very bug
it was meant to catch. The fake therefore models Android faithfully — it answers
every time — and the caller is what the test holds to account.

`HomeScreen` keeps the service in a field so `dispose` can unregister: `ref` is
already unusable there and reading it throws. The widget tests caught that
immediately — 47 of them at once.

The dialog rebuilds its list against `DateTime.now()`, not against the
notification's own time: hours may have passed since it fired, and an option
that has since expired must not be offered. It is long enough to scroll, so a
widget test that taps an entry has to pick one near the top or scroll first.

### "On the day of the memorial" is one of the choices

The ladder starts at 0, and 0 means the morning of the memorial itself. Without
it the day-before notification carries **no button at all** — every other
option has already passed by the moment it fires — and so does anything shown
when the memorial is today or tomorrow. The request was a reminder "up to the
day of the memorial, and not after", and the day itself is inside that.

`choicesBefore` therefore bounds the target by the memorial's *date*, not by
the memorial instant. Do not tighten it back to a strict `isBefore(memorial)`:
that silently empties the list exactly when a reminder matters most.

### Two series can land on the same day, and then everything is announced twice

`ReminderMode.fixedDaysBefore` with a value of 1 puts the main reminder one day
before the memorial — which is precisely where the day-before series already
is. At the default hour of 09:00 they fire in the same minute: two identical
notifications, different ids, for one memorial. `dayBeforeMemorialDates` drops
any date whose main reminder falls on the same **day** (not the same instant —
two hours apart still reads as a duplicate to whoever gets it).

This has to live in the calendar rather than in `_scheduleAll`, because
`rescheduleAll` counts `dayBeforeMemorialDates(m).length` to decide whether the
queue is full. Filtering only at schedule time would leave the count too high
and reschedule everything on every resume.

### The plugin declares no receivers — the app must

`flutter_local_notifications`' own `AndroidManifest.xml` holds two permissions
and nothing else. Every component it dispatches through has to be declared in
`android/app/src/main/AndroidManifest.xml` or the intent lands on nothing:

```
ActionBroadcastReceiver              notification action buttons
ScheduledNotificationReceiver        the scheduled notification itself
ScheduledNotificationBootReceiver    BOOT_COMPLETED / MY_PACKAGE_REPLACED
```

`ActionBroadcastReceiver` was missing until 2026-08-31, so **no reminder button
had ever worked** — not the choice list, and not the fixed 1/3/7-day buttons
before it. The failure is completely silent: the buttons render, the tap is
swallowed, no Dart callback runs and nothing is logged. Two redesigns of the
button were shipped chasing that symptom. A test asserts all three receivers
are declared, because nothing else in the toolchain will.

### A queue holding MORE than it should is not a full queue

`rescheduleAll` skipped a memorial when `pending >= wanted`, read as "there are
enough, nothing to do". More than wanted is not a full queue — it is leftovers
from an earlier configuration, and skipping leaves them scheduled forever. That
is how the day-before series survived after `fixedDaysBefore = 1` made it
redundant: 42 scheduled against 21 wanted, so every launch decided there was
nothing to fix and the reminder kept arriving twice, upgrade after upgrade.

The test is now `pending != wanted`, in `needsReschedule`. An excess can only
come from a code or setting change, so this also makes the app self-heal
**without** a `payloadVersion` bump — which matters, because I forgot that bump
one commit after documenting it.

### A change to a notification does not reach the ones already queued

Text and buttons are baked in at `zonedSchedule` time, and `rescheduleAll`
skips any memorial whose window is already full — so an upgrade that changes
the notification changes nothing for an existing install. That is why the
button fix appeared to do nothing beyond a fresh install.

`payloadVersion` is the fix: `rescheduleAll` reschedules a memorial when any of
its pending notifications carries an older marker. **Bump it whenever the baked-in
content changes**, or the change ships only to memorials that are added or
edited afterwards. `decodePayload` still accepts both older shapes (bare body,
and `<millis>|<body>`) because those notifications are what an upgraded install
is holding.

## Nothing that touches the notification plugin may block the UI

Scheduling one memorial issues ~40 `zonedSchedule` calls and the plugin
rewrites its whole JSON blob on each, so anything awaiting it stalls for
seconds. Every entry point is therefore fire-and-forget:

| path | awaited | background |
|---|---|---|
| splash | `load()` (SQLite) | `syncNotifications()` |
| resume | `load()` | `syncNotifications()` |
| add / update | insert + `_refresh()` | `_scheduleAndRecord()` |
| delete | delete + `_refresh()` | `cancelForMemorial()` |

`ui_test.dart` proves this with a fake whose scheduling never completes: if
any of these regained an `await`, the screen would hang and the test would
time out rather than pass.

### …which means `syncNotifications` must be single-flight

`HomeScreen` starts a sync from its post-frame callback **and** from
`didChangeAppLifecycleState` on `resumed`, and opening the app from a
notification fires both at once. While the work was awaited those calls
serialised themselves; once it became fire-and-forget they began to overlap,
and **that is how the duplicate notification came back** on 2026-08-31. Both
runs read the same `lastNotifiedAt`, both conclude the reminder was missed, and
both deliver it.

`MemorialNotifier.syncNotifications` therefore keeps the in-flight future and
hands it to any caller that arrives while it is running. Do not "fix" a
duplicate by moving the `lastNotifiedAt` write earlier — the write is not the
race, the second reader is. The test drives two overlapping syncs and counts
deliveries; with the guard removed it reports 2.
