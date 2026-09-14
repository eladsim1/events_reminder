import 'dart:math' as math;

import 'package:flutter/material.dart';

/// מגן דוד מוזהב, מצויר ולא אייקון.
///
/// ל-Material Icons אין מגן דוד, והאפשרויות האחרות גרועות: אמוג'י ✡️ מרונדר
/// בגופן של המערכת, כלומר בצבע שהיצרן בחר ובצורה שמשתנה בין מכשירים, וקובץ
/// תמונה היה מיטשטש בכל גודל שלא נוצר בו. ציור נשאר חד בכל גודל, ומקבל את
/// הזהב שהתבקש.
///
/// **מצויר כמצולע אחד ולא כשני משולשים.** בגודל 14 פיקסלים – הגודל שעל
/// הכרטיס – קווי מתאר של שני משולשים נבלעים זה בזה ונראים ככתם; צורה מלאה
/// אחת עם מתאר כהה נשארת מובחנת.
class MagenDavid extends StatelessWidget {
  const MagenDavid({super.key, this.size = 14, this.sparkle = true});

  final double size;

  /// הנצנוץ. מצויר רק מגודל [_sparkleFrom] ומעלה: בגודל הכרטיס הוא הופך
  /// לפיקסל בודד שנראה כלכלוך ולא כברק.
  final bool sparkle;

  static const double _sparkleFrom = 18;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _MagenPainter(sparkle: sparkle && size >= _sparkleFrom),
        ),
      );
}

class _MagenPainter extends CustomPainter {
  const _MagenPainter({required this.sparkle});

  final bool sparkle;

  /// זהב: בהיר למעלה-שמאל, עמוק למטה-ימין. זו ההטיה שקוראים כמתכת ולא
  /// כצהוב שטוח.
  static const _pale = Color(0xFFFFF1B8);
  static const _gold = Color(0xFFE8B923);
  static const _deep = Color(0xFF9A6E05);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    // מקום למתאר, אחרת הוא נחתך בקצוות.
    final r = math.min(size.width, size.height) / 2 - size.width * 0.04;

    final path = _hexagram(c, r);
    final rect = Rect.fromCircle(center: c, radius: r);

    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_pale, _gold, _deep],
          stops: [0.0, 0.55, 1.0],
        ).createShader(rect),
    );

    // מתאר כהה: בלעדיו הצורה נמסה לתוך רקע בהיר ונעלמת בגודל קטן.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.6, size.width * 0.045)
        ..strokeJoin = StrokeJoin.round
        ..color = _deep.withValues(alpha: 0.85),
    );

    if (!sparkle) return;

    // ברק יחיד בזרוע העליונה-שמאלית, בכיוון שממנו בא האור בגרדיאנט.
    final at = c + Offset(-r * 0.42, -r * 0.46);
    final s = r * 0.30;
    final glint = Path()
      ..moveTo(at.dx, at.dy - s)
      ..quadraticBezierTo(at.dx, at.dy, at.dx + s, at.dy)
      ..quadraticBezierTo(at.dx, at.dy, at.dx, at.dy + s)
      ..quadraticBezierTo(at.dx, at.dy, at.dx - s, at.dy)
      ..quadraticBezierTo(at.dx, at.dy, at.dx, at.dy - s)
      ..close();
    canvas.drawPath(
        glint, Paint()..color = Colors.white.withValues(alpha: 0.9));
  }

  /// מגן דוד כמצולע בן 12 קודקודים: שישה חיצוניים ברדיוס [r] ושישה
  /// פנימיים ברדיוס r/√3 – היחס שנותן בדיוק שני משולשים שווי-צלעות
  /// חופפים, ולא צורה שרק דומה להם.
  Path _hexagram(Offset c, double r) {
    final inner = r / math.sqrt(3);
    final path = Path();
    for (var i = 0; i < 12; i++) {
      final radius = i.isEven ? r : inner;
      final a = -math.pi / 2 + i * math.pi / 6;
      final p = c + Offset(math.cos(a) * radius, math.sin(a) * radius);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_MagenPainter old) => old.sparkle != sparkle;
}
