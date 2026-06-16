import AppKit

let app = NSApplication.shared
let delegate = AppController()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
