import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Per-mime preview tile. One visual style per file family so the file list
/// reads at a glance without thumbnails. Matches the website's preview
/// component (lib/dashboard/files-panel.tsx) so the apps look consistent.
class FilePreview extends StatelessWidget {
  const FilePreview({super.key, required this.mime, required this.name, this.size = 40});
  final String mime;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ext = _ext(name);
    final kind = _kind(mime, ext);
    final s = _styles[kind] ?? _styles['other']!;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: s.gradient,
              color: s.gradient == null ? s.bg : null,
              borderRadius: BorderRadius.circular(size * 0.22),
            ),
            alignment: Alignment.center,
            child: Icon(s.icon, size: size * 0.4, color: s.fg),
          ),
          if (s.label != null)
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: Container(
                color: s.fg,
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Text(
                  s.label!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: size * 0.18,
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

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0) return '';
    return name.substring(i + 1).toLowerCase();
  }

  static String _kind(String mime, String ext) {
    if (mime.startsWith('image/')) return 'image';
    if (mime == 'application/pdf') return 'pdf';
    if (mime.startsWith('audio/')) return 'audio';
    if (mime.startsWith('video/')) return 'video';
    if (mime.startsWith('text/')) return 'text';
    if (['xls', 'xlsx', 'csv', 'ods', 'numbers'].contains(ext)) return 'spreadsheet';
    if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2'].contains(ext)) return 'archive';
    if (['js','ts','tsx','jsx','py','go','rs','java','c','cpp','h','sh','json','yaml','yml','html','css','sql','rb','php','dart'].contains(ext)) return 'code';
    if (['doc', 'docx', 'rtf', 'odt'].contains(ext)) return 'doc';
    if (['ppt', 'pptx', 'odp', 'key'].contains(ext)) return 'slides';
    return 'other';
  }

  static final Map<String, _Style> _styles = {
    'image': _Style(
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFC4B5FD), Color(0xFF8B5CF6)]),
      fg: Colors.white,
      icon: Icons.image_outlined,
    ),
    'pdf': _Style(bg: const Color(0xFFFEE2E2), fg: const Color(0xFFDC2626), icon: Icons.picture_as_pdf_outlined, label: 'PDF'),
    'audio': _Style(
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFBCFE8), Color(0xFFEC4899)]),
      fg: Colors.white,
      icon: Icons.music_note_rounded,
    ),
    'video': _Style(
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1F2937), Color(0xFF4B5563)]),
      fg: Colors.white,
      icon: Icons.play_arrow_rounded,
    ),
    'spreadsheet': _Style(bg: const Color(0xFFD1FAE5), fg: const Color(0xFF059669), icon: Icons.table_chart_outlined, label: 'XLS'),
    'archive': _Style(bg: const Color(0xFFFEF3C7), fg: const Color(0xFFD97706), icon: Icons.folder_zip_outlined, label: 'ZIP'),
    'code': _Style(bg: const Color(0xFFDBEAFE), fg: const Color(0xFF2563EB), icon: Icons.code_rounded, label: 'CODE'),
    'doc': _Style(bg: const Color(0xFFDBEAFE), fg: const Color(0xFF2563EB), icon: Icons.description_outlined, label: 'DOC'),
    'slides': _Style(bg: const Color(0xFFFFE4D5), fg: const Color(0xFFEA580C), icon: Icons.slideshow_outlined, label: 'PPT'),
    'text': _Style(bg: const Color(0xFFDBEAFE), fg: const Color(0xFF2563EB), icon: Icons.text_snippet_outlined),
    'other': _Style(bg: const Color(0xFFE5E7EB), fg: const Color(0xFF6B7280), icon: Icons.insert_drive_file_outlined),
  };
}

class _Style {
  _Style({this.gradient, this.bg, required this.fg, required this.icon, this.label});
  final Gradient? gradient;
  final Color? bg;
  final Color fg;
  final IconData icon;
  final String? label;
}
