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

/// The finished campaigns' store (re/campaign_carryover_store_spec.md): 0x5aa960 writes a
/// campaign's entry when its last scenario is won, 0x5aa580 appends the imported entries.
final class CarryStoreTests: XCTestCase {
    func hero(_ name: String) -> SaveGame.HeroState { let h = Hero(actor: "x", x: 0, y: 0); h.name = name; return SaveGame.state(of: h) }
    func carry(_ human: [String], colour: Int, ai: [Int: [String]] = [:], artifacts: [Int]? = nil) -> Carryover {
        var c = Carryover()
        c.human = human.map(hero); c.humanColour = colour
        c.byColour = ai.mapValues { $0.map(hero) }
        c.artifacts = artifacts
        c.scores = [CampaignScore(score: 1, days: 2)]
        return c
    }

    func testGatheringStormImportsEveryFinishedCampaignInHeaderOrder() throws {
        let (a, _) = try StartPlacementTests().archive()
        let gs = try CampaignFile.load(12, from: a)
        var store = CarryoverStore()
        XCTAssertNil(store.carryIn(for: gs))
        // finished in another order than the header's; one finished twice (its entry replaced)
        let names = gs.carryInCampaigns
        for (k, id) in [11, 9, 7, 8, 10, 9].enumerated() {
            let c = try CampaignFile.load(id, from: a)
            XCTAssertTrue(c.carryOut)
            store.record(c, carry: carry(["\(c.name) \(k)"], colour: k % 6, ai: [3: ["foe \(c.name)"]], artifacts: [k]))
        }
        XCTAssertEqual(store.stored, Set(names))
        XCTAssertEqual(gs.missingCarryIn(stored: store.stored), [])
        XCTAssertNil(store.entries["Masters of Magic"]?.carry?.scores)   // the cross-campaign mode writes no scores
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("carrystore-\(UUID()).json")
        try store.save(url); defer { try? FileManager.default.removeItem(at: url) }
        let back = CarryoverStore.load(url)
        let k = try XCTUnwrap(back.carryIn(for: gs))
        XCTAssertFalse(gs.choosesPosition)
        let last = ["Masters of Magic": 5, "A Matter of Life and Death": 2, "Opposites Attract": 3, "Another Bard's Tale": 0, "Might Makes Right": 4]
        XCTAssertEqual(k.human.map(\.name), names.map { "\($0) \(last[$0]!)" })
        XCTAssertEqual(k.byColour[3]?.map(\.name), names.map { "foe \($0)" })
        XCTAssertEqual(k.artifacts, names.map { last[$0]! })
        XCTAssertNil(k.scores)
        // a campaign without the carry-in flag starts from an empty carry
        XCTAssertEqual(store.carryIn(for: try CampaignFile.load(4, from: a))?.human.count, 0)
    }

    func testTheLastBastionSendsEachCampaignsHeroesToTheColourItPlayed() throws {
        let (a, _) = try StartPlacementTests().archive()
        let wow = try CampaignFile.load(18, from: a)
        XCTAssertTrue(wow.choosesPosition)
        var store = CarryoverStore()
        for (k, id) in [14, 15, 17, 16, 13].enumerated() {
            let c = try CampaignFile.load(id, from: a)
            store.record(c, carry: carry(["h\(k)"], colour: [0, 1, 2, 0, 5][k], ai: k == 4 ? [0: ["ai0"]] : [:]))
        }
        let c = try XCTUnwrap(store.carryIn(for: wow))
        XCTAssertEqual(c.human.count, 0)
        // the computer heroes of every entry first, then the human heroes in entry order (0x5bd290)
        XCTAssertEqual(c.byColour[0]?.map(\.name), ["ai0", "h0", "h3"])
        XCTAssertEqual(c.byColour[1]?.map(\.name), ["h1"])
        XCTAssertEqual(c.byColour[5]?.map(\.name), ["h4"])
        // a campaign without the carry-out flag gets an entry that does not count
        var s2 = CarryoverStore()
        s2.record(try CampaignFile.load(1, from: a), carry: carry(["x"], colour: 0))
        XCTAssertEqual(s2.stored, [])
        XCTAssertNotNil(s2.entries["The True Blade"])
    }
}
