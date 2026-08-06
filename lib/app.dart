import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/splash_screen.dart';

/// שורש האפליקציה. מגדיר Material 3, RTL מלא, עברית, ותמיכה במצב כהה.
class AzkarotApp extends StatelessWidget {
  const AzkarotApp({super.key});

  static const _seedColor = Color(0xFF5B4B8A);

  @override
  Widget build(BuildContext context) {
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
        colorScheme: ColorScheme.fromSeed(seedColor: _seedColor),
        cardTheme: const CardThemeData(clipBehavior: Clip.antiAlias),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ),
        cardTheme: const CardThemeData(clipBehavior: Clip.antiAlias),
      ),

      home: const SplashScreen(),
    );
  }
}
