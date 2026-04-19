import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// CloudBox-style semicircular gauge with Downloads/Uploads tallies beneath.
/// Uses CustomPaint — no external dependency.
class StatsGauge extends StatelessWidget {
  const StatsGauge({super.key, required this.downloads, required this.uploads});
  final int downloads;
  final int uploads;

  double get _ratio {
    final total = downloads + uploads;
    if (total == 0) return 0.5;
    return downloads / total;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 2.0,
          child: CustomPaint(painter: _GaugePainter(ratio: _ratio, trackColor: c.border)),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _Tally(label: 'Downloads', value: downloads, color: AppTheme.accent),
            _Tally(label: 'Uploads', value: uploads, color: const Color(0xFFFBBF24)),
          ],
        ),
      ],
    );
  }
}

class _Tally extends StatelessWidget {
  const _Tally({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: GoogleFonts.poppins(color: c.textMuted, fontSize: 11)),
          Text(_formatNumber(value), style: GoogleFonts.poppins(color: c.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
        ]),
      ],
    );
  }

  static String _formatNumber(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K';
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.ratio, required this.trackColor});
  final double ratio;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(10, 10, size.width - 20, size.width - 20);
    final strokeWidth = 16.0;
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth;
    final active = Paint()
      ..shader = const LinearGradient(colors: [AppTheme.accent, Color(0xFFC4B5FD)])
          .createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth;

    // track — semicircle top
    canvas.drawArc(rect, pi, pi, false, track);
    // active arc
    canvas.drawArc(rect, pi, pi * ratio, false, active);

    // needle
    final center = Offset(rect.center.dx, rect.center.dy + 4);
    final needleAngle = pi + pi * ratio;
    final needleLen = rect.width / 2 - strokeWidth;
    final tip = Offset(center.dx + cos(needleAngle) * needleLen, center.dy + sin(needleAngle) * needleLen);
    final needle = Paint()
      ..color = const Color(0xFF1C2033)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, tip, needle);
    canvas.drawCircle(center, 5, needle);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.ratio != ratio;
}
