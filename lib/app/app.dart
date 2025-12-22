import 'package:flutter/material.dart';
import '../core/theme/app_theme.dart';
import 'routes.dart';

class ClearRentApp extends StatelessWidget {
  const ClearRentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ClearRent',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      routerConfig: appRouter,
    );
  }
}