import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memorial.dart';
import '../models/memorial_filter.dart';
import '../providers/memorial_provider.dart';
import '../services/hebrew_calendar_service.dart';
import '../services/notification_service.dart';
import '../widgets/memorial_card.dart';
import 'add_memorial_screen.dart';
import 'edit_memorial_screen.dart';
import 'settings_screen.dart';

/// מסך הבית – מציג את רשימת כל האזכרות, ממוינת לפי קרבת ההתראה.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  /// מצב החיפוש שייך למסך ולא לספק: הוא ויזואלי בלבד, ואמור להתאפס
  /// כשעוזבים את המסך. השאילתה עצמה בספק, כדי ששורת הסינון תוכל לספור לפיה.
  bool _searching = false;
  final _searchController = TextEditingController();

  /// שירות ההתראות שאליו נרשמנו, לניתוק ההרשמה בסיום.
  NotificationService? _notifications;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // עבודת ההתראות מתחילה רק אחרי שהמסך מצויר, ואינה מומתנת – היא איטית
    // ואינה דחופה לרגע.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncInBackground());
  }

  void _syncInBackground() {
    if (!mounted) return;
    ref.read(memorialListProvider.notifier).syncNotifications();
    ref.invalidate(notificationPermissionProvider);

    // לחיצה על "עוד אפשרויות" בהתראה מגיעה לכאן בשני מסלולים: השירות
    // קורא ל-onChooseReminder כשהאפליקציה כבר רצה, ובפתיחה קרה הבקשה
    // ממתינה בפרטי ההשקה. בלי המסלול השני, לחיצה על התראה כשהאפליקציה
    // סגורה הייתה פותחת את המסך ולא מציגה דבר.
    final notifications = ref.read(notificationServiceProvider);
    // נשמר בשדה כדי שאפשר יהיה לנתק את ההרשמה ב-dispose: שם כבר אסור לגעת
    // ב-ref, וקריאה אליו זורקת.
    _notifications = notifications;
    notifications.onChooseReminder = _offerReminderChoice;
    notifications.pendingChoiceRequest().then((request) {
      if (request != null) _offerReminderChoice(request);
    });
  }

  /// מציג את הרשימה המלאה של המועדים האפשריים, ומתזמן מחדש לפי הבחירה.
  Future<void> _offerReminderChoice(ReminderChoiceRequest request) async {
    if (!mounted) return;
    // נבנית מחדש מול הרגע הזה ולא מול מועד ההתראה: ייתכן שעברו שעות מאז
    // שהיא נורתה, ואפשרות שחלפה בינתיים אסור שתוצע.
    final options =
        NotificationService.choicesBefore(request.memorialDate, DateTime.now())
            .reversed
            .toList();

    if (options.isEmpty) {
      _tell('לא נותרו מועדים לבחירה לפני האזכרה');
      return;
    }

    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('מתי להזכיר?'),
        children: [
          for (final d in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, d),
              child: Text(NotificationService.snoozeChoiceLabel(d)),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;

    final moved = await ref
        .read(notificationServiceProvider)
        .rescheduleReminder(request: request, daysBefore: chosen);
    if (!mounted) return;
    _tell(moved
        ? 'התזכורת נקבעה ל${NotificationService.snoozeChoiceLabel(chosen)}'
        : 'המועד שנבחר כבר חלף');
  }

  void _tell(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _notifications?.onChooseReminder = null;
    _searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _closeSearch() {
    _searchController.clear();
    ref.read(memorialSearchProvider.notifier).state = '';
    setState(() => _searching = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // בכל חזרה לחזית – מוודאים שההתראות מתוזמנות ומרעננים.
    // גם מצב ההרשאות נבדק מחדש, כי המשתמש עשוי היה לשנות אותו בהגדרות.
    if (state == AppLifecycleState.resumed) {
      // load() בלבד נמתן; הסנכרון האיטי רץ ברקע.
      ref.read(memorialListProvider.notifier).load();
      _syncInBackground();
    }
  }

  /// פותח ניווט אל מיקום הקבר, ומדווח אם לא נמצאה אפליקציית ניווט.
  Future<void> _navigate(
      BuildContext context, WidgetRef ref, Memorial memorial) async {
    final query = memorial.burialSearchQuery;
    if (query == null) return;

    final opened =
        await ref.read(navigationLauncherProvider).openBurialLocation(query);
    if (opened || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('לא נמצאה אפליקציית ניווט במכשיר')),
    );
  }

  /// ממיין את האזכרות לפי **תאריך האזכרה** הקרוב ביותר ואילך.
  ///
  /// לא לפי מועד התזכורת: זה מקדים את האזכרה ב-5 עד 11 יום תלוי ביום בשבוע,
  /// ולכן היה הופך את הסדר בין אזכרות סמוכות. הוא גם שלילי בחלון שאחרי יום
  /// השלישי, מה שהיה מקפיץ אזכרה שהתזכורת עליה כבר חלפה לראש הרשימה.
  List<Memorial> _sorted(
      List<Memorial> list, HebrewCalendarService calendar) {
    // התאריך מחושב פעם אחת לכל אזכרה ולא בתוך ההשוואה – חישוב התאריך העברי
    // יקר, והשוואה ישירה הייתה מריצה אותו מחדש בכל השוואה ובכל בנייה.
    final keyed = [
      for (final m in list)
        (memorial: m, next: calendar.nextMemorialDate(m)),
    ];
    keyed.sort((a, b) {
      final byDate = a.next.compareTo(b.next);
      if (byDate != 0) return byDate;
      // מיון יציב לשתי אזכרות באותו תאריך.
      return a.memorial.name.compareTo(b.memorial.name);
    });
    return [for (final e in keyed) e.memorial];
  }

  /// מסנן לפי חלון הימים של [filter]. [MemorialFilter.all] אינו מסנן.
  List<Memorial> _filtered(
    List<Memorial> list,
    MemorialFilter filter,
    HebrewCalendarService calendar,
  ) {
    final days = filter.days;
    if (days == null) return list;
    return [
      for (final m in list)
        if (calendar.isMemorialWithin(m, days)) m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final asyncMemorials = ref.watch(memorialListProvider);
    final calendar = ref.watch(hebrewCalendarServiceProvider);

    return Scaffold(
      appBar: AppBar(
        // RTL: leading מרונדר בצד ימין, ו-actions נערמים שמאלה. לכן הנר
        // כאן והחתימה כפעולה האחרונה – הכי שמאלה.
        leading: _searching
            ? IconButton(
                tooltip: 'סגירת החיפוש',
                icon: const Icon(Icons.arrow_forward),
                onPressed: _closeSearch,
              )
            : const Center(
                child: Text('🕯', style: TextStyle(fontSize: 26)),
              ),
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'חיפוש לפי שם',
                  border: InputBorder.none,
                ),
                onChanged: (v) =>
                    ref.read(memorialSearchProvider.notifier).state = v,
              )
            : const Text('תזכורת אזכרות'),
        actions: [
          if (_searching)
            IconButton(
              tooltip: 'ניקוי',
              icon: const Icon(Icons.close),
              onPressed: () {
                _searchController.clear();
                ref.read(memorialSearchProvider.notifier).state = '';
              },
            )
          else ...[
            IconButton(
              tooltip: 'חיפוש',
              icon: const Icon(Icons.search),
              onPressed: () => setState(() => _searching = true),
            ),
            IconButton(
              tooltip: 'הגדרות',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
            // חתימת המפתח, בקצה השמאלי.
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12, start: 4),
              child: Center(
                child: Image.asset(
                  'assets/app_icon.png',
                  width: 30,
                  height: 30,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AddMemorialScreen()),
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('הוספה'),
      ),
      body: Column(
        children: [
          const _PermissionWarning(),
          // מוצג רק כשיש מה לסנן – שורת סינון על רשימה ריקה היא רעש.
          if (asyncMemorials.valueOrNull?.isNotEmpty ?? false)
            _FilterBar(memorials: asyncMemorials.value!, calendar: calendar),
          Expanded(
            child: asyncMemorials.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ErrorView(
                message: 'שגיאה בטעינת האזכרות: $e',
                onRetry: () => ref
                    .read(memorialListProvider.notifier)
                    .loadAndReschedule(),
              ),
              data: (memorials) {
                if (memorials.isEmpty) {
                  return const _EmptyView(filter: MemorialFilter.all);
                }

                final filter = ref.watch(memorialFilterProvider);
                final query = ref.watch(memorialSearchProvider);

                final matched =
                    [for (final m in memorials) if (m.matchesQuery(query)) m];
                final sorted =
                    _sorted(_filtered(matched, filter, calendar), calendar);

                if (sorted.isEmpty) {
                  // מבדיל בין "החיפוש לא מצא" לבין "אין בחלון" – אחרת
                  // המשתמש לא יודע מה בדיוק להרפות ממנו.
                  return _EmptyView(
                    filter: filter,
                    query: matched.isEmpty ? query : '',
                  );
                }

                return RefreshIndicator(
                  onRefresh: () => ref
                      .read(memorialListProvider.notifier)
                      .loadAndReschedule(),
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 88),
                    itemCount: sorted.length,
                    itemBuilder: (context, index) {
                      final m = sorted[index];
                      return MemorialCard(
                        memorial: m,
                        calendar: calendar,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  EditMemorialScreen(memorial: m),
                            ),
                          );
                        },
                        onToggle: (enabled) {
                          ref
                              .read(memorialListProvider.notifier)
                              .toggleEnabled(m, enabled);
                        },
                        onNavigate: m.burialSearchQuery == null
                            ? null
                            : () => _navigate(context, ref, m),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// שורת סינון לפי קרבת האזכרה, עם מונה לכל אפשרות.
///
/// המונה הוא העיקר: הוא עונה על "מה יש לי החודש" בלי ללחוץ בכלל.
class _FilterBar extends ConsumerWidget {
  final List<Memorial> memorials;
  final HebrewCalendarService calendar;

  const _FilterBar({required this.memorials, required this.calendar});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(memorialFilterProvider);
    final query = ref.watch(memorialSearchProvider);

    // המונים נספרים בתוך תוצאות החיפוש. אחרת "החודש (3)" לצד רשימה שמציגה
    // אחת בלבד היה נראה כמו באג.
    final visible =
        [for (final m in memorials) if (m.matchesQuery(query)) m];

    // מחושב פעם אחת לכל אפשרות ולא בתוך בניית ה-chip.
    final counts = {
      for (final f in MemorialFilter.values)
        f: f.days == null
            ? visible.length
            : visible
                .where((m) => calendar.isMemorialWithin(m, f.days!))
                .length,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          for (final f in MemorialFilter.values)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: FilterChip(
                label: Text('${f.label} (${counts[f]})'),
                selected: selected == f,
                onSelected: (_) =>
                    ref.read(memorialFilterProvider.notifier).state = f,
              ),
            ),
        ],
      ),
    );
  }
}

/// אזהרה מתמדת כשחסרה הרשאה שבלעדיה ההתראות לא יעבדו.
///
/// בלי זה סירוב הרשאה הוא כשל שקט – הרשימה נראית תקינה, האזכרות נשמרות,
/// ופשוט לעולם לא מגיעה תזכורת.
class _PermissionWarning extends ConsumerWidget {
  const _PermissionWarning();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(notificationPermissionProvider);

    return status.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (s) {
        if (s.notificationsEnabled && s.exactAlarmsAllowed) {
          return const SizedBox.shrink();
        }

        final theme = Theme.of(context);
        final message = !s.notificationsEnabled
            ? 'ההתראות כבויות – לא תקבל תזכורות'
            : 'חסרה הרשאה לאזעקות מדויקות – התזכורות לא יתוזמנו';

        return Material(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Icon(Icons.notifications_off_outlined,
                    color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () async {
                    await ref
                        .read(notificationServiceProvider)
                        .requestMissingPermissions();
                    ref.invalidate(notificationPermissionProvider);
                  },
                  child: const Text('תיקון'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// מסך ריק. מבדיל בין "אין אזכרות בכלל" לבין "אין בחלון שנבחר" – אחרת
/// סינון פעיל נראה כאילו הנתונים נעלמו.
/// מסך ריק. מבדיל בין שלושה מצבים שונים לגמרי – אין אזכרות בכלל, החיפוש
/// לא מצא, או שאין בחלון שנבחר – אחרת המשתמש לא יודע מה לשנות.
class _EmptyView extends StatelessWidget {
  final MemorialFilter filter;

  /// כשאינו ריק, אף אזכרה לא התאימה לחיפוש הזה.
  final String query;

  const _EmptyView({required this.filter, this.query = ''});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noSearchMatch = query.trim().isNotEmpty;
    final isFiltered = filter != MemorialFilter.all;

    final (title, hint) = switch ((noSearchMatch, isFiltered)) {
      (true, _) => ('לא נמצאה אזכרה בשם "${query.trim()}"', 'נסה שם אחר'),
      (false, true) => (filter.emptyMessage, 'בחר "הכל" כדי לראות הכל'),
      (false, false) => (
          filter.emptyMessage,
          'הוסף אזכרה כדי לקבל תזכורת בשבוע שלפני',
        ),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(noSearchMatch ? '🔍' : '🕯',
                style: const TextStyle(fontSize: 64)),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('נסה שוב')),
          ],
        ),
      ),
    );
  }
}
