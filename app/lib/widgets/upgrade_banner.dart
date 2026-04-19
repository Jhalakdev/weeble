import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// Purple-gradient "Unlock Your plan" banner (bottom-left of CloudBox dashboard).
class UpgradeBanner extends StatelessWidget {
  const UpgradeBanner({super.key, this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [Color(0xFF8F93F6), Color(0xFFB1A7F9)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Unlock Your plan',
                  style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Expanded storage, access to\nmore features on Weeber',
                  style: GoogleFonts.poppins(color: Colors.white.withValues(alpha: 0.9), fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: onTap,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppTheme.accentDark,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    textStyle: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  child: const Text('Go Premium'),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const _LockIllustration(),
        ],
      ),
    );
  }
}

class _LockIllustration extends StatelessWidget {
  const _LockIllustration();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80, height: 80,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.lock_rounded, color: Colors.white, size: 38),
    );
  }
}
