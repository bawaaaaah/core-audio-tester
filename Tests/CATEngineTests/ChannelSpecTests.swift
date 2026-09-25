import Testing
@testable import CATEngine

@Suite struct ChannelSpecTests {
    @Test func simpleRange() throws {
        #expect(try ChannelSpec.parse("1-7") == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test func commaList() throws {
        #expect(try ChannelSpec.parse("1,3,5") == [1, 3, 5])
    }

    @Test func mixed() throws {
        #expect(try ChannelSpec.parse("1-4,9,12-14") == [1, 2, 3, 4, 9, 12, 13, 14])
    }

    @Test func deduplicatesAndSorts() throws {
        #expect(try ChannelSpec.parse("5,1-3,2") == [1, 2, 3, 5])
    }

    @Test func toleratesSpacesAroundTheDash() throws {
        #expect(try ChannelSpec.parse(" 1 - 3 ") == [1, 2, 3])
    }

    @Test func invalidToken() {
        #expect(throws: ChannelSpecError.self) { try ChannelSpec.parse("abc") }
        #expect(throws: ChannelSpecError.self) { try ChannelSpec.parse("5-2") }
    }

    /// Regression: "1-1000000000" used to materialize a billion-element set before any range check.
    @Test func hugeRangeIsRejectedUpFront() {
        #expect(throws: ChannelSpecError.self) { try ChannelSpec.parse("1-1000000000") }
    }

    @Test func formatRoundTrip() throws {
        let channels = try ChannelSpec.parse("1-4,9,12-14")
        #expect(ChannelSpec.format(channels) == "1-4,9,12-14")
    }
}
