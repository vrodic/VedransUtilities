import CMemBench
import XCTest
@testable import VedransUtilities

final class KernelTests: XCTestCase {
    private let size = 64 * 1024

    func testWriteFillsEveryByte() {
        var buffer = [UInt8](repeating: 0, count: size)
        mb_kernel_write(&buffer, size, 0xA5)
        XCTAssertTrue(buffer.allSatisfy { $0 == 0xA5 })
    }

    func testWriteStaysInsideRoundedLength() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        mb_kernel_write(&buffer, 600, 0xA5) // Rounds down to 512.
        XCTAssertTrue(buffer[..<512].allSatisfy { $0 == 0xA5 })
        XCTAssertTrue(buffer[512...].allSatisfy { $0 == 0 })
    }

    func testCopyDuplicatesData() {
        let source = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        var destination = [UInt8](repeating: 0, count: size)
        mb_kernel_copy(&destination, source, size)
        XCTAssertEqual(source, destination)
    }

    func testTriadComputesFormula() {
        let count = size / 8
        var a = [Double](repeating: 0, count: count)
        let b = (0..<count).map { Double($0) }
        let c = (0..<count).map { Double($0) * 2 }
        mb_kernel_triad(&a, b, c, size, 3)
        for index in 0..<count { XCTAssertEqual(a[index], b[index] + 3 * c[index]) }
    }

    func testRandomAdvancesGeneratorWithoutCrashing() {
        let buffer = [UInt8](repeating: 1, count: size)
        let state = mb_kernel_random(buffer, UInt64(size), 10_000, 0x1234_5678)
        XCTAssertNotEqual(state, 0x1234_5678)
    }
}

final class EngineTests: XCTestCase {
    private func measure(_ config: BenchmarkConfig) throws -> Double {
        let engine = try XCTUnwrap(BenchmarkEngine(config: config))
        defer { engine.stop() }
        XCTAssertTrue(engine.waitUntilReady())
        var meter = RateMeter()
        _ = meter.update(try XCTUnwrap(engine.snapshot()))
        Thread.sleep(forTimeInterval: 0.1)
        let rate = try XCTUnwrap(meter.update(try XCTUnwrap(engine.snapshot())))
        XCTAssertEqual(rate.perThread.count, config.threads)
        XCTAssertTrue(rate.perThread.allSatisfy { $0 > 0 }, "Every worker should make progress")
        XCTAssertEqual(rate.total, rate.perThread.reduce(0, +), accuracy: rate.total * 0.001)
        return rate.total
    }

    func testEveryOperationMakesProgress() throws {
        for operation in MemoryOperation.allCases {
            let rate = try measure(.init(operation: operation, blockBytes: 1 << 20, threads: 2, processor: .performance))
            XCTAssertGreaterThan(rate, 0.1, "\(operation.name) measured \(rate) GB/s")
        }
    }

    /// The physics check: if this fails, the kernels aren't really touching memory.
    func testCacheIsFasterThanDRAM() throws {
        let cached = try measure(.init(operation: .read, blockBytes: 32 << 10, threads: 1, processor: .performance))
        let dram = try measure(.init(operation: .read, blockBytes: 1 << 30, threads: 1, processor: .performance))
        XCTAssertGreaterThan(cached, dram)
    }

    func testStopDuringPreparationDoesNotHang() throws {
        let engine = try XCTUnwrap(BenchmarkEngine(config: .init(operation: .read, blockBytes: 1 << 30, threads: 2, processor: .performance)))
        engine.stop()
        XCTAssertNil(engine.snapshot())
    }

    func testImpossibleAllocationReportsFailure() throws {
        let engine = try XCTUnwrap(BenchmarkEngine(config: .init(operation: .read, blockBytes: 1 << 62, threads: 1, processor: .performance)))
        XCTAssertFalse(engine.waitUntilReady())
        engine.stop()
    }
}

final class ModelTests: XCTestCase {
    func testFootprintCountsBuffersAndThreads() {
        let config = BenchmarkConfig(operation: .triad, blockBytes: 1 << 20, threads: 4, processor: .performance)
        XCTAssertEqual(config.footprintBytes, 12 << 20)
    }

    func testEffectiveConfigShrinksToMemoryLimit() {
        let controller = MemoryBenchController(topology: .current)
        controller.update(.init(operation: .triad, blockBytes: 1 << 31, threads: controller.topology.maxThreads(for: .performance), processor: .performance))
        XCTAssertLessThanOrEqual(controller.effectiveConfig.footprintBytes, controller.footprintLimit)
    }

    func testMemoryLevels() {
        let topology = SystemTopology(
            chipName: "Test",
            memoryBytes: 1 << 34,
            logicalCPUs: 8,
            performance: .init(cores: 4, l1Bytes: 128 << 10, l2Bytes: 16 << 20, coresPerL2: 4),
            efficiency: .init(cores: 4, l1Bytes: 64 << 10, l2Bytes: 4 << 20, coresPerL2: 4)
        )
        func level(_ block: UInt64, _ op: MemoryOperation = .read, threads: Int = 1) -> SystemTopology.MemoryLevel {
            topology.level(for: .init(operation: op, blockBytes: block, threads: threads, processor: .performance))
        }
        XCTAssertEqual(level(64 << 10), .l1)
        XCTAssertEqual(level(64 << 10, .triad), .l2, "Three buffers no longer fit in L1")
        XCTAssertEqual(level(8 << 20), .l2)
        XCTAssertEqual(level(8 << 20, threads: 4), .memory, "Four threads share the L2")
        XCTAssertEqual(level(1 << 30), .memory)
    }

    func testRunStatistics() {
        var stats = RunStatistics()
        [10.0, 20, 30].forEach { stats.add($0) }
        XCTAssertEqual(stats.mean, 20)
        XCTAssertEqual(stats.peak, 30)
        XCTAssertEqual(stats.minimum, 10)
        XCTAssertEqual(stats.jitterPercent, 50, accuracy: 0.001)
    }

    func testSweepPlansCoverTheirAxes() {
        let base = BenchmarkConfig(operation: .copy, blockBytes: 1 << 20, threads: 2, processor: .efficiency)
        XCTAssertEqual(SweepPlan.configs(.blocks, from: base, maxThreads: 4).count, BlockSizes.sweep.count)
        XCTAssertEqual(SweepPlan.configs(.threads, from: base, maxThreads: 4).map(\.threads), [1, 2, 3, 4])
        XCTAssertEqual(SweepPlan.configs(.map, from: base, maxThreads: 4).count, BlockSizes.sweep.count * 4)
        XCTAssertEqual(
            SweepPlan.configs(.blocksAllOperations, from: base, maxThreads: 4).count,
            BlockSizes.sweep.count * MemoryOperation.allCases.count
        )
        XCTAssertTrue(SweepPlan.configs(.map, from: base, maxThreads: 4).allSatisfy { $0.processor == .efficiency })
    }

    func testSteadinessIgnoresSmallNoiseButNotRampUp() {
        XCTAssertTrue(SweepRunner.isSteady([100, 101, 99, 100, 98][...]))
        XCTAssertFalse(SweepRunner.isSteady([60, 80, 95, 100, 100][...]))
        XCTAssertFalse(SweepRunner.isSteady([0, 0, 0][...]))
    }

    func testCSVOutput() {
        let results = BenchmarkResults()
        results.record(.init(operation: .read, blockBytes: 4096, threads: 1, processor: .performance), gigabytesPerSecond: 12.3456)
        XCTAssertEqual(results.csv, "operation,processor,threads,block_bytes,gb_per_s\nRead,Performance,1,4096,12.346\n")
    }

    func testFormats() {
        XCTAssertEqual(Format.bytes(4096), "4 KiB")
        XCTAssertEqual(Format.bytes(1 << 30), "1 GiB")
        XCTAssertEqual(Format.bytes(3 << 29), "1.5 GiB")
        XCTAssertEqual(Format.number(251.6), "252")
        XCTAssertEqual(Format.number(91.04), "91.0")
        XCTAssertEqual(Format.number(4.216), "4.22")
        XCTAssertEqual(Format.watts(nil), "—")
        XCTAssertEqual(Format.duration(minutes: 135), "2 h 15 min")
    }

    func testBatteryParsingHandlesWrappedCurrentAndMissingValues() throws {
        let status = try XCTUnwrap(PowerMonitor.parseBattery([
            "CurrentCapacity": 80,
            "Voltage": 12000,
            "InstantAmperage": NSNumber(value: UInt64(bitPattern: -1000)),
            "ExternalConnected": false,
            "TimeRemaining": 65535,
            "BatteryData": ["DesignCapacity": 6000, "NominalChargeCapacity": 5400],
        ], temperature: 30))
        XCTAssertEqual(status.flowWatts, -12, accuracy: 0.001)
        XCTAssertEqual(status.healthPercent, 90)
        XCTAssertNil(status.minutesRemaining)
        XCTAssertNil(status.adapterRatedWatts)
        XCTAssertNil(PowerMonitor.parseBattery([:], temperature: nil))
    }
}
