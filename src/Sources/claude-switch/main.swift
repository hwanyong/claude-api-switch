import AppKit

let cliArgs = Array(CommandLine.arguments.dropFirst())

if cliArgs.isEmpty {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    exit(cliMain(cliArgs))
}
