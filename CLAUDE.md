# events_app — build & test notes

Flutter app (Android-only platform folder) that reminds about recurring happy
occasions — birthdays, wedding anniversaries, the engagement, the day you met —
on the **Tuesday of the week before** the event's week. Each event is counted in
the **Hebrew calendar by default**, or in the Gregorian one if that is what its
date means.

## This app was converted from a memorial-reminder app (2026-09-18)

It began as `azkarot_app`, which reminded about Hebrew-calendar yahrzeits. The
conversion kept every delivery mechanism intact — the id blocks, the alarm
budget, the cross-isolate lock, the catch-up, the canary — and replaced the
domain: event kinds instead of Kaddish categories, a second calendar, and a
bright look instead of a deliberately muted one.

**It is a different app, not an upgrade.** The applicationId is
`com.example.events_app`, the database is `events.db`, and the schema starts at
version 1 with no migration from the memorial schema. That is deliberate three
times over: the two apps are meant to coexist on one phone, an automatic
conversion of a yahrzeit into a "happy event" would be a change of meaning
rather than a migration, and the memorial app is in real use — its data must not
be touched.

**What was deleted, so nobody restores it by reflex:** the grave location
(cemetery / plot / coordinates), the Waze and `geo:` launches, reading the
current location, and both photo slots — with `geolocator` and the `PhotoStore`
along with them. The user asked for that explicitly. What survived from that
layer is `PhoneLauncher.dial`, because the feedback row in Settings opens the
dialer, and with it the `tel:` entry in the manifest's `<queries>`.

## Nothing here has run on hardware

**Not one line of this app has been on a device.** The suite is green (313
tests) and `flutter analyze` is clean, and neither of those can see what only a
phone can.

What *is* known, from the app this was converted from: on 2026-08-04 an event on
כ"ז באב produced a reminder that fired on the configured hour of the Tuesday
before, on a physical Samsung, with the app closed. That confirmed the parts
this app inherited unchanged — `kosher_dart` conversion, the
Tuesday-of-the-week-before rule, `exactAllowWhileIdle` under Doze, and the
`flutter_local_notifications` 22 API. It says nothing about anything added
since.

Unconfirmed on hardware, and this is where the real risk sits:

- the whole **Gregorian** half — it is exercised only by the suite;
- the multi-year recurrence, the boot-receiver restore, and the
  missed-reminder catch-up;
- the DST edge case, only reachable around the March transition;
- the weekly `BackgroundRefresh` job and `CanaryReceiver`;
- the notification text, title and action buttons as the shade renders them;
- **the whole Kotlin layer has no automated coverage at all** — `MainActivity`'s
  method channel and `CanaryReceiver` are exercised by nothing but the device;
- the 32-bit build. The APK provably *contains* `armeabi-v7a` (see "A phone
  without 64 bits"), which is not the same as having watched it run on an
  armv7 phone — nothing here has.

The suite can only ever check what the app believes about itself.


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
| `event_calendar_service_test.dart`, `event_model_test.dart` | pure date/model logic |
| `database_helper_test.dart` | the **real** SQLite schema + CRUD, and `EventRepository` on top of it, via `sqflite_common_ffi` |
| `ui_test.dart` | every screen rendered, plus add / edit / delete / toggle driven through the provider layer |

313 tests, ~14 seconds on this machine. The deliberate holes:

- `notification_service.dart` — the plugin is a private field with no public
  constructor to subclass, so `ui_test.dart` replaces the whole service with a
  recording stub. **Nothing here proves a notification actually fires at the
  right time.** What *can* be checked without a device is the text, and
  `bodyFor` is public for exactly that reason.
- `settings_screen.dart` — export/import go through `path_provider` and
  `file_picker` platform channels. The data shape they move is covered by the
  JSON round-trip test in `database_helper_test.dart`, but the file I/O is not.
- the Kotlin layer — nothing at all. See "Nothing here has run on hardware".

`sqflite_common_ffi` needs no extra setup on this machine — sqlite resolves
without a DLL override. Note that `DatabaseHelper` caches its connection in a
static field, so the tests truncate the table in `setUp` rather than reopening.

## Running the UI without a device

`test/ui_test.dart` is the entry point: it renders every screen and drives the
add-event and toggle flows through the real provider layer.

The cards show "days until the reminder", so the goldens would fail a day after
being generated. `EventCalendarService` therefore takes an injectable clock
(`EventCalendarService({DateTime Function()? now})`, defaulting to
`DateTime.now`), and the test overrides `calendarServiceProvider` with a
pinned one. Note that `EventForm` and `EventDatePicker` construct the
service directly rather than reading the provider, so a pinned clock does not
reach them — fine today, since neither renders anything clock-dependent.

`flutter test` renders real widgets on the Dart VM, so the actual screens can
be driven and screenshotted with no Android involved. Two things are required:

- Override `eventRepositoryProvider` and `notificationServiceProvider` with
  subclasses — the concrete `EventRepository` / `NotificationService` are
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

- `EventCalendarService.nextOccurrenceDate` accepted a `from` parameter but used
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
  returned the result unnormalised. For an event on 2027-03-28 it returned
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

## What an event carries

- **A kind** (`kind`) — birthday / anniversary / engagement / first-met /
  other. Not a decoration: it is what words the notification
  ("יום ההולדת של דנה" against "יום הנישואין של דנה"), what picks the mark and
  the colour on the card, and the second filter dimension on the list. There is
  no "unmarked" value, unlike the memorial app's categories — every event has a
  kind, and an unknown value from a newer backup falls back to `other`.
- **A calendar** (`calendar`) — Hebrew or Gregorian, per event. See "Two
  calendars, one mechanism" below; this is the biggest thing the conversion
  added.
- **A date** (`day`, `month`, `adar_type`) — one pair of columns for both
  calendars, where `month` is a `HebrewMonth` index for a Hebrew event and 1–12
  for a Gregorian one. A second pair of columns would have invited the question
  "which one is live" at every site that touches it, and a wrong answer there is
  an event on the wrong day.
- **A start year** (`start_year`) — **nullable on purpose**: plenty of events
  are kept without remembering the year, so "unknown" has to stay a legitimate
  value rather than collapse into a wrong default. It is stored **in the
  event's own calendar**, which is what makes it subtractable from the
  occurrence year in `EventCalendarService.anniversaryNumber` ("יום הנישואין
  ה-25"). Subtracting a Hebrew year from a Gregorian occurrence would produce
  about −3760, which then vanishes silently because the count refuses to show a
  number below 1.
- **Snooze** from the notification. The handler runs in a background isolate
  with no `ProviderScope` and no database, so the body text travels in the
  notification `payload`, and timezones are re-initialised there.
  `notificationTapBackground` must stay a top-level function annotated
  `@pragma('vm:entry-point')` or R8 removes it.
- **Configurable reminder timing** (`reminder_mode`, `reminder_value`), default
  `weekdayOfPreviousWeek` + Tuesday. `fixedDaysBefore` gives a consistent gap
  instead of the 5–11 day spread. The default sounds odd for a birthday and is
  not: a present, a restaurant booking or a surprise all need a few days.

Schema is **v1** and `_onUpgrade` is empty — see the conversion note at the top.
Every future change has to be incremental and in ascending order, because by
then there will be installs with data.

### The kind is baked into the notification, so changing it must reschedule

`EventNotifier.setKind` calls `updateEvent`, which cancels and reschedules.
That is **the opposite** of the memorial app, where the equivalent `setKind`
deliberately did *not* touch the notification store and a test asserted the log
stayed empty. The reason flipped with the domain: there the category was a
visual label, here the kind decides the notification's title and its opening
words, and those are written at `zonedSchedule` time. Without the reschedule,
an event switched from birthday to anniversary would go on announcing the old
kind until it was edited for some other reason.

`rescheduleAll` alone is not enough for this: it skips an event whose queue is
already the right size, and changing a kind changes no count.

### Test harness notes for the form

`EventForm` is a lazy `ListView`, and it is tall enough that the save button is
not built until scrolled to — `ensureVisible` throws "No element".
`_revealInForm` drives `ScrollPosition.jumpTo` directly instead of simulating a
drag, because a drag starts at the Scrollable's centre, which lands on the date
picker's wheels and silently changes the date. The finder is scoped to
`EventForm`: the home screen stays mounted beneath the pushed route, so a bare
`find.byType(ListView)` can grab the wrong list.

**The conversion snackbar sits over the save button.** Switching the calendar
announces itself in a `SnackBar`, which floats above the bottom of the screen —
exactly where the save row ends up on a phone viewport. A test that switches
and then saves has to let it expire first (`pump(seconds: 5)`); it was the
cause of a save that silently did nothing. The snackbar's duration is 2 seconds
for the same reason, and the picker's own preview line is what really shows the
converted date.


## Two calendars, one mechanism

An event is counted in the Hebrew calendar (the default) or in the Gregorian
one, per event. The whole difference collapses to one question — *what is the
Gregorian date of the occurrence in year N* — and that question is answered in
`EventCalendarService._occurrenceForYear` and **nowhere else**. Everything above
it (the reminder rule, the future-occurrence window, the missed-reminder
catch-up, the postponement, the alarm budget, the sort order) never learns which
calendar it is dealing with.

The word "year" in that service means **a year in the event's own calendar**:
a Hebrew year for a Hebrew event, a Gregorian year for a Gregorian one.
`_yearOf(date, calendar)` is the one place that translation happens.

**Why not use Android's annual repeat for Gregorian events.** `zonedSchedule`'s
`matchDateTimeComponents` can repeat annually on a fixed Gregorian date, which
would fit them exactly. Doing it would mean two scheduling paths, two
cancellation paths, two ways to count what is queued, and an alarm budget that
cannot be computed — for a saving of nothing that matters. One path.

### 29 February is the twin of ל' בחשוון, and worse

The Hebrew half already had the lesson: a date that some years lack must fall
back to the last day of its month rather than skip the year, because an event
with no reminder is worse than one a day early. The Gregorian half needs the
same rule for 29 February — and carries an extra trap:

```dart
DateTime(2027, 2, 29)   // == 1 March 2027. No error. No warning.
```

It does not fail, it *rolls over* — so the naive version moves the event into
another month, silently. `_computeGregorianOccurrence` therefore asks
`daysInGregorianMonth(year, month)` first and clamps. That helper is
`DateTime(year, month + 1, 0).day` — day zero of the next month — so the leap
rule is never written out by hand and cannot drift.

`maxDaysInMonth` scans four years for a Gregorian month and nineteen for a
Hebrew one (the leap cycles), which is what lets the input accept 29 February
and ל' בחשוון while still refusing 30 February and ל' באייר. `adjustedDayNote`
says which years moved and why, in each calendar's own words.

### Switching an event's calendar must convert the date

"14 בחשוון" and "14 בנובמבר" are two different days. Flipping the calendar
while keeping the numbers would silently change when the event falls — the same
class of bug as the picker that used to roll the 30th down to the 29th without
saying anything.

`convertDate` therefore resolves the source date to a real Gregorian day in a
reference year and reads the target representation off it. **The reference year
is the event's start year when it is known** — converting a wedding date belongs
in the wedding's year — and the next occurrence's year when it is not.

**It returns the converted year too, and that is not a nicety.** The start year
is stored in the event's own calendar; converting the date and leaving the year
would leave a Hebrew 5761 under a Gregorian event, and `anniversaryNumber`
would compute about −3760 and then hide it, because it refuses to show a count
below 1. The anniversary count would vanish with no error anywhere.

Two properties are worth testing over any hardcoded gematria, and both are in
the suite: converting a date and resolving it in the reference year lands on the
very same day, and the anniversary count is identical before and after a switch.

### The cache key includes the calendar

`_occurrenceForYear` is memoised, and it is safe for the same reason it was in
the memorial app: the function is pure in (calendar, day, month, adarType,
year) and never reads the clock. Adding the calendar to the key was mandatory —
without it a Hebrew event and a Gregorian one with the same numbers would
answer for each other.

## The card is coloured, and the colour is information

Each kind owns a fixed hue (`EventCard.kindColor`) which the card uses three
times over: a 6px bar at its start edge, a soft gradient wash, and the ring
around the mark. That is what makes a birthday distinguishable from an
anniversary while scrolling, before a single word is read.

**The kind hues are not derived from the app's theme seed**, deliberately:
someone choosing a colour for the app is not asking to change what marks a
birthday. Same argument the memorial app used for its gold Magen David.

Two layout traps, both found by the screenshot rather than by a failing test:

- **A `Container(width: 6)` inside a `Row` gets zero height.** A `Row` centres
  its children by default, so a child with only a width shrinks to the height
  of the content it does not have — the bar simply was not drawn, and nothing
  failed. `crossAxisAlignment: stretch` fixes that in a normal `Row` but
  **throws inside a `Stack`** ("BoxConstraints forces an infinite height"). The
  bar is a `PositionedDirectional` instead, which stretches to the content's
  height and respects RTL.
- The card's gradient uses `AlignmentDirectional`, not `Alignment`, or it runs
  the wrong way in an RTL layout.

### The marks are drawn, and the emoji lives only in the notification

`EventCard.kindMark` returns a Material icon, or a painted `WeddingRings` for
the anniversary — Material has no wedding rings, so they are two stroked
circles, deliberately overlapping, with the stroke scaled to the size (the same
reasoning that drew the Magen David as one filled polygon: a thin line
disappears at 16px).

The first attempt used the kind's emoji (🎂 💍 💎 💖 🎉). It looked right in
theory and was wrong twice: an emoji renders in the *system* font, so its shape
and colour are the manufacturer's choice, and in a widget test — where exactly
one font is loaded — **it renders as an empty box**. Every golden showed
rectangles where the user would see a cake, which means the goldens stopped
being evidence. `EventKind.emoji` survives for the notification *title*, where
Android draws the text itself and no golden is involved.

### Confetti is drawn, deterministic, and rationed

`Confetti` is a `CustomPainter` with a fixed `seed`, so the same widget paints
the same pieces on every run — an animated or randomised version would fail
every golden against its predecessor with nothing having changed. It appears in
three places only: the splash, the empty list, and the header of a card whose
event is today or tomorrow (`EventCard.celebrateWithin`). A permanent sprinkle
would be decoration; rationed, it means "something is happening now".

It is not drawn on a card whose reminders are switched off, because that would
promise a reminder that will not come.

## The notification says which kind of day it is

The title is `EventKind.notificationTitle` — the emoji plus the kind ("🎂 יום
הולדת") — because the title is the line read first in the shade. The body is
built by `bodyFor`, in one place used by both the scheduled notification and the
missed-reminder catch-up; two separate builders would have drifted apart
silently, and the user sees them as the same message.

**The ordinal comes from the occurrence being scheduled, not from the next
one.** Occurrences are scheduled years ahead, so "יום הנישואין ה-25" next year
is the 26th the year after; `anniversaryNumberFor(event, occurrenceDate)` is the
function that gets this right, and `anniversaryNumber` (the card's version) is
defined in terms of it.

One thing the postponement path cannot do: `rescheduleTo` is static so the
background isolate can reach it, and there is no database there to ask what kind
the event is — so a postponed reminder gets the generic
`NotificationService.rescheduledTitle`. The body, which carries the full
wording, is reused as it was.


## Ported from the memorial app, 2026-10-06

The two apps share every mechanism, so a fix made in `azkarot_app` after the
2026-09-18 split is usually a fix owed here too. Seven commits landed there in
between; what came across, and what deliberately did not:

| there | here |
|---|---|
| Name the day each postponement option lands on | ported |
| Read the option as a sentence ("3 ימים לפני ביום רביעי") | ported |
| Keep save and cancel on screen while the form scrolls | ported |
| One list decides which ABIs ship | ported, **replacing** what this app had |
| Ship one APK that installs on every phone | the ABI half ported; the `uses-feature` half does not apply |
| "problem parsing the package" — the phone was out of space | ported as a diagnosis note |
| Bump to 1.1.1+3001 | not copied; this app has its own versionCode floor |

**The `uses-feature` half has no counterpart here.** There, a location
permission implied `android.hardware.location` as *required*, and the app was
calling itself incompatible with any device lacking a location sensor. This app
deleted the location layer entirely, so no permission it declares implies a
hardware feature — confirmed on the built APK, which prints no
`uses-implied-feature` line at all. Do not copy the `<uses-feature>` block
across; it would be declaring a stance on hardware this app never asks about.

**The versionCode floor is this app's own.** Splits were built here on
2026-09-23 and Flutter prefixes their versionCode per ABI (1001 / 2001 / 4001),
so a universal build at +1 would be a downgrade against any of them if one was
ever installed. `pubspec` is `1.1.0+5000` and must never go below it — the same
trap the memorial app hit, with different numbers.

### The names differ on purpose, in one place

The weekday helpers came across as they were, but the two date formatters were
renamed: `formatDayMonth`/`formatGregorianDate` there are `slashDayMonth` and
`slashDate` here. `EventCalendarService` already owns `formatDayMonth` and
`formatGregorianDayMonth`, which render *words* ("14 בנובמבר") for the Gregorian
half this app added — two functions with near-identical names and different
output is how a card ends up showing the wrong shape of date. When porting the
next change, expect that rename at the boundary.

## The postponement list names the day each option lands on

A row reads **"3 ימים לפני ביום רביעי"**. One sentence, not two fields with a
separator: the interval already identifies every row uniquely, so the weekday is
extra information rather than the identifier, and a date beside it was noise.

The event day itself takes a comma — **"ביום האירוע, יום שני"** — because its
label already opens with ביום and "ביום האירוע ביום שני" stutters. It is the
only label that is not of the form "<n> before", so it is the only row that
needs the exception.

On the title line and not in a subtitle: a two-line `ListTile` is 72px against
56px, which over the 31-row ladder is about 500px of extra scrolling and two
fewer options on screen, for information that is part of the same thought. A
test pins that the longest row stays on one line at 412dp.

### One definition of where a postponement lands

`NotificationService.snoozeTargetFor(eventDate, daysBefore)` is that date, and
it has **three** callers: the filter in `choicesBefore`, the actual scheduling
in `rescheduleTo`, and the label. The arithmetic was written out twice before,
and a third copy in the label is exactly how a screen comes to say "יום רביעי"
while the alarm is set for Tuesday.

`snoozeChoiceLabel` was left alone: it is exact-text-matched by unit tests and
reused verbatim by the snackbar, so the weekday is appended by the screen.

### The confirmation is built from what was scheduled

`התזכורת נדחתה ליום רביעי, 07/07/2027` is composed from the date
`rescheduleReminder` **returned**, not from the label that was tapped. Two
things that buys: a message built from the label could not contradict what was
actually scheduled (it never knew it), and the label-based version produced
`התזכורת נדחתה לביום האירוע` — the ל of the sentence on top of the ב of ביום,
on the one option whose label starts with a preposition.

## Save and cancel are pinned, not scrolled to

The row sat at the end of the form's `ListView`, so saving an edit meant
scrolling past the name, the kind chips, the calendar switch, the date wheels,
the year, the reminder rule, the hour and the notes. It is now outside the
scroll: `Form` ▸ `Column` ▸ `Expanded(ListView)` + `_actionBar`.

**In `EventForm`, not in each screen's `Scaffold`.** The add and edit screens
share this form, and pinning it on one only would be a difference nobody
intended.

The safe-area padding moved with it — the row is what sits above the system
navigation bar now, so it owns the inset. A top hairline rather than elevation,
because Material 3 tints an elevated surface and the row would be the only
thing in the app wearing that colour.

The fields moved into `_fields(theme)` rather than being re-indented inside a
new `Column`: this project is not `dart format`-clean, and a 240-line
re-indentation would have buried the actual change in the diff.

Three things the tests hold, because "the button exists" was never the question:

- both buttons are **on screen** before anything is scrolled — asserted on the
  rect, since a widget parked off screen is still found;
- the rect is **unchanged** after the list is scrolled to its end, with a guard
  that the list really did scroll;
- the keyboard pushes the row up rather than covering it, and the `Column` does
  not overflow (which on a device is the striped banner).

The two tests that asserted `ListView.padding` now assert where the button
lands: the inset used to be the list's bottom padding and now belongs to the
pinned row, and neither of those is the thing that matters.

## A phone without 64 bits

One APK installs on every ARM phone, 32-bit and 64-bit alike. Measured on the
build of 2026-10-06:

```
lib/armeabi-v7a/   32-bit ARM   libapp.so, libflutter.so, libdartjni.so
lib/arm64-v8a/     64-bit ARM   libapp.so, libflutter.so, libdartjni.so
                                                       35.5 MB in total
```

**x86 and x86_64 are excluded on purpose.** On Android they mean an emulator or
a Chromebook, and the cost of carrying them was a fifth of the file. Running on
an x86 emulator therefore needs `-Pabis=x86_64` (below) — that is the price.

### Half an ABI is worse than none, and it is easy to ship

`ndk.abiFilters` governs code built **here**. It does not touch the prebuilt
`.so` a plugin ships inside its AAR — so narrowing through it alone leaves a
`lib/<abi>/` directory holding a plugin library with **no `libflutter.so`**.
That is enough for Android to advertise the ABI as supported: a matching device
installs happily and **crashes on launch**, which is worse than "incompatible"
because it surfaces after the install rather than before it.

`--target-platform android-arm` reaches the same trap from the other side: it
narrows the Flutter engine and leaves the plugins' arm64 libraries in place.

So the ABI set is **one list**, `keptAbis` in `android/app/build.gradle.kts`,
feeding both `abiFilters` and `packaging.jniLibs.excludes`. Excluding an ABI
then removes its directory entirely instead of half of it. A test pins that both
sites derive from that one list.

```bash
# the file to hand out — 35.5 MB, both ARM ABIs
flutter build apk --release

# smaller, for a phone short on storage — 17.3 MB, 32-bit only,
# and it runs on 64-bit ARM too
flutter build apk --release --target-platform android-arm -Pabis=armeabi-v7a
```

Both were built and inspected on 2026-10-06: the universal one carries
`libflutter.so` in **both** ARM directories, and the narrowed one declares
`armeabi-v7a` alone and still carries the engine. Note that the second
overwrites `app-release.apk`, so rebuild the universal one before handing
anything out.

**Verify after any narrowed build** that every surviving directory still holds
the engine:

```bash
unzip -l build/app/outputs/flutter-apk/app-release.apk | grep "lib/"
```

An armeabi-v7a-only APK runs on 32-bit **and** 64-bit ARM phones, so it is a
usable fallback when size is the problem — but **not** on 64-bit-only devices
(Pixel 7 and later, the newest Snapdragons), which cannot run 32-bit code at
all. The two-ABI build stays the default deliverable.

### No permission here implies a hardware feature

Worth stating because the memorial app was bitten by it: a location permission
implies `android.hardware.location`, an implied feature defaults to
**required**, and the app then declares itself incompatible with any device
lacking that sensor. This app deleted the location layer, and the built APK
prints exactly one implied feature — `android.hardware.faketouch`, "default
feature for all apps", which every device satisfies. Check it after adding any
permission:

```bash
aapt2 dump badging <apk> | grep -E "uses-feature|implied"
```

### The real limit is Android 7.0, and it is not ours to lower

The floor is `minSdk 24`, and it comes from **`flutter_local_notifications`
22.2.0**, which declares `minSdkVersion 24` in its own `android/build.gradle`.
The manifest merger takes the maximum, so the app cannot go below it while that
plugin is in the build.

Flutter 3.44's own floor is lower, for reference: `DependencyVersionChecker`
hard-errors below **23** and warns below **24**. So the only step available is
one API level, and it is blocked by the plugin the whole app exists for.
Overriding it with `tools:overrideLibrary` would trade a clean install failure
for a runtime failure **on the delivery path** — the one place this app cannot
afford one. Dropping back to `flutter_local_notifications` 17.x, which allowed
less, is blocked by the compileSdk-34 problem documented above.

Stated for whoever asks next: **a 32-bit phone runs this fine, provided it is on
Android 7.0 or newer.** A 32-bit phone on Android 5 or 6 cannot install it, and
its architecture is not the reason.

### versionCode has a floor, and going under it looks like a corrupt file

`--split-per-abi` builds were produced here on 2026-09-23, and Flutter prefixes
their versionCode per ABI: `1001` for armeabi-v7a, `2001` for arm64-v8a, `4001`
for x86_64. A universal build at `+1` is therefore a **downgrade** against any
of them, and Android refuses a downgrade with a message that says nothing about
versions. `pubspec` is `1.1.0+5000`; never go below it.

### "ארעה בעיה בניתוח החבילה" — ask about free storage first

Inherited from the memorial app, where it was reported and resolved the same day
(2026-10-04): **the device had no free space.** The reasoning there had gone to
the transfer instead, which is the plausible wrong answer worth recording.

Installation needs room for the APK *plus* its unpacked code, several times the
file size. A phone that had just enough room for a 20 MB file does not have it
for a 35 MB one — and this app's file grew for exactly that kind of reason, so
the `-Pabis=armeabi-v7a` build above is a legitimate answer rather than only a
workaround.

The distinction between the two messages is worth keeping: "incompatible" means
Android read the APK and rejected it; **"problem parsing the package" means it
could not read it at all** — and an install that runs out of room lands in the
second bucket on many OEM skins rather than saying so plainly.

Causes in the order they actually occur: no free storage; a truncated or
partially-downloaded transfer (give the recipient the byte size and SHA-256, the
only way to tell a bad file from a bad device state); "install from unknown
sources" disabled, which some skins surface as a parse error. Only then suspect
the file, and check it here before blaming it:

```bash
unzip -t <apk>                                    # zip structure
apksigner verify --verbose <apk>                  # which schemes
aapt2 dump xmltree <apk> --file AndroidManifest.xml | head   # manifest parses
```

**v1 signing is absent by design.** AGP disables JAR signing when `minSdk >= 24`,
so `apksigner` reports `v1: false, v2: true`. That is correct — do not "fix" it.

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

## The launcher icon was still the memorial candle until 2026-10-11

`mipmap-*/ic_launcher.png` came across at the 2026-09-18 split and was never
touched: all five files were **byte-identical to `azkarot_app`'s** — a memorial
candle on a muted purple. The notification icon had been converted (to a
wrapped gift) and the launcher icon had not, so the two disagreed about what
the app is.

It is now a wrapped gift, **the same gift**, on a warm amber-to-rose gradient.

### One shape, declared twice, and deliberately not transcribed

The geometry lives in `ic_notification.xml` in a 24-unit viewport.
`ic_launcher_foreground.xml` reuses those exact `pathData` strings and places
them with a `<group>` transform rather than re-stating them in 108-unit
coordinates. Transcribing them would let the shade icon and the home-screen
icon drift apart silently — the same argument as `_buildBackup` serving both
export and share.

The scale is `2.62` and that number is not free: an adaptive icon is 108 units
but the OEM mask can take anything outside a **66-unit circle**. At the more
obvious 2.93 (which fills the 72-unit square) the bottom corner of the box sits
35 units from the centre and is clipped on round-mask devices. 2.62 puts the
furthest corner at 32.4.

The legacy PNGs use 0.62 of the square instead, because nothing masks them.

### Why the amber is `#FF8F00` and not the card's `#F9A825`

The gradient is built from the app's own hues — the birthday amber and the
first-met rose — rather than an arbitrary pair. But the card's amber is too
light to carry a white mark: the gift's top-left corner disappeared into it.
`#FF8F00 -> #D81B60` keeps white legible at both ends.

### `mipmap-anydpi-v26` is what Android 8+ actually shows

Without it a square icon is shrunk inside a white circle with a border, which
is why old icons look small and dated beside the rest. The PNGs still ship
because `minSdk` is 24 and Android 7 does not know `adaptive-icon`.

A `<monochrome>` entry points at the same foreground, for Android 13's themed
icons.

Unlike `ic_notification`, **these need no `keep.xml` entry**: the launcher icon
is referenced from `android:icon` in the manifest, so the shrinker can see it.
Verified in the built APK — resource names are obfuscated in release, so check
the resource table rather than the file names:

```bash
aapt2 dump resources <apk> | grep -A9 'mipmap/ic_launcher'
# wants five densities plus (anydpi-v26)
```

### Rendering the PNGs with no image tooling

There is no ImageMagick and no Python on this machine (`convert` on PATH is
Windows' filesystem converter, not ImageMagick). The five PNGs were produced by
a throwaway `testWidgets` that paints the same shape into a `PictureRecorder`
inside `runAsync` and writes `toByteData(format: png)` — Flutter is already the
rasteriser for the goldens here, so the icon comes out of the engine that draws
the app.

The file was **deleted after it ran**, on purpose: left in `test/` it would
rewrite the PNGs on every `flutter test`. The vector drawables are the source
of truth; write the generator again from them if the design changes.

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
   — an event added *after* its Tuesday went by —
   `EventCalendarService.missedReminderDate` detects it and
   `deliverMissedReminder` shows it immediately.

### A Hebrew date that some years do not have

`ל' בחשוון` and `ל' בכסלו` exist only when the month runs to thirty days.
`_occurrenceForYear` used to return null for the other years and the
whole year was skipped — measured over eleven years, `ל' בחשוון` produced
**five** reminders and `ל' בכסלו` eight. An event with no reminder at all is
a worse answer than one on the adjacent day, so it now falls back to the last
day of that month. Both now match an ordinary date.

The fallback picks the adjacent day that never lands *after* the original one.
A test pins it by comparing the count against an ordinary date in the same
month.

**29 February is the same problem in the other calendar**, with a trap of its
own — see "29 February is the twin of ל' בחשוון" above.

### An alarm that was scheduled and never fired

`lastNotifiedAt` is written at schedule time (below), which means the catch-up
is blocked exactly when the alarm was scheduled and then silently killed —
a force-stop, or an OEM battery manager. Measured: with the event never
scheduled the catch-up fires; with it scheduled and the alarm lost it returns
null.

The signal that separates them is the plugin's own store: **a delivered
notification is removed from it, so one still listed as pending after its time
has passed never fired.** The payload therefore carries `firesAt`
(`firesAtPayloadVersion`), and `_lostAlarm` looks for a pending entry in the
event's block whose firing time is in the past. `_deliverMissed` falls back
to it when `missedReminderDate` says nothing, then **cancels that entry** —
otherwise it would be rediscovered on every launch, since `lastNotifiedAt`
already equals its time and nothing else would stop it.

Two details worth keeping: the pending list is fetched **once per sync**
(`deliverMissedReminders`) rather than per event, which was hundreds of
platform calls on a long list; and `decodePayload` only reads `firesAt` when
the version says it is there, or a version-6 payload would have its body torn
in half.

### lastNotifiedAt must be written at SCHEDULE time, not only on delivery

`flutter_local_notifications` has no delivery callback (only a tap callback), so
the app cannot observe that a scheduled notification fired. The first version
wrote `lastNotifiedAt` only when the catch-up itself delivered, which produced a
**duplicate notification for every normal delivery**: the alarm fired at 09:00,
the user opened the app at 09:01, `missedReminderDate` saw "reminder passed,
event ahead, nothing recorded" and fired a second one. Reported from the
device on 2026-08-04, and the fix confirmed on the device the same day — the
duplicate no longer appears when reopening the app after a delivery.

So `scheduleForEvent` returns the nearest reminder it scheduled,
`rescheduleAll` returns a `{eventId: nearestReminder}` map, and
`EventNotifier` persists them. The field therefore means "the latest reminder
**accounted for**", not "delivered" — keep it that way.

Known trade-off: a force-stop between scheduling and firing loses that year's
reminder, because the schedule record makes it look handled. The boot receiver
covers the far more common phone-was-off case, so this is the right side to err
on — a guaranteed duplicate every year is worse than a rare miss.

### Notification id scheme changed — legacy ids must be swept

Before the multi-year work the id was the raw event id; it is now
`eventId * 100 + occurrenceIndex`. An upgraded install therefore has orphaned
alarms the new code cannot match, which would fire *alongside* the new schedule.
`rescheduleAll` cancels any pending id below `notificationIdsPerEvent` —
SQLite ids start at 1, so block 0 is never legitimately owned.

## Reminders are scheduled a few years ahead, deliberately

`zonedSchedule` is one-shot, and Android offers no yearly repeat that tracks the
Hebrew calendar — `matchDateTimeComponents` only repeats weekly, monthly, or
annually on a **fixed Gregorian date**, while a Hebrew anniversary drifts. So
`NotificationService.scheduleForEvent` enumerates
`EventCalendarService.futureReminderDates` (horizon:
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
the part that is easy to misread. An event whose date has just passed loses
an occurrence immediately, so in the worst case:

```
horizon 2  ->  1.05 years of cover,  3 alarms per event
horizon 3  ->  2.03 years of cover,  4 alarms per event
```

That measurement led me to recommend 3; the user chose 2, deliberately. The
consequence is that thirteen months without opening the app can miss one
event — unless the weekly refresh runs, which is the thing an OEM battery
manager may defer. Do not change the number without redoing the measurement.

A test that indexes a fixed occurrence (`reminders[5]`) breaks the moment this
changes; anchor on `reminders.last` instead.

Two consequences to preserve when touching this:

- Every event owns a contiguous block of `Event.notificationIdsPerEvent`
  (100) notification ids — `id * 100 + occurrenceIndex`. Without the block, each
  year would overwrite the previous one.
- `cancelForEvent` must cancel the whole block. Cancelling only the base id
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

- `cancelForEvent` asks `pendingNotificationRequests()` what actually exists
  and cancels only those. An earlier version swept all 100 ids in the block,
  which cost 100 round trips per event.
- `rescheduleAll` compares the pending count against
  `futureReminderDates().length` and **skips events whose window is already
  full**. Hebrew dates are deterministic, so there is nothing to recompute.
  Without the skip, every foreground resume re-cancelled and re-scheduled
  everything — roughly 1,200 platform calls with ten events, enough to hang
  startup.

`Event.ownsNotificationId` owns the block-boundary check and is unit-tested;
an off-by-one there silently cancels a *different* event's notifications.

## The reminder can legitimately be in the past

`reminderDate` is 5–11 days before the event, so every year there is a
window where the reminder Tuesday has passed but the event has not.
`NotificationService` must therefore schedule from `nextFutureReminderDate`,
which rolls on to the next Hebrew year; the old code called `reminderDate`,
saw a past date, and returned without scheduling anything — commented as a
"rare edge case" when it actually happens annually for every event. A
event added inside that window got no notification at all, that year or the
next. `EventCard` also renders the negative day count as
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

`pendingReport` counts the queued notifications per event, plus anything
whose block belongs to no event at all. Rows come back in
`inReminderOrder` — **not** the repository's `created_at DESC` — and each
carries its next reminder date, so the section reads as the schedule itself and
the allocation's choices are visible. In creation order the same numbers say
nothing.

The date shown is the **reminder's** firing time, not the event's — they
differ by whatever that event's reminder setting says.

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
Twenty years across two series is 42 alarms per event, so the ceiling is
breached at about a dozen events — and because `scheduleForEvent` cancels
before it reschedules, the event that hits it is left with **nothing**
queued. The user sees a reminder that never fires and only appears on opening
the app, which is the catch-up.

**The budget is global, not per event.** `allocateBudget` gathers every
candidate reminder from every event, sorts them by date, and takes the
nearest `maxScheduledAlarms` (400, deliberately short of the real limit). Each
event's own list is chronological, so a prefix of the sorted list is a prefix
of each event's — which is what lets a plain count stand in for a set of
occurrences.

A per-event year count measures the wrong thing: Android caps the *total*,
so "N years each" broke silently at about 84 events and left the ones that
hit the ceiling with nothing queued at all. Measured coverage under the global
budget, on a list of evenly spread dates:

**This table has now been wrong twice, so measure it, never reason about it.**
The first version was measured under the 20-year horizon and never redone when
the horizon dropped to two. The second (2026-09-14) claimed ~24 months of
cover, which contradicted the horizon arithmetic written a few sections up in
this same file — two Hebrew years of *occurrences* is about 13 months of
*cover*, because the nearest occurrence is usually already behind.

Re-measured 2026-09-18 on this code (horizon 2, budget 400, dates spread
through the Hebrew year, coverage = the point at which the FIRST event runs out
of scheduled reminders):

```
1 event       2 alarms   13.7 months
10           20          13.7 months
50          104          13.7 months
100         209          13.7 months
140         292          13.7 months   <- the horizon binds up to about here
200         400          12.5 months   <- the budget binds from here
300         400           4.5 months
1000        400           0            <- most get nothing; the catch-up carries them
```

So: up to ~140 active events the app has to be opened about once a year, at 300
about every four months, and past that essentially every time. Disabled events
are not counted at all, which is what makes switching one off the right way to
archive it.

The measurement is a throwaway test (build N events, sum `allocateBudget`, take
the earliest last-scheduled reminder) — write it again rather than trusting
this table after any change to the horizon, the budget or `futureReminderDates`.

It degrades instead of breaking. The cost at scale is that an event whose
reminder is far off is not scheduled *yet*, so the app has to be opened every
few months rather than every few years. `scheduleForEvent` takes either a
precomputed `quota` (when the caller is scheduling everything at once) or the
list to allocate `among`.

And when exact scheduling is refused anyway — a missing `SCHEDULE_EXACT_ALARM`
grant does the same thing — scheduling **retries once in
`inexactAllowWhileIdle`** rather than giving up. Punctuality and delivery are
separate requirements here, and delivery is the one that matters: a reminder a
few minutes late beats no reminder. The settings row still names what happened.

**`scheduleForEvent` cancels before it schedules**, so a throw inside
`_scheduleAll` leaves the event with *nothing* queued — and the only symptom
is "the reminder never fires, it only appears when I open the app", because all
that is left is the catch-up. The `on Exception` there used to be silent, which
made a scheduling failure indistinguishable from a delivery failure without a
cable. It now records `lastScheduleError`, and the settings row shows it in red
along with the two permissions that gate delivery. Read that row first.

Record the **first line only** (`firstLineOf`). A `PlatformException`'s
`toString` drags its whole stack along, and the first attempt filled the screen
with frames while the reason itself scrolled out of view.

`rescheduleAll` also sweeps every pending id that belongs to no current
event. Two things strand a whole block: the pre-block id scheme, and a
deletion whose cancel never ran — it is fire-and-forget, so a kill at the wrong
moment leaves it behind. Nothing else notices a leftover, since it is counted
neither in what is wanted nor in what an event already holds, and it goes on
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
known before an event is missed rather than after.

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

Identity across devices is `Event.identityKey` — **name plus Hebrew date**,
with whitespace normalised. The row id is meaningless outside the device that
issued it (import assigns new ones), so the comparison has to be on content.
The cost is accepted rather than solved: two people with the same name on the
same date merge into one, and one person written two ways duplicates. There is
no better key without asking the user row by row.

### Import asks what to bring in, before it compares anything

`ImportSelectionDialog` lists every event in the file with a checkbox,
**all ticked**: importing the whole file is the normal case, and a list that
started empty would make the expected behaviour the one that costs work. A
tristate "הכול" row toggles them together, and both actions are disabled when
nothing is ticked.

The mode buttons live in that same dialog rather than a second one. Three
screens in a row for one action is fatigue, not care.

Everything downstream — the identical/candidate/new analysis — runs on the
**selection**, not the file. There is no sense asking about a clash with a
event that was deliberately left out.

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
fields from the file (`Event.filledFrom`). It cannot lose information: name,
date and reminder rule stay with the record that was already there, and only
gaps are filled. The dialog defaults every candidate to **not** the same
person — a wrong merge discards a record from the file and cannot be undone,
while a wrong split adds a duplicate that is one tap to delete. Between two
mistakes, take the one that can be corrected.

`mergeAll` also folds duplicates *within* the file — a backup can repeat a
event — by adding each key to the seen set as it inserts.

In the dialog, **merge is the filled button and replace is plain text**, and
replace names its consequence ("החלפה (מוחק הכול)") rather than saying "ייבוא".
Of the two only one is irreversible, so it should not be the one that looks
like the default.

Tested against the real database rather than the in-memory fake: the point is
the SQL, and the fake would only be testing itself.

## Backup is declared, not assumed

`allowBackup`, `fullBackupContent` and `dataExtractionRules` are now explicit,
covering the database. A new phone or a reinstall is the
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
replaced every event, and skipping would leave the user with **nothing
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
`EventNotifier` does not cover it at all: the screen and the job can sync at
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
events and runs `rescheduleAll`, without the app being opened.

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
  re-fetch the entire pending queue *per event* inside `cancelForEvent` —
  hundreds of platform calls each returning hundreds of rows. It now passes the
  snapshot it already holds; the blocks are disjoint, so scheduling one event
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
event — in slots 50..98. **It was removed on 2026-09-01**: the postponement
list gives exactly the same thing on the user's own initiative, and the second
series doubled every event's share of the alarm budget to pay for it. It also
had to be de-duplicated against the main series, because
`ReminderMode.fixedDaysBefore` with a value of 1 put both on the same day at the
same minute.

`EventCalendarService.rescheduledReminderHour` survives it: that is the hour a
postponed reminder lands at, fixed rather than derived from the event's own
reminder hour, so a postponement always arrives in the morning.

The notification body carries the weekday, the Gregorian date and a countdown.
Those are computed against the **firing** date via `eventDateForReminder` +
`describeEventForReminder`, not against "now" — the text is baked in at
schedule time, years ahead, so anything derived from the current clock would be
wrong by the time it fires.

`hebrewWeekdayNames` includes שבת because an event can fall on any day;
`reminderWeekdayChoices` is the six-day subset offered in the reminder picker.

`daysBeforeChoices` is a full 1..`maxDaysBeforeChoice` run with no gaps, and
`NotificationService.snoozeChoiceLadder` is the same run starting at 0. It used
to be a rounded ladder (1, 2, 3, 5, 7, 10, …) that hid the numbers people
actually ask for — four days, six, nine. Anything the old ladder could have
stored has to stay inside the list: `DropdownButtonFormField` throws when its
`initialValue` is not among its items, so narrowing the range would crash the
edit screen for an existing event.

## "Do not remind again" belongs in that list too

The postponement dialog ends with `לא להזכיר יותר`, which switches the event
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

## The reminder offers a choice of how long before the event

Up to three plain action buttons, labelled by how long **before the event**
they land: `quickChoices` filters the ladder to targets later than now and
earlier than the event, so the list shrinks as the date approaches and the
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

The **payload carries the event date** — `encodePayload` / `decodePayload`
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

- the main reminder lands on `event - 1 day` at 09:00, exactly where the
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
event. Only 0, 1 and 2 get worded labels — a "שבוע לפני" wedged between
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

### "On the day of the event" is one of the choices

The ladder starts at 0, and 0 means the morning of the event itself. Without
it the day-before notification carries **no button at all** — every other
option has already passed by the moment it fires — and so does anything shown
when the event is today or tomorrow. The request was a reminder "up to the
day of the event, and not after", and the day itself is inside that.

`choicesBefore` therefore bounds the target by the event's *date*, not by
the event instant. Do not tighten it back to a strict `isBefore(event)`:
that silently empties the list exactly when a reminder matters most.

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

`rescheduleAll` skipped an event when `pending >= wanted`, read as "there are
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
skips any event whose window is already full — so an upgrade that changes
the notification changes nothing for an existing install. That is why the
button fix appeared to do nothing beyond a fresh install.

`payloadVersion` is the fix: `rescheduleAll` reschedules an event when any of
its pending notifications carries an older marker. **Bump it whenever the baked-in
content changes**, or the change ships only to events that are added or
edited afterwards. `decodePayload` still accepts both older shapes (bare body,
and `<millis>|<body>`) because those notifications are what an upgraded install
is holding.

## Nothing that touches the notification plugin may block the UI

Scheduling one event issues ~40 `zonedSchedule` calls and the plugin
rewrites its whole JSON blob on each, so anything awaiting it stalls for
seconds. Every entry point is therefore fire-and-forget:

| path | awaited | background |
|---|---|---|
| splash | `load()` (SQLite) | `syncNotifications()` |
| resume | `load()` | `syncNotifications()` |
| add / update | insert + `_refresh()` | `_scheduleAndRecord()` |
| delete | delete + `_refresh()` | `cancelForEvent()` |

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

`EventNotifier.syncNotifications` therefore keeps the in-flight future and
hands it to any caller that arrives while it is running. Do not "fix" a
duplicate by moving the `lastNotifiedAt` write earlier — the write is not the
race, the second reader is. The test drives two overlapping syncs and counts
deliveries; with the guard removed it reports 2.

## Code review, 2026-09-04 — what a full pass found

Eight real defects across the whole tree, seven of which still apply here — the
eighth was about photo file names and went out with the photos. The pattern
worth remembering: **most of them were places where one layer was fixed and the
layer next to it was not**, and every one of them was invisible to
`flutter analyze` and to the suite as it stood.

### A date the calendar schedules but the form refuses

The thirtieth of Cheshvan and of Kislev exists only in years where the month
runs to thirty days. The calendar was taught to fall back to the last day of
the month rather than skip the year — but `EventForm._validateHebrewDate`
and `EventDatePicker` still asked `daysInMonth` about the **current** year. In
5786, where Cheshvan has 29, that means:

- the date cannot be entered at all — the form reports it does not exist;
- and `EventDatePicker.initState` clamps an existing day 30 down to 29, so
  **opening the edit screen silently changed the event's date on the next
  save.** Data loss on an ordinary edit, in roughly half the years.

`maxDaysInMonth` answers the length over a 19-year scan (the leap cycle, so
every year type is met) and `isDateEverValid` is what input now asks. Iyar
still comes back 29, so the thirtieth of Iyar is still refused — that half of
the rule is what makes it falsifiable. The lengths are derived from
`kosher_dart` rather than a hardcoded table, so they cannot drift from it.

### An empty list left orphaned alarms firing forever

`syncReminders` returned early when there were no events. But the sweep for
notifications that belong to no event lives inside `rescheduleAll`, and a
delete whose fire-and-forget cancel never ran leaves exactly that. Delete the
last event and nothing would ever sweep them; they go on firing the text
baked into them years ago. The test that asserted the old behaviour — "an empty
list is not work" — *was* the bug, so it was inverted rather than adjusted.

### The cross-isolate lock could throw instead of reporting "taken"

`claimSyncLock` read the row and then wrote it. Two isolates both read "free",
and the loser got `SQLITE_BUSY` — an **exception**, not `false`. Uncaught, it
aborted `_claim`'s whole wait loop, in the one caller that may not skip: the
import. Now the transaction is `exclusive: true` (`BEGIN IMMEDIATE`, taking the
write lock up front) and `_tryClaim` treats a throw as a held lock.

### Smaller, still real

- **`Event.fromMap` used `DateTime.parse` for `last_notified_at`** while the
  field one line above used `tryParse`. One corrupt value took down a whole
  import, for a marker the next sync recomputes anyway.
- **The settings diagnostics built their `Future` inside `build()`.** Every
  rebuild re-issued `pendingNotificationRequests()` plus a full budget
  allocation, and the row flashed back to "checking...". Worse, the refresh
  button "worked" only as a side effect of the rebuild — which is what makes a
  fix like that fragile. Both futures are now held in fields and reloaded
  explicitly.
- **"Do not remind again" could report that the event was not found** on a
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

- The date conversions are recomputed on every build — see "The per-build
  conversions, measured" below for the cache that took the worst of it out.
  What remains is widget rebuilding, which measured flat.
- **The identity key for a merge is name + date + calendar**, so two different
  people who share a name and a birthday merge into one. Same-date-different-
  name is asked about; same-name-same-date is treated as a duplicate without
  asking. Birthdays collide far more often than yahrzeits did, which makes this
  the weakest remaining assumption in the import.

### The occurrence line contradicted the date beside it

Found by the user asking the obvious question — "how does it save the 30th of
Cheshvan in a year that has no 30th?" It does not: an event is stored as a
recurring anniversary (day + month, **no year**), and each year is resolved
separately. Nothing is ever saved "for" a year.

But the answer exposed a second bug. `formatNextOccurrence` promises
the full Hebrew date **of the coming occurrence** — its own doc says so, and it
already resolved the month that way (plain Adar shows as Adar II in a leap
year). The **day** was still taken from the stored field. So the card read:

```
האזכרה הקרובה   יום שבת, 18/11/2028
תאריך עברי      ל' בחשוון תשפ״ט        <- 18/11/2028 is כ"ט
```

Two rows, one card, contradicting each other. The day is now derived from the
Gregorian date that `_occurrenceForYear` already produced, so it cannot
drift from it.

The recurring line above (`formatEventDate`, no year) still says
`ל' בחשוון` — that is what the event *is*, and both facts belong on the
card. The notification body is unchanged for the same reason: it names the
anniversary, not the occurrence.

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

It covers Adar too, and not only the short months: an event saved as Adar I
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
`nextOccurrenceDate` calls per event — `_sorted`, plus two of `_FilterBar`'s
three counters — and 300 cold conversions alone measure ~20 ms.

The cache went in at `_occurrenceForYear`, **not** at
`nextOccurrence**. That placement is the whole safety argument: the
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
about one; and two events differing in everything except the Hebrew date
must share an entry and still be right, while one differing in the date must
not.

## A year the list does not reach

`startYearChoices` offers 120 years back from the current one, **in the calendar
of the event** — gematria for a Hebrew event, digits for a Gregorian one. A
grandparent born further back than that had no way in at all.

**It was also a crash.** `DropdownButtonFormField` asserts that its value is
among its items, so an event carrying a year outside the window took the
whole edit screen down with a Flutter assertion — white screen, no message.
That is reachable today through an imported backup, where `start_year`
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
cannot refuse it and the echo is the only thing that can: forgiving input,
visible interpretation.

**One dialog serves both calendars**, because `parseHebrewYear` returns a plain
number as itself — so `1998` is 1998 and תשנ"ח is 5758. Only the hint text and
the echo differ by calendar.

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

## The colour is a choice, in Settings

`ThemeSeed` holds eight seeds; Material 3 derives the whole scheme — surfaces,
cards, chips, both brightnesses — from one of them. That is why the choice is a
single hue rather than a colour per component: a derived scheme keeps contrast
correct in every combination, while per-component picking produces unreadable
pairs that nobody notices until a user is squinting at one.

**The hues are saturated on purpose, and this is the one place the conversion
reversed a rule rather than renaming it.** The memorial app's palette was
deliberately muted, because "an app about memorials should not shout". An app
about birthdays should: it has to look like one the moment it opens. The only
limit kept is legibility — every seed was checked to derive a scheme that holds
contrast in both brightnesses, which is also why the kind colours are used as
washes and marks and never as a background for text.

**`ThemeSeed.fallback` is rose**, and an unknown stored value falls back rather
than throwing — a theme is a preference, never a reason to fail to start. A
test pins both, and a second one pins that no two swatches share a colour: two
swatches that look alike are not a choice.

Stored in `app_state`, the same key/value table that already holds the sync
lock and the background-job status; it exists for exactly this kind of value.

**Loaded asynchronously, not before the first frame.** Reading it before
`runApp` would block startup — and opening the database also runs migrations —
which is precisely the work that was taken out of the splash screen. The cost,
stated plainly: on a cold start the splash is painted once in the default and
then changes. The *choice* is instant, because the state is set before the
write.

The picker is swatches, not a list of names: the decision is entirely visual
and the name of a hue says less than the hue. The name survives as a tooltip
and a semantics label. The selected one is marked with a ring and a check, not
by colour alone — two adjacent hues look alike, and a marking that relies on
the colour it is marking is not a marking.

Note for the test fakes: `_InMemoryRepo` had to gain `readSetting`/
`writeSetting`, or every settings read falls through to real sqflite and dies
on a platform channel that does not exist under test.

### The keyboard came back on its own

Reported from the device: changing a category from the list raised the
keyboard. The cause is not the sheet — **a modal route restores focus to
whatever held it when the route opened**, and after a search that is the search
field. So leaving the list and coming back pulled the keyboard up over a list
the user was only trying to look at.

Which means it was never about categories. Reproducing it showed the **edit
screen does exactly the same thing**, and so would anything else pushed from
the list. Two failing tests, one cause.

The fix is one `Listener` around the screen body:

```dart
body: Listener(
  onPointerDown: (_) => FocusManager.instance.primaryFocus?.unfocus(),
  child: Column(...),
)
```

Three choices in that, each load-bearing:

- **`Listener`, not `GestureDetector`** — it observes without consuming, so the
  tap still reaches the chip, the card and the switch.
- **`onPointerDown`, not `onTap`** — the focus has to be released *before* the
  route is pushed, or there is something to restore again.
- **One place, not every caller** — the app bar stays outside it, so the search
  field itself still works, and anything added to the body later is covered
  without remembering to.

Two things this cost, worth knowing:

- `dart format` on a single file produced a 93-line diff, because **the project
  is not format-clean** (13 of 29 files would change). Formatting one file in
  isolation buries the change. Reverted and re-indented by hand; `git diff -w`
  shows the real change is 18 lines.
- `git checkout` restored the file with **CRLF** (Windows `core.autocrlf`),
  which silently broke every multi-line anchor in the patch scripts. Normalise
  to LF before matching.
