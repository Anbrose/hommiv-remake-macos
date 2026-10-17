import XCTest
@testable import H4Engine

/// The Window of the Magi (hut_of_the_magi) and its Eyes (re/window_of_the_magi_spec.md).
final class MagiWindowTests: XCTestCase {
    func loadGame(_ file: String = "Chasing Reptiles") throws -> GameState {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/\(file).h4c")
        guard FileManager.default.fileExists(atPath: mapURL.path) else { throw XCTSkip("game data not installed") }
        let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: data.appendingPathComponent(f)) { archive.supplement(with: a) } }
        let tables = try RuleTables(archive: H4Archive(url: data.appendingPathComponent("text.h4r")))
        RandomResolver.creaturePool = (1...4).map { lv in tables.creatures.filter { $0.level == lv && $0.expansion == 0 }.map { $0.keyword } }
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let map = try MapFile(data: Data(contentsOf: mapURL), objectNames: names)
        let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
        let scenes = try (0..<max(1, map.levels)).map { try MapScene(map: map, level: $0, archive: archive, masks: masks) }
        let g = GameState(map: map, level: 0, scenes: scenes)
        g.tables = tables
        g.registerObjects(townFactions: [:])
        g.quickCombatOnly = true
        return g
    }
    /// A window with eyes of its colour, the level it is on.
    func window(_ g: GameState) throws -> (MapScene.Placed, Int, [MagiEye]) {
        for l in g.scenes.indices {
            for p in g.scenes[l].placed where p.type == "hut_of_the_magi" {
                let eyes = g.magiEyes(p.subtype)
                if !eyes.isEmpty { return (p, l, eyes) }
            }
        }
        throw XCTSkip("no Window of the Magi with eyes on the map")
    }
    func state(_ g: GameState, _ e: MagiEye) -> UInt8 { g.fogState(e.x, e.y, level: e.level) }

    func testHumanVisitShowsEachEyeThenLeavesItExplored() throws {
        let g = try loadGame()
        let (p, l, eyes) = try window(g)
        g.level = l
        g.updateVision()
        let unseen = eyes.filter { state(g, $0) == GameState.fogUnexplored }
        XCTAssertFalse(unseen.isEmpty)
        let h = Hero(actor: "hero.life_might_male", x: p.cellX, y: p.cellY + 1)
        h.owner = g.map.humanColour
        XCTAssertTrue(g.debugVisit(hero: h, p))
        // first visit: the strings table's first_visit_magi text and dialogue.tower (sound 26), nothing revealed yet
        XCTAssertEqual(g.scripts.messages, [g.text("first_visit_magi.shroud_removers", "?")])
        XCTAssertTrue(g.scripts.messages[0].hasPrefix("You stare into the magical images"))
        XCTAssertEqual(g.sounds.last, "dialogue.tower")
        XCTAssertEqual(g.magiView?.eyes, eyes)
        for e in unseen { XCTAssertEqual(state(g, e), GameState.fogUnexplored) }
        // each tick: the eye in full sight, the one before back to explored
        var shown: [MagiEye] = []
        while let e = g.magiViewStep() {
            XCTAssertEqual(state(g, e), GameState.fogSeen)
            if let prev = shown.last, unseen.contains(prev), prev != e { XCTAssertEqual(state(g, prev), GameState.fogExplored) }
            shown.append(e)
        }
        XCTAssertEqual(shown, eyes)
        XCTAssertNil(g.magiView)
        for e in unseen { XCTAssertEqual(state(g, e), GameState.fogExplored) }
        // a second visit: the re-visit text, the eyes shown again
        g.scripts.messages = []
        g.debugVisit(hero: h, p)
        XCTAssertEqual(g.scripts.messages, [g.text("re_visit_magi.shroud_removers", "?")])
        XCTAssertEqual(g.magiView?.eyes.count, eyes.count)
    }

    func testInputSkipsTheRestExplored() throws {
        let g = try loadGame()
        let (p, l, eyes) = try window(g)
        g.level = l
        g.updateVision()
        let unseen = eyes.filter { state(g, $0) == GameState.fogUnexplored }
        let h = Hero(actor: "hero.life_might_male", x: p.cellX, y: p.cellY + 1)
        h.owner = g.map.humanColour
        g.debugVisit(hero: h, p)
        XCTAssertNotNil(g.magiViewStep())
        g.magiViewFinish()
        XCTAssertNil(g.magiView)
        for e in unseen { XCTAssertEqual(state(g, e), GameState.fogExplored) }
    }

    func testComputerVisitIsSilentAndOnlyOnceWorthIt() throws {
        let g = try loadGame()
        let (p, l, eyes) = try window(g)
        g.level = l
        g.updateVision()
        let before = eyes.map { state(g, $0) }
        let colour = (0..<8).first { $0 != g.map.humanColour }!
        let h = Hero(actor: "hero.life_might_male", x: p.cellX, y: p.cellY + 1)
        h.owner = colour
        XCTAssertEqual(g.shroudRemoverValue(p, for: colour), 750)
        g.acting(as: colour) { _ = g.debugVisit(hero: h, p) }
        XCTAssertTrue(g.scripts.messages.isEmpty)
        XCTAssertNil(g.magiView)
        XCTAssertEqual(eyes.map { state(g, $0) }, before)   // (the computer's sight is not the player's)
        XCTAssertEqual(g.shroudRemoverValue(p, for: colour), 0)
        XCTAssertEqual(g.shroudRemoverValue(p, for: g.map.humanColour), 750)
    }

    func testLookoutTextsNameTheObject() throws {
        let g = try loadGame("Midnight Mayhem")
        guard let (p, l) = g.scenes.indices.lazy.compactMap({ l in g.scenes[l].placed.first { $0.type == "tower" || $0.type == "cartographer" }.map { ($0, l) } }).first
        else { throw XCTSkip("no tower on the map") }
        g.level = l
        let h = Hero(actor: "hero.life_might_male", x: p.cellX, y: p.cellY + 1)
        h.owner = g.map.humanColour
        XCTAssertTrue(g.debugVisit(hero: h, p))
        let name = g.objectText(p, "name") ?? ""
        XCTAssertEqual(g.scripts.messages, [g.text("first_visit.shroud_removers", "?").replacingOccurrences(of: "%name", with: name)])
        XCTAssertEqual(g.sounds.last, "dialogue.tower")
        g.scripts.messages = []
        g.debugVisit(hero: h, p)
        XCTAssertEqual(g.scripts.messages, [g.text("re_visit.shroud_removers", "?").replacingOccurrences(of: "%name", with: name)])
    }
}
