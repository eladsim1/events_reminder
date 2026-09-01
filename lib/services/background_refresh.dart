import 'package:workmanager/workmanager.dart';

import '../repository/memorial_repository.dart';
import 'notification_service.dart';

/// רענון תקופתי של חלון ההתראות, בלי שהמשתמש יפתח את האפליקציה.
///
/// **למה זה נחוץ.** התראה מתוזמנת היא חד-פעמית, ומספר האזעקות הפעילות מוגבל
/// בידי אנדרואיד – ולכן מתוזמנות רק התזכורות הקרובות ביותר. כשאחת מהן נורית
/// מתפנה מקום, אבל **אף אחד לא ממלא אותו**: מקלט ההפעלה-מחדש רק רושם מחדש
/// אזעקות קיימות ואינו מחשב חדשות, ולפלאגין ההתראות אין קריאה חוזרת על
/// מסירה. עד עכשיו החלון החליק קדימה רק בפתיחת האפליקציה, וברשימה גדולה זה
/// אומר שתזכורת רחוקה עלולה להמתין לפתיחה שלא תבוא.
///
/// עבודה שבועית סוגרת את הפער בלי לבקש דבר מהמשתמש.
class BackgroundRefresh {
  /// שם ייחודי – WorkManager מזהה לפיו את העבודה ומחליף אותה במקום לשכפל.
  static const String uniqueName = 'azkarot-weekly-refresh';
  static const String taskName = 'refreshReminderWindow';

  static const Duration frequency = Duration(days: 7);

  /// רושם את העבודה. בטוח לקריאה חוזרת בכל עלייה של האפליקציה.
  ///
  /// כשל ברישום נבלע בכוונה: בסביבה בלי WorkManager – בדיקות, שולחן עבודה –
  /// הקריאה נכשלת, ואסור שהיא תפיל את עליית האפליקציה. הרענון עצמו הוא
  /// שכבת גיבוי, לא הנתיב העיקרי.
  static Future<void> register() async {
    try {
      await _register();
    } catch (_) {}
  }

  static Future<void> _register() async {
    await Workmanager().initialize(backgroundRefreshDispatcher);
    await Workmanager().registerPeriodicTask(
      uniqueName,
      taskName,
      frequency: frequency,
      // מחליף רישום קיים, אחרת שינוי בתדירות לא היה נכנס לתוקף לעולם:
      // WorkManager שומר על המקורית כשהוא מתבקש "לשמור".
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      // אין צורך ברשת – הכול מקומי. בסוללה נמוכה אפשר לוותר: התזכורות
      // הקרובות כבר מתוזמנות, ומה שמתרענן כאן הוא החלון הרחוק.
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: true,
      ),
    );
  }

  /// העבודה עצמה: טוענת את האזכרות ומתזמנת מחדש.
  ///
  /// רצה ב-isolate נפרד, בלי Riverpod ובלי מצב מסך – ולכן היא מרכיבה את
  /// השירותים ישירות.
  static Future<bool> run() async {
    try {
      final memorials = await MemorialRepository().getAll();
      if (memorials.isEmpty) return true;
      await NotificationService().rescheduleAll(memorials);
      return true;
    } catch (_) {
      // כשל כאן אינו קריטי: החלון יתרענן בפתיחה הבאה, ובנוסף מנגנון
      // ההשלמה מציג תזכורת שמועדה חלף. החזרת false תגרום ל-WorkManager
      // לנסות שוב.
      return false;
    }
  }
}

/// נקודת הכניסה של ה-isolate שמריץ את העבודה.
///
/// חייבת להיות ברמת הקובץ ומסומנת ב-vm:entry-point, אחרת אנדרואיד לא יוכל
/// להיכנס אליה ו-tree shaking יסיר אותה ב-release.
@pragma('vm:entry-point')
void backgroundRefreshDispatcher() {
  Workmanager().executeTask((task, inputData) => BackgroundRefresh.run());
}
