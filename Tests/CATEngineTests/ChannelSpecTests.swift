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

    @Test func invalidToken() {
        #expect(throws: (any Error).self) { try ChannelSpec.parse("abc") }
    }

    @Test func formatRoundTrip() throws {
        let channels = try ChannelSpec.parse("1-4,9,12-14")
        #expect(ChannelSpec.format(channels) == "1-4,9,12-14")
    }
}
