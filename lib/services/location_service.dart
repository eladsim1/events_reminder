import 'package:geolocator/geolocator.dart';

import '../models/coordinates.dart';

/// למה הקריאה נכשלה, כשהיא נכשלת.
///
/// לא כל הכשלים שווים: הרשאה שנדחתה נפתרת בלחיצה נוספת, דחייה לצמיתות
/// נפתרת רק בהגדרות, ו-GPS כבוי אינו קשור להרשאות בכלל. הודעה אחת לכולם
/// הייתה שולחת את המשתמש למקום הלא נכון.
enum LocationFailure { denied, deniedForever, serviceOff, unavailable }

class LocationResult {
  final Coordinates? point;
  final LocationFailure? failure;

  const LocationResult.success(Coordinates this.point) : failure = null;
  const LocationResult.failed(LocationFailure this.failure) : point = null;
}

/// המיקום הנוכחי של המכשיר, לקביעת נקודת ציון של קבר.
///
/// **זו הדרך שבה באמת קובעים נ"צ של קבר:** עומדים לידו ולוחצים. העתקה
/// והדבקה ממפה עובדת, אבל היא מדויקת פחות ודורשת לזהות את השורה הנכונה
/// בתצוגת לוויין.
///
/// ההרשאה נדרשת רק בלחיצה על הכפתור. שימוש רגיל באפליקציה אינו נוגע בה.
class LocationService {
  const LocationService();

  Future<LocationResult> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationResult.failed(LocationFailure.serviceOff);
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return const LocationResult.failed(LocationFailure.deniedForever);
      }
      if (permission == LocationPermission.denied) {
        return const LocationResult.failed(LocationFailure.denied);
      }

      // דיוק גבוה: ההבדל בין קבר לקבר שכן הוא מטרים בודדים, ודיוק בינוני
      // לא מבחין ביניהם. הפסק זמן קיים כי בתוך בית עלמין קליטת GPS יכולה
      // לקחת זמן, וכפתור שנתקע בלי סוף גרוע מהודעת כשל.
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 30),
        ),
      );

      final point = Coordinates(position.latitude, position.longitude);
      return Coordinates.isValid(point.latitude, point.longitude)
          ? LocationResult.success(point)
          : const LocationResult.failed(LocationFailure.unavailable);
    } catch (_) {
      // פסק זמן, מכשיר בלי GPS, או פלטפורמה שאין בה ערוץ (בדיקות).
      return const LocationResult.failed(LocationFailure.unavailable);
    }
  }
}
