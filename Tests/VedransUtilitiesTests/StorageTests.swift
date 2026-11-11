import CStorageProbes
import XCTest
@testable import VedransUtilities

final class DriveHealthTests: XCTestCase {
    private func healthy() -> sp_drive {
        var raw = sp_drive()
        raw.has_smart = true
        raw.temperature_kelvin = 304
        raw.available_spare = 100
        raw.available_spare_threshold = 10
        raw.percentage_used = 3
        raw.data_units_written = 2_000_000
        return raw
    }

    func testHealthyDrivePassesEveryCheck() {
        let drive = DriveHealth(healthy())
        XCTAssertEqual(drive.status, .good)
        XCTAssertTrue(drive.checks.allSatisfy { $0.status == .good })
        XCTAssertEqual(drive.lifeRemainingPercent, 97)
        XCTAssertEqual(drive.bytesWritten, 1_024_000_000_000, "Data units are 512,000 bytes")
        XCTAssertEqual(drive.temperatureCelsius ?? 0, 30.85, accuracy: 0.001)
    }

    func testEachCriticalWarningBitFailsItsCheck() {
        let expectations: [(bit: UInt8, title: String, status: DriveHealth.Status)] = [
            (0, "Spare capacity", .critical),
            (1, "Temperature", .warning),
            (2, "Reliability", .critical),
            (3, "Writable", .critical),
        ]
        for expected in expectations {
            var raw = healthy()
            raw.critical_warning = 1 << expected.bit
            let drive = DriveHealth(raw)
            let check = drive.checks.first { $0.title == expected.title }
            XCTAssertEqual(check?.status, expected.status, expected.title)
            XCTAssertEqual(drive.status, expected.status)
            XCTAssertEqual(drive.checks.filter { $0.status != .good }.count, 1, "Only \(expected.title) should fail")
        }
    }

    func testWearAndMediaErrorThresholds() {
        var raw = healthy()
        raw.percentage_used = 92
        XCTAssertEqual(DriveHealth(raw).status, .warning)
        raw.percentage_used = 130
        let worn = DriveHealth(raw)
        XCTAssertEqual(worn.status, .critical)
        XCTAssertEqual(worn.lifeRemainingPercent, 0, "Life remaining never goes negative")
        raw = healthy()
        raw.media_errors = 2
        XCTAssertEqual(DriveHealth(raw).status, .warning)
    }

    func testDriveWithoutSMARTIsNotReportedHealthy() {
        var raw = sp_drive()
        raw.has_smart = false
        XCTAssertEqual(DriveHealth(raw).status, .warning)
        XCTAssertEqual(DriveHealth(raw).name, "Unknown drive")
    }

    func testStringsAreReadFromFixedBuffers() {
        var raw = healthy()
        withUnsafeMutableBytes(of: &raw.model) { buffer in
            let name = Array("APPLE SSD".utf8)
            buffer.copyBytes(from: name)
        }
        XCTAssertEqual(DriveHealth(raw).model, "APPLE SSD")
    }

    func testFormats() {
        XCTAssertEqual(DriveFormat.bytes(26_052_000_000_000), "26.1 TB")
        XCTAssertEqual(DriveFormat.bytes(512_000_000_000), "512 GB")
        XCTAssertEqual(DriveFormat.hours(723), "30 days")
        XCTAssertEqual(DriveFormat.hours(30), "30 h")
        XCTAssertEqual(DriveFormat.hours(24 * 365 * 2), "2.0 years")
        XCTAssertEqual(DriveFormat.count(1_234_567_890), "1.23 billion")
    }

    /// Reads this Mac's real drives. Every Apple Silicon Mac has an internal NVMe SSD.
    func testReadsTheInternalDrive() throws {
        let drives = DriveHealth.readAll()
        let drive = try XCTUnwrap(drives.first { $0.isInternal }, "Found: \(drives.map(\.name))")
        XCTAssertTrue(drive.hasSMART)
        XCTAssertFalse(drive.model.isEmpty)
        XCTAssertGreaterThan(drive.capacityBytes, 0)
        XCTAssertGreaterThan(drive.powerOnHours, 0)
        XCTAssertGreaterThan(drive.bytesWritten, 0)
        XCTAssertTrue(drive.bsdName.hasPrefix("disk"))
        XCTAssertTrue((0...100).contains(drive.availableSpare))
        print("SMART \(drive.name) fw \(drive.firmware) used \(drive.percentageUsed)% written \(DriveFormat.bytes(drive.bytesWritten)) status \(drive.status.title)")
    }
}

final class PowerSummaryWiringTests: XCTestCase {
    func testMemoryTabShowsPowerSamples() throws {
        let owner = MemoryViewController()
        let view = owner.view
        func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { all(type, in: $0) }
        }
        let summary = try XCTUnwrap(all(PowerSummaryView.self, in: view).first)
        var sample = PowerSample(time: 1)
        sample.system = 42
        sample.thisAppCPU = 12
        NotificationCenter.default.post(name: .powerSample, object: sample)
        XCTAssertEqual(summary.accessibilityLabel(), "System power 42.0 W")
        XCTAssertEqual(summary.footnote.label, "This app's CPU")
        XCTAssertEqual(summary.footnote.value, 12)
    }
}

final class FileReadBenchmarkTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReadBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeFile(_ name: String, bytes: Int) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    private func run(_ settings: FileReadBenchmark.Settings) -> FileReadBenchmark.Progress {
        let benchmark = FileReadBenchmark(settings: settings)
        let done = expectation(description: "finished")
        var result: FileReadBenchmark.Progress?
        benchmark.start { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return result!
    }

    func testFreshlyWrittenFilesAreSkippedAsCached() throws {
        _ = try makeFile("big.bin", bytes: 4 << 20)
        let progress = run(.init(roots: [folder.path], minimumFileBytes: 1 << 20))
        XCTAssertEqual(progress.filesFound, 1)
        XCTAssertEqual(progress.skippedCached, 1, "Just-written data sits in the page cache")
        XCTAssertEqual(progress.filesRead, 0)
        XCTAssertEqual(progress.totalBytes, 0)
    }

    /// With the cache check relaxed, the reading itself can be checked exactly.
    func testReadsEveryByteOfEachLargeFileOnce() throws {
        _ = try makeFile("a.bin", bytes: 3 << 20)
        _ = try makeFile("b.bin", bytes: (5 << 20) + 123)
        _ = try makeFile("small.bin", bytes: 1000)
        let progress = run(.init(roots: [folder.path], minimumFileBytes: 1 << 20, residentLimit: 1.0, requestBytes: 1 << 20))
        XCTAssertEqual(progress.filesFound, 2, "Files under the size limit are ignored")
        XCTAssertEqual(progress.filesRead, 2)
        XCTAssertEqual(progress.totalBytes, UInt64((3 << 20) + (5 << 20) + 123))
        XCTAssertEqual(Set(progress.recent.map(\.name)), ["a.bin", "b.bin"])
        XCTAssertGreaterThan(progress.averageGigabytesPerSecond, 0)
        XCTAssertFalse(progress.isSearching)
    }

    func testHardLinksAndRepeatedRootsAreReadOnce() throws {
        let original = try makeFile("a.bin", bytes: 2 << 20)
        try FileManager.default.linkItem(at: original, to: folder.appendingPathComponent("link.bin"))
        let progress = run(.init(roots: [folder.path, folder.path], minimumFileBytes: 1 << 20, residentLimit: 1.0))
        XCTAssertEqual(progress.filesFound, 1)
        XCTAssertEqual(progress.totalBytes, UInt64(2 << 20))
    }

    func testStopsAtTheByteLimit() throws {
        for index in 0..<4 { _ = try makeFile("f\(index).bin", bytes: 2 << 20) }
        let progress = run(.init(roots: [folder.path], minimumFileBytes: 1 << 20, residentLimit: 1.0, stopAfterBytes: 3 << 20, requestBytes: 1 << 20))
        XCTAssertEqual(progress.totalBytes, UInt64(3 << 20))
    }

    func testMissingRootsFinishCleanly() {
        let progress = run(.init(roots: ["/no/such/folder"]))
        XCTAssertEqual(progress.filesFound, 0)
        XCTAssertEqual(progress.totalBytes, 0)
    }

    func testResidencyReportsCachedFile() throws {
        let url = try makeFile("hot.bin", bytes: 2 << 20)
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        XCTAssertEqual(FileReadBenchmark.residentFraction(descriptor: descriptor, size: 2 << 20) ?? 0, 1, accuracy: 0.01)
    }

    func testNameShortening() {
        XCTAssertEqual(ReadBenchmarkPanel.shorten("short.dmg"), "short.dmg")
        let long = ReadBenchmarkPanel.shorten("246a2ca14728178a0982606799e2019b401aeace.dmg")
        XCTAssertEqual(long.count, 26)
        XCTAssertTrue(long.hasSuffix(".dmg"))
    }
}

extension FileReadBenchmarkTests {
    func testNestedRootsAreWalkedOnceAndLargestFileReadFirst() throws {
        let nested = folder.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try makeFile("small.bin", bytes: 2 << 20)
        try Data(repeating: 1, count: 6 << 20).write(to: nested.appendingPathComponent("large.bin"))
        let benchmark = FileReadBenchmark(settings: .init(roots: [folder.path, nested.path], minimumFileBytes: 1 << 20, residentLimit: 1.0))
        let done = expectation(description: "finished")
        var result: FileReadBenchmark.Progress?
        benchmark.start { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(result?.filesFound, 2)
        XCTAssertEqual(result?.totalBytes, UInt64(8 << 20))
        // Both files may already be queued when reading starts; if so, the larger goes first.
        XCTAssertEqual(result?.recent.count, 2)
    }

    func testReachingTheLimitEndsTheSearchToo() throws {
        for index in 0..<3 { _ = try makeFile("f\(index).bin", bytes: 2 << 20) }
        let benchmark = FileReadBenchmark(settings: .init(
            roots: [folder.path, "/System/Library"],
            minimumFileBytes: 1 << 20,
            residentLimit: 1.0,
            stopAfterBytes: 1 << 20
        ))
        let done = expectation(description: "finished")
        let started = Date()
        benchmark.start { _ in done.fulfill() }
        wait(for: [done], timeout: 15)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "A full walk of /System/Library takes far longer")
    }
}

extension FileReadBenchmarkTests {
    /// Finds an APFS-compressed file to clone. Clones keep compression, unlike a fresh
    /// write, and `ditto --hfsCompression` doesn't compress in every environment.
    private func compressedSample() -> URL? {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil) else { return nil }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 200_000 { return nil }
            var info = stat()
            if stat(url.path, &info) == 0, info.st_flags & UInt32(UF_COMPRESSED) != 0, info.st_size >= 2 << 20,
               info.st_mode & S_IFMT == S_IFREG {
                return url
            }
        }
        return nil
    }

    func testCompressedFilesAreSkipped() throws {
        _ = try makeFile("plain.bin", bytes: 3 << 20)
        let sample = try XCTUnwrap(compressedSample(), "No compressed file in /Applications to clone")
        let compressed = folder.appendingPathComponent("compressed.bin")
        XCTAssertEqual(clonefile(sample.path, compressed.path, 0), 0, String(cString: strerror(errno)))
        var info = stat()
        XCTAssertEqual(stat(compressed.path, &info), 0)
        XCTAssertNotEqual(info.st_flags & UInt32(UF_COMPRESSED), 0, "The clone should keep its compression")

        let progress = run(.init(roots: [folder.path], minimumFileBytes: 1 << 20, residentLimit: 1.0))
        XCTAssertEqual(progress.skippedCompressed, 1)
        XCTAssertEqual(progress.filesRead, 1)
        XCTAssertEqual(progress.recent.first?.name, "plain.bin")
    }
}
