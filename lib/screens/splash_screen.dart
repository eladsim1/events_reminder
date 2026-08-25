import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/memorial_provider.dart';
import 'home_screen.dart';

/// מסך פתיחה.
///
/// אחראי על:
///  - אתחול מסד הנתונים (מתבצע בעצלתיים דרך ה-Repository).
///  - אתחול timezone ו-NotificationService.
///  - בקשת הרשאת התראות.
///  - טעינת כל האזכרות ותזמון התראות חסרות.
///  - מעבר למסך הראשי.
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
      // לכל אזכרה, וכשהיא חסמה כאן האפליקציה נראתה תקועה בכל עלייה.
      await ref.read(memorialListProvider.notifier).load();

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
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('🕯', style: TextStyle(fontSize: 72)),
                const SizedBox(height: 16),
                Text(
                  'תזכורת אזכרות',
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
          // הנר והכותרת מהמרכז.
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: 24 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Image.asset(
                'assets/app_icon.png',
                width: 48,
                height: 48,
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
