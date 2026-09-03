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
  if (!await _claim(repo, owner, waitForLock)) return;

  try {
    final memorials = await repo.getAll();
    if (memorials.isEmpty) return;

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
  } finally {
    await repo.releaseSyncLock();
  }
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
    if (await repo.claimSyncLock(owner)) return true;
    if (deadline == null || !DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 200));
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
