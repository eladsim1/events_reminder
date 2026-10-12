import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/event_provider.dart';
import '../services/background_refresh.dart';
import '../widgets/confetti.dart';
import 'home_screen.dart';

/// מסך פתיחה.
///
/// אחראי על:
///  - אתחול מסד הנתונים (מתבצע בעצלתיים דרך ה-Repository).
///  - טעינת כל האירועים (SQLite בלבד).
///  - רישום העבודה השבועית ברקע.
///  - מעבר למסך הראשי.
///
/// מה שהוא **אינו** עושה, במכוון: אתחול פלאגין ההתראות, בקשת הרשאות
/// ותזמון. אלה עולים עשרות קריאות פלטפורמה לכל אירוע, וכשהם חסמו כאן
/// האפליקציה נראתה תקועה בכל עלייה. ההרשאות נשאלות מהבאנר במסך הראשי,
/// שם גם רואים למה הן נחוצות.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  String _status = 'מאתחל...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      // רק קריאת SQLite לפני המעבר למסך הראשי. כל עבודת ההתראות – אתחול
      // הפלאגין, בקשת הרשאות, השלמות ותזמון – עולה עשרות קריאות פלטפורמה
      // לכל אירוע, וכשהיא חסמה כאן האפליקציה נראתה תקועה בכל עלייה.
      await ref.read(eventListProvider.notifier).load();

      // רישום העבודה השבועית שמחליקה את חלון ההתראות קדימה גם בלי שהמשתמש
      // יפתח את האפליקציה. לא מומתן, כמו כל עבודת ההתראות.
      unawaited(BackgroundRefresh.register());

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'שגיאה באתחול: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Stack(
        children: [
          // קונפטי מאחורי הכול. מסך הפתיחה נראה לרגע אחד, וזה הרגע שבו
          // אומרים לאיזו אפליקציה נכנסת – ציור דטרמיניסטי, ולכן גם ה-golden
          // שלו יציב.
          const Positioned.fill(child: Confetti(seed: 3, count: 34)),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.celebration,
                  size: 72,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'תזכורת אירועים',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 32),
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_status, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          // חתימת המפתח בתחתית. ב-Stack ולא בתוך העמודה, כדי שלא תזיז את
          // הכותרת מהמרכז.
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: 24 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Image.asset(
                'assets/app_icon.png',
                // גדול מ-48: בגודל הקטן הלוגו נקרא ככתם ולא כחתימה.
                width: 88,
                height: 88,
                // הנכס נארז ב-APK, אך נפילה שקטה עדיפה על מסך פתיחה שבור.
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
