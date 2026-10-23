import 'event_date.dart';

/// מודל אירוע יחיד.
///
/// מייצג יום שנה חוזר – יום הולדת, יום נישואין, יום אירוסין, יום היכרות או
/// אירוע משמח אחר – עם התאריך שבו הוא חל, לפי הלוח העברי או הלועזי, שעת
/// התזכורת, האם ההתראה מופעלת, הערות ותאריך יצירה.
///
/// ההעדפה היא לעבוד עם מחלקה זו ולא עם `Map<String, dynamic>` בכל שכבות
/// האפליקציה מלבד שכבת ה-Database שממירה מ/אל Map.
class Event {
  final int? id;

  /// מה כתוב על הכרטיס: "דנה", "אמא", "אנחנו". טקסט חופשי.
  final String name;

  /// סוג האירוע. קובע את ניסוח התזכורת, את הסימן ואת הצבע.
  final EventKind kind;

  /// לפי איזה לוח האירוע חוזר. עברי הוא ברירת המחדל.
  final CalendarSystem calendar;

  /// היום בחודש. 1–30 בלוח העברי, 1–31 בלועזי.
  final int day;

  /// החודש – **ומשמעותו תלויה ב-[calendar]**.
  ///
  /// בלוח העברי זהו האינדקס של [HebrewMonth] (ולאדר תמיד
  /// `HebrewMonth.adar.index`, כשהסוג נשמר בנפרד ב-[adarType]); בלוח
  /// הלועזי זהו מספר החודש, 1–12.
  ///
  /// שדה אחד לשניהם ולא זוג שדות שרק אחד מהם חי: זוג כזה מזמין את השאלה
  /// "איזה מהם תקף עכשיו" בכל מקום שנוגע בו, ותשובה שגויה עליה היא אירוע
  /// בתאריך הלא נכון.
  final int month;

  /// סוג אדר – רלוונטי רק כאשר [calendar] עברי ו-[month] הוא אדר.
  final AdarType adarType;

  /// השנה שבה הכול התחיל – שנת הלידה, שנת החתונה – או null אם אינה ידועה.
  ///
  /// **נשמרת באותו לוח כמו האירוע עצמו**: שנה עברית לאירוע עברי, ושנה
  /// לועזית ללועזי. אחרת לא היה אפשר לחסר אותה מהמופע הקרוב, וזו כל
  /// תכליתה: [EventCalendarService.anniversaryNumber] גוזר ממנה
  /// "יום הנישואין ה-25".
  ///
  /// אופציונלית במכוון: יש אירועים שמציינים בלי לזכור את השנה, ו"לא ידוע"
  /// חייב להישאר ערך לגיטימי ולא להתמוטט לברירת מחדל שגויה.
  final int? startYear;

  final int notificationHour;
  final int notificationMinute;
  final bool enabled;
  final String? notes;
  final DateTime createdAt;

  /// מועד התזכורת האחרון ש**טופל** – כלומר נמסר, או נמסר לאנדרואיד לתזמון.
  ///
  /// חשוב שיעודכן גם בתזמון ולא רק במסירה: ל-flutter_local_notifications
  /// אין callback על מסירת התראה (רק על לחיצה), ולכן אין דרך לדעת שההתראה
  /// המתוזמנת נורתה. בלי הרישום בזמן התזמון, כל פתיחה אחרי שההתראה נורתה
  /// הייתה נראית כמו החמצה ומייצרת התראה כפולה.
  final DateTime? lastNotifiedAt;

  /// מועד שאליו המשתמש דחה את התזכורת של המופע הקרוב.
  ///
  /// חד-פעמי ולא שינוי כלל: [reminderMode] נשאר כפי שהוא, והמופעים של
  /// השנים הבאות אינם מושפעים. תקף רק כל עוד הוא בעתיד ולפני האירוע –
  /// ראה EventCalendarService.activePostponement – ולכן אין צורך לנקות
  /// אותו, הוא מפסיק לחול מעצמו.
  final DateTime? postponedReminderAt;

  /// תאריך האירוע של המופע שהמשתמש ביקש **לדלג** עליו.
  ///
  /// "לא להזכיר השנה" מתוך ההתראה: המופע הזה לא יתוזמן, וכל השאר
  /// נשארים כפי שהם. זה הבדל מהותי מכיבוי האירוע ([enabled]), שמשתיק
  /// אותו לתמיד ודורש פעולה ידנית כדי לחזור.
  ///
  /// נשמר כתאריך האירוע ולא כמועד התזכורת, כי זה מה שמזהה את המופע
  /// באופן יציב גם אם כלל התזכורת משתנה אחר כך.
  ///
  /// מפסיק לחול מעצמו, כמו [postponedReminderAt]: ברגע שהתאריך חלף, כל
  /// מועד עתידי ממילא מאוחר ממנו ואין מה לסנן.
  final DateTime? skippedEventAt;

  /// כיצד נגזר מועד ההתראה.
  final ReminderMode reminderMode;

  /// הפרמטר של [reminderMode]: יום בשבוע (1–7 לפי [DateTime.weekday]) עבור
  /// [ReminderMode.weekdayOfPreviousWeek], או מספר ימים עבור
  /// [ReminderMode.fixedDaysBefore].
  final int reminderValue;

  /// ברירת המחדל של האפליקציה: יום שלישי של השבוע שלפני.
  static const int defaultReminderWeekday = DateTime.tuesday;

  const Event({
    this.id,
    required this.name,
    this.kind = EventKind.other,
    this.calendar = CalendarSystem.hebrew,
    required this.day,
    required this.month,
    this.adarType = AdarType.none,
    this.startYear,
    required this.notificationHour,
    required this.notificationMinute,
    this.enabled = true,
    this.notes,
    required this.createdAt,
    this.lastNotifiedAt,
    this.postponedReminderAt,
    this.skippedEventAt,
    this.reminderMode = ReminderMode.weekdayOfPreviousWeek,
    this.reminderValue = defaultReminderWeekday,
  });

  /// האם האירוע נספר בלוח העברי.
  bool get isHebrew => calendar == CalendarSystem.hebrew;

  /// האם שם האירוע מכיל את [query].
  ///
  /// חיפוש חלקי וללא תלות ברישיות. שאילתה ריקה מתאימה לכולם, כדי ששדה
  /// חיפוש ריק לא יסתיר את הרשימה.
  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q);
  }

  /// החודש העברי הנבחר כפי שהוא מוצג ב-UI (משחזר אדר א'/ב').
  ///
  /// חסר משמעות לאירוע לועזי, ולכן על הקורא לבדוק [isHebrew] קודם.
  HebrewMonth get hebrewMonth => HebrewMonth.fromStorage(month, adarType);

  /// כמה מזהי התראה שמורים לכל אירוע – מופע אחד לכל שנה מתוזמנת.
  static const int notificationIdsPerEvent = 100;

  /// חלוקת הטווח:
  ///   0..98 – מופעי התזכורת, מהקרוב לרחוק
  ///   99    – השלמה של תזכורת שהוחמצה
  static const int catchUpIndex = notificationIdsPerEvent - 1;

  /// מזהה יציב להתראה (int) – נגזר מ-id.
  ///
  /// לכל אירוע שמור טווח רציף של [notificationIdsPerEvent] מזהים, כדי
  /// שאפשר יהיה לתזמן מופע נפרד לכל שנה ולבטל את כולם יחד.
  int get notificationId => notificationIdForOccurrence(0);

  /// המזהה של המופע ה-[index] (0 = הקרוב ביותר).
  int notificationIdForOccurrence(int index) =>
      notificationIdBase(id ?? 0) + index;

  /// תחילת טווח המזהים השמור לאירוע עם המזהה [eventId].
  static int notificationIdBase(int eventId) =>
      eventId * notificationIdsPerEvent;

  /// מה שמזהה אירוע **בין מכשירים**, לצורך מיזוג.
  ///
  /// המזהה המספרי חסר משמעות מחוץ למכשיר שיצר אותו – ייבוא מקצה מזהים
  /// חדשים – ולכן ההשוואה חייבת להיות על תוכן: שם ותאריך.
  ///
  /// **הלוח הוא חלק מהמפתח.** 14 בחשוון ו-14 בנובמבר הם שני תאריכים שונים
  /// לגמרי, והמפתח חייב להבדיל ביניהם.
  ///
  /// **המחיר, במודע:** שני אירועים באותו שם ובאותו תאריך ייחשבו לאותו
  /// אירוע. רווחים מנורמלים כדי ששוני בהקלדה לא ייצור כפילות.
  String get identityKey {
    final normalised = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    return '$normalised|$dateKey';
  }

  /// התאריך בלבד, בלי השם.
  ///
  /// שני אירועים באותו תאריך הם המקרה שבו כדאי לשאול, לא להכריע – ובעיקר
  /// ביום הולדת, שבו התנגשות בין שני אנשים שונים סבירה לגמרי.
  String get dateKey =>
      '${calendar.dbValue}|$day|$month|${adarType.dbValue}';

  /// עותק שבו שדות ריקים מולאו מ-[other].
  ///
  /// **אינו דורס דבר.** מה שכבר קיים כאן נשאר כפי שהוא, וזה מה שהופך את
  /// "אותו אירוע" לפעולה שאינה יכולה לאבד מידע: היא רק מוסיפה למה שחסר.
  /// השם, התאריך, הלוח והתזכורת של הרשומה הקיימת נשארים שלה.
  ///
  /// הסוג אינו ברשימה בכוונה: לכל אירוע יש סוג, ולכן אין דרך להבדיל בין
  /// "לא נשאל" לבין "נבחר במפורש" – ומיזוג אינו מקום לנחש.
  Event filledFrom(Event other) => copyWith(
        notes: notes ?? other.notes,
        startYear: startYear ?? other.startYear,
      );

  /// האירוע שאליו שייך [notificationId].
  ///
  /// מאפשר למסך למצוא את האירוע מתוך התראה, בלי לשאת את המזהה שלו בנפרד.
  static int eventIdForNotification(int notificationId) =>
      notificationId ~/ notificationIdsPerEvent;

  /// האם [notificationId] שייך לטווח של האירוע [eventId].
  ///
  /// קריטי לנכונות הביטול: טעות כאן תבטל התראות של אירוע אחר.
  static bool ownsNotificationId(int notificationId, int eventId) {
    final base = notificationIdBase(eventId);
    return notificationId >= base &&
        notificationId < base + notificationIdsPerEvent;
  }

  Event copyWith({
    int? id,
    String? name,
    EventKind? kind,
    CalendarSystem? calendar,
    int? day,
    int? month,
    AdarType? adarType,
    int? startYear,
    bool clearStartYear = false,
    int? notificationHour,
    int? notificationMinute,
    bool? enabled,
    String? notes,
    bool clearNotes = false,
    DateTime? createdAt,
    DateTime? lastNotifiedAt,
    DateTime? postponedReminderAt,
    bool clearPostponement = false,
    DateTime? skippedEventAt,
    bool clearSkip = false,
    ReminderMode? reminderMode,
    int? reminderValue,
  }) {
    return Event(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      calendar: calendar ?? this.calendar,
      day: day ?? this.day,
      month: month ?? this.month,
      adarType: adarType ?? this.adarType,
      startYear:
          clearStartYear ? null : (startYear ?? this.startYear),
      notificationHour: notificationHour ?? this.notificationHour,
      notificationMinute: notificationMinute ?? this.notificationMinute,
      enabled: enabled ?? this.enabled,
      notes: clearNotes ? null : (notes ?? this.notes),
      createdAt: createdAt ?? this.createdAt,
      lastNotifiedAt: lastNotifiedAt ?? this.lastNotifiedAt,
      postponedReminderAt: clearPostponement
          ? null
          : (postponedReminderAt ?? this.postponedReminderAt),
      skippedEventAt:
          clearSkip ? null : (skippedEventAt ?? this.skippedEventAt),
      reminderMode: reminderMode ?? this.reminderMode,
      reminderValue: reminderValue ?? this.reminderValue,
    );
  }

  /// האם [other] נופל על אותו תאריך, באותו לוח.
  ///
  /// קיימת בשביל הניקוי בעריכה: דחייה ודילוג מצביעים על מופע מסוים,
  /// ושינוי התאריך הופך אותם לדברים שאינם מצביעים על כלום.
  ///
  /// הלוח הוא חלק מההשוואה ולא פרט טכני: "14 בחשוון" ו-"14 בנובמבר"
  /// הם שני ימים שונים, ולכן החלפת לוח מזיזה את כל המופעים בדיוק כמו
  /// שינוי היום או החודש.
  bool sameEventDate(Event other) =>
      day == other.day &&
      month == other.month &&
      adarType == other.adarType &&
      calendar == other.calendar;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'kind': kind.dbValue,
      'calendar': calendar.dbValue,
      'day': day,
      'month': month,
      'adar_type': adarType.dbValue,
      'start_year': startYear,
      'notification_hour': notificationHour,
      'notification_minute': notificationMinute,
      'enabled': enabled ? 1 : 0,
      'notes': notes,
      'created_at': createdAt.toIso8601String(),
      'last_notified_at': lastNotifiedAt?.toIso8601String(),
      'postponed_reminder_at': postponedReminderAt?.toIso8601String(),
      'skipped_event_at': skippedEventAt?.toIso8601String(),
      'reminder_mode': reminderMode.dbValue,
      'reminder_value': reminderValue,
    };
  }

  factory Event.fromMap(Map<String, dynamic> map) {
    return Event(
      id: map['id'] as int?,
      name: map['name'] as String,
      kind: EventKind.fromDb(map['kind'] as String?),
      calendar: CalendarSystem.fromDb(map['calendar'] as String?),
      day: map['day'] as int,
      month: map['month'] as int,
      adarType: AdarType.fromDb(map['adar_type'] as String?),
      startYear: map['start_year'] as int?,
      notificationHour: map['notification_hour'] as int,
      notificationMinute: map['notification_minute'] as int,
      enabled: (map['enabled'] as int) == 1,
      notes: map['notes'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      // tryParse ולא parse: אלה סימונים פנימיים שהסנכרון הבא מחשב מחדש,
      // וערך פגום בגיבוי אינו סיבה להפיל את הייבוא כולו.
      postponedReminderAt: switch (map['postponed_reminder_at']) {
        final String s when s.isNotEmpty => DateTime.tryParse(s),
        _ => null,
      },
      // חסר בגיבויים שנוצרו לפני גרסה 2 של הסכימה.
      skippedEventAt: switch (map['skipped_event_at']) {
        final String s when s.isNotEmpty => DateTime.tryParse(s),
        _ => null,
      },
      lastNotifiedAt: switch (map['last_notified_at']) {
        final String s when s.isNotEmpty => DateTime.tryParse(s),
        _ => null,
      },
      reminderMode: ReminderMode.fromDb(map['reminder_mode'] as String?),
      reminderValue:
          (map['reminder_value'] as int?) ?? defaultReminderWeekday,
    );
  }

  /// ייצוא ל-JSON (עבור גיבוי/שחזור).
  Map<String, dynamic> toJson() => toMap();

  factory Event.fromJson(Map<String, dynamic> json) => Event.fromMap(json);
}
