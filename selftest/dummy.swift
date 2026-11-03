import AppKit
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
w.title = "Dummy"; w.orderFrontRegardless(); app.run()
