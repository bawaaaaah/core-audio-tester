import Testing
@testable import CATAnalysis
@testable import CATEngine

@Suite struct PingTestSessionTests {
    let sampleRate = 48000.0

    private func run(_ simulator: LoopbackSimulator, plan: TestPlan, lostCaptureCycles: Set<Int> = []) -> [PairLatencyResult] {
        let session = PingTestSession(plan: plan, grantedBufferFrames: UInt32(simulator.bufferFrames), sampleRate: sampleRate)
        let cycles = Int(session.estimatedDuration * sampleRate) / simulator.bufferFrames + 4
        simulator.run(provider: session, sink: session, cycles: cycles, lostCaptureCycles: lostCaptureCycles)
        #expect(session.receivedAnyInputSignal)
        return session.finalize()
    }

    /// Also the regression test for the MLS tap bug: with the old taps every clean repetition
    /// scored a secondary-peak ratio of ~1.03 and was counted as ambiguous.
    @Test func parallelPingMeasuresTheRoundTripWithoutAmbiguity() {
        let pairs = [ChannelPair(outputChannel: 1, inputChannel: 1), ChannelPair(outputChannel: 2, inputChannel: 2)]
        let simulator = LoopbackSimulator(pairs: pairs, bufferFrames: 64, ioOffset: 192, physicalDelay: 100)
        let results = run(simulator, plan: LoopbackSimulator.plan(pairs: pairs, pingRepetitions: 4))
        let expectedMs = Double(simulator.roundTripFrames) / sampleRate * 1000
        #expect(results.count == 2)
        for result in results {
            #expect(result.repetitionsDetected == 4)
            #expect(result.ambiguousCount == 0)
            #expect(!result.isUnreliable)
            #expect(abs(result.meanMs - expectedMs) < 0.02)
            #expect(result.stddevMs < 0.01)
        }
    }

    @Test func sequentialCrossPatchedPing() {
        let pairs = [ChannelPair(outputChannel: 1, inputChannel: 2), ChannelPair(outputChannel: 2, inputChannel: 1)]
        let simulator = LoopbackSimulator(pairs: pairs, bufferFrames: 128, ioOffset: 300, physicalDelay: 40)
        let results = run(simulator, plan: LoopbackSimulator.plan(pairs: pairs, pingRepetitions: 2, pingMode: .sequential))
        let expectedMs = Double(simulator.roundTripFrames) / sampleRate * 1000
        for result in results {
            #expect(result.repetitionsDetected == 2)
            #expect(abs(result.meanMs - expectedMs) < 0.02)
        }
    }

    /// Regression: capture was indexed by the count of samples received, so every record the ring
    /// buffer dropped shifted all later bursts and shortened the measured latency.
    @Test func droppedCaptureRecordsDoNotShiftLaterBursts() {
        let pairs = [ChannelPair(outputChannel: 1, inputChannel: 1)]
        let simulator = LoopbackSimulator(pairs: pairs, bufferFrames: 64, ioOffset: 192, physicalDelay: 100)
        // Cycles 30-33 fall in the gap after the first burst.
        let results = run(simulator, plan: LoopbackSimulator.plan(pairs: pairs, pingRepetitions: 4), lostCaptureCycles: [30, 31, 32, 33])
        let expectedMs = Double(simulator.roundTripFrames) / sampleRate * 1000
        #expect(results[0].repetitionsDetected == 4)
        #expect(abs(results[0].minMs - expectedMs) < 0.02)
        #expect(abs(results[0].maxMs - expectedMs) < 0.02)
    }

    @Test func invertedPolarityLoopbackStillMeasures() {
        let pairs = [ChannelPair(outputChannel: 1, inputChannel: 1)]
        var simulator = LoopbackSimulator(pairs: pairs, bufferFrames: 64, ioOffset: 192, physicalDelay: 100)
        simulator.gain = -0.5
        let results = run(simulator, plan: LoopbackSimulator.plan(pairs: pairs, pingRepetitions: 3))
        #expect(results[0].repetitionsDetected == 3)
    }
}
