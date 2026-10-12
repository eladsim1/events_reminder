import '../database/database_helper.dart';
import '../models/event.dart';
import '../models/merge_plan.dart';

/// שכבת גישה לנתונים.
///
/// **חשוב:** כל לוגיקת הגישה לנתונים עוברת דרך Repository זה.
/// שכבת ה-UI וה-Providers אינם ניגשים ישירות ל-SQLite.
class EventRepository {
  final DatabaseHelper _db;

  EventRepository({DatabaseHelper? db})
      : _db = db ?? DatabaseHelper.instance;

  Future<int> insert(Event event) => _db.insert(event);

  Future<int> update(Event event) => _db.update(event);

  Future<int> delete(int id) => _db.delete(id);

  Future<List<Event>> getAll() => _db.getAll();

  Future<Event?> getById(int id) => _db.getById(id);

  /// נעילת הסנכרון, המשותפת לאפליקציה ולעבודה שרצה ברקע.
  ///
  /// יושבת כאן ולא בשירות נפרד כי היא נשמרת במסד – זה המקום היחיד ששני
  /// ה-isolates רואים במשותף.
  Future<bool> claimSyncLock(
    String owner, {
    Duration staleAfter = const Duration(minutes: 10),
  }) =>
      _db.claimSyncLock(owner, staleAfter);

  Future<void> releaseSyncLock() => _db.releaseSyncLock();

  Future<String?> readSetting(String key) => _db.readSetting(key);

  Future<void> writeSetting(String key, String value) =>
      _db.writeSetting(key, value);

  Future<void> recordBackgroundRun(DateTime at, String? error) =>
      _db.recordBackgroundRun(at, error);

  Future<({DateTime? lastRun, String? lastError})> backgroundStatus() =>
      _db.backgroundStatus();

  /// מוסיף רק את מה שאינו קיים (ייבוא במצב הוספה).
  Future<({int added, int skipped})> mergeAll(List<Event> events) =>
      _db.mergeAll(events);

  /// מחשב מה ייבוא במצב הוספה יעשה, בלי לגעת בנתונים.
  ///
  /// מופרד מהביצוע כדי שאפשר יהיה לשאול על המקרים הדומים לפני שמשנים משהו.
  Future<MergePlan> planMerge(List<Event> incoming) async {
    final existing = await getAll();
    final byIdentity = {for (final m in existing) m.identityKey: m};
    final byDate = <String, Event>{};
    for (final m in existing) {
      byDate.putIfAbsent(m.dateKey, () => m);
    }

    final toAdd = <Event>[];
    final candidates = <MergeCandidate>[];
    var identical = 0;
    // גם מול מה שכבר נבחר באותה ריצה: קובץ יכול להכיל כפילות בתוכו.
    final seen = byIdentity.keys.toSet();

    for (final m in incoming) {
      if (!seen.add(m.identityKey)) {
        identical++;
        continue;
      }
      final sameDate = byDate[m.dateKey];
      if (sameDate != null) {
        candidates.add(MergeCandidate(incoming: m, existing: sameDate));
      } else {
        toAdd.add(m);
      }
    }

    return MergePlan(
        toAdd: toAdd, identical: identical, candidates: candidates);
  }

  /// מחליף את כל הנתונים (ייבוא מ-JSON).
  Future<void> replaceAll(List<Event> events) =>
      _db.replaceAll(events);
}
