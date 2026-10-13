import Security

/// Whether Athanor runs in the App Sandbox, as the Mac App Store build does.
/// The entitlements decide it, so the same binary serves both builds.
///
/// Inside it, scripts run in the sandbox too: their home folder is Athanor's
/// container, and the rest of the disk is out of reach, so a login shell has
/// nothing to offer. And a copy of Athanor can only signal processes it
/// started itself, so scripts stop when Athanor quits instead of waiting for
/// the next launch to pick them up.
enum Sandbox {
    static let isActive: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
        else { return false }
        return (value as? Bool) == true
    }()
}
