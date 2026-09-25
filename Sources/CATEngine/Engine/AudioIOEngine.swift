import CoreAudio
import Foundation
import Synchronization

/// Owns the IOProc lifecycle for one device and bridges the realtime callback to Swift.
///
/// Everything the callback touches is prepared in `start()`: selected channels are resolved to
/// buffer locations up front, the provider/sink are captured strongly, and all buffers are
/// preallocated — `handleIO` never allocates, locks, looks anything up in a dictionary or throws.
public final class AudioIOEngine: @unchecked Sendable {
    public let deviceID: AudioObjectID
    let inputMap: ChannelMap
    let outputMap: ChannelMap
    /// Set before `start()`.
    public var selectedOutputChannels: [Int] = []
    /// Set before `start()`.
    public var selectedInputChannels: [Int] = []
    /// Set before `start()`; captured for the duration of the run.
    public weak var outputProvider: OutputSignalProvider?
    /// Set before `start()`; captured for the duration of the run.
    public weak var inputSink: InputCaptureSink?
    /// Fraction (0 to 0.95) of each IO cycle's period to busy-wait inside the IOProc, emulating
    /// the DSP load of a real audio application's callback. Set before `start()`.
    public var ioLoadFraction: Double = 0

    let ringBuffer: CaptureRingBuffer
    private let sampleRate: Double
    private let maxFramesPerCallback: Int
    private var ioProcID: AudioDeviceIOProcID?
    private let outputScratch: UnsafeMutablePointer<Float>
    private let inputScratch: UnsafeMutablePointer<Float>

    private struct ResolvedChannel {
        let channel: Int
        let location: ChannelLocation
    }

    // Realtime snapshot: written in start() before AudioDeviceStart, cleared in stop() after
    // AudioDeviceStop, read only by the IOProc in between.
    private var rtOutputs = UnsafeMutableBufferPointer<ResolvedChannel>(start: nil, count: 0)
    private var rtInputs = UnsafeMutableBufferPointer<ResolvedChannel>(start: nil, count: 0)
    private var rtProvider: OutputSignalProvider?
    private var rtLoadTicksPerFrame: Double = 0

    private var drainThread: Thread?
    private var drainExited: DispatchSemaphore?
    private let drainShouldStop = Atomic<Bool>(false)

    private let overloadCounter = Atomic<Int>(0)
    private let ioStoppedCounter = Atomic<Int>(0)
    private let sampleRateChangeCounter = Atomic<Int>(0)
    private let deviceAliveFlag = Atomic<Bool>(true)
    private var overloadMonitor: OverloadMonitor?

    public var overloadCount: Int { overloadCounter.load(ordering: .relaxed) }
    public var ioStoppedAbnormallyCount: Int { ioStoppedCounter.load(ordering: .relaxed) }
    public var sampleRateChangeCount: Int { sampleRateChangeCounter.load(ordering: .relaxed) }
    public var isDeviceAlive: Bool { deviceAliveFlag.load(ordering: .relaxed) }
    /// Capture records the ring buffer had to drop during the current phase.
    public var droppedCaptureRecords: Int { ringBuffer.droppedRecords }

    func recordOverload() { overloadCounter.wrappingAdd(1, ordering: .relaxed) }
    func recordIOStoppedAbnormally() { ioStoppedCounter.wrappingAdd(1, ordering: .relaxed) }
    func recordSampleRateChange() { sampleRateChangeCounter.wrappingAdd(1, ordering: .relaxed) }
    func checkStillAlive() {
        let alive = (try? AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self)) ?? 1
        if alive == 0 {
            deviceAliveFlag.store(false, ordering: .relaxed)
        }
    }

    /// Only safe to call while stopped, between phases sharing this engine instance.
    public func resetCountersForNewPhase() {
        overloadCounter.store(0, ordering: .relaxed)
        ioStoppedCounter.store(0, ordering: .relaxed)
        sampleRateChangeCounter.store(0, ordering: .relaxed)
        ringBuffer.resetForNewPhase()
    }

    /// `bufferFrames` is the granted IO buffer size; `inputChannelCount` sizes the capture ring so
    /// it holds roughly two seconds of audio for every selected input.
    public init(deviceID: AudioObjectID, bufferFrames: Int, sampleRate: Double, inputChannelCount: Int) throws {
        self.deviceID = deviceID
        self.inputMap = try ChannelMap(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
        self.outputMap = try ChannelMap(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
        self.sampleRate = sampleRate
        // Some drivers deliver more frames than the nominal buffer size on some cycles; anything
        // beyond this is truncated and reported as lost capture rather than silently dropped.
        self.maxFramesPerCallback = max(bufferFrames * 2, 64)
        self.outputScratch = .allocate(capacity: maxFramesPerCallback)
        self.outputScratch.initialize(repeating: 0, count: maxFramesPerCallback)
        self.inputScratch = .allocate(capacity: maxFramesPerCallback)
        self.inputScratch.initialize(repeating: 0, count: maxFramesPerCallback)
        let cyclesPerTwoSeconds = Int(2.0 * sampleRate / Double(max(bufferFrames, 1)))
        let slotCount = min(max(cyclesPerTwoSeconds * max(inputChannelCount, 1), 4096), 65536)
        self.ringBuffer = CaptureRingBuffer(
            slotCount: slotCount,
            maxFramesPerSlot: maxFramesPerCallback,
            channelCapacity: inputMap.highestChannel + 1
        )
    }

    deinit {
        stop()
        outputScratch.deallocate()
        inputScratch.deallocate()
        releaseRealtimeChannels()
    }

    public func start() throws {
        precondition(ioProcID == nil, "AudioIOEngine.start() called while already running")
        let outputs = try selectedOutputChannels.map { ResolvedChannel(channel: $0, location: try outputMap.location(forDeviceChannel: $0)) }
        let inputs = try selectedInputChannels.map { ResolvedChannel(channel: $0, location: try inputMap.location(forDeviceChannel: $0)) }
        releaseRealtimeChannels()
        rtOutputs = .allocate(capacity: outputs.count)
        _ = rtOutputs.initialize(from: outputs)
        rtInputs = .allocate(capacity: inputs.count)
        _ = rtInputs.initialize(from: inputs)
        rtProvider = outputProvider
        rtLoadTicksPerFrame = Self.loadTicksPerFrame(fraction: ioLoadFraction, sampleRate: sampleRate)

        let monitor = OverloadMonitor(deviceID: deviceID, engine: self)
        try monitor.install()
        overloadMonitor = monitor

        let clientData = Unmanaged.passRetained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(deviceID, audioIOProcTrampoline, clientData, &procID)
        guard createStatus == noErr, let procID else {
            Unmanaged<AudioIOEngine>.fromOpaque(clientData).release()
            stop()
            throw CoreAudioError.osStatus(createStatus == noErr ? kAudioHardwareUnspecifiedError : createStatus, "AudioDeviceCreateIOProcID")
        }
        ioProcID = procID
        startDrainThread(sink: inputSink)

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            stop()
            throw CoreAudioError.osStatus(startStatus, "AudioDeviceStart")
        }
    }

    /// Stops IO, then waits for the drain thread to hand every captured record to the sink before
    /// returning — callers read the sink's results right after this.
    public func stop() {
        if let procID = ioProcID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            ioProcID = nil
            Unmanaged.passUnretained(self).release()
        }
        overloadMonitor?.uninstall()
        overloadMonitor = nil
        stopDrainThread()
        rtProvider = nil
    }

    private func releaseRealtimeChannels() {
        rtOutputs.deallocate()
        rtOutputs = UnsafeMutableBufferPointer(start: nil, count: 0)
        rtInputs.deallocate()
        rtInputs = UnsafeMutableBufferPointer(start: nil, count: 0)
    }

    private static func loadTicksPerFrame(fraction: Double, sampleRate: Double) -> Double {
        let clamped = min(max(fraction, 0), 0.95)
        guard clamped > 0, sampleRate > 0 else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.numer > 0 else { return 0 }
        let nanosecondsPerFrame = 1e9 / sampleRate
        return nanosecondsPerFrame * clamped * Double(timebase.denom) / Double(timebase.numer)
    }

    // MARK: Drain thread

    private func startDrainThread(sink: InputCaptureSink?) {
        drainShouldStop.store(false, ordering: .relaxed)
        let exited = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            drainLoop(sink: sink)
            exited.signal()
        }
        thread.name = "core-audio-tester.drain"
        thread.qualityOfService = .userInitiated
        drainExited = exited
        drainThread = thread
        thread.start()
    }

    private func stopDrainThread() {
        guard let exited = drainExited else { return }
        drainShouldStop.store(true, ordering: .releasing)
        if exited.wait(timeout: .now() + 30) == .timedOut {
            Log.warn("le thread de capture ne s'est pas arrêté à temps ; les résultats de cette phase peuvent être incomplets.")
        }
        drainExited = nil
        drainThread = nil
    }

    private func drainLoop(sink: InputCaptureSink?) {
        while !drainShouldStop.load(ordering: .acquiring) {
            if drainAvailable(sink: sink, limit: 256) == 0 {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        // IO is already stopped when the stop flag is raised, so what's left in the ring is final.
        while drainAvailable(sink: sink, limit: 4096) > 0 {}
    }

    private func drainAvailable(sink: InputCaptureSink?, limit: Int) -> Int {
        var count = 0
        while count < limit {
            let consumed = ringBuffer.consume { header, samples in
                sink?.consume(CapturedChunk(
                    channel: Int(header.channel),
                    samples: samples,
                    sampleTime: header.sampleTime,
                    hostTime: header.hostTime,
                    framesLostBefore: Int(header.framesLostBefore)
                ))
            }
            if !consumed { break }
            count += 1
        }
        return count
    }

    // MARK: Realtime callback

    /// Called from the trampoline on the realtime IO thread.
    func handleIO(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        outputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let cycleStartTicks = rtLoadTicksPerFrame > 0 ? mach_absolute_time() : 0
        var cycleFrames = 0
        let inputSampleTime = Int64(inputTime.pointee.mSampleTime)
        let outputSampleTime = Int64(outputTime.pointee.mSampleTime)
        let provider = rtProvider
        provider?.beginIOCycle(inputSampleTime: inputSampleTime, outputSampleTime: outputSampleTime)

        let outputList = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in outputList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        for resolved in rtOutputs {
            let location = resolved.location
            guard location.bufferIndex < outputList.count else { continue }
            let buffer = outputList[location.bufferIndex]
            guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = max(location.channelsInBuffer, 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / stride
            guard frames > 0 else { continue }
            cycleFrames = max(cycleFrames, frames)
            guard let provider else { continue }
            if stride == 1 {
                provider.renderOutput(channel: resolved.channel, buffer: UnsafeMutableBufferPointer(start: base, count: frames), absoluteSampleTime: outputSampleTime)
            } else {
                let count = min(frames, maxFramesPerCallback)
                outputScratch.update(repeating: 0, count: count)
                provider.renderOutput(channel: resolved.channel, buffer: UnsafeMutableBufferPointer(start: outputScratch, count: count), absoluteSampleTime: outputSampleTime)
                for i in 0..<count {
                    base[i * stride + location.channelOffsetWithinBuffer] = outputScratch[i]
                }
            }
        }

        let hostTime = inputTime.pointee.mHostTime
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        for resolved in rtInputs {
            let location = resolved.location
            guard location.bufferIndex < inputList.count else { continue }
            let buffer = inputList[location.bufferIndex]
            guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = max(location.channelsInBuffer, 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / stride
            guard frames > 0 else { continue }
            cycleFrames = max(cycleFrames, frames)
            if stride == 1 {
                ringBuffer.produce(channel: Int32(resolved.channel), sampleTime: inputSampleTime, hostTime: hostTime, source: base, frameCount: frames)
            } else {
                let count = min(frames, maxFramesPerCallback)
                for i in 0..<count {
                    inputScratch[i] = base[i * stride + location.channelOffsetWithinBuffer]
                }
                ringBuffer.produce(channel: Int32(resolved.channel), sampleTime: inputSampleTime, hostTime: hostTime, source: inputScratch, frameCount: frames)
            }
        }

        if rtLoadTicksPerFrame > 0 && cycleFrames > 0 {
            let budget = UInt64(Double(cycleFrames) * rtLoadTicksPerFrame)
            while mach_absolute_time() &- cycleStartTicks < budget {}
        }
    }
}

/// Top-level C function pointer required by AudioDeviceCreateIOProcID — no captures allowed.
func audioIOProcTrampoline(
    _ inDevice: AudioObjectID,
    _ inNow: UnsafePointer<AudioTimeStamp>,
    _ inInputData: UnsafePointer<AudioBufferList>,
    _ inInputTime: UnsafePointer<AudioTimeStamp>,
    _ outOutputData: UnsafeMutablePointer<AudioBufferList>,
    _ inOutputTime: UnsafePointer<AudioTimeStamp>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return noErr }
    let engine = Unmanaged<AudioIOEngine>.fromOpaque(inClientData).takeUnretainedValue()
    engine.handleIO(inputData: inInputData, inputTime: inInputTime, outputData: outOutputData, outputTime: inOutputTime)
    return noErr
}
