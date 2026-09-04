import 'dart:io';

import 'package:flutter/material.dart';

import '../models/hebrew_date.dart';
import '../models/coordinates.dart';
import '../models/memorial.dart';
import '../services/hebrew_calendar_service.dart';
import '../services/location_service.dart';
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

  /// נקודת הציון שהוקלדה, אחרי פענוח. null אם השדה ריק.
  final Coordinates? coordinates;
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
    required this.coordinates,
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

  /// קורא את המיקום הנוכחי. מוזרק מאותה סיבה בדיוק.
  ///
  /// null מסתיר את הכפתור – מסך שאין לו שירות מיקום לא צריך להציע אותו.
  final Future<LocationResult> Function()? locationPicker;

  /// פותח ניווט אל נקודה. מוזרק, ו-null מסתיר את הכפתור.
  final Future<bool> Function(Coordinates at)? navigateTo;

  const MemorialForm({
    super.key,
    this.initial,
    required this.defaultHour,
    required this.defaultMinute,
    this.showEnabledToggle = false,
    required this.onSubmit,
    required this.photoPicker,
    this.locationPicker,
    this.navigateTo,
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
  late TextEditingController _coordinatesController;

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
    _coordinatesController =
        TextEditingController(text: m?.coordinates?.toString() ?? '');
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
    _coordinatesController.dispose();
    super.dispose();
  }

  String? _trimmedOrNull(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  bool _locating = false;

  /// הנקודה שבשדה כרגע, או null אם אין בו כזו.
  Coordinates? get _typedPoint =>
      Coordinates.tryParse(_coordinatesController.text);

  /// בודק את הנקודה שהוקלדה בכך שהוא נוסע אליה.
  Future<void> _navigateToTyped() async {
    final at = _typedPoint;
    final navigate = widget.navigateTo;
    if (at == null || navigate == null) return;

    final opened = await navigate(at);
    if (opened || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ווייז אינה זמינה במכשיר')),
    );
  }

  /// ממלא את שדה נקודת הציון מהמיקום הנוכחי.
  ///
  /// כותב לשדה ולא ישירות לתוצאה, כדי שהמשתמש יראה מה נקלט ויוכל לתקן או
  /// לוותר לפני שהוא שומר.
  Future<void> _useCurrentLocation() async {
    final picker = widget.locationPicker;
    if (picker == null || _locating) return;

    setState(() => _locating = true);
    final result = await picker();
    if (!mounted) return;
    setState(() => _locating = false);

    final point = result.point;
    if (point != null) {
      setState(() => _coordinatesController.text = point.toString());
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_locationMessage(result.failure!))),
    );
  }

  /// הודעה לכל סוג כשל בנפרד: כל אחד מהם נפתר במקום אחר.
  String _locationMessage(LocationFailure failure) => switch (failure) {
        LocationFailure.serviceOff =>
          'המיקום כבוי במכשיר. יש להפעיל אותו ולנסות שוב',
        LocationFailure.denied => 'ללא הרשאת מיקום אי אפשר לקרוא נקודת ציון',
        LocationFailure.deniedForever =>
          'הרשאת המיקום נדחתה לצמיתות. יש לאשר אותה בהגדרות המכשיר',
        LocationFailure.unavailable =>
          'לא הצלחתי לקבל מיקום. בתוך מבנה הקליטה חלשה',
      };

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
        coordinates: Coordinates.tryParse(_coordinatesController.text),
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
                for (final wd in reminderWeekdayChoices)
                  DropdownMenuItem(value: wd, child: Text('יום ${hebrewWeekdayNames[wd]}')),
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
                for (final d in daysBeforeChoices)
                  DropdownMenuItem(value: d, child: Text(daysBeforeLabel(d))),
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
          const SizedBox(height: 12),

          // נקודת ציון. שדה טקסט ולא בורר מפה: בורר דורש מפתח API ותלות
          // כבדה, ובפועל אנשים לא מקלידים קואורדינטות אלא מדביקים אותן.
          TextFormField(
            controller: _coordinatesController,
            keyboardType: TextInputType.text,
            decoration: InputDecoration(
              labelText: 'נקודת ציון',
              hintText: '31.768300, 35.213700',
              helperText: 'הדבקה מוויז או מ-Google Maps. מביא לקבר עצמו',
              helperMaxLines: 2,
              prefixIcon: const Icon(Icons.my_location_outlined),
              border: const OutlineInputBorder(),
            ),
            // בלי זה הכפתור לא היה מתעורר בהקלדה: מצבו נגזר מהטקסט.
            onChanged: (_) => setState(() {}),
            validator: (v) {
              final text = v?.trim() ?? '';
              if (text.isEmpty) return null;
              // שדה לא חובה, אבל ערך שאינו נקרא הוא כפתור ניווט שיוביל
              // לשום מקום – עדיף לומר זאת כאן.
              return Coordinates.tryParse(text) == null
                  ? 'לא זוהתה נקודת ציון'
                  : null;
            },
          ),
          if (widget.locationPicker != null || widget.navigateTo != null) ...[
            const SizedBox(height: 8),
            // Wrap ולא Row: שני כפתורים מתויגים בעברית אינם נכנסים בשורה
            // אחת במסך צר, ו-Row היה גולש.
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (widget.locationPicker != null)
                  TextButton.icon(
                    // מנוטרל בזמן הקריאה ולא רק מוצג עם מחוון: לחיצה שנייה
                    // הייתה מפעילה קריאה מקבילה שתדרוס את הראשונה.
                    onPressed: _locating ? null : _useCurrentLocation,
                    icon: _locating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.gps_fixed),
                    label: Text(
                        _locating ? 'מאתר מיקום...' : 'השתמש במיקום הנוכחי'),
                  ),
                if (widget.navigateTo != null)
                  // כפתור מתויג ומודגש, ולא אייקון בתוך השדה: אייקון עם
                  // tooltip אינו ניתן לגילוי במגע, ולכן שום דבר לא אמר מה
                  // הוא עושה. הכיתוב אומר גם לאן וגם באיזו אפליקציה.
                  FilledButton.tonalIcon(
                    onPressed: _typedPoint == null ? null : _navigateToTyped,
                    icon: const Icon(Icons.navigation),
                    label: const Text('נסיעה לנקודה בוויז'),
                  ),
              ],
            ),
          ],
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
