import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// CloudBox-style folder tile: letter badge with pastel background on the
/// left, folder name + date + file count on the right.
class FolderTile extends StatelessWidget {
  const FolderTile({
    super.key,
    required this.name,
    required this.createdAt,
    required this.fileCount,
    required this.paletteIndex,
    this.onTap,
  });

  final String name;
  final DateTime createdAt;
  final int fileCount;
  final int paletteIndex;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    final (bg, fg) = AppTheme.folderPalette[paletteIndex % AppTheme.folderPalette.length];
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
                alignment: Alignment.center,
                child: Text(
                  letter,
                  style: GoogleFonts.poppins(color: fg, fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              const Spacer(),
              Icon(Icons.more_vert, size: 18, color: c.textMuted),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(color: c.textPrimary, fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Row(children: [
            Icon(Icons.calendar_today_outlined, size: 11, color: c.textMuted),
            const SizedBox(width: 4),
            Text(
              _fmt(createdAt),
              style: GoogleFonts.poppins(color: c.textMuted, fontSize: 11),
            ),
          ]),
          const SizedBox(height: 3),
          Row(children: [
            Icon(Icons.folder_open_outlined, size: 11, color: c.textMuted),
            const SizedBox(width: 4),
            Text(
              '$fileCount File${fileCount == 1 ? '' : 's'}',
              style: GoogleFonts.poppins(color: c.textMuted, fontSize: 11),
            ),
          ]),
        ],
      ),
    );
  }

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  String _fmt(DateTime d) => '${d.day.toString().padLeft(2,'0')} ${_months[d.month-1]}, ${d.year}';
}
