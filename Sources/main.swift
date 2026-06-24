import AppKit

let app = NSApplication.shared
NSApp.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
NSApp.activate(ignoringOtherApps: true)
app.run()
