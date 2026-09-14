# azkarot_app — build & test notes

## Verified end-to-end on hardware (2026-08-04)

A memorial on כ"ז באב (Gregorian 10/08/2026, a Monday) produced a reminder that
fired on **Tuesday 04/08/2026 at the configured hour**, on a physical Samsung
device, with the app closed. Confirmed by the user. This is the first and so far
only live confirmation that the notification path works at all, and it validates:
the Hebrew→Gregorian conversion via `kosher_dart`, the
Tuesday-of-the-week-before rule, `exactAllowWhileIdle` delivery under Doze, and
the `flutter_local_notifications` 17→22 API migration.

Still unconfirmed on hardware, as of 2026-09-04 — the horizon is two Hebrew
years now, not twenty:

- the multi-year recurrence (nothing has yet been observed firing in a later
  year), the boot-receiver restore, and the missed-reminder catch-up;
- the DST edge case, only reachable around the March transition;
- everything added since: the weekly `BackgroundRefresh` job, `CanaryReceiver`,
  the Waze and `geo:` launches, reading the current location, share, and the
  two photo slots;
- **the whole Kotlin layer has no automated coverage at all** — `MainActivity`'s
  method channel and `CanaryReceiver` are exercised by nothing but the device.

That list, and not the Dart defects, is where the real risk sits: the suite can
only ever check what the app believes about itself.

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

## Share and export are different jobs, one file

**Export** saves a copy the user keeps, through the system save dialog.
**Share** hands the file to another app - WhatsApp, mail, anything - through
Android's share sheet, writing to the **cache** directory rather than user
storage: it is a temporary handoff and Android cleans it up. Anyone who wants a
copy on disk uses export.

`_buildBackup` produces the content for both. Two separate builders would drift
apart silently the moment one changed, and the difference would only surface in
a restore; a test counts the call sites to keep it that way.

`share_plus` 12.0.2 builds against the pinned AGP 8.13.2 / Kotlin 2.1.20 set,
which was the risk worth taking deliberately - the alternative was a
hand-written `FileProvider`, which is more surface to get subtly wrong than a
channel that only makes system calls.

Note for the widget tests: the settings body is a **lazy `ListView`**, so each
row added pushes the ones below it out of the built range entirely. A test that
looks for a row below the fold has to `scrollUntilVisible` rather than merely
search - two canary tests broke exactly this way when the share row was added.

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

- **A grave has a point, not only a description.** `latitude`/`longitude`
  (schema v7) sit *beside* `cemetery`/`plot` rather than replacing them: a text
  search reaches the cemetery gate, a coordinate reaches the grave.
  `NavigationLauncher.openCoordinates` uses `geo:lat,lng?q=lat,lng(label)` —
  the repeated `q` with a label matters, because without it some apps centre
  the map on the point without dropping a pin, leaving nothing to press
  "navigate" on. The card prefers the point when both exist, and offers
  navigation when only a point exists.

  The form takes **pasted text**, not a map picker: a picker needs an API key
  and a heavy dependency, and in practice nobody types coordinates — they copy
  them. `Coordinates.tryParse` is deliberately forgiving and takes the first
  pair it finds, so "31.7683, 35.2137", the same without a space, and a whole
  Google Maps URL all work (in a URL the first pair is the place; what follows
  is the zoom). It refuses values outside the real ranges, because a field that
  accepts nonsense is a navigate button that leads nowhere.

  **Percent-decode before matching.** Waze share links encode the comma as
  `%2C`, so undecoded they read as two numbers with no separator and parse as
  nothing — in the very app people use to share a location. Decoding is wrapped
  in a try, since text pasted mid-string can carry broken encoding and
  `decodeFull` throws on it.

  Below the field sits a **labelled** navigate button — "נסיעה לנקודה בוויז" —
  rather than an icon inside it. An icon with a tooltip is not discoverable by
  touch: nothing on screen said what it did or which app it opened. It sits in
  a `Wrap` beside the location button, because two labelled Hebrew buttons do
  not fit one row on a narrow screen and a `Row` overflows.

  It opens Waze straight to
  whatever is typed *right now* — the point of it is to check a value before
  committing to it, so it reads the field rather than the saved record, and it
  is disabled until the text parses. Waze specifically, not the chooser the
  card uses: a check wants a route, not another question. `navigate=yes` is
  what starts driving; without it Waze shows the pin and waits. It falls back
  from `waze://` to the https link, which opens the app if installed and the
  site if not.

  Both the `waze` scheme **and** `<package android:name="com.waze"/>` are
  declared in `<queries>`. Third time this trap has bitten here, after `geo:`
  and `tel:`: without the declaration `canLaunchUrl` returns false however
  well-formed the link is, and the button silently does nothing.

  **"Use my current location"** is the way a grave's point is actually
  captured: you are standing there once a year anyway. `LocationService` wraps
  `geolocator` and reports **why** it failed, not just that it did — a denial
  is a prompt, a permanent denial is system settings, and GPS being off is
  neither, so one message for all three would send the user to the wrong
  screen. It writes into the text field rather than straight into the result,
  so the reading can be seen, corrected or abandoned before saving, and the
  button disables itself while reading: a second tap would start a parallel
  read that could overwrite the newer value.

  The picker is **injected** into `MemorialForm`, like `photoPicker`, so the
  form never touches a plugin and stays testable; passing null hides the
  button. `ACCESS_FINE_LOCATION` is requested only on that tap — ordinary use
  never touches location.

  Two test traps here, both found by failing: the field's `hintText` is a real
  coordinate, so a test using those same numbers matches the hint and passes
  without anything being read; and `ScaffoldMessenger` **queues** snackbars, so
  four failure cases in one loop leave the second and later ones waiting behind
  the first. One test each.

  Two formats deliberately return null rather than a guess: shortened links
  (`maps.app.goo.gl/...`) hold nothing but an id and would need a network fetch,
  and degrees-minutes-seconds (`31°46'05.9"N`) is not parsed at all.

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

Schema is now **v8** (see "Two photos per memorial" below for v8); `_onUpgrade` is incremental and the v3 columns carry SQL
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

### A Hebrew date that some years do not have

`ל' בחשוון` and `ל' בכסלו` exist only when the month runs to thirty days.
`_memorialGregorianForYear` used to return null for the other years and the
whole year was skipped — measured over eleven years, `ל' בחשוון` produced
**five** reminders and `ל' בכסלו` eight. A memorial with no reminder at all is
a worse answer than one on the adjacent day, so it now falls back to the last
day of that month. Both now match an ordinary date.

This is a practical call, not a ruling: some keep the yahrzeit on the 29th and
some on the following Rosh Chodesh. The fallback picks the one that never lands
*after* the original day. A test pins it by comparing the count against an
ordinary date in the same month — the previous test asserted the skipping, so
it had to be inverted rather than adjusted.

### An alarm that was scheduled and never fired

`lastNotifiedAt` is written at schedule time (below), which means the catch-up
is blocked exactly when the alarm was scheduled and then silently killed —
a force-stop, or an OEM battery manager. Measured: with the memorial never
scheduled the catch-up fires; with it scheduled and the alarm lost it returns
null.

The signal that separates them is the plugin's own store: **a delivered
notification is removed from it, so one still listed as pending after its time
has passed never fired.** The payload therefore carries `firesAt`
(`firesAtPayloadVersion`), and `_lostAlarm` looks for a pending entry in the
memorial's block whose firing time is in the past. `_deliverMissed` falls back
to it when `missedReminderDate` says nothing, then **cancels that entry** —
otherwise it would be rediscovered on every launch, since `lastNotifiedAt`
already equals its time and nothing else would stop it.

Two details worth keeping: the pending list is fetched **once per sync**
(`deliverMissedReminders`) rather than per memorial, which was hundreds of
platform calls on a long list; and `decodePayload` only reads `firesAt` when
the version says it is there, or a version-6 payload would have its body torn
in half.

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

## Reminders are scheduled a few years ahead, deliberately

`zonedSchedule` is one-shot, and Android offers no yearly repeat that tracks the
Hebrew calendar — `matchDateTimeComponents` only repeats weekly, monthly, or
annually on a **fixed Gregorian date**, while a Hebrew anniversary drifts. So
`NotificationService.scheduleForMemorial` enumerates
`HebrewCalendarService.futureReminderDates` (horizon:
`scheduleHorizonYears`, currently **2**) and schedules every occurrence. Each
app launch and resume refills the window via `loadAndReschedule`.

**Why not one year, and why not twenty.** One is too few: once the year's
reminder fires, something has to compute and schedule the next, and the boot
receiver only re-registers alarms that already exist — it does not compute new
ones. Twenty was too many: it defended a horizon that other, unhandled failures
reach long before — a new phone, a reinstall, aggressive battery management —
and there is no cloud backup, so a device change resets everything regardless.
It bought that with Android's 500-alarm ceiling and with scheduling that is
quadratic in the number of occurrences.

**The horizon counts Hebrew years, not the lead time that remains**, which is
the part that is easy to misread. A memorial whose date has just passed loses
an occurrence immediately, so in the worst case:

```
horizon 2  ->  1.05 years of cover,  3 alarms per memorial
horizon 3  ->  2.03 years of cover,  4 alarms per memorial
```

That measurement led me to recommend 3; the user chose 2, deliberately. The
consequence is that thirteen months without opening the app can miss one
memorial — unless the weekly refresh runs, which is the thing an OEM battery
manager may defer. Do not change the number without redoing the measurement.

A test that indexes a fixed occurrence (`reminders[5]`) breaks the moment this
changes; anchor on `reminders.last` instead.

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

`pendingReport` counts the queued notifications per memorial, plus anything
whose block belongs to no memorial at all. Rows come back in
`inReminderOrder` — **not** the repository's `created_at DESC` — and each
carries its next reminder date, so the section reads as the schedule itself and
the allocation's choices are visible. In creation order the same numbers say
nothing.

The date shown is the **reminder's** firing time, not the memorial's — they
differ by whatever that memorial's reminder setting says.

**Sorting cannot detect a fault**, since this code does the sorting; rows will
always look ordered. The check that means something is scheduled-versus-planned:
`PendingRow.expected` comes from `allocateBudget`, and a row whose count differs
renders in red and names the gap ("1 מתוך 3") rather than only colouring it.
`PendingReport.inStep` folds that together with orphans and stale payloads, and
the refresh button appears only when it is false — the sync runs on every launch
anyway, so a permanent button would invite taps that do nothing. It is surfaced in the
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

**The budget is global, not per memorial.** `allocateBudget` gathers every
candidate reminder from every memorial, sorts them by date, and takes the
nearest `maxScheduledAlarms` (400, deliberately short of the real limit). Each
memorial's own list is chronological, so a prefix of the sorted list is a prefix
of each memorial's — which is what lets a plain count stand in for a set of
occurrences.

A per-memorial year count measures the wrong thing: Android caps the *total*,
so "N years each" broke silently at about 84 memorials and left the ones that
hit the ceiling with nothing queued at all. Measured coverage under the global
budget, on a list of evenly spread dates:

```
1 name        1 alarm     ~13 months   (worst case: its date has just passed)
10           19           ~20 months
50           99           ~24 months   (the horizon binds here, not the budget)
100         199           ~24 months
200         399           ~24 months
300         400           ~17 months
1000        400           ~5.5 months
```

It degrades instead of breaking. The cost at scale is that a memorial whose
reminder is far off is not scheduled *yet*, so the app has to be opened every
few months rather than every few years. `scheduleForMemorial` takes either a
precomputed `quota` (when the caller is scheduling everything at once) or the
list to allocate `among`.

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

## What only the operating system can answer

`DeliveryChecks` is a hand-written `MethodChannel` in `MainActivity` — **not a
plugin**: the build set is narrow (AGP 8.13.2, Kotlin 2.1.20) and every added
plugin risks the whole build, for what amounts to a handful of system calls. It
covers the questions Dart cannot ask:

- **`channelEnabled`** — `areNotificationsEnabled()` is *app-level*, so a
  channel blocked on its own passed every check the app made while nothing ever
  arrived. Total, silent failure. This was the highest-value gap left.
- **`hasNotificationIcon`** — resolves the drawable at runtime. The shrinker
  once removed it from a release build, because the only reference is a Dart
  string, and every notification then failed silently while being built. The
  `keep.xml` guard and the post-build `aapt2` check still stand; this catches a
  regression on the device itself.
- **`batteryExempt`** / `requestBatteryExemption` — an app Android may stop
  loses its **registered alarms**, including ones scheduled long ago.

The banner ranks them by severity — permission, channel, icon, exact alarms,
battery — because a wrong message sends the user to the wrong settings screen,
and a test pins the order. It shows a fix button only for the two that a
button can fix; a blocked channel and a stripped icon cannot be undone from
inside the app, and a dead button is worse than none.

### The canary alarm

`CanaryReceiver` is a daily alarm that shows nothing. It records that it fired
and re-arms itself, and the settings screen reports the timestamp. **Every other
check in this app examines the app's own bookkeeping; this one observes what
Android actually did.** A stamp going stale means alarms are being suppressed —
known before a memorial is missed rather than after.

It re-arms from inside `onReceive` deliberately: relying on the app being opened
would defeat the point, since it exists for the case where it is not. It uses
`setAndAllowWhileIdle`, not an exact alarm — precision is irrelevant here and it
should not draw from the exact-alarm quota.

**`arm()` must not push an existing deadline forward.** It is called on every
return to the foreground, and the first version rescheduled to *now + 24h* each
time — so for anyone who opens the app daily the canary would never fire at all,
and the row would read "טרם נבדק" forever. Precisely the users whose alarms are
healthy would learn nothing. It now probes with `FLAG_NO_CREATE` and only arms
when nothing is pending; `force` exists for the receiver itself, which must
re-arm after a firing that leaves the PendingIntent intact.

The receiver also listens for `BOOT_COMPLETED`, and on that path arms **without**
recording a firing — a reboot clears alarms, so otherwise the stamp went stale
after every restart and the row reddened for no real reason.

**Do not oversell it.** It proves the alarm mechanism runs. It does *not* prove
a notification was shown, because it shows none — a daily probe that produced
daily noise in the shade would be worse than the problem. The step from "the
alarm fired" to "a notification appeared" has no measurement, and that is not
for lack of trying.

## Import replaces or merges, and the safe one is the default button

`ImportMode.replace` is what import always did: delete everything, insert the
file. `ImportMode.merge` adds only what is missing and deletes nothing.

Identity across devices is `Memorial.identityKey` — **name plus Hebrew date**,
with whitespace normalised. The row id is meaningless outside the device that
issued it (import assigns new ones), so the comparison has to be on content.
The cost is accepted rather than solved: two people with the same name on the
same date merge into one, and one person written two ways duplicates. There is
no better key without asking the user row by row.

### Import asks what to bring in, before it compares anything

`ImportSelectionDialog` lists every memorial in the file with a checkbox,
**all ticked**: importing the whole file is the normal case, and a list that
started empty would make the expected behaviour the one that costs work. A
tristate "הכול" row toggles them together, and both actions are disabled when
nothing is ticked.

The mode buttons live in that same dialog rather than a second one. Three
screens in a row for one action is fatigue, not care.

Everything downstream — the identical/candidate/new analysis — runs on the
**selection**, not the file. There is no sense asking about a clash with a
memorial that was deliberately left out.

It lives in `lib/widgets/` rather than inside the settings screen because it
carries real behaviour worth testing: the default, the tristate, the disabled
actions, and what it hands back. Note the shape of that test — the dialog is
still open when the helper that opens it returns, so a result read there is
always null and the test would assert nothing. The value has to be captured
outside and checked after the dialog closes.

### Similar is asked about, never decided

Exact matches on `identityKey` are skipped silently. **The same Hebrew date
under a different name is a `MergeCandidate`** and the user is asked: the date
is precise and rarely collides, so it is almost always one person written two
ways — but almost is not always. The same name on a *different* date is not a
candidate; two people can share a name, and guessing on names would be noise
rather than help.

`planMerge` computes all of this and touches nothing, so the question comes
before the data does. A test pins that.

Confirming "same person" keeps the **existing** record and fills only its empty
fields from the file (`Memorial.filledFrom`). It cannot lose information: name,
date and reminder rule stay with the record that was already there, and only
gaps are filled. The dialog defaults every candidate to **not** the same
person — a wrong merge discards a record from the file and cannot be undone,
while a wrong split adds a duplicate that is one tap to delete. Between two
mistakes, take the one that can be corrected.

`mergeAll` also folds duplicates *within* the file — a backup can repeat a
memorial — by adding each key to the seen set as it inserts.

In the dialog, **merge is the filled button and replace is plain text**, and
replace names its consequence ("החלפה (מוחק הכול)") rather than saying "ייבוא".
Of the two only one is irreversible, so it should not be the one that looks
like the default.

Tested against the real database rather than the in-memory fake: the point is
the SQL, and the fake would only be testing itself.

## Photo files were never deleted

Not on deleting a memorial, not on an import that replaces everything. They
simply accumulated in app support storage with nothing referencing them — small
each, because of the 256px downscale, but unbounded.

`PhotoStore.deleteOrphans` removes what no memorial points at, and the provider
runs it after a sync and after an import (which produces the largest batch of
orphans at once). It lives in the provider because that is the only layer that
knows the full set of paths in use.

**The grace period is a guard, not a tuning knob.** `MemorialForm` writes the
picked photo to disk *before* the memorial is saved, and in that window the file
is an orphan by every test — a cleanup without the delay would delete the
picture out from under whoever is filling in the form. `PhotoStore` takes an
optional directory so this is tested against real files in a temp directory
rather than a mocked channel.

## Backup is declared, not assumed

`allowBackup`, `fullBackupContent` and `dataExtractionRules` are now explicit,
covering the database and the photo folder. A new phone or a reinstall is the
only scenario that loses *everything* rather than one reminder, and the rules
were undeclared: the defaults may well have covered it, but nothing aimed them
and nothing verified it.

**No `<exclude>` entries.** Once an `<include>` is present everything else is
already excluded, and lint fails the release build for excluding a path outside
the included set — which is how the first attempt was caught.

### Every write to the notification store goes through the lock

The plugin keeps **all** scheduled notifications in a single JSON blob and
rewrites the whole thing on each `zonedSchedule` and each `cancel`. Two
concurrent writers therefore lose one of the two **even with completely
disjoint ids** — they overwrite each other at the file level, not the record
level.

`withSyncLock` is the single place that rule lives. `syncReminders` uses it,
and so do add, edit and delete: the first version of the lock guarded the two
sync paths against each other and left the user-initiated paths touching the
store unguarded, which is the same bug one layer down. Those callers **wait**
rather than skip — an edit that was not scheduled is a reminder that will not
arrive — and a sync holds the lock for seconds while its expiry is ten minutes,
so the wait cannot hang.

### Import is the one caller that may not skip the lock

`syncReminders` normally gives up when the lock is held: the sync runs again on
every resume, so waiting buys nothing. Import is the exception — it has just
replaced every memorial, and skipping would leave the user with **nothing
scheduled** immediately after being told the import succeeded. It passes
`waitForLock`.

Import also no longer calls `cancelAll` first. `replaceAll` deletes and
re-inserts, so the ids change and the old notifications become orphans, which
`rescheduleAll` sweeps anyway. Cancelling up front only opened a window where
everything was cancelled and nothing was scheduled yet.

## Battery optimisation is the last gap the app can narrow

An app Android is allowed to stop does not merely lose background execution —
it loses its **registered alarms**, including ones scheduled long before. That
is the only remaining failure that can miss a reminder outright with every
layer in the app working correctly.

`BatteryExemption` checks `isIgnoringBatteryOptimizations` and can raise the
system dialog. It is a hand-written `MethodChannel` in `MainActivity`, **not a
plugin**: the build set here is narrow (AGP 8.13.2, Kotlin 2.1.20) and every
added plugin risks the whole build, for what amounts to two system calls. The
request falls back to the settings list when the direct dialog will not
resolve.

The state joins `notificationPermissionProvider` alongside the two permissions,
and the home banner ranks them: notifications first (without it nothing shows
at all), then exact alarms, then battery. A test pins that order — naming
battery management while notifications are off sends the user to the wrong
screen.

**Do not oversell this.** Samsung's "sleeping apps" list is managed separately
and has no API: an app cannot remove itself or prevent being added, and Samsung
adds by usage pattern — which makes an app opened twice a year a prime
candidate. The exemption lowers the odds and does not eliminate them. The one
thing that actually closes it is the user checking that list by hand.

`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is a Play-restricted permission, like
`USE_EXACT_ALARM` above. Publishing would likely mean dropping the direct
dialog and sending the user to settings instead.

Widget tests inject a fake exemption (`_FakeBattery`) rather than let the
provider await a real channel — the channel's timing decided whether the banner
had rendered yet, which quietly broke three unrelated permission tests.

## Two isolates, one database, and no shared memory

The background job runs in its own `FlutterEngine` and its own isolate. **Every
static is a separate copy there**, which means the single-flight guard in
`MemorialNotifier` does not cover it at all: the screen and the job can sync at
the same moment, read the same `lastNotifiedAt`, and both deliver the same
reminder — the very failure that produced the duplicate notification. Worse,
`rescheduleAll` cancels before it schedules, so interleaving them can cancel
alarms the other has just written.

`syncReminders` therefore claims a lock **in the database**, the only place the
two isolates can both see. It is a row in `app_state`, taken in a transaction,
and it expires (`staleAfter`, ten minutes, matching the WorkManager limit)
because a process killed mid-run releases nothing and without expiry syncing
would be dead forever. It is released in a `finally`, and a test asserts that —
a throw that kept the lock would silently stop all scheduling.

The same table records the background job's last run and last error. That is
not a nicety: the job runs in another isolate, so `lastScheduleError` — a field
in memory — can never reach the settings screen, and a job failing every week
would be **completely invisible**. `BackgroundRefresh.run` takes an injectable
repo and service purely so this can be tested.

Two isolates also hold two SQLite connections to the same file. Writes are
short and SQLite serialises them, but the lock removes the overlap that would
have made contention likely in the first place.

## The window slides on its own, once a week

`BackgroundRefresh` registers a WorkManager periodic task that reloads the
memorials and runs `rescheduleAll`, without the app being opened.

It exists because nothing else moves the window. A scheduled notification is
one-shot; the plugin has no delivered-callback; the boot receiver only
re-registers alarms that already exist and computes none; and the alarm budget
means only the nearest reminders are queued at all. So when one fires, its slot
frees but nothing fills it — until a launch. On a long list that could mean a
reminder waiting for an app open that never comes.

It runs `syncReminders`, the **same** sequence the home screen runs: deliver
what was missed, then reschedule. It used to reschedule only, which meant a
reminder whose alarm had been killed sat waiting for someone to open the app by
hand. That sequence now lives in `lib/services/reminder_sync.dart` so the two
callers cannot drift apart again — the difference between them was invisible
from anywhere.

The order inside it is load-bearing: rescheduling writes `lastNotifiedAt`
forward to the next occurrence, so running it first buries a missed reminder
for good. A test pins the order rather than the outcome.

Notes for anyone touching it:

- `register()` swallows its own failures. Tests and desktop have no
  WorkManager, and a registration failure must not take down startup — the job
  is a safety net, not the main path.
- `existingWorkPolicy: update`, not `keep`. WorkManager keeps the *original*
  frequency under `keep`, so a change here would never take effect on an
  install that already registered the task.
- The dispatcher is a top-level function annotated `@pragma('vm:entry-point')`,
  same as `notificationTapBackground`, or R8 removes it from the release build.
- `workmanager` 0.10.9 builds cleanly against the pinned AGP 8.13.2 / Kotlin
  2.1.20 set. Verified in the APK: `androidx.work.impl.*` components are
  present in the merged manifest.
- **WorkManager allows a worker about ten minutes.** `rescheduleAll` used to
  re-fetch the entire pending queue *per memorial* inside `cancelForMemorial` —
  hundreds of platform calls each returning hundreds of rows. It now passes the
  snapshot it already holds; the blocks are disjoint, so scheduling one memorial
  cannot invalidate another's ids. The inexact-retry path deliberately fetches
  fresh, because the failed first attempt may already have written notifications
  that the old snapshot does not know about.
- `requiresBatteryNotLow: true` can defer the job indefinitely on a phone kept
  low, and OEM standby buckets stretch "weekly" a long way. A force-stop
  cancels it outright until the app is next opened. None of that is fixable
  from inside the app — which is why the catch-up on launch stays the
  backstop.

## One reminder series, one id block

```
0..98   the reminder itself, nearest occurrence first
99      the missed-reminder catch-up (catchUpIndex)
```

There used to be a second series — a fixed 09:00 reminder the day before the
memorial — in slots 50..98. **It was removed on 2026-09-01**: the postponement
list gives exactly the same thing on the user's own initiative, and the second
series doubled every memorial's share of the alarm budget to pay for it. It also
had to be de-duplicated against the main series, because
`ReminderMode.fixedDaysBefore` with a value of 1 put both on the same day at the
same minute.

`HebrewCalendarService.rescheduledReminderHour` survives it: that is the hour a
postponed reminder lands at, fixed rather than derived from the memorial's own
reminder hour, so a postponement always arrives in the morning.

The notification body carries the weekday, the Gregorian date and a countdown.
Those are computed against the **firing** date via `memorialDateForReminder` +
`describeMemorialForReminder`, not against "now" — the text is baked in at
schedule time, years ahead, so anything derived from the current clock would be
wrong by the time it fires.

`hebrewWeekdayNames` includes שבת because a memorial can fall on any day;
`reminderWeekdayChoices` is the six-day subset offered in the reminder picker.

`daysBeforeChoices` is a full 1..`maxDaysBeforeChoice` run with no gaps, and
`NotificationService.snoozeChoiceLadder` is the same run starting at 0. It used
to be a rounded ladder (1, 2, 3, 5, 7, 10, …) that hid the numbers people
actually ask for — four days, six, nine. Anything the old ladder could have
stored has to stay inside the list: `DropdownButtonFormField` throws when its
`initialValue` is not among its items, so narrowing the range would crash the
edit screen for an existing memorial.

## "Do not remind again" belongs in that list too

The postponement dialog ends with `לא להזכיר יותר`, which switches the memorial
off — the same state as the toggle in the list, so it is reversible, and the
snackbar says so. No extra confirmation: choosing it from a list is already
explicit, and a second prompt would be noise.

It sits in the dialog's **actions** row rather than at the end of the option
list. The intervals scroll, and an entry at the bottom of them was off screen —
a widget test caught that by failing to tap it. For a related reason the list is
a `ListBody` in a `SingleChildScrollView` rather than a lazy `ListView`: a lazy
one builds only what is visible, so a test counting the offered options sees
eight of thirty-one.

The dialog opens even when no interval is left, since switching the reminders
off is still meaningful then — otherwise the button would open the app only to
report there was nothing to do.

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

## Two photos per memorial, at two sizes

A memorial carries **`photo_path`** (the portrait) and **`grave_photo_path`**
(the grave), schema v8. They are not variants of one field — they answer
different questions, and a form with a single picture forced a choice between
"who was this" and "where is the stone".

The sizes differ for that same reason:

| | `PhotoStore.maxDimension` | `PhotoStore.graveMaxDimension` |
|---|---|---|
| portrait | 256 px | |
| grave | | 800 px |

256 px is fine for a 48 px avatar and useless for reading an inscription in a
cemetery; 800 px is where a backup holding dozens of memorials still sends over
WhatsApp, because **every doubling of the side quadruples the file** and photos
travel base64-embedded in the JSON.

Three consequences, each of which is a silent bug if missed:

- `PhotoStore.pickAndStore` / `storeBytes` / `downscale` take an optional
  `maxSide`; `restoreFromBase64` takes one too. **Restoring without it
  re-downscales to 256**, so every export/import cycle would degrade the grave
  photo a little further. The bytes in the backup are already at their final
  size — the restore must not "helpfully" shrink them again.
- Export removes **both** local paths and carries `photo_data` +
  `grave_photo_data`. A path from another device is meaningless for either.
- `Memorial.photoPaths` (not `photoPath`) is what the orphan sweep must use.
  `_cleanUpPhotos` iterating only the portrait would delete every grave photo
  as unreferenced, on the next sync.

`copyWith` needs `clearGravePhoto` alongside `clearPhoto`, for the same reason
the original one exists: `null` means "unchanged" in a `copyWith`, so removing
a picture is not expressible without an explicit flag.

The tile's thumbnail opens the picture full-screen in an `InteractiveViewer`.
Without that the grave photo is unusable exactly where it is needed — 40 px
identifies nothing in a cemetery, and the inscription is usually read zoomed.

## Code review, 2026-09-04 — what a full pass found

Eight real defects across the whole tree. The pattern worth remembering: **most
of them were places where one layer was fixed and the layer next to it was
not**, and every one of them was invisible to `flutter analyze` and to the
suite as it stood.

### A date the calendar schedules but the form refuses

The thirtieth of Cheshvan and of Kislev exists only in years where the month
runs to thirty days. The calendar was taught to fall back to the last day of
the month rather than skip the year — but `MemorialForm._validateHebrewDate`
and `HebrewDatePicker` still asked `daysInMonth` about the **current** year. In
5786, where Cheshvan has 29, that means:

- the date cannot be entered at all — the form reports it does not exist;
- and `HebrewDatePicker.initState` clamps an existing day 30 down to 29, so
  **opening the edit screen silently changed the memorial's date on the next
  save.** Data loss on an ordinary edit, in roughly half the years.

`maxDaysInMonth` answers the length over a 19-year scan (the leap cycle, so
every year type is met) and `isDateEverValid` is what input now asks. Iyar
still comes back 29, so the thirtieth of Iyar is still refused — that half of
the rule is what makes it falsifiable. The lengths are derived from
`kosher_dart` rather than a hardcoded table, so they cannot drift from it.

### Photo file names were never content-addressed

```dart
final name = 'p${resized.lengthInBytes}_${resized.hashCode.abs()}.png';
```

The comment said "named by content, so re-picking the same image does not
create duplicates". **`Uint8List.hashCode` is identity, not content** — lists
in Dart do not override it. So the same picture picked twice made two files,
and, in the dangerous direction, two different images with the same length and
a colliding identity hash would hit `if (!target.existsSync())` and return the
**old** path — silently attaching the wrong photo. Now an FNV-1a pass over the
bytes.

### An empty list left orphaned alarms firing forever

`syncReminders` returned early when there were no memorials. But the sweep for
notifications that belong to no memorial lives inside `rescheduleAll`, and a
delete whose fire-and-forget cancel never ran leaves exactly that. Delete the
last memorial and nothing would ever sweep them; they go on firing the text
baked into them years ago. The test that asserted the old behaviour — "an empty
list is not work" — *was* the bug, so it was inverted rather than adjusted.

### The cross-isolate lock could throw instead of reporting "taken"

`claimSyncLock` read the row and then wrote it. Two isolates both read "free",
and the loser got `SQLITE_BUSY` — an **exception**, not `false`. Uncaught, it
aborted `_claim`'s whole wait loop, in the one caller that may not skip: the
import. Now the transaction is `exclusive: true` (`BEGIN IMMEDIATE`, taking the
write lock up front) and `_tryClaim` treats a throw as a held lock.

### Smaller, still real

- **`Memorial.fromMap` used `DateTime.parse` for `last_notified_at`** while the
  field one line above used `tryParse`. One corrupt value took down a whole
  import, for a marker the next sync recomputes anyway.
- **The settings diagnostics built their `Future` inside `build()`.** Every
  rebuild re-issued `pendingNotificationRequests()` plus a full budget
  allocation, and the row flashed back to "checking...". Worse, the refresh
  button "worked" only as a side effect of the rebuild — which is what makes a
  fix like that fragile. Both futures are now held in fields and reloaded
  explicitly.
- **"Do not remind again" could report that the memorial was not found** on a
  cold launch from the notification button, because the screen read the
  provider's cached list while it was still loading. `setEnabledById` falls
  back to the database.
- **The import row still said it replaces everything** after merge became the
  default button — it promised destruction that the normal path does not do.

### The splash golden was order-dependent

`07_splash.png` passed in a full run and failed when its group ran alone. Two
causes, both timing: the repository fake's load completed after an
indeterminate number of turns, so the capture was sometimes the splash and
sometimes the home screen; and the logo is an asset, whose decode does not
complete under `testWidgets`' fake clock unless an earlier test happened to
warm the image cache.

Fixed by removing the timing from the test rather than by blessing a new
image — `_NeverLoadsRepo` keeps the splash on screen, `_warmLogo` precaches
inside `runAsync`, and an `expect(find.byType(SplashScreen), ...)` makes a
future flip fail with a sentence instead of a pixel count. The regenerated file
came back **byte-identical** to the committed one, which is the evidence that
the old golden was right and only the run order was wrong.

### Known and deliberately left alone

- **The Hebrew date conversions are recomputed per build.** `_sorted`,
  `_filtered`, `_FilterBar`'s counters and every `MemorialCard` call into
  `kosher_dart` on each frame — so a keystroke in the search field costs one
  conversion per memorial. Fine at ten, not obviously fine at the three hundred
  the alarm budget is designed for. Fixing it means memoising in
  `HebrewCalendarService`, which has an injectable clock and therefore a cache
  key that is easy to get subtly wrong. Measure before touching it.
- `_FilterBar` is a plain `Row`; three chips fit the tested viewport but a very
  narrow screen would overflow.
- The photo count in the merge snackbar counts photos in the *selection*, so it
  can overstate when rows are skipped as identical.

### The occurrence line contradicted the date beside it

Found by the user asking the obvious question — "how does it save the 30th of
Cheshvan in a year that has no 30th?" It does not: a memorial is stored as a
recurring anniversary (day + month, **no year**), and each year is resolved
separately. Nothing is ever saved "for" a year.

But the answer exposed a second bug. `formatNextMemorialHebrewDate` promises
the full Hebrew date **of the coming occurrence** — its own doc says so, and it
already resolved the month that way (plain Adar shows as Adar II in a leap
year). The **day** was still taken from the stored field. So the card read:

```
האזכרה הקרובה   יום שבת, 18/11/2028
תאריך עברי      ל' בחשוון תשפ״ט        <- 18/11/2028 is כ"ט
```

Two rows, one card, contradicting each other. The day is now derived from the
Gregorian date that `_memorialGregorianForYear` already produced, so it cannot
drift from it.

The recurring line above (`formatHebrewDate`, no year) still says
`ל' בחשוון` — that is what the memorial *is*, and both facts belong on the
card. The notification body is unchanged for the same reason: it names the
yahrzeit, not the occurrence.

### …and then says why

`adjustedDayNote` puts one line on the card in the years where the stored day
does not exist:

```
ל' בחשוון אינו קיים בתשפ״ט, ולכן האזכרה בכ"ט
```

It returns null in every other year, so the card stays quiet when there is
nothing to explain — a note that always shows is noise rather than help, and a
test pins both halves. Without it the card simply displayed a different day
from the one that was entered, with no reason given.

It covers Adar too, and not only the short months: a memorial saved as Adar I
(thirty days) falls into the single Adar of a non-leap year, which has
twenty-nine — `ל' באדר אינו קיים בתשפ״ו, ולכן האזכרה בכ"ט`.

### The per-build conversions, measured — and then fixed

The review left this one open on the grounds that it needed measuring first.
It did. Measured on the desktop VM (JIT, so indicative rather than a device
number) by pumping the real home screen and timing a keystroke in the search
field, which re-filters, re-counts and re-sorts the whole list:

```
              boot     keystroke (median)
 10 names     600 ms      33.8 ms
 50 names     122 ms      33.5 ms
300 names     220 ms      86.0 ms
```

So the constant ~33 ms is widget rebuilding and is not the interesting part.
The growth is: at the default filter each keystroke costs about **three**
`nextMemorialDate` calls per memorial — `_sorted`, plus two of `_FilterBar`'s
three counters — and 300 cold conversions alone measure ~20 ms.

The cache went in at `_memorialGregorianForYear`, **not** at
`nextMemorialOccurrence**. That placement is the whole safety argument: the
former is a pure function of day, month, adar type and Hebrew year, with no
reference to the clock at all, so there is nothing to expire and a key holding
those four cannot return someone else's answer. The latter depends on
`_now()`, and an injectable clock is exactly the cache key that is easy to get
subtly wrong. The cache is per instance, so a test that builds its own service
starts clean.

```
              boot     keystroke (median)
 10 names     587 ms      29.1 ms
 50 names     109 ms      24.1 ms
300 names     140 ms      41.2 ms      <- was 86.0
```

Two tests hold the property rather than the numbers: a service that has been
asked about every day of every month must agree with a fresh service asked
about one; and two memorials differing in everything except the Hebrew date
must share an entry and still be right, while one differing in the date must
not.

## A year the list does not reach

`deathYearChoices` offers 120 Hebrew years back from the current one. A
great-grandparent is further back than that, and there was no way to enter such
a year at all.

**It was also a crash.** `DropdownButtonFormField` asserts that its value is
among its items, so a memorial carrying a year outside the window took the
whole edit screen down with a Flutter assertion — white screen, no message.
That is reachable today through an imported backup, where `death_hebrew_year`
is a raw integer that no dropdown ever constrained. `_yearChoices()` now adds
the chosen year to the list when the range does not contain it, which is both
the feature and the fix.

The escape hatch is the **last** item, not the first: it is a way out, not the
normal path. Choosing it opens a small dialog that accepts either form —

```
תשפ״ו · התשפ״ו · ה׳תשפ״ו · 5786   ->   5786
```

`parseHebrewYear` completes the missing thousand (a sum below 1000 is the
common shortened spelling) and handles a leading ה explicitly rather than
through the sum — otherwise ה׳תשפ״ו totals 791 and then becomes 5791, a wrong
year that looks entirely valid.

**The dialog echoes what it understood**, formatted and as a number, before the
confirm. Gematria is easy to mistype and a wrong year does not look wrong;
`זזז` is perfectly good arithmetic (21, completed to 5021), so the parser
cannot refuse it and the echo is the only thing that can. Same bargain as the
coordinates field: forgiving input, visible interpretation.

Two traps worth keeping:

- **Cancelling must put the field back by hand.** The dropdown keeps a value of
  its own and `didUpdateWidget` syncs it only when `initialValue` changes —
  which a cancel does not do, so the field stayed on "שנה אחרת…" showing a
  sentinel. A `GlobalKey<FormFieldState<int?>>` and an explicit `didChange`
  after the dialog closes, on both branches.
- A widget test should **not** drive the menu: it holds 120-odd items, so the
  entry at its end is not reliably built. The menu is wired straight to
  `state.didChange`, which sets the internal value *and* calls `onChanged` — so
  calling that one method is exactly a real tap, and the items list is asserted
  separately off the inner `DropdownButton`.

## Who gets Kaddish, and who does not

`MemorialKind` (schema v9) holds three states, and the third one is the point:

```
none     never asked — the default, and what every existing row upgrades to
family   a relative       — אומרים קדיש
tzadik   a rav or tzadik  — ללא קדיש
```

**`none` is not "no".** Defaulting an upgraded row to `family` would assert
something halachic that nobody said, so the column carries a SQL default of
`none` and an unmarked memorial claims neither. The card shows nothing for it —
a marking that appears on everything marks nothing.

The chip says **what to do, not who the person was**: "אומרים קדיש" reads at a
glance, where "משפחה" would need the reader to remember what it implies. Colour
distinguishes the two but never carries the meaning alone — a colour legend
nobody can see is not a marking. In the form the labels are longer and state
the rule in full, because that is the moment of choosing.

The selector is a vertical `RadioGroup`, not a `SegmentedButton`: three labels
of that length do not fit three segments on a narrow screen, and shortening
them to bare categories would put the legend problem right back.

`filledFrom` fills a marking in but never overwrites one, like every other
field it touches — so a merge cannot silently reclassify a memorial.

Note `RadioListTile`'s `groupValue`/`onChanged` are deprecated after 3.32; the
group value belongs on a `RadioGroup` ancestor now.
