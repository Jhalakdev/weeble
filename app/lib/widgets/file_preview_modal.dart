import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:video_player/video_player.dart';
import '../services/relay_client.dart';
import '../theme/app_theme.dart';
import 'byte_size.dart';
import 'file_preview.dart';

/// Native file preview on iOS / Android / macOS. Downloads the file via
/// the relay client (showing progress), then renders the appropriate
/// viewer:
///   image/*        → Image.memory
///   application/pdf → pdfx PdfViewPinch
///   video/*        → video_player
///   audio/*        → just_audio with a minimal transport UI
///   text/* + .csv  → parsed + rendered (CSV as table)
///   other          → "No preview" placeholder with Download button
///
/// Caller passes an onDownload callback so the modal can offer a
/// save-to-disk / share-sheet path once bytes are in hand.
Future<void> showFilePreview({
  required BuildContext context,
  required WidgetRef ref,
  required RelayFile file,
  required Future<void> Function() onDownload,
}) {
  return showDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (ctx) => _FilePreviewModal(file: file, onDownload: onDownload, ref: ref),
  );
}

class _FilePreviewModal extends StatefulWidget {
  const _FilePreviewModal({required this.file, required this.onDownload, required this.ref});
  final RelayFile file;
  final Future<void> Function() onDownload;
  final WidgetRef ref;
  @override
  State<_FilePreviewModal> createState() => _FilePreviewModalState();
}

class _FilePreviewModalState extends State<_FilePreviewModal> {
  double _progress = 0;
  Uint8List? _bytes;
  File? _tempFile;           // video/audio need a file URL, not bytes
  String? _error;
  PdfControllerPinch? _pdfCtrl;
  VideoPlayerController? _videoCtrl;
  ja.AudioPlayer? _audioCtrl;

  String get _ext => p.extension(widget.file.name).toLowerCase().replaceAll('.', '');
  bool get _isImage => widget.file.mime.startsWith('image/');
  bool get _isPdf => widget.file.mime == 'application/pdf';
  bool get _isVideo => widget.file.mime.startsWith('video/');
  bool get _isAudio => widget.file.mime.startsWith('audio/');
  bool get _isCsv => _ext == 'csv' || widget.file.mime == 'text/csv';
  bool get _isText => !_isCsv && (widget.file.mime.startsWith('text/') || ['md','json','yaml','yml','log','txt'].contains(_ext));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.ref.read(relayClientProvider).downloadFile(
        id: widget.file.id,
        onProgress: (r, t) {
          if (!mounted || t == 0) return;
          setState(() => _progress = r / t);
        },
      );
      if (!mounted) return;
      setState(() { _bytes = bytes; _progress = 1; });
      // Set up the appropriate viewer.
      if (_isPdf) {
        _pdfCtrl = PdfControllerPinch(document: PdfDocument.openData(bytes));
        if (mounted) setState(() {});
      } else if (_isVideo) {
        final tmp = await _writeTemp(bytes, _ext.isEmpty ? 'mp4' : _ext);
        _videoCtrl = VideoPlayerController.file(tmp);
        await _videoCtrl!.initialize();
        await _videoCtrl!.setLooping(false);
        if (mounted) { setState(() { _tempFile = tmp; }); _videoCtrl!.play(); }
      } else if (_isAudio) {
        final tmp = await _writeTemp(bytes, _ext.isEmpty ? 'mp3' : _ext);
        _audioCtrl = ja.AudioPlayer();
        await _audioCtrl!.setFilePath(tmp.path);
        if (mounted) { setState(() { _tempFile = tmp; }); _audioCtrl!.play(); }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<File> _writeTemp(Uint8List bytes, String ext) async {
    final dir = await getTemporaryDirectory();
    final f = File(p.join(dir.path, 'weeber-preview-${DateTime.now().microsecondsSinceEpoch}.$ext'));
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  @override
  void dispose() {
    _pdfCtrl?.dispose();
    _videoCtrl?.dispose();
    _audioCtrl?.dispose();
    // Best-effort cleanup of the temp file; OS will GC anyway.
    _tempFile?.delete().catchError((_) => _tempFile!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Dialog.fullscreen(
      backgroundColor: c.surface,
      child: Column(
        children: [
          // --- Header ---
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
            child: Row(children: [
              FilePreview(mime: widget.file.mime, name: widget.file.name, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.file.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text('${formatBytes(widget.file.size)} · ${_fmtDate(widget.file.createdAt)}',
                      style: GoogleFonts.poppins(fontSize: 11, color: c.textMuted)),
                ]),
              ),
              IconButton(
                icon: const Icon(Icons.download_rounded),
                tooltip: 'Download',
                onPressed: () async { await widget.onDownload(); },
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ),

          // --- Body ---
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not load preview: $_error',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 12, color: Colors.red.shade600)),
        ),
      );
    }
    if (_bytes == null) return _loading();

    if (_isImage) {
      return InteractiveViewer(
        child: Center(child: Image.memory(_bytes!, fit: BoxFit.contain)),
      );
    }
    if (_isPdf && _pdfCtrl != null) {
      return PdfViewPinch(controller: _pdfCtrl!);
    }
    if (_isVideo && _videoCtrl != null && _videoCtrl!.value.isInitialized) {
      return Center(
        child: AspectRatio(
          aspectRatio: _videoCtrl!.value.aspectRatio,
          child: Stack(alignment: Alignment.center, children: [
            VideoPlayer(_videoCtrl!),
            VideoProgressIndicator(_videoCtrl!, allowScrubbing: true),
            _VideoOverlay(ctrl: _videoCtrl!),
          ]),
        ),
      );
    }
    if (_isAudio && _audioCtrl != null) {
      return _AudioPlayer(ctrl: _audioCtrl!, name: widget.file.name);
    }
    if (_isCsv) {
      return _CsvTable(raw: utf8.decode(_bytes!, allowMalformed: true));
    }
    if (_isText) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: SelectableText(
            utf8.decode(_bytes!, allowMalformed: true),
            style: GoogleFonts.robotoMono(fontSize: 12),
          ),
        ),
      );
    }
    // Fallback — type isn't previewable.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.insert_drive_file_outlined, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 14),
          Text('No preview available',
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text("This file type can't be previewed. Tap Download to open it externally.",
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => widget.onDownload(),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download'),
          ),
        ]),
      ),
    );
  }

  Widget _loading() {
    final c = context.weeberColors;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 56, height: 56,
          child: CircularProgressIndicator(
            value: _progress > 0 && _progress < 1 ? _progress : null,
            strokeWidth: 3,
            valueColor: const AlwaysStoppedAnimation(AppTheme.accent),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          _progress > 0 && _progress < 1 ? 'Loading preview… ${(_progress * 100).toStringAsFixed(0)}%' : 'Loading preview…',
          style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted),
        ),
      ]),
    );
  }

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  static String _fmtDate(int unix) {
    if (unix == 0) return 'just now';
    final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    return '${_months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

// Simple CSV parser — quoted fields, embedded commas/quotes. Capped at
// 1000 rows to keep the phone from OOMing on a huge sheet.
class _CsvTable extends StatelessWidget {
  const _CsvTable({required this.raw});
  final String raw;
  @override
  Widget build(BuildContext context) {
    final rows = _parse(raw).take(1000).toList();
    if (rows.isEmpty) {
      return const Center(child: Text('Empty CSV'));
    }
    final header = rows.first;
    final body = rows.skip(1).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          columnSpacing: 14,
          horizontalMargin: 8,
          headingRowColor: WidgetStateProperty.all(context.weeberColors.body),
          columns: [for (final h in header) DataColumn(label: Text(h, style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600)))],
          rows: [
            for (final r in body)
              DataRow(cells: [
                for (var i = 0; i < header.length; i++)
                  DataCell(Text(i < r.length ? r[i] : '',
                      style: GoogleFonts.robotoMono(fontSize: 11))),
              ]),
          ],
        ),
      ),
    );
  }

  static List<List<String>> _parse(String raw) {
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < raw.length && raw[i + 1] == '"') { field.write('"'); i++; } else { inQuotes = false; }
        } else { field.write(ch); }
      } else if (ch == '"') { inQuotes = true; }
      else if (ch == ',') { row.add(field.toString()); field = StringBuffer(); }
      else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < raw.length && raw[i + 1] == '\n') i++;
        row.add(field.toString()); field = StringBuffer();
        rows.add(row); row = <String>[];
      } else { field.write(ch); }
    }
    if (field.isNotEmpty || row.isNotEmpty) { row.add(field.toString()); rows.add(row); }
    return rows.where((r) => r.length > 1 || (r.length == 1 && r[0].isNotEmpty)).toList();
  }
}

class _VideoOverlay extends StatefulWidget {
  const _VideoOverlay({required this.ctrl});
  final VideoPlayerController ctrl;
  @override
  State<_VideoOverlay> createState() => _VideoOverlayState();
}

class _VideoOverlayState extends State<_VideoOverlay> {
  @override
  void initState() { super.initState(); widget.ctrl.addListener(_tick); }
  @override
  void dispose() { widget.ctrl.removeListener(_tick); super.dispose(); }
  void _tick() { if (mounted) setState(() {}); }
  @override
  Widget build(BuildContext context) {
    final playing = widget.ctrl.value.isPlaying;
    return GestureDetector(
      onTap: () => playing ? widget.ctrl.pause() : widget.ctrl.play(),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: playing ? 0 : 1,
        child: Container(
          color: Colors.black26,
          alignment: Alignment.center,
          child: const Icon(Icons.play_arrow_rounded, size: 72, color: Colors.white),
        ),
      ),
    );
  }
}

class _AudioPlayer extends StatefulWidget {
  const _AudioPlayer({required this.ctrl, required this.name});
  final ja.AudioPlayer ctrl;
  final String name;
  @override
  State<_AudioPlayer> createState() => _AudioPlayerState();
}

class _AudioPlayerState extends State<_AudioPlayer> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.ctrl.positionStream,
      builder: (_, posSnap) {
        return StreamBuilder<Duration?>(
          stream: widget.ctrl.durationStream,
          builder: (_, durSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final dur = durSnap.data ?? Duration.zero;
            final max = dur.inMilliseconds.toDouble();
            final v = pos.inMilliseconds.toDouble().clamp(0.0, max == 0 ? 1.0 : max);
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 140, height: 140,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFFBCFE8), Color(0xFFEC4899)]),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: const Icon(Icons.music_note_rounded, size: 72, color: Colors.white),
                ),
                const SizedBox(height: 24),
                Text(widget.name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 24),
                Slider(
                  min: 0, max: max == 0 ? 1 : max, value: v,
                  onChanged: (nv) => widget.ctrl.seek(Duration(milliseconds: nv.toInt())),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(_fmt(pos), style: GoogleFonts.robotoMono(fontSize: 11)),
                  Text(_fmt(dur), style: GoogleFonts.robotoMono(fontSize: 11)),
                ]),
                const SizedBox(height: 12),
                StreamBuilder<ja.PlayerState>(
                  stream: widget.ctrl.playerStateStream,
                  builder: (_, snap) {
                    final playing = snap.data?.playing ?? false;
                    return IconButton.filled(
                      iconSize: 40,
                      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      onPressed: () => playing ? widget.ctrl.pause() : widget.ctrl.play(),
                    );
                  },
                ),
              ]),
            );
          },
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
