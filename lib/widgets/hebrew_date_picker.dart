import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/hebrew_date.dart';
import '../services/hebrew_calendar_service.dart';

/// בורר תאריך עברי ייעודי (יום + חודש) באמצעות גלגלי גלילה.
///
/// **אין** שימוש ב-DatePicker הלועזי של Flutter.
/// הווידג'ט מונע בחירת תאריך שאינו קיים לעולם (למשל ל' באייר) על ידי
/// הגבלת מספר הימים לאורך המרבי של החודש הנבחר – המרבי על פני השנים, כי
/// חשוון וכסלו מתחלפים בין 29 ל-30 ותאריך אינו חדל להתקיים בגללן.
class HebrewDatePicker extends StatefulWidget {
  final int initialDay;
  final HebrewMonth initialMonth;
  final void Function(int day, HebrewMonth month) onChanged;

  const HebrewDatePicker({
    super.key,
    required this.initialDay,
    required this.initialMonth,
    required this.onChanged,
  });

  @override
  State<HebrewDatePicker> createState() => _HebrewDatePickerState();
}

class _HebrewDatePickerState extends State<HebrewDatePicker> {
  final _calendar = HebrewCalendarService();

  late int _selectedDay;
  late HebrewMonth _selectedMonth;

  late FixedExtentScrollController _dayController;
  late FixedExtentScrollController _monthController;

  /// רשימת החודשים המוצגים. אדר א'/ב' מוצגים תמיד; המשתמש אחראי
  /// לבחור נכון, והתקינות נאכפת מול השנה בעת השמירה.
  static const _months = HebrewMonth.values;

  @override
  void initState() {
    super.initState();
    _selectedMonth = widget.initialMonth;
    _selectedDay = widget.initialDay.clamp(1, _daysInSelectedMonth());

    _dayController =
        FixedExtentScrollController(initialItem: _selectedDay - 1);
    _monthController = FixedExtentScrollController(
      initialItem: _months.indexOf(_selectedMonth),
    );
  }

  @override
  void dispose() {
    _dayController.dispose();
    _monthController.dispose();
    super.dispose();
  }

  /// כמה ימים להציע בגלגל.
  ///
  /// האורך המרבי על פני השנים ולא אורך החודש השנה: חשוון וכסלו מתחלפים
  /// בין 29 ל-30, וסינון לפי השנה הנוכחית הסתיר את ל' בחשוון בכל שנה
  /// קצרה – וגרוע מכך, גלגל עריכה של אזכרה קיימת בתאריך הזה היה מגלגל
  /// אותה בשקט לכ"ט ומשנה את התאריך בשמירה.
  int _daysInSelectedMonth() {
    final adarType = _selectedMonth.toStorage().adarType;
    return _calendar.maxDaysInMonth(
      month: _selectedMonth,
      adarType: adarType,
    );
  }

  void _emit() {
    widget.onChanged(_selectedDay, _selectedMonth);
  }

  void _onMonthChanged(int index) {
    setState(() {
      _selectedMonth = _months[index];
      final maxDay = _daysInSelectedMonth();
      if (_selectedDay > maxDay) {
        // מונע תאריך לא קיים – מצמצם את היום ומגלגל את הבורר.
        _selectedDay = maxDay;
        _dayController.animateToItem(
          _selectedDay - 1,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
    _emit();
  }

  void _onDayChanged(int index) {
    setState(() {
      _selectedDay = index + 1;
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = _daysInSelectedMonth();
    final theme = Theme.of(context);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // תצוגה מקדימה של התאריך הנבחר.
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              _calendar.formatHebrewDayMonth(_selectedDay, _selectedMonth),
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(
            height: 200,
            child: Row(
              children: [
                // גלגל הימים.
                Expanded(
                  child: _WheelColumn(
                    label: 'יום',
                    controller: _dayController,
                    itemCount: daysInMonth,
                    onSelectedItemChanged: _onDayChanged,
                    itemBuilder: (i) => HebrewNumerals.dayToHebrew(i + 1),
                  ),
                ),
                const VerticalDivider(width: 1),
                // גלגל החודשים.
                Expanded(
                  flex: 2,
                  child: _WheelColumn(
                    label: 'חודש',
                    controller: _monthController,
                    itemCount: _months.length,
                    onSelectedItemChanged: _onMonthChanged,
                    itemBuilder: (i) => _months[i].hebrewName,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// עמודת גלגל גלילה בודדת עם כותרת.
class _WheelColumn extends StatelessWidget {
  final String label;
  final FixedExtentScrollController controller;
  final int itemCount;
  final ValueChanged<int> onSelectedItemChanged;
  final String Function(int index) itemBuilder;

  const _WheelColumn({
    required this.label,
    required this.controller,
    required this.itemCount,
    required this.onSelectedItemChanged,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Expanded(
          child: CupertinoPicker(
            scrollController: controller,
            itemExtent: 40,
            onSelectedItemChanged: onSelectedItemChanged,
            selectionOverlay: CupertinoPickerDefaultSelectionOverlay(
              background:
                  theme.colorScheme.primary.withValues(alpha: 0.08),
            ),
            children: List.generate(
              itemCount,
              (i) => Center(
                child: Text(
                  itemBuilder(i),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
