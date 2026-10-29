import XCTest
@testable import H4Engine

/// A carry-in campaign's start (re/carryover_placeholder_spec.md): without the other campaigns'
/// results the exe refuses it (0x5aa330, 0x76c110) instead of starting a map whose placeholders
/// would have no hero.
final class CarryInTests: XCTestCase {
    func testGatheringStormNeedsTheOtherCampaignsResults() throws {
        let (a, _) = try StartPlacementTests().archive()
        let c = try CampaignFile.load(12, from: a)
        XCTAssertTrue(c.carryIn)
        XCTAssertEqual(c.carryInCampaigns, ["Masters of Magic", "A Matter of Life and Death", "Opposites Attract", "Another Bard's Tale", "Might Makes Right"])
        let missing = c.missingCarryIn(stored: [])
        XCTAssertEqual(missing, c.carryInCampaigns)
        XCTAssertEqual(c.missingCarryIn(stored: Set(c.carryInCampaigns)), [])
        XCTAssertEqual(c.carryInRefusal(missing: missing, strings: [:]),
                       "You must complete Might Makes Right, Another Bard's Tale, Opposites Attract, A Matter of Life and Death and Masters of Magic before your heroes will be ready for The Gathering Storm.")
        // a campaign without the carry-in flag starts with nothing stored
        XCTAssertEqual(try CampaignFile.load(4, from: a).missingCarryIn(stored: []), [])
    }
}
