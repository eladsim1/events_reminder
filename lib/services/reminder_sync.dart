import '../models/memorial.dart';
import '../repository/memorial_repository.dart';
import 'notification_service.dart';

/// רצף הסנכרון של ההתראות: השלמת תזכורות שהוחמצו, ואז תזמון מחדש.
///
/// חי כאן ולא בתוך ה-Provider כדי ששני הנתיבים יריצו **בדיוק** את אותו דבר:
/// המסך הראשי, שרץ עם Riverpod, והעבודה השבועית ברקע, שרצה ב-isolate בלי
/// Riverpod ובלי מצב מסך. כשהרצף היה כתוב רק בצד אחד, הרקע תיזמן מחדש אך
/// לא הציג תזכורת שאבדה – ואת ההפרש הזה אי אפשר היה לראות משום מקום.
///
/// **הסדר בין שני השלבים קובע.** התזמון מחדש רושם ב-[Memorial.lastNotifiedAt]
/// את המועד הקרוב הבא; אילו רץ ראשון, הוא היה מסתיר תזכורת שהוחמצה והיא לא
/// הייתה מוצגת לעולם.
Future<void> syncReminders(
  MemorialRepository repo,
  NotificationService notifications, {
  String owner = 'app',
  Duration? waitForLock,
}) async {
  // ריצה אחת בכל רגע, **בכל התהליך ולא רק ב-isolate הזה**. השמירה שבמסך
  // היא שדה בזיכרון, ולעבודה ברקע יש עותק משלה של כל סטטי – כלומר שתיהן
  // יכולות לרוץ יחד, לקרוא את אותו lastNotifiedAt ולהציג את אותה תזכורת
  // פעמיים, או לשזור ביטול ותזמון זה בזה.
  await withSyncLock(repo, owner, waitFor: waitForLock, () async {
    final memorials = await repo.getAll();

    // גם ברשימה ריקה – ואולי דווקא בה. rescheduleAll סוחף התראות שאינן
    // שייכות לאף אזכרה, וכשמחקו את האחרונה כל מה שנשאר בתור הוא כזה:
    // ביטול שרץ ברקע ולא הספיק משאיר אזעקה שתמשיך לירות לנצח, ויציאה
    // מוקדמת כאן פירושה שאיש לעולם לא יסחוף אותה.
    await _record(
      repo,
      memorials,
      await notifications.deliverMissedReminders(memorials),
    );
    await _record(
      repo,
      memorials,
      await notifications.rescheduleAll(memorials),
    );
  });
}

/// מריץ [work] תחת נעילת הסנכרון, ומחזיר האם היא נתפסה.
///
/// **כל נגיעה במאגר ההתראות חייבת לעבור כאן.** הפלאגין מחזיק את כל ההתראות
/// המתוזמנות ב-JSON יחיד, וכל תזמון או ביטול קורא אותו, משנה וכותב אותו
/// במלואו. שתי כתיבות מקבילות משני isolates מאבדות אחת מהן – **גם כשהמזהים
/// זרים לגמרי**, כי הן דורסות זו את זו ברמת הקובץ ולא ברמת הרשומה.
///
/// זה מה שהחמיץ התיקון הקודם: הוא הגן על שני מסלולי הסנכרון זה מפני זה,
/// אבל הוספה, עריכה ומחיקה המשיכו לגעת במאגר בלי נעילה.
Future<bool> withSyncLock(
  MemorialRepository repo,
  String owner,
  Future<void> Function() work, {
  Duration? waitFor,
}) async {
  if (!await _claim(repo, owner, waitFor)) return false;
  try {
    await work();
  } finally {
    await repo.releaseSyncLock();
  }
  return true;
}

/// תופס את הנעילה, ואם [wait] ניתן – ממתין לה במקום לוותר.
///
/// רוב הקוראים מוותרים בשמחה: הסנכרון רץ שוב בכל חזרה לחזית, ואין טעם
/// לחכות. הייבוא הוא היוצא מן הכלל – הוא **חייב** לתזמן מחדש, ודילוג היה
/// משאיר את המשתמש, אחרי הודעת "יובאו N אזכרות", בלי אף תזכורת מתוזמנת.
Future<bool> _claim(
  MemorialRepository repo,
  String owner,
  Duration? wait,
) async {
  final deadline = wait == null ? null : DateTime.now().add(wait);
  while (true) {
    // כשל בתפיסה אינו רק "תפוס": שני isolates שמתנגשים על אותה שורה
    // מקבלים SQLITE_BUSY, וזו חריגה. בלי התפיסה כאן היא הייתה מבטלת את
    // לולאת ההמתנה כולה – בדיוק במקרה שבשבילו היא קיימת, הייבוא.
    if (await _tryClaim(repo, owner)) return true;
    if (deadline == null || !DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<bool> _tryClaim(MemorialRepository repo, String owner) async {
  try {
    return await repo.claimSyncLock(owner);
  } catch (_) {
    // התנגשות כתיבה מול ה-isolate האחר. מבחינת הקורא זו נעילה תפוסה.
    return false;
  }
}

/// רושם לכל אזכרה את המועד שטופל.
///
/// הרישום הוא מה שמונע התראה כפולה: אחרי שהתראה מתוזמנת נורית אין דרך לדעת
/// זאת מהפלאגין, ולכן בלעדיו כל פתיחה הייתה מזהה בה "החמצה".
Future<void> _record(
  MemorialRepository repo,
  List<Memorial> memorials,
  Map<int, DateTime> handled,
) async {
  if (handled.isEmpty) return;
  for (final m in memorials) {
    final at = handled[m.id];
    if (at == null || m.lastNotifiedAt == at) continue;
    await repo.update(m.copyWith(lastNotifiedAt: at));
  }
}
