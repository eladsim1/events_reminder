import 'dart:io';

import 'package:flutter/material.dart';

import '../models/hebrew_date.dart';
import '../models/memorial.dart';
import '../services/hebrew_calendar_service.dart';
import 'magen_david.dart';

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

  /// הסימן של קטגוריה. חשוף כדי שהטופס ושורת הסינון ישתמשו באותו אחד.
  static Widget kindMark(MemorialKind kind, {Color? color, double? size}) =>
      _KindChip.markFor(kind, color: color, size: size);

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

  /// כשהמשתמש דחה את התזכורת, הכרטיס אומר זאת במפורש – אחרת המספר
  /// המוצג היה סותר את מה שהוא בחר בלי הסבר.
  String _postponedLabel(int days) {
    if (days <= 0) return 'נדחתה להיום';
    if (days == 1) return 'נדחתה למחר';
    if (days == 2) return 'נדחתה לעוד יומיים';
    return 'נדחתה לעוד $days ימים';
  }

  /// "יום שני, 10/08/2026" – היום בשבוע שבו תחול האזכרה.
  String _memorialDayLabel(DateTime d) {
    final weekday = hebrewWeekdayNames[d.weekday] ?? '';
    return 'יום $weekday, ${_formatGregorian(d)}';
  }

  /// כמה נותר עד האזכרה עצמה – בשונה מהספירה עד התזכורת.
  String _untilMemorialLabel(int days) {
    if (days <= 0) return 'האזכרה היום';
    if (days == 1) return 'האזכרה מחר';
    if (days == 2) return 'האזכרה בעוד יומיים';
    return 'האזכרה בעוד $days ימים';
  }

  /// "האזכרה הראשונה" / "האזכרה ה-7". השנה הראשונה זוכה לניסוח מלא כי היא
  /// המשמעותית ביותר.
  String _yahrzeitLabel(int n) {
    const words = {
      1: 'הראשונה',
      2: 'השנייה',
      3: 'השלישית',
      4: 'הרביעית',
      5: 'החמישית',
      6: 'השישית',
      7: 'השביעית',
      8: 'השמינית',
      9: 'התשיעית',
      10: 'העשירית',
    };
    final word = words[n];
    return word != null ? 'האזכרה $word' : 'האזכרה ה-$n';
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
    final yahrzeitNumber = calendar.yahrzeitNumber(memorial);
    final daysToMemorial = calendar.daysUntilMemorial(memorial);
    final nextDate = calendar.nextMemorialDate(memorial);
    final nextHebrew = calendar.formatNextMemorialHebrewDate(memorial);
    final adjusted = calendar.adjustedDayNote(memorial);
    final daysUntil = calendar.daysUntilReminder(memorial);
    final postponed = calendar.activePostponement(memorial);

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
                Row(
                  children: [
                    Text(
                      hebrewDate,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    // הסימון צמוד לתאריך העברי ולא לשם: הוא מאפיין את
                    // האזכרה, ובמבט על הרשימה הוא נקרא באותה שורה שבה
                    // קוראים מתי היא.
                    if (memorial.kind != MemorialKind.none) ...[
                      const SizedBox(width: 8),
                      _KindChip(kind: memorial.kind),
                    ],
                    if (memorial.deathHebrewYear case final year?) ...[
                      const SizedBox(width: 8),
                      Text(
                        'נפטר בשנת ${calendar.formatHebrewYear(year)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                _InfoRow(
                  icon: Icons.event,
                  label: 'האזכרה הקרובה',
                  value: _memorialDayLabel(nextDate),
                ),
                const SizedBox(height: 6),
                _InfoRow(
                  icon: Icons.hourglass_bottom_outlined,
                  label: 'זמן שנותר',
                  value: _untilMemorialLabel(daysToMemorial),
                  highlight: daysToMemorial <= 1,
                ),
                if (nextHebrew != null) ...[
                  const SizedBox(height: 6),
                  _InfoRow(
                    icon: Icons.calendar_month_outlined,
                    label: 'תאריך עברי',
                    value: nextHebrew,
                  ),
                ],
                // מוצג רק בשנים שבהן היום שהוזן אינו קיים. בלעדיו נראה
                // כאילו התאריך שונה בלי סיבה.
                if (adjusted != null) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 26),
                    child: Text(
                      adjusted,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ],
                if (yahrzeitNumber != null) ...[
                  const SizedBox(height: 6),
                  _InfoRow(
                    icon: Icons.numbers_outlined,
                    label: 'מספר האזכרה',
                    value: _yahrzeitLabel(yahrzeitNumber),
                  ),
                ],
                const SizedBox(height: 6),
                _InfoRow(
                  icon: Icons.notifications_active_outlined,
                  label: 'מועד התזכורת',
                  value: !memorial.enabled
                      ? 'ההתראה כבויה'
                      : postponed != null
                          ? _postponedLabel(daysUntil)
                          : _daysLabel(daysUntil),
                  highlight: memorial.enabled && daysUntil <= 1,
                ),
                if (memorial.hasBurialLocation) ...[
                  const SizedBox(height: 6),
                  _InfoRow(
                    icon: Icons.place_outlined,
                    label: 'מיקום הקבר',
                    // הטקסט אם יש, ואחרת הנקודה עצמה: שורה בלי ערך
                    // הייתה כפתור ניווט בלי הסבר לאן.
                    value: memorial.burialSearchQuery ??
                        memorial.coordinates!.toString(),
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

/// שבב הקטגוריה: אייקון ושם.
///
/// האייקון הוא המזהה במבט על הרשימה – משפחה מול ספר – והכיתוב לצדו כדי
/// שלא יידרש מקרא. צבע מבדיל בין השניים אך אינו נושא את המידע לבדו.
class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});

  final MemorialKind kind;

  /// הסימן של כל קטגוריה. מקום אחד, כדי שהרשימה, הסינון והכרטיס לא יציגו
  /// שלושה דברים שונים לאותה קטגוריה.
  ///
  /// **18 ולא 14**: ל-Material Icons יש משקל שמחזיק גם בגודל קטן, אבל
  /// למגן דוד יש זרועות דקות שנבלעות – בגודל הכרטיס המקורי הוא נראה כנקודה
  /// מוזהבת ולא כצורה. הגודל אחיד לשלוש הקטגוריות כדי שהשורה לא תקפוץ.
  static const double markSize = 18;

  static Widget markFor(MemorialKind kind, {Color? color, double? size}) {
    final s = size ?? markSize;
    return switch (kind) {
      // מצויר ולא אייקון, ובזהב משלו: הצבע כאן אינו נגזר מהערכה, כי זה
      // הרעיון – ראה MagenDavid.
      MemorialKind.tzadik => MagenDavid(size: s),
      MemorialKind.family => Icon(Icons.family_restroom, size: s, color: color),
      MemorialKind.none =>
        Icon(Icons.remove_circle_outline, size: s, color: color),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final family = kind == MemorialKind.family;
    final bg = family
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.tertiaryContainer;
    final fg = family
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onTertiaryContainer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          markFor(kind, color: fg),
          const SizedBox(width: 4),
          Text(
            kind.label,
            style: theme.textTheme.labelSmall?.copyWith(color: fg),
          ),
        ],
      ),
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
