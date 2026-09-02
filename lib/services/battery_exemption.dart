import 'package:flutter/services.dart';

/// הפטור של האפליקציה מאופטימיזציית הסוללה של אנדרואיד.
///
/// **למה זה כאן.** אפליקציה שאנדרואיד מרשה לעצור אינה מאבדת רק ריצה ברקע –
/// היא מאבדת את **האזעקות הרשומות שלה**, כולל כאלה שתוזמנו מזמן. זה הכשל
/// היחיד שנשאר שיכול לגרום לפספוס ודאי בלי שאף שכבה באפליקציה תדע על כך.
///
/// **מה זה לא פותר, וחשוב לא להבטיח יותר.** רשימת "אפליקציות ישנות" של
/// סמסונג מנוהלת בנפרד, ואין ממשק שמאפשר לאפליקציה לצאת ממנה או למנוע
/// הכנסה אליה – סמסונג מוסיפה לפי דפוס שימוש, ואפליקציה שכמעט לא פותחים
/// היא מועמדת מובהקת. הפטור מקטין את הסיכוי משמעותית ואינו מאפס אותו.
///
/// **הערה להפצה:** REQUEST_IGNORE_BATTERY_OPTIMIZATIONS היא הרשאה מוגבלת
/// ב-Google Play, המאושרת לקטגוריות מצומצמות. להפצה בחנות ייתכן שיהיה צורך
/// להסתפק בהפניית המשתמש להגדרות במקום בדיאלוג הישיר.
class BatteryExemption {
  static const MethodChannel _channel = MethodChannel('azkarot_app/battery');

  const BatteryExemption();

  /// האם האפליקציה פטורה כרגע.
  ///
  /// מחוץ לאנדרואיד – בדיקות, שולחן עבודה – אין ערוץ, ומחזירים "פטורה" כדי
  /// לא להציג אזהרה על מצב שאינו קיים שם.
  Future<bool> isExempt() async {
    try {
      return await _channel.invokeMethod<bool>('isExempt') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// פותח את בקשת הפטור. שקט אם אין ערוץ.
  Future<void> request() async {
    try {
      await _channel.invokeMethod<void>('requestExemption');
    } on PlatformException {
      // המשתמש יופנה להגדרות ידנית; אין מה להפיל בגלל זה.
    } on MissingPluginException {
      // ignore
    }
  }
}
