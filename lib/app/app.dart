import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/theme_provider.dart';
import '../shared/widgets/connectivity_wrapper.dart';
import '../shared/widgets/upgrade_gate.dart';
import 'routes.dart';

class ClearRentApp extends ConsumerWidget {
  const ClearRentApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'ClearRent',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      routerConfig: appRouter,

      // Keeps AppColors + system chrome in sync with effective brightness
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        syncAppColorsWithBrightness(
          themeMode,
          MediaQuery.platformBrightnessOf(context),
        );

        final isDark = brightness == Brightness.dark;
        SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              isDark ? Brightness.light : Brightness.dark,
          systemNavigationBarColor:
              isDark ? const Color(0xFF1E1E1E) : Colors.white,
          systemNavigationBarIconBrightness:
              isDark ? Brightness.light : Brightness.dark,
        ));

        // The offline banner lives here — above the router, so it covers every
        // route with a single subscription. It sits OUTSIDE the KeyedSubtree so
        // a theme switch doesn't rebuild it and lose its state mid-animation.
        //
        // UpgradeGate sits inside it for the same reason and with the same
        // constraint (no Navigator above the router), but below the banner:
        // being told you're offline still matters on a blocked build, and it
        // explains why the store button does nothing.
        return ConnectivityWrapper(
          child: UpgradeGate(
            child: KeyedSubtree(
              key: ValueKey(isDark),
              child: child!,
            ),
          ),
        );
      },
    );
  }
}