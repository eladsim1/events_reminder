import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memorial.dart';
import '../providers/memorial_provider.dart';
import '../services/notification_service.dart';

/// מסך הגדרות.
///
/// מאפשר: קביעת שעת ברירת מחדל להתראות, ייצוא הנתונים לקובץ JSON,
/// וייבוא מקובץ JSON.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _pickDefaultTime(
      BuildContext context, WidgetRef ref) async {
    final current = ref.read(defaultReminderTimeProvider);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
    );
    if (picked != null) {
      ref.read(defaultReminderTimeProvider.notifier).state =
          DefaultReminderTime(picked.hour, picked.minute);
    }
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    try {
      final memorials =
          await ref.read(memorialRepositoryProvider).getAll();
      final photos = ref.read(photoStoreProvider);

      final jsonList = <Map<String, dynamic>>[];
      var withPhoto = 0;
      for (final m in memorials) {
        final map = m.toJson();
        // הנתיב המקומי חסר משמעות במכשיר אחר; התמונה עצמה נוסעת מוטמעת.
        map.remove('photo_path');
        final data = await photos.readAsBase64(m.photoPath);
        if (data != null) {
          map['photo_data'] = data;
          withPhoto++;
        }
        jsonList.add(map);
      }
      final jsonStr = const JsonEncoder.withIndent('  ').convert(jsonList);

      // חובה לתת למשתמש לבחור את היעד דרך דיאלוג המערכת.
      // getApplicationDocumentsDirectory מחזיר תיקייה פרטית לאפליקציה
      // (‎/data/user/0/<package>/app_flutter), שבורר הקבצים של אנדרואיד אינו
      // יכול לראות – כלומר הגיבוי לא היה ניתן לאיתור, לשיתוף, או לייבוא,
      // והיה נמחק עם הסרת האפליקציה.
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final saved = await FilePicker.saveFile(
        dialogTitle: 'שמירת גיבוי',
        fileName: 'azkarot_backup_$ts.json',
        bytes: Uint8List.fromList(utf8.encode(jsonStr)),
      );

      if (!context.mounted) return;
      if (saved == null) return; // המשתמש ביטל

      final sizeKb = (jsonStr.length / 1024).round();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${memorials.length} אזכרות נשמרו לגיבוי'
            '${withPhoto > 0 ? ' (כולל $withPhoto תמונות)' : ''}'
            ' · $sizeKb KB',
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה בייצוא: $e')),
        );
      }
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    try {
      // FileType.any ולא custom: סינון לפי סיומת מתורגם באנדרואיד לסינון
      // MIME, וספקי קבצים רבים אינם מדווחים על application/json – התוצאה
      // היא שקובצי הגיבוי מופיעים מעומעמים ולא ניתנים לבחירה. מסננים כאן.
      final result = await FilePicker.pickFiles(
        dialogTitle: 'בחירת קובץ גיבוי',
        type: FileType.any,
      );
      if (result == null || result.files.single.path == null) return;

      final picked = result.files.single;
      if (!picked.name.toLowerCase().endsWith('.json')) {
        throw const FormatException('יש לבחור קובץ בסיומת ‎.json');
      }

      final file = File(picked.path!);
      final content = await file.readAsString();
      final decoded = jsonDecode(content);

      if (decoded is! List) {
        throw const FormatException('מבנה הקובץ אינו תקין');
      }

      final photos = ref.read(photoStoreProvider);
      final memorials = <Memorial>[];
      var restoredPhotos = 0;

      for (final entry in decoded.cast<Map<String, dynamic>>()) {
        var memorial = Memorial.fromJson(entry);
        // התמונה מגיעה מוטמעת; נכתבת מחדש מקומית ומקבלת נתיב של המכשיר הזה.
        final path =
            await photos.restoreFromBase64(entry['photo_data'] as String?);
        if (path != null) {
          memorial = memorial.copyWith(photoPath: path);
          restoredPhotos++;
        }
        memorials.add(memorial);
      }

      // בחירת הקובץ וקריאתו הן פעולות אסינכרוניות – המסך עלול להיסגר
      // בינתיים, ואז showDialog על context מנותק זורק חריגה.
      if (!context.mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('ייבוא נתונים'),
          content: Text(
            'הייבוא יחליף את כל האזכרות הקיימות ב-${memorials.length} אזכרות מהקובץ. להמשיך?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('ביטול'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('ייבוא'),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await ref
            .read(memorialListProvider.notifier)
            .importMemorials(memorials);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'יובאו ${memorials.length} אזכרות'
                '${restoredPhotos > 0 ? ' ו-$restoredPhotos תמונות' : ''}',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה בייבוא: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defaultTime = ref.watch(defaultReminderTimeProvider);
    final timeLabel =
        '${defaultTime.hour.toString().padLeft(2, '0')}:${defaultTime.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(title: const Text('הגדרות')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.access_time),
            title: const Text('שעת ברירת מחדל להתראות'),
            subtitle: const Text('משמשת עבור אזכרות חדשות'),
            trailing: Text(timeLabel,
                style: Theme.of(context).textTheme.titleMedium),
            onTap: () => _pickDefaultTime(context, ref),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('ייצוא הנתונים'),
            subtitle: const Text('שמירת גיבוי לקובץ JSON'),
            onTap: () => _export(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('ייבוא נתונים'),
            subtitle: const Text('שחזור מקובץ JSON (מחליף את הקיים)'),
            onTap: () => _import(context, ref),
          ),
          const Divider(),
          const _ScheduledReminders(),
          const _BackgroundRefreshStatus(),
        ],
      ),
    );
  }
}

/// מתי רץ הרענון השבועי, ומה קרה בו.
///
/// העבודה רצה ב-isolate נפרד, ולכן שדה בזיכרון לעולם לא יגיע לכאן – ובלי
/// התצוגה הזו עבודה שנכשלת כל שבוע אינה נראית משום מקום.
class _BackgroundRefreshStatus extends ConsumerWidget {
  const _BackgroundRefreshStatus();

  String _ago(DateTime at) {
    final days = DateTime.now().difference(at).inDays;
    if (days <= 0) return 'היום';
    if (days == 1) return 'אתמול';
    return 'לפני $days ימים';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return FutureBuilder<({DateTime? lastRun, String? lastError})>(
      future: ref.read(memorialRepositoryProvider).backgroundStatus(),
      builder: (context, snapshot) {
        final status = snapshot.data;
        final failed = status?.lastError != null;
        return ListTile(
          leading: const Icon(Icons.autorenew),
          title: const Text('רענון שבועי ברקע'),
          subtitle: Text(
            status == null
                ? 'נבדק...'
                : status.lastRun == null
                    ? 'טרם רץ. אנדרואיד מריץ אותו מתי שנוח לו.'
                    : failed
                        ? 'נכשל ${_ago(status.lastRun!)} — ${status.lastError}'
                        : 'רץ ${_ago(status.lastRun!)}',
            style: failed
                ? theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)
                : theme.textTheme.bodySmall,
          ),
        );
      },
    );
  }
}

/// מה מתוזמן בפועל, לכל אזכרה.
///
/// נראה למשתמש בכוונה: כשתזכורת מגיעה פעמיים אין שום דרך אחרת לדעת אם היא
/// באמת מתוזמנת פעמיים או שהמערכת מציגה אותה שוב. בלי התצוגה הזו כל תיקון
/// לבאג כזה הוא ניחוש.
class _ScheduledReminders extends ConsumerStatefulWidget {
  const _ScheduledReminders();

  @override
  ConsumerState<_ScheduledReminders> createState() =>
      _ScheduledRemindersState();
}

class _ScheduledRemindersState extends ConsumerState<_ScheduledReminders> {
  bool _refreshing = false;

  /// "24/08/27 · סבא יעקב (3)" – מועד, שם, וכמה מתוזמנות.
  ///
  /// המועד ראשון בכוונה: השורות ממוינות לפיו, וכך אפשר לקרוא אותן כרשימה
  /// אחת ולראות מה ההקצאה בחרה לתזמן. **התאריך הוא מועד התזכורת, לא מועד
  /// האזכרה** – ההפרש ביניהם נקבע בהגדרת מועד התזכורת של כל אזכרה.
  String _row(PendingRow r) {
    final at = r.nextReminder;
    final when = at == null
        ? '—'
        : '${at.day.toString().padLeft(2, '0')}/'
            '${at.month.toString().padLeft(2, '0')}/'
            '${(at.year % 100).toString().padLeft(2, '0')}';

    // כשיש פער, מוצג גם מה היה אמור להיות – בלעדיו האדום מסמן בעיה ולא
    // אומר מהי.
    final count =
        r.matchesPlan ? '${r.scheduled}' : '${r.scheduled} מתוך ${r.expected}';
    final stale = r.stale > 0 ? ' · ${r.stale} לרענון' : '';
    return '$when · ${r.name} ($count)$stale';
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    // אותו סנכרון שרץ בפתיחה: הוא מתזמן מחדש כל אזכרה שהתור שלה אינו תואם.
    await ref.read(memorialListProvider.notifier).syncNotifications();
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final memorials =
        ref.watch(memorialListProvider).valueOrNull ?? const <Memorial>[];
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final bad = small?.copyWith(color: theme.colorScheme.error);

    return FutureBuilder<PendingReport>(
      future: ref.read(notificationServiceProvider).pendingReport(
            memorials,
            batteryExempt: ref
                    .watch(notificationPermissionProvider)
                    .valueOrNull
                    ?.batteryExempt ??
                true,
          ),
      builder: (context, snapshot) {
        final report = snapshot.data;
        return ListTile(
          leading: const Icon(Icons.pending_actions),
          title: const Text('מועדי התזכורות המתוזמנות'),
          isThreeLine: report != null && report.rows.isNotEmpty,
          subtitle: report == null
              ? const Text('נבדק...')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('סה"כ ${report.total}', style: small),
                    if (report.orphans > 0)
                      Text('ללא אזכרה: ${report.orphans}', style: bad),
                    for (final r in report.rows)
                      Text(_row(r),
                          style: r.matchesPlan && r.stale == 0 ? small : bad),
                    if (!report.notificationsEnabled)
                      Text('הרשאת התראות חסרה', style: bad),
                    if (!report.exactAlarmsAllowed)
                      Text('הרשאת אזעקה מדויקת חסרה', style: bad),
                    if (!report.batteryExempt)
                      Text('ניהול הסוללה פעיל – אנדרואיד רשאי למחוק אזעקות',
                          style: bad),
                    if (report.lastError != null)
                      Text(report.lastError!, style: bad),
                  ],
                ),
          // הכפתור מופיע רק כשיש מה לתקן. הסנכרון רץ ממילא בכל פתיחה, ולכן
          // כפתור קבוע היה מזמין לחיצות שאינן עושות דבר.
          trailing: report == null || report.inStep
              ? null
              : _refreshing
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'רענון האזעקות',
                      onPressed: _refresh,
                    ),
        );
      },
    );
  }
}
