import 'dart:io';
import 'package:path/path.dart' as p;

/// Adds a "Weeber" bookmark to the user's Linux file manager so they
/// can drag-drop straight into the storage folder, just like Google
/// Drive / Dropbox appear in the Finder sidebar on macOS.
///
/// Writes to:
///   ~/.config/gtk-3.0/bookmarks   (Nautilus / Files / most GTK FMs)
///   ~/.config/gtk-4.0/bookmarks   (newer GTK)
///   ~/.local/share/user-places.xbel  (KDE Dolphin)
///
/// Idempotent: if Weeber is already bookmarked, leaves the file alone.
/// No-op on non-Linux platforms.
class LinuxBookmark {
  static Future<void> ensure(String storagePath) async {
    if (!Platform.isLinux) return;
    final home = Platform.environment['HOME'];
    if (home == null) return;

    final fileUri = 'file://$storagePath';
    await _gtkBookmarks(p.join(home, '.config', 'gtk-3.0', 'bookmarks'), fileUri);
    await _gtkBookmarks(p.join(home, '.config', 'gtk-4.0', 'bookmarks'), fileUri);
    await _kdePlaces(p.join(home, '.local', 'share', 'user-places.xbel'), storagePath);
  }

  /// GTK bookmarks file — one entry per line, "URI Name". Idempotent
  /// on the URI part (re-runs don't duplicate).
  static Future<void> _gtkBookmarks(String path, String fileUri) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final existing = await file.exists() ? await file.readAsString() : '';
      // Already bookmarked? Skip.
      if (existing.split('\n').any((line) => line.startsWith('$fileUri ') || line.trim() == fileUri)) {
        return;
      }
      final newLine = '$fileUri Weeber\n';
      final next = existing.endsWith('\n') || existing.isEmpty ? '$existing$newLine' : '$existing\n$newLine';
      await file.writeAsString(next);
    } catch (_) {
      // File-manager bookmarks aren't critical; failures here are
      // silent. The user just doesn't get the sidebar shortcut.
    }
  }

  /// KDE places file — XBEL XML format. We append a single bookmark
  /// node if Weeber isn't already there.
  static Future<void> _kdePlaces(String path, String storagePath) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final existing = await file.exists() ? await file.readAsString() : '';
      if (existing.contains('href="file://$storagePath"')) return;

      // Build an entry. KDE treats the <bookmark> + nested metadata
      // as a single sidebar item.
      final entry = '''
 <bookmark href="file://$storagePath">
  <title>Weeber</title>
  <info>
   <metadata owner="http://freedesktop.org">
    <bookmark:icon name="folder-cloud"/>
   </metadata>
   <metadata owner="http://www.kde.org">
    <ID>weeber-${DateTime.now().millisecondsSinceEpoch}</ID>
    <isSystemItem>false</isSystemItem>
   </metadata>
  </info>
 </bookmark>
''';

      String next;
      if (existing.isEmpty) {
        // Bootstrap a fresh XBEL doc with our entry.
        next = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE xbel>
<xbel xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks"
      xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info"
      xmlns:kdepriv="http://www.kde.org/kdepriv">
$entry</xbel>
''';
      } else if (existing.contains('</xbel>')) {
        // Insert before the closing tag.
        next = existing.replaceFirst('</xbel>', '$entry</xbel>');
      } else {
        // File exists but malformed — leave it alone.
        return;
      }
      await file.writeAsString(next);
    } catch (_) {
      // Same fail-soft policy as GTK.
    }
  }
}
