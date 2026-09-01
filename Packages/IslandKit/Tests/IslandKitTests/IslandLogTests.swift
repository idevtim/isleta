import Foundation
import Testing
@testable import IslandKit

@Suite("The log line, the levels and the router")
struct IslandLogTests {

    private let utc = TimeZone(identifier: "UTC")!

    @Test("a line is timestamp, padded level, bracketed category, message")
    func lineFormat() {
        let date = Date(timeIntervalSince1970: 1_787_566_683.123) // 2026-08-24 10:18:03.123 UTC
        let line = LogLine.format(date: date, level: .info, category: IslandLog.sources, message: "hello", timeZone: utc)
        #expect(line == "2026-08-24 10:18:03.123 INFO  [sources] hello")
    }

    @Test("every level label is five characters, so the columns line up")
    func levelLabelsAlign() {
        for level in LogLevel.allCases {
            #expect(level.label.count == 5, Comment(rawValue: "\(level)"))
        }
    }

    @Test("a multi-line message is indented from its second line")
    func multiLineIndented() {
        let line = LogLine.format(date: Date(timeIntervalSince1970: 0), level: .error, category: IslandLog.app, message: "first\nsecond", timeZone: utc)
        #expect(line.hasSuffix("[app] first\n    second"))
    }

    @Test("the UTC offset prints as a sign and four digits")
    func utcOffset() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(LogLine.utcOffset(date, timeZone: utc) == "+0000")
        #expect(LogLine.utcOffset(date, timeZone: TimeZone(secondsFromGMT: -4 * 3600)!) == "-0400")
        #expect(LogLine.utcOffset(date, timeZone: TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60)!) == "+0530")
    }

    @Test("levels order debug < info < warning < error")
    func levelOrder() {
        #expect(LogLevel.debug < .info)
        #expect(LogLevel.info < .warning)
        #expect(LogLevel.warning < .error)
    }

    @Test("a level parses from its label, ignoring padding and case")
    func levelFromLabel() {
        #expect(LogLevel(label: "debug") == .debug)
        #expect(LogLevel(label: "WARN ") == .warning)
        #expect(LogLevel(label: "Error") == .error)
        #expect(LogLevel(label: "verbose") == nil)
    }

    /// The router is exercised directly rather than through `IslandLog`, whose state is global and
    /// shared with every other test in the bundle running in parallel.
    @Test("lines written before a sink exists are replayed into it, in order")
    func backlogReplays() throws {
        let router = LogRouter()
        router.write("one")
        router.write("two")
        #expect(router.backlogCount == 2)

        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = LogFileSink(directory: directory)
        router.attach(sink)
        router.write("three")
        sink.drain()

        let text = try String(contentsOf: sink.activeFileURL, encoding: .utf8)
        #expect(text == "one\ntwo\nthree\n")
        #expect(router.backlogCount == 0)
    }

    @Test("the backlog is bounded, and says how many it dropped")
    func backlogBounded() throws {
        let router = LogRouter()
        for index in 0..<(LogRouter.backlogLimit + 5) {
            router.write("line \(index)")
        }
        #expect(router.backlogCount == LogRouter.backlogLimit)

        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = LogFileSink(directory: directory)
        router.attach(sink)
        sink.drain()

        let text = try String(contentsOf: sink.activeFileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == LogRouter.backlogLimit + 1)
        #expect(lines.first?.contains("5 earlier line(s) were dropped") == true)
        #expect(lines.last == "line \(LogRouter.backlogLimit - 1)")
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IslandKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
