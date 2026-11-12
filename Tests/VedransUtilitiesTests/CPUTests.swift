import AppKit
import CCPUBench
import XCTest
@testable import VedransUtilities

final class CPUKernelTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testSHA256MatchesPublishedVectors() {
        var digest = [UInt8](repeating: 0, count: 32)
        cb_sha256(Array("abc".utf8), 3, &digest)
        XCTAssertEqual(hex(digest), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        cb_sha256([], 0, &digest)
        XCTAssertEqual(hex(digest), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // 56 bytes: the padding spills into a second block.
        cb_sha256(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8), 56, &digest)
        XCTAssertEqual(hex(digest), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testAESMatchesFIPS197() {
        let key = (0..<16).map { UInt8($0) }
        var roundKeys = [UInt8](repeating: 0, count: 176)
        cb_aes128_expand(key, &roundKeys)
        XCTAssertEqual(hex(Array(roundKeys[160...])), "13111d7fe3944a17f307a78b4d2b30c5", "Last round key for the FIPS-197 appendix C.1 key")

        let block = (0..<16).map { UInt8($0 * 0x11) }
        // Five blocks, so both the four-at-a-time path and the remainder run.
        var data = Array(repeating: block, count: 5).flatMap { $0 }
        cb_aes128_encrypt(roundKeys, &data, data.count)
        for index in 0..<5 {
            XCTAssertEqual(hex(Array(data[index * 16..<index * 16 + 16])), "69c4e0d86a7b0430d8cdb78070b4c55a")
        }
    }

    func testSortOrdersAwkwardInputs() {
        var generator = SystemRandomNumberGenerator()
        let inputs: [[UInt32]] = [
            (0..<5000).map { _ in UInt32.random(in: 0...UInt32.max, using: &generator) },
            (0..<5000).map { _ in UInt32.random(in: 0...3, using: &generator) },
            Array(0..<3000),
            Array((0..<3000).reversed()),
            [UInt32](repeating: 7, count: 2000),
            [], [1], [2, 1],
        ]
        for input in inputs {
            var values = input
            cb_sort(&values, values.count)
            XCTAssertEqual(values, input.sorted())
        }
    }

    func testMandelbrotCountsIterations() {
        XCTAssertEqual(cb_mandelbrot(0, 0, 1, 1, 300), 300, "The origin never escapes")
        XCTAssertEqual(cb_mandelbrot(2, 2, 1, 1, 300), 1, "A far point escapes after one step")
        // c = -1 cycles forever; c = 1 goes 1, 2, 5 and escapes.
        XCTAssertEqual(cb_mandelbrot(-1, 0, 2, 2, 50), 50 + 3 + cb_mandelbrot(-1, 2, 1, 1, 50) + cb_mandelbrot(1, 2, 1, 1, 50))
    }

    func testMatrixMultiplyMatchesScalarArithmetic() {
        let side = Int(CB_MATRIX_SIDE)
        let a = (0..<side * side).map { Float($0 % 7) - 3 }
        let b = (0..<side * side).map { Float($0 % 5) * 0.5 }
        var c = [Float](repeating: -1, count: side * side)
        cb_matmul(&c, a, b)
        for (row, column) in [(0, 0), (3, 17), (31, 31), (12, 4)] {
            let expected = (0..<side).reduce(Float(0)) { $0 + a[row * side + $1] * b[$1 * side + column] }
            XCTAssertEqual(c[row * side + column], expected, accuracy: 1e-3)
        }
    }

    func testEveryWorkloadMakesProgressOnEveryThread() {
        for workload in CPUWorkload.allCases {
            let config = cb_config(work: Int32(workload.rawValue), cores: CB_CORES_PERFORMANCE, threads: 2)
            let engine = try! XCTUnwrap(cb_start(config))
            var perThread = [UInt64](repeating: 0, count: 2)
            let deadline = Date().addingTimeInterval(5)
            while perThread.contains(0), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
                XCTAssertEqual(cb_snapshot(engine, &perThread, 2), perThread.reduce(0, +))
            }
            cb_stop(engine)
            XCTAssertFalse(perThread.contains(0), workload.name)
        }
    }

    func testEngineRejectsBadConfigurations() {
        XCTAssertNil(cb_start(cb_config(work: 0, cores: 0, threads: 0)))
        XCTAssertNil(cb_start(cb_config(work: CB_WORK_COUNT, cores: 0, threads: 1)))
    }
}

final class CPUInfoTests: XCTestCase {
    private func words(_ values: [UInt32]) -> Data {
        Data(values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } })
    }

    func testFrequencyTablesInKilohertzAndHertz() {
        // M4 style: kilohertz.
        let modern = CPUInfo.parseFrequencyStates(words([1_260_000, 790, 4_512_000, 1055]))
        XCTAssertEqual(modern, [.init(megahertz: 1260, millivolts: 790), .init(megahertz: 4512, millivolts: 1055)])
        // M1 style: hertz, with an unused first slot.
        let older = CPUInfo.parseFrequencyStates(words([0, 0, 600_000_000, 781, 3_204_000_000, 1081]))
        XCTAssertEqual(older.map(\.megahertz), [600, 3204])
        XCTAssertEqual(CPUInfo.parseFrequencyStates(Data([1, 2, 3])), [])
    }

    func testDeviceTreeValuesAreNamed() {
        XCTAssertEqual(CPUInfo.revisionName(0x11), "B1")
        XCTAssertEqual(CPUInfo.revisionName(0x00), "A0")
        XCTAssertEqual(CPUInfo.designName("apple,everest"), "Everest")
        XCTAssertNil(CPUInfo.designName("ARM,v8"))
        XCTAssertEqual(CPUInfo.parsePlatform(Data("arm-io,t6041\0".utf8)), "t6041")
        XCTAssertEqual(Data("apple,sawtooth\0ARM,v8\0".utf8).strings, ["apple,sawtooth", "ARM,v8"])
    }

    func testThisMacIsDescribedConsistently() {
        let info = CPUInfo.current
        XCTAssertEqual(info.cores.count, Int(Sysctl.value("hw.logicalcpu") ?? 0))
        XCTAssertEqual(info.cores.map(\.id), Array(0..<info.cores.count))
        XCTAssertEqual(info.cores(.performance).count, SystemTopology.current.performance.cores)
        XCTAssertEqual(info.cores(.efficiency).count, SystemTopology.current.efficiency.cores)
        XCTAssertTrue(info.features.contains { $0.name == "AES" && $0.isSupported }, "The crypto test needs AES")
        XCTAssertFalse(info.features.contains { $0.name.hasPrefix("FEAT_") })
        for table in info.states.values {
            XCTAssertEqual(table.map(\.megahertz), table.map(\.megahertz).sorted(), "States run slowest to fastest")
            XCTAssertTrue(table.allSatisfy { (300...8000).contains($0.megahertz) })
        }
    }

    func testSysctlWalkStaysUnderItsRoot() {
        let names = Sysctl.names(under: "hw.optional")
        XCTAssertTrue(names.contains("hw.optional.arm64"))
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("hw.optional.") })
    }
}

final class CPULoadTests: XCTestCase {
    private let table: [CPUInfo.FrequencyState] = [.init(megahertz: 1000, millivolts: 700), .init(megahertz: 3000, millivolts: 900)]

    private func info(efficiency: Int, performance: Int) -> CPUInfo {
        var info = CPUInfo.current
        info.cores = (0..<efficiency).map { .init(id: $0, kind: .efficiency, cluster: 0) }
            + (0..<performance).map { .init(id: efficiency + $0, kind: .performance, cluster: 1) }
        info.states = [.efficiency: table, .performance: table]
        return info
    }

    func testLoadIsRunningShareAndTimeWeightedClock() {
        let before = CoreResidency(name: "PCPU0", idle: 100, states: [10, 10])
        let after = CoreResidency(name: "PCPU0", idle: 150, states: [20, 50])
        let load = CPULoadMonitor.load(from: before, to: after, table: table)
        XCTAssertEqual(load.active, 0.5, accuracy: 1e-9)
        XCTAssertEqual(load.megahertz ?? 0, (10 * 1000 + 40 * 3000) / 50, accuracy: 1e-9)
    }

    func testIdleCoreHasNoClockAndMismatchedTableIsNotTrusted() {
        let idle = CPULoadMonitor.load(from: .init(name: "E", idle: 0, states: [5, 5]), to: .init(name: "E", idle: 90, states: [5, 5]), table: table)
        XCTAssertEqual(idle, CoreLoad(active: 0, megahertz: nil))
        let busy = CPULoadMonitor.load(from: .init(name: "E", idle: 0, states: [0, 0, 0]), to: .init(name: "E", idle: 0, states: [1, 1, 1]), table: table)
        XCTAssertEqual(busy, CoreLoad(active: 1, megahertz: nil))
    }

    func testChannelsPairWithCoresByTypeWhateverTheirOrder() {
        func sample(_ p: UInt64, _ e: UInt64) -> [CoreResidency] {
            [.init(name: "PCPU0", idle: 0, states: [0, p]), .init(name: "ECPU0", idle: 0, states: [e, 0]), .init(name: "PCPU1", idle: p, states: [0, 0])]
        }
        let loads = CPULoadMonitor.loads(from: sample(0, 0), to: sample(10, 10), info: info(efficiency: 1, performance: 2))
        XCTAssertEqual(loads, [CoreLoad(active: 1, megahertz: 1000), CoreLoad(active: 1, megahertz: 3000), CoreLoad(active: 0, megahertz: nil)])
    }

    func testUnexpectedChannelsGiveNoLoadsInsteadOfWrongOnes() {
        let one = [CoreResidency(name: "PCPU0", idle: 0, states: [0, 0])]
        XCTAssertNil(CPULoadMonitor.loads(from: one, to: one, info: info(efficiency: 1, performance: 1)))
        let renamed = [CoreResidency(name: "MCPU0", idle: 0, states: [0, 0]), CoreResidency(name: "PCPU0", idle: 0, states: [0, 0])]
        XCTAssertNil(CPULoadMonitor.loads(from: renamed, to: renamed, info: info(efficiency: 1, performance: 1)))
        XCTAssertNil(CPULoadMonitor.loads(from: [], to: one, info: info(efficiency: 0, performance: 1)), "The first sample has nothing to compare with")
    }

    func testTickFallbackCountsEverythingButIdle() {
        // user, system, idle, nice
        let loads = CPULoadMonitor.loads(fromTicks: [[0, 0, 0, 0], [5, 5, 5, 5]], to: [[30, 10, 60, 0], [5, 5, 5, 5]], coreCount: 2)
        XCTAssertEqual(loads, [CoreLoad(active: 0.4), CoreLoad(active: 0)])
        XCTAssertNil(CPULoadMonitor.loads(fromTicks: [], to: [[1, 1, 1, 1]], coreCount: 1))
    }

    func testMonitorDeliversOneLoadPerCore() {
        let monitor = CPULoadMonitor()
        let delivered = expectation(description: "sample")
        delivered.assertForOverFulfill = false
        monitor.onSample = { loads in
            XCTAssertEqual(loads.count, CPUInfo.current.cores.count)
            XCTAssertTrue(loads.allSatisfy { (0...1).contains($0.active) })
            delivered.fulfill()
        }
        monitor.start()
        wait(for: [delivered], timeout: 5)
        monitor.stop()
    }
}

final class CPUInterfaceTests: XCTestCase {
    private var owner: CPUViewController!

    override func setUp() {
        owner = CPUViewController()
        owner.timing = .init(warmupSeconds: 0.01, measureSeconds: 0.04, stepSeconds: 0.02)
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { all(type, in: $0) }
    }

    private func spin(until condition: @escaping () -> Bool, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition())
    }

    func testStartFillsEveryCellAndReturnsToStart() throws {
        let view = owner.view
        let start = try XCTUnwrap(all(NSButton.self, in: view).first { $0.title == "Start" })
        start.performClick(nil)
        XCTAssertEqual(start.title, "Stop")
        spin(until: { start.title == "Start" })
        let modes = CPURunMode.available(.current)
        XCTAssertEqual(owner.results.results.count, CPUWorkload.allCases.count * modes.count)
        XCTAssertTrue(owner.results.results.values.allSatisfy { $0 > 0 })
        XCTAssertNil(owner.results.active)
        for workload in CPUWorkload.allCases { XCTAssertNotNil(owner.results.scaling(workload)) }
        XCTAssertTrue(all(NSTextField.self, in: view).contains { $0.stringValue.hasPrefix("Done.") })
    }

    func testStopKeepsFinishedTestsAndASecondRunStartsClean() throws {
        owner.timing = .init(warmupSeconds: 0.05, measureSeconds: 0.2, stepSeconds: 0.05)
        let view = owner.view
        let start = try XCTUnwrap(all(NSButton.self, in: view).first { $0.title == "Start" })
        start.performClick(nil)
        spin(until: { !self.owner.results.results.isEmpty })
        start.performClick(nil)
        spin(until: { start.title == "Start" && start.isEnabled })
        let kept = owner.results.results.count
        XCTAssertGreaterThan(kept, 0)
        XCTAssertLessThan(kept, CPUWorkload.allCases.count * CPURunMode.available(.current).count)
        XCTAssertTrue(all(NSTextField.self, in: view).contains { $0.stringValue.hasPrefix("Stopped.") })

        start.performClick(nil)
        XCTAssertTrue(owner.results.results.isEmpty)
        start.performClick(nil)
        spin(until: { start.title == "Start" && start.isEnabled })
    }

    func testProcessorFactsAreShown() throws {
        let view = owner.view
        let labels = all(NSTextField.self, in: view).map(\.stringValue)
        XCTAssertTrue(labels.contains(CPUInfo.current.chipName))
        let facts = try XCTUnwrap(all(FactListView.self, in: view).first)
        let titles = facts.rows.map(\.0)
        XCTAssertTrue(titles.contains("Performance cores"))
        XCTAssertTrue(titles.contains("Thermal state"))
        XCTAssertLessThanOrEqual(facts.rows.count, 12, "The card is sized for twelve rows")
        XCTAssertEqual(try XCTUnwrap(all(CoreGridView.self, in: view).first).cores.count, CPUInfo.current.cores.count)
    }
}
