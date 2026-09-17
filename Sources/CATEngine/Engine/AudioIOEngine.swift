import CoreAudio
import Foundation
import Synchronization

/// Owns the AudioObjectID + IOProcID lifecycle for one device and bridges the realtime
/// IOProc callback to Swift. All heap allocation happens in `start()`, before
/// `AudioDeviceStart` — nothing allocates inside `handleIO`.
public final class AudioIOEngine: @unchecked Sendable {
    public let deviceID: AudioObjectID
    let inputMap: ChannelMap
    let outputMap: ChannelMap
    public var selectedOutputChannels: [Int] = []
    public var selectedInputChannels: [Int] = []
    public weak var outputProvider: OutputSignalProvider?
    public weak var inputSink: InputCaptureSink?

    let ringBuffer: CaptureRingBuffer
    private var ioProcID: AudioDeviceIOProcID?
    private var outputScratch: UnsafeMutablePointer<Float>
    private var inputScratch: UnsafeMutablePointer<Float>
    private let maxFramesPerCallback: Int

    private var drainThread: Thread?
    private let drainShouldStop = Atomic<Bool>(false)
    private let drainRunning = Atomic<Bool>(false)

    private let overloadCounter = Atomic<Int>(0)
    private let ioStoppedCounter = Atomic<Int>(0)
    private let deviceAliveFlag = Atomic<Bool>(true)
    private var overloadMonitor: OverloadMonitor?

    public var overloadCount: Int { overloadCounter.load(ordering: .relaxed) }
    public var ioStoppedAbnormallyCount: Int { ioStoppedCounter.load(ordering: .relaxed) }
    public var isDeviceAlive: Bool { deviceAliveFlag.load(ordering: .relaxed) }

    func recordOverload() { overloadCounter.wrappingAdd(1, ordering: .relaxed) }
    func recordIOStoppedAbnormally() { ioStoppedCounter.wrappingAdd(1, ordering: .relaxed) }

    /// Only safe to call while stopped, between phases sharing this engine instance.
    public func resetCountersForNewPhase() {
        overloadCounter.store(0, ordering: .relaxed)
        ioStoppedCounter.store(0, ordering: .relaxed)
        ringBuffer.resetForNewPhase()
    }
    func checkStillAlive() {
        let alive = (try? AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self)) ?? 1
        if alive == 0 {
            deviceAliveFlag.store(false, ordering: .relaxed)
        }
    }

    public init(deviceID: AudioObjectID, maxFramesPerCallback: Int) throws {
        self.deviceID = deviceID
        self.inputMap = try ChannelMap(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
        self.outputMap = try ChannelMap(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
        self.maxFramesPerCallback = maxFramesPerCallback
        self.outputScratch = .allocate(capacity: maxFramesPerCallback)
        self.inputScratch = .allocate(capacity: maxFramesPerCallback)
        self.ringBuffer = CaptureRingBuffer(slotCount: 4096, maxFramesPerSlot: maxFramesPerCallback)
    }

    deinit {
        outputScratch.deallocate()
        inputScratch.deallocate()
    }

    public func start() throws {
        let monitor = OverloadMonitor(deviceID: deviceID, engine: self)
        try monitor.install()
        overloadMonitor = monitor

        let clientData = Unmanaged.passRetained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        try caCheck(
            AudioDeviceCreateIOProcID(deviceID, audioIOProcTrampoline, clientData, &procID),
            "AudioDeviceCreateIOProcID"
        )
        self.ioProcID = procID
        try caCheck(AudioDeviceStart(deviceID, procID), "AudioDeviceStart")

        drainShouldStop.store(false, ordering: .relaxed)
        let thread = Thread { [weak self] in self?.drainLoop() }
        thread.name = "core-audio-tester.drain"
        thread.qualityOfService = .userInitiated
        thread.start()
        drainThread = thread
    }

    public func stop() {
        if let procID = ioProcID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            ioProcID = nil
            Unmanaged.passUnretained(self).release()
        }
        overloadMonitor?.uninstall()
        overloadMonitor = nil
        drainShouldStop.store(true, ordering: .relaxed)
        drainThread?.cancel()
        // Wait for the drain thread to actually observe drainShouldStop and exit before
        // returning: the caller immediately calls resetForNewPhase() and start() again on this
        // SAME engine/ring-buffer instance for the next phase, and the ring buffer is documented
        // single-producer/single-consumer — a straggling old drain thread still mid-loop when the
        // new phase's fresh drain thread starts would make it a second, uncoordinated consumer.
        // Bounded so a wedged thread can't hang the sweep indefinitely.
        let deadline = Date().addingTimeInterval(0.5)
        while drainRunning.load(ordering: .relaxed) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.0005)
        }
        drainThread = nil
    }

    private func drainLoop() {
        drainRunning.store(true, ordering: .relaxed)
        defer { drainRunning.store(false, ordering: .relaxed) }
        while !drainShouldStop.load(ordering: .relaxed) {
            var drainedAny = false
            for _ in 0..<256 {
                let did = ringBuffer.consume { header, samples in
                    self.inputSink?.consume(channel: Int(header.channel), samples: samples, sampleTime: header.sampleTime, hostTime: header.hostTime)
                }
                if !did { break }
                drainedAny = true
            }
            if !drainedAny {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    /// Called from the trampoline. Realtime thread — no allocation, no locking, no throwing work.
    func handleIO(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        outputTime: UnsafePointer<AudioTimeStamp>
    ) {
        do {
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in abl {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            if let provider = outputProvider {
                let sampleTime = Int64(outputTime.pointee.mSampleTime)
                for channel in selectedOutputChannels {
                    guard let loc = try? outputMap.location(forDeviceChannel: channel) else { continue }
                    let buf = abl[loc.bufferIndex]
                    guard let base = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / max(loc.channelsInBuffer, 1)
                    guard frames > 0 else { continue }
                    if loc.channelsInBuffer == 1 {
                        provider.renderOutput(channel: channel, buffer: UnsafeMutableBufferPointer(start: base, count: frames), absoluteSampleTime: sampleTime)
                    } else {
                        let scratchBuf = UnsafeMutableBufferPointer(start: outputScratch, count: min(frames, maxFramesPerCallback))
                        provider.renderOutput(channel: channel, buffer: scratchBuf, absoluteSampleTime: sampleTime)
                        for i in 0..<scratchBuf.count {
                            base[i * loc.channelsInBuffer + loc.channelOffsetWithinBuffer] = outputScratch[i]
                        }
                    }
                }
            }
        }

        do {
            let sampleTime = Int64(inputTime.pointee.mSampleTime)
            let hostTime = inputTime.pointee.mHostTime
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            for channel in selectedInputChannels {
                guard let loc = try? inputMap.location(forDeviceChannel: channel) else { continue }
                let buf = abl[loc.bufferIndex]
                guard let base = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / max(loc.channelsInBuffer, 1)
                guard frames > 0 else { continue }
                let clamped = min(frames, maxFramesPerCallback)
                if loc.channelsInBuffer == 1 {
                    ringBuffer.produce(channel: Int32(channel), sampleTime: sampleTime, hostTime: hostTime, source: base, frameCount: clamped)
                } else {
                    for i in 0..<clamped {
                        inputScratch[i] = base[i * loc.channelsInBuffer + loc.channelOffsetWithinBuffer]
                    }
                    ringBuffer.produce(channel: Int32(channel), sampleTime: sampleTime, hostTime: hostTime, source: inputScratch, frameCount: clamped)
                }
            }
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
