/// נקודת ציון של מקום הקבר.
///
/// חיפוש טקסטואלי ("הר המנוחות, חלקה ז") מביא לשער בית העלמין; נקודת ציון
/// מביאה לקבר עצמו. זו הסיבה שהיא קיימת לצד השדות הקיימים ולא במקומם.
class Coordinates {
  final double latitude;
  final double longitude;

  const Coordinates(this.latitude, this.longitude);

  /// גבולות התקפות של קואורדינטות גיאוגרפיות.
  static bool isValid(double lat, double lng) =>
      lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;

  /// מחלץ נקודת ציון מטקסט חופשי, או null אם אין בו כזו.
  ///
  /// **סלחני בכוונה.** אנשים לא מקלידים קואורדינטות – הם מדביקים אותן, ומה
  /// שמודבק תלוי מאיפה: "31.7683, 35.2137" מ-Google Maps, אותו דבר בלי
  /// רווח, או כתובת שלמה כמו
  /// `https://maps.google.com/?q=31.7683,35.2137`. דרישה לפורמט אחד הייתה
  /// הופכת פעולה של הדבקה לעבודה.
  ///
  /// נלקח **הזוג הראשון** בטקסט: בכתובות של Google הוא הנקודה עצמה, ומה
  /// שאחריו הוא רמת זום ופרמטרים אחרים.
  static Coordinates? tryParse(String? text) {
    if (text == null) return null;

    // פענוח קידוד אחוזים לפני הכול. **קישור שיתוף של ווייז מקודד את הפסיק
    // כ-%2C**, וכל עוד לא פוענח הוא נראה כמו שני מספרים בלי מפריד ולא נקרא
    // כלל – בדיוק באפליקציה שאנשים משתמשים בה כדי לשתף מיקום.
    final decoded = _decoded(text);

    // מספר עשרוני, אולי שלילי, ואחריו מפריד שאינו ספרה, ואז עוד אחד.
    final match = RegExp(r'(-?\d+(?:\.\d+)?)\s*[,;\s]\s*(-?\d+(?:\.\d+)?)')
        .firstMatch(decoded);
    if (match == null) return null;

    final lat = double.tryParse(match.group(1)!);
    final lng = double.tryParse(match.group(2)!);
    if (lat == null || lng == null || !isValid(lat, lng)) return null;

    return Coordinates(lat, lng);
  }

  /// מפענח קידוד אחוזים, ומחזיר את המקור אם הקידוד פגום.
  ///
  /// טקסט שהודבק בטעות באמצע עלול להיות קידוד לא חוקי, ואז decodeFull זורק.
  /// עדיף לנסות לקרוא את המקור מאשר להיכשל.
  static String _decoded(String text) {
    try {
      return Uri.decodeFull(text);
    } catch (_) {
      return text;
    }
  }

  /// הצורה שמוצגת ומודבקת חזרה. שש ספרות הן דיוק של כ-11 ס"מ – די והותר
  /// לקבר, ומעבר לזה הן רעש.
  @override
  String toString() =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';

  @override
  bool operator ==(Object other) =>
      other is Coordinates &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);
}
