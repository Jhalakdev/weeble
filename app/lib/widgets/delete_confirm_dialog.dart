import 'package:flutter/material.dart';

enum DeleteScope { thisDeviceOnly, everyone, cancelled }

/// WhatsApp-style delete dialog.
/// - "Delete for me"  → only removes the local cached copy on the calling device
/// - "Delete for everyone" → removes from the host (source of truth) and all paired clients
class DeleteConfirmDialog extends StatelessWidget {
  const DeleteConfirmDialog({
    super.key,
    required this.fileName,
    this.canDeleteForEveryone = true,
  });

  final String fileName;
  final bool canDeleteForEveryone;

  static Future<DeleteScope> show(BuildContext context, {required String fileName, bool canDeleteForEveryone = true}) async {
    final result = await showDialog<DeleteScope>(
      context: context,
      builder: (_) => DeleteConfirmDialog(fileName: fileName, canDeleteForEveryone: canDeleteForEveryone),
    );
    return result ?? DeleteScope.cancelled;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete this file?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fileName, style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          Text(
            canDeleteForEveryone
                ? 'Choose how to delete it.'
                : 'This will only remove the local copy on this device.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(DeleteScope.cancelled),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(DeleteScope.thisDeviceOnly),
          child: const Text('Delete for me'),
        ),
        if (canDeleteForEveryone)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(context).pop(DeleteScope.everyone),
            child: const Text('Delete for everyone'),
          ),
      ],
    );
  }
}
