
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
signal(SIGINT) { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
signal(SIGTERM) { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
app.run()
