import XCTest
@testable import H4Engine

/// A wandering stack met by a human hero (heroes4.exe 0x522560, re/neutral_encounter_spec.md):
/// Charm / Diplomacy offers (0x521780), then the flight question when the stack is worth at most
/// a fifth of the army (0x52278a), then the battle.
final class NeutralEncounterTests: XCTestCase {
    func testFiveTimesRule() {
        XCTAssertTrue(GameState.stackRuns(stackWorth: 100, armyWorth: 500))    // equal counts (fcompp C3)
        XCTAssertTrue(GameState.stackRuns(stackWorth: 0, armyWorth: 1))
        XCTAssertFalse(GameState.stackRuns(stackWorth: 100.1, armyWorth: 500))
    }

    func testSwayCapsByExperience() {
        let exp: (String) -> Int = { ["peasant": 2, "wolf": 25][$0] ?? 1 }
        // 30% of 100 peasants = 30, allowance 60 xp -> 30 peasants (60 xp); nothing left for wolves
        var s = GameState.sway([.init(creature: "peasant", count: 100), .init(creature: "wolf", count: 10)], margin: 30, allowance: 60, allowed: { _ in true }, experience: exp)
        XCTAssertEqual(s.map { "\($0.creature):\($0.count)" }, ["peasant:30"])
        // the allowance limits: 15% of 100 = 15 peasants wanted, 20 xp pays for 10
        s = GameState.sway([.init(creature: "peasant", count: 100)], margin: 15, allowance: 20, allowed: { _ in true }, experience: exp)
        XCTAssertEqual(s.first?.count, 10)
        // truncation: 15% of 6 = 0, nobody; refused kinds are skipped
        XCTAssertTrue(GameState.sway([.init(creature: "peasant", count: 6)], margin: 15, allowance: 999, allowed: { _ in true }, experience: exp).isEmpty)
        XCTAssertTrue(GameState.sway([.init(creature: "wolf", count: 50)], margin: 70, allowance: 999, allowed: { $0 != "wolf" }, experience: exp).isEmpty)
    }

    func loadGame() throws -> GameState {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/A Land without a King.h4c")
        guard FileManager.default.fileExists(atPath: mapURL.path) else { throw XCTSkip("game data not installed") }
        let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        let tables = try RuleTables(archive: H4Archive(url: data.appendingPathComponent("text.h4r")))
        RandomResolver.creaturePool = (1...4).map { lv in tables.creatures.filter { $0.level == lv && $0.expansion == 0 }.map { $0.keyword } }
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let map = try MapFile(data: Data(contentsOf: mapURL), objectNames: names)
        let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
        let g = GameState(map: map, level: 0, scenes: [try MapScene(map: map, level: 0, archive: archive, masks: masks)])
        g.tables = tables
        g.registerObjects(townFactions: [:])
        return g
    }

    func testFlightQuestionAndLetThemRun() throws {
        let g = try loadGame()
        guard let i = g.monsters.indices.first(where: { g.monsters[$0].bank == nil }),
              let p = g.scene.placed.first(where: { g.monster(for: $0) == i }) else { throw XCTSkip("no stack") }
        let h = Hero(actor: "hero.life_might_male", x: g.monsters[i].x + 1, y: g.monsters[i].y, movement: 30)
        h.owner = g.map.humanColour; g.heroes.append(h)
        g.monsters[i] = GameState.Monster(x: g.monsters[i].x, y: g.monsters[i].y, name: g.monsters[i].name, creature: "peasant", count: 10)
        h.army = [Hero.Stack(creature: "peasant", count: 10)]
        XCTAssertFalse(g.enemyRunsOffered(hero: h, monsterAt: i))           // as strong as the stack: it fights
        h.army = [Hero.Stack(creature: "archangel", count: 5)]
        g.quickCombatOnly = true
        XCTAssertFalse(g.enemyRunsOffered(hero: h, monsterAt: i))           // the Quick Combat option: no question
        g.quickCombatOnly = false
        XCTAssertTrue(g.enemyRunsOffered(hero: h, monsterAt: i))
        h.owner = (g.map.humanColour + 1) % 8
        XCTAssertFalse(g.enemyRunsOffered(hero: h, monsterAt: i))           // a computer's army never asks
        h.owner = g.map.humanColour
        let n = g.monsters.count, xp = h.experience, won = g.battlesWon[h.owner, default: 0]
        g.fight(hero: h, monsterAt: i, p)
        XCTAssertNotNil(g.pendingFlee); XCTAssertNil(g.pendingBattle)
        g.resolveFlee(.letThemRun)
        XCTAssertEqual(g.monsters.count, n - 1)                            // the stack left the map
        XCTAssertEqual(h.experience, xp)                                   // nobody fell: no experience
        XCTAssertEqual(g.battlesWon[h.owner, default: 0], won + 1)         // a won battle for the score
        XCTAssertEqual(h.army.first?.count, 5)
    }

    func testCharmAndDiplomacyOffer() throws {
        let g = try loadGame()
        guard let i = g.monsters.indices.first(where: { g.monsters[$0].bank == nil }),
              let p = g.scene.placed.first(where: { g.monster(for: $0) == i }) else { throw XCTSkip("no stack") }
        let h = Hero(actor: "hero.life_might_male", x: g.monsters[i].x + 1, y: g.monsters[i].y, movement: 30)
        h.owner = g.map.humanColour; g.heroes.append(h)
        g.monsters[i] = GameState.Monster(x: g.monsters[i].x, y: g.monsters[i].y, name: g.monsters[i].name, creature: "skeleton", count: 20, extra: [("wolf", 8)])
        h.army = [Hero.Stack(creature: "archangel", count: 10)]; h.level = 11
        h.skills["charm"] = 3; h.skills["diplomacy"] = 0                      // Expert Charm: 25%, 180 xp + 180 x 10 / 10
        var o = try XCTUnwrap(g.joinOffer(hero: h, monsterAt: i, p))
        let wolf = try XCTUnwrap(g.tables?.creature("wolf"))
        XCTAssertEqual(o.charm.map { $0.creature }, ["wolf"])                  // undead skeletons are never charmed
        XCTAssertEqual(o.charm.first?.count, min(8 * 25 / 100, 360 / wolf.experience))
        XCTAssertTrue(o.diplomacy.isEmpty)
        h.skills["charm"] = 0; h.skills["diplomacy"] = 1                      // Basic Diplomacy: 30%, 120 + 120 xp
        o = try XCTUnwrap(g.joinOffer(hero: h, monsterAt: i, p))
        XCTAssertTrue(o.charm.isEmpty)
        let cost = o.diplomacy.reduce(0) { $0 + $1.count * (g.tables?.creature($1.creature)?.gold ?? 0) } >> 1
        XCTAssertEqual(o.cost, cost)
        // too weak an army (experience value < 3 x the stack's): no offer
        h.army = [Hero.Stack(creature: "peasant", count: 1)]; h.level = 1; g.monsters[i].count = 200
        XCTAssertNil(g.joinOffer(hero: h, monsterAt: i, p))
        // accepting: the creatures leave the stack and join the army, the gold is paid
        h.army = [Hero.Stack(creature: "archangel", count: 10)]; h.level = 11; g.monsters[i].count = 20
        let offer = try XCTUnwrap(g.joinOffer(hero: h, monsterAt: i, p))
        g.resources["Gold"] = 100_000; g.quickCombatOnly = false
        let before = g.monsters[i].count + g.monsters[i].extra.reduce(0) { $0 + $1.count }
        let swayed = offer.diplomacy.reduce(0) { $0 + $1.count }
        g.pendingJoin = offer
        g.resolveJoin(2)
        XCTAssertEqual(g.resources["Gold"], 100_000 - offer.cost)
        XCTAssertEqual(h.army.filter { $0.creature != "archangel" }.reduce(0) { $0 + $1.count }, swayed)
        XCTAssertTrue(swayed > 0)
        XCTAssertEqual(g.monsters[i].count + g.monsters[i].extra.reduce(0) { $0 + $1.count }, before - swayed)   // the rest stand, and now turn to flee
        XCTAssertNotNil(g.pendingFlee)
    }
}
