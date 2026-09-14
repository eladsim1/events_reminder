import 'package:flutter/material.dart';

/// צבע הבסיס של האפליקציה.
///
/// Material 3 גוזר ערכה שלמה – רקעים, כרטיסים, שבבים, מצב בהיר ומצב כהה –
/// מצבע יחיד. לכן הבחירה כאן היא בגוון אחד, ולא ברשימת צבעים לכל רכיב:
/// ערכה שנגזרת שומרת על ניגודיות תקינה בכל צירוף, ובחירה ידנית לכל רכיב
/// מייצרת שילובים בלתי קריאים בלי שאיש ישים לב.
///
/// הגוונים כאן עמומים בכוונה. זו אפליקציית אזכרות, וצבע רווי היה צועק.
enum ThemeSeed {
  violet('סגול', Color(0xFF5B4B8A)),
  indigo('כחול', Color(0xFF33518C)),
  teal('טורקיז', Color(0xFF1F6F6B)),
  green('ירוק', Color(0xFF3F6B4A)),
  olive('זית', Color(0xFF6B6B33)),
  brown('חום', Color(0xFF7A5230)),
  burgundy('בורדו', Color(0xFF7B3B4A)),
  slate('אפור־כחול', Color(0xFF4A5568));

  const ThemeSeed(this.label, this.color);

  final String label;
  final Color color;

  /// ברירת המחדל של האפליקציה, ומה שהיה בה עד שהבחירה נוספה.
  static const ThemeSeed fallback = ThemeSeed.violet;

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
