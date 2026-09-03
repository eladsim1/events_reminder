import 'package:flutter/services.dart';

/// מה שקובע אם תזכורת אכן תגיע, ואי אפשר לשאול עליו מ-Dart.
///
/// הקבוצה הזו היא מה שנשאר אחרי שכל שאר הבדיקות באפליקציה בוחנות את הספרים
/// של עצמה. כאן שואלים את **מערכת ההפעלה**.
class DeliveryChecks {
  static const MethodChannel _channel = MethodChannel('azkarot_app/checks');

  const DeliveryChecks();

  /// פטור מאופטימיזציית סוללה.
  ///
  /// אפליקציה שאנדרואיד רשאי לעצור מאבדת את **האזעקות הרשומות שלה**, כולל
  /// כאלה שתוזמנו מזמן. **הערה להפצה:** ההרשאה לבקשת הפטור מוגבלת ב-Google
  /// Play; בחנות ייתכן שיהיה צורך להפנות להגדרות במקום לדיאלוג הישיר.
  Future<bool> batteryExempt() => _ask('batteryExempt');

  Future<void> requestBatteryExemption() => _tell('requestBatteryExemption');

  /// האם ערוץ ההתראות עצמו פעיל.
  ///
  /// חסימת הערוץ בלבד היא כשל מוחלט ושקט: הבדיקה ברמת האפליקציה עוברת
  /// בשלום, המסך נראה תקין, ושום תזכורת אינה מגיעה לעולם.
  Future<bool> channelEnabled(String channelId) =>
      _ask('channelEnabled', channelId);

  /// האם אייקון ההתראה קיים בחבילה.
  ///
  /// הוא מוגדר כמחרוזת ב-Dart, ולכן מכווץ המשאבים אינו רואה אליו הפניה.
  /// זה כבר קרה כאן: האייקון נמחק מגרסת release וכל התראה נכשלה בשקט בזמן
  /// הירי. keep.xml מגן, וזו בדיקה שנייה על המכשיר עצמו.
  Future<bool> hasNotificationIcon() => _ask('hasNotificationIcon');

  /// מזמן את אזעקת הביקורת הבאה. בטוח לקריאה חוזרת.
  Future<void> armCanary() => _tell('armCanary');

  /// מתי אזעקת הביקורת נורתה לאחרונה, או null אם מעולם לא.
  ///
  /// זו הבדיקה היחידה שבוחנת את **התנהגות המערכת** ולא את הספרים שלנו:
  /// היא אמורה לרוץ מדי יום, וחותמת שמתיישנת פירושה שאנדרואיד מדכא את
  /// האזעקות – ידיעה שמגיעה לפני שאובדת תזכורת ולא אחריה.
  ///
  /// מה שהיא **אינה** מוכיחה: שהתראה הוצגה. היא אינה מציגה התראה.
  Future<DateTime?> canaryLastFired() async {
    final millis = await _channel
        .invokeMethod<int>('canaryLastFired')
        .catchError((_) => null);
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// מחוץ לאנדרואיד – בדיקות, שולחן עבודה – אין ערוץ. מחזירים "תקין" כדי לא
  /// להזהיר על מצב שאינו קיים שם.
  Future<bool> _ask(String method, [Object? argument]) async {
    try {
      return await _channel.invokeMethod<bool>(method, argument) ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  Future<void> _tell(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // אין מה להפיל בגלל זה.
    } on MissingPluginException {
      // ignore
    }
  }
}
