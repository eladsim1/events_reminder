import 'package:kosher_dart/kosher_dart.dart';

import '../models/hebrew_date.dart';
import '../models/memorial.dart';

/// שירות מרכזי לכל חישובי התאריכים העבריים והלועזיים.
///
/// **חשוב:** כל לוגיקת התאריכים באפליקציה מרוכזת כאן בלבד.
/// שכבת ה-UI אינה מבצעת חישובי תאריכים ישירות.
///
/// עוטף את kosher_dart ומספק API נקי לשאר האפליקציה.
///
/// הערה על מספרי חודשים: אנו משתמשים בערכים המספריים של kosher_dart/KosherJava
/// ישירות (ולא בקבועים בעלי שם, שכן שמם משתנה בין גרסאות/forks של החבילה –
/// NISSAN מול NISAN וכד'). המספור:
///   ניסן=1, אייר=2, סיוון=3, תמוז=4, אב=5, אלול=6,
///   תשרי=7, חשוון=8, כסלו=9, טבת=10, שבט=11,
///   אדר=12, אדר ב'=13 (רק בשנה מעוברת).
class HebrewCalendarService {
  /// מקור הזמן הנוכחי. ברירת המחדל היא שעון המערכת; ניתן להזרקה כדי
  /// שתצוגות התלויות ב"היום" (למשל מספר הימים עד התזכורת) יהיו ניתנות
  /// לבדיקה דטרמיניסטית.
  final DateTime Function() _now;

  HebrewCalendarService({DateTime Function()? now}) : _now = now ?? DateTime.now;

  // מספרי החודשים לפי kosher_dart (זהים ל-KosherJava).
  static const int _nissan = 1;
  static const int _iyar = 2;
  static const int _sivan = 3;
  static const int _tammuz = 4;
  static const int _av = 5;
  static const int _elul = 6;
  static const int _tishrei = 7;
  static const int _cheshvan = 8;
  static const int _kislev = 9;
  static const int _teves = 10;
  static const int _shevat = 11;
  static const int _adar = 12;
  static const int _adarII = 13;

  /// ממיר חודש שאינו אדר למספר החודש בשיטת kosher_dart.
  int _kosherMonth(HebrewMonth month) {
    switch (month) {
      case HebrewMonth.tishrei:
        return _tishrei;
      case HebrewMonth.cheshvan:
        return _cheshvan;
      case HebrewMonth.kislev:
        return _kislev;
      case HebrewMonth.tevet:
        return _teves;
      case HebrewMonth.shevat:
        return _shevat;
      case HebrewMonth.nisan:
        return _nissan;
      case HebrewMonth.iyar:
        return _iyar;
      case HebrewMonth.sivan:
        return _sivan;
      case HebrewMonth.tammuz:
        return _tammuz;
      case HebrewMonth.av:
        return _av;
      case HebrewMonth.elul:
        return _elul;
      // חודשי אדר מטופלים דרך _resolveAdarMonth.
      case HebrewMonth.adar:
      case HebrewMonth.adarA:
      case HebrewMonth.adarB:
        return _adar;
    }
  }

  /// מטפל בהמרת אדר לפי סוג האדר עבור שנה קונקרטית.
  ///
  /// כאשר אזכרה נשמרה כ"אדר" סתמי (בשנה פשוטה) והיא מחושבת לשנה מעוברת,
  /// המנהג הרווח הוא לציין את יום השנה באדר ב'. לכן:
  ///  - adar   -> בשנה מעוברת נבחר אדר ב' (13); בשנה פשוטה אדר (12).
  ///  - adarA  -> אדר א' (12).
  ///  - adarB  -> אדר ב' (13) בשנה מעוברת; אדר (12) בשנה פשוטה.
  int _resolveAdarMonth(int hebrewYear, AdarType adarType) {
    final leap = _isHebrewLeapYear(hebrewYear);
    if (!leap) return _adar;
    switch (adarType) {
      case AdarType.adarA:
        return _adar; // אדר א' = 12
      case AdarType.adarB:
      case AdarType.adar:
        return _adarII; // אדר ב' = 13
      case AdarType.none:
        return _adar;
    }
  }

  /// מחזיר את מספר החודש בשיטת kosher_dart עבור אזכרה בשנה נתונה.
  int _monthForYear(HebrewMonth month, AdarType adarType, int hebrewYear) {
    if (month.isAdar) return _resolveAdarMonth(hebrewYear, adarType);
    return _kosherMonth(month);
  }

  /// אלגוריתם 19 שנים: שנים 3,6,8,11,14,17,19 במחזור הן מעוברות.
  bool _isHebrewLeapYear(int hebrewYear) {
    return ((7 * hebrewYear) + 1) % 19 < 7;
  }

  /// האם שנה עברית נתונה היא מעוברת.
  bool isLeapYear(int hebrewYear) => _isHebrewLeapYear(hebrewYear);

  /// היום העברי בחודש שבו חל תאריך לועזי נתון.
  int _hebrewDayOf(DateTime gregorian) {
    final jd = JewishDate();
    jd.setDate(gregorian);
    return jd.getJewishDayOfMonth();
  }

  /// מחזיר את השנה העברית שבה חל תאריך לועזי נתון.
  int _hebrewYearOf(DateTime gregorian) {
    final jd = JewishDate();
    jd.setDate(gregorian);
    return jd.getJewishYear();
  }

  /// מחזיר את השנה העברית הנוכחית.
  int _currentHebrewYear() => _hebrewYearOf(_now());

  int currentHebrewYear() => _currentHebrewYear();

  /// מספר הימים בחודש עברי נתון עבור שנה נתונה (או השנה הנוכחית).
  int daysInMonth({
    required HebrewMonth month,
    required AdarType adarType,
    int? forYear,
  }) {
    final year = forYear ?? _currentHebrewYear();
    try {
      final kMonth = _monthForYear(month, adarType, year);
      final jd = JewishDate();
      jd.setJewishDate(year, kMonth, 1);
      return jd.getDaysInJewishMonth();
    } catch (_) {
      return 29;
    }
  }

  /// כמה שנים נסרקות כדי למצוא את אורכו המרבי של חודש.
  ///
  /// מחזור העיבור הוא 19 שנים, ולכן סריקה כזו פוגשת את כל סוגי השנים –
  /// ובכללם אלה שבהן חשוון וכסלו בני שלושים.
  static const int _monthLengthScanYears = 19;

  /// אורכו המרבי של חודש על פני השנים, ולא אורכו בשנה הנוכחית.
  ///
  /// **חשוון וכסלו הם בני 29 או 30 יום, תלוי בשנה.** כשהשאלה היא אם יום
  /// שנה יכול לחול בתאריך מסוים, התשובה חייבת להיות על פני השנים כולן:
  /// אזכרה נשמרת פעם אחת וחוזרת לנצח, ושנה אחת שבה החודש קצר אינה הופכת
  /// את התאריך ללא קיים.
  ///
  /// זה מה שמיישר את הקלט עם החישוב: [_memorialGregorianForYear] כבר נסוג
  /// ליום האחרון של החודש בשנים הקצרות במקום לדלג עליהן, בעוד שהבורר
  /// והוולידציה עדיין שאלו את השנה הנוכחית בלבד – כך שבשנה קצרה אי אפשר
  /// היה להזין ל' בחשוון כלל, ועריכה של אזכרה קיימת כזו הייתה מגלגלת
  /// אותה בשקט לכ"ט.
  ///
  /// נגזר מ-kosher_dart ולא מטבלה קבועה, כדי שלא יוכל לסתור אותו.
  int maxDaysInMonth({
    required HebrewMonth month,
    required AdarType adarType,
  }) {
    final start = _currentHebrewYear();
    var longest = 0;
    for (var i = 0; i < _monthLengthScanYears; i++) {
      final days = daysInMonth(month: month, adarType: adarType, forYear: start + i);
      if (days > longest) longest = days;
    }
    return longest;
  }

  /// האם התאריך קיים **באיזושהי שנה**, ולא בהכרח בשנה הנוכחית.
  ///
  /// זו השאלה הנכונה בשביל קלט: ל' באייר אינו קיים לעולם ויש לדחות אותו,
  /// ואילו ל' בחשוון קיים ברוב השנים ובקצרות נסוג ליום האחרון של החודש.
  bool isDateEverValid({
    required int day,
    required HebrewMonth month,
    required AdarType adarType,
  }) =>
      day >= 1 &&
      day <= maxDaysInMonth(month: month, adarType: adarType);

  /// בודק אם צירוף יום/חודש/סוג-אדר הוא תאריך עברי חוקי.
  ///
  /// למשל: ל' באייר אינו חוקי (אייר בן 29 יום).
  bool isValidHebrewDate({
    required int day,
    required HebrewMonth month,
    required AdarType adarType,
    int? forYear,
  }) {
    if (day < 1 || day > 30) return false;

    final year = forYear ?? _currentHebrewYear();
    // אם החודש הוא אדר א'/ב' – נדרשת שנה מעוברת כדי שהחודש יתקיים כפי שנבחר;
    // אך "אדר" סתמי חוקי תמיד (נופל על האדר היחיד/אדר ב').
    try {
      final kMonth = _monthForYear(month, adarType, year);
      final jd = JewishDate();
      jd.setJewishDate(year, kMonth, 1);
      final daysInMonth = jd.getDaysInJewishMonth();
      return day <= daysInMonth;
    } catch (_) {
      return false;
    }
  }

  /// מטמון ההמרות. ראה [_memorialGregorianForYear].
  final Map<String, DateTime?> _gregorianCache = {};

  /// תקרה למטמון. בפועל הוא קטן בהרבה – שילובי יום/חודש/אדר כפול טווח
  /// השנים שנסרק – אבל גבול מונע ממנו לגדול בלי סוף אם מישהו יסרוק רחוק.
  static const int _cacheLimit = 2048;

  /// ממיר אזכרה לתאריך לועזי (DateTime, ללא שעה) בשנה עברית ספציפית,
  /// או null אם היום/החודש אינם קיימים בשנה זו.
  ///
  /// **ממוטמן, וזה בטוח כאן משום שהפונקציה טהורה**: התוצאה תלויה אך ורק
  /// ביום, בחודש, בסוג האדר ובשנה העברית המבוקשת – ולא ב"עכשיו". לכן אין
  /// מה לפוג, ומפתח שכולל את ארבעתם אינו יכול להחזיר תשובה של מישהו אחר.
  /// זו הסיבה שהמטמון יושב כאן ולא ב-[nextMemorialOccurrence], שכן תלוי
  /// בשעון – ושעון מוזרק הוא בדיוק המפתח שקל לטעות בו.
  ///
  /// המטמון הוא של המופע ולא סטטי, כך שבדיקה שבונה שירות משלה מתחילה נקייה.
  ///
  /// נמדד: הקלדה במסך עם 300 אזכרות עלתה 86ms בלי המטמון ו-38ms איתו,
  /// כשקו הבסיס של בניית הווידג'טים לבדה הוא 33ms.
  DateTime? _memorialGregorianForYear(Memorial memorial, int hebrewYear) {
    final key = '${memorial.hebrewDay}|${memorial.hebrewMonth}'
        '|${memorial.adarType.dbValue}|$hebrewYear';
    final hit = _gregorianCache[key];
    if (hit != null || _gregorianCache.containsKey(key)) return hit;

    final computed = _computeMemorialGregorian(memorial, hebrewYear);
    if (_gregorianCache.length >= _cacheLimit) _gregorianCache.clear();
    _gregorianCache[key] = computed;
    return computed;
  }

  DateTime? _computeMemorialGregorian(Memorial memorial, int hebrewYear) {
    try {
      final kMonth = _monthForYear(
        memorial.selectedMonth,
        memorial.adarType,
        hebrewYear,
      );

      final probe = JewishDate();
      probe.setJewishDate(hebrewYear, kMonth, 1);
      final daysInMonth = probe.getDaysInJewishMonth();

      // ל' בחודש שאורכו 29 בשנה זו – חשוון וכסלו משתנים באורכם. עד כה השנה
      // דולגה כליל, ומדידה הראתה שאזכרה בל' בחשוון קיבלה תזכורת ב-5 שנים
      // בלבד מתוך 11. **חוסר תזכורת גרוע מתזכורת ביום סמוך**, ולכן נסוגים
      // ליום האחרון של אותו חודש. זו הכרעה מעשית ולא פסיקה: יש נוהגים
      // לציין בכ"ט ויש בראש חודש שאחריו, והבחירה כאן היא זו שלעולם אינה
      // מאחרת אחרי היום המקורי.
      final day =
          memorial.hebrewDay > daysInMonth ? daysInMonth : memorial.hebrewDay;

      final jd = JewishDate();
      jd.setJewishDate(hebrewYear, kMonth, day);
      final g = jd.getGregorianCalendar();
      return DateTime(g.year, g.month, g.day);
    } catch (_) {
      return null;
    }
  }

  /// מחזיר את תאריך האזכרה הלועזי הקרוב ביותר (מהיום והלאה).
  ///
  /// אם התאריך של השנה הנוכחית כבר עבר – מחזיר את של השנה הבאה.
  /// בשנה שבה היום אינו קיים (ל' בחודש שאורכו 29) נסוגים ליום האחרון של
  /// אותו חודש, במקום לדלג על השנה.
  DateTime nextMemorialDate(Memorial memorial, {DateTime? from}) {
    final occurrence = nextMemorialOccurrence(memorial, from: from);
    if (occurrence != null) return occurrence.gregorian;

    final now = from ?? _now();
    return DateTime(now.year, now.month, now.day);
  }

  /// המופע הקרוב של האזכרה – התאריך הלועזי **והשנה העברית** שבה הוא חל.
  ///
  /// נחוץ כדי להציג תאריך עברי מלא (כולל שנה) עבור המופע הקרוב, בשונה מיום
  /// השנה החוזר שאין לו שנה.
  ({DateTime gregorian, int hebrewYear})? nextMemorialOccurrence(
    Memorial memorial, {
    DateTime? from,
  }) {
    final now = from ?? _now();
    final nowDateOnly = DateTime(now.year, now.month, now.day);

    // נגזר מ-[from] ולא מ-DateTime.now(), אחרת החיפוש היה מתחיל בשנה
    // העברית של השעון האמיתי ומתעלם מנקודת הייחוס שהועברה.
    final startHebrewYear = _hebrewYearOf(nowDateOnly);

    for (int offset = 0; offset <= 4; offset++) {
      final hebrewYear = startHebrewYear + offset;
      final gregorian = _memorialGregorianForYear(memorial, hebrewYear);
      if (gregorian == null) continue;

      if (!gregorian.isBefore(nowDateOnly)) {
        return (gregorian: gregorian, hebrewYear: hebrewYear);
      }
    }

    final fallbackYear = startHebrewYear + 1;
    final fallback = _memorialGregorianForYear(memorial, fallbackYear);
    if (fallback == null) return null;
    return (gregorian: fallback, hebrewYear: fallbackYear);
  }

  /// מחשב את מועד ההתראה של האזכרה **הקרובה**:
  /// יום שלישי של השבוע שלפני השבוע שבו חלה האזכרה.
  ///
  /// לוגיקה:
  ///   1. מחשבים את התאריך הלועזי של האזכרה הקרובה.
  ///   2. מוצאים את יום ראשון של שבוע האזכרה.
  ///   3. חוזרים שבוע אחד אחורה.
  ///   4. מוצאים את יום שלישי של אותו שבוע.
  ///
  /// השעה נקבעת לפי notificationHour/notificationMinute של האזכרה.
  ///
  /// **שים לב:** התוצאה עשויה להיות בעבר. מועד ההתראה מקדים את האזכרה
  /// ב-5 עד 11 יום, ולכן בכל שנה יש חלון שבו יום השלישי כבר חלף אך האזכרה
  /// עצמה עוד לפנינו. לתזמון התראות יש להשתמש ב-[nextFutureReminderDate].
  DateTime reminderDate(Memorial memorial, {DateTime? from}) {
    return _reminderForMemorialDate(
      memorial,
      nextMemorialDate(memorial, from: from),
    );
  }

  /// מועד ההתראה הבא שטרם עבר, או null אם לא נמצא בטווח הנסרק.
  ///
  /// בשונה מ-[reminderDate], אינו נעצר על האזכרה הקרובה: אם ההתראה עבורה
  /// כבר חלפה, ממשיך לשנה העברית הבאה. זהו המקור לתזמון התראות — אחרת
  /// אזכרה שנוספת בתוך אותו חלון לא הייתה מקבלת התראה כלל.
  DateTime? nextFutureReminderDate(Memorial memorial, {DateTime? from}) {
    final now = from ?? _now();
    final startHebrewYear =
        _hebrewYearOf(DateTime(now.year, now.month, now.day));

    for (int offset = 0; offset <= 5; offset++) {
      final memorialDate =
          _memorialGregorianForYear(memorial, startHebrewYear + offset);
      if (memorialDate == null) continue;

      final reminder = _reminderForMemorialDate(memorial, memorialDate);
      if (reminder.isAfter(now)) return reminder;
    }
    return null;
  }

  /// כמה שנים עבריות קדימה מתוזמנות התראות בכל פעם.
  ///
  /// אנדרואיד אינו מציע חזרה שנתית לפי הלוח העברי – התאריך העברי נודד בלוח
  /// הלועזי, ו-matchDateTimeComponents יודע לחזור רק שבועית/חודשית/שנתית
  /// לפי תאריך לועזי קבוע. לכן כל מופע מתוזמן בנפרד, וכל פתיחה של
  /// האפליקציה ממלאת את החלון מחדש.
  ///
  /// **שתיים ולא עשרים.** שנה אחת אינה מספיקה: אחרי שהתזכורת של השנה
  /// נורית מישהו חייב לחשב ולתזמן את הבאה, ומקלט ההפעלה-מחדש רק רושם מחדש
  /// אזעקות קיימות ואינו מחשב חדשות. עשרים שנה, מנגד, הגנו על תרחיש
  /// שכשלים אחרים מכסים הרבה לפניו – החלפת מכשיר, התקנה מחדש, ניהול סוללה
  /// – ובתמורה שילמו בתקרת 500 האזעקות של אנדרואיד ובתזמון בעלות ריבועית
  /// שהקפיא את הפתיחה.
  ///
  /// **הטווח נספר בשנים עבריות, לא במרווח שנשאר קדימה**, וזה ההבדל שקל
  /// לפספס. אזכרה שמועדה בדיוק חלף מאבדת מופע אחד מיד, ולכן במקרה הגרוע:
  ///
  ///     טווח 2  ->  כיסוי 1.05 שנים,  3 אזעקות לאזכרה
  ///     טווח 3  ->  כיסוי 2.03 שנים,  4 אזעקות לאזכרה
  ///
  /// המדידה הזו הובילה אותי להמליץ על 3; המשתמש בחר 2, במודע. המשמעות היא
  /// ששלושה-עשר חודשים בלי לפתוח את האפליקציה עלולים להחמיץ אזכרה אחת –
  /// אלא אם הרענון השבועי רץ, וזה הדבר שמנהל הסוללה עלול לדחות. אל תשנה
  /// את המספר בלי לחזור למדידה.
  static const int scheduleHorizonYears = 2;

  /// השעה שאליה נוחתת תזכורת שנדחתה.
  ///
  /// קבועה ואינה נגזרת משעת התזכורת של האזכרה, כדי שדחייה תגיע בבוקר גם
  /// למי שהגדיר תזכורת ראשית בשעה אחרת.
  static const int rescheduledReminderHour = 9;

  /// הדחייה שהמשתמש ביקש, אם היא עדיין תקפה.
  ///
  /// תקפה = בעתיד, ולא אחרי יום האזכרה. ההשוואה לאזכרה היא ברמת התאריך
  /// ולא הרגע, כי "ביום האזכרה" נוחת ב-09:00 ויום האזכרה מיוצג בחצות.
  ///
  /// אין מנגנון ניקוי: דחייה שחלפה פשוט מפסיקה לחול, וזה מספיק.
  DateTime? activePostponement(Memorial memorial, {DateTime? from}) {
    final at = memorial.postponedReminderAt;
    if (at == null) return null;

    final now = from ?? _now();
    if (!at.isAfter(now)) return null;

    final memorialDate = nextMemorialDate(memorial, from: now);
    final lastDay =
        DateTime(memorialDate.year, memorialDate.month, memorialDate.day);
    final atDay = DateTime(at.year, at.month, at.day);
    return atDay.isAfter(lastDay) ? null : at;
  }

  /// כל מועדי ההתראה העתידיים, מהקרוב לרחוק.
  ///
  /// מדלג על שנים שבהן התאריך אינו קיים (ל' בחודש חסר, אדר א' בשנה פשוטה)
  /// ועל מועדים שכבר חלפו.
  List<DateTime> futureReminderDates(
    Memorial memorial, {
    DateTime? from,
    int years = scheduleHorizonYears,
  }) {
    final now = from ?? _now();
    final startHebrewYear =
        _hebrewYearOf(DateTime(now.year, now.month, now.day));

    final reminders = <DateTime>[];
    for (int offset = 0; offset <= years; offset++) {
      final memorialDate =
          _memorialGregorianForYear(memorial, startHebrewYear + offset);
      if (memorialDate == null) continue;

      final reminder = _reminderForMemorialDate(memorial, memorialDate);
      if (reminder.isAfter(now)) reminders.add(reminder);
    }

    // דחייה מחליפה את המופע הקרוב ואינה מתווספת אליו. בלי ההסרה, תזכורת
    // שנדחתה עוד לפני שמועדה המקורי חלף הייתה מגיעה פעמיים.
    final postponed = activePostponement(memorial, from: now);
    if (postponed != null) {
      final memorialDate = nextMemorialDate(memorial, from: now);
      reminders.removeWhere((d) => d.isBefore(memorialDate));
      reminders.insert(0, postponed);
    }
    return reminders;
  }

  /// מועד תזכורת שחלף אך טרם נמסר, או null אם אין כזה.
  ///
  /// מחזיר ערך רק כשהתזכורת של האזכרה **הקרובה** כבר עברה בעוד האזכרה עצמה
  /// לפנינו – החלון בן 5 עד 11 הימים שבו יום השלישי חלף. במצב כזה עדיף
  /// להציג את התזכורת באיחור מאשר לדלג עליה.
  ///
  /// [lastNotifiedAt] הוא המועד האחרון שכבר הוצג; אם הוא זהה למועד שחלף,
  /// אין מה להשלים.
  DateTime? missedReminderDate(Memorial memorial, {DateTime? from}) {
    final now = from ?? _now();

    final occurrence = nextMemorialOccurrence(memorial, from: now);
    if (occurrence == null) return null;

    final reminder = _reminderForMemorialDate(memorial, occurrence.gregorian);
    if (!reminder.isBefore(now)) return null; // עוד לא הגיע – יטופל בתזמון

    final last = memorial.lastNotifiedAt;
    if (last != null && !last.isBefore(reminder)) return null; // כבר נמסר

    return reminder;
  }



  /// תאריך האזכרה שאליו שייך מועד תזכורת נתון, או null אם לא נמצא.
  ///
  /// נחוץ כדי לבנות את טקסט ההתראה בזמן התזמון: לכל מופע יש תאריך אזכרה
  /// משלו, וההתראה נכתבת שנים מראש.
  DateTime? memorialDateForReminder(
    Memorial memorial,
    DateTime reminder, {
    int years = scheduleHorizonYears,
  }) {
    final startHebrewYear =
        _hebrewYearOf(DateTime(reminder.year, reminder.month, reminder.day));

    // התזכורת קודמת לאזכרה, ולכן היא עשויה ליפול בשנה העברית שלפניה.
    for (int offset = 0; offset <= years + 1; offset++) {
      final candidate =
          _memorialGregorianForYear(memorial, startHebrewYear + offset);
      if (candidate == null) continue;
      if (!candidate.isBefore(
          DateTime(reminder.year, reminder.month, reminder.day))) {
        return candidate;
      }
    }
    return null;
  }
  /// תיאור האזכרה לטקסט התראה: יום בשבוע, תאריך לועזי, וכמה ימים נותרו.
  ///
  /// [reminderDate] הוא מועד הירי – מספר הימים נמדד ממנו ולא מ"עכשיו",
  /// כי ההתראה מתוזמנת שנים מראש והטקסט נקבע בזמן התזמון.
  String describeMemorialForReminder(
    Memorial memorial,
    DateTime reminderDate,
    DateTime memorialDate,
  ) {
    final weekday = hebrewWeekdayNames[memorialDate.weekday] ?? '';
    final d = memorialDate.day.toString().padLeft(2, '0');
    final mo = memorialDate.month.toString().padLeft(2, '0');

    // ב-UTC כדי ששעון קיץ לא יגרע יום.
    final days = DateTime.utc(
            memorialDate.year, memorialDate.month, memorialDate.day)
        .difference(DateTime.utc(
            reminderDate.year, reminderDate.month, reminderDate.day))
        .inDays;

    final countdown = switch (days) {
      <= 0 => 'היום',
      1 => 'מחר',
      2 => 'בעוד יומיים',
      _ => 'בעוד $days ימים',
    };

    return 'יום $weekday $d/$mo/${memorialDate.year}, $countdown';
  }
  /// מועד ההתראה עבור [memorialDate], לפי כלל התזכורת של האזכרה.
  DateTime _reminderForMemorialDate(Memorial memorial, DateTime memorialDate) {
    final day = switch (memorial.reminderMode) {
      ReminderMode.weekdayOfPreviousWeek =>
        weekdayBeforeWeekOf(memorialDate, memorial.reminderValue),
      ReminderMode.fixedDaysBefore => DateTime(
          memorialDate.year,
          memorialDate.month,
          memorialDate.day - memorial.reminderValue,
        ),
    };

    return DateTime(
      day.year,
      day.month,
      day.day,
      memorial.notificationHour,
      memorial.notificationMinute,
    );
  }

  /// יום [weekday] של השבוע שלפני שבוע [memorialDate].
  ///
  /// [weekday] לפי [DateTime.weekday] – שלישי = 2. עבור יום ראשון (7) נדרש
  /// טיפול נפרד, כי יום ראשון הוא **תחילת** השבוע ולא סופו.
  ///
  /// גם כאן החשבון על רכיבי התאריך ולא ב-[Duration], מאותה סיבת שעון קיץ.
  DateTime weekdayBeforeWeekOf(DateTime memorialDate, int weekday) {
    final sunday = _sundayOfWeek(memorialDate);
    // ראשון(7) -> 0 ימים מיום ראשון, שני(1) -> 1, ... שישי(5) -> 5.
    final offsetFromSunday = weekday % 7;
    return DateTime(
      sunday.year,
      sunday.month,
      sunday.day - 7 + offsetFromSunday,
    );
  }

  /// מחזיר את יום ראשון של השבוע המכיל את [date] (שבוע ראשון–שבת).
  ///
  /// **חשוב:** החשבון נעשה על רכיבי התאריך ולא באמצעות [Duration].
  /// `DateTime.subtract` פועל על זמן אבסולוטי, ולכן חציית מעבר שעון קיץ
  /// מזיזה את שעת התוצאה ועלולה להחזיר את היום הקודם.
  DateTime _sundayOfWeek(DateTime date) {
    // weekday: Mon=1..Sun=7. ראשון(7)->0, שני(1)->1, ... שבת(6)->6.
    final daysFromSunday = date.weekday % 7;
    return DateTime(date.year, date.month, date.day - daysFromSunday);
  }

  /// יום שלישי של השבוע שלפני שבוע התאריך הנתון – ברירת המחדל של האפליקציה.
  DateTime tuesdayBeforeWeekOf(DateTime memorialDate) =>
      weekdayBeforeWeekOf(memorialDate, DateTime.tuesday);

  /// מפרמט תאריך עברי לתצוגה, למשל: י"ד בחשוון.
  ///
  /// זהו יום השנה החוזר – ללא שנה. לתאריך של מופע ספציפי ראה
  /// [formatNextMemorialHebrewDate].
  String formatHebrewDate(Memorial memorial) {
    final dayHeb = HebrewNumerals.dayToHebrew(memorial.hebrewDay);
    final monthName = memorial.selectedMonth.hebrewName;
    return '$dayHeb ב$monthName';
  }

  /// באיזו שנה האזכרה הקרובה – 1 לאזכרה הראשונה, 2 לשנייה וכן הלאה.
  ///
  /// null כששנת הפטירה אינה ידועה, או אם היא מאוחרת מהמופע הקרוב (נתון
  /// שגוי – עדיף לא להציג מספר מטעה).
  int? yahrzeitNumber(Memorial memorial, {DateTime? from}) {
    final deathYear = memorial.deathHebrewYear;
    if (deathYear == null) return null;

    final occurrence = nextMemorialOccurrence(memorial, from: from);
    if (occurrence == null) return null;

    final n = occurrence.hebrewYear - deathYear;
    return n >= 1 ? n : null;
  }

  /// טווח השנים העבריות להצגה בבורר שנת הפטירה, מהחדשה לישנה.
  ///
  /// מוגבל לעבר: אי אפשר להיפטר בעתיד.
  List<int> deathYearChoices({int span = 120}) {
    final current = _currentHebrewYear();
    return [for (var y = current; y > current - span; y--) y];
  }

  /// מפרמט שנה עברית בגימטריה, למשל 5786 -> תשפ״ו.
  /// (kosher_dart משמיט את אלף השנים ומשתמש בגרשיים ״.)
  String formatHebrewYear(int hebrewYear) {
    final formatter = HebrewDateFormatter()..hebrewFormat = true;
    return formatter.formatHebrewNumber(hebrewYear);
  }

  /// התאריך העברי המלא של המופע הקרוב, כולל שנה.
  /// למשל: כ"ו באב תשפ״ו.
  ///
  /// **התאריך הוא של המופע בפועל, לא זה שנשמר** – גם היום וגם החודש.
  ///
  /// אזכרה שנשמרה כ"אדר" סתמי מוצגת כ"אדר ב'" בשנה מעוברת. ובאותו אופן,
  /// אזכרה בל' בחשוון בשנה שבה חשוון בן 29 מוצגת כ-כ"ט בחשוון, כי שם היא
  /// באמת נופלת: [_memorialGregorianForYear] נסוג ליום האחרון של החודש.
  ///
  /// עד כה היום נלקח מהשדה השמור, והשורה סתרה את השורה שמעליה – "ל' בחשוון
  /// תשפ״ט" לצד 18/11/2028, שהוא כ"ט. השורה הזו היא **המופע**; יום השנה
  /// החוזר, בלי שנה, מוצג בנפרד ב-[formatHebrewDate] וממשיך לומר ל' בחשוון.
  ///
  /// היום נגזר מהתאריך הלועזי שכבר חושב ולא מחושב שוב, כדי שלא יוכל לסטות
  /// ממנו.
  String? formatNextMemorialHebrewDate(Memorial memorial, {DateTime? from}) {
    final occurrence = nextMemorialOccurrence(memorial, from: from);
    if (occurrence == null) return null;

    final year = occurrence.hebrewYear;
    final dayHeb = HebrewNumerals.dayToHebrew(_hebrewDayOf(occurrence.gregorian));

    return '$dayHeb ב${_monthNameForYear(memorial, year)} '
        '${formatHebrewYear(year)}';
  }

  /// שם החודש כפי שהוא באותה שנה: "אדר" סתמי הוא אדר ב' בשנה מעוברת.
  String _monthNameForYear(Memorial memorial, int hebrewYear) {
    final month = memorial.selectedMonth;
    if (!month.isAdar) return month.hebrewName;
    if (_resolveAdarMonth(hebrewYear, memorial.adarType) == _adarII) {
      return "אדר ב'";
    }
    return _isHebrewLeapYear(hebrewYear) ? "אדר א'" : 'אדר';
  }

  /// משפט הסבר כשהיום שנשמר אינו קיים בשנת המופע, או null כשהוא כן קיים.
  ///
  /// ל' בחשוון ובכסלו קיים רק בשנים שבהן החודש בן שלושים, ואז המופע נסוג
  /// ליום האחרון של החודש. בלי משפט אחד שאומר זאת, הכרטיס נראה כאילו
  /// התאריך שהוזן שונה מעצמו בלי סיבה – ומי שהזין ל' בחשוון צריך לדעת
  /// שהתזכורת מגיעה יום קודם, ולמה.
  String? adjustedDayNote(Memorial memorial, {DateTime? from}) {
    final occurrence = nextMemorialOccurrence(memorial, from: from);
    if (occurrence == null) return null;

    final actual = _hebrewDayOf(occurrence.gregorian);
    if (actual == memorial.hebrewDay) return null;

    final month = _monthNameForYear(memorial, occurrence.hebrewYear);
    return '${HebrewNumerals.dayToHebrew(memorial.hebrewDay)} ב$month '
        'אינו קיים ב${formatHebrewYear(occurrence.hebrewYear)}, '
        'ולכן האזכרה ב${HebrewNumerals.dayToHebrew(actual)}';
  }

  /// מפרמט תאריך עברי מתוך יום/חודש גולמיים (עבור ה-picker בזמן אמת).
  String formatHebrewDayMonth(int day, HebrewMonth month) {
    final dayHeb = HebrewNumerals.dayToHebrew(day);
    return '$dayHeb ב${month.hebrewName}';
  }

  /// מספר הימים (שלמים) מהיום ועד האזכרה הקרובה. אינו שלילי.
  ///
  /// ההפרש נמדד ב-UTC מאותה סיבה כמו ב-[daysUntilReminder]: על תאריכים
  /// מקומיים מעבר שעון קיץ מקצר את ההפרש ו-inDays מעגל כלפי מטה.
  int daysUntilMemorial(Memorial memorial, {DateTime? from}) {
    final now = from ?? _now();
    final memorialDate = nextMemorialDate(memorial, from: from);

    final today = DateTime.utc(now.year, now.month, now.day);
    final target = DateTime.utc(
        memorialDate.year, memorialDate.month, memorialDate.day);
    return target.difference(today).inDays;
  }

  /// האם האזכרה הקרובה חלה בתוך [days] הימים הבאים (כולל היום).
  bool isMemorialWithin(Memorial memorial, int days, {DateTime? from}) =>
      daysUntilMemorial(memorial, from: from) <= days;

  /// מספר הימים (שלמים) מהיום ועד מועד ההתראה. שלילי אם עבר.
  int daysUntilReminder(Memorial memorial, {DateTime? from}) {
    final now = from ?? _now();
    // דחייה גוברת על הכלל: היא המועד שבו ההתראה באמת תגיע.
    final reminder = activePostponement(memorial, from: from) ??
        reminderDate(memorial, from: from);

    // ההפרש נמדד ב-UTC: על תאריכים מקומיים מעבר שעון קיץ הופך את ההפרש
    // האבסולוטי ל-167 או 169 שעות, ו-inDays היה מעגל כלפי מטה ומחסיר יום.
    final today = DateTime.utc(now.year, now.month, now.day);
    final reminderDay =
        DateTime.utc(reminder.year, reminder.month, reminder.day);
    return reminderDay.difference(today).inDays;
  }
}
