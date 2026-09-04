import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memorial.dart';
import '../models/merge_plan.dart';
import '../providers/memorial_provider.dart';
import '../widgets/import_selection_dialog.dart';
import '../services/photo_store.dart';
import '../services/notification_service.dart';

/// מסך הגדרות.
///
/// מאפשר: קביעת שעת ברירת מחדל להתראות, ייצוא הנתונים לקובץ JSON,
/// וייבוא מקובץ JSON.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _pickDefaultTime(BuildContext context, WidgetRef ref) async {
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

  /// בונה את תוכן הגיבוי. משותף לשמירה לקובץ ולשיתוף.
  ///
  /// מופרד כדי ששני המסלולים יפיקו **בדיוק** את אותו קובץ; שתי בנייה נפרדות
  /// היו נפרדות זו מזו בשקט ברגע שאחת מהן משתנה.
  Future<({String json, int count, int withPhoto})> _buildBackup(
      WidgetRef ref) async {
    final memorials = await ref.read(memorialRepositoryProvider).getAll();
    final photos = ref.read(photoStoreProvider);

    final jsonList = <Map<String, dynamic>>[];
    var withPhoto = 0;
    for (final m in memorials) {
      final map = m.toJson();
      // הנתיב המקומי חסר משמעות במכשיר אחר; התמונה עצמה נוסעת מוטמעת.
      map.remove('photo_path');
      map.remove('grave_photo_path');
      final data = await photos.readAsBase64(m.photoPath);
      final graveData = await photos.readAsBase64(m.gravePhotoPath);
      if (data != null) {
        map['photo_data'] = data;
      }
      if (graveData != null) {
        map['grave_photo_data'] = graveData;
      }
      if (data != null) withPhoto++;
      if (graveData != null) withPhoto++;
      jsonList.add(map);
    }

    return (
      json: const JsonEncoder.withIndent('  ').convert(jsonList),
      count: memorials.length,
      withPhoto: withPhoto,
    );
  }

  /// שם קובץ עם חותמת זמן, כדי ששיתופים עוקבים לא ידרסו זה את זה.
  String _backupFileName() {
    final ts =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    return 'azkarot_backup_$ts.json';
  }

  /// שולח את הגיבוי דרך בורר השיתוף של אנדרואיד.
  ///
  /// הקובץ נכתב לתיקיית ה-cache ולא לאחסון המשתמש: הוא זמני ומיועד למסירה
  /// לאפליקציה אחרת, ואנדרואיד מנקה אותו בעצמו. מי שרוצה עותק שמור ישתמש
  /// ב"ייצוא".
  Future<void> _share(BuildContext context, WidgetRef ref) async {
    try {
      final backup = await _buildBackup(ref);
      final file = File(
        p.join((await getTemporaryDirectory()).path, _backupFileName()),
      );
      await file.writeAsString(backup.json);

      if (!context.mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json')],
          subject: 'גיבוי תזכורת אזכרות',
          text: '${backup.count} אזכרות'
              '${backup.withPhoto > 0 ? ' · ${backup.withPhoto} תמונות' : ''}',
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה בשיתוף: $e')),
        );
      }
    }
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    try {
      final backup = await _buildBackup(ref);
      final jsonStr = backup.json;

      // חובה לתת למשתמש לבחור את היעד דרך דיאלוג המערכת.
      // getApplicationDocumentsDirectory מחזיר תיקייה פרטית לאפליקציה
      // (‎/data/user/0/<package>/app_flutter), שבורר הקבצים של אנדרואיד אינו
      // יכול לראות – כלומר הגיבוי לא היה ניתן לאיתור, לשיתוף, או לייבוא,
      // והיה נמחק עם הסרת האפליקציה.
      final saved = await FilePicker.saveFile(
        dialogTitle: 'שמירת גיבוי',
        fileName: _backupFileName(),
        bytes: Uint8List.fromList(utf8.encode(jsonStr)),
      );

      if (!context.mounted) return;
      if (saved == null) return; // המשתמש ביטל

      final sizeKb = (jsonStr.length / 1024).round();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${backup.count} אזכרות נשמרו לגיבוי'
            '${backup.withPhoto > 0 ? ' (כולל ${backup.withPhoto} תמונות)' : ''}'
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

      for (final entry in decoded.cast<Map<String, dynamic>>()) {
        var memorial = Memorial.fromJson(entry);
        // התמונות מגיעות מוטמעות; נכתבות מחדש מקומית ומקבלות נתיב של
        // המכשיר הזה. כל אחת בגודל שבו נשמרה.
        final path =
            await photos.restoreFromBase64(entry['photo_data'] as String?);
        final gravePath = await photos.restoreFromBase64(
          entry['grave_photo_data'] as String?,
          maxSide: PhotoStore.graveMaxDimension,
        );
        if (path != null || gravePath != null) {
          memorial = memorial.copyWith(
            photoPath: path,
            gravePhotoPath: gravePath,
          );
        }
        memorials.add(memorial);
      }

      // בחירת הקובץ וקריאתו הן פעולות אסינכרוניות – המסך עלול להיסגר
      // בינתיים, ואז showDialog על context מנותק זורק חריגה.
      if (!context.mounted) return;

      // בחירה ומצב באותו דיאלוג ולא בשניים: שלושה מסכים ברצף על פעולה
      // אחת הם עייפות, לא זהירות.
      final choice = await showDialog<ImportChoice>(
        context: context,
        builder: (ctx) => ImportSelectionDialog(
          memorials: memorials,
          calendar: ref.read(hebrewCalendarServiceProvider),
        ),
      );
      if (choice == null || choice.selected.isEmpty) return;

      final mode = choice.mode;
      final selected = choice.selected;

      final notifier = ref.read(memorialListProvider.notifier);
      // נספרות רק התמונות של מה שנבחר. הקובץ שוחזר במלואו לדיסק לפני
      // הבחירה, ומה שלא נבחר יתנקה כתמונה יתומה.
      final photoCount =
          selected.fold<int>(0, (sum, m) => sum + m.photoPaths.length);
      final photoNote = photoCount > 0 ? ' ו-$photoCount תמונות' : '';

      final String message;
      if (mode == ImportMode.replace) {
        await notifier.importMemorials(selected);
        message = 'יובאו ${selected.length} אזכרות$photoNote';
      } else {
        final plan = await notifier.planMerge(selected);

        // מקרים דומים – אותו תאריך עברי בשם אחר – אינם ניתנים להכרעה
        // אוטומטית, ולכן נשאלים לפני שנוגעים בנתונים.
        var sameAs = const <MergeCandidate>[];
        if (plan.needsDecision) {
          if (!context.mounted) return;
          final chosen = await showDialog<List<MergeCandidate>>(
            context: context,
            builder: (ctx) => _SimilarMemorialsDialog(plan.candidates),
          );
          if (chosen == null) return; // ביטול – לא נגענו בכלום
          sameAs = chosen;
        }

        final separate = [
          ...plan.toAdd,
          for (final c in plan.candidates)
            if (!sameAs.contains(c)) c.incoming,
        ];

        final result = await notifier.applyMerge(
          toAdd: separate,
          sameAs: sameAs,
          skipped: plan.identical,
        );

        message = result.added == 0 && result.merged == 0
            ? 'כל האזכרות בקובץ כבר קיימות'
            : [
                  if (result.added > 0) 'נוספו ${result.added}',
                  if (result.merged > 0) 'מוזגו ${result.merged}',
                  if (result.skipped > 0) '${result.skipped} כבר היו קיימות',
                ].join(', ') +
                photoNote;
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
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
            trailing:
                Text(timeLabel, style: Theme.of(context).textTheme.titleMedium),
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
            leading: const Icon(Icons.share_outlined),
            title: const Text('שיתוף הנתונים'),
            subtitle: const Text('שליחה בוואטסאפ, במייל, או לכל אפליקציה'),
            onTap: () => _share(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('ייבוא נתונים'),
            subtitle: const Text('שחזור מקובץ JSON (מחליף את הקיים)'),
            onTap: () => _import(context, ref),
          ),
          const Divider(),
          const _Feedback(),
          const Divider(),
          const _ScheduledReminders(),
          const _BackgroundRefreshStatus(),
          const _AlarmCanaryStatus(),
        ],
      ),
    );
  }
}

/// שואל אילו מהאזכרות הדומות הן אותו אדם.
///
/// **ברירת המחדל היא "לא".** סימון שגוי כ"אותו אדם" מוותר על רשומה מהקובץ
/// ואינו הפיך; אי-סימון שגוי מוסיף כפילות שאפשר למחוק בלחיצה. בין שתי
/// טעויות, בוחרים את זו שניתן לתקן.
class _SimilarMemorialsDialog extends StatefulWidget {
  const _SimilarMemorialsDialog(this.candidates);

  final List<MergeCandidate> candidates;

  @override
  State<_SimilarMemorialsDialog> createState() =>
      _SimilarMemorialsDialogState();
}

class _SimilarMemorialsDialogState extends State<_SimilarMemorialsDialog> {
  final Set<MergeCandidate> _same = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('אזכרות דומות'),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: ListBody(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'אלה חלות באותו תאריך עברי בשם אחר. סמן את אלה שהם אותו '
                  'אדם – הן ימוזגו לרשומה הקיימת. השאר ייווספו בנפרד.',
                ),
              ),
              for (final c in widget.candidates)
                CheckboxListTile(
                  value: _same.contains(c),
                  onChanged: (on) => setState(() {
                    if (on == true) {
                      _same.add(c);
                    } else {
                      _same.remove(c);
                    }
                  }),
                  title: Text(c.incoming.name),
                  subtitle: Text('קיים: ${c.existing.name}'),
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
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_same.toList(growable: false)),
          child: const Text('אישור'),
        ),
      ],
    );
  }
}

/// פרטי הקשר למשוב.
///
/// מעל שורות האבחון בכוונה: אלה מיועדות לי, וזו מיועדת למשתמש.
class _Feedback extends ConsumerWidget {
  const _Feedback();

  static const String name = 'אלעד שמחי';
  static const String phone = '0544908008';
  static const String display = '054-490-8008';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.feedback_outlined),
      title: const Text('הערות והארות'),
      subtitle: const Text('$name · $display'),
      trailing: const Icon(Icons.phone_outlined),
      onTap: () async {
        final opened = await ref.read(navigationLauncherProvider).dial(phone);
        if (!opened && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('לא נמצאה אפליקציית חיוג')),
          );
        }
      },
    );
  }
}

/// מתי אנדרואיד הפעיל לאחרונה אזעקה של האפליקציה.
///
/// **זו הבדיקה היחידה שבוחנת את המערכת ולא את הספרים שלנו.** כל השאר שואל
/// את הפלאגין כמה הוא חושב שמתוזמן; כאן רואים אם אזעקות בכלל פועלות.
/// אמורה להתעדכן מדי יום, וחותמת שמתיישנת היא סימן לדיכוי – ידיעה שמגיעה
/// לפני שאובדת תזכורת ולא אחריה.
///
/// מה שהיא אינה מוכיחה: שהתראה הוצגה. הביקורת אינה מציגה התראה.
class _AlarmCanaryStatus extends ConsumerWidget {
  const _AlarmCanaryStatus();

  /// מעל יומיים בלי ריצה זה כבר לא פיגור סביר של תזמון.
  static const int _staleDays = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final at =
        ref.watch(notificationPermissionProvider).valueOrNull?.canaryLastFired;

    final days = at == null ? null : DateTime.now().difference(at).inDays;
    final stale = days != null && days > _staleDays;

    return ListTile(
      leading: const Icon(Icons.alarm_on),
      title: const Text('מנגנון האזעקות'),
      subtitle: Text(
        at == null
            ? 'טרם נבדק – הבדיקה הראשונה תוך יממה'
            : stale
                ? 'לא פעל $days ימים – ייתכן שאנדרואיד מדכא אזעקות'
                : days! <= 0
                    ? 'פעל היום'
                    : 'פעל לפני $days ימים',
        style: stale
            ? theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error)
            : theme.textTheme.bodySmall,
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
