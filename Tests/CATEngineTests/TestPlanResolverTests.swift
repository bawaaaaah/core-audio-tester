import Foundation
import Testing
@testable import CATEngine

@Suite struct TestPlanResolverTests {
    private func device(inputs: Int = 8, outputs: Int = 8, range: ClosedRange<UInt32> = 16...4096) -> DeviceInfo {
        DeviceInfo(
            audioObjectID: 0, uid: "test-uid", name: "Test", inputChannelCount: inputs, outputChannelCount: outputs,
            nominalSampleRate: 48000, bufferFrameSizeRange: range, transportType: "USB"
        )
    }

    private func resolve(_ args: [String], config: TestConfigFile? = nil, device: DeviceInfo? = nil, warnings: inout [String]) throws -> TestPlan {
        var collected: [String] = []
        defer { warnings = collected }
        return try TestPlanResolver.resolve(cli: try ArgumentParser.parse(args), config: config, device: device ?? self.device()) { collected.append($0) }
    }

    private func resolve(_ args: [String], config: TestConfigFile? = nil, device: DeviceInfo? = nil) throws -> TestPlan {
        var ignored: [String] = []
        return try resolve(args, config: config, device: device, warnings: &ignored)
    }

    @Test func defaultsToFullDeviceAuto() throws {
        let plan = try resolve([], device: device(inputs: 4, outputs: 6))
        #expect(plan.isAutoMode)
        #expect(plan.pairs.count == 4)
        #expect(plan.outputLevelDBFS == TestPlan.defaultOutputLevelDBFS)
        #expect(plan.ioLoadPercent == 0)
        #expect(plan.stabilitySignalKind == .tone)
    }

    /// Regression: config `pairs` used to win over `--in`/`--out` given on the command line.
    @Test func commandLineChannelsOverrideConfigPairs() throws {
        var config = TestConfigFile()
        config.pairs = [ConfigPairSpec(output: 7, input: 7)]
        let plan = try resolve(["--in", "1-2", "--out", "3-4"], config: config)
        #expect(plan.pairs == [ChannelPair(outputChannel: 3, inputChannel: 1), ChannelPair(outputChannel: 4, inputChannel: 2)])
        #expect(!plan.isAutoMode)
    }

    @Test func configPairsApplyWithoutCommandLineSelection() throws {
        var config = TestConfigFile()
        config.pairs = [ConfigPairSpec(output: 5, input: 3)]
        let plan = try resolve([], config: config)
        #expect(plan.pairs == [ChannelPair(outputChannel: 5, inputChannel: 3)])
    }

    @Test func autoFlagWinsOverConfigSelection() throws {
        var config = TestConfigFile()
        config.pairs = [ConfigPairSpec(output: 5, input: 3)]
        let plan = try resolve(["--auto"], config: config, device: device(inputs: 2, outputs: 2))
        #expect(plan.isAutoMode && plan.pairs.count == 2)
    }

    @Test func mismatchedChannelCountsAreRejected() {
        #expect(throws: TestPlanResolverError.self) { try resolve(["--in", "1-3", "--out", "1-2"]) }
    }

    @Test func anInputCanOnlyBelongToOnePair() {
        #expect(throws: TestPlanResolverError.self) { try resolve(["--pairs", "1:1,2:1"]) }
    }

    @Test func outOfRangeChannelsAreRejected() {
        #expect(throws: TestPlanResolverError.self) { try resolve(["--pairs", "9:1"]) }
    }

    /// Regression: an unknown signal name silently fell back to the sine.
    @Test func unknownStabilitySignalIsRejected() {
        #expect(throws: TestPlanResolverError.self) { try resolve(["--stability-signal", "pnik"]) }
        var config = TestConfigFile()
        config.stabilitySignal = "blue"
        #expect(throws: TestPlanResolverError.self) { try resolve([], config: config) }
    }

    @Test func unknownConfigPingModeIsRejected() {
        var config = TestConfigFile()
        config.pingMode = "diagonal"
        #expect(throws: TestPlanResolverError.self) { try resolve([], config: config) }
    }

    /// Regression: a zero or negative duration was accepted and produced an instant "clean" pass.
    @Test func durationMustBePositive() {
        #expect(throws: TestPlanResolverError.self) { try resolve(["--duration", "0"]) }
        #expect(throws: TestPlanResolverError.self) { try resolve(["--duration", "-5s"]) }
        #expect(throws: TestPlanResolverError.self) { try resolve(["--duration", "5min"]) }
    }

    @Test func pingRepetitionsAreBounded() {
        #expect(throws: TestPlanResolverError.self) { try resolve(["--ping-reps", "0"]) }
    }

    @Test func invalidBufferSizeTokenIsRejected() {
        #expect(throws: TestPlanResolverError.self) { try resolve(["--buffer-sizes", "64,abc"]) }
    }

    @Test func outOfRangeBufferSizesAreDroppedWithAWarning() throws {
        var warnings: [String] = []
        let plan = try resolve(["--buffer-sizes", "8,64,128,64"], device: device(range: 32...1024), warnings: &warnings)
        #expect(plan.bufferSizes == [64, 128])
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("8") == true)
    }

    @Test func cpuLoadLevelsAreValidated() throws {
        #expect(throws: TestPlanResolverError.self) { try resolve(["--cpu-load-levels", "abc"]) }
        #expect(throws: TestPlanResolverError.self) { try resolve(["--cpu-load-levels", "50,120"]) }
        #expect(try resolve(["--cpu-load-levels", "75,25,75"]).cpuLoadLevelsPercent == [25, 75])
        #expect(try resolve(["--cpu-load"]).cpuLoadLevelsPercent == TestPlanResolver.defaultCPULoadLevelsPercent)
    }

    @Test func memoryPressureAloneEnablesDefaultCPULevels() throws {
        let plan = try resolve(["--mem-pressure-mb", "256"])
        #expect(plan.memoryPressureMB == 256)
        #expect(plan.cpuLoadLevelsPercent == TestPlanResolver.defaultCPULoadLevelsPercent)
        #expect(throws: TestPlanResolverError.self) { try resolve(["--mem-pressure-mb", "-1"]) }
    }

    @Test func outputLevelAndIOLoadAreBounded() throws {
        #expect(try resolve(["--level", "-20"]).outputLevelDBFS == -20)
        #expect(throws: TestPlanResolverError.self) { try resolve(["--level", "0"]) }
        #expect(throws: TestPlanResolverError.self) { try resolve(["--level", "-80"]) }
        #expect(try resolve(["--io-load", "50"]).ioLoadPercent == 50)
        #expect(throws: TestPlanResolverError.self) { try resolve(["--io-load", "95"]) }
    }

    @Test func commandLineSignalOverridesConfigWavFile() throws {
        var config = TestConfigFile()
        config.wavFile = "/nonexistent.wav"
        let plan = try resolve(["--stability-signal", "pink"], config: config)
        #expect(plan.stabilitySignalKind == .pinkNoise)
        #expect(plan.wavFilePath == nil)
    }

    @Test func configWavFileIsUsedAndValidated() {
        var config = TestConfigFile()
        config.wavFile = "/nonexistent.wav"
        #expect(throws: TestPlanResolverError.self) { try resolve([], config: config) }
    }

    @Test func wavSignalWithoutFileIsRejected() {
        #expect(throws: TestPlanResolverError.self) { try resolve(["--stability-signal", "wav"]) }
    }
}

@Suite struct TestConfigFileTests {
    private func decode(_ json: String) throws -> TestConfigFile {
        try TestConfigFile.decode(Data(json.utf8), path: "test.json")
    }

    @Test func decodesKnownKeys() throws {
        let config = try decode(#"{"device": "WING", "bufferSizes": [64, 128], "pairs": [{"output": 1, "input": 2}], "outputLevelDBFS": -18, "wavFile": "a.wav"}"#)
        #expect(config.device == "WING")
        #expect(config.bufferSizes == [64, 128])
        #expect(config.pairs?.first?.input == 2)
        #expect(config.outputLevelDBFS == -18)
        #expect(config.wavFile == "a.wav")
    }

    /// Regression: a typo like "bufferSize" was silently ignored and the default used instead.
    @Test func unknownKeysAreRejected() {
        #expect(throws: TestConfigFileError.self) { try decode(#"{"bufferSize": [64]}"#) }
    }

    @Test func nonObjectIsRejected() {
        #expect(throws: TestConfigFileError.self) { try decode("[1, 2]") }
    }
}
