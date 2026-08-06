import 'package:flutter_test/flutter_test.dart';

import 'package:azkarot_app/models/hebrew_date.dart';
import 'package:azkarot_app/models/memorial.dart';
import 'package:azkarot_app/services/hebrew_calendar_service.dart';

Memorial _memorial({
  required int day,
  required HebrewMonth month,
  AdarType adarType = AdarType.none,
  int hour = 9,
  int minute = 0,
}) {
  final storage = month.toStorage();
  return Memorial(
    id: 1,
    name: 'בדיקה',
    hebrewDay: day,
    hebrewMonth: storage.baseMonth,
    adarType: adarType == AdarType.none ? storage.adarType : adarType,
    notificationHour: hour,
    notificationMinute: minute,
    createdAt: DateTime(2024, 1, 1),
  );
}

void main() {
  final calendar = HebrewCalendarService();

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

  group('tuesdayBeforeWeekOf – יום שלישי של השבוע שלפני שבוע האזכרה', () {
    test('אזכרה ביום חמישי -> שלישי של השבוע הקודם', () {
      // חמישי 20/05/2027.
      final memorialDate = DateTime(2027, 5, 20);
      expect(memorialDate.weekday, DateTime.thursday);

      final reminder = calendar.tuesdayBeforeWeekOf(memorialDate);
      // צפוי: שלישי 11/05/2027.
      expect(reminder.weekday, DateTime.tuesday);
      expect(reminder, DateTime(2027, 5, 11));
    });

    test('אזכרה ביום ראשון -> שלישי של השבוע הקודם', () {
      // ראשון הוא תחילת השבוע; השבוע הקודם מתחיל ראשון שלפני.
      final memorialDate = DateTime(2027, 5, 16); // ראשון
      expect(memorialDate.weekday, DateTime.sunday);

      final reminder = calendar.tuesdayBeforeWeekOf(memorialDate);
      expect(reminder.weekday, DateTime.tuesday);
      // שבוע האזכרה מתחיל 16/05 -> שבוע קודם מתחיל 09/05 -> שלישי 11/05.
      expect(reminder, DateTime(2027, 5, 11));
    });

    test('אזכרה ביום שבת -> שלישי של השבוע הקודם', () {
      final memorialDate = DateTime(2027, 5, 22); // שבת
      expect(memorialDate.weekday, DateTime.saturday);

      final reminder = calendar.tuesdayBeforeWeekOf(memorialDate);
      expect(reminder.weekday, DateTime.tuesday);
      // שבוע האזכרה: ראשון 16/05 .. שבת 22/05 -> קודם: שלישי 11/05.
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

  group('nextMemorialDate', () {
    test('מחזיר את השנה הבאה אם התאריך כבר עבר', () {
      // אזכרה בתשרי (סמוך לראש השנה). נבדוק ממועד מאוחר בשנה.
      final m = _memorial(day: 10, month: HebrewMonth.tishrei);
      final from = DateTime(2025, 12, 1);
      final next = calendar.nextMemorialDate(m, from: from);
      expect(next.isAfter(from) || next.isAtSameMomentAs(from), isTrue);
    });

    test('לא מחזיר תאריך בעבר', () {
      final months = HebrewMonth.values
          .where((mo) => !mo.isAdar || mo == HebrewMonth.adar)
          .toList();
      final from = DateTime(2026, 3, 15);
      for (final mo in months) {
        final maxDay = calendar.daysInMonth(
          month: mo,
          adarType: mo.toStorage().adarType,
        );
        final m = _memorial(day: maxDay.clamp(1, 29), month: mo);
        final next = calendar.nextMemorialDate(m, from: from);
        final fromDay = DateTime(from.year, from.month, from.day);
        expect(next.isBefore(fromDay), isFalse,
            reason: 'חודש $mo החזיר תאריך בעבר: $next');
      }
    });
  });

  group('אדר א\' ואדר ב\' בשנה מעוברת', () {
    test('אדר א\' ואדר ב\' מפיקים תאריכים לועזיים שונים בשנה מעוברת', () {
      // 5784 מעוברת.
      final adarA = _memorial(
        day: 10,
        month: HebrewMonth.adarA,
        adarType: AdarType.adarA,
      );
      final adarB = _memorial(
        day: 10,
        month: HebrewMonth.adarB,
        adarType: AdarType.adarB,
      );

      final from = DateTime(2023, 12, 1); // לפני אדר של 5784 (אביב 2024)
      final dateA = calendar.nextMemorialDate(adarA, from: from);
      final dateB = calendar.nextMemorialDate(adarB, from: from);

      expect(dateA, isNot(equals(dateB)));
      // אדר א' קודם לאדר ב'.
      expect(dateA.isBefore(dateB), isTrue);
    });

    test('אדר סתמי בשנה מעוברת נופל על אדר ב\' (מנהג נפוץ)', () {
      final adarPlain = _memorial(
        day: 10,
        month: HebrewMonth.adar,
        adarType: AdarType.adar,
      );
      final adarB = _memorial(
        day: 10,
        month: HebrewMonth.adarB,
        adarType: AdarType.adarB,
      );

      final from = DateTime(2023, 12, 1);
      final datePlain = calendar.nextMemorialDate(adarPlain, from: from);
      final dateB = calendar.nextMemorialDate(adarB, from: from);

      expect(datePlain, equals(dateB));
    });
  });

  group('formatHebrewDate', () {
    test("י\"ד בחשוון", () {
      final m = _memorial(day: 14, month: HebrewMonth.cheshvan);
      expect(calendar.formatHebrewDate(m), 'י"ד בחשוון');
    });

    test("א' בניסן", () {
      final m = _memorial(day: 1, month: HebrewMonth.nisan);
      expect(calendar.formatHebrewDate(m), "א' בניסן");
    });

    test("ט\"ו בשבט", () {
      final m = _memorial(day: 15, month: HebrewMonth.shevat);
      expect(calendar.formatHebrewDate(m), 'ט"ו בשבט');
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
}
