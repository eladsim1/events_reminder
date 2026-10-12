import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/event_date.dart';
import '../models/event.dart';
import '../models/event_filter.dart';
import '../models/theme_seed.dart';
import '../models/merge_plan.dart';
import '../repository/event_repository.dart';
import '../services/delivery_checks.dart';
import '../services/event_calendar_service.dart';
import '../services/phone_launcher.dart';
import '../services/notification_service.dart';
import '../services/reminder_sync.dart';

/// מה עושה ייבוא עם מה שכבר קיים.
///
/// [merge] אינו מוחק דבר; [replace] מוחק את הכול ואינו הפיך.
enum ImportMode { merge, replace }

/// ספקי תשתית (Repository ושירותים).
final eventRepositoryProvider = Provider<EventRepository>((ref) {
  return EventRepository();
});

final phoneLauncherProvider = Provider<PhoneLauncher>((ref) {
  return const PhoneLauncher();
});

final deliveryChecksProvider = Provider<DeliveryChecks>((ref) {
  return const DeliveryChecks();
});

final calendarServiceProvider =
    Provider<EventCalendarService>((ref) {
  return EventCalendarService();
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(
    calendar: ref.watch(calendarServiceProvider),
  );
});

/// הסינון הנבחר ברשימה.
///
/// מכוון לאיפוס בכל הפעלה: פתיחת האפליקציה עם סינון פעיל מלפני שבוע נראית
/// כאילו האירועים נעלמו.
final eventFilterProvider = StateProvider<EventFilter>((ref) {
  return EventFilter.all;
});

/// הקטגוריה שמוצגת, או null לכולן.
///
/// ממד נפרד מ-[eventFilterProvider]: זה חלון זמן וזו קטגוריה, והם
/// נחתכים. מתאפס בכל הפעלה מאותה סיבה – פתיחה עם סינון ישן נראית כאילו
/// חצי מהרשימה נעלמה.
final eventKindFilterProvider = StateProvider<EventKind?>((ref) => null);

/// שאילתת החיפוש הפעילה. ריק = ללא חיפוש.
final eventSearchProvider = StateProvider<String>((ref) => '');

/// מצב ההרשאות שבלעדיהן ההתראות פשוט לא יעבדו.
///
/// נחשף כספק נפרד כדי שהמסך הראשי יוכל להזהיר – בלעדיו סירוב הרשאה הוא
/// כשל שקט: האפליקציה נראית תקינה לגמרי ופשוט לעולם לא מתריעה.
/// כל מה שצריך להיות תקין כדי שתזכורת תגיע בפועל.
///
/// בלי [notificationsEnabled] דבר לא יוצג; בלי [channelEnabled] אותו דבר,
/// אלא שהבדיקה ברמת האפליקציה עוברת בשלום ולכן זה כשל שקט לגמרי; בלי
/// [exactAlarmsAllowed] התזמון יורד לדיוק משוער; בלי [batteryExempt]
/// אנדרואיד רשאי לעצור את האפליקציה **ולמחוק את האזעקות הרשומות שלה**;
/// ובלי [hasNotificationIcon] כל התראה נכשלת בבנייה בזמן הירי.
final notificationPermissionProvider = FutureProvider<
    ({
      bool notificationsEnabled,
      bool exactAlarmsAllowed,
      bool batteryExempt,
      bool channelEnabled,
      bool hasNotificationIcon,
      DateTime? canaryLastFired,
    })>((ref) async {
  final permissions =
      await ref.watch(notificationServiceProvider).permissionStatus();
  final checks = ref.watch(deliveryChecksProvider);

  // מזמנים את הביקורת הבאה בכל בדיקה. היא חד-פעמית ומזמנת את עצמה מחדש,
  // אבל אם אנדרואיד מחק אותה זו ההזדמנות להחזיר אותה.
  await checks.armCanary();

  return (
    notificationsEnabled: permissions.notificationsEnabled,
    exactAlarmsAllowed: permissions.exactAlarmsAllowed,
    batteryExempt: await checks.batteryExempt(),
    channelEnabled:
        await checks.channelEnabled(NotificationService.channelId),
    hasNotificationIcon: await checks.hasNotificationIcon(),
    canaryLastFired: await checks.canaryLastFired(),
  );
});

/// צבע הבסיס של האפליקציה, נשמר בין הפעלות.
///
/// **נטען אסינכרונית ולא לפני הציור הראשון.** קריאה מהמסד לפני runApp
/// הייתה חוסמת את העלייה – ופתיחת המסד מריצה גם מיגרציות – וזו בדיוק
/// העבודה שהוצאה ממסך הפתיחה. המחיר: בהפעלה קרה מסך הפתיחה מצויר רגע
/// בברירת המחדל ואז מתחלף. הבחירה עצמה מיידית, כי המצב נקבע לפני השמירה.
class ThemeSeedNotifier extends Notifier<ThemeSeed> {
  static const String storageKey = 'theme_seed';

  @override
  ThemeSeed build() {
    _load();
    return ThemeSeed.fallback;
  }

  Future<void> _load() async {
    try {
      final saved =
          await ref.read(eventRepositoryProvider).readSetting(storageKey);
      final seed = ThemeSeed.fromDb(saved);
      if (seed != state) state = seed;
    } catch (_) {
      // אין מסד (שולחן עבודה, בדיקות). ערכה היא העדפה ולא סיבה להיכשל.
    }
  }

  Future<void> choose(ThemeSeed seed) async {
    state = seed; // קודם המסך, אחר כך הדיסק
    try {
      await ref
          .read(eventRepositoryProvider)
          .writeSetting(storageKey, seed.dbValue);
    } catch (_) {}
  }
}

final themeSeedProvider =
    NotifierProvider<ThemeSeedNotifier, ThemeSeed>(ThemeSeedNotifier.new);

/// שעת ברירת מחדל להתראות (שעה, דקה). ניתנת לשינוי במסך ההגדרות.
class DefaultReminderTime {
  final int hour;
  final int minute;
  const DefaultReminderTime(this.hour, this.minute);
}

final defaultReminderTimeProvider =
    StateProvider<DefaultReminderTime>((ref) {
  return const DefaultReminderTime(9, 0);
});

/// מצב רשימת האירועים.
///
/// כל המסכים קוראים מכאן ואינם ניגשים ישירות ל-Repository או ל-SQLite.
class EventNotifier extends AsyncNotifier<List<Event>> {
  EventRepository get _repo => ref.read(eventRepositoryProvider);
  NotificationService get _notifications =>
      ref.read(notificationServiceProvider);

  @override
  Future<List<Event>> build() async {
    return _repo.getAll();
  }

  Future<void> _refresh() async {
    state = AsyncData(await _repo.getAll());
  }

  /// טוען את הרשימה בלבד. מהיר – קריאת SQLite אחת.
  ///
  /// מופרד מ-[syncNotifications] במכוון: עבודת התזמון עולה עשרות קריאות
  /// פלטפורמה לכל אירוע, והפלאגין כותב מחדש את כל רשימת ההתראות בכל
  /// קריאה. כשהיא חסמה את מסך הפתיחה, האפליקציה נראתה תקועה בכל עלייה.
  Future<void> load() async {
    try {
      state = AsyncData(await _repo.getAll());
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  /// ריצת סנכרון שכבר פועלת, אם יש כזו.
  Future<void>? _syncing;

  /// כמה להמתין לנעילה בפעולה שאסור לה להידלג עליה.
  ///
  /// סנכרון מחזיק אותה לשניות בודדות; התפוגה שלה היא עשר דקות, ולכן המתנה
  /// כזו אינה יכולה להיתקע.
  static const Duration _lockWait = Duration(seconds: 15);

  /// כל עבודת ההתראות: אתחול, השלמת תזכורות שהוחמצו, ותזמון מחדש.
  ///
  /// אינה חוסמת את ה-UI ואינה מפילה אותו – התזמון אינו דחוף לרגע, וכשל בו
  /// מדווח דרך באנר ההרשאות ולא דרך מסך שגיאה.
  ///
  /// **ריצה אחת בכל רגע.** המסך הראשי קורא לכאן פעמיים בפתיחה – אחרי הציור
  /// הראשון, ושוב מ-didChangeAppLifecycleState כשהמצב הופך ל-resumed – ומאז
  /// שהעבודה הזו אינה מומתנת, שתי הקריאות רצות במקביל. שתיהן קוראות את אותו
  /// lastNotifiedAt מהמסד, שתיהן מסיקות שהתזכורת הוחמצה, ושתיהן מציגות
  /// אותה. זו ההתראה הכפולה. קריאה שנייה מצטרפת לריצה הקיימת במקום לפתוח
  /// עוד אחת.
  Future<void> syncNotifications() {
    return _syncing ??= _syncNotifications().whenComplete(() {
      _syncing = null;
    });
  }

  Future<void> _syncNotifications() async {
    try {
      // אותו רצף בדיוק שרץ בעבודה השבועית ברקע – ראה syncReminders.
      await syncReminders(_repo, _notifications);
      // הרשימה נטענת מחדש כי שני השלבים עדכנו את lastNotifiedAt.
      state = AsyncData(await _repo.getAll());
    } catch (_) {
      // הרשימה כבר מוצגת; אין מה להחליף אותה במסך שגיאה.
    }
  }

  /// טוען ומסנכרן, שניהם מוגמרים. משמש בייבוא ובבדיקות שדורשות ודאות.
  Future<void> loadAndReschedule() async {
    await load();
    await syncNotifications();
  }

  Future<void> addEvent(Event event) async {
    final id = await _repo.insert(event);
    // הרשימה מתרעננת לפני התזמון, כדי שהמסך ייסגר מיד. תזמון אירוע עולה
    // עשרות קריאות פלטפורמה, והמתנה לו כאן הקפיאה את כפתור השמירה.
    await _refresh();
    unawaited(_scheduleAndRecord(event.copyWith(id: id)));
  }

  Future<void> updateEvent(Event event) async {
    await _repo.update(event);
    await _refresh();
    // כל שינוי מחייב חישוב מחדש של ההתראה – ברקע, מאותה סיבה.
    unawaited(_scheduleAndRecord(event));
  }

  /// מתזמן אירוע בודד ורושם את המועד הקרוב שטופל.
  ///
  /// תחת הנעילה, כמו כל נגיעה במאגר ההתראות – ראה withSyncLock. **ממתין**
  /// ואינו מדלג: הוספה או עריכה שלא תוזמנה היא תזכורת שלא תגיע, וסנכרון
  /// שמחזיק את הנעילה משחרר אותה תוך שניות.
  Future<void> _scheduleAndRecord(Event event) async {
    try {
      await withSyncLock(_repo, 'edit', waitFor: _lockWait, () async {
        // הרשימה כולה נמסרת כדי שהמכסה תיגזר מולה: לאנדרואיד יש תקרת
        // אזעקות לכל אפליקציה, וחריגה ממנה מפילה את התזמון כולו.
        final nearest = await _notifications.scheduleForEvent(
          event,
          among: state.valueOrNull ?? const [],
        );
        if (nearest == null || event.lastNotifiedAt == nearest) return;
        await _repo.update(event.copyWith(lastNotifiedAt: nearest));
        await _refresh();
      });
    } catch (_) {
      // רץ ברקע: הרשימה כבר מוצגת ואין מה להחליף אותה במסך שגיאה.
    }
  }

  /// שומר דחייה שהמשתמש ביקש מתוך ההתראה.
  ///
  /// בלי השמירה הדחייה קיימת רק באזעקה עצמה: היא לא מופיעה ברשימה, והתזמון
  /// מחדש הבא מחזיר את המועד המקורי ומוחק אותה בשקט.
  ///
  /// lastNotifiedAt מתעדכן יחד איתה, כי המועד הזה הוא מעתה "התזכורת הקרובה
  /// שטופלה" – אחרת מנגנון ההשלמה היה רואה בה החמצה.
  Future<void> recordPostponement(int eventId, DateTime at) async {
    final list = state.valueOrNull ?? await _repo.getAll();
    for (final m in list) {
      if (m.id != eventId) continue;
      await _repo.update(
        m.copyWith(postponedReminderAt: at, lastNotifiedAt: at),
      );
      await _refresh();
      return;
    }
  }

  /// משנה את סוג האירוע.
  ///
  /// **מתזמן מחדש, בשונה מגרסת האזכרות של המסך הזה.** שם הקטגוריה הייתה
  /// תווית ויזואלית בלבד, וביטול ותזמון מחדש בגללה היו עבודה מיותרת על
  /// מאגר ההתראות. כאן הסוג הוא חלק מהתוכן שנצרב בהתראה – הכותרת
  /// ("🎂 יום הולדת") והפתיח ("יום ההולדת של דנה") נגזרים ממנו – ולכן שינוי
  /// שלא יתזמן מחדש היה משאיר התראות שמכריזות על הסוג הקודם עד שהאירוע
  /// ייערך מסיבה אחרת. rescheduleAll לבדו אינו מספיק כאן: הוא מדלג על
  /// אירוע שהתור שלו מלא, וספירת המופעים אינה משתנה.
  Future<void> setKind(Event event, EventKind kind) async {
    if (event.kind == kind) return;
    await updateEvent(event.copyWith(kind: kind));
  }

  /// מכבה או מפעיל תזכורות לפי מזהה, ומחזיר את השם או null אם אין כזה.
  ///
  /// נופל חזרה למסד כשהרשימה עדיין לא נטענה. זה קורה בדיוק בנתיב שבשבילו
  /// הפונקציה קיימת: פתיחה קרה מלחיצה על "דחיית תזכורת", שבה הדיאלוג עולה
  /// מיד אחרי הציור הראשון בעוד הטעינה עוד באוויר – ואז המסך היה מודיע
  /// "האירוע לא נמצא" על אירוע שקיים.
  Future<String?> setEnabledById(int eventId, bool enabled) async {
    final list = state.valueOrNull ?? await _repo.getAll();
    for (final m in list) {
      if (m.id != eventId) continue;
      await updateEvent(m.copyWith(enabled: enabled));
      return m.name;
    }
    return null;
  }

  Future<void> deleteEvent(Event event) async {
    if (event.id == null) return;
    await _repo.delete(event.id!);
    await _refresh();
    // ביטול עולה קריאה לכל התראה מתוזמנת – ברקע, כמו התזמון, ותחת אותה
    // נעילה: גם ביטול קורא-משנה-כותב את מאגר ההתראות כולו.
    unawaited(withSyncLock(_repo, 'delete', waitFor: _lockWait,
        () => _notifications.cancelForEvent(event.id!)));
  }

  /// מפעיל/מכבה התראה של אירוע קיים.
  Future<void> toggleEnabled(Event event, bool enabled) async {
    final updated = event.copyWith(enabled: enabled);
    await updateEvent(updated);
  }

  /// מה ייבוא במצב הוספה יעשה, בלי לגעת בנתונים.
  Future<MergePlan> planMerge(List<Event> events) =>
      _repo.planMerge(events);

  /// מבצע את התוכנית, אחרי שהוכרעו המקרים הדומים.
  ///
  /// [sameAs] הם הזוגות שהמשתמש אישר כאותו אדם: הרשומה הקיימת נשמרת ורק
  /// שדות ריקים בה מתמלאים מהקובץ, כך שהפעולה אינה יכולה לאבד מידע.
  ///
  /// המסלול הבטוח מבין השניים: שום דבר קיים אינו נמחק.
  Future<({int added, int merged, int skipped})> applyMerge({
    required List<Event> toAdd,
    required List<MergeCandidate> sameAs,
    int skipped = 0,
  }) async {
    for (final pair in sameAs) {
      final filled = pair.existing.filledFrom(pair.incoming);
      if (filled.toMap().toString() == pair.existing.toMap().toString()) {
        continue; // לא היה מה להשלים
      }
      await _repo.update(filled);
    }

    final result = toAdd.isEmpty
        ? (added: 0, skipped: 0)
        : await _repo.mergeAll(toAdd);

    if (result.added > 0 || sameAs.isNotEmpty) {
      await syncReminders(_repo, _notifications,
          owner: 'import', waitForLock: _lockWait);
    }
    state = AsyncData(await _repo.getAll());

    return (
      added: result.added,
      merged: sameAs.length,
      skipped: skipped + result.skipped,
    );
  }

  /// מחליף את כל הנתונים (ייבוא מ-JSON) ומתזמן מחדש.
  ///
  /// אותו רצף של הסנכרון הרגיל: אחרי ייבוא ייתכן שמועד של אירוע כבר חלף,
  /// והשלמה היא בדיוק מה שנדרש שם.
  Future<void> importEvents(List<Event> events) async {
    await _repo.replaceAll(events);

    // אין כאן cancelAll: replaceAll מוחק ומכניס מחדש, כך שהמזהים משתנים
    // וההתראות הישנות הופכות ליתומות – ו-rescheduleAll סוחף אותן ממילא.
    // ביטול מוקדם היה פותח חלון שבו הכול מבוטל ודבר עוד לא תוזמן.
    //
    // וממתינים לנעילה: זה הקורא היחיד שאסור לו לדלג, כי אחרי "יובאו N
    // אירועים" המשתמש מאמין שהעניין סגור.
    await syncReminders(_repo, _notifications,
        owner: 'import', waitForLock: const Duration(seconds: 15));
    state = AsyncData(await _repo.getAll());
  }
}

final eventListProvider =
    AsyncNotifierProvider<EventNotifier, List<Event>>(
  EventNotifier.new,
);
