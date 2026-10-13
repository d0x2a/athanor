import Foundation

/// Decides what happens after a crash: restart after a pause, or stop trying
/// because the script keeps crashing.
package struct RestartPolicy: Sendable, Equatable {
    package enum Decision: Equatable, Sendable {
        /// Restart number `attempt` within the window, after `delay` seconds.
        case restart(attempt: Int, delay: TimeInterval)
        /// The limit is used up: `crashes` crashes over the last `span` seconds.
        case giveUp(crashes: Int, span: TimeInterval)
    }

    /// Pauses before restart 1, 2, 3 and any after.
    package static let delays: [TimeInterval] = [1, 3, 10, 30]

    package var limit: Int
    package var window: TimeInterval
    /// When each restart in the window was decided on, oldest first.
    package private(set) var restarts: [Date] = []

    package init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    package mutating func crashed(at now: Date) -> Decision {
        restarts.removeAll { now.timeIntervalSince($0) >= window }
        guard restarts.count < limit else {
            let span = restarts.first.map { now.timeIntervalSince($0) } ?? 0
            return .giveUp(crashes: restarts.count + 1, span: span)
        }
        restarts.append(now)
        let attempt = restarts.count
        return .restart(attempt: attempt, delay: Self.delays[min(attempt, Self.delays.count) - 1])
    }

    /// A start by hand wipes the slate.
    package mutating func reset() {
        restarts.removeAll()
    }
}
