import 'package:url_launcher/url_launcher.dart';

/// פותח ניווט אל מיקום הקבר.
///
/// מרוכז כאן ולא ב-UI, כדי שהמסכים לא יתעסקו בסכמות URI.
class NavigationLauncher {
  const NavigationLauncher();

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
