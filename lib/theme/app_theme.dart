import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppPalette {
  static const azulOscuro = Color(0xFF1E3A8A);
  static const celesteClaro = Color(0xFF60A5FA);
  static const turquesaBrillante = Color(0xFF3EE0C2);
  static const verdeAzulado = Color(0xFF1CA7A1);
  static const exito = Color(0xFF22C55E);
  static const alerta = Color(0xFFF59E0B);
  static const error = Color(0xFFEF4444);
}

class AppTheme {
  static ThemeData light() {
    return _base(
      brightness: Brightness.light,
      surface: Colors.white.withValues(alpha: 0.86),
      onSurface: const Color(0xFF0F172A),
    );
  }

  static ThemeData dark() {
    return _base(
      brightness: Brightness.dark,
      surface: const Color(0xFF081329).withValues(alpha: 0.84),
      onSurface: Colors.white,
    );
  }

  static ThemeData _base({
    required Brightness brightness,
    required Color surface,
    required Color onSurface,
  }) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppPalette.verdeAzulado,
      brightness: brightness,
      primary: isDark ? AppPalette.turquesaBrillante : AppPalette.azulOscuro,
      secondary: isDark ? AppPalette.celesteClaro : AppPalette.verdeAzulado,
      tertiary: AppPalette.turquesaBrillante,
      error: AppPalette.error,
      surface: surface,
      onSurface: onSurface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF06101F)
          : const Color(0xFFF4FAFF),
      textTheme: GoogleFonts.robotoCondensedTextTheme(
        ThemeData(brightness: brightness).textTheme,
      ).apply(bodyColor: onSurface, displayColor: onSurface),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.primary,
        contentTextStyle: GoogleFonts.robotoCondensed(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: scheme.primary.withValues(alpha: 0.42),
          disabledForegroundColor: Colors.white70,
          minimumSize: const Size.fromHeight(52),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: onSurface,
          backgroundColor: surface.withValues(alpha: isDark ? 0.18 : 0.74),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  static String backgroundFor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? 'assets/fondo2.png'
        : 'assets/fondo1.png';
  }

  static Color glassSurface(BuildContext context, {double? alpha}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return theme.colorScheme.surface.withValues(
      alpha: alpha ?? (isDark ? 0.78 : 0.84),
    );
  }

  static Color glassBorder(BuildContext context, {double alpha = 0.28}) {
    final theme = Theme.of(context);
    return (theme.brightness == Brightness.dark
            ? AppPalette.turquesaBrillante
            : AppPalette.azulOscuro)
        .withValues(alpha: alpha);
  }
}
