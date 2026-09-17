/// Implemented by CATAnalysis. Called directly on the realtime IOProc thread for every output
/// channel present in the current callback — must not allocate, lock, or throw.
public protocol OutputSignalProvider: AnyObject {
    func renderOutput(channel: Int, buffer: UnsafeMutableBufferPointer<Float>, absoluteSampleTime: Int64)
}

/// Implemented by CATAnalysis. Called on the non-realtime drain thread that consumes the ring buffer.
public protocol InputCaptureSink: AnyObject {
    func consume(channel: Int, samples: UnsafeBufferPointer<Float>, sampleTime: Int64, hostTime: UInt64)
}
