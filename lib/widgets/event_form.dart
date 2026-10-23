import 'package:flutter/material.dart';

import '../models/event.dart';
import '../models/event_date.dart';
import '../services/event_calendar_service.dart';
import 'event_card.dart';
import 'event_date_picker.dart';

/// מבקש שנה בהקלדה, לשנים שאינן ברשימה.
///
/// מקבל גימטריה או מספרים – ראה [EventCalendarService.parseHebrewYear].
/// מציג את מה שהובן לפני האישור, כי גימטריה קל להקליד בטעות ושנה שגויה
/// אינה נראית שגויה.
class _YearInputDialog extends StatefulWidget {
  const _YearInputDialog({
    required this.calendar,
    required this.system,
    this.initial,
  });

  final EventCalendarService calendar;
  final CalendarSystem system;
  final int? initial;

  @override
  State<_YearInputDialog> createState() => _YearInputDialogState();
}

class _YearInputDialogState extends State<_YearInputDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial == null
        ? ''
        : widget.calendar.formatYear(widget.system, widget.initial!),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// מה שהוקלד, כפי שהובן. null כשאי אפשר לקרוא אותו.
  int? get _parsed => widget.calendar.parseHebrewYear(_controller.text);

  void _confirm() {
    final year = _parsed;
    if (year == null) {
      setState(() => _error = 'לא הצלחתי לקרוא את השנה');
      return;
    }
    // אירוע שכבר קרה לא התחיל בעתיד – אותה מגבלה שיש לרשימה עצמה.
    if (year > widget.calendar.currentYear(widget.system)) {
      setState(() => _error = 'השנה עדיין לא הגיעה');
      return;
    }
    Navigator.of(context).pop(year);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final year = _parsed;
    final hebrew = widget.system == CalendarSystem.hebrew;
    return AlertDialog(
      title: const Text('שנת האירוע'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: hebrew ? 'תשפ״ו או 5786' : '1998',
              helperText: hebrew ? 'בגימטריה או במספרים' : 'ארבע ספרות',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _confirm(),
          ),
          const SizedBox(height: 12),
          // מה שהובן, כפי שיוצג בכרטיס. בלי ההד הזה אי אפשר לדעת אם
          // הגימטריה נקראה כמו שהתכוונת עד שהאירוע כבר נשמר.
          Text(
            year == null
                ? '—'
                : '${widget.calendar.formatYear(widget.system, year)}  ·  $year',
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('ביטול'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('אישור')),
      ],
    );
  }
}

/// תוצאת טופס האירוע שמוחזרת למסך הקורא.
///
/// [month] ו-[adarType] מוחזרים כבר בצורת האחסון – אינדקס חודש עברי או
/// מספר חודש לועזי – כדי שהמסך הקורא לא יצטרך להמיר דבר.
class EventFormResult {
  final String name;
  final EventKind kind;
  final CalendarSystem calendar;
  final int day;
  final int month;
  final AdarType adarType;
  final int? startYear;
  final int hour;
  final int minute;
  final bool enabled;
  final String? notes;
  final ReminderMode reminderMode;
  final int reminderValue;

  const EventFormResult({
    required this.name,
    required this.kind,
    required this.calendar,
    required this.day,
    required this.month,
    required this.adarType,
    required this.startYear,
    required this.hour,
    required this.minute,
    required this.enabled,
    required this.notes,
    required this.reminderMode,
    required this.reminderValue,
  });
}

/// טופס משותף להוספה ולעריכה של אירוע.
///
/// אחראי על ולידציה (שם חובה, תאריך שקיים באיזושהי שנה) ומחזיר
/// [EventFormResult] דרך [onSubmit]. אינו ניגש ישירות ל-Repository או
/// לשירותים.
class EventForm extends StatefulWidget {
  final Event? initial;
  final int defaultHour;
  final int defaultMinute;
  final bool showEnabledToggle;
  final void Function(EventFormResult result) onSubmit;

  const EventForm({
    super.key,
    this.initial,
    required this.defaultHour,
    required this.defaultMinute,
    this.showEnabledToggle = false,
    required this.onSubmit,
  });

  @override
  State<EventForm> createState() => _EventFormState();
}

class _EventFormState extends State<EventForm> {
  final _formKey = GlobalKey<FormState>();
  final _calendar = EventCalendarService();

  late TextEditingController _nameController;
  late TextEditingController _notesController;

  late CalendarSystem _system;
  late int _day;
  late int _month;
  late AdarType _adarType;
  late TimeOfDay _time;
  late bool _enabled;
  late ReminderMode _reminderMode;
  late int _reminderValue;
  int? _startYear;
  late EventKind _kind;

  @override
  void initState() {
    super.initState();
    final e = widget.initial;
    _nameController = TextEditingController(text: e?.name ?? '');
    _notesController = TextEditingController(text: e?.notes ?? '');
    _system = e?.calendar ?? CalendarSystem.hebrew;
    _day = e?.day ?? 1;
    _month = e?.month ??
        (_system == CalendarSystem.hebrew
            ? HebrewMonth.tishrei.index
            : DateTime.now().month);
    _adarType = e?.adarType ?? AdarType.none;
    _time = e != null
        ? TimeOfDay(hour: e.notificationHour, minute: e.notificationMinute)
        : TimeOfDay(hour: widget.defaultHour, minute: widget.defaultMinute);
    _enabled = e?.enabled ?? true;
    _reminderMode = e?.reminderMode ?? ReminderMode.weekdayOfPreviousWeek;
    _reminderValue = e?.reminderValue ?? Event.defaultReminderWeekday;
    _startYear = e?.startYear;
    _kind = e?.kind ?? EventKind.birthday;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String? _trimmedOrNull(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  /// ערך הדמה של "שנה אחרת". שלילי, ולכן לעולם אינו מתנגש בשנה אמיתית.
  static const int _otherYear = -1;

  /// מפתח לשדה השנה, כדי להחזיר אותו למצב שלנו אחרי הדיאלוג.
  ///
  /// DropdownButtonFormField מחזיק ערך פנימי משלו, ו-didUpdateWidget מסנכרן
  /// אותו רק כש-initialValue משתנה. בביטול הדיאלוג הוא אינו משתנה – ובלי
  /// המפתח השדה היה נשאר תקוע על "שנה אחרת…" אף שלא נבחרה שנה.
  final _yearFieldKey = GlobalKey<FormFieldState<int?>>();

  /// השנים שמוצעות ברשימה, בלוח הנבחר.
  ///
  /// הטווח הרגיל, ובנוסף השנה שכבר נבחרה כשהיא מחוצה לו. **בלי התוספת הזו
  /// הרשימה זורקת**: DropdownButtonFormField דורש שהערך יופיע בין הפריטים,
  /// ואירוע שיובא עם שנה רחוקה מ-120 שנה היה מפיל את מסך העריכה כולו.
  List<int> _yearChoices() {
    final years = _calendar.startYearChoices(_system);
    final chosen = _startYear;
    if (chosen != null && !years.contains(chosen)) {
      years.add(chosen);
      years.sort((a, b) => b.compareTo(a));
    }
    return years;
  }

  /// מטפל בבחירה בשדה השנה.
  Future<void> _pickYear(int? value) async {
    if (value != _otherYear) {
      setState(() => _startYear = value);
      return;
    }
    final typed = await showDialog<int>(
      context: context,
      builder: (_) => _YearInputDialog(
        calendar: _calendar,
        system: _system,
        initial: _startYear,
      ),
    );
    if (!mounted) return;
    if (typed != null) setState(() => _startYear = typed);
    // בשני המקרים מיישרים את השדה למצב שלנו: באישור כדי שיציג את השנה
    // החדשה, ובביטול כדי שלא יישאר תקוע על ערך הדמה.
    _yearFieldKey.currentState?.didChange(_startYear);
  }

  /// מחליף את הלוח – **וממיר את התאריך**.
  ///
  /// החלפת תווית בלבד הייתה משנה בשקט את היום שבו האירוע חל: "14 בחשוון"
  /// ו-"14 בנובמבר" הם שני ימים שונים לגמרי. גם שנת האירוע מומרת, אחרת
  /// מספר השנה שמוצג על הכרטיס נעשה חסר משמעות.
  ///
  /// העיגון הוא שנת האירוע כשהיא ידועה – ההמרה של תאריך חתונה שייכת לשנת
  /// החתונה – ואחרת שנת המופע הקרוב.
  void _switchCalendar(CalendarSystem next) {
    if (next == _system) return;

    final converted = _calendar.convertDate(
      from: _system,
      to: next,
      day: _day,
      month: _month,
      adarType: _adarType,
      referenceYear: _startYear,
    );

    setState(() {
      _system = next;
      if (converted != null) {
        _day = converted.day;
        _month = converted.month;
        _adarType = converted.adarType;
        if (_startYear != null) _startYear = converted.year;
      } else {
        // אין תאריך מקביל (מקרה קצה, למשל חודש שאינו קיים): מתחילים
        // מתאריך תקף בלוח החדש במקום להשאיר ערך שאין לו פירוש.
        _day = 1;
        _month =
            next == CalendarSystem.hebrew ? HebrewMonth.tishrei.index : 1;
        _adarType = AdarType.none;
      }
      _yearFieldKey.currentState?.didChange(_startYear);
    });

    // אומרים מה קרה. אותו היגיון כמו בהד של דיאלוג השנה: קלט סלחני חייב
    // להראות איך הוא הובן, ובלי זה ההמרה נראית כמו שינוי שרירותי.
    //
    // קצר בכוונה: ההודעה מרחפת מעל תחתית המסך, ושם יושב כפתור השמירה –
    // ובמסך צר היא מכסה אותו. התצוגה המקדימה שבתוך הבורר, שורה אחת מכאן,
    // מראה את התוצאה ממילא, ולכן די בהבהוב.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('התאריך הומר ל${_formattedDate()}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formattedDate() => _calendar.formatDayMonth(
        _system,
        _day,
        _month,
        adarType: _adarType,
      );

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
    );
    if (picked != null) setState(() => _time = picked);
  }

  /// נבדק מול כל השנים ולא מול השנה הנוכחית.
  ///
  /// ל' בחשוון ו-29 בפברואר קיימים ברוב השנים, ובקצרות התזכורת נסוגה ליום
  /// האחרון של החודש. בדיקה מול השנה הנוכחית בלבד הייתה חוסמת את התאריך
  /// לגמרי, אף שהחישוב תומך בו.
  bool _validateDate() => _calendar.isDateEverValid(
        calendar: _system,
        day: _day,
        month: _month,
        adarType: _adarType,
      );

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (!_validateDate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'התאריך ${_formattedDate()} אינו קיים. בחר תאריך אחר.',
          ),
        ),
      );
      return;
    }

    widget.onSubmit(
      EventFormResult(
        name: _nameController.text.trim(),
        kind: _kind,
        calendar: _system,
        day: _day,
        month: _month,
        adarType: _adarType,
        startYear: _startYear,
        hour: _time.hour,
        minute: _time.minute,
        enabled: _enabled,
        notes: _trimmedOrNull(_notesController),
        reminderMode: _reminderMode,
        reminderValue: _reminderValue,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      // Column ולא ListView לבדו: שורת הפעולות יושבת **מחוץ** לגלילה, כך
      // שהיא נראית תמיד. קודם היא הייתה הפריט האחרון ברשימה, והטופס ארוך
      // מספיק שכדי לשמור היה צריך לגלול עד הסוף – דרך השם, הסוג, הלוח,
      // גלגלי התאריך, השנה, מועד התזכורת, השעה וההערות.
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              children: _fields(theme),
            ),
          ),
          _actionBar(theme),
        ],
      ),
    );
  }

  /// שדות הטופס, בסדר שבו הם נשאלים.
  ///
  /// במתודה נפרדת ולא בתוך build: הרשימה ארוכה, ושורת הפעולות שמתחתיה
  /// נבלעה בה כשהכול היה ברצף אחד.
  List<Widget> _fields(ThemeData theme) {
    return [
      // שם האירוע (חובה).
      TextFormField(
        controller: _nameController,
        decoration: const InputDecoration(
          labelText: 'שם האירוע *',
          hintText: 'דנה · אמא · אנחנו',
          prefixIcon: Icon(Icons.celebration_outlined),
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

      // מיד אחרי השם: הסוג קובע את ניסוח התזכורת ואת הצבע, ולכן הוא
      // השאלה השנייה בחשיבותה.
      Text('סוג האירוע', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      // שבבים ולא רדיו: חמש שורות רדיו הן חצי מסך, וחמישה שבבים
      // נכנסים בשתי שורות – ומראים את הסימן והצבע שיופיעו על הכרטיס,
      // כך שמי שבוחר כאן מזהה אחר כך את האירוע ברשימה בלי ללמוד מחדש.
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final k in EventKind.values)
            ChoiceChip(
              key: ValueKey('kind-${k.name}'),
              // בשבב נבחר הרקע עצמו הוא גוון הסוג, ולכן הסימן ממוזג
              // לכיוון צבע הטקסט – אחרת ענבר על ענבר נעלם.
              avatar: EventCard.kindMark(
                k,
                size: 16,
                color: _kind == k
                    ? Color.lerp(
                        EventCard.kindColor(k),
                        theme.colorScheme.onSurface,
                        0.45,
                      )
                    : null,
              ),
              label: Text(k.label),
              selected: _kind == k,
              selectedColor:
                  EventCard.kindColor(k).withValues(alpha: 0.25),
              onSelected: (_) => setState(() => _kind = k),
            ),
        ],
      ),
      const SizedBox(height: 20),

      // הלוח. עברי הוא ברירת המחדל, ומי שרוצה לועזי מקבל את אותה
      // תזכורת בדיוק – רק שהיא חוזרת לפי התאריך הלועזי.
      Text('לפי איזה לוח *', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      SegmentedButton<CalendarSystem>(
        segments: [
          for (final c in CalendarSystem.values)
            ButtonSegment(value: c, label: Text(c.label)),
        ],
        selected: {_system},
        onSelectionChanged: (s) => _switchCalendar(s.first),
      ),
      const SizedBox(height: 16),

      Text('תאריך האירוע *', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      // חצי רוחב, צמוד לשמאל. גלגלי הבחירה בולעים כל גרירה אנכית
      // שמתחילה עליהם, ולכן בורר שתופס את מלוא הרוחב לא משאיר שום מקום
      // לגלול בו: כל ניסיון לדפדף מעל התאריך שינה אותו. החצי הימני פנוי
      // עכשיו, וזה גם הצד שהאגודל נוחת בו.
      //
      // Alignment.centerLeft ולא AlignmentDirectional.centerStart:
      // התבקש הצד השמאלי הפיזי, ו-start ב-RTL הוא דווקא הימני.
      Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: 0.5,
          child: Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              // המפתח כולל את הלוח: החלפת לוח בונה בורר חדש עם התאריך
              // שהומר, במקום לסנכרן גלגלים קיימים אל ערכים שהשתנו מבחוץ.
              child: EventDatePicker(
                key: ValueKey(_system),
                calendar: _system,
                initialDay: _day,
                initialMonth: _month,
                initialAdarType: _adarType,
                onChanged: (day, month, adarType) {
                  setState(() {
                    _day = day;
                    _month = month;
                    _adarType = adarType;
                  });
                },
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 20),

      // שנת האירוע – אופציונלית. יש אירועים שמציינים בלי לזכור את
      // השנה, ולכן "לא ידועה" חייבת להישאר אפשרות לגיטימית ולא ברירת
      // מחדל שגויה כלשהי.
      DropdownButtonFormField<int?>(
        key: _yearFieldKey,
        initialValue: _startYear,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: 'שנת האירוע',
          prefixIcon: const Icon(Icons.history_outlined),
          border: const OutlineInputBorder(),
          helperText: _kind == EventKind.birthday
              ? 'לא חובה. מאפשר להציג באיזה יום הולדת מדובר'
              : 'לא חובה. מאפשר להציג באיזו שנה האירוע',
          helperMaxLines: 2,
        ),
        items: [
          const DropdownMenuItem<int?>(
            value: null,
            child: Text('לא ידועה'),
          ),
          for (final y in _yearChoices())
            DropdownMenuItem<int?>(
              value: y,
              child: Text(_calendar.formatYear(_system, y)),
            ),
          // בסוף הרשימה ולא בראשה: זו יציאת חירום, לא המסלול הרגיל.
          // הרשימה מכסה 120 שנה, ומי שצריך רחוק מזה נתקע בלי שום דרך
          // להזין את השנה.
          const DropdownMenuItem<int?>(
            value: _otherYear,
            child: Text('שנה אחרת…'),
          ),
        ],
        onChanged: _pickYear,
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
                  ? Event.defaultReminderWeekday
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
            helperText: 'בשבוע שלפני שבוע האירוע',
          ),
          items: [
            for (final wd in reminderWeekdayChoices)
              DropdownMenuItem(
                  value: wd, child: Text(hebrewWeekdayName(wd))),
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

      // הערות (אופציונלי).
      TextFormField(
        controller: _notesController,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: 'הערות',
          hintText: 'מה קנינו בשנה שעברה, מי מגיע, רעיונות למתנה',
          alignLabelWithHint: true,
          prefixIcon: Icon(Icons.note_outlined),
          border: OutlineInputBorder(),
        ),
      ),
    ];
  }

  /// שמירה וביטול, מחוץ לגלילה.
  ///
  /// **ב-EventForm ולא ב-Scaffold של כל מסך**: מסך ההוספה ומסך העריכה
  /// חולקים את הטופס הזה, ונעיצה באחד מהם בלבד הייתה הבדל שאיש לא התכוון
  /// אליו.
  ///
  /// הריווח התחתון עבר לכאן יחד איתה: השורה הזו היא מה שיושב מעל סרגל
  /// הניווט של המערכת עכשיו, ולכן היא זו שמחזיקה את ה-inset. קו עליון ולא
  /// הצללה, כי Material 3 צובע משטח מוגבה – והשורה הייתה הדבר היחיד
  /// באפליקציה שלובש את הגוון הזה.
  Widget _actionBar(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
        child: Row(
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
      ),
    );
  }
}
