import Foundation
import Testing
@testable import IslandKit

@Suite("Assembling an Export Logs bundle")
struct LogExportTests {

    private let utc = TimeZone(identifier: "UTC")!

    @Test("the file name is dash-separated local time with no colons")
    func fileName() {
        let date = Date(timeIntervalSince1970: 1_787_566_683) // 2026-08-24 10:18:03 UTC
        let name = LogExport.fileName(exportedAt: date, timeZone: utc)
        #expect(name == "Isleta-logs-2026-08-24-10-18-03.log")
        #expect(!name.contains(":"))
    }

    @Test("the header lists the environment with aligned values and the file count")
    func header() {
        let text = LogExport.header(
            environment: [(label: "Exported", value: "now"), (label: "App version", value: "1.0.1 (42)")],
            fileCount: 2
        )
        #expect(text.contains(" Isleta — Log Export\n"))
        #expect(text.contains("Exported:        now\n"))
        #expect(text.contains("App version:     1.0.1 (42)\n"))
        #expect(text.contains("Files included:  2\n"))
    }

    @Test("sections come before the files, and each file has a banner")
    func bundleOrder() throws {
        let older = LogExportFile(url: URL(fileURLWithPath: "/logs/isleta.1.log"), name: "isleta.1.log", size: 10, modified: Date(timeIntervalSince1970: 100))
        let newer = LogExportFile(url: URL(fileURLWithPath: "/logs/isleta.log"), name: "isleta.log", size: 2048, modified: Date(timeIntervalSince1970: 200))
        let text = LogExport.bundle(
            environment: [(label: "Exported", value: "now")],
            sections: [(title: "Diagnostics", body: "report body")],
            files: [older, newer],
            timeZone: utc
        ) { url in
            url.lastPathComponent == "isleta.log" ? "new line\n" : "old line"
        }

        let diagnostics = try #require(text.range(of: "=== Diagnostics ===\nreport body\n"))
        let first = try #require(text.range(of: "=== isleta.1.log (10 bytes, modified 1970-01-01 00:01:40.000) ===\nold line\n"))
        let second = try #require(text.range(of: "=== isleta.log (2.0 KB, modified 1970-01-01 00:03:20.000) ===\nnew line\n"))
        #expect(diagnostics.lowerBound < first.lowerBound)
        #expect(first.lowerBound < second.lowerBound)
        #expect(text.hasSuffix("\n"))
    }

    @Test("a file that cannot be read is noted inline and the rest still export")
    func unreadableFileIsNoted() {
        struct Unreadable: Error, LocalizedError { var errorDescription: String? { "gone" } }
        let broken = LogExportFile(url: URL(fileURLWithPath: "/logs/isleta.1.log"), name: "isleta.1.log", size: 0, modified: .distantPast)
        let fine = LogExportFile(url: URL(fileURLWithPath: "/logs/isleta.log"), name: "isleta.log", size: 0, modified: .distantPast)
        let text = LogExport.bundle(environment: [], files: [broken, fine], timeZone: utc) { url in
            if url.lastPathComponent == "isleta.1.log" { throw Unreadable() }
            return "ok"
        }
        #expect(text.contains("[Could not read this file: gone]"))
        #expect(text.contains("=== isleta.log"))
        #expect(text.hasSuffix("ok\n"))
    }

    @Test("collecting reads only log files, oldest first")
    func collectOrdersOldestFirst() throws {
        let directory = try IslandLogTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default

        func make(_ name: String, age: TimeInterval) throws {
            let url = directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        try make("isleta.log", age: 10)
        try make("isleta.1.log", age: 100)
        try make("isleta.2.log", age: 1000)
        try make("notes.txt", age: 5)
        try make(".DS_Store", age: 5)

        let names = LogExport.collectFiles(in: directory).map(\.name)
        #expect(names == ["isleta.2.log", "isleta.1.log", "isleta.log"])
    }

    @Test("a missing directory collects nothing rather than throwing")
    func missingDirectory() {
        let nowhere = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        #expect(LogExport.collectFiles(in: nowhere).isEmpty)
    }

    @Test("byte counts print in the unit a person would pick")
    func bytes() {
        #expect(LogExport.formatBytes(12) == "12 bytes")
        #expect(LogExport.formatBytes(3 * 1024 + 512) == "3.5 KB")
        #expect(LogExport.formatBytes(5 * 1024 * 1024) == "5.0 MB")
    }

    @Test("the host description has a version, a model and an architecture")
    func host() {
        #expect(HostDescription.macOSVersion.contains("."))
        #expect(!HostDescription.hardwareModel.isEmpty)
        #expect(HostDescription.architecture == "arm64" || HostDescription.architecture == "x86_64")
    }
}
