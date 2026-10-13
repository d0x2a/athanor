import Foundation

/// Numbers and times the way the popover and log window show them.
package enum Format {
    /// "45s", "12m 5s", "3h 12m", "2d 4h".
    package static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = total % 86_400 / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    /// "6.2 GB", "182 MB", "4.5 MB", "640 KB". Binary units, as Activity Monitor uses.
    package static func bytes(_ count: UInt64) -> String {
        let value = Double(count)
        let gb = value / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = value / 1_048_576
        if mb >= 10 { return String(format: "%.0f MB", mb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", max(value / 1024, 0))
    }

    package static func cpu(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    /// "just now", "4 min ago", "2 h ago", then "yesterday", a weekday, a date.
    package static func ago(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded()))) min ago" }
        if seconds < 6 * 3600 { return "\(Int(seconds / 3600)) h ago" }
        return day(date, now: now, calendar: calendar)
    }

    /// "today", "yesterday", "Sat" within the week, else "12 Oct".
    package static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = now.timeIntervalSince(date) < 6 * 86_400 ? "EEE" : "d MMM"
        return formatter.string(from: date)
    }

    /// "06:29".
    package static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// Whether anything accepts TCP connections on localhost.
package enum PortProbe {
    package static func isOpen(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        return connectIPv4(UInt16(port)) || connectIPv6(UInt16(port))
    }

    private static func connectIPv4(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func connectIPv6(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }
}
