import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock - menu bar only app
        NSApp.setActivationPolicy(.accessory)
    }
}
