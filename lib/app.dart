import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/memorial_provider.dart';
import 'screens/splash_screen.dart';

/// שורש האפליקציה. מגדיר Material 3, RTL מלא, עברית, ותמיכה במצב כהה.
class AzkarotApp extends ConsumerWidget {
  const AzkarotApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seedColor = ref.watch(themeSeedProvider).color;
    return MaterialApp(
      title: 'תזכורת אזכרות',
      debugShowCheckedModeBanner: false,

      // עברית ו-RTL מלא.
      locale: const Locale('he'),
      supportedLocales: const [Locale('he'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },

      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
        cardTheme: const CardThemeData(clipBehavior: Clip.antiAlias),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ),
        cardTheme: const CardThemeData(clipBehavior: Clip.antiAlias),
      ),

      home: const SplashScreen(),
    );
  }
}
