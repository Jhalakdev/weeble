import 'dart:io';

/// Pins the Weeber storage folder to Windows Explorer's Quick Access
/// so it appears in the left-hand sidebar of every Explorer window —
/// users can drag files there to upload, just like OneDrive / Dropbox.
///
/// Strategy: shell out to PowerShell and call the Shell.Application
/// COM verb "pintohome", which is the documented way to "Pin to
/// Quick access" on Windows 10/11.
///
/// Idempotent: invoking the verb on a folder that's already pinned
/// is a no-op. Fail-soft: any error leaves the user without the
/// shortcut — they can drag the folder there manually.
class WindowsQuickAccess {
  static Future<void> ensure(String storagePath) async {
    if (!Platform.isWindows) return;
    // Escape any single quotes for embedding in the PS1 string literal.
    final escaped = storagePath.replaceAll("'", "''");
    final script = '''
      \$ErrorActionPreference = 'SilentlyContinue'
      \$o = New-Object -ComObject shell.application
      \$ns = \$o.Namespace('$escaped')
      if (\$ns -ne \$null) { \$ns.Self.InvokeVerb('pintohome') }
    ''';
    try {
      final r = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
      ).timeout(const Duration(seconds: 8));
      // ignore: avoid_print
      print('[win-quickaccess] code=${r.exitCode}');
    } catch (_) {
      // Silently swallow — same fail-soft policy.
    }
  }
}
