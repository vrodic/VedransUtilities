import XCTest
import Metal
@testable import VedransUtilities

/// Exercises the same controller paths the interface drives, on the real engine.
final class ControllerTests: XCTestCase {
    private let small = BenchmarkConfig(operation: .read, blockBytes: 1 << 20, threads: 2, processor: .performance)

    private func makeController() -> MemoryBenchController {
        let controller = MemoryBenchController(topology: .current)
        controller.update(small)
        return controller
    }

    private func wait(for what: String, timeout: TimeInterval = 15, until condition: @escaping () -> Bool) {
        let done = expectation(description: what)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if condition() {
                timer.invalidate()
                done.fulfill()
            }
        }
        wait(for: [done], timeout: timeout)
        timer.invalidate()
    }

    func testLiveRunPublishesSamplesAndRecordsResultOnStop() {
        let controller = makeController()
        var latest: MemoryBenchController.Sample?
        controller.onSample = { latest = $0 }
        controller.toggleLive()
        XCTAssertEqual(controller.activity, .preparing)
        wait(for: "sustained samples") { (latest?.statistics.count ?? 0) > 20 && latest!.time > 1.2 }
        XCTAssertEqual(controller.activity, .live)
        XCTAssertEqual(latest?.perThread.count, 2)
        XCTAssertGreaterThan(latest?.gigabytesPerSecond ?? 0, 0)

        controller.toggleLive()
        XCTAssertEqual(controller.activity, .idle)
        XCTAssertNotNil(controller.results.values[small], "A sustained live run counts as a result")
    }

    func testChangingConfigWhileLiveRestartsTheEngineWithNewSettings() {
        let controller = makeController()
        var latest: MemoryBenchController.Sample?
        controller.onSample = { latest = $0 }
        controller.toggleLive()
        wait(for: "first samples") { latest?.config == self.small }

        var changed = small
        changed.operation = .write
        changed.threads = 3
        controller.update(changed)
        wait(for: "restart") { latest?.config == changed }
        XCTAssertEqual(latest?.perThread.count, 3)
        controller.stop()
    }

    func testRapidSliderChangesSettleOnTheLastValue() {
        let controller = makeController()
        var latest: MemoryBenchController.Sample?
        controller.onSample = { latest = $0 }
        controller.toggleLive()
        var config = small
        for block in BlockSizes.all.prefix(10) {
            config.blockBytes = block
            controller.update(config)
        }
        wait(for: "settled") { latest?.config == config }
        controller.stop()
    }

    func testStopDuringPreparationEndsIdleAndStaysIdle() {
        let controller = makeController()
        var big = small
        big.blockBytes = 1 << 30
        controller.update(big)
        controller.toggleLive()
        controller.toggleLive()
        XCTAssertEqual(controller.activity, .idle)
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        XCTAssertEqual(controller.activity, .idle, "A late-finishing start must not revive the run")
    }

    func testThreadSweepCompletesAndFillsResults() {
        let controller = makeController()
        var activities: [MemoryBenchController.Activity] = []
        controller.onActivity = { activities.append($0) }
        controller.startSweep(.threads)
        wait(for: "sweep", timeout: 60) { controller.activity == .idle }
        let measured = (1...controller.topology.maxThreads(for: .performance)).compactMap {
            controller.results.values[BenchmarkConfig(operation: .read, blockBytes: 1 << 20, threads: $0, processor: .performance)]
        }
        XCTAssertEqual(measured.count, controller.topology.maxThreads(for: .performance))
        XCTAssertTrue(measured.allSatisfy { $0 > 0 })
        XCTAssertEqual(activities.last, .idle)
    }

    func testCancelledSweepStopsEarlyWithoutMarkingCellsSkipped() {
        let controller = makeController()
        controller.startSweep(.blocksAllOperations)
        wait(for: "some results") { controller.results.values.count >= 2 }
        controller.toggleLive()
        wait(for: "cancelled") { controller.activity == .idle }
        let total = BlockSizes.sweep.count * MemoryOperation.allCases.count
        XCTAssertLessThan(controller.results.values.count, total)
        XCTAssertTrue(controller.results.skipped.isEmpty)
    }

    func testOversizedConfigurationsAreSkippedNotRun() {
        let results = BenchmarkResults()
        let oversized = BenchmarkConfig(operation: .read, blockBytes: 1 << 20, threads: 2, processor: .performance)
        let runner = SweepRunner(plan: [oversized], footprintLimit: 1 << 10)
        let done = expectation(description: "finished")
        runner.start(
            onEngine: { _, _ in XCTFail("Oversized configuration must not start") },
            onResult: { config, value in
                if value == nil { results.markSkipped(config) }
            },
            onFinish: { _ in done.fulfill() }
        )
        wait(for: [done], timeout: 5)
        XCTAssertTrue(results.skipped.contains(oversized))
    }

    func testEfficiencyCoresAreSlowerThanPerformanceCores() throws {
        func rate(_ processor: Processor) throws -> Double {
            let engine = try XCTUnwrap(BenchmarkEngine(config: .init(operation: .read, blockBytes: 16 << 10, threads: 1, processor: processor)))
            defer { engine.stop() }
            XCTAssertTrue(engine.waitUntilReady())
            var meter = RateMeter()
            _ = meter.update(try XCTUnwrap(engine.snapshot()))
            Thread.sleep(forTimeInterval: 0.2)
            return try XCTUnwrap(meter.update(try XCTUnwrap(engine.snapshot()))).total
        }
        XCTAssertGreaterThan(try rate(.performance), try rate(.efficiency), "QoS should steer these onto different core types")
    }
}

/// Checks what the shaders actually compute, on shared buffers the test can read.
final class GPUKernelTests: XCTestCase {
    private let block: UInt64 = 64 << 10

    private func run(
        _ operation: MemoryOperation,
        buffers: [MTLBuffer],
        sink: MTLBuffer,
        sentinel: UInt32 = GPUKernels.neverMatches,
        invocations: Int? = nil
    ) throws {
        let kernels = try XCTUnwrap(GPUKernels.shared)
        let commandBuffer = try XCTUnwrap(kernels.queue.makeCommandBuffer())
        kernels.encode(
            operation,
            buffers: buffers,
            sink: sink,
            blockBytes: block,
            invocations: invocations ?? Int(block / GPUKernels.invocationBytes(operation)),
            start: 0,
            seed: 1,
            sentinel: sentinel,
            into: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
    }

    private func buffer(filledWith value: Float? = nil, words: UInt32? = nil) throws -> MTLBuffer {
        let kernels = try XCTUnwrap(GPUKernels.shared)
        let buffer = try XCTUnwrap(kernels.device.makeBuffer(length: Int(block), options: .storageModeShared))
        let count = Int(block) / 4
        if let value { buffer.contents().bindMemory(to: Float.self, capacity: count).initialize(repeating: value, count: count) }
        if let words { buffer.contents().bindMemory(to: UInt32.self, capacity: count).initialize(repeating: words, count: count) }
        return buffer
    }

    private func words(_ buffer: MTLBuffer) -> UnsafeBufferPointer<UInt32> {
        UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt32.self, capacity: Int(block) / 4), count: Int(block) / 4)
    }

    func testWriteFillsTheWholeBlock() throws {
        let target = try buffer(words: 0)
        try run(.write, buffers: [target], sink: buffer(words: 0))
        XCTAssertTrue(words(target).allSatisfy { $0 == 0xA5A5_A5A5 })
    }

    func testCopyDuplicatesData() throws {
        let source = try buffer(words: 0)
        let destination = try buffer(words: 0)
        let input = source.contents().bindMemory(to: UInt32.self, capacity: Int(block) / 4)
        for index in 0..<Int(block) / 4 { input[index] = UInt32(index) &* 2_654_435_761 }
        try run(.copy, buffers: [source, destination], sink: buffer(words: 0))
        XCTAssertTrue(zip(words(source), words(destination)).allSatisfy { $0 == $1 })
    }

    func testTriadComputesFormula() throws {
        let a = try buffer(filledWith: 0)
        try run(.triad, buffers: [a, buffer(filledWith: 1), buffer(filledWith: 2)], sink: buffer(words: 0))
        let result = UnsafeBufferPointer(start: a.contents().bindMemory(to: Float.self, capacity: Int(block) / 4), count: Int(block) / 4)
        XCTAssertTrue(result.allSatisfy { $0 == 7 })
    }

    /// If the compiler had removed the loads, a matching sentinel couldn't reach the sink.
    func testReadAndRandomReallyLoadTheData() throws {
        let readSink = try buffer(words: 0)
        // XOR of 16 identical vectors is zero.
        try run(.read, buffers: [buffer(words: 7)], sink: readSink, sentinel: 0)
        XCTAssertEqual(words(readSink)[0], 1)

        let randomSink = try buffer(words: 0)
        try run(.random, buffers: [buffer(words: 7)], sink: randomSink, sentinel: 7)
        XCTAssertEqual(words(randomSink)[0], 1)
    }

    func testNonMatchingSentinelLeavesSinkAlone() throws {
        let sink = try buffer(words: 0)
        try run(.read, buffers: [buffer(words: 7)], sink: sink)
        XCTAssertEqual(words(sink)[0], 0)
    }

    func testDispatchLargerThanBlockWrapsWithoutOverrun() throws {
        let kernels = try XCTUnwrap(GPUKernels.shared)
        let guarded = try XCTUnwrap(kernels.device.makeBuffer(length: Int(block) * 2, options: .storageModeShared))
        memset(guarded.contents(), 0, guarded.length)
        try run(.write, buffers: [guarded], sink: buffer(words: 0), invocations: Int(block / GPUKernels.chunkBytes) * 3)
        let all = UnsafeBufferPointer(start: guarded.contents().bindMemory(to: UInt32.self, capacity: Int(block) / 2), count: Int(block) / 2)
        XCTAssertTrue(all[..<(Int(block) / 4)].allSatisfy { $0 == 0xA5A5_A5A5 })
        XCTAssertTrue(all[(Int(block) / 4)...].allSatisfy { $0 == 0 })
    }
}

final class GPUEngineTests: XCTestCase {
    func testEveryOperationMakesProgress() throws {
        for operation in MemoryOperation.allCases {
            let engine = try XCTUnwrap(GPUBenchmarkEngine(config: .init(operation: operation, blockBytes: 16 << 20, threads: 1, processor: .gpu)))
            defer { engine.stop() }
            XCTAssertTrue(engine.waitUntilReady())
            var meter = RateMeter()
            _ = meter.update(try XCTUnwrap(engine.snapshot()))
            Thread.sleep(forTimeInterval: 0.2)
            let rate = try XCTUnwrap(meter.update(try XCTUnwrap(engine.snapshot())))
            print("GPU \(operation.name): \(Format.rate(rate.total))")
            XCTAssertGreaterThan(rate.total, 0.1, operation.name)
        }
    }

    func testStopAndSnapshotAfterStop() throws {
        let engine = try XCTUnwrap(GPUBenchmarkEngine(config: .init(operation: .read, blockBytes: 1 << 20, threads: 1, processor: .gpu)))
        XCTAssertTrue(engine.waitUntilReady())
        engine.stop()
        engine.stop()
        XCTAssertNil(engine.snapshot())
    }

    func testOversizedBufferReportsFailureInsteadOfCrashing() throws {
        let tooBig = UInt64(MTLCreateSystemDefaultDevice()!.maxBufferLength) * 2
        let engine = try XCTUnwrap(GPUBenchmarkEngine(config: .init(operation: .read, blockBytes: tooBig, threads: 1, processor: .gpu)))
        XCTAssertFalse(engine.waitUntilReady())
        engine.stop()
    }

    func testCPUEngineRefusesGPUConfig() {
        XCTAssertNil(BenchmarkEngine(config: .init(operation: .read, blockBytes: 1 << 20, threads: 1, processor: .gpu)))
    }

    func testThreadLimitsMatchCoreCounts() {
        let topology = SystemTopology.current
        XCTAssertEqual(topology.maxThreads(for: .performance), topology.performance.cores)
        XCTAssertEqual(topology.maxThreads(for: .efficiency), topology.efficiency.cores)
        XCTAssertEqual(topology.maxThreads(for: .gpu), 1)
    }
}
