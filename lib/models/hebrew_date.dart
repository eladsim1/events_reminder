/// מודלים ועזרים לתאריך העברי.
///
/// המחלקה מגדירה את החודשים העבריים, מטפלת בסוגי אדר (אדר / אדר א' / אדר ב')
/// ומספקת המרות לשמות עבריים ולערכי מסד הנתונים.
library;

/// כיצד נגזר מועד ההתראה מתאריך האזכרה.
enum ReminderMode {
  /// יום מסוים בשבוע **שלפני** שבוע האזכרה. ברירת המחדל של האפליקציה
  /// (יום שלישי), ומרווח של 5 עד 11 יום תלוי ביום שבו חלה האזכרה.
  weekdayOfPreviousWeek,

  /// מספר ימים קבוע לפני האזכרה. מרווח עקבי.
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

/// שמות ימי השבוע לתצוגה, באינדקס של [DateTime.weekday] (2 = שלישי).
const Map<int, String> hebrewWeekdayNames = {
  DateTime.sunday: 'ראשון',
  DateTime.monday: 'שני',
  DateTime.tuesday: 'שלישי',
  DateTime.wednesday: 'רביעי',
  DateTime.thursday: 'חמישי',
  DateTime.friday: 'שישי',
};

/// סוג האדר עבור אזכרה.
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
/// הערך [monthNumber] הוא מספר החודש בשיטת kosher_dart (תשרי = 7 ... אלול = 6,
/// אדר = 12, אדר ב' = 13 בשנה מעוברת), אך המרה מדויקת נעשית ב-HebrewCalendarService.
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
