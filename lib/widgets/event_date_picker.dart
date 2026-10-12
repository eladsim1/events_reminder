import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/event_date.dart';
import '../services/event_calendar_service.dart';

/// בורר תאריך חוזר בגלגלי גלילה, לשני הלוחות.
///
/// **אין** שימוש ב-DatePicker של Flutter: הוא בוחר תאריך מלא עם שנה, וכאן
/// אין שנה – יום שנה חוזר הוא יום וחודש בלבד. בורר עם שנה היה מזמין את
/// המשתמש להזין את שנת האירוע במקום שאינו מתכוון אליה.
///
/// הווידג'ט מונע בחירת תאריך שאינו קיים לעולם (ל' באייר, 31 בפברואר) על
/// ידי הגבלת מספר הימים לאורך המרבי של החודש הנבחר – **המרבי על פני
/// השנים**, כי חשוון וכסלו מתחלפים בין 29 ל-30 ופברואר בין 28 ל-29, ותאריך
/// אינו חדל להתקיים בגללן.
///
/// **מעבר בין הלוחות אינו נעשה כאן.** מי שמחליף לוח בונה את הבורר מחדש עם
/// מפתח חדש ועם התאריך שהומר (ראה `EventCalendarService.convertDate`);
/// סנכרון פנימי של הגלגלים אל ערכים שהשתנו מבחוץ הוא בדיוק המקום שבו בורר
/// כזה מתחיל לשקר לגבי מה שנבחר.
class EventDatePicker extends StatefulWidget {
  final CalendarSystem calendar;
  final int initialDay;

  /// החודש ההתחלתי במונחי הלוח: אינדקס [HebrewMonth] לעברי, 1–12 ללועזי.
  final int initialMonth;
  final AdarType initialAdarType;

  final void Function(int day, int month, AdarType adarType) onChanged;

  const EventDatePicker({
    super.key,
    required this.calendar,
    required this.initialDay,
    required this.initialMonth,
    this.initialAdarType = AdarType.none,
    required this.onChanged,
  });

  @override
  State<EventDatePicker> createState() => _EventDatePickerState();
}

/// אפשרות אחת בגלגל החודשים – מה שמוצג, ומה שנשמר.
class _MonthOption {
  const _MonthOption(this.label, this.month, this.adarType);

  final String label;
  final int month;
  final AdarType adarType;
}

class _EventDatePickerState extends State<EventDatePicker> {
  final _calendar = EventCalendarService();

  late List<_MonthOption> _months;
  late int _monthIndex;
  late int _selectedDay;

  late FixedExtentScrollController _dayController;
  late FixedExtentScrollController _monthController;

  @override
  void initState() {
    super.initState();
    _months = _optionsFor(widget.calendar);
    _monthIndex = _indexOf(widget.initialMonth, widget.initialAdarType);
    _selectedDay = widget.initialDay.clamp(1, _daysInSelectedMonth());

    _dayController = FixedExtentScrollController(initialItem: _selectedDay - 1);
    _monthController = FixedExtentScrollController(initialItem: _monthIndex);
  }

  @override
  void dispose() {
    _dayController.dispose();
    _monthController.dispose();
    super.dispose();
  }

  /// החודשים שמוצעים בכל לוח.
  ///
  /// אדר א'/ב' מוצגים תמיד, גם בשנה פשוטה: אירוע שחל באדר א' של שנה
  /// מעוברת הוא עובדה שלא תלויה בשנה שבה ממלאים את הטופס.
  static List<_MonthOption> _optionsFor(CalendarSystem calendar) {
    if (calendar == CalendarSystem.gregorian) {
      return [
        for (var m = 1; m <= 12; m++)
          _MonthOption(gregorianMonthName(m), m, AdarType.none),
      ];
    }
    return [
      for (final m in HebrewMonth.values)
        _MonthOption(
          m.hebrewName,
          m.toStorage().baseMonth,
          m.toStorage().adarType,
        ),
    ];
  }

  int _indexOf(int month, AdarType adarType) {
    final i = _months.indexWhere(
      (o) => o.month == month && o.adarType == adarType,
    );
    if (i >= 0) return i;
    // אדר שנשמר בלי סוג, או חודש מחוץ לטווח: נופלים לראשון שמתאים לחודש.
    final byMonth = _months.indexWhere((o) => o.month == month);
    return byMonth >= 0 ? byMonth : 0;
  }

  _MonthOption get _selected => _months[_monthIndex];

  /// כמה ימים להציע בגלגל.
  ///
  /// האורך המרבי על פני השנים ולא אורך החודש השנה: חשוון וכסלו מתחלפים בין
  /// 29 ל-30 ופברואר בין 28 ל-29, וסינון לפי השנה הנוכחית הסתיר את ל'
  /// בחשוון ואת 29 בפברואר בכל שנה קצרה – וגרוע מכך, גלגל של עריכה היה
  /// מגלגל אירוע קיים כזה בשקט ליום הקודם ומשנה את התאריך בשמירה.
  int _daysInSelectedMonth() => _calendar.maxDaysInMonth(
        calendar: widget.calendar,
        month: _selected.month,
        adarType: _selected.adarType,
      );

  void _emit() {
    widget.onChanged(_selectedDay, _selected.month, _selected.adarType);
  }

  void _onMonthChanged(int index) {
    setState(() {
      _monthIndex = index;
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
    setState(() => _selectedDay = index + 1);
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
              _calendar.formatDayMonth(
                widget.calendar,
                _selectedDay,
                _selected.month,
                adarType: _selected.adarType,
              ),
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
                    itemBuilder: (i) => widget.calendar ==
                            CalendarSystem.hebrew
                        ? HebrewNumerals.dayToHebrew(i + 1)
                        : '${i + 1}',
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
                    itemBuilder: (i) => _months[i].label,
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
              background: theme.colorScheme.primary.withValues(alpha: 0.08),
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
