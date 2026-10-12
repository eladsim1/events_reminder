import 'package:url_launcher/url_launcher.dart';

/// פותח את מסך החיוג של המכשיר.
///
/// מרוכז כאן ולא ב-UI כדי שהמסכים לא יתעסקו בסכמות URI, ומוזרק דרך ספק
/// כדי שבדיקות ווידג'ט לא ייגעו בפלטפורמה.
class PhoneLauncher {
  const PhoneLauncher();

  /// פותח את מסך החיוג עם [phone]. מחזיר האם נפתח.
  ///
  /// חיוג ולא שיחה ישירה: אין הרשאת CALL_PHONE, ואין סיבה שתהיה – פתיחת
  /// המסך משאירה את ההחלטה למשתמש.
  ///
  /// **`tel:` חייב להיות מוצהר ב-`<queries>` שבמניפסט.** בלי ההצהרה
  /// `canLaunchUrl` מחזיר false מאנדרואיד 11 ומעלה גם כשיש אפליקציית חיוג,
  /// והכפתור פשוט אינו עושה דבר.
  Future<bool> dial(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
