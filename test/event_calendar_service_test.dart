import 'package:flutter_test/flutter_test.dart';

import 'package:events_app/models/event_date.dart';
import 'package:events_app/models/event.dart';
import 'package:events_app/services/event_calendar_service.dart';

Event _hebrewEvent({
  required int day,
  required HebrewMonth month,
  AdarType adarType = AdarType.none,
  int hour = 9,
  int minute = 0,
}) {
  final storage = month.toStorage();
  return Event(
    id: 1,
    name: 'בדיקה',
    day: day,
    month: storage.baseMonth,
    adarType: adarType == AdarType.none ? storage.adarType : adarType,
    notificationHour: hour,
    notificationMinute: minute,
    createdAt: DateTime(2024, 1, 1),
  );
}

void main() {
  final calendar = EventCalendarService();

  group('isLeapYear', () {
    test('שנים מעוברות ידועות', () {
      // 5784 מעוברת, 5785 אינה, 5787 מעוברת.
      expect(calendar.isLeapYear(5784), isTrue);
      expect(calendar.isLeapYear(5785), isFalse);
      expect(calendar.isLeapYear(5787), isTrue);
    });
  });

  group('isValidHebrewDate', () {
    test("ל' באייר אינו חוקי (אייר בן 29)", () {
      expect(
        calendar.isValidHebrewDate(
          day: 30,
          month: HebrewMonth.iyar,
          adarType: AdarType.none,
        ),
        isFalse,
      );
    });

    test("כ\"ט באייר חוקי", () {
      expect(
        calendar.isValidHebrewDate(
          day: 29,
          month: HebrewMonth.iyar,
          adarType: AdarType.none,
        ),
        isTrue,
      );
    });

    test('יום 0 ויום 31 אינם חוקיים', () {
      expect(
        calendar.isValidHebrewDate(
          day: 0,
          month: HebrewMonth.tishrei,
          adarType: AdarType.none,
        ),
        isFalse,
      );
      expect(
        calendar.isValidHebrewDate(
          day: 31,
          month: HebrewMonth.tishrei,
          adarType: AdarType.none,
        ),
        isFalse,
      );
    });

    test('תשרי בן 30 – יום 30 חוקי', () {
      expect(
        calendar.isValidHebrewDate(
          day: 30,
          month: HebrewMonth.tishrei,
          adarType: AdarType.none,
        ),
        isTrue,
      );
    });
  });

  group('tuesdayBeforeWeekOf – יום שלישי של השבוע שלפני שבוע האירוע', () {
    test('אירוע ביום חמישי -> שלישי של השבוע הקודם', () {
      // חמישי 20/05/2027.
      final eventDate = DateTime(2027, 5, 20);
      expect(eventDate.weekday, DateTime.thursday);

      final reminder = calendar.tuesdayBeforeWeekOf(eventDate);
      // צפוי: שלישי 11/05/2027.
      expect(reminder.weekday, DateTime.tuesday);
      expect(reminder, DateTime(2027, 5, 11));
    });

    test('אירוע ביום ראשון -> שלישי של השבוע הקודם', () {
      // ראשון הוא תחילת השבוע; השבוע הקודם מתחיל ראשון שלפני.
      final eventDate = DateTime(2027, 5, 16); // ראשון
      expect(eventDate.weekday, DateTime.sunday);

      final reminder = calendar.tuesdayBeforeWeekOf(eventDate);
      expect(reminder.weekday, DateTime.tuesday);
      // שבוע האירוע מתחיל 16/05 -> שבוע קודם מתחיל 09/05 -> שלישי 11/05.
      expect(reminder, DateTime(2027, 5, 11));
    });

    test('אירוע ביום שבת -> שלישי של השבוע הקודם', () {
      final eventDate = DateTime(2027, 5, 22); // שבת
      expect(eventDate.weekday, DateTime.saturday);

      final reminder = calendar.tuesdayBeforeWeekOf(eventDate);
      expect(reminder.weekday, DateTime.tuesday);
      // שבוע האירוע: ראשון 16/05 .. שבת 22/05 -> קודם: שלישי 11/05.
      expect(reminder, DateTime(2027, 5, 11));
    });

    test('ההתראה תמיד ביום שלישי', () {
      for (int i = 0; i < 60; i++) {
        final d = DateTime(2027, 1, 1).add(Duration(days: i));
        final reminder = calendar.tuesdayBeforeWeekOf(d);
        expect(reminder.weekday, DateTime.tuesday,
            reason: 'נכשל עבור $d');
      }
    });
  });

  group('nextOccurrenceDate', () {
    test('מחזיר את השנה הבאה אם התאריך כבר עבר', () {
      // אירוע בתשרי (סמוך לראש השנה). נבדוק ממועד מאוחר בשנה.
      final m = _hebrewEvent(day: 10, month: HebrewMonth.tishrei);
      final from = DateTime(2025, 12, 1);
      final next = calendar.nextOccurrenceDate(m, from: from);
      expect(next.isAfter(from) || next.isAtSameMomentAs(from), isTrue);
    });

    test('לא מחזיר תאריך בעבר', () {
      final months = HebrewMonth.values
          .where((mo) => !mo.isAdar || mo == HebrewMonth.adar)
          .toList();
      final from = DateTime(2026, 3, 15);
      for (final mo in months) {
        final maxDay = calendar.daysInHebrewMonth(
          month: mo,
          adarType: mo.toStorage().adarType,
        );
        final m = _hebrewEvent(day: maxDay.clamp(1, 29), month: mo);
        final next = calendar.nextOccurrenceDate(m, from: from);
        final fromDay = DateTime(from.year, from.month, from.day);
        expect(next.isBefore(fromDay), isFalse,
            reason: 'חודש $mo החזיר תאריך בעבר: $next');
      }
    });
  });

  group('אדר א\' ואדר ב\' בשנה מעוברת', () {
    test('אדר א\' ואדר ב\' מפיקים תאריכים לועזיים שונים בשנה מעוברת', () {
      // 5784 מעוברת.
      final adarA = _hebrewEvent(
        day: 10,
        month: HebrewMonth.adarA,
        adarType: AdarType.adarA,
      );
      final adarB = _hebrewEvent(
        day: 10,
        month: HebrewMonth.adarB,
        adarType: AdarType.adarB,
      );

      final from = DateTime(2023, 12, 1); // לפני אדר של 5784 (אביב 2024)
      final dateA = calendar.nextOccurrenceDate(adarA, from: from);
      final dateB = calendar.nextOccurrenceDate(adarB, from: from);

      expect(dateA, isNot(equals(dateB)));
      // אדר א' קודם לאדר ב'.
      expect(dateA.isBefore(dateB), isTrue);
    });

    test('אדר סתמי בשנה מעוברת נופל על אדר ב\' (מנהג נפוץ)', () {
      final adarPlain = _hebrewEvent(
        day: 10,
        month: HebrewMonth.adar,
        adarType: AdarType.adar,
      );
      final adarB = _hebrewEvent(
        day: 10,
        month: HebrewMonth.adarB,
        adarType: AdarType.adarB,
      );

      final from = DateTime(2023, 12, 1);
      final datePlain = calendar.nextOccurrenceDate(adarPlain, from: from);
      final dateB = calendar.nextOccurrenceDate(adarB, from: from);

      expect(datePlain, equals(dateB));
    });
  });

  group('formatEventDate', () {
    test("י\"ד בחשוון", () {
      final m = _hebrewEvent(day: 14, month: HebrewMonth.cheshvan);
      expect(calendar.formatEventDate(m), 'י"ד בחשוון');
    });

    test("א' בניסן", () {
      final m = _hebrewEvent(day: 1, month: HebrewMonth.nisan);
      expect(calendar.formatEventDate(m), "א' בניסן");
    });

    test("ט\"ו בשבט", () {
      final m = _hebrewEvent(day: 15, month: HebrewMonth.shevat);
      expect(calendar.formatEventDate(m), 'ט"ו בשבט');
    });
  });

  group('HebrewNumerals', () {
    test('המרות בסיסיות', () {
      expect(HebrewNumerals.dayToHebrew(1), "א'");
      expect(HebrewNumerals.dayToHebrew(9), "ט'");
      expect(HebrewNumerals.dayToHebrew(10), "י'");
      expect(HebrewNumerals.dayToHebrew(14), 'י"ד');
      expect(HebrewNumerals.dayToHebrew(15), 'ט"ו');
      expect(HebrewNumerals.dayToHebrew(16), 'ט"ז');
      expect(HebrewNumerals.dayToHebrew(20), "כ'");
      expect(HebrewNumerals.dayToHebrew(21), 'כ"א');
      expect(HebrewNumerals.dayToHebrew(30), "ל'");
    });
  });

  group('דילוג על שנה אחת', () {
    // המבחנים האלה הם העיקר: הממשק יכול להציג "לא תוזכר השנה" בעוד
    // התזמון ממשיך לירות, והמשתמש יגלה את זה רק כשההתראה תגיע.
    final now = DateTime(2026, 1, 1);
    final m = _hebrewEvent(day: 10, month: HebrewMonth.tishrei);

    test('המופע שדולג יורד, והבא אחריו נשאר', () {
      final before = calendar.futureReminderDates(m, from: now);
      expect(before, isNotEmpty);
      final skippedEvent = calendar.nextOccurrenceDate(m, from: now);

      final after = calendar.futureReminderDates(
        m.copyWith(skippedEventAt: skippedEvent),
        from: now,
      );

      expect(after.length, before.length - 1,
          reason: 'בדיוק מופע אחד יורד, לא יותר ולא פחות');
      expect(after, isNotEmpty,
          reason: 'השנה הבאה חייבת להישאר – אחרת זה כיבוי ולא דילוג');
      expect(after.first.isAfter(skippedEvent), isTrue);
      // ומה שנשאר הוא בדיוק הזנב של הרשימה המקורית.
      expect(after, before.sublist(1));
    });

    test('ההשלמה בפתיחה לא מגישה מופע שדולג', () {
      // בלי זה הבחירה הייתה מתבטלת מיד: התזכורת חלפה, האירוע עוד לפנינו,
      // וההשלמה הייתה מציגה אותה בפתיחה הבאה.
      final eventDate = calendar.nextOccurrenceDate(m, from: now);
      final reminder = calendar.reminderDate(m, from: now);
      // רגע שבו התזכורת כבר חלפה והאירוע עוד לא.
      final justAfter =
          DateTime(reminder.year, reminder.month, reminder.day + 1);

      expect(calendar.missedReminderDate(m, from: justAfter), isNotNull,
          reason: 'בלי דילוג זהו בדיוק המצב שההשלמה קיימת בשבילו');
      expect(
        calendar.missedReminderDate(
          m.copyWith(skippedEventAt: eventDate),
          from: justAfter,
        ),
        isNull,
      );
    });

    test('הדילוג מפסיק לחול אחרי שהתאריך חלף', () {
      final skipped = DateTime(2026, 3, 10);
      final withSkip = m.copyWith(skippedEventAt: skipped);

      expect(calendar.isYearSkipped(withSkip, from: DateTime(2026, 3, 9)),
          isTrue);
      expect(calendar.isYearSkipped(withSkip, from: DateTime(2026, 3, 10)),
          isTrue, reason: 'ביום האירוע עצמו הדילוג עוד תקף');
      expect(calendar.isYearSkipped(withSkip, from: DateTime(2026, 3, 11)),
          isFalse, reason: 'אין מנגנון ניקוי – הוא חייב לפוג מעצמו');
    });

    test('דילוג גובר על דחייה של אותו מופע', () {
      // שניהם לא אמורים להתקיים יחד (הספק מוחק את הדחייה), אבל הסדר
      // בתוך futureReminderDates הוא מה שמונע מ-insert(0) להחזיר לחיים
      // בדיוק את המופע שהתבקש לדלג עליו.
      final eventDate = calendar.nextOccurrenceDate(m, from: now);
      final both = m.copyWith(
        // דחייה ליום האירוע עצמו – 09:00, מאוחר מחצות של אותו תאריך.
        postponedReminderAt:
            DateTime(eventDate.year, eventDate.month, eventDate.day, 9),
        skippedEventAt: eventDate,
      );

      final dates = calendar.futureReminderDates(both, from: now);
      // הטענה על הערך עצמו ולא על "מאוחר מ-": הדחייה נוחתת ב-09:00 על
      // תאריך האירוע, שהוא אחרי חצות של אותו יום – ולכן isAfter עבר גם
      // כשהסינון היה מושבת. המוטציה היא שחשפה את זה.
      expect(dates, isNot(contains(both.postponedReminderAt)),
          reason: 'הדחייה שרדה את הדילוג');
      expect(dates, isNotEmpty,
          reason: 'השנה הבאה ירדה יחד איתה – זה כבר כיבוי');
    });
  });
}
