import 'package:flutter/material.dart';

import '../models/event.dart';
import '../models/event_date.dart';
import '../services/event_calendar_service.dart';
import 'confetti.dart';
import 'wedding_rings.dart';

/// כרטיס תצוגה של אירוע בודד במסך הבית.
///
/// מציג: סימן הסוג, השם, התאריך החוזר, המופע הקרוב (לועזי ובלוח של
/// האירוע), מספר השנה, מועד התזכורת והערות.
///
/// **הצבע כאן נושא מידע.** לכל סוג אירוע גוון משלו, והוא זה שמאפשר לזהות
/// יום הולדת מיום נישואין במעבר עין על הרשימה, לפני שקוראים מילה. הגוון
/// אינו נגזר מערכת האפליקציה במכוון: מי שבוחר צבע לאפליקציה אינו מתכוון
/// לשנות את מה שמסמן "יום הולדת".
class EventCard extends StatelessWidget {
  final Event event;
  final EventCalendarService calendar;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  /// נקרא בהקשה על שבב הסוג. null הופך אותו לתווית בלבד.
  final VoidCallback? onChangeKind;

  /// המפתח של שבב הסוג.
  ///
  /// קיים בשביל הבדיקות: השבב יושב בתוך ה-InkWell של הכרטיס, ולכן חיפוש
  /// לפי טקסט מחזיר שני InkWell – והבחירה ביניהם לפי סדר היא בדיוק סוג
  /// השבירות שאין דרך לראות עד שהיא נשברת.
  static const Key kindChipKey = ValueKey('kind-chip');

  /// עד כמה ימים לפני האירוע הכרטיס חוגג – קונפטי וצבע מלא.
  static const int celebrateWithin = 1;

  const EventCard({
    super.key,
    required this.event,
    required this.calendar,
    required this.onTap,
    required this.onToggle,
    this.onChangeKind,
  });

  /// הגוון של כל סוג. מקום אחד, כדי שהכרטיס, הטופס ושורת הסינון לא יראו
  /// שלושה צבעים שונים לאותו סוג.
  ///
  /// הגוונים משמשים כרקע בשקיפות וכמסגרת, ולא כרקע לטקסט: ענבר עם טקסט
  /// לבן אינו קריא, וניגודיות תקינה בשני מצבי התצוגה חשובה יותר מרוויה.
  static Color kindColor(EventKind kind) => switch (kind) {
        EventKind.birthday => const Color(0xFFF9A825),
        EventKind.anniversary => const Color(0xFFE0457B),
        EventKind.engagement => const Color(0xFF7C4DFF),
        EventKind.firstMet => const Color(0xFFD81B60),
        EventKind.other => const Color(0xFF00A6A6),
      };

  /// הסימן של סוג. חשוף כדי שהטופס, הגיליון ושורת הסינון ישתמשו באותו אחד.
  ///
  /// **מצויר, ולא אמוג'י.** האמוג'י שבשדה [EventKind.emoji] מרונדר בגופן של
  /// המערכת: הצורה והצבע הם בחירה של יצרן המכשיר, ובבדיקות ווידג'ט – שבהן
  /// נטען גופן אחד – הוא אינו מרונדר בכלל אלא כמלבן ריק, כך ששום golden לא
  /// היה מראה את מה שהמשתמש רואה. אייקון או ציור נראים אותו דבר בכל מקום.
  /// האמוג'י נשאר לכותרת ההתראה, שם אנדרואיד מרנדר אותו בעצמו.
  ///
  /// [color] ברירת המחדל היא הגוון של הסוג – זה מה שהופך את הסימן לזיהוי
  /// במבט אחד ולא לעוד אייקון אפור.
  static Widget kindMark(EventKind kind, {double size = 18, Color? color}) {
    final tint = color ?? kindColor(kind);
    return switch (kind) {
      EventKind.birthday => Icon(Icons.cake, size: size, color: tint),
      EventKind.anniversary => WeddingRings(size: size, color: tint),
      EventKind.engagement => Icon(Icons.diamond, size: size, color: tint),
      EventKind.firstMet => Icon(Icons.favorite, size: size, color: tint),
      EventKind.other => Icon(Icons.celebration, size: size, color: tint),
    };
  }

  String _daysLabel(int days) {
    // שלילי: מועד התזכורת של השנה הזו כבר חלף אך האירוע עצמו עוד לפנינו.
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

  /// כמה נותר עד האירוע עצמו – בשונה מהספירה עד התזכורת.
  String _untilEventLabel(int days) {
    if (days <= 0) return 'האירוע היום';
    if (days == 1) return 'האירוע מחר';
    if (days == 2) return 'האירוע בעוד יומיים';
    return 'האירוע בעוד $days ימים';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = kindColor(event.kind);

    final dateText = calendar.formatEventDate(event);
    final anniversary = calendar.anniversaryNumber(event);
    final daysToEvent = calendar.daysUntilEvent(event);
    final nextDate = calendar.nextOccurrenceDate(event);
    final nextFull = calendar.formatNextOccurrence(event);
    final adjusted = calendar.adjustedDayNote(event);
    final daysUntil = calendar.daysUntilReminder(event);
    final postponed = calendar.activePostponement(event);
    final skipped = calendar.isYearSkipped(event);

    final dim = !event.enabled;
    // חוגגים רק כשההתראה פעילה: קונפטי על אירוע שכיבו הוא הבטחה שלא תקוים.
    final celebrating = event.enabled && daysToEvent <= celebrateWithin;

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
          child: Stack(
            children: [
              // רקע בגוון הסוג. בשקיפות נמוכה כדי שיעבוד גם במצב כהה בלי
              // לפגוע בקריאות – צבע מלא כאן היה הופך כל טקסט לבעיה.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.topStart,
                      end: AlignmentDirectional.bottomEnd,
                      colors: [
                        color.withValues(alpha: celebrating ? 0.22 : 0.10),
                        color.withValues(alpha: 0.02),
                      ],
                    ),
                  ),
                ),
              ),
              // קונפטי רק ביום האירוע ובערב שלפניו. תמיד – היה נוי קבוע
              // שאינו אומר דבר; כאן הוא הסימן שמשהו קורה עכשיו.
              if (celebrating)
                const Positioned(
                  top: 0,
                  right: 0,
                  left: 0,
                  height: 72,
                  child: Confetti(count: 18, opacity: 0.55),
                ),
              // פס בגוון הסוג בקצה הכרטיס. הוא מה שנקרא ראשון בגלילה
              // מהירה, לפני הסימן ולפני הטקסט.
              //
              // PositionedDirectional ולא רכיב ראשון ב-Row: ב-Row הוא היה
              // מקבל גובה אפס (יישור מרכזי מצמיד אותו לגובה התוכן שאין לו),
              // ו-CrossAxisAlignment.stretch בתוך Stack מבקש גובה אין-סופי
              // ומפיל את הפריסה. כאן הוא נמתח לגובה התוכן, וזה בדיוק הרצוי.
              PositionedDirectional(
                start: 0,
                top: 0,
                bottom: 0,
                width: 6,
                child: ColoredBox(color: color),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 14, 10, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _KindAvatar(kind: event.kind),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                event.name,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                dateText,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.75),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: event.enabled,
                          onChanged: onToggle,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _KindChip(kind: event.kind, onTap: onChangeKind),
                        const SizedBox(width: 8),
                        // תווית הלוח מוצגת רק ללועזי: העברי הוא
                        // ברירת המחדל, ותג על כל שורה אינו מסמן דבר.
                        if (!event.isHebrew)
                          _Tag(
                            text: event.calendar.label,
                            color: theme.colorScheme.outline,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _InfoRow(
                      icon: Icons.event,
                      label: 'האירוע הקרוב',
                      value: hebrewDayAndDate(nextDate),
                    ),
                    const SizedBox(height: 6),
                    _InfoRow(
                      icon: Icons.hourglass_bottom_outlined,
                      label: 'זמן שנותר',
                      value: _untilEventLabel(daysToEvent),
                      highlight: daysToEvent <= 1,
                    ),
                    // התאריך העברי של המופע הקרוב – ורק לאירוע עברי.
                    //
                    // באירוע לועזי השורה הזו הייתה חזרה על "האירוע הקרוב"
                    // שמעליה: אותו יום, אותו חודש, והשנה כבר כתובה שם. שורה
                    // שאינה מוסיפה דבר אינה מידע אלא רעש. מה שכן שונה שם –
                    // 29 בפברואר שנסוג ל-28 – נאמר בשורת ההסבר שמתחת.
                    if (nextFull != null && event.isHebrew) ...[
                      const SizedBox(height: 6),
                      _InfoRow(
                        icon: Icons.calendar_month_outlined,
                        label: 'תאריך עברי',
                        value: nextFull,
                      ),
                    ],
                    // מוצג רק בשנים שבהן היום שהוזן אינו קיים. בלעדיו
                    // נראה כאילו התאריך שונה בלי סיבה.
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
                    if (anniversary != null) ...[
                      const SizedBox(height: 6),
                      _InfoRow(
                        icon: Icons.cake_outlined,
                        label: 'מספר השנה',
                        value: event.kind.ordinal(anniversary),
                      ),
                    ],
                    const SizedBox(height: 6),
                    _InfoRow(
                      icon: Icons.notifications_active_outlined,
                      label: 'מועד התזכורת',
                      // דילוג לפני דחייה: הוא מבטל אותה, ושורה
                      // שמבטיחה תזכורת שלא תגיע גרועה משורה שאינה
                      // אומרת דבר.
                      value: !event.enabled
                          ? 'ההתראה כבויה'
                          : skipped
                              ? 'לא תוזכר השנה'
                              : postponed != null
                                  ? _postponedLabel(daysUntil)
                                  : _daysLabel(daysUntil),
                      // daysUntilReminder סופר אל המופע הקרוב, שאינו
                      // זה שיגיע כשיש דילוג – בלי !skipped השורה
                      // "לא תוזכר השנה" הייתה מודגשת באדום.
                      highlight:
                          event.enabled && !skipped && daysUntil <= 1,
                    ),
                    // ההערות הן בדיוק המידע שרוצים ביד לפני אירוע
                    // (מה קנינו בשנה שעברה, מי מגיע), ולכן הן מוצגות
                    // ברשימה ולא רק בטופס.
                    if ((event.notes ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _InfoRow(
                        icon: Icons.note_outlined,
                        label: 'הערות',
                        value: event.notes!.trim(),
                        maxLines: 2,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// הסימן של סוג האירוע בעיגול צבעוני.
///
/// עיגול ולא אמוג'י חשוף: אמוג'י על רקע הכרטיס נראה כמו תו שנשתל בטקסט,
/// ובעיגול הוא נקרא כסמל של השורה.
class _KindAvatar extends StatelessWidget {
  const _KindAvatar({required this.kind});

  final EventKind kind;

  @override
  Widget build(BuildContext context) {
    final color = EventCard.kindColor(kind);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [
            color.withValues(alpha: 0.35),
            color.withValues(alpha: 0.12),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Center(child: EventCard.kindMark(kind, size: 24)),
    );
  }
}

/// שבב הסוג: הסימן ושם הסוג.
///
/// הסימן הוא המזהה במבט על הרשימה, והכיתוב לצדו כדי שלא יידרש מקרא.
class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind, this.onTap});

  final EventKind kind;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = EventCard.kindColor(kind);

    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          EventCard.kindMark(kind, size: 14),
          const SizedBox(width: 6),
          Text(
            kind.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return content;

    // InkWell מקונן: הוא בולע את ההקשה כך שהיא אינה מגיעה לכרטיס ופותחת
    // את מסך העריכה. בלי זה הקשה על השבב הייתה עושה את שני הדברים.
    return InkWell(
      key: EventCard.kindChipKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: content,
    );
  }
}

/// תג טקסט קטן ומאופק, לתוויות משנה כמו הלוח שבו האירוע נספר.
class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
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

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.highlight = false,
    this.maxLines = 1,
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
        // Expanded ולא Text חשוף: הערות חופשיות ושורת התאריך המלא ארוכות
        // מספיק כדי לגלוש במכשירים צרים.
        Expanded(
          child: Text(
            value,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
              color: highlight ? theme.colorScheme.primary : null,
            ),
          ),
        ),
      ],
    );
  }
}
