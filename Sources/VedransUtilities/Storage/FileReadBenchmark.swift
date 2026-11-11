import Darwin
import Foundation

/// Measures sequential read speed from the SSD using large files already on disk.
///
/// One search thread per folder streams files to a single reader, so reading starts
/// as soon as the first file turns up and never waits on one slow folder. The reader
/// takes the largest file waiting, one at a time. Two things keep the number honest:
/// - Files already noticeably in memory are skipped, because macOS serves cached
///   pages from RAM even when caching is turned off for the read.
/// - Reads use F_NOCACHE, so they don't fill RAM or warm the cache for the next run.
/// - APFS-compressed files are skipped: the CPU decompresses them during the read,
///   so they measure decompression (about 1.3 GB/s here), not the drive.
final class FileReadBenchmark {
    struct Settings {
        var roots: [String]
        var minimumFileBytes: Int64 = 64 << 20
        /// Above this fraction of a file resident in memory, it would measure RAM, not the SSD.
        var residentLimit = 0.02
        var stopAfterBytes: UInt64 = 40_000_000_000
        var requestBytes = 32 << 20
    }

    struct FileResult {
        var name: String
        var bytes: UInt64
        var gigabytesPerSecond: Double
        /// Whether the search was still walking folders while this file was read.
        var duringSearch = false
    }

    struct Progress {
        var isSearching = true
        var filesFound = 0
        var filesRead = 0
        var skippedCached = 0
        var skippedCompressed = 0
        var skippedUnreadable = 0
        var currentFile: String?
        var currentFileFraction = 0.0
        var totalBytes: UInt64 = 0
        /// Time spent inside reads, excluding any wait for the search.
        var readingNanoseconds: UInt64 = 0
        var recent: [FileResult] = []

        var averageGigabytesPerSecond: Double {
            readingNanoseconds > 0 ? Double(totalBytes) / Double(readingNanoseconds) : 0
        }
    }

    /// Folders macOS lets any app read without asking. Home folders, Desktop,
    /// Documents and other apps' containers would trigger privacy prompts.
    static let defaultRoots = [
        "/Applications",
        "/System/Library/AssetsV2",
        "/Library",
        "/System/Library",
        "/System/Volumes/Preboot/Cryptexes",
        "/opt",
        "/usr",
        "/Users/Shared",
    ]

    let settings: Settings
    static let recentLimit = 8
    private let lock = NSCondition()
    private var queue: [(path: String, size: Int64)] = []
    private var seen = Set<FileIdentity>()
    private var progress = Progress()
    private var countedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    private var stopRequested = false
    private var finishedThreads = 0
    private var activeSearchers = 0
    private var onFinish: ((Progress) -> Void)?

    private struct FileIdentity: Hashable {
        var device: Int32
        var inode: UInt64
    }

    init(settings: Settings = Settings(roots: FileReadBenchmark.defaultRoots)) {
        self.settings = settings
    }

    /// `onFinish` runs on the main queue once both threads are done.
    func start(onFinish: @escaping (Progress) -> Void) {
        self.onFinish = onFinish
        let roots = settings.roots
        activeSearchers = roots.count
        progress.isSearching = !roots.isEmpty
        var jobs: [(String, () -> Void)] = [("read", read)]
        for root in roots {
            // A folder inside another root is left to its own thread.
            let others = Set(roots.filter { $0 != root })
            jobs.append(("search \(root)", { [self] in search(root, skipping: others) }))
        }
        for (name, body) in jobs {
            let thread = Thread { [self] in
                body()
                lock.lock()
                finishedThreads += 1
                let isDone = finishedThreads == jobs.count
                let result = progress
                lock.unlock()
                if isDone { DispatchQueue.main.async { self.onFinish?(result) } }
            }
            thread.name = "FileReadBenchmark.\(name)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func stop() {
        lock.lock()
        stopRequested = true
        lock.broadcast()
        lock.unlock()
    }

    func snapshot() -> (sample: EngineSnapshot, progress: Progress) {
        lock.lock()
        defer { lock.unlock() }
        return (EngineSnapshot(perThread: [progress.totalBytes], totalBytes: progress.totalBytes, nanoseconds: countedAt), progress)
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    // MARK: Search

    private func search(_ root: String, skipping others: Set<String>) {
        defer {
            lock.lock()
            activeSearchers -= 1
            if activeSearchers == 0 { progress.isSearching = false }
            lock.broadcast()
            lock.unlock()
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }
        for case let url as URL in walker {
            if shouldStop { return }
            if others.contains(url.path) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, Int64(size) >= settings.minimumFileBytes else { continue }
            // The same data can be reachable twice, through firmlinks or hard links.
            var info = stat()
            guard stat(url.path, &info) == 0 else { continue }
            let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
            let isCompressed = info.st_flags & UInt32(UF_COMPRESSED) != 0
            lock.lock()
            if isCompressed {
                if seen.insert(identity).inserted { progress.skippedCompressed += 1 }
            } else if seen.insert(identity).inserted {
                queue.append((url.path, Int64(size)))
                progress.filesFound += 1
                lock.signal()
            }
            lock.unlock()
        }
    }

    // MARK: Read

    private func nextFile() -> (path: String, size: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        while queue.isEmpty && progress.isSearching && !stopRequested { lock.wait() }
        if stopRequested || queue.isEmpty || progress.totalBytes >= settings.stopAfterBytes { return nil }
        // Largest first: less time lost to opening files, and longer steady reads.
        let index = queue.indices.max { queue[$0].size < queue[$1].size }!
        return queue.remove(at: index)
    }

    private func read() {
        guard let buffer = aligned(settings.requestBytes) else { return }
        defer { free(buffer) }
        while let file = nextFile() {
            readFile(file.path, size: file.size, buffer: buffer)
        }
        // Once reading is over, there's no use for the rest of the search.
        lock.lock()
        progress.currentFile = nil
        stopRequested = true
        lock.broadcast()
        lock.unlock()
    }

    private func readFile(_ path: String, size: Int64, buffer: UnsafeMutableRawPointer) {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            record { $0.skippedUnreadable += 1 }
            return
        }
        defer { close(descriptor) }
        if let resident = Self.residentFraction(descriptor: descriptor, size: size), resident > settings.residentLimit {
            record { $0.skippedCached += 1 }
            return
        }
        _ = fcntl(descriptor, F_NOCACHE, 1)

        let name = (path as NSString).lastPathComponent
        record {
            $0.currentFile = name
            $0.currentFileFraction = 0
        }
        var offset: Int64 = 0
        var fileNanoseconds: UInt64 = 0
        while offset < size, !shouldStop {
            let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let count = pread(descriptor, buffer, settings.requestBytes, off_t(offset))
            let ended = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard count > 0 else { break }
            offset += Int64(count)
            fileNanoseconds += ended - started
            lock.lock()
            progress.totalBytes += UInt64(count)
            progress.readingNanoseconds += ended - started
            progress.currentFileFraction = Double(offset) / Double(size)
            countedAt = ended
            let reachedLimit = progress.totalBytes >= settings.stopAfterBytes
            lock.unlock()
            if reachedLimit { break }
        }
        guard offset > 0 else {
            record { $0.skippedUnreadable += 1 }
            return
        }
        record {
            $0.filesRead += 1
            $0.recent.insert(FileResult(name: name, bytes: UInt64(offset), gigabytesPerSecond: Double(offset) / Double(max(1, fileNanoseconds)), duringSearch: $0.isSearching), at: 0)
            if $0.recent.count > Self.recentLimit { $0.recent.removeLast() }
        }
    }

    private func record(_ change: (inout Progress) -> Void) {
        lock.lock()
        change(&progress)
        lock.unlock()
    }

    private func aligned(_ bytes: Int) -> UnsafeMutableRawPointer? {
        var pointer: UnsafeMutableRawPointer?
        // Page alignment lets uncached reads go straight from the drive into the buffer.
        return posix_memalign(&pointer, Int(getpagesize()), bytes) == 0 ? pointer : nil
    }

    /// How much of a file is already in memory, checked without reading it.
    static func residentFraction(descriptor: Int32, size: Int64) -> Double? {
        guard size > 0, let mapping = mmap(nil, Int(size), PROT_READ, MAP_SHARED, descriptor, 0), mapping != MAP_FAILED else { return nil }
        defer { munmap(mapping, Int(size)) }
        let page = Int(getpagesize())
        let pages = (Int(size) + page - 1) / page
        var residency = [CChar](repeating: 0, count: pages)
        guard mincore(mapping, Int(size), &residency) == 0 else { return nil }
        let resident = residency.reduce(0) { $0 + Int($1 & 1) }
        return Double(resident) / Double(pages)
    }
}
