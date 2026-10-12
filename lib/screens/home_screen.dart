import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/event_date.dart';
import '../models/event.dart';
import '../models/event_filter.dart';
import '../providers/event_provider.dart';
import '../services/event_calendar_service.dart';
import '../services/notification_service.dart';
import '../widgets/confetti.dart';
import '../widgets/event_card.dart';
import 'add_event_screen.dart';
import 'edit_event_screen.dart';
import 'settings_screen.dart';

/// מסך הבית – מציג את רשימת כל האירועים, ממוינת לפי קרבת ההתראה.
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

  /// האם כבר נבדקו פרטי ההשקה של התהליך הזה.
  bool _askedForLaunchRequest = false;

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
    ref.read(eventListProvider.notifier).syncNotifications();
    ref.invalidate(notificationPermissionProvider);

    // לחיצה על "דחיית תזכורת" בהתראה מגיעה לכאן בשני מסלולים: השירות
    // קורא ל-onChooseReminder כשהאפליקציה כבר רצה, ובפתיחה קרה הבקשה
    // ממתינה בפרטי ההשקה. בלי המסלול השני, לחיצה על התראה כשהאפליקציה
    // סגורה הייתה פותחת את המסך ולא מציגה דבר.
    final notifications = ref.read(notificationServiceProvider);
    // נשמר בשדה כדי שאפשר יהיה לנתק את ההרשמה ב-dispose: שם כבר אסור לגעת
    // ב-ref, וקריאה אליו זורקת.
    _notifications = notifications;
    notifications.onChooseReminder = _offerReminderChoice;

    // פעם אחת בלבד. פרטי ההשקה אינם מתנקים אחרי קריאה – אנדרואיד משיב אותו
    // דבר כל עוד התהליך חי – ולכן שאלה חוזרת בכל חזרה לחזית הציעה שוב ושוב
    // לדחות תזכורת שכבר נדחתה.
    if (!_askedForLaunchRequest) {
      _askedForLaunchRequest = true;
      notifications.pendingChoiceRequest().then((request) {
        if (request != null) _offerReminderChoice(request);
      });
    }
  }

  /// "3 ימים לפני ביום רביעי" – המרווח, ובאיזה יום הוא נופל.
  ///
  /// **משפט אחד, לא שני שדות עם מפריד.** המרווח כבר מזהה כל שורה באופן
  /// חד-ערכי, ולכן שם היום הוא מידע נוסף ולא מזהה – ותאריך לצדו היה רעש.
  ///
  /// יום האירוע עצמו מקבל פסיק במקום המילה "ביום": התווית שלו כבר פותחת
  /// ב"ביום", ו"ביום האירוע ביום שני" הוא גמגום. זו התווית היחידה שאינה
  /// מהצורה "כך וכך לפני", ולכן היחידה שצריכה את החריג.
  ///
  /// בשורה אחת ולא ב-subtitle: ListTile דו-שורתי הוא 72 פיקסלים במקום 56,
  /// כלומר כמעט 500 פיקסלים גלילה נוספים ושתי אפשרויות פחות על המסך –
  /// בשביל מידע שהוא חלק מאותה מחשבה, לא פירוט מתחתיה.
  String _choiceLabel(ReminderChoiceRequest request, int daysBefore) {
    final at =
        NotificationService.snoozeTargetFor(request.eventDate, daysBefore);
    final label = NotificationService.snoozeChoiceLabel(daysBefore);
    final weekday = hebrewWeekdayLabel(at);
    return daysBefore == 0 ? '$label, $weekday' : '$label ב$weekday';
  }

  /// מציג את הרשימה המלאה של המועדים האפשריים, ומתזמן מחדש לפי הבחירה.
  Future<void> _offerReminderChoice(ReminderChoiceRequest request) async {
    if (!mounted) return;
    // נבנית מחדש מול הרגע הזה ולא מול מועד ההתראה: ייתכן שעברו שעות מאז
    // שהיא נורתה, ואפשרות שחלפה בינתיים אסור שתוצע.
    final options =
        NotificationService.choicesBefore(request.eventDate, DateTime.now())
            .reversed
            .toList();

    // הדיאלוג נפתח גם כשלא נותר מועד לבחור בו: "לא להזכיר יותר" עדיין
    // רלוונטי, ובלעדיו הכפתור היה פותח את האפליקציה ומודיע שאין מה לעשות.
    //
    // AlertDialog ולא SimpleDialog: רשימת המועדים ארוכה ונגללת, וכפתור
    // הכיבוי בתחתיתה היה יוצא מהמסך. בשורת הפעולות הוא נשאר גלוי תמיד.
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('מתי להזכיר?'),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: double.maxFinite,
          child: options.isEmpty
              ? const Padding(
                  padding: EdgeInsets.fromLTRB(24, 4, 24, 4),
                  child: Text('לא נותרו מועדים לפני האירוע'),
                )
              // נבנית במלואה ולא ListView עצל: הרשימה קצרה מספיק, וכך
              // בחירה רחוקה נשארת ניתנת למציאה בגלילה אחת.
              : SingleChildScrollView(
                  child: ListBody(
                    children: [
                      for (final d in options)
                        ListTile(
                          title: Text(_choiceLabel(request, d)),
                          onTap: () => Navigator.pop(context, d),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, NotificationService.stopReminding),
            child: Text(
              NotificationService.stopRemindingLabel,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;

    if (chosen == NotificationService.stopReminding) {
      await _stopReminding(request);
      return;
    }

    final movedTo = await ref
        .read(notificationServiceProvider)
        .rescheduleReminder(request: request, daysBefore: chosen);
    if (!mounted) return;
    if (movedTo == null) {
      _tell('המועד שנבחר כבר חלף');
      return;
    }

    // נשמר באירוע, ולא רק באזעקה: כך הדחייה נראית ברשימה ושורדת תזמון מחדש.
    await ref.read(eventListProvider.notifier).recordPostponement(
          Event.eventIdForNotification(request.notificationId),
          movedTo,
        );
    if (!mounted) return;
    // נבנה מ-movedTo, המועד שהתזמון **החזיר**, ולא מתווית הבחירה. שני
    // רווחים: תווית הבחירה ייצרה "התזכורת נדחתה לביום האירוע" – ל+ב כפולים
    // – ולא יכלה לסתור את מה שנקבע בפועל, כי היא לא ידעה עליו.
    _tell('התזכורת נדחתה ל${hebrewDayAndDate(movedTo)}');
  }

  /// מכבה את התזכורות של האירוע שההתראה שייכת אליו.
  ///
  /// הפעולה הפיכה – אותו מתג שברשימה – ולכן אין כאן אישור נוסף: הבחירה
  /// מתוך רשימה כבר מפורשת דיה, ואישור עליה היה רעש.
  Future<void> _stopReminding(ReminderChoiceRequest request) async {
    final name = await ref.read(eventListProvider.notifier).setEnabledById(
          Event.eventIdForNotification(request.notificationId),
          false,
        );
    if (!mounted) return;
    if (name == null) {
      _tell('האירוע לא נמצא');
      return;
    }
    _tell('התזכורות עבור $name כובו. אפשר להחזיר מהרשימה.');
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
    ref.read(eventSearchProvider.notifier).state = '';
    setState(() => _searching = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // בכל חזרה לחזית – מוודאים שההתראות מתוזמנות ומרעננים.
    // גם מצב ההרשאות נבדק מחדש, כי המשתמש עשוי היה לשנות אותו בהגדרות.
    if (state == AppLifecycleState.resumed) {
      // load() בלבד נמתן; הסנכרון האיטי רץ ברקע.
      ref.read(eventListProvider.notifier).load();
      _syncInBackground();
    }
  }

  /// בוחר את סוג האירוע, מתוך הרשימה עצמה.
  ///
  /// גיליון תחתון ולא תפריט: חמש שורות עם סימן וכיתוב נקראות טוב יותר
  /// מתפריט צף, והן גדולות מספיק להקשה בלי דיוק.
  Future<void> _pickKind(BuildContext context, Event event) async {
    final chosen = await showModalBottomSheet<EventKind>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                event.name,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (final k in EventKind.values)
              ListTile(
                leading: EventCard.kindMark(k, size: 22),
                title: Text(k.label),
                // מה שנבחר כרגע מסומן, אחרת אי אפשר לדעת ממה משנים.
                trailing: event.kind == k
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(k),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted || chosen == event.kind) return;

    await ref.read(eventListProvider.notifier).setKind(event, chosen);
    if (!mounted) return;
    // אומרים מה קרה: עם סינון סוג פעיל האירוע נעלם מהרשימה ברגע שהוא
    // משתנה, וזה נראה כמו מחיקה אם לא אומרים דבר. וגם כשאין סינון – הסוג
    // משנה את נוסח ההתראה עצמה, וזה שינוי שראוי לאשר בקול.
    _tell('${event.name} — ${chosen.label}');
  }

  /// ממיין את האירועים לפי **תאריך האירוע** הקרוב ביותר ואילך.
  ///
  /// לא לפי מועד התזכורת: זה מקדים את האירוע ב-5 עד 11 יום תלוי ביום בשבוע,
  /// ולכן היה הופך את הסדר בין אירועים סמוכות. הוא גם שלילי בחלון שאחרי יום
  /// השלישי, מה שהיה מקפיץ אירוע שהתזכורת עליו כבר חלפה לראש הרשימה.
  List<Event> _sorted(List<Event> list, EventCalendarService calendar) {
    // התאריך מחושב פעם אחת לכל אירוע ולא בתוך ההשוואה – חישוב התאריך העברי
    // יקר, והשוואה ישירה הייתה מריצה אותו מחדש בכל השוואה ובכל בנייה.
    final keyed = [
      for (final m in list) (event: m, next: calendar.nextOccurrenceDate(m)),
    ];
    keyed.sort((a, b) {
      final byDate = a.next.compareTo(b.next);
      if (byDate != 0) return byDate;
      // מיון יציב לשתי אירועים באותו תאריך.
      return a.event.name.compareTo(b.event.name);
    });
    return [for (final e in keyed) e.event];
  }

  /// מסנן לפי קטגוריה. null אינו מסנן.
  List<Event> _ofKind(List<Event> list, EventKind? kind) {
    if (kind == null) return list;
    return [
      for (final m in list)
        if (m.kind == kind) m,
    ];
  }

  /// מסנן לפי חלון הימים של [filter]. [EventFilter.all] אינו מסנן.
  List<Event> _filtered(
    List<Event> list,
    EventFilter filter,
    EventCalendarService calendar,
  ) {
    final days = filter.days;
    if (days == null) return list;
    return [
      for (final m in list)
        if (calendar.isEventWithin(m, days)) m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final asyncEvents = ref.watch(eventListProvider);
    final calendar = ref.watch(calendarServiceProvider);

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
            : Center(
                // אייקון ולא אמוג'י, כמו כל סימן אחר באפליקציה: אמוג'י
                // מרונדר בגופן של המערכת, ובבדיקות ווידג'ט – שבהן נטען גופן
                // אחד – הוא אינו מרונדר בכלל. ראה EventCard.kindMark.
                child: Icon(
                  Icons.celebration,
                  size: 24,
                  color: Theme.of(context).colorScheme.primary,
                ),
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
                    ref.read(eventSearchProvider.notifier).state = v,
              )
            : const Text('תזכורת אירועים'),
        actions: [
          if (_searching)
            IconButton(
              tooltip: 'ניקוי',
              icon: const Icon(Icons.close),
              onPressed: () {
                _searchController.clear();
                ref.read(eventSearchProvider.notifier).state = '';
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
            MaterialPageRoute(builder: (_) => const AddEventScreen()),
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('הוספה'),
      ),
      // כל נגיעה בגוף המסך משחררת את המיקוד.
      //
      // **זו הסיבה שהמקלדת חזרה.** מסלול מודאלי – גיליון הקטגוריה,
      // מסך העריכה – מחזיר בסגירתו את המיקוד למי שהחזיק אותו בפתיחה,
      // ואחרי חיפוש זהו שדה החיפוש. כך יציאה וחזרה העלו את המקלדת על
      // רשימה שהמשתמש ניסה רק להסתכל בה.
      //
      // Listener ולא GestureDetector: הוא מאזין ואינו בולע, ולכן
      // ההקשה ממשיכה לשבב, לכרטיס ולמתג כרגיל. onPointerDown ולא
      // onTap, כדי שהשחרור יקרה **לפני** שהמסלול נדחף – אחרת יש שוב
      // מה להחזיר.
      //
      // במקום אחד ולא בכל קורא: כך גם מה שייווסף כאן מחר מכוסה. סרגל
      // הכותרת אינו בפנים, ולכן שדה החיפוש עצמו ממשיך לעבוד.
      body: Listener(
        onPointerDown: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        child: Column(
          children: [
            const _PermissionWarning(),
            // מוצג רק כשיש מה לסנן – שורת סינון על רשימה ריקה היא רעש.
            if (asyncEvents.valueOrNull?.isNotEmpty ?? false)
              _FilterBar(events: asyncEvents.value!, calendar: calendar),
            Expanded(
              child: asyncEvents.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => _ErrorView(
                  message: 'שגיאה בטעינת האירועים: $e',
                  onRetry: () =>
                      ref.read(eventListProvider.notifier).loadAndReschedule(),
                ),
                data: (events) {
                  if (events.isEmpty) {
                    return const _EmptyView(filter: EventFilter.all);
                  }

                  final filter = ref.watch(eventFilterProvider);
                  final kind = ref.watch(eventKindFilterProvider);
                  final query = ref.watch(eventSearchProvider);

                  final matched = [
                    for (final m in events)
                      if (m.matchesQuery(query)) m
                  ];
                  final sorted = _sorted(
                      _ofKind(_filtered(matched, filter, calendar), kind),
                      calendar);

                  if (sorted.isEmpty) {
                    // מבדיל בין "החיפוש לא מצא" לבין "אין בחלון" – אחרת
                    // המשתמש לא יודע מה בדיוק להרפות ממנו.
                    return _EmptyView(
                      filter: filter,
                      query: matched.isEmpty ? query : '',
                      kind: kind,
                    );
                  }

                  return RefreshIndicator(
                    onRefresh: () => ref
                        .read(eventListProvider.notifier)
                        .loadAndReschedule(),
                    child: ListView.builder(
                      padding: const EdgeInsets.only(top: 8, bottom: 88),
                      itemCount: sorted.length,
                      itemBuilder: (context, index) {
                        final m = sorted[index];
                        return EventCard(
                          event: m,
                          calendar: calendar,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => EditEventScreen(event: m),
                              ),
                            );
                          },
                          onToggle: (enabled) {
                            ref
                                .read(eventListProvider.notifier)
                                .toggleEnabled(m, enabled);
                          },
                          onChangeKind: () => _pickKind(context, m),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// שורת סינון לפי קרבת האירוע, עם מונה לכל אפשרות.
///
/// המונה הוא העיקר: הוא עונה על "מה יש לי החודש" בלי ללחוץ בכלל.
class _FilterBar extends ConsumerWidget {
  final List<Event> events;
  final EventCalendarService calendar;

  const _FilterBar({required this.events, required this.calendar});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(eventFilterProvider);
    final query = ref.watch(eventSearchProvider);

    // המונים נספרים בתוך תוצאות החיפוש. אחרת "החודש (3)" לצד רשימה שמציגה
    // אחת בלבד היה נראה כמו באג.
    final visible = [
      for (final m in events)
        if (m.matchesQuery(query)) m
    ];

    // מחושב פעם אחת לכל אפשרות ולא בתוך בניית ה-chip.
    final counts = {
      for (final f in EventFilter.values)
        f: f.days == null
            ? visible.length
            : visible
                .where((m) => calendar.isEventWithin(m, f.days!))
                .length,
    };

    // שורת הסוגים מוצגת **תמיד**, בשונה משורת הקטגוריות של גרסת האזכרות:
    // שם רוב הרשומות לא היו מסומנות כלל והשורה הייתה רעש קבוע, וכאן לכל
    // אירוע יש סוג – ולכן השורה היא סינון שמשמעותו ברורה בכל מצב.
    final selectedKind = ref.watch(eventKindFilterProvider);
    final kindCounts = {
      for (final k in EventKind.values)
        k: visible.where((m) => m.kind == k).length,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // גלילה אופקית: שלושה שבבים נכנסים במסך שנבדק, אבל מסך צר או
          // גופן מוגדל מגלישים Row חשוף – וגלישה כאן מסתירה אפשרות סינון.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final f in EventFilter.values)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: FilterChip(
                      label: Text('${f.label} (${counts[f]})'),
                      selected: selected == f,
                      onSelected: (_) =>
                          ref.read(eventFilterProvider.notifier).state = f,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: FilterChip(
                      label: Text('כל הסוגים (${visible.length})'),
                      selected: selectedKind == null,
                      onSelected: (_) => ref
                          .read(eventKindFilterProvider.notifier)
                          .state = null,
                    ),
                  ),
                  for (final k in EventKind.values)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: FilterChip(
                        // כשהשבב נבחר, הרקע שלו הוא גוון הסוג – וסימן באותו
                        // גוון על גביו נעלם. מיזוג לכיוון צבע הטקסט שומר על
                        // הזיהוי ומחזיר ניגודיות, בשני מצבי התצוגה.
                        avatar: EventCard.kindMark(
                          k,
                          size: 16,
                          color: selectedKind == k
                              ? Color.lerp(
                                  EventCard.kindColor(k),
                                  Theme.of(context).colorScheme.onSurface,
                                  0.45,
                                )
                              : null,
                        ),
                        label: Text('${k.label} (${kindCounts[k]})'),
                        selected: selectedKind == k,
                        // אותו גוון שמסמן את הסוג על הכרטיס. שבב שנבחר
                        // בצבע הערכה היה מנתק את הקשר בין השניים.
                        selectedColor:
                            EventCard.kindColor(k).withValues(alpha: 0.28),
                        onSelected: (_) => ref
                            .read(eventKindFilterProvider.notifier)
                            .state = selectedKind == k ? null : k,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// אזהרה מתמדת כשחסרה הרשאה שבלעדיה ההתראות לא יעבדו.
///
/// בלי זה סירוב הרשאה הוא כשל שקט – הרשימה נראית תקינה, האירועים נשמרים,
/// ופשוט לעולם לא מגיעה תזכורת.
class _PermissionWarning extends ConsumerWidget {
  const _PermissionWarning();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(notificationPermissionProvider);

    return status.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (s) {
        if (s.notificationsEnabled &&
            s.channelEnabled &&
            s.hasNotificationIcon &&
            s.exactAlarmsAllowed &&
            s.batteryExempt) {
          return const SizedBox.shrink();
        }

        final theme = Theme.of(context);
        // מדורג לפי חומרה: קודם מה שמונע הצגה לגמרי, אחר כך מה שפוגע
        // בתזמון, ולבסוף מה שמסכן את האזעקות עצמן. הודעה לא נכונה שולחת
        // את המשתמש למסך הגדרות הלא נכון.
        final message = !s.notificationsEnabled
            ? 'ההתראות כבויות – לא תקבל תזכורות'
            : !s.channelEnabled
                ? 'ערוץ "תזכורות אירועים" חסום – לא תקבל תזכורות'
                : !s.hasNotificationIcon
                    ? 'תקלה בבנייה: אייקון ההתראה חסר, ההתראות ייכשלו'
                    : !s.exactAlarmsAllowed
                        ? 'חסרה הרשאה לאזעקות מדויקות – התזכורות לא יתוזמנו'
                        : 'ניהול הסוללה עלול לעצור את האפליקציה ולמחוק תזכורות';

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
                // ערוץ חסום מתוקן רק בהגדרות המערכת, ואייקון חסר הוא תקלת
                // בנייה. כפתור שאינו עושה דבר גרוע מהיעדרו.
                if (s.channelEnabled && s.hasNotificationIcon)
                  FilledButton.tonal(
                    onPressed: () async {
                      if (!s.notificationsEnabled || !s.exactAlarmsAllowed) {
                        await ref
                            .read(notificationServiceProvider)
                            .requestMissingPermissions();
                      } else if (!s.batteryExempt) {
                        await ref
                            .read(deliveryChecksProvider)
                            .requestBatteryExemption();
                      }
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

/// מסך ריק. מבדיל בין שלושה מצבים שונים לגמרי – אין אירועים בכלל, החיפוש
/// לא מצא, או שאין בחלון שנבחר – אחרת המשתמש לא יודע מה לשנות.
class _EmptyView extends StatelessWidget {
  final EventFilter filter;

  /// כשאינו ריק, אף אירוע לא התאים לחיפוש הזה.
  final String query;

  /// הסוג שסונן, אם סונן. מצב רביעי: יש אירועים, יש בחלון, אבל אין בסוג
  /// הזה – ובלי לומר זאת נראה כאילו הרשימה התרוקנה.
  final EventKind? kind;

  const _EmptyView({required this.filter, this.query = '', this.kind});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noSearchMatch = query.trim().isNotEmpty;
    final isFiltered = filter != EventFilter.all;

    final (title, hint) = switch ((noSearchMatch, isFiltered, kind)) {
      (true, _, _) => ('לא נמצא אירוע בשם "${query.trim()}"', 'נסה שם אחר'),
      (false, _, final k?) => (
          'אין אירועים מסוג "${k.label}"',
          'בחר "כל הסוגים" כדי לראות הכל',
        ),
      (false, true, _) => (filter.emptyMessage, 'בחר "הכל" כדי לראות הכל'),
      (false, false, _) => (
          filter.emptyMessage,
          'הוסף יום הולדת או יום נישואין, ותקבל תזכורת בשבוע שלפני',
        ),
    };

    return Stack(
      children: [
        // קונפטי רק על הרשימה הריקה: זה המסך היחיד שאין בו מה לקרוא,
        // והוא גם הראשון שרואים – ולכן המקום שבו הוא אומר במה מדובר.
        if (!noSearchMatch) const Positioned.fill(child: Confetti(opacity: 0.5)),
        Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              noSearchMatch ? Icons.search_off : Icons.celebration,
              size: 64,
              color: theme.colorScheme.primary,
            ),
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
        ),
      ],
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
