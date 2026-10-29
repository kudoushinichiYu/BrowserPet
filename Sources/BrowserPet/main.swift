import AppKit

if CommandLine.arguments.contains("--native-messaging") {
    NativeGroupHost.run()
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
