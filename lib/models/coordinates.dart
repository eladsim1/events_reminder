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

    // מספר עשרוני, אולי שלילי, ואחריו מפריד שאינו ספרה, ואז עוד אחד.
    final match = RegExp(r'(-?\d+(?:\.\d+)?)\s*[,;\s]\s*(-?\d+(?:\.\d+)?)')
        .firstMatch(text);
    if (match == null) return null;

    final lat = double.tryParse(match.group(1)!);
    final lng = double.tryParse(match.group(2)!);
    if (lat == null || lng == null || !isValid(lat, lng)) return null;

    return Coordinates(lat, lng);
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
