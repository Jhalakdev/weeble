import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// "Welcome Penny" card — greeting + notification tease + small illustration.
class WelcomeHero extends StatelessWidget {
  const WelcomeHero({super.key, required this.name, this.notifications = 0, this.messages = 0, this.onAction});
  final String name;
  final int notifications;
  final int messages;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome, $name',
                  style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: c.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'You have $notifications new notifications\nand $messages unread messages to reply',
                  style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted, height: 1.5),
                ),
                const SizedBox(height: 14),
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accent,
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Try Now', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w500)),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_forward, size: 14),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 130, height: 100, child: CustomPaint(painter: _BoxesPainter(c.textMuted))),
        ],
      ),
    );
  }
}

/// Simple abstract illustration — stacked boxes with a plant, to evoke the
/// "shelves of stored items" vibe from the CloudBox reference without needing
/// the original SVG.
class _BoxesPainter extends CustomPainter {
  _BoxesPainter(this.accent);
  final Color accent;
  @override
  void paint(Canvas canvas, Size size) {
    final pink = Paint()..color = const Color(0xFFFBBFC3);
    final purple = Paint()..color = const Color(0xFFC7CAFB);
    final amber = Paint()..color = const Color(0xFFFBD38D);
    final green = Paint()..color = const Color(0xFF9AE6B4);
    final r = 6.0;

    Rect b1 = Rect.fromLTWH(10, 60, 36, 28);
    Rect b2 = Rect.fromLTWH(48, 50, 32, 38);
    Rect b3 = Rect.fromLTWH(82, 40, 38, 48);
    Rect b4 = Rect.fromLTWH(52, 18, 26, 30);
    canvas.drawRRect(RRect.fromRectAndRadius(b1, Radius.circular(r)), pink);
    canvas.drawRRect(RRect.fromRectAndRadius(b2, Radius.circular(r)), purple);
    canvas.drawRRect(RRect.fromRectAndRadius(b3, Radius.circular(r)), amber);
    canvas.drawRRect(RRect.fromRectAndRadius(b4, Radius.circular(r)), green);
  }

  @override
  bool shouldRepaint(_BoxesPainter old) => false;
}
