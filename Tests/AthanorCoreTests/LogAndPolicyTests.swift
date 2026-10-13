@testable import AthanorCore
import Foundation
import Testing

struct LogFormatTests {
    @Test func formatsAndParses() {
        var time = timeval()
        time.tv_sec = 1_760_255_000
        time.tv_usec = 123_456
        let line = LogFormat.line(.err, "ssh: connect to host staging port 22", at: time)
        #expect(line.hasSuffix(" err ssh: connect to host staging port 22\n"))
        let parsed = LogFormat.parse(line.dropLast())
        #expect(parsed.stream == .err)
        #expect(parsed.text == "ssh: connect to host staging port 22")
        #expect(parsed.timestamp?.count == 23)
        #expect(parsed.timestamp?.hasSuffix(".123") == true)
        #expect(parsed.clockTime.count == 8)

        let foreign = LogFormat.parse("plain output line")
        #expect(foreign.timestamp == nil)
        #expect(foreign.text == "plain output line")
        #expect(LogFormat.parse("2026-10-12 09:41:03.123 ath ").text == "")
    }

    @Test func spotsErrors() {
        #expect(LogFormat.looksLikeError("ssh: Could not resolve hostname staging"))
        #expect(LogFormat.looksLikeError("Traceback (most recent call last):"))
        #expect(LogFormat.looksLikeError("ERROR: model not found"))
        #expect(!LogFormat.looksLikeError("POST /v1/chat/completions 200 · 1.82 s"))
        #expect(!LogFormat.looksLikeError("terrorist cell biology"))
    }

    @Test func stripsEscapes() {
        #expect(LogFormat.stripANSI("\u{1B}[1;32mready\u{1B}[0m in 412 ms") == "ready in 412 ms")
        #expect(LogFormat.stripANSI("\u{1B}]0;title\u{07}text") == "text")
    }

    @Test func splitsLines() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Array("one\ntwo\r\nthr".utf8)) == ["one", "two"])
        #expect(splitter.feed(Array("ee\n".utf8)) == ["three"])
        // A progress bar redrawn with \r keeps only its last state.
        #expect(splitter.feed(Array("10%\r50%\r100%\n".utf8)) == ["100%"])
        // \r\n split across reads is still one line break.
        #expect(splitter.feed(Array("a\r".utf8)) == [])
        #expect(splitter.feed(Array("\nb".utf8)) == ["a"])
        #expect(splitter.flush() == "b")
        #expect(splitter.flush() == nil)
    }
}

struct RestartPolicyTests {
    @Test func backsOffThenGivesUp() {
        var policy = RestartPolicy(limit: 3, window: 300)
        let start = Date(timeIntervalSince1970: 1000)
        #expect(policy.crashed(at: start) == .restart(attempt: 1, delay: 1))
        #expect(policy.crashed(at: start + 10) == .restart(attempt: 2, delay: 3))
        #expect(policy.crashed(at: start + 20) == .restart(attempt: 3, delay: 10))
        #expect(policy.crashed(at: start + 30) == .giveUp(crashes: 4, span: 30))
    }

    @Test func forgetsCrashesOutsideTheWindow() {
        var policy = RestartPolicy(limit: 1, window: 60)
        let start = Date(timeIntervalSince1970: 1000)
        #expect(policy.crashed(at: start) == .restart(attempt: 1, delay: 1))
        #expect(policy.crashed(at: start + 61) == .restart(attempt: 1, delay: 1))
        policy.reset()
        #expect(policy.crashed(at: start + 62) == .restart(attempt: 1, delay: 1))
    }

    @Test func zeroLimitNeverRestarts() {
        var policy = RestartPolicy(limit: 0, window: 60)
        #expect(policy.crashed(at: Date()) == .giveUp(crashes: 1, span: 0))
    }
}

struct FormatTests {
    @Test func durationsAndSizes() {
        #expect(Format.duration(45) == "45s")
        #expect(Format.duration(725) == "12m 5s")
        #expect(Format.duration(3 * 3600 + 12 * 60 + 5) == "3h 12m")
        #expect(Format.duration(2 * 86_400 + 4 * 3600) == "2d 4h")
        #expect(Format.bytes(6_657_199_308) == "6.2 GB")
        #expect(Format.bytes(190_840_832) == "182 MB")
        #expect(Format.bytes(1_048_576) == "1.0 MB")
        #expect(Format.bytes(655_360) == "640 KB")
    }

    @Test func days() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_760_263_260) // Sun 12 Oct 2025, 10:01 UTC
        #expect(Format.day(now - 3600, now: now, calendar: calendar) == "today")
        #expect(Format.day(now - 86_400, now: now, calendar: calendar) == "yesterday")
        #expect(Format.day(now - 2 * 86_400, now: now, calendar: calendar) == "Fri")
        #expect(Format.day(now - 30 * 86_400, now: now, calendar: calendar) == "12 Sep")
        #expect(Format.ago(now - 10, now: now, calendar: calendar) == "just now")
        #expect(Format.ago(now - 240, now: now, calendar: calendar) == "4 min ago")
    }
}
