import AppKit
import XCTest
@testable import VedransUtilities

/// Fires real controls through their target/action paths, without a window server session.
final class InterfaceWiringTests: XCTestCase {
    // Controls hold their targets weakly, so the view controller must outlive the view.
    private var owner: MemoryViewController!

    override func setUp() {
        owner = MemoryViewController()
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { all(type, in: $0) }
    }

    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(all(NSButton.self, in: view).first { $0.title == title }, "No button titled \(title)")
    }

    private func spin(until condition: @escaping () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition())
    }

    func testStartButtonRunsAndStops() throws {
        let view = owner.view
        let start = try button("Start", in: view)
        start.performClick(nil)
        XCTAssertEqual(start.title, "Stop")
        let peak = try XCTUnwrap(all(StatTile.self, in: view).first { $0.title == "Peak" })
        spin(until: { peak.value != "—" })
        XCTAssertTrue(peak.value.hasSuffix("GB/s"))
        start.performClick(nil)
        XCTAssertEqual(start.title, "Start")
    }

    func testSlidersUpdateTheirReadouts() throws {
        let view = owner.view
        let sliders = all(NSSlider.self, in: view)
        let block = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "Block size" })
        let threads = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "Threads" })
        block.doubleValue = 2 // 16 KiB
        _ = block.sendAction(block.action, to: block.target)
        threads.doubleValue = 3
        _ = threads.sendAction(threads.action, to: threads.target)
        let labels = all(NSTextField.self, in: view).map(\.stringValue)
        XCTAssertTrue(labels.contains("16 KiB"))
        XCTAssertTrue(labels.contains("3 of \(SystemTopology.current.performance.cores)"))
        XCTAssertTrue(labels.contains("Allocates 48 KiB in total."))
    }

    func testOperationRowsAreSelectableAndExclusive() throws {
        let view = owner.view
        let copy = try button("Copy", in: view)
        copy.performClick(nil)
        XCTAssertEqual(copy.state, .on)
        XCTAssertEqual(try button("Read", in: view).state, .off)
        // Copy uses two buffers: 256 MiB x 4 threads x 2.
        XCTAssertTrue(all(NSTextField.self, in: view).map(\.stringValue).contains("Allocates 2 GiB in total."))
    }

    func testPickingASweepRunsItAndCancelReturnsToStart() throws {
        let view = owner.view
        let picker = try XCTUnwrap(all(NSPopUpButton.self, in: view).first)
        XCTAssertEqual(picker.itemTitles.count, SweepKind.allCases.count + 1)
        picker.selectItem(withTitle: SweepKind.blocks.title)
        _ = picker.sendAction(picker.action, to: picker.target)
        let start = try button("Cancel Sweep", in: view)
        XCTAssertFalse(picker.isEnabled, "Settings are locked during a sweep")
        start.performClick(nil)
        spin(until: { start.title == "Start" })
        XCTAssertTrue(picker.isEnabled)
    }

    func testAnalysisTabsSwitchTheVisibleChart() throws {
        let view = owner.view
        let control = try XCTUnwrap(all(NSSegmentedControl.self, in: view).first { $0.label(forSegment: 0) == "Block Curve" })
        let heatmap = try XCTUnwrap(all(HeatmapView.self, in: view).first)
        XCTAssertTrue(heatmap.isHidden)
        control.selectedSegment = 1
        _ = control.sendAction(control.action, to: control.target)
        XCTAssertFalse(heatmap.isHidden)
    }

    func testClickingAHeatmapCellChoosesThatConfiguration() throws {
        let view = owner.view
        let heatmap = try XCTUnwrap(all(HeatmapView.self, in: view).first)
        heatmap.onSelect?(.init(column: 0, row: 7))
        let labels = all(NSTextField.self, in: view).map(\.stringValue)
        XCTAssertTrue(labels.contains("4 KiB"))
        XCTAssertTrue(labels.contains("8 of \(SystemTopology.current.performance.cores)"))
    }
}

extension InterfaceWiringTests {
    private func select(_ processor: Processor, in view: NSView) throws {
        let control = try XCTUnwrap(allViews(NSSegmentedControl.self, in: view).first { $0.segmentCount == Processor.allCases.count && $0.label(forSegment: 2) == "GPU" })
        control.selectedSegment = processor.rawValue
        _ = control.sendAction(control.action, to: control.target)
    }

    private func allViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { allViews(type, in: $0) }
    }

    func testThreadSliderIsCappedToTheChosenCoreType() throws {
        let view = owner.view
        let threads = try XCTUnwrap(allViews(NSSlider.self, in: view).first { $0.accessibilityLabel() == "Threads" })
        XCTAssertEqual(threads.maxValue, Double(SystemTopology.current.performance.cores))
        threads.doubleValue = threads.maxValue
        _ = threads.sendAction(threads.action, to: threads.target)

        try select(.efficiency, in: view)
        XCTAssertEqual(threads.maxValue, Double(SystemTopology.current.efficiency.cores))
        XCTAssertEqual(threads.doubleValue, threads.maxValue, "Thread count should clamp to the new maximum")
    }

    func testGPUModeLocksThreadsAndThreadBasedViewsThenRestores() throws {
        let view = owner.view
        let threads = try XCTUnwrap(allViews(NSSlider.self, in: view).first { $0.accessibilityLabel() == "Threads" })
        let picker = try XCTUnwrap(allViews(NSPopUpButton.self, in: view).first)
        let analysis = try XCTUnwrap(allViews(NSSegmentedControl.self, in: view).first { $0.label(forSegment: 0) == "Block Curve" })
        let before = threads.doubleValue

        try select(.gpu, in: view)
        XCTAssertFalse(threads.isEnabled)
        XCTAssertFalse(try XCTUnwrap(picker.item(withTitle: SweepKind.map.title)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(picker.item(withTitle: SweepKind.threads.title)).isEnabled)
        XCTAssertTrue(try XCTUnwrap(picker.item(withTitle: SweepKind.blocks.title)).isEnabled)
        XCTAssertFalse(analysis.isEnabled(forSegment: 1))
        XCTAssertTrue(allViews(NSTextField.self, in: view).map(\.stringValue).contains("Set by GPU"))

        try select(.performance, in: view)
        XCTAssertTrue(threads.isEnabled)
        XCTAssertEqual(threads.doubleValue, before, "The CPU thread count returns after visiting the GPU")
        XCTAssertTrue(analysis.isEnabled(forSegment: 1))
    }

    func testGPUStartButtonProducesMeasurements() throws {
        let view = owner.view
        try select(.gpu, in: view)
        let start = try XCTUnwrap(allViews(NSButton.self, in: view).first { $0.title == "Start" })
        start.performClick(nil)
        let peak = try XCTUnwrap(allViews(StatTile.self, in: view).first { $0.title == "Peak" })
        let deadline = Date().addingTimeInterval(10)
        while peak.value == "—", Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(peak.value.hasSuffix("GB/s"))
        XCTAssertTrue(peak.caption.hasSuffix("GPU"))
        start.performClick(nil)
    }
}
