import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final bg         = isDark ? AppColors.background     : AppColors.backgroundLight;
    final surfaceLow = isDark ? AppColors.surfaceLow     : AppColors.surfaceLowLight;
    final surfaceHi  = isDark ? AppColors.surfaceHigh    : AppColors.surfaceHighLight;
    final primary    = isDark ? AppColors.primary        : AppColors.primaryLight;
    final border     = isDark ? AppColors.borderSubtle   : AppColors.borderSubtleLight;
    final onPrimary  = isDark ? Colors.black             : Colors.white;

    return ThemeData(
      brightness: brightness,
      useMaterial3: true,

      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
      ).copyWith(
        surface: bg,
        surfaceContainerLow: surfaceLow,
        surfaceContainerHigh: surfaceHi,
        primary: primary,
        onPrimary: onPrimary,
        error: AppColors.danger,
      ),
      scaffoldBackgroundColor: bg,

      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),

      cardTheme: CardThemeData(
        color: surfaceLow,
        elevation: isDark ? 0 : 1,
        shadowColor: isDark ? null : Colors.black12,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: border, width: 1),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: onPrimary,
          backgroundColor: primary,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          side: BorderSide(color: border),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceLow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: primary.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceHi,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        showDragHandle: true,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearMinHeight: 6,
      ),

      dividerTheme: DividerThemeData(
        color: border,
        thickness: 1,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
      ),
    );
  }
}
