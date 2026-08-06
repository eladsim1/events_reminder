import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/memorial.dart';
import 'hebrew_calendar_service.dart';

/// מטפל בלחיצה על פעולת התראה כשהאפליקציה אינה בחזית.
///
/// חייב להיות פונקציה ברמת הקובץ ומסומן ב-vm:entry-point, אחרת אנדרואיד לא
/// יוכל להיכנס אליו ב-isolate הרקע ו-tree shaking יסיר אותו ב-release.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  // ה-isolate הזה מבודד: אין ProviderScope ואין חיבור למסד הנתונים.
  // מספיק לתזמן התראה חדשה, וזו פעולה שהפלאגין תומך בה כאן.
  NotificationService.handleNotificationResponse(response);
}

/// שירות מרכזי לניהול כל ההתראות המקומיות.
///
/// **חשוב:** כל ההתראות מנוהלות כאן בלבד.
/// כל פעולה המשנה אזכרה חייבת לקרוא ל-[scheduleForMemorial] או
/// [cancelForMemorial] דרך שכבת ה-Provider.
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final HebrewCalendarService _calendar;

  bool _initialized = false;

  static const String _channelId = 'azkarot_reminders';
  static const String _channelName = 'תזכורות אזכרה';
  static const String _channelDescription =
      'התראות תזכורת לאזכרות לפי התאריך העברי';

  /// מזהי הפעולות שמופיעות על ההתראה.
  static const String snooze3Days = 'snooze_3d';
  static const String snooze7Days = 'snooze_7d';

  /// כמה ימים דוחה כל פעולה.
  static const Map<String, int> snoozeDays = {
    snooze3Days: 3,
    snooze7Days: 7,
  };

  /// הגדרות אחידות לכל ההתראות – מתוזמנות והשלמות כאחד.
  static const AndroidNotificationDetails _androidDetails =
      AndroidNotificationDetails(
    _channelId,
    _channelName,
    channelDescription: _channelDescription,
    importance: Importance.high,
    priority: Priority.high,
    icon: '@drawable/ic_notification',
    actions: <AndroidNotificationAction>[
      // showsUserInterface=false כדי שהדחייה תטופל ברקע בלי לפתוח את
      // האפליקציה; cancelNotification=true מסלק את ההתראה הנוכחית.
      AndroidNotificationAction(
        snooze3Days,
        'הזכר בעוד 3 ימים',
        showsUserInterface: false,
      ),
      AndroidNotificationAction(
        snooze7Days,
        'הזכר בעוד שבוע',
        showsUserInterface: false,
      ),
    ],
  );

  NotificationService({HebrewCalendarService? calendar})
      : _calendar = calendar ?? HebrewCalendarService();

  /// אתחול פלאגין ההתראות ואזורי הזמן. יש לקרוא פעם אחת ב-Splash.
  Future<void> init() async {
    if (_initialized) return;

    _initTimeZones();

    // לא ic_launcher: אנדרואיד מרנדר אייקון התראה כצללית לפי ערוץ האלפא,
    // ולכן אייקון צבעוני מופיע ככתם לבן. ic_notification הוא לבן על שקוף.
    const androidInit =
        AndroidInitializationSettings('@drawable/ic_notification');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: handleNotificationResponse,
      // נדרש כדי שכפתורי הדחייה יעבדו כשהאפליקציה סגורה – אנדרואיד מריץ
      // אז isolate נפרד, שאין לו את ה-Riverpod ולא את מסד הנתונים.
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    // יצירת ערוץ ההתראות (Android 8+).
    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      ),
    );

    _initialized = true;
  }

  /// מצב ההרשאות שההתראות תלויות בהן.
  ///
  /// [notificationsEnabled] – בלעדיה שום התראה לא תוצג.
  /// [exactAlarmsAllowed] – בלעדיה הפלאגין זורק חריגה והתזמון **נכשל**.
  Future<({bool notificationsEnabled, bool exactAlarmsAllowed})>
      permissionStatus() async {
    await init();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    // בפלטפורמות שאינן אנדרואיד אין מה לבדוק – לא חוסמים את המסך.
    if (androidImpl == null) {
      return (notificationsEnabled: true, exactAlarmsAllowed: true);
    }

    return (
      notificationsEnabled: await androidImpl.areNotificationsEnabled() ?? true,
      exactAlarmsAllowed:
          await androidImpl.canScheduleExactNotifications() ?? true,
    );
  }

  /// פותח את מסך ההגדרות המתאים כדי שהמשתמש יוכל לאשר.
  Future<void> requestMissingPermissions() async {
    await init();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return;

    final status = await permissionStatus();
    if (!status.notificationsEnabled) {
      await androidImpl.requestNotificationsPermission();
    }
    if (!status.exactAlarmsAllowed) {
      await androidImpl.requestExactAlarmsPermission();
    }
  }

  /// מבקש הרשאת התראות (Android 13+ ו-iOS). מחזיר האם ניתנה.
  Future<bool> requestPermissions() async {
    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final iosImpl = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();

    bool granted = true;

    if (androidImpl != null) {
      final result = await androidImpl.requestNotificationsPermission();
      granted = result ?? false;
      // נדרש ב-Android 12+ כדי שההתראה תופיע בשעה המדויקת. אם המשתמש
      // יסרב, אנדרואיד ידחה את ההתראה – אך היא לא תאבד, כי מנגנוני
      // ההשלמה עדיין פועלים.
      await androidImpl.requestExactAlarmsPermission();
    }
    if (iosImpl != null) {
      final result = await iosImpl.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      granted = result ?? false;
    }
    return granted;
  }

  /// מתזמן את כל המופעים העתידיים של אזכרה, ומחזיר את **המועד הקרוב שתוזמן**
  /// (או null אם לא תוזמן דבר).
  ///
  /// הקורא אחראי לשמור את הערך המוחזר ב-lastNotifiedAt. בלי זה, פתיחת
  /// האפליקציה אחרי שההתראה נורתה נראית כמו החמצה ומייצרת התראה כפולה.
  Future<DateTime?> scheduleForMemorial(Memorial memorial) async {
    await init();
    if (memorial.id == null) return null;

    // ביטול ההתראה הקודמת לפני חישוב מחדש.
    await cancelForMemorial(memorial.id!);

    if (!memorial.enabled) return null;

    // מתזמנים את כל המופעים העתידיים בבת אחת ולא רק את הקרוב: zonedSchedule
    // הוא חד-פעמי, ולאנדרואיד אין חזרה שנתית לפי הלוח העברי. בלי זה, אחרי
    // שההתראה נורית לא הייתה מתוזמנת שנה נוספת עד לפתיחת האפליקציה.
    final reminders = _calendar.futureReminderDates(memorial);
    if (reminders.isEmpty) return null;

    final hebrewDate = _calendar.formatHebrewDate(memorial);

    // הפלאגין זורק כשאין הרשאת אזעקות מדויקות. לא מפילים את המסך – המשתמש
    // מקבל על כך אזהרה מתמדת דרך permissionStatus, ראה HomeScreen.
    try {
      await _scheduleAll(memorial, reminders, hebrewDate);
    } on Exception {
      return null;
    }
    return reminders.first;
  }

  Future<void> _scheduleAll(
    Memorial memorial,
    List<DateTime> reminders,
    String hebrewDate,
  ) async {
    final body = 'בשבוע הבא תחול אזכרתו של ${memorial.name} – $hebrewDate';

    for (var i = 0; i < reminders.length; i++) {
      await _plugin.zonedSchedule(
        id: memorial.notificationIdForOccurrence(i),
        title: 'תזכורת אזכרה',
        body: body,
        // ה-payload נושא את הטקסט כדי שכפתור הדחייה יוכל לשחזר אותו:
        // isolate הרקע אינו יכול לקרוא את מסד הנתונים.
        payload: body,
        scheduledDate: tz.TZDateTime.from(reminders[i], tz.local),
        notificationDetails: const NotificationDetails(
          android: _androidDetails,
          iOS: DarwinNotificationDetails(),
        ),
        // מדויק, ו-allowWhileIdle כדי שיירה גם כשהמכשיר במצב Doze.
        // אי-פספוס אינו נשען על מצב התזמון אלא על שתי שכבות נפרדות:
        // המקלט של BOOT_COMPLETED, ו-deliverMissedReminder בפתיחה.
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  /// מאתחל אזורי זמן. בטוח לקריאה חוזרת, וגם מ-isolate הרקע.
  static void _initTimeZones() {
    tz_data.initializeTimeZones();
    // ברירת מחדל: זמן ישראל.
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Jerusalem'));
    } catch (_) {
      // אם לא נמצא – נשארים בברירת המחדל של הספרייה.
    }
  }

  /// מטפל בלחיצה על פעולה בהתראה: דוחה את התזכורת במספר ימים.
  ///
  /// סטטי כדי שיהיה נגיש גם מ-isolate הרקע, שבו אין מופע חי של השירות.
  /// ה-payload נושא את גוף ההתראה, כי ב-isolate אין גישה למסד הנתונים
  /// ואי אפשר לשחזר את האזכרה מהמזהה.
  static Future<void> handleNotificationResponse(
    NotificationResponse response,
  ) async {
    final days = snoozeDays[response.actionId];
    if (days == null) return; // הקשה רגילה על ההתראה – אין מה לעשות

    final id = response.id;
    if (id == null) return;

    // ב-isolate הרקע אזורי הזמן אינם מאותחלים – init() לא רץ שם.
    _initTimeZones();

    final plugin = FlutterLocalNotificationsPlugin();
    final when = tz.TZDateTime.now(tz.local).add(Duration(days: days));

    await plugin.zonedSchedule(
      // אותו מזהה: הדחייה מחליפה את התזכורת ולא מוסיפה אחת נוספת.
      id: id,
      title: 'תזכורת אזכרה',
      body: response.payload ?? 'אזכרה מתקרבת',
      scheduledDate: when,
      notificationDetails: const NotificationDetails(
        android: _androidDetails,
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  /// מציג מיד תזכורת שמועדה חלף וטרם נמסרה.
  ///
  /// מחזיר את המועד שהוצג, או null אם לא היה מה להשלים. הקורא אחראי לשמור
  /// אותו ב-lastNotifiedAt כדי שלא יוצג שוב בפתיחה הבאה.
  Future<DateTime?> deliverMissedReminder(Memorial memorial) async {
    await init();
    if (memorial.id == null || !memorial.enabled) return null;

    final missed = _calendar.missedReminderDate(memorial);
    if (missed == null) return null;

    final hebrewDate = _calendar.formatHebrewDate(memorial);
    final body = 'בשבוע הקרוב תחול אזכרתו של ${memorial.name} – $hebrewDate';

    await _plugin.show(
      id: memorial.notificationIdForOccurrence(
        Memorial.notificationIdsPerMemorial - 1,
      ),
      title: 'תזכורת אזכרה',
      body: body,
      payload: body,
      notificationDetails: const NotificationDetails(
        android: _androidDetails,
        iOS: DarwinNotificationDetails(),
      ),
    );
    return missed;
  }

  /// מבטל את **כל** המופעים המתוזמנים של אזכרה.
  ///
  /// לכל אזכרה שמור טווח רציף של מזהים, ולכן מבטלים את כולו – אחרת מופעים
  /// של שנים הבאות היו נשארים מתוזמנים גם אחרי מחיקה או כיבוי.
  ///
  /// **ביצועים:** מבטלים רק מזהים שקיימים בפועל, ולא סורקים את כל הטווח.
  /// כל cancel חוצה את גשר הפלטפורמה וגורם לפלאגין לכתוב מחדש את כל רשימת
  /// ההתראות המתוזמנות, כך שסריקה עיוורת של 100 מזהים לכל אזכרה הייתה
  /// עולה מאות קריאות בכל חזרה לחזית.
  Future<void> cancelForMemorial(int memorialId) async {
    await init();
    await _cancelIds(await _pendingIdsFor(memorialId));
  }

  /// המזהים המתוזמנים בפועל בטווח של אזכרה נתונה.
  Future<List<int>> _pendingIdsFor(int memorialId) async {
    final pending = await _plugin.pendingNotificationRequests();
    return _idsWithin(pending.map((p) => p.id), memorialId);
  }

  List<int> _idsWithin(Iterable<int> ids, int memorialId) =>
      ids.where((id) => Memorial.ownsNotificationId(id, memorialId)).toList();

  Future<void> _cancelIds(Iterable<int> ids) async {
    for (final id in ids) {
      await _plugin.cancel(id: id);
    }
  }

  /// עובר על כל האזכרות וממלא מחדש את חלון ההתראות.
  /// נקרא ב-Splash ובכל חזרה לחזית.
  ///
  /// **מדלג על אזכרות שהתור שלהן כבר מלא.** התאריכים העבריים דטרמיניסטיים,
  /// ולכן אין טעם לתזמן מחדש מה שכבר תוזמן; בלי הדילוג כל חזרה לחזית הייתה
  /// מבטלת ומתזמנת הכל מחדש, ולפלאגין זו פעולה בעלות ריבועית.
  /// מחזיר, לכל מזהה אזכרה שתוזמנה מחדש, את המועד הקרוב שתוזמן – כדי
  /// שהקורא ישמור אותו ב-lastNotifiedAt וימנע התראה כפולה בפתיחה הבאה.
  Future<Map<int, DateTime>> rescheduleAll(List<Memorial> memorials) async {
    await init();
    final scheduled = <int, DateTime>{};

    final pending = (await _plugin.pendingNotificationRequests())
        .map((p) => p.id)
        .toList();

    // ניקוי שאריות מסכימת המזהים הישנה, שבה המזהה היה ה-id הגולמי של
    // האזכרה ולא בלוק. מזהי SQLite מתחילים ב-1, ולכן בלוק 0 לעולם אינו
    // בשימוש וכל מזהה בתוכו הוא שריד. בלי זה תישלח התראה כפולה אחרי שדרוג.
    await _cancelIds(
      pending.where((id) => id < Memorial.notificationIdsPerMemorial),
    );

    for (final m in memorials) {
      if (m.id == null) continue;

      final existing = _idsWithin(pending, m.id!);

      if (!m.enabled) {
        await _cancelIds(existing);
        continue;
      }

      // ממלאים רק כשהחלון הצטמצם – כלומר מופעים נורו מאז הפעם הקודמת.
      final upcoming = _calendar.futureReminderDates(m);
      if (existing.length >= upcoming.length) {
        // גם כשאין מה לתזמן, רושמים שהמועד הקרוב מטופל – אחרת אחרי שההתראה
        // תיורה, הפתיחה הבאה תראה בה החמצה ותשלח כפולה.
        if (upcoming.isNotEmpty) scheduled[m.id!] = upcoming.first;
        continue;
      }

      final nearest = await scheduleForMemorial(m);
      if (nearest != null) scheduled[m.id!] = nearest;
    }
    return scheduled;
  }

  /// מבטל את כל ההתראות (למשל לפני ייבוא נתונים).
  Future<void> cancelAll() async {
    await init();
    await _plugin.cancelAll();
  }
}
