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
    // 강조가 아닌 글자·테두리. 시드 색에서 뽑은 강조색 기운의 중립색을 쓰지 않는다.
    final ink        = isDark ? AppColors.success        : AppColors.successLight;
    final muted      = isDark ? AppColors.onSurfaceMuted : AppColors.onSurfaceMutedLight;
    // 보조 버튼 테두리. 바탕 위 3:1 이상(다크 3.9 / 라이트 3.2).
    final outline    = isDark ? const Color(0xFF6B7080)  : const Color(0xFF8A8E98);

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
        // fromSeed는 글자·테두리·보조 면까지 시드(강조색) 기운으로 칠한다.
        // 강조는 primary 한 자리에만 남기고 나머지는 중립으로 되돌린다.
        onSurface: ink,
        onSurfaceVariant: muted,
        outline: outline,
        outlineVariant: border,
        surfaceTint: Colors.transparent,
        surfaceContainer: surfaceLow,
        surfaceContainerHighest: surfaceHi,
        secondaryContainer: surfaceHi,
        onSecondaryContainer: ink,
      ),
      scaffoldBackgroundColor: bg,

      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),

      // 라이트는 **그림자**로, 다크는 **테두리**로 카드를 나눈다.
      // 어두운 바탕에서는 그림자가 보이지 않으므로 같은 장치를 쓸 수 없다.
      // 그림자에 강조색 기를 섞으면 회색 그림자보다 부드럽게 앉는다.
      cardTheme: CardThemeData(
        color: surfaceLow,
        elevation: isDark ? 0 : 3,
        shadowColor:
            isDark ? null : primary.withValues(alpha: 0.10),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: isDark
              ? BorderSide(color: border, width: 1)
              : BorderSide.none,
        ),
      ),

      // 알약 모양을 쓰지 않는다. 칩·배지도 알약이라 화면에 같은 형태가
      // 반복되면 무엇이 주 행동인지 형태로 구분되지 않고, 그 반복 자체가
      // 생성형 시안처럼 보이게 한다. 주 행동만 각진 큰 면으로 둔다.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: onPrimary,
          backgroundColor: primary,
          minimumSize: const Size.fromHeight(56),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          // 보조 행동은 무채색이다. 주 행동(채운 버튼)과 같은 강조색 테두리를
          // 두르면 둘 중 무엇이 주 행동인지 색으로 구분되지 않는다.
          foregroundColor: ink,
          side: BorderSide(color: outline),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: ink),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceLow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: primary.withValues(alpha: 0.16),
        elevation: 0,
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
        // 입력칸은 카드보다 **눌린** 면이다. 카드와 같은 흰색이면
        // 흰 카드 위에서 어디가 입력칸인지 사라진다.
        fillColor: surfaceHi,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: border),
        ),
      ),
    );
  }
}
