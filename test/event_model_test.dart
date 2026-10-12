import 'package:flutter_test/flutter_test.dart';

import 'package:events_app/models/event_date.dart';
import 'package:events_app/models/event.dart';

void main() {
  group('Event serialization', () {
    test('toMap/fromMap הלוך ושוב', () {
      final m = Event(
        id: 5,
        name: 'דנה',
        day: 14,
        month: HebrewMonth.cheshvan.index,
        adarType: AdarType.none,
        notificationHour: 9,
        notificationMinute: 30,
        enabled: true,
        notes: 'הערה',
        kind: EventKind.birthday,
        startYear: 5756,
        createdAt: DateTime(2024, 5, 1, 12, 0),
      );

      final map = m.toMap();
      final restored = Event.fromMap(map);

      expect(restored.id, m.id);
      expect(restored.name, m.name);
      expect(restored.day, m.day);
      expect(restored.month, m.month);
      expect(restored.adarType, m.adarType);
      expect(restored.notificationHour, m.notificationHour);
      expect(restored.notificationMinute, m.notificationMinute);
      expect(restored.enabled, m.enabled);
      expect(restored.notes, m.notes);
      expect(restored.createdAt, m.createdAt);
      expect(restored.kind, m.kind);
      expect(restored.calendar, CalendarSystem.hebrew,
          reason: 'the default has to survive a round trip too');
      expect(restored.startYear, 5756);
    });

    test('a Gregorian event keeps its calendar and its month number', () {
      final m = Event(
        id: 7,
        name: 'דנה',
        calendar: CalendarSystem.gregorian,
        day: 29,
        month: 2,
        kind: EventKind.birthday,
        startYear: 1996,
        notificationHour: 9,
        notificationMinute: 0,
        createdAt: DateTime(2024, 1, 1),
      );

      final restored = Event.fromJson(m.toJson());
      expect(restored.calendar, CalendarSystem.gregorian);
      expect(restored.isHebrew, isFalse);
      // The same column that holds a HebrewMonth index for a Hebrew event.
      expect(restored.month, 2);
      expect(restored.day, 29);
      expect(restored.startYear, 1996);
    });

    test('the identity key separates the two calendars', () {
      Event at(CalendarSystem c) => Event(
            name: 'דנה',
            calendar: c,
            day: 14,
            month: 1,
            notificationHour: 9,
            notificationMinute: 0,
            createdAt: DateTime(2024, 1, 1),
          );
      // Same name, same numbers, two completely different days.
      expect(at(CalendarSystem.hebrew).identityKey,
          isNot(at(CalendarSystem.gregorian).identityKey));
    });

    test('toJson/fromJson הלוך ושוב עם אדר ב\'', () {
      final m = Event(
        id: 2,
        name: 'אנחנו',
        day: 10,
        month: HebrewMonth.adar.index,
        adarType: AdarType.adarB,
        notificationHour: 8,
        notificationMinute: 0,
        enabled: false,
        notes: null,
        createdAt: DateTime(2024, 1, 1),
      );

      final restored = Event.fromJson(m.toJson());
      expect(restored.adarType, AdarType.adarB);
      expect(restored.hebrewMonth, HebrewMonth.adarB);
      expect(restored.enabled, isFalse);
      expect(restored.notes, isNull);
    });

    test('copyWith עם clearNotes מנקה הערות', () {
      final m = Event(
        name: 'אמא',
        day: 1,
        month: HebrewMonth.nisan.index,
        notificationHour: 9,
        notificationMinute: 0,
        notes: 'קיים',
        createdAt: DateTime(2024, 1, 1),
      );

      final cleared = m.copyWith(clearNotes: true);
      expect(cleared.notes, isNull);

      final changed = m.copyWith(name: 'אמא שלי');
      expect(changed.notes, 'קיים');
      expect(changed.name, 'אמא שלי');
    });
  });

  group('HebrewMonth storage round-trip', () {
    test('אדר סתמי', () {
      final s = HebrewMonth.adar.toStorage();
      expect(s.adarType, AdarType.adar);
      expect(HebrewMonth.fromStorage(s.baseMonth, s.adarType),
          HebrewMonth.adar);
    });

    test("אדר א'", () {
      final s = HebrewMonth.adarA.toStorage();
      expect(s.adarType, AdarType.adarA);
      expect(HebrewMonth.fromStorage(s.baseMonth, s.adarType),
          HebrewMonth.adarA);
    });

    test("אדר ב'", () {
      final s = HebrewMonth.adarB.toStorage();
      expect(s.adarType, AdarType.adarB);
      expect(HebrewMonth.fromStorage(s.baseMonth, s.adarType),
          HebrewMonth.adarB);
    });

    test('חודש רגיל שומר על עצמו', () {
      for (final mo in [
        HebrewMonth.tishrei,
        HebrewMonth.nisan,
        HebrewMonth.elul,
      ]) {
        final s = mo.toStorage();
        expect(s.adarType, AdarType.none);
        expect(HebrewMonth.fromStorage(s.baseMonth, s.adarType), mo);
      }
    });
  });
}
