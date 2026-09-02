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
  NotificationService notifications,
) async {
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
