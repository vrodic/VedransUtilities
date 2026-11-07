import AppKit

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--export-iconset" {
    try AppIcon.exportIconset(to: arguments[2])
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
