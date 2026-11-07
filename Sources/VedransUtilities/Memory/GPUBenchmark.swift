import Foundation
import Metal

/// Metal compute versions of the memory operations.
///
/// Each invocation handles one 256-byte chunk (one 128-byte line for random), and
/// chunks wrap around the block, so a dispatch can be larger or smaller than it.
/// Loads feed a comparison that can write to `sink`. The sentinel never matches in
/// practice, but the shader compiler can't know that, so it can't remove the loads.
final class GPUKernels {
    struct Parameters {
        var start: UInt32 = 0
        var chunkMask: UInt32 = 0
        var lineMask: UInt32 = 0
        var seed: UInt32 = 0
        var sentinel: UInt32 = GPUKernels.neverMatches
        var pattern: UInt32 = 0xA5A5_A5A5
    }

    static let neverMatches: UInt32 = 0x1234_5678
    static let chunkBytes: UInt64 = 256
    static let lineBytes: UInt64 = 128
    static let shared = GPUKernels()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipelines: [MemoryOperation: MTLComputePipelineState]

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil) else { return nil }
        var pipelines: [MemoryOperation: MTLComputePipelineState] = [:]
        for operation in MemoryOperation.allCases {
            guard let function = library.makeFunction(name: "mem_\(operation.name.lowercased())"),
                  let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
            pipelines[operation] = pipeline
        }
        self.device = device
        self.queue = queue
        self.pipelines = pipelines
    }

    /// Bytes one invocation counts as work, before the operation's read/write multiplier.
    static func invocationBytes(_ operation: MemoryOperation) -> UInt64 {
        operation == .random ? lineBytes : chunkBytes
    }

    /// Bytes crossing the memory interface per byte of block processed, as on the CPU.
    static func multiplier(_ operation: MemoryOperation) -> UInt64 {
        switch operation {
        case .copy: 2
        case .triad: 3
        default: 1
        }
    }

    func encode(
        _ operation: MemoryOperation,
        buffers: [MTLBuffer],
        sink: MTLBuffer,
        blockBytes: UInt64,
        invocations: Int,
        start: UInt32,
        seed: UInt32,
        sentinel: UInt32 = GPUKernels.neverMatches,
        into commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder(), let pipeline = pipelines[operation] else { return }
        var parameters = Parameters(
            start: start,
            chunkMask: UInt32(blockBytes / Self.chunkBytes - 1),
            lineMask: UInt32(blockBytes / Self.lineBytes - 1),
            seed: seed,
            sentinel: sentinel
        )
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
        encoder.setBuffer(sink, offset: 0, index: 3)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 4)
        encoder.dispatchThreads(
            MTLSize(width: invocations, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
        )
        encoder.endEncoding()
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters {
        uint start, chunkMask, lineMask, seed, sentinel, pattern;
    };

    static inline uint chunkBase(uint i, constant Parameters &p) {
        return ((p.start + i) & p.chunkMask) * 16; // In 16-byte vectors.
    }

    kernel void mem_read(device const uint4 *a [[buffer(0)]], device uint *sink [[buffer(3)]],
                         constant Parameters &p [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        uint base = chunkBase(i, p);
        uint4 x = 0;
        for (uint j = 0; j < 16; j++) x ^= a[base + j];
        if (x.x == p.sentinel) sink[0] = 1;
    }

    kernel void mem_write(device uint4 *a [[buffer(0)]],
                          constant Parameters &p [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        uint base = chunkBase(i, p);
        for (uint j = 0; j < 16; j++) a[base + j] = uint4(p.pattern);
    }

    kernel void mem_copy(device const uint4 *a [[buffer(0)]], device uint4 *b [[buffer(1)]],
                         constant Parameters &p [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        uint base = chunkBase(i, p);
        for (uint j = 0; j < 16; j++) b[base + j] = a[base + j];
    }

    kernel void mem_triad(device float4 *a [[buffer(0)]], device const float4 *b [[buffer(1)]],
                          device const float4 *c [[buffer(2)]],
                          constant Parameters &p [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        uint base = chunkBase(i, p);
        for (uint j = 0; j < 16; j++) a[base + j] = b[base + j] + 3.0f * c[base + j];
    }

    kernel void mem_random(device const uint *a [[buffer(0)]], device uint *sink [[buffer(3)]],
                           constant Parameters &p [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        uint h = (i + p.seed) * 2654435761u;
        h ^= h >> 15;
        h *= 2246822519u;
        h ^= h >> 13;
        uint value = a[(h & p.lineMask) * 32]; // A line is 32 words.
        if (value == p.sentinel) sink[0] = 1;
    }
    """
}

/// Runs one operation on the GPU continuously, from a dedicated submitting thread.
final class GPUBenchmarkEngine: BandwidthEngine {
    let config: BenchmarkConfig

    /// Each command buffer aims for this duration, so the meter updates smoothly at
    /// any speed without a single submission hogging the GPU.
    private static let targetCommandSeconds = 0.016
    private static let minimumDispatchBytes: UInt64 = 1 << 20
    private static let maximumDispatchBytes: UInt64 = 16 << 30

    private let lock = NSLock()
    private var totalBytes: UInt64 = 0
    /// When `totalBytes` last changed. Bytes only land as a command buffer completes,
    /// so rates must divide by this rather than the time of sampling. Otherwise each
    /// sample catches a varying number of completions and the reading swings wildly.
    private var countedAt: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    private var stopRequested = false
    private var isStopped = false
    private var didPrepare = false
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    init?(config: BenchmarkConfig) {
        guard config.processor == .gpu, let kernels = GPUKernels.shared else { return nil }
        self.config = config
        let thread = Thread { [self] in
            run(kernels)
            finished.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func waitUntilReady() -> Bool {
        ready.wait()
        ready.signal() // Stays ready for any later caller.
        lock.lock()
        defer { lock.unlock() }
        return didPrepare
    }

    func snapshot() -> EngineSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return nil }
        return EngineSnapshot(perThread: [totalBytes], totalBytes: totalBytes, nanoseconds: countedAt)
    }

    func stop() {
        lock.lock()
        let alreadyStopped = isStopped
        stopRequested = true
        isStopped = true
        lock.unlock()
        if !alreadyStopped { finished.wait() }
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    /// Private storage is what a real GPU workload would use, and a blit fill faults
    /// the pages in with non-zero data, the same as the CPU side's preparation.
    private func prepareBuffers(_ kernels: GPUKernels) -> (buffers: [MTLBuffer], sink: MTLBuffer)? {
        let device = kernels.device
        guard config.blockBytes <= UInt64(device.maxBufferLength),
              let sink = device.makeBuffer(length: 256, options: .storageModeShared),
              let commandBuffer = kernels.queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        var buffers: [MTLBuffer] = []
        for _ in 0..<config.operation.bufferCount {
            guard let buffer = device.makeBuffer(length: Int(config.blockBytes), options: .storageModePrivate) else {
                blit.endEncoding()
                return nil
            }
            // 0x3F bytes read as a small finite float, which keeps Triad clear of denormals.
            blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0x3F)
            buffers.append(buffer)
        }
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? (buffers, sink) : nil
    }

    private func run(_ kernels: GPUKernels) {
        let prepared = prepareBuffers(kernels)
        lock.lock()
        didPrepare = prepared != nil
        lock.unlock()
        ready.signal()
        guard let prepared else { return }

        let operation = config.operation
        let unit = GPUKernels.invocationBytes(operation)
        let multiplier = GPUKernels.multiplier(operation)
        var dispatchBytes = max(Self.minimumDispatchBytes, min(config.blockBytes, 64 << 20))
        var position: UInt64 = 0
        var seed: UInt32 = 1

        while !shouldStop {
            let succeeded: Bool = autoreleasepool {
                guard let commandBuffer = kernels.queue.makeCommandBuffer() else { return false }
                let invocations = Int(dispatchBytes / unit)
                kernels.encode(
                    operation,
                    buffers: prepared.buffers,
                    sink: prepared.sink,
                    blockBytes: config.blockBytes,
                    invocations: invocations,
                    start: UInt32(truncatingIfNeeded: position),
                    seed: seed,
                    into: commandBuffer
                )
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                guard commandBuffer.status == .completed else { return false }

                position &+= UInt64(invocations)
                seed &+= UInt32(truncatingIfNeeded: invocations)
                lock.lock()
                totalBytes += dispatchBytes * multiplier
                countedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                lock.unlock()

                let elapsed = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
                if elapsed > 0 {
                    let factor = min(2, max(0.5, Self.targetCommandSeconds / elapsed))
                    let wanted = UInt64(Double(dispatchBytes) * factor)
                    dispatchBytes = max(Self.minimumDispatchBytes, min(Self.maximumDispatchBytes, wanted / unit * unit))
                }
                return true
            }
            if !succeeded { break }
        }
    }
}
