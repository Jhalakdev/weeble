import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// Compact "Quick Access" folder tile — pastel icon + name.
class QuickAccessTile extends StatelessWidget {
  const QuickAccessTile({super.key, required this.name, required this.paletteIndex, this.onTap});
  final String name;
  final int paletteIndex;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    final (bg, fg) = AppTheme.folderPalette[paletteIndex % AppTheme.folderPalette.length];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64, height: 64,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
            alignment: Alignment.center,
            child: Icon(Icons.folder_rounded, color: fg, size: 30),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            style: GoogleFonts.poppins(fontSize: 11, color: c.textMuted, fontWeight: FontWeight.w500),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
