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
      final notifications = ref.read(notificationServiceProvider);

      setState(() => _status = 'מאתחל התראות...');
      await notifications.init();
      await notifications.requestPermissions();

      setState(() => _status = 'טוען אזכרות...');
      await ref.read(memorialListProvider.notifier).loadAndReschedule();

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
      body: Center(
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
    );
  }
}
