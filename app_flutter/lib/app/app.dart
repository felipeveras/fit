import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../features/dashboard/dashboard_controller.dart';
import '../features/dashboard/dashboard_page.dart';

class AppFit extends StatelessWidget {
  const AppFit({
    super.key,
    required this.controller,
    this.dashboardModules = const [],
  });
  final DashboardController controller;
  final List<Widget> dashboardModules;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'App Fit',
    debugShowCheckedModeBanner: false,
    locale: const Locale('pt', 'BR'),
    supportedLocales: const [Locale('pt', 'BR')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF22618B),
        surface: const Color(0xFFF2F6FA),
      ),
      scaffoldBackgroundColor: const Color(0xFFF2F6FA),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF2F6FA)),
      cardTheme: const CardThemeData(elevation: 0, color: Colors.white),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: DashboardPage(controller: controller, modules: dashboardModules),
  );
}
