import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memorial.dart';
import '../models/memorial_filter.dart';
import '../repository/memorial_repository.dart';
import '../services/hebrew_calendar_service.dart';
import '../services/navigation_launcher.dart';
import '../services/notification_service.dart';
import '../services/reminder_sync.dart';
import '../services/photo_store.dart';

/// ספקי תשתית (Repository ושירותים).
final memorialRepositoryProvider = Provider<MemorialRepository>((ref) {
  return MemorialRepository();
});

final navigationLauncherProvider = Provider<NavigationLauncher>((ref) {
  return const NavigationLauncher();
});

final photoStoreProvider = Provider<PhotoStore>((ref) {
  return const PhotoStore();
});

final hebrewCalendarServiceProvider =
    Provider<HebrewCalendarService>((ref) {
  return HebrewCalendarService();
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(
    calendar: ref.watch(hebrewCalendarServiceProvider),
  );
});

/// הסינון הנבחר ברשימה.
///
/// מכוון לאיפוס בכל הפעלה: פתיחת האפליקציה עם סינון פעיל מלפני שבוע נראית
/// כאילו האזכרות נעלמו.
final memorialFilterProvider = StateProvider<MemorialFilter>((ref) {
  return MemorialFilter.all;
});

/// שאילתת החיפוש הפעילה. ריק = ללא חיפוש.
final memorialSearchProvider = StateProvider<String>((ref) => '');

/// מצב ההרשאות שבלעדיהן ההתראות פשוט לא יעבדו.
///
/// נחשף כספק נפרד כדי שהמסך הראשי יוכל להזהיר – בלעדיו סירוב הרשאה הוא
/// כשל שקט: האפליקציה נראית תקינה לגמרי ופשוט לעולם לא מתריעה.
final notificationPermissionProvider = FutureProvider<
    ({bool notificationsEnabled, bool exactAlarmsAllowed})>((ref) async {
  return ref.watch(notificationServiceProvider).permissionStatus();
});

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

/// מצב רשימת האזכרות.
///
/// כל המסכים קוראים מכאן ואינם ניגשים ישירות ל-Repository או ל-SQLite.
class MemorialNotifier extends AsyncNotifier<List<Memorial>> {
  MemorialRepository get _repo => ref.read(memorialRepositoryProvider);
  NotificationService get _notifications =>
      ref.read(notificationServiceProvider);

  @override
  Future<List<Memorial>> build() async {
    return _repo.getAll();
  }

  Future<void> _refresh() async {
    state = AsyncData(await _repo.getAll());
  }

  /// טוען את הרשימה בלבד. מהיר – קריאת SQLite אחת.
  ///
  /// מופרד מ-[syncNotifications] במכוון: עבודת התזמון עולה עשרות קריאות
  /// פלטפורמה לכל אזכרה, והפלאגין כותב מחדש את כל רשימת ההתראות בכל
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

  Future<void> addMemorial(Memorial memorial) async {
    final id = await _repo.insert(memorial);
    // הרשימה מתרעננת לפני התזמון, כדי שהמסך ייסגר מיד. תזמון אזכרה עולה
    // עשרות קריאות פלטפורמה, והמתנה לו כאן הקפיאה את כפתור השמירה.
    await _refresh();
    unawaited(_scheduleAndRecord(memorial.copyWith(id: id)));
  }

  Future<void> updateMemorial(Memorial memorial) async {
    await _repo.update(memorial);
    await _refresh();
    // כל שינוי מחייב חישוב מחדש של ההתראה – ברקע, מאותה סיבה.
    unawaited(_scheduleAndRecord(memorial));
  }

  /// מתזמן אזכרה בודדת ורושם את המועד הקרוב שטופל.
  Future<void> _scheduleAndRecord(Memorial memorial) async {
    try {
      // הרשימה כולה נמסרת כדי שהמכסה תיגזר מולה: לאנדרואיד יש תקרת
      // אזעקות לכל אפליקציה, וחריגה ממנה מפילה את התזמון כולו.
      final nearest = await _notifications.scheduleForMemorial(
        memorial,
        among: state.valueOrNull ?? const [],
      );
      if (nearest == null || memorial.lastNotifiedAt == nearest) return;
      await _repo.update(memorial.copyWith(lastNotifiedAt: nearest));
      await _refresh();
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
  Future<void> recordPostponement(int memorialId, DateTime at) async {
    final list = state.valueOrNull ?? await _repo.getAll();
    for (final m in list) {
      if (m.id != memorialId) continue;
      await _repo.update(
        m.copyWith(postponedReminderAt: at, lastNotifiedAt: at),
      );
      await _refresh();
      return;
    }
  }

  Future<void> deleteMemorial(Memorial memorial) async {
    if (memorial.id == null) return;
    await _repo.delete(memorial.id!);
    await _refresh();
    // ביטול עולה קריאה לכל התראה מתוזמנת – ברקע, כמו התזמון.
    unawaited(_notifications.cancelForMemorial(memorial.id!));
  }

  /// מפעיל/מכבה התראה של אזכרה קיימת.
  Future<void> toggleEnabled(Memorial memorial, bool enabled) async {
    final updated = memorial.copyWith(enabled: enabled);
    await updateMemorial(updated);
  }

  /// מחליף את כל הנתונים (ייבוא מ-JSON) ומתזמן מחדש.
  ///
  /// אותו רצף של הסנכרון הרגיל: אחרי ייבוא ייתכן שמועד של אזכרה כבר חלף,
  /// והשלמה היא בדיוק מה שנדרש שם.
  Future<void> importMemorials(List<Memorial> memorials) async {
    await _notifications.cancelAll();
    await _repo.replaceAll(memorials);
    await syncReminders(_repo, _notifications);
    state = AsyncData(await _repo.getAll());
  }
}

final memorialListProvider =
    AsyncNotifierProvider<MemorialNotifier, List<Memorial>>(
  MemorialNotifier.new,
);
