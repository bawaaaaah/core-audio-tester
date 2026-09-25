/// Implemented by CATAnalysis. Called directly on the realtime IOProc thread — must not allocate,
/// lock, or throw.
public protocol OutputSignalProvider: AnyObject {
    /// Called once at the start of every IO cycle, before any `renderOutput` for that cycle. Both
    /// times are device sample times of the same cycle, so a provider can pair its output timeline
    /// with the input one (their difference is the cycle's fixed input-to-output offset).
    func beginIOCycle(inputSampleTime: Int64, outputSampleTime: Int64)

    /// Fills `buffer` for one selected output channel. `buffer` is zero-filled before the call, so
    /// samples with nothing to play can be left untouched. `absoluteSampleTime` is the device
    /// sample time of `buffer[0]`.
    func renderOutput(channel: Int, buffer: UnsafeMutableBufferPointer<Float>, absoluteSampleTime: Int64)
}

public extension OutputSignalProvider {
    func beginIOCycle(inputSampleTime: Int64, outputSampleTime: Int64) {}
}

/// One channel's input from one IO callback, as handed to an `InputCaptureSink`.
public struct CapturedChunk {
    public let channel: Int
    /// Only valid for the duration of the `consume` call.
    public let samples: UnsafeBufferPointer<Float>
    /// Device sample time of `samples[0]`.
    public let sampleTime: Int64
    public let hostTime: UInt64
    /// Frames of this channel dropped by the capture ring buffer (the drain thread fell behind)
    /// immediately before this chunk. Any further jump in `sampleTime` is a gap in what the
    /// device itself delivered.
    public let framesLostBefore: Int

    public init(channel: Int, samples: UnsafeBufferPointer<Float>, sampleTime: Int64, hostTime: UInt64, framesLostBefore: Int) {
        self.channel = channel
        self.samples = samples
        self.sampleTime = sampleTime
        self.hostTime = hostTime
        self.framesLostBefore = framesLostBefore
    }
}

/// Implemented by CATAnalysis. Called on the non-realtime drain thread that empties the ring buffer.
public protocol InputCaptureSink: AnyObject {
    func consume(_ chunk: CapturedChunk)
}
