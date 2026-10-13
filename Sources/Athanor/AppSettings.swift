import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement

/// What happens to running scripts when Athanor quits.
enum QuitBehavior: String, CaseIterable {
    case stop
    case leave
    case ask
}

/// A global keyboard shortcut, in the terms Carbon's hot key API takes.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// "⌥⌘A"
    var display: String

    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey | cmdKey), display: "⌥⌘A")

    init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    /// From a key press while recording one. Needs ⌘, ⌥ or ⌃, so plain typing
    /// can't become a shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        let key = Self.keyName(event)
        guard !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: symbols + key)
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            return (event.charactersIgnoringModifiers ?? "").uppercased()
        }
    }
}

/// Preferences, kept in UserDefaults. Login items are the system's, so that
/// one is read from and written to ServiceManagement directly.
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var showRunningCount: Bool {
        didSet { defaults.set(showRunningCount, forKey: "showRunningCount") }
    }
    var quitBehavior: QuitBehavior {
        didSet { defaults.set(quitBehavior.rawValue, forKey: "quitBehavior") }
    }
    /// A script crashed and won't be restarted (restart off, or it gave up).
    var notifyWhenDown: Bool {
        didSet { defaults.set(notifyWhenDown, forKey: "notifyWhenDown") }
    }
    var notifyOnRestart: Bool {
        didSet { defaults.set(notifyOnRestart, forKey: "notifyOnRestart") }
    }
    var notifyOnFinish: Bool {
        didSet { defaults.set(notifyOnFinish, forKey: "notifyOnFinish") }
    }
    var logCapMB: Int {
        didSet { defaults.set(logCapMB, forKey: "logCapMB") }
    }
    var hotkey: Hotkey? {
        didSet {
            if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
                defaults.set(data, forKey: "hotkey")
            } else {
                defaults.set(Data(), forKey: "hotkey")
            }
        }
    }
    /// Bumped to make views re-read the login item status.
    private(set) var loginItemRevision = 0

    var logCapBytes: Int64 { Int64(logCapMB) * 1_048_576 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "showRunningCount": false,
            "quitBehavior": QuitBehavior.leave.rawValue,
            "notifyWhenDown": true,
            "notifyOnRestart": false,
            "notifyOnFinish": false,
            "logCapMB": 10,
        ])
        showRunningCount = defaults.bool(forKey: "showRunningCount")
        quitBehavior = QuitBehavior(rawValue: defaults.string(forKey: "quitBehavior") ?? "") ?? .leave
        notifyWhenDown = defaults.bool(forKey: "notifyWhenDown")
        notifyOnRestart = defaults.bool(forKey: "notifyOnRestart")
        notifyOnFinish = defaults.bool(forKey: "notifyOnFinish")
        logCapMB = max(1, defaults.integer(forKey: "logCapMB"))
        // No entry yet means the default shortcut; an empty one means none.
        if let data = defaults.data(forKey: "hotkey") {
            hotkey = data.isEmpty ? nil : (try? JSONDecoder().decode(Hotkey.self, from: data))
        } else {
            hotkey = .default
        }
    }

    var launchesAtLogin: Bool {
        _ = loginItemRevision
        return SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) throws {
        defer { loginItemRevision += 1 }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
