import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// בחירה, הקטנה, שמירה וגיבוי של תמונת הנפטר.
///
/// התמונה מועתקת לאחסון הפרטי של האפליקציה ולא נשארת במקור: הנתיב שבורר
/// הקבצים מחזיר הוא נתיב cache שאנדרואיד מוחק, כך שהתמונה הייתה נעלמת
/// מהכרטיס אחרי זמן מה.
class PhotoStore {
  /// [directory] גובר על אחסון האפליקציה. קיים כדי שהניקוי ייבדק על קבצים
  /// אמיתיים בתיקייה זמנית, במקום מול ערוץ פלטפורמה.
  const PhotoStore({Directory? directory}) : _override = directory;

  final Directory? _override;

  static const String _folder = 'memorial_photos';

  /// רוחב/גובה מרבי לשמירה.
  ///
  /// התמונה מוצגת כאווטאר בקוטר 48 – 256 פיקסלים מספיקים גם למסך בצפיפות
  /// 3x. הקטנה כאן חוסכת מגה-בייטים לכל אזכרה, ובעיקר מאפשרת להטמיע את
  /// התמונה בגיבוי ה-JSON בגודל סביר.
  static const int maxDimension = 256;

  /// רוחב/גובה מרבי לתמונת הקבר.
  ///
  /// גדול מזה של הדיוקן, כי התפקיד שונה: דיוקן מוצג כאווטאר בקוטר 48,
  /// ותמונת קבר נועדה שיסתכלו בה כדי למצוא את הקבר בשטח – 256 פיקסלים
  /// היו מטושטשים למטרה הזו.
  ///
  /// לא גדול מזה: התמונות נוסעות מוטמעות בגיבוי ה-JSON, וכל הכפלה של הצלע
  /// מרבעת את משקל הקובץ. 800 הוא הגבול שבו גיבוי עם עשרות אזכרות עדיין
  /// נשלח בוואטסאפ.
  static const int graveMaxDimension = 800;

  Future<Directory> _photoDir() async {
    final dir = _override ??
        Directory(
          p.join((await getApplicationSupportDirectory()).path, _folder),
        );
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// מוחק קובצי תמונה שאף אזכרה אינה מפנה אליהם. מחזיר כמה נמחקו.
  ///
  /// עד כה שום דבר לא מחק תמונות – לא מחיקת אזכרה ולא ייבוא שמחליף את
  /// הכול – והקבצים נצברו באחסון בלי שאיש מפנה אליהם.
  ///
  /// **[grace] הוא הגנה ולא אופטימיזציה.** תמונה שנבחרה בטופס נכתבת לדיסק
  /// לפני שהאזכרה נשמרת, ובאותו חלון היא יתומה לכל דבר. ניקוי בלי תקופת
  /// חסד היה מוחק אותה מתחת לידיו של מי שממלא את הטופס.
  Future<int> deleteOrphans(
    Iterable<String> keep, {
    Duration grace = const Duration(days: 1),
  }) async {
    final dir = await _photoDir();
    if (!dir.existsSync()) return 0;

    final kept = keep.toSet();
    final cutoff = DateTime.now().subtract(grace);
    var removed = 0;

    for (final entity in dir.listSync()) {
      if (entity is! File || kept.contains(entity.path)) continue;
      try {
        if (entity.statSync().modified.isAfter(cutoff)) continue;
        entity.deleteSync();
        removed++;
      } catch (_) {
        // קובץ נעול, או שנמחק בינתיים. לא סיבה להפיל ניקוי.
      }
    }
    return removed;
  }

  /// פותח בורר תמונות ומחזיר נתיב מקומי קבוע, או null אם המשתמש ביטל.
  Future<String?> pickAndStore({int? maxSide}) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'בחירת תמונה',
      type: FileType.image,
    );
    final source = result?.files.single.path;
    if (source == null) return null;

    return storeBytes(await File(source).readAsBytes(), maxSide: maxSide);
  }

  /// מקטין ושומר [bytes], ומחזיר את הנתיב שנוצר.
  Future<String> storeBytes(Uint8List bytes, {int? maxSide}) async {
    final resized = await downscale(bytes, maxSide: maxSide);
    final dir = await _photoDir();

    // שם לפי תוכן ולא לפי חותמת זמן, כדי שבחירה חוזרת של אותה תמונה לא
    // תיצור עותקים כפולים.
    final name = 'p${resized.lengthInBytes}_${resized.hashCode.abs()}.png';
    final target = File(p.join(dir.path, name));
    if (!target.existsSync()) await target.writeAsBytes(resized);
    return target.path;
  }

  /// מקטין תמונה כך שצלעה הארוכה לא תעלה על [maxDimension], ומחזיר PNG.
  ///
  /// משתמש ב-dart:ui ולא בחבילת עיבוד תמונה – אין צורך בתלות נוספת.
  Future<Uint8List> downscale(Uint8List bytes, {int? maxSide}) async {
    final limit = maxSide ?? maxDimension;
    final descriptor = await ui.ImageDescriptor.encoded(
      await ui.ImmutableBuffer.fromUint8List(bytes),
    );

    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;

    // כבר קטנה מספיק – לא מפענחים ומקודדים מחדש סתם.
    if (longest <= limit) {
      descriptor.dispose();
      return bytes;
    }

    final scale = limit / longest;
    final codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round(),
      targetHeight: (descriptor.height * scale).round(),
    );
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.png);

    frame.image.dispose();
    codec.dispose();
    descriptor.dispose();

    return data!.buffer.asUint8List();
  }

  /// מחזיר את התמונה מקודדת ב-base64 לצורך גיבוי, או null אם אין קובץ.
  Future<String?> readAsBase64(String? path) async {
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    return base64Encode(await file.readAsBytes());
  }

  /// משחזר תמונה מגיבוי ומחזיר את הנתיב החדש, או null אם [data] ריק/פגום.
  ///
  /// [maxSide] חייב להיות זה שבו נשמרה התמונה במקור: הבייטים כבר הוקטנו לפני
  /// הגיבוי, ושחזור בברירת המחדל היה מכווץ תמונת קבר מ-800 ל-256 בכל ייבוא.
  Future<String?> restoreFromBase64(String? data, {int? maxSide}) async {
    if (data == null || data.isEmpty) return null;
    try {
      return await storeBytes(base64Decode(data), maxSide: maxSide);
    } catch (_) {
      // גיבוי פגום לא אמור להפיל את כל הייבוא.
      return null;
    }
  }
}
