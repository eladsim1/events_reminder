import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/hebrew_date.dart';
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

/// בקשה לבחור מחדש את מועד התזכורת, שנולדה מלחיצה על "דחיית תזכורת".
///
/// נושאת את גוף ההתראה כי היא נכתבת מחדש עם אותו טקסט, ואת תאריך האזכרה כי
/// בלעדיו אי אפשר לחשב "כך וכך ימים לפני".
class ReminderChoiceRequest {
  final int notificationId;
  final DateTime memorialDate;
  final String body;

  const ReminderChoiceRequest({
    required this.notificationId,
    required this.memorialDate,
    required this.body,
  });
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

  /// כל המרווחים שאפשר לבחור: רצף מלא מיום האזכרה עצמו ועד
  /// [maxDaysBeforeChoice] ימים לפניה, בלי לדלג על אף מספר.
  ///
  /// אפס הוא בוקר יום האזכרה. בלעדיו התזכורת של יום-לפני נשארת בלי שום
  /// אפשרות – כל השאר כבר חלפו באותו רגע – וגם כשהאזכרה מחר או היום לא נותר
  /// דבר לבחור. הבקשה הייתה "עד יום האזכרה ולא אחרי", ויום האזכרה בכלל זה.
  static final List<int> snoozeChoiceLadder = List<int>.unmodifiable(
      List<int>.generate(maxDaysBeforeChoice + 1, (i) => i));

  /// הפעולה היחידה בהתראה: פותחת את האפליקציה עם הרשימה המלאה.
  ///
  /// אנדרואיד מרנדר שלוש פעולות לכל היותר, ולכן כפתורים מהירים יכלו להציע
  /// רק שלושה מרווחים מתוך רצף שלם – והבחירה שנשארה בחוץ היא בדיוק מה
  /// שביקשו. עדיף מעבר אחד למסך שמציג את הכול.
  static const String snoozeActionId = 'reschedule:more';
  static const String snoozeActionLabel = 'דחיית תזכורת';

  /// קידומת מזהה הפעולה; אחריה מספר הימים שלפני האזכרה.
  static const String rescheduleActionPrefix = 'reschedule:';

  static String rescheduleActionIdFor(int daysBefore) =>
      '$rescheduleActionPrefix$daysBefore';

  /// ממיר מזהה פעולה חזרה למספר ימים, או null אם אינו מוכר.
  static int? daysBeforeFromActionId(String? actionId) {
    if (actionId == null || !actionId.startsWith(rescheduleActionPrefix)) {
      return null;
    }
    final days =
        int.tryParse(actionId.substring(rescheduleActionPrefix.length));
    return snoozeChoiceLadder.contains(days) ? days : null;
  }

  /// רק היחיד והזוגי מנוסחים במילים.
  ///
  /// "שבוע לפני" בין "6 ימים לפני" ל-"8 ימים לפני" שובר את הסריקה של רשימה
  /// רציפה, ולכן שאר המספרים נשארים מספרים.
  static String snoozeChoiceLabel(int daysBefore) => switch (daysBefore) {
        0 => 'ביום האזכרה',
        1 => 'יום לפני',
        2 => 'יומיים לפני',
        _ => '$daysBefore ימים לפני',
      };

  /// האפשרויות שעדיין בעתיד: כאלה שהמועד שלהן מאוחר מ-[notBefore].
  ///
  /// זה מה שמונע בחירה שנוחתת אחרי האזכרה, או לפני רגע זה.
  static List<int> choicesBefore(DateTime? memorialDate, DateTime notBefore) {
    if (memorialDate == null) return const [];
    return [
      for (final d in snoozeChoiceLadder)
        if (DateTime(memorialDate.year, memorialDate.month,
                memorialDate.day - d, HebrewCalendarService.dayBeforeReminderHour)
            .isAfter(notBefore))
          d,
    ];
  }

  /// גרסת ה-payload. **יש להעלות אותה בכל שינוי בתוכן שנצרב בהתראה** –
  /// בטקסט או בכפתורים.
  ///
  /// [rescheduleAll] מזהה לפיה התראות שתוזמנו בגרסה ישנה, ומתזמן אותן
  /// מחדש. בלעדיה שדרוג של האפליקציה לא היה מגיע לעולם למי שכבר בתור:
  /// תוכן ההתראה נצרב בזמן התזמון, והחלון המלא שלה גורם לדילוג.
  static const int payloadVersion = 6;

  /// ה-payload נושא גם את תאריך האזכרה: ה-isolate שמטפל בבחירה מבודד ואינו
  /// יכול לקרוא את מסד הנתונים, ובלי התאריך אין לו מול מה לחשב "ימים לפני".
  static String encodePayload(DateTime? memorialDate, String body) =>
      'v$payloadVersion|${memorialDate?.millisecondsSinceEpoch ?? 0}|$body';

  /// האם ה-payload נכתב בגרסה הנוכחית.
  static bool isCurrentPayload(String? payload) =>
      payload != null && payload.startsWith('v$payloadVersion|');

  /// האם התור של אזכרה מסוימת צריך להיבנות מחדש.
  ///
  /// שוויון ולא "לפחות": התנאי היה `pending >= wanted`, כלומר "יש מספיק,
  /// אין מה לעשות". אבל **יותר** מהנדרש אינו תור מלא – אלה שאריות
  /// מקונפיגורציה קודמת, והדילוג משאיר אותן מתוזמנות לנצח. כך שרדה
  /// סדרת יום-לפני אחרי שהמצב "יום אחד לפני" הפך אותה למיותרת: 42 מתוזמנות
  /// מול 21 נדרשות, ולכן כל פתיחה החליטה שאין מה לתקן – והתזכורת המשיכה
  /// להגיע פעמיים.
  ///
  /// עודף נובע רק משינוי קוד או הגדרה, ולכן התיקון אינו תלוי בסימון גרסה:
  /// האפליקציה מנקה את עצמה גם בלי שאזכור להעלות אותו.
  static bool needsReschedule({
    required int pendingCount,
    required int wantedCount,
    required bool stalePayload,
  }) =>
      stalePayload || pendingCount != wantedCount;

  static ({DateTime? memorialDate, String body})? decodePayload(String? p) {
    if (p == null) return null;

    var rest = p;
    // קידומת הגרסה, אם קיימת. בניות קודמות כתבו payload בלעדיה, וההתראות
    // שלהן עדיין בתור.
    final v = rest.indexOf('|');
    if (v > 0 &&
        rest.startsWith('v') &&
        int.tryParse(rest.substring(1, v)) != null) {
      rest = rest.substring(v + 1);
    }

    final i = rest.indexOf('|');
    if (i < 0) return (memorialDate: null, body: rest);
    final ms = int.tryParse(rest.substring(0, i));
    if (ms == null) return (memorialDate: null, body: rest);
    return (
      memorialDate: ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms),
      body: rest.substring(i + 1),
    );
  }

  /// הגדרות ההתראה. [withSnoozeAction] מוסיף את הכפתור שפותח את הרשימה במסך;
  /// בלעדיו ההתראה יוצאת בלי כפתורים, וזה הנכון כשלא נותר מה לבחור.
  static AndroidNotificationDetails _androidDetails({
    bool withSnoozeAction = false,
  }) =>
      AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@drawable/ic_notification',
        // כפתורים רגילים, ולא רשימת בחירה בתוך פעולה אחת: RemoteInput עם
        // choices ובלי טקסט חופשי אינו מוצג במגירת ההתראות. אנדרואיד פותח
        // את שדה הקלט רק כשמותר קלט חופשי, והצגת הבחירות כשלעצמן תלויה
        // במימוש של יצרן המכשיר. במכשיר עצמו התוצאה הייתה שאין דחייה כלל.
        // פעולה רגילה, לעומת זאת, מוצגת בכל מגירה.
        actions: [
          if (withSnoozeAction)
            const AndroidNotificationAction(
              snoozeActionId,
              snoozeActionLabel,
              // כאן כן פותחים את האפליקציה: הרשימה המלאה לא נכנסת בהתראה.
              showsUserInterface: true,
            ),
        ],
      );

  static NotificationDetails _details({bool withSnoozeAction = false}) =>
      NotificationDetails(
        android: _androidDetails(withSnoozeAction: withSnoozeAction),
        iOS: const DarwinNotificationDetails(),
      );

  /// ההגדרות המתאימות למועד ירי נתון: כפתור בחירה רק כשיש מה לבחור.
  static NotificationDetails _detailsFor(
    DateTime? memorialDate,
    DateTime notBefore,
  ) =>
      _details(withSnoozeAction: choicesBefore(memorialDate, notBefore).isNotEmpty);

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
      onDidReceiveNotificationResponse: _onResponse,
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
    for (var i = 0; i < reminders.length; i++) {
      await _scheduleOne(
        memorial: memorial,
        hebrewDate: hebrewDate,
        when: reminders[i],
        id: memorial.notificationIdForOccurrence(i),
        prefix: 'אזכרתו של',
      );
    }

    // סדרה שנייה: יום לפני האזכרה, בבוקר. טווח מזהים נפרד, אחרת היא
    // הייתה דורסת את הראשית.
    final dayBefore = _calendar.dayBeforeMemorialDates(memorial);
    for (var i = 0; i < dayBefore.length; i++) {
      await _scheduleOne(
        memorial: memorial,
        hebrewDate: hebrewDate,
        when: dayBefore[i],
        id: memorial.notificationIdForDayBefore(i),
        prefix: 'מחר אזכרתו של',
      );
    }
  }

  /// מתזמן התראה אחת, עם טקסט וכפתורי דחייה שמותאמים למופע הספציפי.
  Future<void> _scheduleOne({
    required Memorial memorial,
    required String hebrewDate,
    required DateTime when,
    required int id,
    required String prefix,
  }) async {
    final memorialDate = _calendar.memorialDateForReminder(memorial, when);
    final detail = memorialDate == null
        ? ''
        : ', ${_calendar.describeMemorialForReminder(memorial, when, memorialDate)}';
    final body = '$prefix ${memorial.name} – $hebrewDate$detail';

    await _plugin.zonedSchedule(
      id: id,
      title: 'תזכורת אזכרה',
      body: body,
      // ה-payload נושא את הטקסט כדי שכפתור הדחייה יוכל לשחזר אותו:
      // isolate הרקע אינו יכול לקרוא את מסד הנתונים.
      payload: encodePayload(memorialDate, body),
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      // רק אפשרויות שנוחתות לפני האזכרה ואחרי מועד ההתראה עצמו.
      notificationDetails: _detailsFor(memorialDate, when),
      // מדויק, ו-allowWhileIdle כדי שיירה גם כשהמכשיר במצב Doze.
      // אי-פספוס אינו נשען על מצב התזמון אלא על שתי שכבות נפרדות:
      // המקלט של BOOT_COMPLETED, ו-deliverMissedReminder בפתיחה.
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
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

  /// נקרא כשהמשתמש ביקש את הרשימה המלאה והאפליקציה בחזית.
  ///
  /// המסך הראשי נרשם לכאן. השירות עצמו אינו מציג ממשק – הוא רק מעביר את
  /// הבקשה, כי בחירה מתוך רשימה שייכת ל-UI ולא לשכבת ההתראות.
  void Function(ReminderChoiceRequest request)? onChooseReminder;

  void _onResponse(NotificationResponse response) {
    final request = choiceRequestFrom(response);
    if (request != null) {
      onChooseReminder?.call(request);
      return;
    }
    handleNotificationResponse(response);
  }

  /// הבקשה שגלומה בתגובה, או null אם אין זו לחיצה על "דחיית תזכורת".
  static ReminderChoiceRequest? choiceRequestFrom(NotificationResponse r) {
    if (r.actionId != snoozeActionId) return null;
    final id = r.id;
    final decoded = decodePayload(r.payload);
    final memorialDate = decoded?.memorialDate;
    if (id == null || decoded == null || memorialDate == null) return null;
    return ReminderChoiceRequest(
      notificationId: id,
      memorialDate: memorialDate,
      body: decoded.body,
    );
  }

  /// בקשה שממתינה מפתיחה קרה – האפליקציה לא רצה כשנלחץ הכפתור.
  Future<ReminderChoiceRequest?> pendingChoiceRequest() async {
    await init();
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final response = launch?.notificationResponse;
    return response == null ? null : choiceRequestFrom(response);
  }

  /// מתזמן מחדש לפי בחירת המשתמש במסך. מחזיר האם המועד עדיין בעתיד.
  Future<bool> rescheduleReminder({
    required ReminderChoiceRequest request,
    required int daysBefore,
  }) async {
    await init();
    return rescheduleTo(
      notificationId: request.notificationId,
      memorialDate: request.memorialDate,
      body: request.body,
      daysBefore: daysBefore,
    );
  }

  /// מטפל בלחיצה על כפתור דחייה: מתזמן מחדש למספר הימים שנבחר לפני האזכרה.
  ///
  /// סטטי כדי שיהיה נגיש גם מ-isolate הרקע, שבו אין מופע חי של השירות.
  static Future<void> handleNotificationResponse(
    NotificationResponse response,
  ) async {
    // הקשה רגילה על גוף ההתראה, או פעולה שאינה מוכרת.
    final daysBefore = daysBeforeFromActionId(response.actionId);
    if (daysBefore == null) return;

    final id = response.id;
    final decoded = decodePayload(response.payload);
    final memorialDate = decoded?.memorialDate;
    if (id == null || decoded == null || memorialDate == null) return;

    await rescheduleTo(
      notificationId: id,
      memorialDate: memorialDate,
      body: decoded.body,
      daysBefore: daysBefore,
    );
  }

  /// מתזמן התראה קיימת מחדש ל-[daysBefore] ימים לפני האזכרה.
  ///
  /// סטטי כדי שיהיה נגיש גם מ-isolate הרקע, שבו אין מופע חי של השירות.
  static Future<bool> rescheduleTo({
    required int notificationId,
    required DateTime memorialDate,
    required String body,
    required int daysBefore,
  }) async {
    // ב-isolate הרקע אזורי הזמן אינם מאותחלים – init() לא רץ שם.
    _initTimeZones();

    final when = DateTime(
      memorialDate.year,
      memorialDate.month,
      memorialDate.day - daysBefore,
      HebrewCalendarService.dayBeforeReminderHour,
    );
    // הגנה: מוצעות רק אפשרויות עתידיות, אבל אם המשתמש התמהמה עם ההתראה
    // פתוחה, המועד שנבחר עשוי לחלוף בינתיים.
    if (!when.isAfter(DateTime.now())) return false;

    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.zonedSchedule(
      // אותו מזהה: הבחירה מחליפה את התזכורת ולא מוסיפה אחת נוספת.
      id: notificationId,
      title: 'תזכורת אזכרה',
      body: body,
      // נכתב מחדש ולא מועתק: כך התראה שתוזמנה בגרסה ישנה עולה לנוכחית.
      payload: encodePayload(memorialDate, body),
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      // האפשרויות נבנות מחדש מול המועד החדש, כך שאפשר לשנות שוב.
      notificationDetails: _detailsFor(memorialDate, when),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
    return true;
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

    final now = DateTime.now();
    final memorialDate = _calendar.nextMemorialDate(memorial);
    final hebrewDate = _calendar.formatHebrewDate(memorial);

    // נמדד מ"עכשיו" ולא ממועד התזכורת שחלף: ההתראה מוצגת ברגע זה, ולכן
    // הספירה חייבת לשקף כמה ימים באמת נותרו.
    final detail =
        _calendar.describeMemorialForReminder(memorial, now, memorialDate);
    final body = 'אזכרתו של ${memorial.name} – $hebrewDate, $detail';

    await _plugin.show(
      id: memorial.notificationIdForOccurrence(Memorial.catchUpIndex),
      title: 'תזכורת אזכרה',
      body: body,
      payload: encodePayload(memorialDate, body),
      notificationDetails: _detailsFor(memorialDate, now),
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

    final requests = await _plugin.pendingNotificationRequests();
    final pending = requests.map((p) => p.id).toList();

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
      // נספרות **שתי** הסדרות: הראשית והתזכורת של יום לפני. בלי הסדרה
      // השנייה בחשבון, התור היה נראה מלא והיא לא הייתה מתוזמנת לעולם.
      final upcoming = _calendar.futureReminderDates(m);
      final wanted =
          upcoming.length + _calendar.dayBeforeMemorialDates(m).length;
      // התראה שתוזמנה בגרסת payload ישנה נושאת את הטקסט והכפתורים של
      // אותה גרסה – הם נצרבים בזמן התזמון. בלי הבדיקה הזו, שדרוג שמשנה
      // את ההתראה לא היה מגיע לעולם למי שכבר תוזמן.
      final stale = requests.any((p) =>
          Memorial.ownsNotificationId(p.id, m.id!) &&
          !isCurrentPayload(p.payload));

      if (!needsReschedule(
        pendingCount: existing.length,
        wantedCount: wanted,
        stalePayload: stale,
      )) {
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
