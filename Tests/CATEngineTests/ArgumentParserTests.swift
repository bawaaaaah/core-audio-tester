import Testing
@testable import CATEngine

@Suite struct ArgumentParserTests {
    @Test func parsesValuesFlagsAndInlineForms() throws {
        let options = try ArgumentParser.parse([
            "--device", "WING", "--in=1-4", "--out", "1-4", "--ping-reps", "5", "--yes",
            "--level", "-18dBFS", "--io-load", "40", "--exclusive",
        ])
        #expect(options.device == "WING")
        #expect(options.inputChannels == "1-4")
        #expect(options.outputChannels == "1-4")
        #expect(options.pingRepetitions == 5)
        #expect(options.skipConfirmation)
        #expect(options.outputLevelDBFS == -18)
        #expect(options.ioLoadPercent == 40)
        #expect(options.exclusive)
    }

    @Test func versionFlag() throws {
        #expect(try ArgumentParser.parse(["--version"]).version)
    }

    @Test func unknownFlagIsAnError() {
        #expect(throws: ArgumentParserError.self) { try ArgumentParser.parse(["--bogus"]) }
    }

    @Test func positionalArgumentIsAnError() {
        #expect(throws: ArgumentParserError.self) { try ArgumentParser.parse(["WING"]) }
    }

    /// Regression: "--device --auto" used to take "--auto" as the device name.
    @Test func flagFollowingAValueFlagMeansTheValueIsMissing() {
        #expect(throws: ArgumentParserError.self) { try ArgumentParser.parse(["--device", "--auto"]) }
    }

    /// Regression: non-numeric values were silently replaced by the default.
    @Test func nonNumericValuesAreRejected() {
        #expect(throws: ArgumentParserError.self) { try ArgumentParser.parse(["--ping-reps", "abc"]) }
        #expect(throws: ArgumentParserError.self) { try ArgumentParser.parse(["--mem-pressure-mb", "lots"]) }
        #expect(throws: ArgumentParserError.self) { try ArgumentParser.parse(["--level", "loud"]) }
    }

    @Test func autoConflictsWithSelection() {
        #expect(throws: ArgumentParserError.self) { try ArgumentParser.parse(["--auto", "--in", "1"]) }
    }

    @Test func wavFileConflictsWithAnotherSignal() {
        #expect(throws: ArgumentParserError.self) { try ArgumentParser.parse(["--wav-file", "a.wav", "--stability-signal", "pink"]) }
        #expect(throws: Never.self) { try ArgumentParser.parse(["--wav-file", "a.wav", "--stability-signal", "wav"]) }
    }
}
