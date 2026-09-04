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

/// כמה התראות מתוזמנות לאזכרה אחת, מפולחות לפי סדרה.
class PendingRow {
  final String name;

  /// כמה התראות מתוזמנות לאזכרה הזו.
  final int scheduled;

  /// מועד התזכורת הקרובה שלה, או null אם אין מתוזמנת.
  final DateTime? nextReminder;

  /// כמה **אמורות** להיות מתוזמנות לפי ההקצאה.
  ///
  /// זו הבדיקה היחידה שיש לה משמעות כאן: השורות ממוינות לפי מועד ולכן הן
  /// תמיד ייראו מסודרות, ומיון אינו יכול לגלות דבר. מה שכן מגלה הוא פער
  /// בין מה שמתוזמן לבין מה שההקצאה קבעה – אזכרה קרובה בלי אזעקה, או
  /// שאריות מקונפיגורציה קודמת.
  final int expected;

  bool get matchesPlan => scheduled == expected;

  /// כמה מהן נצרבו בגרסת תוכן ישנה וממתינות לתזמון מחדש.
  final int stale;

  const PendingRow({
    required this.name,
    required this.scheduled,
    required this.stale,
    required this.expected,
    this.nextReminder,
  });
}

/// מה שמתוזמן בפועל, כולל מה שאינו שייך לאף אזכרה.
class PendingReport {
  final List<PendingRow> rows;
  final int total;

  /// התראות שהבלוק שלהן אינו של אף אזכרה קיימת – שאריות ממחיקה או מסכימה
  /// ישנה. הן ממשיכות לירות עד שנסחפות.
  final int orphans;

  /// כשל התזמון האחרון, אם היה.
  final String? lastError;

  /// האם התור תואם למה שההקצאה קבעה. **זו הבדיקה, לא המיון.**
  bool get inStep =>
      orphans == 0 && rows.every((r) => r.matchesPlan && r.stale == 0);

  /// שלושת התנאים שבלעדיהם תזכורת לא תגיע: שתי ההרשאות, ופטור מניהול
  /// הסוללה – שבלעדיו אנדרואיד רשאי לעצור את האפליקציה ולמחוק את האזעקות
  /// הרשומות שלה, גם כאלה שתוזמנו מזמן.
  final bool notificationsEnabled;
  final bool exactAlarmsAllowed;
  final bool batteryExempt;

  const PendingReport({
    required this.rows,
    required this.total,
    required this.orphans,
    this.lastError,
    this.notificationsEnabled = true,
    this.exactAlarmsAllowed = true,
    this.batteryExempt = true,
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

  /// כשל התזמון האחרון, או null אם התזמון האחרון הצליח.
  ///
  /// מוצג במסך ההגדרות. תפיסה שקטה כאן הפכה "לא תוזמן דבר" ל"ההתראה לא
  /// קופצת", ואי אפשר היה להבדיל ביניהם בלי לחבר את הטלפון.
  String? lastScheduleError;

  /// ציבורי: מסך ההגדרות שואל את המערכת אם דווקא הערוץ הזה חסום.
  static const String channelId = 'azkarot_reminders';
  static const String _channelId = channelId;
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

  /// בחירה מיוחדת ברשימת הדחייה: לכבות את התזכורות לאזכרה הזו.
  ///
  /// ערך שלילי, ולכן לעולם אינו מתנגש במספר ימים אמיתי ואינו עובר את
  /// [daysBeforeFromActionId].
  static const int stopReminding = -1;
  static const String stopRemindingLabel = 'לא להזכיר יותר';

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
                memorialDate.day - d, HebrewCalendarService.rescheduledReminderHour)
            .isAfter(notBefore))
          d,
    ];
  }

  /// כמה אזעקות מותר להחזיק פעילות בו-זמנית.
  ///
  /// **אנדרואיד מגביל אפליקציה ל-500, וחריגה זורקת מתוך AlarmManager.** זה
  /// קטלני כאן: scheduleForMemorial מבטל לפני שהוא מתזמן, ולכן אזכרה שנפלה
  /// על התקרה נשארת בלי אף התראה. עשרים שנה כפול שתי סדרות הן 42 אזעקות
  /// לאזכרה, כלומר התקרה נפרצת כבר סביב תריסר אזכרות.
  static const int maxScheduledAlarms = 400;

  /// חלוקת התקציב: אילו תזכורות יתוזמנו בפועל, ולכל אזכרה כמה מכל סדרה.
  ///
  /// **גלובלית ולא לכל אזכרה בנפרד.** אנדרואיד מגביל את סך האזעקות, לא את
  /// מספר השנים, ולכן חלוקה של "כך וכך שנים לכל אזכרה" מודדת את הדבר הלא
  /// נכון: היא נשברת בשקט סביב 84 אזכרות, ומחזירה בדיוק את הכשל שמותיר
  /// אזכרה בלי אף התראה. כאן נלקחות התזכורות **הקרובות ביותר מכל האזכרות
  /// יחד**, עד מילוי התקציב. עם עשר אזכרות זה שנים של כיסוי, עם שלוש מאות
  /// זה חודשים, ובשום מספר זה לא נשבר – הכיסוי מתקצר בהדרגה.
  ///
  /// המחיר בסקאלה גדולה: אזכרה שמועדה רחוק אינה מתוזמנת עדיין, ולכן צריך
  /// לפתוח את האפליקציה מדי כמה חודשים במקום מדי כמה שנים.
  ///
  /// סטטית ומקבלת את הלוח במפורש, כדי שאפשר יהיה לבדוק אותה בלי להקים את
  /// השירות – הפלאגין שבתוכו אינו ניתן להקמה בבדיקה.
  static Map<int, int> allocateBudget(
    List<Memorial> memorials,
    HebrewCalendarService calendar, {
    int budget = maxScheduledAlarms,
  }) {
    final candidates = <({int memorialId, DateTime when})>[];
    for (final m in memorials) {
      final id = m.id;
      if (id == null || !m.enabled) continue;
      for (final when in calendar.futureReminderDates(m)) {
        candidates.add((memorialId: id, when: when));
      }
    }
    // רשימת כל אזכרה כרונולוגית בפני עצמה, ולכן חיתוך של הרשימה הממוינת
    // הוא תמיד רישא של כל אזכרה – מה שמאפשר לתרגם ספירה למספר מופעים.
    candidates.sort((a, b) => a.when.compareTo(b.when));

    final out = <int, int>{};
    for (final c in candidates.take(budget)) {
      out[c.memorialId] = (out[c.memorialId] ?? 0) + 1;
    }
    return out;
  }

  /// סדר התזמון: לפי מועד התזכורת הקרובה, ולא לפי מזהה.
  ///
  /// החלוקה ב-[allocateBudget] כבר ממוינת לפי תאריך, אבל לולאת התזמון עברה
  /// לפי סדר הרשימה. כל עוד התקציב מתחת לתקרה של אנדרואיד זה לא משנה, כי
  /// שום קריאה אינה נדחית – אבל אם קריאה כן תידחה, מי שיישאר בלי אזעקה
  /// יהיה מי שנמצא במקרה בסוף הרשימה, ולא מי שמועדו הרחוק ביותר. אזכרה
  /// שהתזכורת שלה בעוד שבוע יכולה ליפול רק משום שהמזהה שלה גבוה.
  ///
  /// כאן ההידרדרות הופכת מסודרת: הרחוקות נופלות ראשונות, וזו הבחירה הנכונה.
  ///
  /// אזכרה בלי מועד עתידי כלל יורדת לסוף – אין לה מה לתפוס.
  static List<Memorial> inReminderOrder(
    List<Memorial> memorials,
    HebrewCalendarService calendar,
  ) {
    DateTime? nearest(Memorial m) {
      final dates = calendar.futureReminderDates(m);
      return dates.isEmpty ? null : dates.first;
    }

    final keyed = [
      for (final m in memorials) (memorial: m, next: nearest(m)),
    ];
    keyed.sort((a, b) {
      final an = a.next, bn = b.next;
      if (an == null) return bn == null ? 0 : 1;
      if (bn == null) return -1;
      return an.compareTo(bn);
    });
    return [for (final e in keyed) e.memorial];
  }

  /// השורה הראשונה בלבד של שגיאה.
  ///
  /// ה-toString של חריגת פלטפורמה גורר את כל ה-stack. במסך ההגדרות זה יצא
  /// דף שלם של מסגרות שאי אפשר לקרוא ממנו את הסיבה עצמה.
  static String firstLineOf(Object error, {int max = 200}) {
    final text = error.toString().split('\n').first.trim();
    return text.length <= max ? text : '${text.substring(0, max)}…';
  }

  /// גרסת ה-payload. **יש להעלות אותה בכל שינוי בתוכן שנצרב בהתראה** –
  /// בטקסט או בכפתורים.
  ///
  /// [rescheduleAll] מזהה לפיה התראות שתוזמנו בגרסה ישנה, ומתזמן אותן
  /// מחדש. בלעדיה שדרוג של האפליקציה לא היה מגיע לעולם למי שכבר בתור:
  /// תוכן ההתראה נצרב בזמן התזמון, והחלון המלא שלה גורם לדילוג.
  static const int payloadVersion = 7;

  /// הגרסה שממנה ה-payload נושא גם את מועד הירי.
  ///
  /// נדרש כדי לפענח נכון payload ישן: שם השדה השני הוא כבר גוף ההודעה.
  static const int firesAtPayloadVersion = 7;

  /// ה-payload נושא גם את תאריך האזכרה: ה-isolate שמטפל בבחירה מבודד ואינו
  /// יכול לקרוא את מסד הנתונים, ובלי התאריך אין לו מול מה לחשב "ימים לפני".
  /// [firesAt] הוא מועד הירי המתוכנן. הוא מה שמאפשר לזהות אזעקה שאבדה:
  /// התראה שנורית נמחקת ממאגר הפלאגין, ולכן אחת שעדיין ממתינה אף שמועדה
  /// חלף היא כזו שמעולם לא נורתה.
  static String encodePayload(
    DateTime? memorialDate,
    String body, {
    DateTime? firesAt,
  }) =>
      'v$payloadVersion|${memorialDate?.millisecondsSinceEpoch ?? 0}'
      '|${firesAt?.millisecondsSinceEpoch ?? 0}|$body';

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

  static ({DateTime? memorialDate, DateTime? firesAt, String body})?
      decodePayload(String? p) {
    if (p == null) return null;

    var rest = p;
    var version = 0;
    // קידומת הגרסה, אם קיימת. בניות קודמות כתבו payload בלעדיה, וההתראות
    // שלהן עדיין בתור.
    final v = rest.indexOf('|');
    if (v > 0 && rest.startsWith('v')) {
      final parsed = int.tryParse(rest.substring(1, v));
      if (parsed != null) {
        version = parsed;
        rest = rest.substring(v + 1);
      }
    }

    DateTime? at(int ms) =>
        ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);

    final i = rest.indexOf('|');
    if (i < 0) return (memorialDate: null, firesAt: null, body: rest);
    final ms = int.tryParse(rest.substring(0, i));
    if (ms == null) return (memorialDate: null, firesAt: null, body: rest);
    rest = rest.substring(i + 1);

    // רק מגרסה זו והלאה יש שדה שני. בישנות ממנה מה שאחריו הוא גוף ההודעה.
    DateTime? firesAt;
    if (version >= firesAtPayloadVersion) {
      final j = rest.indexOf('|');
      if (j >= 0) {
        final parsed = int.tryParse(rest.substring(0, j));
        if (parsed != null) {
          firesAt = at(parsed);
          rest = rest.substring(j + 1);
        }
      }
    }

    return (memorialDate: at(ms), firesAt: firesAt, body: rest);
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
  Future<DateTime?> scheduleForMemorial(
    Memorial memorial, {
    List<Memorial> among = const [],
    int? quota,
    List<PendingNotificationRequest>? pending,
  }) async {
    await init();
    final memorialId = memorial.id;
    if (memorialId == null) return null;

    // ביטול ההתראה הקודמת לפני חישוב מחדש.
    await cancelForMemorial(memorialId, pending: pending);

    if (!memorial.enabled) return null;

    // המכסה מגיעה מהקורא כשהוא מתזמן את כולן יחד; אחרת היא מחושבת מול
    // הרשימה כפי שהיא, כדי שהוספה בודדת לא תיקח יותר מחלקה.
    final share = quota ??
        allocateBudget(among.isEmpty ? [memorial] : among, _calendar)[
            memorialId] ??
        0;

    // מתזמנים את כל המופעים העתידיים בבת אחת ולא רק את הקרוב: zonedSchedule
    // הוא חד-פעמי, ולאנדרואיד אין חזרה שנתית לפי הלוח העברי. בלי זה, אחרי
    // שההתראה נורית לא הייתה מתוזמנת שנה נוספת עד לפתיחת האפליקציה.
    final reminders =
        _calendar.futureReminderDates(memorial).take(share).toList();
    if (reminders.isEmpty) return null;

    final hebrewDate = _calendar.formatHebrewDate(memorial);

    // הפלאגין זורק כשאין הרשאת אזעקות מדויקות. לא מפילים את המסך – המשתמש
    // מקבל על כך אזהרה מתמדת דרך permissionStatus, ראה HomeScreen.
    //
    // אבל התפיסה **נרשמת**. היא הייתה שקטה לגמרי, וזה מסוכן במיוחד כאן:
    // cancelForMemorial כבר רץ, כך שכשל בתזמון מותיר את האזכרה בלי אף
    // התראה מתוזמנת – והסימפטום היחיד הוא "ההתראה לא קופצת, רק כשנכנסים
    // לאפליקציה", כי רק ההשלמה נשארת. בלי הרישום אין שום דרך להבדיל בין
    // כשל תזמון לבין כשל מסירה.
    try {
      await _scheduleAll(memorial, reminders, hebrewDate,
          AndroidScheduleMode.exactAllowWhileIdle);
      lastScheduleError = null;
    } on Exception catch (e) {
      // נסיון שני, במצב לא-מדויק. אנדרואיד דוחה תזמון מדויק כשההרשאה
      // חסרה או כשנפרצה תקרת האזעקות, ואז ההתראה מגיעה באיחור של דקות –
      // מה שעדיף בהרבה על לא להגיע כלל. הדיוק וההגעה הן שתי דרישות
      // נפרדות, וכשצריך לוותר, מוותרים על הדיוק.
      try {
        // בלי הצילום הישן: ההתראות שהניסיון הראשון הספיק לכתוב אינן בו,
        // והן היו נשארות בתור לצד החדשות.
        await cancelForMemorial(memorialId);
        await _scheduleAll(memorial, reminders, hebrewDate,
            AndroidScheduleMode.inexactAllowWhileIdle);
        lastScheduleError =
            'תזמון מדויק נדחה, ההתראות תוזמנו כמשוערות — ${firstLineOf(e)}';
      } on Exception catch (fallback) {
        lastScheduleError = 'כשל בתזמון — ${firstLineOf(fallback)}';
        return null;
      }
    }
    return reminders.first;
  }

  Future<void> _scheduleAll(
    Memorial memorial,
    List<DateTime> reminders,
    String hebrewDate,
    AndroidScheduleMode mode,
  ) async {
    for (var i = 0; i < reminders.length; i++) {
      await _scheduleOne(
        memorial: memorial,
        hebrewDate: hebrewDate,
        when: reminders[i],
        id: memorial.notificationIdForOccurrence(i),
        prefix: 'אזכרתו של',
        mode: mode,
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
    required AndroidScheduleMode mode,
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
      payload: encodePayload(memorialDate, body, firesAt: when),
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      // רק אפשרויות שנוחתות לפני האזכרה ואחרי מועד ההתראה עצמו.
      notificationDetails: _detailsFor(memorialDate, when),
      // מדויק כברירת מחדל, ו-allowWhileIdle כדי שיירה גם ב-Doze. אם
      // אנדרואיד דוחה תזמון מדויק, הקורא חוזר לכאן במצב משוער.
      // אי-פספוס אינו נשען על מצב התזמון אלא על שתי שכבות נפרדות:
      // המקלט של BOOT_COMPLETED, ו-deliverMissedReminder בפתיחה.
      androidScheduleMode: mode,
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
  ///
  /// **מחזיר את אותה בקשה בכל קריאה.** פרטי ההשקה אינם מתנקים: אנדרואיד
  /// משיב אותו דבר כל עוד התהליך חי. על הקורא לשאול פעם אחת בלבד – ראה
  /// HomeScreen, ששאל בכל חזרה לחזית והציע שוב ושוב לדחות תזכורת שכבר נדחתה.
  Future<ReminderChoiceRequest?> pendingChoiceRequest() async {
    await init();
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final response = launch?.notificationResponse;
    return response == null ? null : choiceRequestFrom(response);
  }

  /// מתזמן מחדש לפי בחירת המשתמש במסך.
  ///
  /// מחזיר את המועד שנקבע, או null אם הוא כבר חלף. הקורא אחראי לשמור אותו
  /// באזכרה – בלי זה הדחייה חיה רק באזעקה, וה-rescheduleAll הבא מוחק אותה.
  Future<DateTime?> rescheduleReminder({
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
  static Future<DateTime?> rescheduleTo({
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
      HebrewCalendarService.rescheduledReminderHour,
    );
    // הגנה: מוצעות רק אפשרויות עתידיות, אבל אם המשתמש התמהמה עם ההתראה
    // פתוחה, המועד שנבחר עשוי לחלוף בינתיים.
    if (!when.isAfter(DateTime.now())) return null;

    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.zonedSchedule(
      // אותו מזהה: הבחירה מחליפה את התזכורת ולא מוסיפה אחת נוספת.
      id: notificationId,
      title: 'תזכורת אזכרה',
      body: body,
      // נכתב מחדש ולא מועתק: כך התראה שתוזמנה בגרסה ישנה עולה לנוכחית.
      payload: encodePayload(memorialDate, body, firesAt: when),
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      // האפשרויות נבנות מחדש מול המועד החדש, כך שאפשר לשנות שוב.
      notificationDetails: _detailsFor(memorialDate, when),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
    return when;
  }

  /// מציג מיד תזכורת שמועדה חלף וטרם נמסרה.
  ///
  /// מחזיר את המועד שהוצג, או null אם לא היה מה להשלים. הקורא אחראי לשמור
  /// אותו ב-lastNotifiedAt כדי שלא יוצג שוב בפתיחה הבאה.
  Future<Map<int, DateTime>> deliverMissedReminders(
      List<Memorial> memorials) async {
    await init();
    // פעם אחת לכל הסבב: קריאה לכל אזכרה הייתה מאות קריאות פלטפורמה ברשימה
    // גדולה, וכל אחת מהן מחזירה את כל התור.
    final pending = await _plugin.pendingNotificationRequests();

    final delivered = <int, DateTime>{};
    for (final m in memorials) {
      final at = await _deliverMissed(m, pending);
      if (at != null && m.id != null) delivered[m.id!] = at;
    }
    return delivered;
  }

  Future<DateTime?> deliverMissedReminder(Memorial memorial) async {
    await init();
    return _deliverMissed(
        memorial, await _plugin.pendingNotificationRequests());
  }

  /// התראה שמועדה חלף והיא עדיין רשומה כממתינה – כלומר האזעקה שלה אבדה.
  ///
  /// התראה שנורית נמחקת ממאגר הפלאגין. אחת שנשארה בו אחרי שמועדה עבר לא
  /// נורתה מעולם, וזה מה שקורה כשאנדרואיד מוחק את האזעקות: סגירה כפויה, או
  /// מנהל סוללה שהרג את האפליקציה.
  ///
  /// דווקא כאן ההשלמה הרגילה חסומה: lastNotifiedAt נכתב בזמן **התזמון**,
  /// ולכן הוא כבר שווה למועד שאבד ומשכנע את missedReminderDate שהכול טופל.
  static ({int id, DateTime firesAt})? _lostAlarm(
    Memorial memorial,
    List<PendingNotificationRequest> pending,
    DateTime now,
  ) {
    final memorialId = memorial.id;
    if (memorialId == null) return null;

    ({int id, DateTime firesAt})? latest;
    for (final r in pending) {
      if (!Memorial.ownsNotificationId(r.id, memorialId)) continue;
      final at = decodePayload(r.payload)?.firesAt;
      if (at == null || at.isAfter(now)) continue;
      if (latest == null || at.isAfter(latest.firesAt)) {
        latest = (id: r.id, firesAt: at);
      }
    }
    return latest;
  }

  Future<DateTime?> _deliverMissed(
    Memorial memorial,
    List<PendingNotificationRequest> pending,
  ) async {
    if (memorial.id == null || !memorial.enabled) return null;

    final lost = _lostAlarm(memorial, pending, DateTime.now());
    final missed = _calendar.missedReminderDate(memorial) ?? lost?.firesAt;
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

    // מבטלים את מה שאבד אחרי שהוצג, אחרת הוא יזוהה שוב בכל פתיחה: הסימון
    // כבר שווה למועדו, ולכן שום דבר אחר לא ימנע חזרה.
    if (lost != null) await _plugin.cancel(id: lost.id);
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
  /// [pending] הוא צילום מצב שכבר נשלף, כדי לא לשלוף שוב.
  ///
  /// **קריטי בסבב מלא:** בלעדיו rescheduleAll שלף את כל התור מחדש לכל
  /// אזכרה – מאות קריאות פלטפורמה שכל אחת מהן מחזירה מאות רשומות, בעבודה
  /// שאנדרואיד קוצב לה עשר דקות. הצילום תקף כי הבלוקים זרים זה לזה: תזמון
  /// אזכרה אחת אינו משנה את המזהים של אחרת.
  Future<void> cancelForMemorial(
    int memorialId, {
    List<PendingNotificationRequest>? pending,
  }) async {
    await init();
    final snapshot = pending ?? await _plugin.pendingNotificationRequests();
    await _cancelIds(_idsWithin(snapshot.map((p) => p.id), memorialId));
  }

  List<int> _idsWithin(Iterable<int> ids, int memorialId) =>
      ids.where((id) => Memorial.ownsNotificationId(id, memorialId)).toList();

  /// האם [notificationId] הוא שריד: אינו שייך לאף אזכרה קיימת.
  ///
  /// שריד ממשיך לירות לנצח את הטקסט שנצרב בו, ואינו נספר בשום מקום אחר –
  /// לא ב-wanted ולא ב-existing – ולכן אף בדיקה אחרת אינה מגלה אותו.
  static bool isOrphanId(int notificationId, List<Memorial> memorials) =>
      !_belongsToAny(notificationId, memorials);

  /// האם [notificationId] שייך לאחת מהאזכרות הקיימות.
  static bool _belongsToAny(int notificationId, List<Memorial> memorials) {
    for (final m in memorials) {
      final id = m.id;
      if (id != null && Memorial.ownsNotificationId(notificationId, id)) {
        return true;
      }
    }
    return false;
  }

  /// תמונת מצב של מה שמתוזמן בפועל – לאבחון מתוך מסך ההגדרות.
  ///
  /// קיימת כי אין דרך אחרת לדעת מה יושב בתור: הפלאגין מחזיק את ההתראות
  /// אצלו, והשאלה "כמה תזכורות באמת מתוזמנות לאזכרה הזו" הכריעה יותר מבאג
  /// אחד שנוסה לתקן מתוך ניחוש.
  Future<PendingReport> pendingReport(
    List<Memorial> memorials, {
    bool batteryExempt = true,
  }) async {
    await init();
    final requests = await _plugin.pendingNotificationRequests();

    // בסדר התזמון ולא בסדר הרשימה, שהוא לפי מועד יצירה. זו התצוגה היחידה
    // שממנה אפשר לראות מה ההקצאה באמת עשתה, ובלי המיון היא לא מראה זאת.
    final allocation = allocateBudget(memorials, _calendar);
    final rows = <PendingRow>[];
    for (final m in inReminderOrder(memorials, _calendar)) {
      final id = m.id;
      if (id == null) continue;

      var scheduled = 0, stale = 0;
      for (final r in requests) {
        if (!Memorial.ownsNotificationId(r.id, id)) continue;
        scheduled++;
        if (!isCurrentPayload(r.payload)) stale++;
      }
      final upcoming = _calendar.futureReminderDates(m);
      rows.add(PendingRow(
        name: m.name,
        scheduled: scheduled,
        stale: stale,
        expected: m.enabled ? (allocation[id] ?? 0) : 0,
        nextReminder: upcoming.isEmpty ? null : upcoming.first,
      ));
    }

    final permissions = await permissionStatus();
    return PendingReport(
      rows: rows,
      total: requests.length,
      orphans:
          requests.where((r) => !_belongsToAny(r.id, memorials)).length,
      lastError: lastScheduleError,
      notificationsEnabled: permissions.notificationsEnabled,
      exactAlarmsAllowed: permissions.exactAlarmsAllowed,
      batteryExempt: batteryExempt,
    );
  }

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
    final allocation = allocateBudget(memorials, _calendar);

    // סחיפת כל מה שאינו שייך לאזכרה קיימת.
    //
    // שני מקורות לשאריות כאלה, ושניהם יורים לנצח את הטקסט שנצרב בהם פעם:
    // סכימת המזהים הישנה, שבה המזהה היה ה-id הגולמי ולא בלוק (בלוק 0 –
    // מזהי SQLite מתחילים ב-1, ולכן הוא לעולם אינו בשימוש); ומחיקת אזכרה
    // שהביטול שלה לא הספיק לרוץ, כי הוא מתבצע ברקע ואינו מומתן.
    await _cancelIds(pending.where((id) => !_belongsToAny(id, memorials)));

    for (final m in inReminderOrder(memorials, _calendar)) {
      if (m.id == null) continue;

      final existing = _idsWithin(pending, m.id!);

      if (!m.enabled) {
        await _cancelIds(existing);
        continue;
      }

      // ממלאים רק כשהחלון הצטמצם – כלומר מופעים נורו מאז הפעם הקודמת.
      // נספרות **שתי** הסדרות: הראשית והתזכורת של יום לפני. בלי הסדרה
      // השנייה בחשבון, התור היה נראה מלא והיא לא הייתה מתוזמנת לעולם.
      final share = allocation[m.id!] ?? 0;
      final upcoming = _calendar.futureReminderDates(m).take(share).toList();
      final wanted = share;
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

      final nearest =
          await scheduleForMemorial(m, quota: share, pending: requests);
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
