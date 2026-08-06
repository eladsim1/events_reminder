import 'hebrew_date.dart';

/// מודל אזכרה יחיד.
///
/// מייצג נפטר, תאריך פטירה עברי (יום + חודש + סוג אדר), שעת התזכורת,
/// האם ההתראה מופעלת, הערות ותאריך יצירה.
///
/// ההעדפה היא לעבוד עם מחלקה זו ולא עם `Map<String, dynamic>` בכל שכבות
/// האפליקציה מלבד שכבת ה-Database שממירה מ/אל Map.
class Memorial {
  final int? id;
  final String name;

  /// יום עברי בחודש (1–30).
  final int hebrewDay;

  /// אינדקס חודש הבסיס לפי [HebrewMonth] (לאדר תמיד HebrewMonth.adar.index).
  final int hebrewMonth;

  /// סוג אדר – רלוונטי רק כאשר [hebrewMonth] הוא אדר.
  final AdarType adarType;

  final int notificationHour;
  final int notificationMinute;
  final bool enabled;
  final String? notes;
  final DateTime createdAt;

  /// מועד התזכורת האחרון ש**טופל** – כלומר נמסר, או נמסר לאנדרואיד לתזמון.
  ///
  /// חשוב שזה יעודכן גם בתזמון ולא רק במסירה: ל-flutter_local_notifications
  /// אין callback על מסירת התראה (רק על לחיצה), ולכן אין דרך לדעת שההתראה
  /// המתוזמנת נורתה. בלי הרישום בזמן התזמון, כל פתיחה אחרי שההתראה נורתה
  /// הייתה נראית כמו החמצה ומייצרת התראה כפולה.
  final DateTime? lastNotifiedAt;

  /// שם בית העלמין, למשל "ירקון".
  final String? cemetery;

  /// מיקום הקבר בתוך בית העלמין, למשל "גוש ה', חלקה 12, שורה 4".
  final String? plot;

  /// נתיב מקומי לתמונת הנפטר. נשמר בתיקייה הפרטית של האפליקציה, ולכן
  /// **אינו נכלל בגיבוי ה-JSON** ונמחק בהסרת האפליקציה.
  final String? photoPath;

  /// כיצד נגזר מועד ההתראה.
  final ReminderMode reminderMode;

  /// הפרמטר של [reminderMode]: יום בשבוע (1–7 לפי [DateTime.weekday]) עבור
  /// [ReminderMode.weekdayOfPreviousWeek], או מספר ימים עבור
  /// [ReminderMode.fixedDaysBefore].
  final int reminderValue;

  /// ברירת המחדל של האפליקציה: יום שלישי של השבוע שלפני.
  static const int defaultReminderWeekday = DateTime.tuesday;

  const Memorial({
    this.id,
    required this.name,
    required this.hebrewDay,
    required this.hebrewMonth,
    this.adarType = AdarType.none,
    required this.notificationHour,
    required this.notificationMinute,
    this.enabled = true,
    this.notes,
    required this.createdAt,
    this.lastNotifiedAt,
    this.cemetery,
    this.plot,
    this.photoPath,
    this.reminderMode = ReminderMode.weekdayOfPreviousWeek,
    this.reminderValue = defaultReminderWeekday,
  });

  /// הטקסט לניווט: בית העלמין ומיקום הקבר יחד, או null אם אין מה לנווט אליו.
  String? get burialSearchQuery {
    final parts = [cemetery, plot]
        .map((s) => s?.trim())
        .where((s) => s != null && s.isNotEmpty)
        .cast<String>()
        .toList();
    if (parts.isEmpty) return null;
    return parts.join(', ');
  }

  /// החודש הנבחר כפי שמוצג ב-UI (משחזר אדר א'/ב').
  HebrewMonth get selectedMonth =>
      HebrewMonth.fromStorage(hebrewMonth, adarType);

  /// כמה מזהי התראה שמורים לכל אזכרה – מופע אחד לכל שנה מתוזמנת.
  static const int notificationIdsPerMemorial = 100;

  /// מזהה יציב להתראה (int) – נגזר מ-id.
  ///
  /// לכל אזכרה שמור טווח רציף של [notificationIdsPerMemorial] מזהים, כדי
  /// שאפשר יהיה לתזמן מופע נפרד לכל שנה ולבטל את כולם יחד.
  int get notificationId => notificationIdForOccurrence(0);

  /// המזהה של המופע ה-[index] (0 = הקרוב ביותר).
  int notificationIdForOccurrence(int index) =>
      notificationIdBase(id ?? 0) + index;

  /// תחילת טווח המזהים השמור לאזכרה עם המזהה [memorialId].
  static int notificationIdBase(int memorialId) =>
      memorialId * notificationIdsPerMemorial;

  /// האם [notificationId] שייך לטווח של האזכרה [memorialId].
  ///
  /// קריטי לנכונות הביטול: טעות כאן תבטל התראות של אזכרה אחרת.
  static bool ownsNotificationId(int notificationId, int memorialId) {
    final base = notificationIdBase(memorialId);
    return notificationId >= base &&
        notificationId < base + notificationIdsPerMemorial;
  }

  Memorial copyWith({
    int? id,
    String? name,
    int? hebrewDay,
    int? hebrewMonth,
    AdarType? adarType,
    int? notificationHour,
    int? notificationMinute,
    bool? enabled,
    String? notes,
    DateTime? createdAt,
    bool clearNotes = false,
    DateTime? lastNotifiedAt,
    String? cemetery,
    String? plot,
    String? photoPath,
    bool clearPhoto = false,
    ReminderMode? reminderMode,
    int? reminderValue,
  }) {
    return Memorial(
      id: id ?? this.id,
      name: name ?? this.name,
      hebrewDay: hebrewDay ?? this.hebrewDay,
      hebrewMonth: hebrewMonth ?? this.hebrewMonth,
      adarType: adarType ?? this.adarType,
      notificationHour: notificationHour ?? this.notificationHour,
      notificationMinute: notificationMinute ?? this.notificationMinute,
      enabled: enabled ?? this.enabled,
      notes: clearNotes ? null : (notes ?? this.notes),
      createdAt: createdAt ?? this.createdAt,
      lastNotifiedAt: lastNotifiedAt ?? this.lastNotifiedAt,
      cemetery: cemetery ?? this.cemetery,
      plot: plot ?? this.plot,
      photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
      reminderMode: reminderMode ?? this.reminderMode,
      reminderValue: reminderValue ?? this.reminderValue,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'hebrew_day': hebrewDay,
      'hebrew_month': hebrewMonth,
      'adar_type': adarType.dbValue,
      'notification_hour': notificationHour,
      'notification_minute': notificationMinute,
      'enabled': enabled ? 1 : 0,
      'notes': notes,
      'created_at': createdAt.toIso8601String(),
      'last_notified_at': lastNotifiedAt?.toIso8601String(),
      'cemetery': cemetery,
      'plot': plot,
      'photo_path': photoPath,
      'reminder_mode': reminderMode.dbValue,
      'reminder_value': reminderValue,
    };
  }

  factory Memorial.fromMap(Map<String, dynamic> map) {
    return Memorial(
      id: map['id'] as int?,
      name: map['name'] as String,
      hebrewDay: map['hebrew_day'] as int,
      hebrewMonth: map['hebrew_month'] as int,
      adarType: AdarType.fromDb(map['adar_type'] as String?),
      notificationHour: map['notification_hour'] as int,
      notificationMinute: map['notification_minute'] as int,
      enabled: (map['enabled'] as int) == 1,
      notes: map['notes'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      // חסר בגיבויים שנוצרו לפני גרסה 2 של הסכימה.
      lastNotifiedAt: switch (map['last_notified_at']) {
        final String s when s.isNotEmpty => DateTime.parse(s),
        _ => null,
      },
      cemetery: map['cemetery'] as String?,
      plot: map['plot'] as String?,
      photoPath: map['photo_path'] as String?,
      // חסרים בגיבויים שנוצרו לפני גרסה 3 של הסכימה.
      reminderMode: ReminderMode.fromDb(map['reminder_mode'] as String?),
      reminderValue:
          (map['reminder_value'] as int?) ?? defaultReminderWeekday,
    );
  }

  /// ייצוא ל-JSON (עבור גיבוי/שחזור).
  Map<String, dynamic> toJson() => toMap();

  factory Memorial.fromJson(Map<String, dynamic> json) =>
      Memorial.fromMap(json);
}
