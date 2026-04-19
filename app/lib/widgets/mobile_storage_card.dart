import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import 'byte_size.dart';

/// Compact storage card for the mobile/client drive screen. Mirrors the
/// website StorageCard so users see the same info regardless of surface.
class MobileStorageCard extends StatelessWidget {
  const MobileStorageCard({
    super.key,
    required this.usedBytes,
    required this.allocatedBytes,
    required this.fileCount,
  });

  final int usedBytes;
  final int allocatedBytes;
  final int fileCount;

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    final hasCap = allocatedBytes > 0;
    final pct = hasCap ? (usedBytes / allocatedBytes).clamp(0.0, 1.0) : 0.0;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: c.surface, borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.storage_rounded, size: 16, color: AppTheme.accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Storage', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600, color: c.textPrimary)),
                  Text(
                    hasCap
                        ? '${formatBytes(usedBytes)} of ${formatBytes(allocatedBytes)} used · $fileCount file${fileCount == 1 ? '' : 's'}'
                        : '${formatBytes(usedBytes)} used · $fileCount file${fileCount == 1 ? '' : 's'}',
                    style: GoogleFonts.poppins(fontSize: 10, color: c.textMuted),
                  ),
                ],
              ),
            ),
            if (hasCap)
              Text('${(pct * 100).toStringAsFixed(0)}%', style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.accent)),
          ]),
          if (hasCap) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 5,
                backgroundColor: c.surface,
                valueColor: const AlwaysStoppedAnimation(AppTheme.accent),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Storage lives on your computer. To make room for more files, use the Weeber app on your computer to increase storage.',
            style: GoogleFonts.poppins(fontSize: 10, color: c.textMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}
