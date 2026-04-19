import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// The Weeber wordmark — lavender gradient mark + "weeber" text. Matches the
/// CloudBox-style sidebar logo.
class WeeberLogo extends StatelessWidget {
  const WeeberLogo({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size * 1.4,
          height: size * 1.4,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.accentGradient1, AppTheme.accentGradient2],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(size * 0.35),
          ),
          child: Icon(Icons.cloud, color: Colors.white, size: size),
        ),
        SizedBox(width: size * 0.45),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'Wee',
                style: GoogleFonts.poppins(
                  fontSize: size * 1.05,
                  fontWeight: FontWeight.w300,
                  color: context.weeberColors.textPrimary,
                ),
              ),
              TextSpan(
                text: 'BER',
                style: GoogleFonts.poppins(
                  fontSize: size * 1.05,
                  fontWeight: FontWeight.w700,
                  color: context.weeberColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
