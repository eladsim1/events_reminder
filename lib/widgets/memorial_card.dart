import 'dart:io';

import 'package:flutter/material.dart';

import '../models/memorial.dart';
import '../services/hebrew_calendar_service.dart';

/// כרטיס תצוגה של אזכרה בודדת במסך הבית.
///
/// מציג: תמונת הנפטר (אם קיימת), שמו, התאריך העברי, התאריך הלועזי הקרוב,
/// מועד ההתראה, מספר הימים שנותרו, מיקום הקבר והערות.
class MemorialCard extends StatelessWidget {
  final Memorial memorial;
  final HebrewCalendarService calendar;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  /// נקרא בהקשה על מיקום הקבר. null מסתיר את כפתור הניווט.
  final VoidCallback? onNavigate;

  const MemorialCard({
    super.key,
    required this.memorial,
    required this.calendar,
    required this.onTap,
    required this.onToggle,
    this.onNavigate,
  });

  String _daysLabel(int days) {
    // שלילי: יום השלישי של שבוע-לפני כבר חלף אך האזכרה עצמה עוד לפנינו.
    if (days < 0) return 'התזכורת לשנה זו כבר עברה';
    if (days == 0) return 'התזכורת היום';
    if (days == 1) return 'התזכורת מחר';
    if (days == 2) return 'התזכורת בעוד יומיים';
    return 'התזכורת בעוד $days ימים';
  }

  String _formatGregorian(DateTime d) {
    final day = d.day.toString().padLeft(2, '0');
    final month = d.month.toString().padLeft(2, '0');
    return '$day/$month/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hebrewDate = calendar.formatHebrewDate(memorial);
    final nextDate = calendar.nextMemorialDate(memorial);
    final nextHebrew = calendar.formatNextMemorialHebrewDate(memorial);
    final daysUntil = calendar.daysUntilReminder(memorial);

    final dim = !memorial.enabled;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Opacity(
          opacity: dim ? 0.55 : 1.0,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Portrait(photoPath: memorial.photoPath),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        memorial.name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Switch(
                      value: memorial.enabled,
                      onChanged: onToggle,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  hebrewDate,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 12),
                _InfoRow(
                  icon: Icons.event,
                  label: 'האזכרה הקרובה',
                  // התאריך העברי כאן כולל שנה – בשונה מיום השנה החוזר שמוצג
                  // מתחת לשם, זהו המופע הקונקרטי הקרוב.
                  value: nextHebrew == null
                      ? _formatGregorian(nextDate)
                      : '${_formatGregorian(nextDate)} · $nextHebrew',
                ),
                const SizedBox(height: 6),
                _InfoRow(
                  icon: Icons.notifications_active_outlined,
                  label: 'מועד התזכורת',
                  value: memorial.enabled
                      ? _daysLabel(daysUntil)
                      : 'ההתראה כבויה',
                  highlight: memorial.enabled && daysUntil <= 1,
                ),
                if (memorial.burialSearchQuery case final query?) ...[
                  const SizedBox(height: 6),
                  _InfoRow(
                    icon: Icons.place_outlined,
                    label: 'מיקום הקבר',
                    value: query,
                    maxLines: 2,
                    onAction: onNavigate,
                    actionIcon: Icons.navigation_outlined,
                    actionTooltip: 'ניווט',
                  ),
                ],
                // ההערות הן בדיוק המידע שרוצים ביד לפני אזכרה (טלפון של
                // החברה קדישא וכדומה), ולכן הן מוצגות ברשימה ולא רק בטופס.
                if ((memorial.notes ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _InfoRow(
                    icon: Icons.note_outlined,
                    label: 'הערות',
                    value: memorial.notes!.trim(),
                    maxLines: 2,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// תמונת הנפטר, או נר כברירת מחדל כשאין תמונה.
class _Portrait extends StatelessWidget {
  final String? photoPath;

  const _Portrait({this.photoPath});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = photoPath;

    // הקובץ שמור בתיקייה הפרטית ועלול להיעדר (הסרה, גיבוי שהועבר למכשיר
    // אחר), ולכן בודקים קיום ולא רק אם הנתיב מוגדר.
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return CircleAvatar(
        radius: 24,
        backgroundImage: FileImage(File(path)),
      );
    }

    return CircleAvatar(
      radius: 24,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text('🕯', style: theme.textTheme.titleLarge),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool highlight;
  final int maxLines;

  /// כפתור פעולה בסוף השורה, למשל ניווט למיקום הקבר.
  final VoidCallback? onAction;
  final IconData? actionIcon;
  final String? actionTooltip;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.highlight = false,
    this.maxLines = 1,
    this.onAction,
    this.actionIcon,
    this.actionTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18, color: theme.colorScheme.outline),
        ),
        const SizedBox(width: 8),
        Text('$label: ', style: theme.textTheme.bodyMedium),
        // Expanded ולא Text חשוף: הערות חופשיות ושורת התאריך העברי המלא
        // ארוכות מספיק כדי לגלוש במכשירים צרים.
        Expanded(
          child: Text(
            value,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
              color: highlight ? theme.colorScheme.error : null,
            ),
          ),
        ),
        if (onAction != null && actionIcon != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            tooltip: actionTooltip,
            icon: Icon(actionIcon, size: 20),
            color: theme.colorScheme.primary,
            onPressed: onAction,
          ),
      ],
    );
  }
}
