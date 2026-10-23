import 'package:kosher_dart/kosher_dart.dart';

import '../models/event.dart';
import '../models/event_date.dart';

/// שירות מרכזי לכל חישובי התאריכים – העבריים והלועזיים כאחד.
///
/// **חשוב:** כל לוגיקת התאריכים באפליקציה מרוכזת כאן בלבד.
/// שכבת ה-UI אינה מבצעת חישובי תאריכים ישירות.
///
/// **שני לוחות, מנגנון אחד.** ההבדל בין אירוע עברי ללועזי מצטמצם לשאלה
/// אחת: מהו התאריך הלועזי של המופע בשנה מספר N. ברגע שיש תשובה, כל מה
/// שמעליה – מועד התזכורת, המופעים העתידיים, ההשלמה, הדחייה ותקציב
/// האזעקות – זהה לחלוטין לשני הלוחות ואינו יודע עליהם דבר. לכן הפיצול
/// יושב ב-[_occurrenceForYear] ובו בלבד.
///
/// המילה "שנה" בשירות הזה פירושה **שנה בלוח של האירוע**: שנה עברית לאירוע
/// עברי, ושנה לועזית ללועזי.
///
/// הערה על מספרי חודשים: אנו משתמשים בערכים המספריים של kosher_dart/KosherJava
/// ישירות (ולא בקבועים בעלי שם, שכן שמם משתנה בין גרסאות/forks של החבילה –
/// NISSAN מול NISAN וכד'). המספור:
///   ניסן=1, אייר=2, סיוון=3, תמוז=4, אב=5, אלול=6,
///   תשרי=7, חשוון=8, כסלו=9, טבת=10, שבט=11,
///   אדר=12, אדר ב'=13 (רק בשנה מעוברת).
class EventCalendarService {
  /// מקור הזמן הנוכחי. ברירת המחדל היא שעון המערכת; ניתן להזרקה כדי
  /// שתצוגות התלויות ב"היום" (למשל מספר הימים עד התזכורת) יהיו ניתנות
  /// לבדיקה דטרמיניסטית.
  final DateTime Function() _now;

  EventCalendarService({DateTime Function()? now}) : _now = now ?? DateTime.now;

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
      case HebrewMonth.adar:
      case HebrewMonth.adarA:
      case HebrewMonth.adarB:
        // מטופל ב-_resolveAdarMonth.
        return _adar;
    }
  }

  /// קובע לאיזה חודש בפועל מתורגם האדר בשנה נתונה.
  ///
  /// בשנה פשוטה יש אדר אחד (12). בשנה מעוברת: אדר א' = 12, אדר ב' = 13,
  /// ו"אדר" סתמי נופל על אדר ב' – כמנהג הרווח לציין יום שנה באדר ב'.
  int _resolveAdarMonth(int hebrewYear, AdarType adarType) {
    final leap = _isHebrewLeapYear(hebrewYear);
    if (!leap) return _adar;
    switch (adarType) {
      case AdarType.adarA:
        return _adar;
      case AdarType.adarB:
      case AdarType.adar:
      case AdarType.none:
        return _adarII;
    }
  }

  /// מספר החודש בשיטת kosher_dart עבור שנה נתונה.
  int _monthForYear(HebrewMonth month, AdarType adarType, int hebrewYear) {
    if (month.isAdar) return _resolveAdarMonth(hebrewYear, adarType);
    return _kosherMonth(month);
  }

  bool _isHebrewLeapYear(int hebrewYear) {
    return ((7 * hebrewYear) + 1) % 19 < 7;
  }

  /// האם השנה העברית מעוברת (יש בה אדר א' ואדר ב').
  bool isLeapYear(int hebrewYear) => _isHebrewLeapYear(hebrewYear);

  /// היום העברי בחודש של תאריך לועזי נתון.
  int _hebrewDayOf(DateTime gregorian) {
    final jd = JewishDate();
    jd.setDate(gregorian);
    return jd.getJewishDayOfMonth();
  }

  /// השנה העברית שבה חל תאריך לועזי נתון.
  int _hebrewYearOf(DateTime gregorian) {
    final jd = JewishDate();
    jd.setDate(gregorian);
    return jd.getJewishYear();
  }

  /// מחזיר את השנה העברית הנוכחית.
  int _currentHebrewYear() => _hebrewYearOf(_now());

  int currentHebrewYear() => _currentHebrewYear();

  /// השנה הנוכחית בלוח [calendar].
  int currentYear(CalendarSystem calendar) => calendar == CalendarSystem.hebrew
      ? _currentHebrewYear()
      : _now().year;

  /// השנה שבה חל תאריך לועזי נתון, בלוח [calendar].
  int _yearOf(DateTime date, CalendarSystem calendar) =>
      calendar == CalendarSystem.hebrew ? _hebrewYearOf(date) : date.year;

  /// מספר הימים בחודש עברי נתון עבור שנה נתונה (או השנה הנוכחית).
  int daysInHebrewMonth({
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

  /// מספר הימים בחודש לועזי נתון בשנה נתונה.
  ///
  /// היום ה-0 של החודש הבא הוא היום האחרון של החודש הזה – כך גם פברואר של
  /// שנה מעוברת יוצא נכון בלי טבלה ובלי חוק עיבור כתוב ביד.
  int daysInGregorianMonth(int year, int month) {
    if (month < 1 || month > 12) return 0;
    return DateTime(year, month + 1, 0).day;
  }

  /// כמה שנים נסרקות כדי למצוא את אורכו המרבי של חודש.
  ///
  /// מחזור העיבור העברי הוא 19 שנים, ולכן סריקה כזו פוגשת את כל סוגי
  /// השנים – ובכללם אלה שבהן חשוון וכסלו בני שלושים. בלוח הלועזי המחזור
  /// הוא ארבע שנים, ודי בהן כדי לפגוש 29 בפברואר.
  static const int _hebrewScanYears = 19;
  static const int _gregorianScanYears = 4;

  /// אורכו המרבי של חודש על פני השנים, ולא אורכו בשנה הנוכחית.
  ///
  /// **חשוון וכסלו הם בני 29 או 30 יום, ופברואר בן 28 או 29.** כשהשאלה
  /// היא אם יום שנה יכול לחול בתאריך מסוים, התשובה חייבת להיות על פני
  /// השנים כולן: אירוע נשמר פעם אחת וחוזר לנצח, ושנה אחת שבה החודש קצר
  /// אינה הופכת את התאריך ללא קיים.
  ///
  /// זה מה שמיישר את הקלט עם החישוב: [_occurrenceForYear] כבר נסוג ליום
  /// האחרון של החודש בשנים הקצרות במקום לדלג עליהן, ואילו הבורר והוולידציה
  /// היו שואלים את השנה הנוכחית בלבד – כך שבשנה קצרה אי אפשר היה להזין
  /// ל' בחשוון (או 29 בפברואר) כלל, ועריכה של אירוע קיים כזה הייתה מגלגלת
  /// אותו בשקט ליום הקודם.
  ///
  /// נגזר מהלוח עצמו ולא מטבלה קבועה, כדי שלא יוכל לסתור אותו.
  int maxDaysInMonth({
    required CalendarSystem calendar,
    required int month,
    AdarType adarType = AdarType.none,
  }) {
    if (calendar == CalendarSystem.gregorian) {
      final start = _now().year;
      var longest = 0;
      for (var i = 0; i < _gregorianScanYears; i++) {
        final days = daysInGregorianMonth(start + i, month);
        if (days > longest) longest = days;
      }
      return longest;
    }

    final hebrewMonth = HebrewMonth.fromStorage(month, adarType);
    final start = _currentHebrewYear();
    var longest = 0;
    for (var i = 0; i < _hebrewScanYears; i++) {
      final days = daysInHebrewMonth(
        month: hebrewMonth,
        adarType: adarType,
        forYear: start + i,
      );
      if (days > longest) longest = days;
    }
    return longest;
  }

  /// האם התאריך קיים **באיזושהי שנה**, ולא בהכרח בשנה הנוכחית.
  ///
  /// זו השאלה הנכונה בשביל קלט: ל' באייר ו-31 בפברואר אינם קיימים לעולם
  /// ויש לדחות אותם, ואילו ל' בחשוון ו-29 בפברואר קיימים בחלק מהשנים
  /// ובקצרות נסוגים ליום האחרון של החודש.
  bool isDateEverValid({
    required CalendarSystem calendar,
    required int day,
    required int month,
    AdarType adarType = AdarType.none,
  }) =>
      day >= 1 &&
      day <=
          maxDaysInMonth(
            calendar: calendar,
            month: month,
            adarType: adarType,
          );

  /// בודק אם צירוף יום/חודש/סוג-אדר הוא תאריך עברי חוקי בשנה נתונה.
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
      return day <= jd.getDaysInJewishMonth();
    } catch (_) {
      return false;
    }
  }

  /// מטמון ההמרות. ראה [_occurrenceForYear].
  final Map<String, DateTime?> _occurrenceCache = {};

  /// תקרה למטמון. בפועל הוא קטן בהרבה – שילובי יום/חודש/לוח כפול טווח
  /// השנים שנסרק – אבל גבול מונע ממנו לגדול בלי סוף אם מישהו יסרוק רחוק.
  static const int _cacheLimit = 2048;

  /// התאריך הלועזי של המופע בשנה [year] (בלוח של האירוע), או null אם אין
  /// מופע כזה.
  ///
  /// **ממוטמן, וזה בטוח כאן משום שהפונקציה טהורה**: התוצאה תלויה אך ורק
  /// בלוח, ביום, בחודש, בסוג האדר ובשנה המבוקשת – ולא ב"עכשיו". לכן אין
  /// מה לפוג, ומפתח שכולל את חמשתם אינו יכול להחזיר תשובה של מישהו אחר.
  /// זו הסיבה שהמטמון יושב כאן ולא ב-[nextOccurrence], שכן תלוי בשעון –
  /// ושעון מוזרק הוא בדיוק המפתח שקל לטעות בו.
  ///
  /// המטמון הוא של המופע ולא סטטי, כך שבדיקה שבונה שירות משלה מתחילה נקייה.
  DateTime? _occurrenceForYear(Event event, int year) {
    final key = '${event.calendar.dbValue}|${event.day}|${event.month}'
        '|${event.adarType.dbValue}|$year';
    final hit = _occurrenceCache[key];
    if (hit != null || _occurrenceCache.containsKey(key)) return hit;

    final computed = event.isHebrew
        ? _computeHebrewOccurrence(event, year)
        : _computeGregorianOccurrence(event, year);
    if (_occurrenceCache.length >= _cacheLimit) _occurrenceCache.clear();
    _occurrenceCache[key] = computed;
    return computed;
  }

  DateTime? _computeHebrewOccurrence(Event event, int hebrewYear) {
    try {
      final kMonth = _monthForYear(
        event.hebrewMonth,
        event.adarType,
        hebrewYear,
      );

      final probe = JewishDate();
      probe.setJewishDate(hebrewYear, kMonth, 1);
      final daysInMonth = probe.getDaysInJewishMonth();

      // ל' בחודש שאורכו 29 בשנה זו – חשוון וכסלו משתנים באורכם. עד כה השנה
      // דולגה כליל, ומדידה הראתה שאירוע בל' בחשוון קיבל תזכורת ב-5 שנים
      // בלבד מתוך 11. **חוסר תזכורת גרוע מתזכורת ביום סמוך**, ולכן נסוגים
      // ליום האחרון של אותו חודש – הבחירה שלעולם אינה מאחרת אחרי היום
      // המקורי.
      final day = event.day > daysInMonth ? daysInMonth : event.day;

      final jd = JewishDate();
      jd.setJewishDate(hebrewYear, kMonth, day);
      final g = jd.getGregorianCalendar();
      return DateTime(g.year, g.month, g.day);
    } catch (_) {
      return null;
    }
  }

  /// המופע הלועזי – ואותו כלל בדיוק: 29 בפברואר נסוג ל-28 בשנה שאינה
  /// מעוברת, במקום לדלג על השנה.
  ///
  /// החישוב על רכיבי התאריך ולא דרך [DateTime] ישירות: `DateTime(2027, 2, 29)`
  /// **אינו נכשל** אלא גולש בשקט ל-1 במרץ, וזו תזכורת ביום הלא נכון.
  DateTime? _computeGregorianOccurrence(Event event, int year) {
    final daysInMonth = daysInGregorianMonth(year, event.month);
    if (daysInMonth == 0) return null;
    final day = event.day > daysInMonth ? daysInMonth : event.day;
    return DateTime(year, event.month, day);
  }

  /// מחזיר את התאריך הלועזי של המופע הקרוב (מהיום והלאה).
  ///
  /// אם המופע של השנה הנוכחית כבר עבר – מחזיר את של השנה הבאה.
  DateTime nextOccurrenceDate(Event event, {DateTime? from}) {
    final occurrence = nextOccurrence(event, from: from);
    if (occurrence != null) return occurrence.gregorian;

    final now = from ?? _now();
    return DateTime(now.year, now.month, now.day);
  }

  /// המופע הקרוב – התאריך הלועזי **והשנה** (בלוח של האירוע) שבה הוא חל.
  ///
  /// השנה נחוצה כדי להציג תאריך מלא כולל שנה, וכדי לדעת "יום הנישואין
  /// הכמה" זה.
  ({DateTime gregorian, int year})? nextOccurrence(
    Event event, {
    DateTime? from,
  }) {
    final now = from ?? _now();
    final nowDateOnly = DateTime(now.year, now.month, now.day);

    // נגזר מ-[from] ולא מ-DateTime.now(), אחרת החיפוש היה מתחיל בשנה
    // של השעון האמיתי ומתעלם מנקודת הייחוס שהועברה.
    final startYear = _yearOf(nowDateOnly, event.calendar);

    for (int offset = 0; offset <= 4; offset++) {
      final year = startYear + offset;
      final gregorian = _occurrenceForYear(event, year);
      if (gregorian == null) continue;

      if (!gregorian.isBefore(nowDateOnly)) {
        return (gregorian: gregorian, year: year);
      }
    }

    final fallbackYear = startYear + 1;
    final fallback = _occurrenceForYear(event, fallbackYear);
    if (fallback == null) return null;
    return (gregorian: fallback, year: fallbackYear);
  }

  /// מחשב את מועד ההתראה של המופע **הקרוב**, לפי כלל התזכורת של האירוע.
  ///
  /// בברירת המחדל: יום שלישי של השבוע שלפני השבוע שבו חל האירוע.
  ///
  /// **שים לב:** התוצאה עשויה להיות בעבר. מועד ההתראה מקדים את האירוע
  /// ב-5 עד 11 יום, ולכן בכל שנה יש חלון שבו יום השלישי כבר חלף אך האירוע
  /// עצמו עוד לפנינו. התזמון עצמו עובר דרך [futureReminderDates], שמונה
  /// את כל החלון – ולא דרך [nextFutureReminderDate], שאין לו יותר קוראים
  /// ב-lib ושאינו מכבד דילוג על שנה.
  DateTime reminderDate(Event event, {DateTime? from}) {
    return _reminderForEventDate(
      event,
      nextOccurrenceDate(event, from: from),
    );
  }

  /// מועד ההתראה הבא שטרם עבר, או null אם לא נמצא בטווח הנסרק.
  ///
  /// בשונה מ-[reminderDate], אינו נעצר על המופע הקרוב: אם ההתראה עבורו
  /// כבר חלפה, ממשיך לשנה הבאה. זהו המקור לתזמון התראות — אחרת אירוע
  /// שנוסף בתוך אותו חלון לא היה מקבל התראה כלל.
  DateTime? nextFutureReminderDate(Event event, {DateTime? from}) {
    final now = from ?? _now();
    final startYear =
        _yearOf(DateTime(now.year, now.month, now.day), event.calendar);

    for (int offset = 0; offset <= 5; offset++) {
      final eventDate = _occurrenceForYear(event, startYear + offset);
      if (eventDate == null) continue;

      final reminder = _reminderForEventDate(event, eventDate);
      if (reminder.isAfter(now)) return reminder;
    }
    return null;
  }

  /// כמה שנים קדימה מתוזמנות התראות בכל פעם.
  ///
  /// אנדרואיד אינו מציע חזרה שנתית לפי הלוח העברי – התאריך העברי נודד בלוח
  /// הלועזי, ו-matchDateTimeComponents יודע לחזור רק שבועית/חודשית/שנתית
  /// לפי תאריך לועזי קבוע. לכן כל מופע מתוזמן בנפרד, וכל פתיחה של
  /// האפליקציה ממלאת את החלון מחדש. אירוע לועזי היה יכול בעיקרון להסתמך על
  /// חזרה שנתית, אבל לא כדאי: שני מסלולי תזמון נפרדים פירושם שני מנגנוני
  /// ביטול, שתי דרכים לספור מה מתוזמן, ותקציב אזעקות שאי אפשר לחשב.
  ///
  /// **שתיים ולא עשרים.** שנה אחת אינה מספיקה: אחרי שהתזכורת של השנה
  /// נורית מישהו חייב לחשב ולתזמן את הבאה, ומקלט ההפעלה-מחדש רק רושם מחדש
  /// אזעקות קיימות ואינו מחשב חדשות. עשרים שנה, מנגד, הגנו על תרחיש
  /// שכשלים אחרים מכסים הרבה לפניו – החלפת מכשיר, התקנה מחדש, ניהול סוללה
  /// – ובתמורה שילמו בתקרת 500 האזעקות של אנדרואיד ובתזמון בעלות ריבועית
  /// שהקפיא את הפתיחה.
  ///
  /// **הטווח נספר בשנים, לא במרווח שנשאר קדימה**, וזה ההבדל שקל לפספס.
  /// אירוע שמועדו בדיוק חלף מאבד מופע אחד מיד, ולכן במקרה הגרוע:
  ///
  ///     טווח 2  ->  כיסוי 1.05 שנים,  3 אזעקות לאירוע
  ///     טווח 3  ->  כיסוי 2.03 שנים,  4 אזעקות לאירוע
  ///
  /// המשמעות היא ששלושה-עשר חודשים בלי לפתוח את האפליקציה עלולים להחמיץ
  /// אירוע אחד – אלא אם הרענון השבועי רץ, וזה הדבר שמנהל הסוללה עלול
  /// לדחות. אל תשנה את המספר בלי לחזור למדידה.
  static const int scheduleHorizonYears = 2;

  /// השעה שאליה נוחתת תזכורת שנדחתה.
  ///
  /// קבועה ואינה נגזרת משעת התזכורת של האירוע, כדי שדחייה תגיע בבוקר גם
  /// למי שהגדיר תזכורת ראשית בשעה אחרת.
  static const int rescheduledReminderHour = 9;

  /// הדחייה שהמשתמש ביקש, אם היא עדיין תקפה.
  ///
  /// תקפה = בעתיד, ולא אחרי יום האירוע. ההשוואה לאירוע היא ברמת התאריך
  /// ולא הרגע, כי "ביום האירוע" נוחת ב-09:00 ויום האירוע מיוצג בחצות.
  ///
  /// אין מנגנון ניקוי: דחייה שחלפה פשוט מפסיקה לחול, וזה מספיק.
  DateTime? activePostponement(Event event, {DateTime? from}) {
    final at = event.postponedReminderAt;
    if (at == null) return null;

    final now = from ?? _now();
    if (!at.isAfter(now)) return null;

    final eventDate = nextOccurrenceDate(event, from: now);
    final lastDay = DateTime(eventDate.year, eventDate.month, eventDate.day);
    final atDay = DateTime(at.year, at.month, at.day);
    return atDay.isAfter(lastDay) ? null : at;
  }

  /// כל מועדי ההתראה העתידיים, מהקרוב לרחוק.
  ///
  /// מדלג על שנים שבהן התאריך אינו קיים ועל מועדים שכבר חלפו.
  List<DateTime> futureReminderDates(
    Event event, {
    DateTime? from,
    int years = scheduleHorizonYears,
  }) {
    final now = from ?? _now();
    final startYear =
        _yearOf(DateTime(now.year, now.month, now.day), event.calendar);

    final reminders = <DateTime>[];
    for (int offset = 0; offset <= years; offset++) {
      final eventDate = _occurrenceForYear(event, startYear + offset);
      if (eventDate == null) continue;

      final reminder = _reminderForEventDate(event, eventDate);
      if (reminder.isAfter(now)) reminders.add(reminder);
    }

    // דחייה מחליפה את המופע הקרוב ואינה מתווספת אליו. בלי ההסרה, תזכורת
    // שנדחתה עוד לפני שמועדה המקורי חלף הייתה מגיעה פעמיים.
    final postponed = activePostponement(event, from: now);
    if (postponed != null) {
      final eventDate = nextOccurrenceDate(event, from: now);
      reminders.removeWhere((d) => d.isBefore(eventDate));
      reminders.insert(0, postponed);
    }

    // דילוג מסיר את המופע ואינו מוסיף דבר במקומו – זה כל ההבדל בינו
    // לבין דחייה. **אחרי** הדחייה ולא לפניה, כדי שדילוג יבטל גם דחייה
    // שנרשמה קודם לכן; אחרת insert(0) היה מחזיר לחיים בדיוק את המופע
    // שהתבקש לדלג עליו.
    //
    // ההשוואה ברמת היום ולא הרגע: דחייה "ביום האירוע" נוחתת ב-09:00 על
    // תאריך האירוע עצמו, ו-isBefore היה משאיר אותה עומדת.
    final skipped = activeSkip(event, from: now);
    if (skipped != null) {
      final skipDay = DateTime(skipped.year, skipped.month, skipped.day);
      reminders.removeWhere(
          (d) => !DateTime(d.year, d.month, d.day).isAfter(skipDay));
    }
    return reminders;
  }

  /// הדילוג שהמשתמש ביקש, אם הוא עדיין תקף – כלומר התאריך טרם חלף.
  ///
  /// **אין כאן בדיקה שהתאריך עדיין תואם מופע של האירוע**, אף שעריכת
  /// התאריך הופכת אותו לחסר משמעות. ניסיתי זאת ונסוגתי: הערך מגיע
  /// מה-payload של ההתראה כמילישניות, וההשוואה היא מול חצות מקומית –
  /// מעבר שעון קיץ בין הרגעים מזיז את אחד הצדדים ביום, והדילוג היה
  /// נדחה בשקט דווקא אחרי שהמשתמש ביקש אותו. ניקוי בעריכה (ראה
  /// EventNotifier.updateEvent) פותר את אותה בעיה בלי להשוות תאריכים
  /// משני מקורות.
  ///
  /// אין מנגנון ניקוי לפקיעה עצמה: סימון שחלף פשוט מפסיק לחול.
  DateTime? activeSkip(Event event, {DateTime? from}) {
    final at = event.skippedEventAt;
    if (at == null) return null;

    final now = from ?? _now();
    // רכיבי תאריך ולא Duration – ראה הכלל בראש הקובץ.
    return DateTime(at.year, at.month, at.day)
            .isBefore(DateTime(now.year, now.month, now.day))
        ? null
        : at;
  }

  /// האם המשתמש ביקש לדלג על המופע הקרוב. ראה [activeSkip].
  bool isYearSkipped(Event event, {DateTime? from}) =>
      activeSkip(event, from: from) != null;

  /// מועד תזכורת שחלף אך טרם נמסר, או null אם אין כזה.
  ///
  /// מחזיר ערך רק כשהתזכורת של המופע **הקרוב** כבר עברה בעוד האירוע עצמו
  /// לפנינו – החלון בן 5 עד 11 הימים שבו יום השלישי חלף. במצב כזה עדיף
  /// להציג את התזכורת באיחור מאשר לדלג עליה.
  ///
  /// [Event.lastNotifiedAt] הוא המועד האחרון שכבר טופל; אם הוא זהה למועד
  /// שחלף, אין מה להשלים.
  DateTime? missedReminderDate(Event event, {DateTime? from}) {
    final now = from ?? _now();

    // מופע שדולג עליו אינו החמצה. בלי השורה הזו ההשלמה הייתה מגישה
    // אותו מיד בפתיחה הבאה – כלומר מבטלת את הבחירה שזה עתה נעשתה.
    if (activeSkip(event, from: now) != null) return null;

    final occurrence = nextOccurrence(event, from: now);
    if (occurrence == null) return null;

    final reminder = _reminderForEventDate(event, occurrence.gregorian);
    if (!reminder.isBefore(now)) return null; // עוד לא הגיע – יטופל בתזמון

    final last = event.lastNotifiedAt;
    if (last != null && !last.isBefore(reminder)) return null; // כבר נמסר

    return reminder;
  }

  /// תאריך האירוע שאליו שייך מועד תזכורת נתון, או null אם לא נמצא.
  ///
  /// נחוץ כדי לבנות את טקסט ההתראה בזמן התזמון: לכל מופע יש תאריך משלו,
  /// וההתראה נכתבת שנים מראש.
  DateTime? eventDateForReminder(
    Event event,
    DateTime reminder, {
    int years = scheduleHorizonYears,
  }) {
    final startYear = _yearOf(
        DateTime(reminder.year, reminder.month, reminder.day), event.calendar);

    // התזכורת קודמת לאירוע, ולכן היא עשויה ליפול בשנה שלפניו.
    for (int offset = 0; offset <= years + 1; offset++) {
      final candidate = _occurrenceForYear(event, startYear + offset);
      if (candidate == null) continue;
      if (!candidate.isBefore(
          DateTime(reminder.year, reminder.month, reminder.day))) {
        return candidate;
      }
    }
    return null;
  }

  /// תיאור האירוע לטקסט התראה: יום בשבוע, תאריך לועזי, וכמה ימים נותרו.
  ///
  /// [reminderDate] הוא מועד הירי – מספר הימים נמדד ממנו ולא מ"עכשיו",
  /// כי ההתראה מתוזמנת שנים מראש והטקסט נקבע בזמן התזמון.
  String describeEventForReminder(
    Event event,
    DateTime reminderDate,
    DateTime eventDate,
  ) {
    // בונה את השם ידנית ולא דרך hebrewWeekdayLabel, בכוונה: הטקסט הזה נצרב
    // ב-payload של התראות שכבר מתוזמנות, ולכן שינוי שלו מחייב העלאת
    // payloadVersion ותזמון מחדש של כל התור. אל "תסדר" את זה.
    final weekday = hebrewWeekdayNames[eventDate.weekday] ?? '';
    final d = eventDate.day.toString().padLeft(2, '0');
    final mo = eventDate.month.toString().padLeft(2, '0');

    // ב-UTC כדי ששעון קיץ לא יגרע יום.
    final days =
        DateTime.utc(eventDate.year, eventDate.month, eventDate.day)
            .difference(DateTime.utc(
                reminderDate.year, reminderDate.month, reminderDate.day))
            .inDays;

    final countdown = switch (days) {
      <= 0 => 'היום',
      1 => 'מחר',
      2 => 'בעוד יומיים',
      _ => 'בעוד $days ימים',
    };

    return 'יום $weekday $d/$mo/${eventDate.year}, $countdown';
  }

  /// מועד ההתראה עבור [eventDate], לפי כלל התזכורת של האירוע.
  DateTime _reminderForEventDate(Event event, DateTime eventDate) {
    final day = switch (event.reminderMode) {
      ReminderMode.weekdayOfPreviousWeek =>
        weekdayBeforeWeekOf(eventDate, event.reminderValue),
      ReminderMode.fixedDaysBefore => DateTime(
          eventDate.year,
          eventDate.month,
          eventDate.day - event.reminderValue,
        ),
    };

    return DateTime(
      day.year,
      day.month,
      day.day,
      event.notificationHour,
      event.notificationMinute,
    );
  }

  /// יום [weekday] של השבוע שלפני שבוע [eventDate].
  ///
  /// [weekday] לפי [DateTime.weekday] – שלישי = 2. עבור יום ראשון (7) נדרש
  /// טיפול נפרד, כי יום ראשון הוא **תחילת** השבוע ולא סופו.
  ///
  /// גם כאן החשבון על רכיבי התאריך ולא ב-[Duration], מאותה סיבת שעון קיץ.
  DateTime weekdayBeforeWeekOf(DateTime eventDate, int weekday) {
    final sunday = _sundayOfWeek(eventDate);
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
  DateTime tuesdayBeforeWeekOf(DateTime eventDate) =>
      weekdayBeforeWeekOf(eventDate, DateTime.tuesday);

  /// התאריך החוזר של האירוע, **ללא שנה**: י"ד בחשוון, או 14 בנובמבר.
  ///
  /// זהו מה שהאירוע *הוא*. לתאריך של מופע ספציפי ראה [formatNextOccurrence].
  String formatEventDate(Event event) => event.isHebrew
      ? formatHebrewDayMonth(event.day, event.hebrewMonth)
      : formatGregorianDayMonth(event.day, event.month);

  /// באיזו שנה המופע הקרוב – 1 לראשון, 2 לשני וכן הלאה.
  ///
  /// null כששנת הפתיחה אינה ידועה, או אם היא מאוחרת מהמופע הקרוב (נתון
  /// שגוי – עדיף לא להציג מספר מטעה).
  int? anniversaryNumber(Event event, {DateTime? from}) {
    final occurrence = nextOccurrence(event, from: from);
    if (occurrence == null) return null;
    return anniversaryNumberFor(event, occurrence.gregorian);
  }

  /// באיזו שנה **מופע מסוים**, ולא הקרוב.
  ///
  /// נחוץ כדי לצרוב את המספר בטקסט ההתראה: כל מופע מתוזמן בנפרד ושנים
  /// מראש, ו"יום הנישואין ה-25" של השנה הבאה הוא ה-26 בזו שאחריה. שאלה על
  /// המופע הקרוב הייתה נותנת לכל ההתראות את אותו מספר – ולשלוש מהן מספר
  /// שגוי.
  int? anniversaryNumberFor(Event event, DateTime occurrence) {
    final startYear = event.startYear;
    if (startYear == null) return null;

    final n = _yearOf(occurrence, event.calendar) - startYear;
    return n >= 1 ? n : null;
  }

  /// טווח השנים להצגה בבורר שנת הפתיחה, מהחדשה לישנה, בלוח של האירוע.
  ///
  /// מוגבל לעבר: אירוע שכבר קרה לא התחיל בעתיד.
  List<int> startYearChoices(CalendarSystem calendar, {int span = 120}) {
    final current = currentYear(calendar);
    return [for (var y = current; y > current - span; y--) y];
  }

  /// ערכי הגימטריה. אותיות סופיות נספרות כרגילות – בשנים לא נהוג לתת
  /// להן 500–900, ומי שמקליד ת״ש ולא ת״ם מתכוון לאותו דבר.
  static const Map<String, int> _gematria = {
    'א': 1, 'ב': 2, 'ג': 3, 'ד': 4, 'ה': 5, 'ו': 6, 'ז': 7, 'ח': 8, 'ט': 9,
    'י': 10, 'כ': 20, 'ך': 20, 'ל': 30, 'מ': 40, 'ם': 40, 'נ': 50, 'ן': 50,
    'ס': 60, 'ע': 70, 'פ': 80, 'ף': 80, 'צ': 90, 'ץ': 90,
    'ק': 100, 'ר': 200, 'ש': 300, 'ת': 400,
  };

  /// קורא שנה עברית שהוקלדה כטקסט, או null אם אי אפשר לקרוא אותה.
  ///
  /// **סלחני בכוונה**: הרשימה מציגה גימטריה, ולכן זו הצורה שיבוא לאדם
  /// להקליד – אבל מי שיש לו את המספר לא צריך לתרגם אותו בראש. שתי הצורות
  /// מתקבלות:
  ///
  ///     תשפ״ו · התשפ״ו · ה׳תשפ״ו · 5786   ->   5786
  ///
  /// אלף החמישי מושלם כשהוא חסר: מחרוזת שסכומה קטן מאלף היא כתיב מקוצר
  /// (תשפ״ו = 786), וזה הכתיב הרווח. ה׳ פותחת מטופלת במפורש ולא דרך
  /// הסכום, אחרת ה׳תשפ״ו היה יוצא 791 ואז 5791 – שנה שגויה שנראית תקינה.
  ///
  /// מספרים מוחזרים כמות שהם, וזה מה שמאפשר לאותו דיאלוג לשרת גם שנה
  /// לועזית: 1998 הוא 1998.
  int? parseHebrewYear(String? text) {
    if (text == null) return null;
    final raw = text.trim();
    if (raw.isEmpty) return null;

    // מספרים כפי שהם.
    if (RegExp(r'^\d+$').hasMatch(raw)) return int.tryParse(raw);

    // גרשיים, גרש, רווחים ואפוסטרוף אינם נושאים ערך – מוסרים הכול חוץ
    // מאותיות עבריות.
    final letters = raw.replaceAll(RegExp(r'[^א-ת]'), '');
    if (letters.isEmpty) return null;

    var rest = letters;
    var thousands = 0;
    if (rest.length > 1 && rest[0] == 'ה') {
      thousands = 5000;
      rest = rest.substring(1);
    }

    var sum = 0;
    for (final ch in rest.split('')) {
      final v = _gematria[ch];
      if (v == null) return null;
      sum += v;
    }
    if (sum == 0) return null;
    if (thousands == 0 && sum < 1000) thousands = 5000;
    return thousands + sum;
  }

  /// מפרמט שנה עברית בגימטריה, למשל 5786 -> תשפ״ו.
  /// (kosher_dart משמיט את אלף השנים ומשתמש בגרשיים ״.)
  String formatHebrewYear(int hebrewYear) {
    final formatter = HebrewDateFormatter()..hebrewFormat = true;
    return formatter.formatHebrewNumber(hebrewYear);
  }

  /// שנה כפי שמציגים אותה בלוח [calendar]: גימטריה לעברית, ספרות ללועזית.
  String formatYear(CalendarSystem calendar, int year) =>
      calendar == CalendarSystem.hebrew
          ? formatHebrewYear(year)
          : year.toString();

  /// התאריך המלא של המופע הקרוב, כולל שנה.
  /// למשל: כ"ו באב תשפ״ו · 14 בנובמבר 2027.
  ///
  /// **התאריך הוא של המופע בפועל, לא זה שנשמר** – גם היום וגם החודש.
  ///
  /// אירוע שנשמר כ"אדר" סתמי מוצג כ"אדר ב'" בשנה מעוברת. ובאותו אופן,
  /// אירוע בל' בחשוון בשנה שבה חשוון בן 29 מוצג כ-כ"ט בחשוון, ו-29 בפברואר
  /// בשנה שאינה מעוברת מוצג כ-28 – כי שם הוא באמת נופל.
  ///
  /// היום נגזר מהתאריך הלועזי שכבר חושב ולא מחושב שוב, כדי שלא יוכל לסטות
  /// ממנו. השורה הזו היא **המופע**; התאריך החוזר, בלי שנה, מוצג בנפרד
  /// ב-[formatEventDate] וממשיך לומר את מה שהוזן.
  String? formatNextOccurrence(Event event, {DateTime? from}) {
    final occurrence = nextOccurrence(event, from: from);
    if (occurrence == null) return null;

    final g = occurrence.gregorian;
    if (!event.isHebrew) {
      return '${g.day} ב${gregorianMonthName(g.month)} ${g.year}';
    }

    final dayHeb = HebrewNumerals.dayToHebrew(_hebrewDayOf(g));
    return '$dayHeb ב${_monthNameForYear(event, occurrence.year)} '
        '${formatHebrewYear(occurrence.year)}';
  }

  /// שם החודש כפי שהוא באותה שנה: "אדר" סתמי הוא אדר ב' בשנה מעוברת.
  String _monthNameForYear(Event event, int hebrewYear) {
    final month = event.hebrewMonth;
    if (!month.isAdar) return month.hebrewName;
    if (_resolveAdarMonth(hebrewYear, event.adarType) == _adarII) {
      return "אדר ב'";
    }
    return _isHebrewLeapYear(hebrewYear) ? "אדר א'" : 'אדר';
  }

  /// משפט הסבר כשהיום שנשמר אינו קיים בשנת המופע, או null כשהוא כן קיים.
  ///
  /// ל' בחשוון ובכסלו קיים רק בשנים שבהן החודש בן שלושים, ו-29 בפברואר רק
  /// בשנה מעוברת; בשאר השנים המופע נסוג ליום האחרון של החודש. בלי משפט אחד
  /// שאומר זאת, הכרטיס נראה כאילו התאריך שהוזן שונה מעצמו בלי סיבה – ומי
  /// שהזין אותו צריך לדעת שהתזכורת מגיעה יום קודם, ולמה.
  String? adjustedDayNote(Event event, {DateTime? from}) {
    final occurrence = nextOccurrence(event, from: from);
    if (occurrence == null) return null;

    final g = occurrence.gregorian;
    if (!event.isHebrew) {
      if (g.day == event.day && g.month == event.month) return null;
      return '${event.day} ב${gregorianMonthName(event.month)} '
          'אינו קיים ב-${occurrence.year}, ולכן האירוע ב-${g.day}';
    }

    final actual = _hebrewDayOf(g);
    if (actual == event.day) return null;

    final month = _monthNameForYear(event, occurrence.year);
    return '${HebrewNumerals.dayToHebrew(event.day)} ב$month '
        'אינו קיים ב${formatHebrewYear(occurrence.year)}, '
        'ולכן האירוע ב${HebrewNumerals.dayToHebrew(actual)}';
  }

  /// מפרמט תאריך עברי מתוך יום/חודש גולמיים (עבור ה-picker בזמן אמת).
  String formatHebrewDayMonth(int day, HebrewMonth month) =>
      '${HebrewNumerals.dayToHebrew(day)} ב${month.hebrewName}';

  /// מפרמט תאריך לועזי חוזר: "14 בנובמבר".
  String formatGregorianDayMonth(int day, int month) =>
      '$day ב${gregorianMonthName(month)}';

  /// מפרמט תאריך חוזר בכל אחד מהלוחות – עבור תצוגה מקדימה בבורר.
  String formatDayMonth(
    CalendarSystem calendar,
    int day,
    int month, {
    AdarType adarType = AdarType.none,
  }) =>
      calendar == CalendarSystem.hebrew
          ? formatHebrewDayMonth(day, HebrewMonth.fromStorage(month, adarType))
          : formatGregorianDayMonth(day, month);

  /// ממיר תאריך חוזר מלוח אחד לשני.
  ///
  /// **מעבר בין הלוחות חייב להמיר ולא רק להחליף תווית.** "14 בחשוון" ו-"14
  /// בנובמבר" הם שני ימים שונים לגמרי, ומעבר ששומר את המספרים כפי שהם משנה
  /// בשקט את היום שבו האירוע חל – בדיוק סוג הכשל שהאפליקציה הזו כבר שילמה
  /// עליו פעם, כשבורר התאריך גלגל ל' לכ"ט בלי לומר דבר.
  ///
  /// [referenceYear] הוא נקודת העיגון בלוח המקור: ההמרה תלויה בשנה, כי
  /// התאריך העברי נודד בלועזי. השנה שבה הכול התחיל היא העוגן הנכון –
  /// ההמרה של תאריך חתונה שייכת לשנת החתונה – וכשהיא אינה ידועה נופלים
  /// לשנת המופע הקרוב, שהיא התשובה הנכונה ביותר שנותרה.
  /// [year] שבתשובה הוא שנת העיגון **בלוח היעד**, וגם היא נחוצה: שנת
  /// הפתיחה נשמרת בלוח של האירוע, ומעבר שממיר את היום ומשאיר את השנה מותיר
  /// "יום הנישואין ה־-3760" – כלומר מספר שלילי שנעלם בשקט מהכרטיס.
  ({int day, int month, AdarType adarType, int year})? convertDate({
    required CalendarSystem from,
    required CalendarSystem to,
    required int day,
    required int month,
    AdarType adarType = AdarType.none,
    int? referenceYear,
  }) {
    if (from == to) {
      return (
        day: day,
        month: month,
        adarType: adarType,
        year: referenceYear ?? currentYear(to),
      );
    }

    // אירוע זמני, רק כדי לשאול את אותו מנוע המרה שמשרת את כל השאר.
    final probe = Event(
      name: '',
      calendar: from,
      day: day,
      month: month,
      adarType: adarType,
      notificationHour: 0,
      notificationMinute: 0,
      createdAt: DateTime.now(),
    );

    final year = referenceYear ?? nextOccurrence(probe)?.year;
    if (year == null) return null;

    final gregorian = _occurrenceForYear(probe, year);
    if (gregorian == null) return null;

    if (to == CalendarSystem.gregorian) {
      return (
        day: gregorian.day,
        month: gregorian.month,
        adarType: AdarType.none,
        year: gregorian.year,
      );
    }

    final jd = JewishDate();
    jd.setDate(gregorian);
    final kMonth = jd.getJewishMonth();
    final hebrewYear = jd.getJewishYear();

    final (hebrewMonth, type) = switch (kMonth) {
      _adarII => (HebrewMonth.adar, AdarType.adarB),
      _adar => _isHebrewLeapYear(hebrewYear)
          ? (HebrewMonth.adar, AdarType.adarA)
          : (HebrewMonth.adar, AdarType.adar),
      _nissan => (HebrewMonth.nisan, AdarType.none),
      _iyar => (HebrewMonth.iyar, AdarType.none),
      _sivan => (HebrewMonth.sivan, AdarType.none),
      _tammuz => (HebrewMonth.tammuz, AdarType.none),
      _av => (HebrewMonth.av, AdarType.none),
      _elul => (HebrewMonth.elul, AdarType.none),
      _tishrei => (HebrewMonth.tishrei, AdarType.none),
      _cheshvan => (HebrewMonth.cheshvan, AdarType.none),
      _kislev => (HebrewMonth.kislev, AdarType.none),
      _teves => (HebrewMonth.tevet, AdarType.none),
      _ => (HebrewMonth.shevat, AdarType.none),
    };

    return (
      day: jd.getJewishDayOfMonth(),
      month: hebrewMonth.toStorage().baseMonth,
      adarType: type,
      year: hebrewYear,
    );
  }

  /// מספר הימים (שלמים) מהיום ועד המופע הקרוב. אינו שלילי.
  ///
  /// ההפרש נמדד ב-UTC מאותה סיבה כמו ב-[daysUntilReminder]: על תאריכים
  /// מקומיים מעבר שעון קיץ מקצר את ההפרש ו-inDays מעגל כלפי מטה.
  int daysUntilEvent(Event event, {DateTime? from}) {
    final now = from ?? _now();
    final eventDate = nextOccurrenceDate(event, from: from);

    final today = DateTime.utc(now.year, now.month, now.day);
    final target =
        DateTime.utc(eventDate.year, eventDate.month, eventDate.day);
    return target.difference(today).inDays;
  }

  /// האם המופע הקרוב חל בתוך [days] הימים הבאים (כולל היום).
  bool isEventWithin(Event event, int days, {DateTime? from}) =>
      daysUntilEvent(event, from: from) <= days;

  /// מספר הימים (שלמים) מהיום ועד מועד ההתראה. שלילי אם עבר.
  int daysUntilReminder(Event event, {DateTime? from}) {
    final now = from ?? _now();
    // דחייה גוברת על הכלל: היא המועד שבו ההתראה באמת תגיע.
    final reminder = activePostponement(event, from: from) ??
        reminderDate(event, from: from);

    // ההפרש נמדד ב-UTC: על תאריכים מקומיים מעבר שעון קיץ הופך את ההפרש
    // האבסולוטי ל-167 או 169 שעות, ו-inDays היה מעגל כלפי מטה ומחסיר יום.
    final today = DateTime.utc(now.year, now.month, now.day);
    final reminderDay =
        DateTime.utc(reminder.year, reminder.month, reminder.day);
    return reminderDay.difference(today).inDays;
  }
}
