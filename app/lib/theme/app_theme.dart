import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// CloudBox-style theme. Light + dark variants. Poppins throughout.
/// Design tokens extracted from the reference screenshots.
class AppTheme {
  // Brand
  static const Color accent = Color(0xFF8F93F6);         // primary lavender/purple
  static const Color accentDark = Color(0xFF6E74F2);     // hover/darker
  static const Color accentGradient1 = Color(0xFF8F93F6);
  static const Color accentGradient2 = Color(0xFFAFB3FA);

  // Light-mode
  static const Color lightBody = Color(0xFFFAFBFE);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSidebar = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFE7E9F4);
  static const Color lightTextPrimary = Color(0xFF1C2033);
  static const Color lightTextMuted = Color(0xFF767B93);
  static const Color lightSidebarActiveBg = Color(0xFFF1F1FE);

  // Dark-mode — premium neutral (Vercel/Linear/Apple). Blue lives ONLY
  // in the accent so it reads as a pop against pure-grayscale surfaces.
  static const Color darkBody = Color(0xFF0A0A0A);            // near-black canvas
  static const Color darkSurface = Color(0xFF141414);         // cards / panels
  static const Color darkSidebar = Color(0xFF0F0F0F);         // one notch darker for depth
  static const Color darkBorder = Color(0xFF262626);          // hairline divider
  static const Color darkTextPrimary = Color(0xFFF5F5F5);     // off-white, easier on eyes
  static const Color darkTextMuted = Color(0xFFA3A3A3);       // neutral-400
  static const Color darkSidebarActiveBg = Color(0xFF1A1A22); // black with whisper of accent

  // File-type icon palette
  static const Color fileRed = Color(0xFFEF4444);
  static const Color fileBlue = Color(0xFF3B82F6);
  static const Color fileGreen = Color(0xFF10B981);
  static const Color fileOrange = Color(0xFFF59E0B);
  static const Color filePurple = Color(0xFF8B5CF6);

  // Folder tile palette (pastel bg + stronger letter)
  static const folderPalette = <(Color, Color)>[
    (Color(0xFFFDE2E4), Color(0xFFFB7185)), // pink
    (Color(0xFFE0E7FF), Color(0xFF8B5CF6)), // purple
    (Color(0xFFFEF3C7), Color(0xFFF59E0B)), // amber
    (Color(0xFFD1FAE5), Color(0xFF10B981)), // green
    (Color(0xFFDBEAFE), Color(0xFF3B82F6)), // blue
    (Color(0xFFFAE8FF), Color(0xFFA855F7)), // fuchsia
  ];

  static ThemeData light() {
    return _build(
      brightness: Brightness.light,
      body: lightBody,
      surface: lightSurface,
      border: lightBorder,
      textPrimary: lightTextPrimary,
      textMuted: lightTextMuted,
    );
  }

  static ThemeData dark() {
    return _build(
      brightness: Brightness.dark,
      body: darkBody,
      surface: darkSurface,
      border: darkBorder,
      textPrimary: darkTextPrimary,
      textMuted: darkTextMuted,
    );
  }

  static ThemeData _build({
    required Brightness brightness,
    required Color body,
    required Color surface,
    required Color border,
    required Color textPrimary,
    required Color textMuted,
  }) {
    final isLight = brightness == Brightness.light;
    final baseText = GoogleFonts.poppinsTextTheme(
      isLight ? ThemeData.light().textTheme : ThemeData.dark().textTheme,
    ).apply(bodyColor: textPrimary, displayColor: textPrimary);

    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(primary: accent, secondary: accent, surface: surface);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: body,
      dividerColor: border,
      textTheme: baseText,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.poppins(color: textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          side: BorderSide(color: border),
          textStyle: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: body,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: GoogleFonts.poppins(color: textMuted, fontSize: 13),
      ),
      iconTheme: IconThemeData(color: textMuted),
      extensions: [
        WeeberColors(
          body: body,
          surface: surface,
          border: border,
          textPrimary: textPrimary,
          textMuted: textMuted,
          sidebarBg: isLight ? lightSidebar : darkSidebar,
          sidebarActiveBg: isLight ? lightSidebarActiveBg : darkSidebarActiveBg,
        ),
      ],
    );
  }
}

class WeeberColors extends ThemeExtension<WeeberColors> {
  const WeeberColors({
    required this.body,
    required this.surface,
    required this.border,
    required this.textPrimary,
    required this.textMuted,
    required this.sidebarBg,
    required this.sidebarActiveBg,
  });

  final Color body;
  final Color surface;
  final Color border;
  final Color textPrimary;
  final Color textMuted;
  final Color sidebarBg;
  final Color sidebarActiveBg;

  @override
  WeeberColors copyWith({Color? body, Color? surface, Color? border, Color? textPrimary, Color? textMuted, Color? sidebarBg, Color? sidebarActiveBg}) {
    return WeeberColors(
      body: body ?? this.body,
      surface: surface ?? this.surface,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textMuted: textMuted ?? this.textMuted,
      sidebarBg: sidebarBg ?? this.sidebarBg,
      sidebarActiveBg: sidebarActiveBg ?? this.sidebarActiveBg,
    );
  }

  @override
  WeeberColors lerp(WeeberColors? other, double t) {
    if (other == null) return this;
    return WeeberColors(
      body: Color.lerp(body, other.body, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      sidebarBg: Color.lerp(sidebarBg, other.sidebarBg, t)!,
      sidebarActiveBg: Color.lerp(sidebarActiveBg, other.sidebarActiveBg, t)!,
    );
  }
}

extension WeeberTheme on BuildContext {
  WeeberColors get weeberColors => Theme.of(this).extension<WeeberColors>()!;
}
