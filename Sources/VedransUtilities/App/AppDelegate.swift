import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let tabs = NSTabViewController()
    private let memory = MemoryViewController()
    private let power = PowerViewController()
    private let storage = StorageViewController()
    private let cpu = CPUViewController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.applicationIconImage = AppIcon.image(size: 512)
        NSApp.mainMenu = buildMenu()
        PowerMonitor.shared.begin()

        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        tabs.canPropagateSelectedChildViewControllerTitle = false
        addTab(memory, label: "Memory", symbol: "memorychip")
        addTab(power, label: "Power", symbol: "bolt.fill")
        addTab(storage, label: "SSD", symbol: "internaldrive")
        addTab(cpu, label: "CPU", symbol: "cpu")

        let window = NSWindow(contentViewController: tabs)
        window.title = "Vedran's Utilities"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.backgroundColor = Theme.page
        window.setContentSize(NSSize(width: 1280, height: 860))
        window.contentMinSize = NSSize(width: 1120, height: 780)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        applyLaunchOptions()
    }

    /// Lets scripts open the app in a known state, for screenshots and checks.
    private func applyLaunchOptions() {
        let environment = ProcessInfo.processInfo.environment
        if let index = ["memory", "power", "ssd", "cpu"].firstIndex(of: environment["VU_TAB"] ?? "") {
            tabs.selectedTabViewItemIndex = index
        }
        if environment["VU_PROCESSOR"] == "gpu" { memory.selectForLaunch(.gpu) }
        switch environment["VU_AUTORUN"] {
        case "live": memory.startFromLaunch(sweep: nil)
        case "blocks": memory.startFromLaunch(sweep: .blocksAllOperations)
        case "map": memory.startFromLaunch(sweep: .map)
        case "threads": memory.startFromLaunch(sweep: .threads)
        case "read": storage.startReadBenchmark()
        case "cpu": cpu.startBenchmark()
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func addTab(_ controller: NSViewController, label: String, symbol: String) {
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabs.addTabViewItem(item)
    }

    @objc private func toggleBenchmark() {
        tabs.selectedTabViewItemIndex = 0
        memory.toggleRun()
    }

    @objc private func showMemory() { tabs.selectedTabViewItemIndex = 0 }
    @objc private func showPower() { tabs.selectedTabViewItemIndex = 1 }
    @objc private func showStorage() { tabs.selectedTabViewItemIndex = 2 }
    @objc private func showCPU() { tabs.selectedTabViewItemIndex = 3 }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Vedran's Utilities", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Vedran's Utilities", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Vedran's Utilities", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "Vedran's Utilities"))

        let view = NSMenu(title: "View")
        let memoryItem = view.addItem(withTitle: "Memory", action: #selector(showMemory), keyEquivalent: "1")
        memoryItem.target = self
        let powerItem = view.addItem(withTitle: "Power", action: #selector(showPower), keyEquivalent: "2")
        powerItem.target = self
        let storageItem = view.addItem(withTitle: "SSD", action: #selector(showStorage), keyEquivalent: "3")
        storageItem.target = self
        let cpuItem = view.addItem(withTitle: "CPU", action: #selector(showCPU), keyEquivalent: "4")
        cpuItem.target = self
        main.addItem(submenu(view, title: "View"))

        let benchmark = NSMenu(title: "Benchmark")
        let run = benchmark.addItem(withTitle: "Start or Stop", action: #selector(toggleBenchmark), keyEquivalent: "r")
        run.target = self
        main.addItem(submenu(benchmark, title: "Benchmark"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

enum AppIcon {
    /// The gauge motif on a rounded dark tile.
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let inset = rect.width * 0.09
            let tile = rect.insetBy(dx: inset, dy: inset)
            let radius = tile.width * 0.22
            NSGradient(starting: NSColor(hex: 0x2A2A28), ending: NSColor(hex: 0x0D0D0D))?
                .draw(in: NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius), angle: 90)

            let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
            let outer = tile.width * 0.38
            let inner = tile.width * 0.27
            let ticks = 25
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = rect.width * 0.022
            for tick in 0..<ticks {
                let ratio = Double(tick) / Double(ticks - 1)
                let angle = (150 + ratio * 240) * .pi / 180
                path.removeAllPoints()
                path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                path.line(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                (ratio < 0.72 ? Theme.blue : Theme.axis).setStroke()
                path.stroke()
            }
            let chip = CGRect(x: center.x - tile.width * 0.12, y: center.y - tile.width * 0.08, width: tile.width * 0.24, height: tile.width * 0.16)
            Theme.inkPrimary.setFill()
            NSBezierPath(roundedRect: chip, xRadius: tile.width * 0.03, yRadius: tile.width * 0.03).fill()
            return true
        }
    }

    /// Writes an .iconset folder that iconutil can turn into the bundle's .icns.
    static func exportIconset(to folder: String) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let pixels = points * scale
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name)"))
        }
    }
}
