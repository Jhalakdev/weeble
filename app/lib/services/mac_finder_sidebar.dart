import 'dart:io';

/// Adds the Weeber storage folder to the macOS Finder sidebar
/// (Favorites section) so users can drag files into "Weeber" right
/// from any Finder window — same UX as Google Drive / Dropbox.
///
/// Strategy: shell out to `osascript -l JavaScript` (JXA, built into
/// every Mac since 10.10) and call the still-functional
/// `LSSharedFileListInsertItemURL` Cocoa API. This API is officially
/// deprecated but every cloud-storage app in the wild still uses it
/// (Dropbox, Sync, Maestral) because Apple never shipped a public
/// replacement. Marked deprecated since 10.11; still works in 14.x.
///
/// Idempotent: the API itself ignores duplicates of the same URL.
/// Fail-soft: any error just leaves the user without the sidebar
/// shortcut — they can drag the folder there manually.
class MacFinderSidebar {
  static Future<void> ensure(String storagePath) async {
    if (!Platform.isMacOS) return;
    final escaped = storagePath.replaceAll("'", r"\'");
    final script = '''
      ObjC.import('Foundation');
      ObjC.import('CoreServices');
      try {
        const sfl = \$.LSSharedFileListCreate(\$(), \$.kLSSharedFileListFavoriteItems, \$());
        if (sfl) {
          const url = \$.NSURL.fileURLWithPath('$escaped');
          \$.LSSharedFileListInsertItemURL(sfl, \$.kLSSharedFileListItemLast, \$(), \$(), url, \$(), \$());
          'ok';
        } else {
          'no_sfl';
        }
      } catch (e) {
        'err: ' + e;
      }
    ''';
    try {
      final r = await Process.run('osascript', ['-l', 'JavaScript', '-e', script])
          .timeout(const Duration(seconds: 5));
      // ignore: avoid_print
      print('[mac-sidebar] result: ${(r.stdout as String).trim()}');
    } catch (_) {
      // Silently swallow — user just doesn't get the sidebar shortcut.
    }
  }
}
