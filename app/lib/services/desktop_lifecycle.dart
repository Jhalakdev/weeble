import 'dart:io';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Method channel to Swift. The native side hides on close instead of
/// quitting; this channel is how Dart requests a REAL quit from the
/// tray's "Quit Weeber" menu item.
const _quitChannel = MethodChannel('app.weeber/quit');

/// "Always-on" desktop integration:
///   - Auto-launch on system boot (LaunchAgent on macOS, Run registry
///     entry on Windows, autostart .desktop on Linux). Re-asserted every
///     launch so a stale entry can't drift.
///   - Menu-bar (macOS) / system-tray (Windows + Linux) icon with a
///     small context menu: Open Weeber, Status, Quit.
///   - Closing the window HIDES it instead of quitting, so the host
///     keeps serving files. "Quit Weeber" in the tray menu is the
///     only way to actually stop the host.
///
/// Mobile platforms skip everything here.
class DesktopLifecycle with TrayListener, WindowListener {
  DesktopLifecycle._();
  static final DesktopLifecycle instance = DesktopLifecycle._();

  bool _ready = false;
  /// User can set this from elsewhere so "Show files folder" in the
  /// tray menu opens the right folder. Optional.
  String? storagePath;

  /// Call ONCE early in main() before runApp.
  Future<void> initialize() async {
    if (!_isDesktop || _ready) return;
    _ready = true;

    // Window: don't quit on close — hide instead. The host's tunnel
    // and HTTPS server keep running. On macOS the hiding is handled
    // natively in MainFlutterWindow.swift (windowShouldClose); on
    // Windows + Linux we use window_manager's Dart-side interception.
    await windowManager.ensureInitialized();
    if (!Platform.isMacOS) {
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
    }

    // Tray icon — tiny menu bar / system tray entry.
    try {
      await trayManager.setIcon('assets/tray_icon.png');
      await trayManager.setToolTip('Weeber');
      await trayManager.setContextMenu(_menu(connected: false));
      trayManager.addListener(this);
    } catch (e) {
      // ignore: avoid_print
      print('[lifecycle] tray init failed: $e');
    }

    // Auto-launch on boot.
    try {
      launchAtStartup.setup(
        appName: 'Weeber',
        appPath: Platform.resolvedExecutable,
        packageName: 'app.weeber.weeber',
      );
      final enabled = await launchAtStartup.isEnabled();
      if (!enabled) await launchAtStartup.enable();
    } catch (e) {
      // ignore: avoid_print
      print('[lifecycle] auto-launch setup failed: $e');
    }
  }

  /// Update the menu when host status changes (so users see Connected /
  /// Disconnected without opening the app).
  Future<void> updateStatus({required bool connected}) async {
    if (!_ready) return;
    try {
      await trayManager.setContextMenu(_menu(connected: connected));
      await trayManager.setToolTip(connected ? 'Weeber — online' : 'Weeber — offline');
    } catch (_) {}
  }

  Menu _menu({required bool connected}) {
    return Menu(items: [
      MenuItem(
        key: 'status',
        label: connected ? '● Connected' : '○ Disconnected',
        disabled: true,
      ),
      MenuItem.separator(),
      MenuItem(key: 'open', label: 'Open Weeber'),
      MenuItem(key: 'show_files', label: 'Show files folder'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit Weeber'),
    ]);
  }

  // ---- TrayListener
  @override
  void onTrayIconMouseDown() {
    if (Platform.isMacOS) {
      trayManager.popUpContextMenu();
    } else {
      _showWindow();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'open': _showWindow(); break;
      case 'show_files': _openFilesFolder(); break;
      case 'quit': _hardQuit(); break;
    }
  }

  // ---- WindowListener
  @override
  void onWindowClose() async {
    // User clicked the red X — keep running, just hide.
    await windowManager.hide();
  }

  Future<void> _showWindow() async {
    // On macOS the window was hidden via orderOut() + activation
    // policy = accessory. Flip it back to regular so the dock icon
    // returns, then show + focus.
    if (Platform.isMacOS) {
      try {
        await _quitChannel.invokeMethod('show');
      } catch (_) {}
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _openFilesFolder() async {
    final p = storagePath;
    if (p == null) return;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [p]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [p]);
      } else {
        await Process.run('xdg-open', [p]);
      }
    } catch (_) {}
  }

  Future<void> _hardQuit() async {
    if (Platform.isMacOS) {
      // Ask Swift to call NSApp.terminate(nil) — the Swift delegate
      // flips its quitRequested flag first so the next
      // windowShouldClose returns YES and the app genuinely exits.
      try {
        await _quitChannel.invokeMethod('quit');
      } catch (_) {
        // Fall through to window_manager's destroy as a backstop.
        await windowManager.destroy();
      }
    } else {
      await windowManager.destroy();
    }
  }

  bool get _isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

// Keep flutter/services in scope for any future MethodChannel callers.
// ignore: unused_element
final _keepFlutterServices = SystemNavigator.routeInformationUpdated;
