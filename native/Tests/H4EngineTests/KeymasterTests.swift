import XCTest
@testable import H4Engine

/// Keymaster's tents, border gates and guards on "The Pirate's Daughter" (campaign 4, map 0;
/// re/keymaster_spec.md).
final class KeymasterTests: XCTestCase {
    static let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
    func game() throws -> GameState {
        let h4r = KeymasterTests.data.appendingPathComponent("heroes4.h4r")
        guard FileManager.default.fileExists(atPath: h4r.path) else { throw XCTSkip("no game files") }
        let archive = try H4Archive(url: h4r)
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: KeymasterTests.data.appendingPathComponent(f)) { archive.supplement(with: a) } }
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let map = try MapFile(data: CampaignFile.load(4, from: archive).scenario(0), objectNames: names)
        let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
        let g = GameState(map: map, level: 0, scenes: [try MapScene(map: map, level: 0, archive: archive, masks: masks)])
        g.tables = try RuleTables(archive: H4Archive(url: KeymasterTests.data.appendingPathComponent("text.h4r")))
        g.setupObjects()
        return g
    }
    func object(_ g: GameState, _ type: String, _ colour: String, at c: (Int, Int)? = nil) -> MapScene.Placed {
        g.scene.placed.first { $0.type == type && $0.subtype == colour && (c == nil || ($0.cellX, $0.cellY) == c!) }!
    }

    func testKeysGatesAndGuards() throws {
        let g = try game()
        let human = g.map.humanColour
        let h = Hero(actor: "hero.life_might_male", x: 134, y: 70, movement: 30); h.owner = human
        g.heroes.append(h)
        // the green gate across (133..135, 71): its middle cell is the passage
        let gate = object(g, "border_gate", "green", at: (133, 71)), tent = object(g, "keymaster_tent", "green")
        XCTAssertTrue(g.passability.isTrigger(134, 71))
        // no key: the passage is a stop -- a route ends on it (the bump), never goes through it
        g.preparePlanner(for: h)
        XCTAssertFalse(g.passability.isFree(134, 71))
        XCTAssertFalse(g.passability.path(from: (134, 70), to: (134, 72))?.contains { $0 == (134, 71) } ?? false)
        XCTAssertEqual(g.passability.path(from: (134, 70), to: (134, 71))?.count, 1)
        XCTAssertTrue(g.isVisitable(gate))
        g.debugVisit(hero: h, gate)
        let denied = try XCTUnwrap(g.scripts.messages.last)
        XCTAssertTrue(denied.contains(g.keymasterName("green")), denied)
        XCTAssertFalse(denied.contains("%"), denied)
        XCTAssertEqual(g.sounds.last, "dialogue.\(GameState.dialogueSounds[17])")
        // a computer player bumping it is told nothing
        let ai = Hero(actor: "hero.life_might_male", x: 134, y: 70, movement: 30); ai.owner = (human + 1) % 6
        g.scripts.messages = []
        g.debugVisit(hero: ai, gate)
        XCTAssertTrue(g.scripts.messages.isEmpty)
        // the tent: the key, "Initial"; then "Empty"
        XCTAssertEqual(g.describe(tent).body, [])
        g.debugVisit(hero: h, tent)
        XCTAssertTrue(g.hasKey(human, "green"))
        XCTAssertEqual(g.scripts.messages.last, g.objectText(tent, "Initial"))
        XCTAssertEqual(g.describe(tent).body, [g.text("visited.object", "?")])
        g.debugVisit(hero: h, tent)
        XCTAssertEqual(g.scripts.messages.last, g.objectText(tent, "Empty"))
        XCTAssertNotEqual(g.objectText(tent, "Initial"), g.objectText(tent, "Empty"))
        // with the key the gate is open ground for the player, and stays on the map
        XCTAssertTrue(g.passability.isFree(134, 71))
        XCTAssertEqual(g.passability.path(from: (134, 70), to: (134, 72))?.map { [$0.x, $0.y] }, [[134, 71], [134, 72]])
        XCTAssertFalse(g.isVisitable(gate))
        g.scripts.messages = []
        g.debugVisit(hero: h, gate)
        XCTAssertTrue(g.scripts.messages.isEmpty)
        XCTAssertTrue(g.scene.placed.contains { $0.type == "border_gate" && ($0.cellX, $0.cellY) == (133, 71) })
        // keys are per player: for the computer's army the gate is still shut
        g.preparePlanner(for: ai)
        XCTAssertFalse(g.passability.isFree(134, 71))
        g.preparePlanner(for: h)
        XCTAssertTrue(g.passability.isFree(134, 71))
        // saved and restored
        let s = try JSONDecoder().decode(SaveGame.self, from: JSONEncoder().encode(g.snapshot(mapPath: "x")))
        g.keys = [:]; g.applyBorderGates(for: human)
        XCTAssertFalse(g.passability.isFree(134, 71))
        g.restore(s)
        XCTAssertEqual(g.keys, [human: ["green"]])
        XCTAssertTrue(g.passability.isFree(134, 71))

        // (one map load: building the scene is slow in debug builds)
        guardGoesWithItsChains(g)
    }

    func guardGoesWithItsChains(_ g: GameState) {
        let human = g.map.humanColour
        let guardian = object(g, "border_guard", "purple")
        let h = Hero(actor: "hero.life_might_male", x: guardian.cellX, y: guardian.cellY - 1, movement: 30); h.owner = human
        g.heroes.append(h)
        func chainsNear() -> Int { g.scene.placed.filter { $0.type == "chain" && abs($0.cellX - guardian.cellX) <= 3 && abs($0.cellY - guardian.cellY) <= 3 }.count }
        let before = chainsNear()
        XCTAssertGreaterThan(before, 0)
        g.debugVisit(hero: h, guardian)   // no key: "Denied", nothing asked
        XCTAssertNil(g.question)
        XCTAssertEqual(g.scripts.messages.last, g.objectText(guardian, "Denied", ["%keymaster_tent_name": g.keymasterName("purple")]))
        g.keys[human] = ["purple"]
        g.debugVisit(hero: h, guardian)
        guard let q = g.question else { return XCTFail("no question") }
        XCTAssertEqual(q.text, g.objectText(guardian, "Accepted"))
        XCTAssertTrue(g.scene.placed.contains { $0.type == "border_guard" && $0.subtype == "purple" })
        q.yes()
        XCTAssertFalse(g.scene.placed.contains { $0.type == "border_guard" && $0.subtype == "purple" })
        XCTAssertEqual(chainsNear(), 0)
        XCTAssertTrue(g.passability.isFreeWater(guardian.cellX, guardian.cellY))   // a water guard: open sea again
    }
}
