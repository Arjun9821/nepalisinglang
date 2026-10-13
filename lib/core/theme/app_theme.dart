import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Central Material 3 theme: light, rounded, minimal, blue primary.
class AppTheme {
  AppTheme._();

  static const Color _primaryBlue = Color(0xFF2563EB);
  static const Color _secondaryBlue = Color(0xFF60A5FA);
  static const Color _backgroundColor = Color(0xFFF6F8FC);
  static const Color _surfaceColor = Colors.white;

  static ThemeData get lightTheme {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _primaryBlue,
        primary: _primaryBlue,
        secondary: _secondaryBlue,
        surface: _surfaceColor,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: _backgroundColor,
    );

    final textTheme = GoogleFonts.poppinsTextTheme(base.textTheme);

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: _backgroundColor,
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
        centerTitle: true,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: _surfaceColor,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _primaryBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _primaryBlue,
          side: const BorderSide(color: _primaryBlue, width: 1.4),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _surfaceColor,
        elevation: 6,
        height: 68,
        indicatorColor: _primaryBlue.withValues(alpha: 0.12),
        labelTextStyle: WidgetStateProperty.all(
          textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: _secondaryBlue.withValues(alpha: 0.12),
        labelStyle: textTheme.labelMedium?.copyWith(color: _primaryBlue),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
        ),
      ),
    );
  }
}