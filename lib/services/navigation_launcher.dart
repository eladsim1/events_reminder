import 'package:url_launcher/url_launcher.dart';

import '../models/coordinates.dart';

/// פותח אפליקציות חיצוניות – ניווט, חיוג.
///
/// מרוכז כאן ולא ב-UI, כדי שהמסכים לא יתעסקו בסכמות URI, ומוזרק דרך ספק
/// כדי שבדיקות ווידג'ט לא ייגעו בפלטפורמה.
class NavigationLauncher {
  const NavigationLauncher();

  /// פותח את מסך החיוג עם [phone]. מחזיר האם נפתח.
  ///
  /// חיוג ולא שיחה ישירה: אין הרשאת CALL_PHONE, ואין סיבה שתהיה – פתיחת
  /// המסך משאירה את ההחלטה למשתמש.
  Future<bool> dial(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// פותח ניווט בוויז אל [at].
  ///
  /// ווייז ספציפית ולא בורר, בשונה מ-[openCoordinates]: זו בדיקה של הנקודה
  /// שהוקלדה, ובדיקה רוצה מסלול נהיגה מיידי ולא עוד שאלה.
  ///
  /// `navigate=yes` הוא מה שמתחיל נסיעה; בלעדיו ווייז רק מציגה את הנקודה.
  /// יש נפילה חזרה לכתובת https, שפותחת את ווייז אם היא מותקנת ואת האתר אם
  /// לא – עדיף מכפתור שלא עושה כלום במכשיר בלי ווייז.
  Future<bool> openWaze(Coordinates at) async {
    final point = '${at.latitude},${at.longitude}';

    final candidates = [
      Uri.parse('waze://?ll=$point&navigate=yes'),
      Uri.parse('https://waze.com/ul?ll=$point&navigate=yes'),
    ];

    for (final uri in candidates) {
      if (await canLaunchUrl(uri)) {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return true;
        }
      }
    }
    return false;
  }

  /// מנווט אל [at] – הקבר עצמו ולא שער בית העלמין.
  ///
  /// גם כאן `geo:` ולא ספק מסוים, כדי שאנדרואיד יציג בורר. הפרמטר `q`
  /// חוזר על הנקודה עם תווית, כי בלעדיו חלק מהאפליקציות מרכזות את המפה על
  /// הנקודה בלי לסמן אותה – ואז אין לאן ללחוץ "נווט".
  Future<bool> openCoordinates(Coordinates at, {String? label}) async {
    final point = '${at.latitude},${at.longitude}';
    final marker =
        label == null ? point : '$point(${Uri.encodeComponent(label)})';

    final candidates = [
      Uri.parse('geo:$point?q=$marker'),
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$point'),
    ];

    for (final uri in candidates) {
      if (await canLaunchUrl(uri)) {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return true;
        }
      }
    }
    return false;
  }

  /// פותח את [query] באפליקציית ניווט.
  ///
  /// משתמש בסכמת `geo:` ולא בכתובת של ספק מסוים, כדי שאנדרואיד יציג בורר
  /// ובו כל האפליקציות המותקנות – Waze, Google Maps, ואחרות. נופל חזרה
  /// לכתובת Google Maps בדפדפן אם אין אפליקציית ניווט.
  ///
  /// מחזיר האם נפתח משהו.
  Future<bool> openBurialLocation(String query) async {
    final encoded = Uri.encodeComponent(query);

    final candidates = [
      Uri.parse('geo:0,0?q=$encoded'),
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$encoded'),
    ];

    for (final uri in candidates) {
      if (await canLaunchUrl(uri)) {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return true;
        }
      }
    }
    return false;
  }
}
