import AppKit

// Build-time hooks: scripts/bundle.sh renders the app icon with the first;
// the second renders the UI to PNGs (see Snapshot).
if CommandLine.arguments.count >= 3 {
    switch CommandLine.arguments[1] {
    case "--export-iconset":
        AppIcon.exportIconset(to: CommandLine.arguments[2])
        exit(0)
    case "--snapshot":
        MainActor.assumeIsolated { Snapshot.run(to: CommandLine.arguments[2]) }
    default:
        break
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // NSApplication.delegate is weak; this keeps it alive for the process.
    let delegate = AppDelegate()
    withExtendedLifetime(delegate) {
        app.delegate = delegate
        app.run()
    }
}
