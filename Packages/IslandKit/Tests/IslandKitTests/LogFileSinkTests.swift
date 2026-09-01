import Foundation
import Testing
@testable import IslandKit

@Suite("The rotating log file")
struct LogFileSinkTests {

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = try IslandLogTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("lines are appended in order, each on its own row")
    func appendsInOrder() throws {
        try withDirectory { directory in
            let sink = LogFileSink(directory: directory)
            sink.write("a")
            sink.write("b")
            sink.write("c")
            sink.drain()
            let text = try String(contentsOf: sink.activeFileURL, encoding: .utf8)
            #expect(text == "a\nb\nc\n")
        }
    }

    @Test("a missing directory is created")
    func createsDirectory() throws {
        try withDirectory { directory in
            let nested = directory.appendingPathComponent("deeper/still", isDirectory: true)
            let sink = LogFileSink(directory: nested)
            sink.write("x")
            sink.drain()
            #expect(FileManager.default.fileExists(atPath: sink.activeFileURL.path))
            #expect(sink.lastFailure == nil)
        }
    }

    /// A second session appends to the same file, separated by one blank row — the file is a
    /// history, not a scratch pad, and the previous run is the one a bug report is usually about.
    @Test("a second sink on the same file appends after a blank row")
    func secondSessionAppends() throws {
        try withDirectory { directory in
            let first = LogFileSink(directory: directory)
            first.write("session one")
            first.close()

            let second = LogFileSink(directory: directory)
            second.write("session two")
            second.drain()

            let text = try String(contentsOf: second.activeFileURL, encoding: .utf8)
            #expect(text == "session one\n\nsession two\n")
        }
    }

    @Test("crossing the size limit shifts the set and drops the oldest")
    func rotates() throws {
        try withDirectory { directory in
            // 1024 is the smallest limit the sink accepts; 40-byte rows cross it every ~26 rows.
            let sink = LogFileSink(directory: directory, maximumFileSize: 1024, retainedFileCount: 3)
            let row = String(repeating: "x", count: 39)
            for index in 0..<200 {
                sink.write(String(format: "%03d", index) + row.dropFirst(3))
            }
            sink.drain()

            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(names == ["isleta.1.log", "isleta.2.log", "isleta.log"])

            // Nothing retained is over the limit by more than one row, and nothing was reordered:
            // concatenated oldest-first the surviving rows are still strictly increasing.
            let files = LogExport.collectFiles(in: directory)
            #expect(files.map(\.name) == ["isleta.2.log", "isleta.1.log", "isleta.log"])
            for file in files {
                #expect(file.size <= 1024 + 40, Comment(rawValue: file.name))
            }
            let rows = try files
                .flatMap { try String(contentsOf: $0.url, encoding: .utf8).split(separator: "\n") }
                .compactMap { Int($0.prefix(3)) }
            #expect(rows == Array(rows.sorted()))
            #expect(rows.last == 199)
            #expect(rows.count < 200, "the oldest file was dropped")
        }
    }

    @Test("a directory that cannot be written stops the sink and reports why")
    func failureIsRecorded() throws {
        try withDirectory { directory in
            // A regular file where the directory should be: `createDirectory` cannot succeed.
            let blocker = directory.appendingPathComponent("blocked", isDirectory: false)
            try Data("not a directory".utf8).write(to: blocker)
            let sink = LogFileSink(directory: blocker)
            sink.write("anything")
            sink.drain()
            #expect(sink.lastFailure != nil)
            #expect(sink.status.contains("writing stopped"))
        }
    }

    @Test("the file name test accepts the rotation's names and nothing else")
    func fileNames() {
        #expect(LogFileSink.rotatedFileName(0) == "isleta.log")
        #expect(LogFileSink.rotatedFileName(3) == "isleta.3.log")
        #expect(LogFileSink.isLogFileName("isleta.log"))
        #expect(LogFileSink.isLogFileName("isleta.12.log"))
        #expect(!LogFileSink.isLogFileName("isleta.log.bak"))
        #expect(!LogFileSink.isLogFileName("other.log"))
        #expect(!LogFileSink.isLogFileName(".DS_Store"))
    }
}
