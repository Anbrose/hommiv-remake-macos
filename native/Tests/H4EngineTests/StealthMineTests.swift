import XCTest
@testable import H4Engine

/// Experience for sneaking past wandering armies (re/stealth_xp_spec.md: 0x546300 / 0x546050 /
/// 0x546720) and a mine's visit (re/mine_capture_spec.md: 0x79c7f0 / 0x79cf30), on a real map
/// (skipped when the game is not installed).
final class StealthMineTests: XCTestCase {
    func loadGame() throws -> GameState {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/A Land without a King.h4c")
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
        g.setupObjects()
        g.fogEnabled = false
        return g
    }

    /// A wandering stack moved onto open dry ground (radius 6 clear, the other stacks out of the
    /// way), as `creature` x count.
    func stackOnOpenGround(_ g: GameState, creature: String, count: Int) throws -> (Int, (Int, Int)) {
        guard let i = g.guardStacks.first else { throw XCTSkip("no wandering stack") }
        let n = g.map.size, r = 6
        for x in r + 2..<n - r - 2 { for y in r + 2..<n - r - 2 {
            var ok = true
            for dx in -r...r { for dy in -r...r where ok {
                let a = x + dx, b = y + dy
                if g.map.cells[0][a * n + b] == nil || g.passability.terrainBlocked[a * n + b] || g.passability.isWater(a, b) || g.passability.bridgeAxis[a * n + b] != 0 { ok = false }
            } }
            guard ok else { continue }
            for k in g.monsters.indices where k != i && max(abs(g.monsters[k].x - x), abs(g.monsters[k].y - y)) <= r + 4 { g.monsters[k].count = 0 }
            for dx in -r...r { for dy in -r...r { g.passability.free(x + dx, y + dy) } }
            let m = g.monsters[i]
            guard let p = g.scene.placed.first(where: { g.monster(for: $0) == i }) else { throw XCTSkip("stack not placed") }
            g.passability.free(m.x, m.y)
            g.monsters[i] = GameState.Monster(x: x, y: y, name: m.name, creature: creature, count: count)
            g.passability.block(x, y); g.passability.openTrigger(x, y, object: Int.max)
            _ = g.scene.relocate(p, toX: x, y: y)
            return (i, (x, y))
        } }
        throw XCTSkip("no open ground")
    }
    func hero(_ g: GameState, at c: (Int, Int), stealth: Int) -> Hero {
        let h = Hero(actor: "hero.life_might_male", x: c.0, y: c.1, movement: 30)
        h.owner = g.map.humanColour
        h.name = "Sir Test"
        h.skills["stealth"] = stealth
        h.army = []
        g.heroes = [h]
        return h
    }

    func testStealthAndMines() throws {
        let g = try loadGame()
        try scenarioShareOfTheValue(g)
        try scenarioOncePerArmyPerHero(g)
        try scenarioWhoIsEluded(g)
        try scenarioWalkPastTellsAtTheEnd(g)
        try scenarioComputerTakesTheLevels(g)
        try scenarioMineCapture(g)
        try scenarioGuardedMine(g)
    }

    /// 0x546050: value / (4 x the difficulty factor) + 0.5, truncated, for a human player's army;
    /// / 4 for the computer's. The value is the army's creatures times their experience.
    func scenarioShareOfTheValue(_ g: GameState) throws {
        g.difficulty = 1
        XCTAssertEqual(g.eludedExperience(400, human: true), 100)
        XCTAssertEqual(g.eludedExperience(402, human: true), 101)   // 100.5 -> 101
        XCTAssertEqual(g.eludedExperience(401, human: true), 100)
        g.difficulty = 0
        XCTAssertEqual(g.eludedExperience(400, human: true), 150)   // / 2.6668
        g.difficulty = 4
        XCTAssertEqual(g.eludedExperience(400, human: true), 33)    // / 12
        XCTAssertEqual(g.eludedExperience(400, human: false), 100)
        g.difficulty = 1
        guard let peasant = g.tables?.creature("peasant") else { return XCTFail("no peasant") }
        var m = GameState.Monster(x: 0, y: 0, name: "x", creature: "peasant", count: 30, extra: [("peasant", 10)])
        XCTAssertEqual(g.experienceValue(of: m), 40 * peasant.experience)
        m.count = 0
        XCTAssertEqual(g.experienceValue(of: m), 10 * peasant.experience)
    }

    /// Each living hero of the army is paid the whole share (not split), once per army: the
    /// army's id goes into the hero's set (0x733e20) and a second pass pays nothing.
    func scenarioOncePerArmyPerHero(_ g: GameState) throws {
        let (i, m) = try stackOnOpenGround(g, creature: "peasant", count: 40)
        let h = hero(g, at: (m.0 - 1, m.1 - 1), stealth: 2)
        let mate = Hero(actor: "hero.life_magic_female", x: h.x, y: h.y, movement: 30)
        mate.name = "Lady Test"; mate.skills["stealth"] = 3
        h.companions = [mate]
        let share = g.eludedExperience(g.experienceValue(of: g.monsters[i]), human: true)
        XCTAssertGreaterThan(share, 0)
        g.markEluded(h)
        XCTAssertEqual(h.experience, share)
        XCTAssertEqual(mate.experience, share)
        XCTAssertEqual(h.eludedGains.map(\.amount), [share, share])
        g.markEluded(h)
        XCTAssertEqual(h.experience, share)
        XCTAssertTrue(h.eluded.contains(g.monsters[i].uid))
        // the save keeps the set
        let back = SaveGame.hero(from: SaveGame.state(of: h))
        XCTAssertEqual(back.eluded, h.eluded)
        h.eludedGains = []
    }

    /// 0x546300: the army's stealth must be 1 or more (Advanced) and beat the stack's scouting + 1;
    /// a creature in the army spoils it; the cells looked at are x - 2 ..< x + 2, y - 2 ..< y + 2.
    func scenarioWhoIsEluded(_ g: GameState) throws {
        let (i, m) = try stackOnOpenGround(g, creature: "peasant", count: 20)
        func gained(stealth: Int, at c: (Int, Int), army: [Hero.Stack] = []) -> Bool {
            let h = hero(g, at: c, stealth: stealth)
            h.army = army
            g.markEluded(h)
            return h.experience > 0
        }
        XCTAssertFalse(gained(stealth: 1, at: (m.0 - 1, m.1)))   // basic: stealth 0
        XCTAssertTrue(gained(stealth: 2, at: (m.0 - 1, m.1)))    // advanced vs level 1: 1 > -1 + 1
        XCTAssertFalse(gained(stealth: 2, at: (m.0 - 1, m.1), army: [Hero.Stack(creature: "peasant", count: 1)]))
        XCTAssertTrue(gained(stealth: 2, at: (m.0 + 2, m.1 + 2)))    // the stack at x - 2, y - 2: in
        XCTAssertFalse(gained(stealth: 2, at: (m.0 - 2, m.1)))       // the stack at x + 2: out
        XCTAssertFalse(gained(stealth: 2, at: (m.0, m.1 - 2)))       // at y + 2: out
        XCTAssertFalse(gained(stealth: 2, at: (m.0 + 3, m.1)))
        guard let four = g.tables?.creatures.first(where: { $0.level == 4 })?.keyword else { return XCTFail() }
        g.monsters[i] = GameState.Monster(x: m.0, y: m.1, name: g.monsters[i].name, creature: four, count: 2)
        XCTAssertFalse(gained(stealth: 4, at: (m.0 - 1, m.1)))   // master (3) vs level 4: 3 <= 2 + 1
        XCTAssertTrue(gained(stealth: 5, at: (m.0 - 1, m.1)))
        g.heroes = []
    }

    /// A walk past the stack: paid on the step into its reach, the box comes when the walk is
    /// over -- the singular text, the hero's experience picture -- and nothing attacks.
    func scenarioWalkPastTellsAtTheEnd(_ g: GameState) throws {
        let (i, m) = try stackOnOpenGround(g, creature: "peasant", count: 30)
        // along y + 2: the stack is in reach (y - 2 <= its y < y + 2) from x - 1 to x + 2
        let h = hero(g, at: (m.0 - 5, m.1 + 2), stealth: 2)
        g.scripts.messages = []; g.messagePictures = [:]; g.pendingBattle = nil; g.charge = nil
        g.click(hero: h, x: m.0 + 5, y: m.1 + 2)
        g.click(hero: h, x: m.0 + 5, y: m.1 + 2)
        XCTAssertTrue(h.isWalking)
        var paidWhileWalking = false
        for _ in 0..<900 {
            g.update(dt: 1.0 / 30)
            if h.isWalking, h.experience > 0 { paidWhileWalking = true; XCTAssertTrue(g.scripts.messages.isEmpty) }
            if !h.isWalking && h.walkAnim == nil { break }
        }
        XCTAssertTrue(paidWhileWalking)
        XCTAssertNil(g.pendingBattle)
        let share = g.eludedExperience(g.experienceValue(of: g.monsters[i]), human: true)
        XCTAssertEqual(h.experience, share)
        XCTAssertEqual(g.scripts.messages, ["Sir Test has gained experience from using his Stealth skill."])
        guard let pic = g.messagePictures[g.scripts.messages[0]]?.first, case .heroExperience(let who, let n) = pic else { return XCTFail("no picture") }
        XCTAssertTrue(who === h); XCTAssertEqual(n, share)
        XCTAssertNil(g.messageAnchors[g.scripts.messages[0]])   // centred (0x5596f0)
        XCTAssertTrue(h.eludedGains.isEmpty)
        // several heroes: the plural text, "A and B, C" (0x74f2d0)
        let b = Hero(actor: "hero.life_magic_female", x: 0, y: 0, movement: 1); b.name = "B"
        let c = Hero(actor: "hero.life_might_male", x: 0, y: 0, movement: 1); c.name = "C"
        let a = Hero(actor: "hero.life_might_male", x: 0, y: 0, movement: 1); a.name = "A"
        XCTAssertEqual(g.heroText("stealth_use_plural.misc", "", [a, b, c]), "A and B, C have gained experience from using their Stealth skills.")
        XCTAssertEqual(g.heroText("stealth_use_singular.misc", "", b), "B has gained experience from using her Stealth skill.")
        g.scripts.messages = []
        g.heroes = []
    }

    /// The computer's army: paid / 4, no box, its levels taken at once.
    func scenarioComputerTakesTheLevels(_ g: GameState) throws {
        let (_, m) = try stackOnOpenGround(g, creature: "peasant", count: 10000)
        let h = hero(g, at: (m.0 - 1, m.1), stealth: 2)
        g.heroes = []
        h.owner = (g.map.humanColour + 1) % 6
        let value = g.experienceValue(of: g.monsters.first { $0.x == m.0 && $0.y == m.1 }!)
        g.markEluded(h)
        XCTAssertEqual(h.experience, g.eludedExperience(value, human: false))
        g.finishEluded(h)
        XCTAssertTrue(g.scripts.messages.isEmpty)
        XCTAssertEqual(h.level, Hero.level(for: h.experience))
        XCTAssertGreaterThan(h.level, 1)
    }

    /// 0x79c7f0 / 0x79cf30: a human army plays flag_mine on every visit; claiming shows the
    /// mine's box above the army: its name as the title, `initial` with %material, the material
    /// captioned "+N name/day"; the own mine shows nothing more; a heroless army gets `no_heroes`
    /// centred; the computer claims in silence.
    func scenarioMineCapture(_ g: GameState) throws {
        guard let i = g.mines.firstIndex(where: { $0.owner == nil && $0.z == 0 && $0.guards.isEmpty }),
              let p = g.scene.placed.first(where: { g.mine(for: $0) == i }) else { throw XCTSkip("no free mine") }
        let h = hero(g, at: (p.cellX - 1, p.cellY + p.sprite.footprint.h), stealth: 0)
        g.scripts.messages = []; g.sounds = []
        g.interact(hero: h, p)
        XCTAssertEqual(g.sounds, ["miscellaneous.flag_mine"])
        XCTAssertEqual(g.mines[i].owner, g.map.humanColour)
        XCTAssertEqual(g.scripts.messages.count, 1)
        let t = g.scripts.messages[0], m = g.mineMaterial(i), n = g.mines[i].amount
        let name = g.tables?.objectText(p.type, p.subtype, "name")
        XCTAssertNotNil(name)
        XCTAssertEqual(g.messageTitles[t], name)
        XCTAssertTrue(t.contains("\(n) \(GameState.materialNames[m].lowercased())"), t)
        XCTAssertTrue(t.contains(name!), t)
        guard case .material(let mm, let nn, let perDay)? = g.messagePictures[t]?.first else { return XCTFail("no picture") }
        XCTAssertEqual([mm, nn], [m, n]); XCTAssertTrue(perDay)
        XCTAssertEqual(g.messageAnchors[t].map { [$0.x, $0.y] }, [h.x, h.y])
        // again: the sound, nothing else
        g.scripts.messages = []; g.sounds = []
        g.interact(hero: h, p)
        XCTAssertEqual(g.sounds, ["miscellaneous.flag_mine"])
        XCTAssertTrue(g.scripts.messages.isEmpty)
        // the computer takes it back without a word
        let ai = (g.map.humanColour + 1) % 6
        let e = hero(g, at: (h.x, h.y), stealth: 0); e.owner = ai
        g.scripts.messages = []; g.sounds = []
        g.acting(as: ai) { g.interact(hero: e, p) }
        XCTAssertEqual(g.mines[i].owner, ai)
        XCTAssertTrue(g.scripts.messages.isEmpty); XCTAssertTrue(g.sounds.isEmpty)
        // a heroless army: no_heroes, centred, the mine stays the computer's
        let army = hero(g, at: (h.x, h.y), stealth: 0); army.heroless = true; army.army = [Hero.Stack(creature: "peasant", count: 5)]
        g.interact(hero: army, p)
        XCTAssertEqual(g.sounds, ["miscellaneous.flag_mine"])
        XCTAssertEqual(g.mines[i].owner, ai)
        XCTAssertEqual(g.scripts.messages, [g.objectText(p, "no_heroes")].compactMap { $0 })
        XCTAssertEqual(g.scripts.messages.count, 1)
        XCTAssertNil(g.messageAnchors[g.scripts.messages.first ?? ""])
        g.scripts.messages = []; g.heroes = []
    }

    /// Guards left in a mine: the human is asked `initial_guarded` (titled, above the army); won,
    /// the mine is claimed with `defeat`.
    func scenarioGuardedMine(_ g: GameState) throws {
        guard let i = g.mines.firstIndex(where: { $0.owner == nil && $0.z == 0 }),
              let p = g.scene.placed.first(where: { g.mine(for: $0) == i }) else { throw XCTSkip("no free mine") }
        g.mines[i].guards = [Hero.Stack(creature: "peasant", count: 1)]
        let h = hero(g, at: (p.cellX - 1, p.cellY + p.sprite.footprint.h), stealth: 0)
        h.army = [Hero.Stack(creature: g.tables?.creatures.first { $0.level == 4 }?.keyword ?? "peasant", count: 20)]
        g.scripts.messages = []; g.sounds = []
        g.interact(hero: h, p)
        XCTAssertEqual(g.sounds, ["miscellaneous.flag_mine"])
        guard let q = g.question else { return XCTFail("no question") }
        XCTAssertEqual(q.text, g.objectText(p, "initial_guarded", ["%creatures": g.mineGuardText(i), "%the_creatures": g.mineGuardText(i)]))
        XCTAssertEqual(g.questionTitle, g.tables?.objectText(p.type, p.subtype, "name"))
        XCTAssertEqual(g.questionAnchor.map { [$0.x, $0.y] }, [h.x, h.y])
        g.question = nil
        let words = g.mineGuardText(i)
        XCTAssertEqual(words, "1 " + (g.tables?.creature("peasant")?.name ?? ""))
        g.quickCombatOnly = true
        q.yes()
        XCTAssertEqual(g.mines[i].owner, g.map.humanColour)
        XCTAssertTrue(g.mines[i].guards.isEmpty)
        XCTAssertEqual(g.scripts.messages.count, 1)
        XCTAssertEqual(g.scripts.messages.first, g.objectText(p, "defeat", ["%material": g.materialList([(g.mineMaterial(i), g.mines[i].amount)]), "%the_creatures": words]))
        g.quickCombatOnly = false
    }
}
