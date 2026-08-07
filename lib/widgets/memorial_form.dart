import 'dart:io';

import 'package:flutter/material.dart';

import '../models/hebrew_date.dart';
import '../models/memorial.dart';
import '../services/hebrew_calendar_service.dart';
import 'hebrew_date_picker.dart';

/// תוצאת טופס האזכרה שמוחזרת למסך הקורא.
class MemorialFormResult {
  final String name;
  final int day;
  final HebrewMonth month;
  final int hour;
  final int minute;
  final bool enabled;
  final String? notes;
  final String? cemetery;
  final String? plot;
  final String? photoPath;
  final ReminderMode reminderMode;
  final int reminderValue;
  final int? deathHebrewYear;

  const MemorialFormResult({
    required this.name,
    required this.day,
    required this.month,
    required this.hour,
    required this.minute,
    required this.enabled,
    required this.notes,
    required this.cemetery,
    required this.plot,
    required this.photoPath,
    required this.reminderMode,
    required this.reminderValue,
    required this.deathHebrewYear,
  });
}

/// טופס משותף להוספה ולעריכה של אזכרה.
///
/// אחראי על ולידציה (שם חובה, תאריך עברי חוקי) ומחזיר [MemorialFormResult]
/// דרך [onSubmit]. אינו ניגש ישירות ל-Repository או לשירותים.
class MemorialForm extends StatefulWidget {
  final Memorial? initial;
  final int defaultHour;
  final int defaultMinute;
  final bool showEnabledToggle;
  final void Function(MemorialFormResult result) onSubmit;

  /// בוחר תמונה ומחזיר נתיב מקומי, או null אם המשתמש ביטל.
  ///
  /// מוזרק ולא נקרא ישירות, כדי שהטופס לא ייקשר לפלאגין ויישאר ניתן לבדיקה.
  final Future<String?> Function() photoPicker;

  const MemorialForm({
    super.key,
    this.initial,
    required this.defaultHour,
    required this.defaultMinute,
    this.showEnabledToggle = false,
    required this.onSubmit,
    required this.photoPicker,
  });

  @override
  State<MemorialForm> createState() => _MemorialFormState();
}

class _MemorialFormState extends State<MemorialForm> {
  final _formKey = GlobalKey<FormState>();
  final _calendar = HebrewCalendarService();

  late TextEditingController _nameController;
  late TextEditingController _notesController;
  late TextEditingController _cemeteryController;
  late TextEditingController _plotController;

  late int _day;
  late HebrewMonth _month;
  late TimeOfDay _time;
  late bool _enabled;
  late ReminderMode _reminderMode;
  late int _reminderValue;
  String? _photoPath;
  int? _deathYear;

  @override
  void initState() {
    super.initState();
    final m = widget.initial;
    _nameController = TextEditingController(text: m?.name ?? '');
    _notesController = TextEditingController(text: m?.notes ?? '');
    _cemeteryController = TextEditingController(text: m?.cemetery ?? '');
    _plotController = TextEditingController(text: m?.plot ?? '');
    _day = m?.hebrewDay ?? 1;
    _month = m?.selectedMonth ?? HebrewMonth.tishrei;
    _time = m != null
        ? TimeOfDay(hour: m.notificationHour, minute: m.notificationMinute)
        : TimeOfDay(hour: widget.defaultHour, minute: widget.defaultMinute);
    _enabled = m?.enabled ?? true;
    _photoPath = m?.photoPath;
    _reminderMode = m?.reminderMode ?? ReminderMode.weekdayOfPreviousWeek;
    _reminderValue = m?.reminderValue ?? Memorial.defaultReminderWeekday;
    _deathYear = m?.deathHebrewYear;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    _cemeteryController.dispose();
    _plotController.dispose();
    super.dispose();
  }

  String? _trimmedOrNull(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _pickPhoto() async {
    final picked = await widget.photoPicker();
    if (picked != null && mounted) setState(() => _photoPath = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
    );
    if (picked != null) setState(() => _time = picked);
  }

  bool _validateHebrewDate() {
    final adarType = _month.toStorage().adarType;
    return _calendar.isValidHebrewDate(
      day: _day,
      month: _month,
      adarType: adarType,
    );
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (!_validateHebrewDate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'התאריך ${_calendar.formatHebrewDayMonth(_day, _month)} אינו קיים. בחר תאריך אחר.',
          ),
        ),
      );
      return;
    }

    widget.onSubmit(
      MemorialFormResult(
        name: _nameController.text.trim(),
        day: _day,
        month: _month,
        hour: _time.hour,
        minute: _time.minute,
        enabled: _enabled,
        notes: _trimmedOrNull(_notesController),
        cemetery: _trimmedOrNull(_cemeteryController),
        plot: _trimmedOrNull(_plotController),
        photoPath: _photoPath,
        reminderMode: _reminderMode,
        reminderValue: _reminderValue,
        deathHebrewYear: _deathYear,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Scaffold אינו מוסיף ריווח תחתון לגוף המסך, ולכן הפריט האחרון בגלילה
    // יושב מתחת לסרגל הניווט של המערכת ולחצני השמירה/ביטול מתנגשים בו.
    // paddingOf מחזיר את ה-safe area בפועל, ומתאפס כשהמקלדת פתוחה –
    // שם ה-Scaffold ממילא מכווץ את הגוף.
    final bottomSafeArea = MediaQuery.paddingOf(context).bottom;

    return Form(
      key: _formKey,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + bottomSafeArea),
        children: [
          // שם הנפטר (חובה).
          TextFormField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'שם הנפטר *',
              prefixIcon: Icon(Icons.person_outline),
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'יש להזין שם';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),

          Text('תאריך עברי *', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: HebrewDatePicker(
                initialDay: _day,
                initialMonth: _month,
                onChanged: (day, month) {
                  setState(() {
                    _day = day;
                    _month = month;
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: 20),

          // שנת הפטירה – אופציונלית. אזכרות רבות נשמרות לפי יום השנה בלבד,
          // ולכן "לא ידועה" חייבת להישאר אפשרות לגיטימית ולא ברירת מחדל
          // שגויה כלשהי.
          DropdownButtonFormField<int?>(
            initialValue: _deathYear,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'שנת הפטירה',
              prefixIcon: Icon(Icons.history_outlined),
              border: OutlineInputBorder(),
              helperText: 'לא חובה. מאפשר לדעת באיזו שנה האזכרה',
            ),
            items: [
              const DropdownMenuItem<int?>(
                value: null,
                child: Text('לא ידועה'),
              ),
              for (final y in _calendar.deathYearChoices())
                DropdownMenuItem<int?>(
                  value: y,
                  child: Text(_calendar.formatHebrewYear(y)),
                ),
            ],
            onChanged: (v) => setState(() => _deathYear = v),
          ),
          const SizedBox(height: 20),

          // מועד ההתראה – ברירת המחדל היא יום שלישי של השבוע שלפני.
          Text('מועד ההתראה *', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ReminderMode>(
            segments: const [
              ButtonSegment(
                value: ReminderMode.weekdayOfPreviousWeek,
                label: Text('יום בשבוע שלפני'),
              ),
              ButtonSegment(
                value: ReminderMode.fixedDaysBefore,
                label: Text('מספר ימים לפני'),
              ),
            ],
            selected: {_reminderMode},
            onSelectionChanged: (s) => setState(() {
              _reminderMode = s.first;
              // כל מצב מפרש reminderValue אחרת, ולכן מאפסים לברירת מחדל
              // סבירה במקום לגרור מספר חסר משמעות.
              _reminderValue =
                  _reminderMode == ReminderMode.weekdayOfPreviousWeek
                      ? Memorial.defaultReminderWeekday
                      : 7;
            }),
          ),
          const SizedBox(height: 12),
          if (_reminderMode == ReminderMode.weekdayOfPreviousWeek)
            DropdownButtonFormField<int>(
              initialValue: _reminderValue,
              decoration: const InputDecoration(
                labelText: 'יום בשבוע',
                prefixIcon: Icon(Icons.event_repeat),
                border: OutlineInputBorder(),
                helperText: 'בשבוע שלפני שבוע האזכרה',
              ),
              items: [
                for (final e in hebrewWeekdayNames.entries)
                  DropdownMenuItem(value: e.key, child: Text('יום ${e.value}')),
              ],
              onChanged: (v) =>
                  setState(() => _reminderValue = v ?? _reminderValue),
            )
          else
            DropdownButtonFormField<int>(
              initialValue: _reminderValue,
              decoration: const InputDecoration(
                labelText: 'כמה ימים לפני',
                prefixIcon: Icon(Icons.timelapse),
                border: OutlineInputBorder(),
                helperText: 'מרווח קבוע, ללא תלות ביום בשבוע',
              ),
              items: [
                for (final d in const [1, 2, 3, 5, 7, 10, 14, 21, 30])
                  DropdownMenuItem(value: d, child: Text('$d ימים')),
              ],
              onChanged: (v) =>
                  setState(() => _reminderValue = v ?? _reminderValue),
            ),
          const SizedBox(height: 20),

          // שעת התזכורת (חובה).
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            leading: const Icon(Icons.access_time),
            title: const Text('שעת התזכורת *'),
            trailing: Text(
              _time.format(context),
              style: theme.textTheme.titleMedium,
            ),
            onTap: _pickTime,
          ),
          const SizedBox(height: 16),

          if (widget.showEnabledToggle) ...[
            SwitchListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('התראה מופעלת'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            const SizedBox(height: 16),
          ],

          // מיקום הקבר – שדות מסודרים, כדי שאפשר יהיה לנווט אליהם.
          Text('מיקום הקבר', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextFormField(
            controller: _cemeteryController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'בית עלמין',
              hintText: 'לדוגמה: ירקון',
              prefixIcon: Icon(Icons.location_city_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _plotController,
            decoration: const InputDecoration(
              labelText: 'גוש / חלקה / שורה',
              hintText: "לדוגמה: גוש ה', חלקה 12, שורה 4",
              prefixIcon: Icon(Icons.place_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),

          // תמונת הנפטר.
          Text('תמונה', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            leading: _photoPath == null
                ? const Icon(Icons.add_a_photo_outlined)
                : CircleAvatar(
                    radius: 20,
                    backgroundImage: FileImage(File(_photoPath!)),
                  ),
            title: Text(_photoPath == null ? 'בחירת תמונה' : 'החלפת תמונה'),
            subtitle: _photoPath == null
                ? const Text('נשמרת במכשיר בלבד, ואינה נכללת בגיבוי')
                : null,
            trailing: _photoPath == null
                ? null
                : IconButton(
                    tooltip: 'הסרת התמונה',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _photoPath = null),
                  ),
            onTap: _pickPhoto,
          ),
          const SizedBox(height: 20),

          // הערות (אופציונלי).
          TextFormField(
            controller: _notesController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'הערות',
              alignLabelWithHint: true,
              prefixIcon: Icon(Icons.note_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),

          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('ביטול'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submit,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('שמירה'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
