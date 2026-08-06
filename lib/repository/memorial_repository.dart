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

  /// מחליף את כל הנתונים (ייבוא מ-JSON).
  Future<void> replaceAll(List<Memorial> memorials) =>
      _db.replaceAll(memorials);
}
