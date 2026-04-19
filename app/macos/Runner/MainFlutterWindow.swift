import Cocoa
import FlutterMacOS

/// Main window. Intercepts the red close button (windowShouldClose) so
/// the window HIDES instead of closing — the host's tunnel + HTTPS
/// server keep running, and the menu-bar tray stays visible. This is
/// the macOS-native version of the "hide-to-tray" pattern; the earlier
/// Dart-side window_manager approach wasn't firing reliably (the app
/// was dying to a black shell), so we intercept one level down where
/// Cocoa itself will honor the NO.
///
/// "Quit Weeber" in the tray menu calls NSApp.terminate(nil) via a
/// method channel, which bypasses windowShouldClose and actually exits.
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var quitRequested = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Bridge for the tray's "Quit Weeber" action. When Dart calls
    // this channel, we flip a flag + terminate so the next
    // windowShouldClose allows the close through.
    let quitChannel = FlutterMethodChannel(
      name: "app.weeber/quit",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    quitChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "quit":
        self?.quitRequested = true
        NSApp.terminate(nil)
        result(nil)
      case "show":
        // Bring the app back from accessory (menu-bar-only) into a
        // regular dock-shown application, then show + focus the
        // window. Used by the tray's "Open Weeber" menu item.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        self?.makeKeyAndOrderFront(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if quitRequested { return true }
    // User clicked the red ✕ — hide instead. orderOut removes the
    // window from screen without destroying it; next `show()` from
    // the tray brings it back instantly.
    self.orderOut(nil)
    // Also hide the app from the Dock so clicking the dock icon
    // doesn't re-show it behind the curtain; the tray icon is the
    // canonical way back in.
    NSApp.setActivationPolicy(.accessory)
    return false
  }
}
