import '../database/database_helper.dart';
import '../models/memorial.dart';

/// שכבת גישה לנתונים.
///
/// **חשוב:** כל לוגיקת הגישה לנתונים עוברת דרך Repository זה.
/// שכבת ה-UI וה-Providers אינם ניגשים ישירות ל-SQLite.
class MemorialRepository {
  final DatabaseHelper _db;

  MemorialRepository({DatabaseHelper? db})
      : _db = db ?? DatabaseHelper.instance;

  Future<int> insert(Memorial memorial) => _db.insert(memorial);

  Future<int> update(Memorial memorial) => _db.update(memorial);

  Future<int> delete(int id) => _db.delete(id);

  Future<List<Memorial>> getAll() => _db.getAll();

  Future<Memorial?> getById(int id) => _db.getById(id);

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

  Future<void> recordBackgroundRun(DateTime at, String? error) =>
      _db.recordBackgroundRun(at, error);

  Future<({DateTime? lastRun, String? lastError})> backgroundStatus() =>
      _db.backgroundStatus();

  /// מוסיף רק את מה שאינו קיים (ייבוא במצב הוספה).
  Future<({int added, int skipped})> mergeAll(List<Memorial> memorials) =>
      _db.mergeAll(memorials);

  /// מחליף את כל הנתונים (ייבוא מ-JSON).
  Future<void> replaceAll(List<Memorial> memorials) =>
      _db.replaceAll(memorials);
}
