import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memorial.dart';
import '../models/memorial_filter.dart';
import '../providers/memorial_provider.dart';
import '../services/hebrew_calendar_service.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // בכל חזרה לחזית – מוודאים שההתראות מתוזמנות ומרעננים.
    // גם מצב ההרשאות נבדק מחדש, כי המשתמש עשוי היה לשנות אותו בהגדרות.
    if (state == AppLifecycleState.resumed) {
      ref.read(memorialListProvider.notifier).loadAndReschedule();
      ref.invalidate(notificationPermissionProvider);
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
        title: const Text('תזכורת אזכרות'),
        actions: [
          IconButton(
            tooltip: 'הגדרות',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
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
                  return const _EmptyView(MemorialFilter.all);
                }

                final filter = ref.watch(memorialFilterProvider);
                final sorted =
                    _sorted(_filtered(memorials, filter, calendar), calendar);

                if (sorted.isEmpty) return _EmptyView(filter);

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

    // מחושב פעם אחת לכל אפשרות ולא בתוך בניית ה-chip.
    final counts = {
      for (final f in MemorialFilter.values)
        f: f.days == null
            ? memorials.length
            : memorials
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
class _EmptyView extends StatelessWidget {
  final MemorialFilter filter;

  const _EmptyView(this.filter);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFiltered = filter != MemorialFilter.all;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🕯', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 16),
            Text(
              filter.emptyMessage,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              isFiltered
                  ? 'בחר "הכל" כדי לראות את כל האזכרות'
                  : 'הוסף אזכרה כדי לקבל תזכורת בשבוע שלפני',
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
