import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';
import '../services/file_index.dart';
import '../state/auth.dart';

/// WhatsApp/Drive-style "Share this file" dialog. Generates a public URL the
/// user can paste anywhere. Download-count, expiry, revocation are all
/// supported by the backend but kept hidden from the v1 UI — one-button UX.
class ShareDialog extends ConsumerStatefulWidget {
  const ShareDialog({super.key, required this.file});
  final FileEntry file;

  static Future<void> show(BuildContext context, FileEntry file) {
    return showDialog(context: context, builder: (_) => ShareDialog(file: file));
  }

  @override
  ConsumerState<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends ConsumerState<ShareDialog> {
  String? _url;
  String? _error;
  bool _busy = true;
  int _expiryDays = 7;

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    setState(() { _busy = true; _error = null; });
    final token = ref.read(authProvider).token;
    if (token == null) {
      setState(() { _busy = false; _error = 'Not signed in.'; });
      return;
    }
    try {
      final res = await ref.read(apiProvider).createShare(
            token: token,
            fileId: widget.file.id,
            fileName: widget.file.name,
            mime: widget.file.mime,
            sizeBytes: widget.file.size,
            expiresInSeconds: _expiryDays * 24 * 3600,
          );
      if (!mounted) return;
      setState(() {
        _url = res['url'] as String;
        _busy = false;
      });
    } on ApiException catch (e) {
      setState(() { _busy = false; _error = e.code; });
    } catch (e) {
      setState(() { _busy = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.indigo.shade50, borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.link, color: Colors.indigo.shade600, size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('Share a link')),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.file.name, style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text('Anyone with the link can download this file.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 20),
            if (_busy)
              const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.shade200)),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
              )
            else
              _LinkRow(url: _url!),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('Expires in: ', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                DropdownButton<int>(
                  value: _expiryDays,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 day')),
                    DropdownMenuItem(value: 7, child: Text('7 days')),
                    DropdownMenuItem(value: 30, child: Text('30 days')),
                  ],
                  onChanged: _busy ? null : (v) {
                    if (v == null) return;
                    setState(() { _expiryDays = v; });
                    _create();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

class _LinkRow extends StatefulWidget {
  const _LinkRow({required this.url});
  final String url;
  @override
  State<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends State<_LinkRow> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          Expanded(
            child: Text(widget.url, style: const TextStyle(fontFamily: 'monospace', fontSize: 13), overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
            label: Text(_copied ? 'Copied' : 'Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.url));
              setState(() { _copied = true; });
              await Future.delayed(const Duration(seconds: 2));
              if (mounted) setState(() { _copied = false; });
            },
          ),
        ],
      ),
    );
  }
}
