import XCTest
@testable import H4Engine

/// Right clicks on towns, armies and quests (re/town_popup_spec.md): the information level of
/// heroes4.exe 0x4faf40 and the quest text of 0x7ee020.
final class RightClickInfoTests: XCTestCase {
    func loadGame(_ name: String = "A Land without a King") throws -> GameState {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/\(name).h4c")
        guard FileManager.default.fileExists(atPath: mapURL.path) else { throw XCTSkip("game data not installed") }
        let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: data.appendingPathComponent(f)) { archive.supplement(with: a) } }
        let tables = try RuleTables(archive: H4Archive(url: data.appendingPathComponent("text.h4r")))
        RandomResolver.creaturePool = (1...4).map { lv in tables.creatures.filter { $0.level == lv && $0.expansion == 0 }.map { $0.keyword } }
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let map = try MapFile(data: Data(contentsOf: mapURL), objectNames: names)
        let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
        let scene = try MapScene(map: map, level: 0, archive: archive, masks: masks)
        let g = GameState(map: map, level: 0, scenes: [scene])
        g.tables = tables
        g.registerObjects(townFactions: [:])
        return g
    }

    func scout(_ g: GameState, at x: Int, _ y: Int, scouting: Int?) -> Hero {
        let h = Hero(actor: "hero.life_might_male", x: x, y: y)
        h.owner = g.map.humanColour
        if let s = scouting { h.skills["scouting"] = s + 1 }   // 0 basic ... 4 grandmaster
        g.heroes = [h]
        return h
    }

    /// 0x4faf40: own or allied 4; else the best Scouting level of a hero whose sight radius
    /// (10 + Scouting level) reaches the object's first footprint cell; -1 out of sight or with
    /// no Scouting (fog off here: every cell is in sight).
    func testInformationLevel() throws {
        let g = try loadGame()
        guard let i = g.towns.indices.first(where: { g.townColour(g.towns[$0]) != g.map.humanColour }) else { throw XCTSkip("no foreign town") }
        let t = g.towns[i]
        guard let p = g.scene.placed.first(where: { $0.category == "castle" && $0.cellX == t.x && $0.cellY == t.y }) else { return XCTFail("no town object") }
        let (cx, cy) = g.firstOccupiedCell(p)
        // radius 10 + Scouting level (basic 0, advanced 1): the hero's own level within it
        _ = scout(g, at: cx + 5, cy, scouting: nil)
        XCTAssertEqual(g.infoLevel(town: i), -1)
        _ = scout(g, at: cx + 10, cy, scouting: 0)
        XCTAssertEqual(g.infoLevel(town: i), 0)
        _ = scout(g, at: cx + 11, cy, scouting: 1)
        XCTAssertEqual(g.infoLevel(town: i), 1)
        _ = scout(g, at: cx + 11, cy, scouting: 0)   // 10 + 0 < 11
        XCTAssertEqual(g.infoLevel(town: i), -1)
        _ = scout(g, at: cx + 6, cy + 8, scouting: 0)   // straight-line distance 10
        XCTAssertEqual(g.infoLevel(town: i), 0)
        // Visions: at least 3 within the sight radius
        let v = scout(g, at: cx + 3, cy, scouting: nil)
        v.timedEffects["spell.visions"] = 1
        XCTAssertEqual(g.infoLevel(town: i), 3)
        // the player's own town: 4 wherever the heroes are
        g.heroes = []
        g.towns[i].owned = true
        XCTAssertEqual(g.infoLevel(town: i), 4)
    }

    /// 0x7ee020: the table's help until visited (or scouted), then the objective text, then the
    /// table's completed text -- per colour.
    func testQuestHelp() throws {
        var found: (GameState, MapScene.Placed)?
        for name in ["A Land without a King", "Beyond the lake", "Ancestral Home", "Bandits of the Rifen Maze", "Barbarians from Below", "Chasing Reptiles", "Conquest of Four lakes"] {
            guard let g = try? loadGame(name) else { continue }
            if let p = g.scene.placed.first(where: { ["seers_hut", "quest_gate", "quest_guard"].contains($0.type) && (g.record(for: $0)?.questTexts.count ?? 0) >= 4 }) { found = (g, p); break }
        }
        guard let (g, p) = found else { throw XCTSkip("no quest on the maps tried") }
        let r = g.record(for: p)!
        g.heroes = []
        let key = g.objectKey(p)
        XCTAssertEqual(g.questHelp(p), g.objectText(p, "help"))
        g.objectStates[key, default: ObjectState()].questVisited = [(g.map.humanColour + 1) % 6]   // another colour's visit
        XCTAssertEqual(g.questHelp(p), g.objectText(p, "help"))
        g.objectStates[key, default: ObjectState()].questVisited.append(g.map.humanColour)
        XCTAssertEqual(g.questHelp(p), r.questTexts[1])
        g.objectStates[key, default: ObjectState()].questDone = [g.map.humanColour]
        XCTAssertEqual(g.questHelp(p), g.objectText(p, "completed"))
        // a scout with Scouting in range reads the objective without a visit
        g.objectStates[key] = ObjectState()
        let (cx, cy) = g.firstOccupiedCell(p)
        _ = scout(g, at: cx + 2, cy, scouting: 0)
        XCTAssertEqual(g.questHelp(p), r.questTexts[1])
    }
}
