import 'dart:math' as math;

import 'package:flutter/material.dart';

/// קונפטי מצויר – שכבת רקע חגיגית.
///
/// מצויר ולא תמונה ולא אנימציה, משתי סיבות: קובץ תמונה מיטשטש בכל גודל
/// שלא נוצר בו, ואנימציה שרצה תמיד היא רעש שגוזל סוללה באפליקציה שנפתחת
/// לרגע. ציור נשאר חד בכל מידה ועולה כמה עשרות מלבנים.
///
/// **הפיזור דטרמיניסטי בכוונה.** [seed] קבוע, ולכן אותו ווידג'ט מצייר
/// בדיוק את אותו קונפטי בכל ריצה – אחרת כל צילום golden היה נכשל מול קודמו
/// בלי שאיש שינה דבר. מי שרוצה פיזור אחר במקום אחר מעביר seed אחר.
class Confetti extends StatelessWidget {
  const Confetti({
    super.key,
    this.seed = 7,
    this.count = 26,
    this.opacity = 0.9,
  });

  /// זרע הפיזור. אותו זרע = אותה תמונה.
  final int seed;

  /// כמה פיסות. מעל ~40 זה מתחיל להיראות כמו לכלוך ולא כמו חגיגה.
  final int count;

  final double opacity;

  /// הגוונים. לא נגזרים מהערכה של האפליקציה: קונפטי צבעוני הוא צבעוני,
  /// וקונפטי בגוון אחד נראה כמו טעות.
  static const List<Color> colors = [
    Color(0xFFE23C77),
    Color(0xFFF2542D),
    Color(0xFFEF9A00),
    Color(0xFF63B222),
    Color(0xFF00A6A6),
    Color(0xFF2E86DE),
    Color(0xFF8A4FFF),
  ];

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: CustomPaint(
            painter: _ConfettiPainter(seed: seed, count: count),
            size: Size.infinite,
          ),
        ),
      );
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({required this.seed, required this.count});

  final int seed;
  final int count;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed);
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < count; i++) {
      final color = Confetti.colors[random.nextInt(Confetti.colors.length)];
      paint.color = color;

      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      // טווח גדלים צר: פיסות באותו גודל נראות כתבנית, ופיסות בטווח רחב
      // נראות כאילו חלקן קרובות לעין וחלקן רחוקות.
      final w = 3.0 + random.nextDouble() * 4;
      final h = w * (1.4 + random.nextDouble());
      final angle = random.nextDouble() * math.pi;

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      // מלבן מעוגל לפיסת נייר, ועיגול לחלק מהן – תערובת קוראת כמו קונפטי
      // אמיתי, שבו לא כל הפיסות זהות.
      if (random.nextInt(4) == 0) {
        canvas.drawCircle(Offset.zero, w / 2, paint);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: w, height: h),
            Radius.circular(w / 3),
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) =>
      old.seed != seed || old.count != count;
}
