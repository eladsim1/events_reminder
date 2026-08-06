import 'package:flutter_test/flutter_test.dart';

import 'package:azkarot_app/models/hebrew_date.dart';
import 'package:azkarot_app/models/memorial.dart';

void main() {
  group('Memorial serialization', () {
    test('toMap/fromMap הלוך ושוב', () {
      final m = Memorial(
        id: 5,
        name: 'משה בן יעקב',
        hebrewDay: 14,
        hebrewMonth: HebrewMonth.cheshvan.index,
        adarType: AdarType.none,
        notificationHour: 9,
        notificationMinute: 30,
        enabled: true,
        notes: 'הערה',
        createdAt: DateTime(2024, 5, 1, 12, 0),
      );

      final map = m.toMap();
      final restored = Memorial.fromMap(map);

      expect(restored.id, m.id);
      expect(restored.name, m.name);
      expect(restored.hebrewDay, m.hebrewDay);
      expect(restored.hebrewMonth, m.hebrewMonth);
      expect(restored.adarType, m.adarType);
      expect(restored.notificationHour, m.notificationHour);
      expect(restored.notificationMinute, m.notificationMinute);
      expect(restored.enabled, m.enabled);
      expect(restored.notes, m.notes);
      expect(restored.createdAt, m.createdAt);
    });

    test('toJson/fromJson הלוך ושוב עם אדר ב\'', () {
      final m = Memorial(
        id: 2,
        name: 'שרה',
        hebrewDay: 10,
        hebrewMonth: HebrewMonth.adar.index,
        adarType: AdarType.adarB,
        notificationHour: 8,
        notificationMinute: 0,
        enabled: false,
        notes: null,
        createdAt: DateTime(2024, 1, 1),
      );

      final restored = Memorial.fromJson(m.toJson());
      expect(restored.adarType, AdarType.adarB);
      expect(restored.selectedMonth, HebrewMonth.adarB);
      expect(restored.enabled, isFalse);
      expect(restored.notes, isNull);
    });

    test('copyWith עם clearNotes מנקה הערות', () {
      final m = Memorial(
        name: 'דוד',
        hebrewDay: 1,
        hebrewMonth: HebrewMonth.nisan.index,
        notificationHour: 9,
        notificationMinute: 0,
        notes: 'קיים',
        createdAt: DateTime(2024, 1, 1),
      );

      final cleared = m.copyWith(clearNotes: true);
      expect(cleared.notes, isNull);

      final changed = m.copyWith(name: 'דוד המלך');
      expect(changed.notes, 'קיים');
      expect(changed.name, 'דוד המלך');
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
