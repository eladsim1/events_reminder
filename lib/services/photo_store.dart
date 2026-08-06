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
  const PhotoStore();

  static const String _folder = 'memorial_photos';

  /// רוחב/גובה מרבי לשמירה.
  ///
  /// התמונה מוצגת כאווטאר בקוטר 48 – 256 פיקסלים מספיקים גם למסך בצפיפות
  /// 3x. הקטנה כאן חוסכת מגה-בייטים לכל אזכרה, ובעיקר מאפשרת להטמיע את
  /// התמונה בגיבוי ה-JSON בגודל סביר.
  static const int maxDimension = 256;

  Future<Directory> _photoDir() async {
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, _folder),
    );
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// פותח בורר תמונות ומחזיר נתיב מקומי קבוע, או null אם המשתמש ביטל.
  Future<String?> pickAndStore() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'בחירת תמונה',
      type: FileType.image,
    );
    final source = result?.files.single.path;
    if (source == null) return null;

    return storeBytes(await File(source).readAsBytes());
  }

  /// מקטין ושומר [bytes], ומחזיר את הנתיב שנוצר.
  Future<String> storeBytes(Uint8List bytes) async {
    final resized = await downscale(bytes);
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
  Future<Uint8List> downscale(Uint8List bytes) async {
    final descriptor = await ui.ImageDescriptor.encoded(
      await ui.ImmutableBuffer.fromUint8List(bytes),
    );

    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;

    // כבר קטנה מספיק – לא מפענחים ומקודדים מחדש סתם.
    if (longest <= maxDimension) {
      descriptor.dispose();
      return bytes;
    }

    final scale = maxDimension / longest;
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
  Future<String?> restoreFromBase64(String? data) async {
    if (data == null || data.isEmpty) return null;
    try {
      return await storeBytes(base64Decode(data));
    } catch (_) {
      // גיבוי פגום לא אמור להפיל את כל הייבוא.
      return null;
    }
  }
}
