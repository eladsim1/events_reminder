import 'package:flutter/material.dart';

/// צבע הבסיס של האפליקציה.
///
/// Material 3 גוזר ערכה שלמה – רקעים, כרטיסים, שבבים, מצב בהיר ומצב כהה –
/// מצבע יחיד. לכן הבחירה כאן היא בגוון אחד, ולא ברשימת צבעים לכל רכיב:
/// ערכה שנגזרת שומרת על ניגודיות תקינה בכל צירוף, ובחירה ידנית לכל רכיב
/// מייצרת שילובים בלתי קריאים בלי שאיש ישים לב.
///
/// **הגוונים כאן רוויים בכוונה.** זו אפליקציה של ימי הולדת וימי נישואין,
/// והיא אמורה להיראות כך ברגע שפותחים אותה. הגבול היחיד הוא קריאוּת: כל
/// גוון נבחר כך שהערכה שנגזרת ממנו עומדת בניגודיות גם במצב כהה.
enum ThemeSeed {
  rose('ורוד', Color(0xFFE23C77)),
  coral('אלמוג', Color(0xFFF2542D)),
  amber('ענבר', Color(0xFFEF9A00)),
  lime('ליים', Color(0xFF63B222)),
  turquoise('טורקיז', Color(0xFF00A6A6)),
  sky('תכלת', Color(0xFF2E86DE)),
  violet('סגול', Color(0xFF8A4FFF)),
  fuchsia('פוקסיה', Color(0xFFC724B1));

  const ThemeSeed(this.label, this.color);

  final String label;
  final Color color;

  /// ברירת המחדל של האפליקציה.
  static const ThemeSeed fallback = ThemeSeed.rose;

  String get dbValue => name;

  /// ערך לא מוכר – גיבוי מגרסה חדשה יותר, או שדה פגום – חוזר לברירת
  /// המחדל ואינו מפיל דבר. ערכה היא העדפה, לא נתון.
  static ThemeSeed fromDb(String? value) {
    if (value == null) return fallback;
    return ThemeSeed.values.firstWhere(
      (e) => e.name == value,
      orElse: () => fallback,
    );
  }
}
