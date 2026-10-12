/// מודלים ועזרים לתאריך של אירוע.
///
/// המחלקה מגדירה את שתי מערכות התאריכים שהאפליקציה מכירה, את החודשים
/// העבריים והלועזיים, מטפלת בסוגי אדר (אדר / אדר א' / אדר ב') ומספקת
/// המרות לשמות עבריים ולערכי מסד הנתונים.
library;

/// לפי איזה לוח האירוע חוזר.
///
/// **עברי הוא ברירת המחדל**, וזו אינה רק בחירה התחלתית: יום שנה עברי נודד
/// בלוח הלועזי ולכן חייב להיפתר מחדש בכל שנה, בעוד שאירוע שהוגדר בלוח
/// הלועזי חוזר באותו יום ובאותו חודש לועזיים – והתזכורת עליו נגזרת מהם.
///
/// הבחירה היא **לכל אירוע בנפרד**: מי שמציין יום נישואין לפי התאריך העברי
/// ויום הולדת לפי הלועזי מחזיק את שניהם באותה רשימה בלי סתירה.
enum CalendarSystem {
  hebrew('עברי'),
  gregorian('לועזי');

  const CalendarSystem(this.label);

  final String label;

  String get dbValue => name;

  /// ערך חסר או לא מוכר חוזר לעברי – ברירת המחדל של האפליקציה.
  static CalendarSystem fromDb(String? value) {
    if (value == null) return CalendarSystem.hebrew;
    return CalendarSystem.values.firstWhere(
      (e) => e.name == value,
      orElse: () => CalendarSystem.hebrew,
    );
  }
}

/// סוג האירוע.
///
/// בשונה מקטגוריה שאפשר שלא לסמן, לאירוע **תמיד** יש סוג: הוא מה שקובע את
/// ניסוח התזכורת ("יום ההולדת של…" מול "יום הנישואין של…"), את הסימן על
/// הכרטיס ואת הצבע. ערך לא מוכר נופל ל-[other] במקום להיכשל.
enum EventKind {
  birthday('יום הולדת', '🎂', 'יום ההולדת'),
  anniversary('יום נישואין', '💍', 'יום הנישואין'),
  engagement('יום אירוסין', '💎', 'יום האירוסין'),
  firstMet('יום היכרות', '💖', 'יום ההיכרות'),
  other('אירוע משמח', '🎉', 'האירוע');

  const EventKind(this.label, this.emoji, this.noun);

  /// שם הקטגוריה, כפי שהוא מופיע בטופס, בשבב ובסינון.
  final String label;

  /// הסימן שמזהה את הסוג במבט אחד.
  ///
  /// אמוג'י ולא אייקון: לשניים מהסוגים כאן אין מקבילה ב-Material Icons
  /// (טבעת, יהלום), והאמוג'י צבעוני מטבעו – וזו אפליקציה שאמורה להיות
  /// צבעונית. המחיר, במודע: הצורה נקבעת בידי יצרן המכשיר.
  final String emoji;

  /// שם האירוע כשם עצם מיודע, לניסוח משפטים: "יום ההולדת של דנה",
  /// "יום הנישואין ה-25".
  final String noun;

  String get dbValue => name;

  static EventKind fromDb(String? value) {
    if (value == null) return EventKind.other;
    return EventKind.values.firstWhere(
      (e) => e.name == value,
      orElse: () => EventKind.other,
    );
  }

  /// "יום ההולדת של דנה" – הפתיח של גוף ההתראה.
  String get reminderPrefix => '$noun של';

  /// כותרת ההתראה: הסימן ושם הסוג.
  ///
  /// הסוג בכותרת ולא רק בגוף, כי במגירת ההתראות רואים קודם את השורה
  /// הראשונה – ו"🎂 יום הולדת" אומר במבט אחד מה מחכה, לפני שקוראים את מי.
  String get notificationTitle => '$emoji $label';

  /// "יום הנישואין ה-25" – כשידועה השנה שבה הכול התחיל.
  String ordinal(int n) => '$noun ה-$n';
}

/// כיצד נגזר מועד ההתראה מתאריך האירוע.
enum ReminderMode {
  /// יום מסוים בשבוע **שלפני** שבוע האירוע. ברירת המחדל של האפליקציה
  /// (יום שלישי), ומרווח של 5 עד 11 יום תלוי ביום שבו חל האירוע.
  ///
  /// נשמע מוזר לתזכורת של יום הולדת, ואינו: מתנה, הזמנת מסעדה או ארגון
  /// הפתעה דורשים כמה ימים. מי שרוצה מרווח קבוע בוחר את המצב השני.
  weekdayOfPreviousWeek,

  /// מספר ימים קבוע לפני האירוע. מרווח עקבי.
  fixedDaysBefore;

  String get dbValue => name;

  static ReminderMode fromDb(String? value) {
    if (value == null) return ReminderMode.weekdayOfPreviousWeek;
    return ReminderMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ReminderMode.weekdayOfPreviousWeek,
    );
  }
}

/// שמות ימי השבוע לתצוגה, באינדקס של [DateTime.weekday].
///
/// כולל שבת: תאריך האירוע יכול ליפול בכל יום. לבחירת יום התזכורת יש
/// להשתמש ב-[reminderWeekdayChoices], שאינו כולל שבת.
const Map<int, String> hebrewWeekdayNames = {
  DateTime.sunday: 'ראשון',
  DateTime.monday: 'שני',
  DateTime.tuesday: 'שלישי',
  DateTime.wednesday: 'רביעי',
  DateTime.thursday: 'חמישי',
  DateTime.friday: 'שישי',
  DateTime.saturday: 'שבת',
};

/// "יום שני" – שם היום לפי מספרו ב-[DateTime.weekday].
///
/// המפה שמעל מחזיקה את השם החשוף, וכל קורא הוסיף לו "יום " בעצמו. כאן זה
/// במקום אחד, ומספר יום שאינו מוכר מחזיר מחרוזת ריקה ולא "יום null".
String hebrewWeekdayName(int weekday) =>
    'יום ${hebrewWeekdayNames[weekday] ?? ''}';

/// "יום שני" – שם היום שבו חל [d].
String hebrewWeekdayLabel(DateTime d) => hebrewWeekdayName(d.weekday);

/// "10/08" – יום וחודש בספרות.
///
/// **בספרות, בשונה מ-[gregorianMonthName]**: זה הפורמט שקוראים לצד שם היום,
/// ושם "10 באוגוסט" היה מאריך את השורה בלי להוסיף דבר. שני הפורמטים חיים זה
/// לצד זה בכוונה, ולכן שמם שונה.
String slashDayMonth(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

/// "10/08/2026".
String slashDate(DateTime d) => '${slashDayMonth(d)}/${d.year}';

/// "יום שני, 10/08/2026" – היום בשבוע והתאריך המלא.
String hebrewDayAndDate(DateTime d) =>
    '${hebrewWeekdayLabel(d)}, ${slashDate(d)}';

/// הימים שניתן לבחור כמועד תזכורת. שבת אינה ברשימה.
const List<int> reminderWeekdayChoices = [
  DateTime.sunday,
  DateTime.monday,
  DateTime.tuesday,
  DateTime.wednesday,
  DateTime.thursday,
  DateTime.friday,
];

/// המרווח המרבי, בימים, שאפשר לבקש לפני האירוע.
const int maxDaysBeforeChoice = 30;

/// כל המרווחים שניתן לבחור במצב "מספר ימים לפני" – רצף מלא, בלי דילוגים.
///
/// היה כאן סולם מדלג (1,2,3,5,7,10,…) והוא הסתיר מספרים שאנשים באמת רוצים:
/// ארבעה ימים, שישה, תשעה. אין סיבה לכפות עיגול על בחירה של המשתמש.
final List<int> daysBeforeChoices = List<int>.unmodifiable(
    List<int>.generate(maxDaysBeforeChoice, (i) => i + 1));

/// ניסוח מרווח בעברית. יחיד וזוגי אינם "1 ימים" ו-"2 ימים".
String daysBeforeLabel(int days) => switch (days) {
      1 => 'יום אחד',
      2 => 'יומיים',
      _ => '$days ימים',
    };

/// סוג האדר עבור אירוע עברי.
///
/// [none] – החודש אינו אדר.
/// [adar] – "אדר" סתמי (נקבע בעת הוספה בשנה פשוטה, או ברירת מחדל).
/// [adarA] – אדר א' (רלוונטי רק בשנה מעוברת).
/// [adarB] – אדר ב' (רלוונטי רק בשנה מעוברת).
enum AdarType {
  none,
  adar,
  adarA,
  adarB;

  String get dbValue => name;

  static AdarType fromDb(String? value) {
    if (value == null) return AdarType.none;
    return AdarType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AdarType.none,
    );
  }
}

/// חודש עברי כפי שהמשתמש בוחר אותו ב-UI.
///
/// שים לב: ה-UI מציג רשימה קבועה של חודשים (כולל אדר, אדר א', אדר ב').
/// ההמרה למספור של kosher_dart (תשרי = 7 … אלול = 6, אדר = 12, אדר ב' = 13
/// בשנה מעוברת) נעשית ב-EventCalendarService בלבד.
enum HebrewMonth {
  tishrei('תשרי'),
  cheshvan('חשוון'),
  kislev('כסלו'),
  tevet('טבת'),
  shevat('שבט'),
  adar('אדר'),
  adarA("אדר א'"),
  adarB("אדר ב'"),
  nisan('ניסן'),
  iyar('אייר'),
  sivan('סיוון'),
  tammuz('תמוז'),
  av('אב'),
  elul('אלול');

  final String hebrewName;
  const HebrewMonth(this.hebrewName);

  /// האם החודש הוא אחד מחודשי האדר.
  bool get isAdar =>
      this == HebrewMonth.adar ||
      this == HebrewMonth.adarA ||
      this == HebrewMonth.adarB;

  /// ממיר את בחירת המשתמש לזוג (חודש בסיס, סוג אדר) לשמירה במסד הנתונים.
  ({int baseMonth, AdarType adarType}) toStorage() {
    switch (this) {
      case HebrewMonth.adar:
        return (baseMonth: HebrewMonth.adar.index, adarType: AdarType.adar);
      case HebrewMonth.adarA:
        return (baseMonth: HebrewMonth.adar.index, adarType: AdarType.adarA);
      case HebrewMonth.adarB:
        return (baseMonth: HebrewMonth.adar.index, adarType: AdarType.adarB);
      default:
        return (baseMonth: index, adarType: AdarType.none);
    }
  }

  /// בונה מחדש את החודש שנבחר מתוך ערכי מסד הנתונים.
  static HebrewMonth fromStorage(int monthIndex, AdarType adarType) {
    if (monthIndex == HebrewMonth.adar.index) {
      switch (adarType) {
        case AdarType.adarA:
          return HebrewMonth.adarA;
        case AdarType.adarB:
          return HebrewMonth.adarB;
        default:
          return HebrewMonth.adar;
      }
    }
    // עבור מדד שאינו אדר – מחזירים לפי האינדקס, אך מדלגים על adarA/adarB
    return HebrewMonth.values[monthIndex];
  }
}

/// שמות החודשים הלועזיים בעברית, לפי מספר החודש (1–12).
///
/// רשימה ולא enum, בשונה מהחודש העברי: לחודש לועזי אין סוגים (אין אדר א'
/// ואדר ב'), ומספר החודש עצמו הוא מה שנשמר – כך שאין מה לעטוף.
const List<String> gregorianMonthNames = [
  'ינואר',
  'פברואר',
  'מרץ',
  'אפריל',
  'מאי',
  'יוני',
  'יולי',
  'אוגוסט',
  'ספטמבר',
  'אוקטובר',
  'נובמבר',
  'דצמבר',
];

/// שם החודש הלועזי, או מחרוזת ריקה למספר שאינו 1–12.
String gregorianMonthName(int month) =>
    month >= 1 && month <= 12 ? gregorianMonthNames[month - 1] : '';

/// המרת מספר יום (1..30) לגימטריה עברית (א', ב', ... ל').
class HebrewNumerals {
  static const _ones = ['', 'א', 'ב', 'ג', 'ד', 'ה', 'ו', 'ז', 'ח', 'ט'];
  static const _tens = ['', 'י', 'כ', 'ל'];

  /// מחזיר ייצוג עברי ליום בחודש (1–30) עם גרש/גרשיים.
  static String dayToHebrew(int day) {
    if (day < 1 || day > 30) return day.toString();

    final tens = day ~/ 10;
    final ones = day % 10;

    // מקרים מיוחדים: ט"ו ו-ט"ז כדי לא לכתוב שם ה'.
    if (day == 15) return 'ט"ו';
    if (day == 16) return 'ט"ז';

    final buffer = StringBuffer();
    if (tens > 0) buffer.write(_tens[tens]);
    if (ones > 0) buffer.write(_ones[ones]);

    final letters = buffer.toString();
    if (letters.length == 1) return '$letters\'';
    if (letters.length >= 2) {
      return '${letters.substring(0, letters.length - 1)}"${letters.substring(letters.length - 1)}';
    }
    return letters;
  }
}
