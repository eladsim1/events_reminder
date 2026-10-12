import 'package:flutter/material.dart';

/// שתי טבעות שלובות, מצוירות.
///
/// ל-Material Icons אין טבעות נישואין, והאפשרויות האחרות גרועות: אמוג'י 💍
/// מרונדר בגופן של המערכת – כלומר בצורה ובצבע שהיצרן בחר, ובבדיקות ווידג'ט
/// הוא אפילו לא מרונדר כלל אלא כמלבן ריק – וקובץ תמונה מיטשטש בכל גודל שלא
/// נוצר בו. ציור נשאר חד בכל מידה, ומקבל את הצבע של סוג האירוע.
///
/// **שתי טבעות ולא אחת.** טבעת בודדת בגודל 16 פיקסלים אינה נבדלת מעיגול,
/// והצירוף השלוב הוא מה שקוראים כנישואין. הקווים עבים ביחס לגודל מאותה סיבה
/// שהמגן דוד צויר כמצולע אחד: קו דק בגודל הזה נעלם.
class WeddingRings extends StatelessWidget {
  const WeddingRings({super.key, this.size = 18, this.color});

  final double size;

  /// null לוקח את צבע הטקסט שבהקשר – כך הסימן מתיישר עם הכיתוב שלצדו.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final paint = color ?? IconTheme.of(context).color ?? Colors.black;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _RingsPainter(paint)),
    );
  }
}

class _RingsPainter extends CustomPainter {
  const _RingsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide * 0.30;
    final stroke = size.shortestSide * 0.12;

    final brush = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color;

    final y = size.height * 0.58;
    // חופפות, אך לא מרוכזות: חפיפה חלקית היא מה שקורא כשתי טבעות שלובות
    // ולא כשמינה אחת.
    canvas.drawCircle(Offset(size.width * 0.37, y), r, brush);
    canvas.drawCircle(Offset(size.width * 0.63, y), r, brush);
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.color != color;
}
