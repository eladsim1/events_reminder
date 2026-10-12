import 'package:flutter/material.dart';

import '../models/event.dart';
import '../providers/event_provider.dart' show ImportMode;
import '../services/event_calendar_service.dart';

/// מה שנבחר לייבא, ומה לעשות איתו.
class ImportChoice {
  final ImportMode mode;
  final List<Event> selected;

  const ImportChoice(this.mode, this.selected);
}

/// בוחר אילו אירועים מהקובץ לייבא, ובאיזה מצב.
///
/// **הכול מסומן בהתחלה.** המקרה הרגיל הוא לייבא את כל הקובץ, ורשימה שמתחילה
/// ריקה הייתה מחייבת עבודה כדי להגיע להתנהגות הצפויה.
///
/// הבדיקה מה קיים ומה חסר רצה **אחרי** הבחירה ורק על מה שנבחר: אין טעם
/// לשאול על התנגשות עם אירוע שהוחלט לא לייבא.
class ImportSelectionDialog extends StatefulWidget {
  const ImportSelectionDialog({
    super.key,
    required this.events,
    required this.calendar,
  });

  final List<Event> events;
  final EventCalendarService calendar;

  @override
  State<ImportSelectionDialog> createState() => ImportSelectionDialogState();
}

class ImportSelectionDialogState extends State<ImportSelectionDialog> {
  late final Set<Event> _selected = widget.events.toSet();

  bool get _all => _selected.length == widget.events.length;

  @override
  Widget build(BuildContext context) {
    final none = _selected.isEmpty;

    return AlertDialog(
      title: const Text('ייבוא נתונים'),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: ListBody(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('בקובץ ${widget.events.length} אירועים. '
                    'בטל סימון של מה שאין לייבא.'),
              ),
              CheckboxListTile(
                value: none ? false : (_all ? true : null),
                tristate: true,
                title: const Text('הכול'),
                onChanged: (_) => setState(() {
                  if (_all) {
                    _selected.clear();
                  } else {
                    _selected.addAll(widget.events);
                  }
                }),
              ),
              const Divider(height: 1),
              for (final m in widget.events)
                CheckboxListTile(
                  value: _selected.contains(m),
                  title: Text(m.name),
                  subtitle: Text(widget.calendar.formatEventDate(m)),
                  onChanged: (on) => setState(() {
                    if (on == true) {
                      _selected.add(m);
                    } else {
                      _selected.remove(m);
                    }
                  }),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('ביטול'),
        ),
        // ההוספה מודגשת והמחיקה לא, ולא להפך: מבין השתיים רק אחת אינה
        // הפיכה, והכיתוב שלה אומר מה היא עושה במקום להסתפק ב"ייבוא".
        TextButton(
          onPressed: none
              ? null
              : () => Navigator.of(context)
                  .pop(ImportChoice(ImportMode.replace, _selected.toList())),
          child: const Text('החלפה (מוחק הכול)'),
        ),
        FilledButton(
          onPressed: none
              ? null
              : () => Navigator.of(context)
                  .pop(ImportChoice(ImportMode.merge, _selected.toList())),
          child: const Text('הוספה'),
        ),
      ],
    );
  }
}
