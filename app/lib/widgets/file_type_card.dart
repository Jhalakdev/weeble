import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// A file-as-paper card like the CloudBox "Documents" strip. Rounded paper
/// shape with a coloured label band at the bottom showing the type abbrev.
/// Used for PDF / DOC / XLS / PPT thumbnails.
class FileTypeCard extends StatelessWidget {
  const FileTypeCard({super.key, required this.kind, required this.fileName, this.onTap});

  final String kind; // 'PDF', 'DOC', 'XLS', 'PPT', 'IMG', 'VID', etc.
  final String fileName;
  final VoidCallback? onTap;

  static final Map<String, Color> _kindColors = {
    'PDF': AppTheme.fileRed,
    'DOC': AppTheme.fileBlue,
    'DOCX': AppTheme.fileBlue,
    'XLS': AppTheme.fileGreen,
    'XLSX': AppTheme.fileGreen,
    'PPT': AppTheme.fileOrange,
    'PPTX': AppTheme.fileOrange,
    'IMG': AppTheme.filePurple,
    'PNG': AppTheme.filePurple,
    'JPG': AppTheme.filePurple,
    'MP4': AppTheme.fileRed,
    'TXT': AppTheme.fileBlue,
  };

  static Color _colorFor(String kind) => _kindColors[kind.toUpperCase()] ?? AppTheme.accent;
  static String kindFromName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'FILE';
    return name.substring(dot + 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(kind);
    final c = context.weeberColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.border),
              ),
              child: Center(
                child: _Paper(kind: kind.toUpperCase(), color: color),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(color: c.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Paper extends StatelessWidget {
  const _Paper({required this.kind, required this.color});
  final String kind;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 68,
      child: Stack(
        children: [
          // paper body
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFFDFDFD),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFFD8DAE5), width: 0.6),
                boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 4, offset: Offset(0, 2))],
              ),
            ),
          ),
          // corner fold
          Positioned(
            top: 0, right: 0,
            child: CustomPaint(size: const Size(14, 14), painter: _CornerFold()),
          ),
          // lines
          Positioned(
            left: 8, right: 8, top: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(3, (i) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Container(
                  height: 2,
                  width: i == 2 ? 24 : 40,
                  color: const Color(0xFFD8DAE5),
                ),
              )),
            ),
          ),
          // colored label
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              height: 22,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(4), bottomRight: Radius.circular(4)),
              ),
              alignment: Alignment.center,
              child: Text(
                kind,
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CornerFold extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..close();
    final paint = Paint()..color = const Color(0xFFEAECF3);
    canvas.drawPath(path, paint);
    final fold = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    final foldPaint = Paint()..color = const Color(0xFFCCD0DB);
    canvas.drawPath(fold, foldPaint);
  }

  @override
  bool shouldRepaint(_CornerFold oldDelegate) => false;
}
