import XCTest
@testable import H4Engine

/// The cheat codes (re/cheats_spec.md): matching (0x5cf240) and each code's effect on the screens
/// that handle it (adventure 0x4bd620, combat 0x6326d0, town 0x8b60c3).
final class CheatTests: XCTestCase {
    // MARK: matching

    func testMatchIsExactIgnoringCase() {
        XCTAssertEqual(Cheats.command(for: "nwcAmbrosia", strings: [:]), .freeMaterials)
        XCTAssertEqual(Cheats.command(for: "NWCAMBROSIA", strings: [:]), .freeMaterials)
        XCTAssertEqual(Cheats.command(for: "nwcprometheus", strings: [:]), .shroud)
        XCTAssertNil(Cheats.command(for: "nwcAmbrosia ", strings: [:]))   // no trimming
        XCTAssertNil(Cheats.command(for: " nwcAmbrosia", strings: [:]))
        XCTAssertNil(Cheats.command(for: "nwcAmbros", strings: [:]))      // the lengths must agree
        XCTAssertNil(Cheats.command(for: "nwcAmbrosiaa", strings: [:]))
        XCTAssertNil(Cheats.command(for: "", strings: [:]))
        // the codes are strings.Text data: a localised table's text is the code
        XCTAssertEqual(Cheats.command(for: "zauber", strings: ["free_materials.cheats": "Zauber"]), .freeMaterials)
        XCTAssertNil(Cheats.command(for: "nwcAmbrosia", strings: ["free_materials.cheats": "Zauber"]))
        // only A-Z fold (the "C" locale's _strnicmp)
        XCTAssertFalse(Cheats.same("\u{e9}", "\u{c9}"))
    }

    func testEveryCodeHasItsCommand() {
        XCTAssertEqual(Cheats.codes.count, 42)
        XCTAssertEqual(Set(Cheats.codes.map { $0.key }).count, 42)
        XCTAssertEqual(Cheats.command(for: "nwcHephaestus", strings: [:]), .newGame)       // 0x8081 = New Game
        XCTAssertEqual(Cheats.command(for: "nwcExcalibur", strings: [:]), .dumpMapImage)   // 0x8083
        XCTAssertEqual(Cheats.command(for: "nwcEtTuBrute", strings: [:]), .daggerOfDespair)
        XCTAssertEqual(Cheats.creatures.count, 20)
        XCTAssertEqual(Cheats.Command.oldManJack.rawValue, 0x808b)
    }

    func testCodesComeFromStringsText() throws {
        let t = try tables()
        for c in Cheats.codes { XCTAssertEqual(t.strings[c.key], c.code, c.key) }
        XCTAssertEqual(t.strings["cheater.misc"], "Cheater")
    }

    // MARK: the adventure map

    func testFreeMaterialsAndTheCheatedFlag() throws {
        let g = try loadGame()
        g.resources = ["Gold": 100, "Wood": 0, "Ore": 5]
        XCTAssertFalse(g.cheated)
        XCTAssertEqual(g.enterCheat("nobody", on: .adventure), .nothing)
        XCTAssertFalse(g.cheated)   // only a match marks the game
        XCTAssertEqual(g.enterCheat("NWCAMBROSIA", on: .adventure), .done)
        XCTAssertTrue(g.cheated)
        XCTAssertEqual(g.resources["Gold"], 200_100)
        XCTAssertEqual(g.resources["Ore"], 305)
        for m in ["Wood", "Crystal", "Sulfur", "Mercury", "Gems"] { XCTAssertEqual(g.resources[m], 300, m) }
        XCTAssertEqual(g.highScoreName(typed: "Anbrose"), "Cheater")
    }

    func testNoEffectCodesStillMarkTheGame() throws {
        let g = try loadGame()
        XCTAssertEqual(g.highScoreName(typed: "Anbrose"), "Anbrose")
        for code in ["nwcPan", "nwcSphinx", "nwcSacrificeToTheGods", "nwcImAGod", "nwcCityOfTroy", "nwcAphrodite", "nwcOldMan", "nwcAres"] {
            g.cheated = false
            XCTAssertEqual(g.enterCheat(code, on: .adventure), .nothing, code)
            XCTAssertTrue(g.cheated, code)
        }
    }

    func testUnlimitedMovement() throws {
        let (g, h) = try gameWithHero()
        h.movement = 3
        g.enterCheat("nwcHermes", on: .adventure)
        XCTAssertEqual(h.movement, 10_000)   // 1,000,000 points
    }

    func testIncreaseLevel() throws {
        let (g, h) = try gameWithHero()
        h.experience = 250
        g.enterCheat("nwcThoth", on: .adventure)
        XCTAssertEqual(h.experience, 1000)   // exactly level 2's threshold
        XCTAssertTrue(g.levelUp?.hero === h || h.level == 2)
        while g.levelUp != nil { g.chooseSkill(0) }
        XCTAssertEqual(h.level, 2)
        g.enterCheat("nwcThoth", on: .adventure)
        XCTAssertEqual(h.experience, 2000)
    }

    func testLearnAllSpells() throws {
        let (g, h) = try gameWithHero()
        g.enterCheat("nwcIsis", on: .adventure)
        let teach = (0..<188).filter { RuleTables.spells[$0].has("Teach") }
        XCTAssertFalse(teach.isEmpty)
        XCTAssertEqual(h.spells, Set(teach))
        XCTAssertEqual(h.spellPoints, 1000)
    }

    func testCreatures() throws {
        let (g, h) = try gameWithHero()
        h.army = [Hero.Stack(creature: "champion", count: 3)]
        g.enterCheat("nwcLancelot", on: .adventure)
        XCTAssertEqual(h.army.first { $0.creature == "champion" }?.count, 23)
        func kw(_ k: String) -> String { g.tables?.creature(k)?.keyword ?? k }
        g.enterCheat("nwcFafnir", on: .adventure)
        XCTAssertEqual(h.army.first { $0.creature == kw("black dragon") }?.count, 20)
        g.enterCheat("nwcStMichael", on: .adventure)
        XCTAssertEqual(h.army.first { $0.creature == kw("archangel") }?.count, 20)
        // every creature code names a creature of the tables
        for k in Cheats.creatures.values { XCTAssertNotNil(g.tables?.creature(k), k) }
        // a full army takes no new kind
        h.army = ["peasant", "squire", "pikeman", "crossbowman", "monk", "crusader"].map { Hero.Stack(creature: $0, count: 1) }
        g.enterCheat("nwcCronus", on: .adventure)
        XCTAssertFalse(h.army.contains { $0.creature == kw("titan") })
        g.enterCheat("nwcTristram", on: .adventure)
        XCTAssertEqual(h.army.first { $0.creature == "crusader" }?.count, 21)
    }

    func testArtifacts() throws {
        let (g, h) = try gameWithHero()
        g.enterCheat("nwcEtTuBrute", on: .adventure)
        g.enterCheat("nwcNibelungenlied", on: .adventure)
        XCTAssertEqual(h.backpack, [0xcc, 0x4e])
        XCTAssertEqual(RuleTables.artifactIds[0xcc], "tynans_dagger_of_despair")
        XCTAssertEqual(RuleTables.artifactIds[0x4e], "greater_ring_of_vulnerability")
        // nwcExcalibur and nwcHephaestus are the frame's Dump Map / New Game commands
        XCTAssertEqual(g.enterCheat("nwcExcalibur", on: .adventure), .dumpMapImage)
        XCTAssertEqual(g.enterCheat("nwcHephaestus", on: .adventure), .newGame)
        XCTAssertEqual(h.backpack.count, 2)
        // an army without a hero gets none (0x6402b0)
        h.heroless = true
        XCTAssertEqual(g.enterCheat("nwcEtTuBrute", on: .adventure), .nothing)
        XCTAssertEqual(h.backpack.count, 2)
    }

    func testShroudToggles() throws {
        let g = try loadGame()
        XCTAssertTrue(g.fogEnabled)
        g.enterCheat("nwcPrometheus", on: .adventure)
        XCTAssertFalse(g.fogEnabled)
        XCTAssertEqual(g.fogState(0, 0), GameState.fogSeen)
        g.enterCheat("nwcPrometheus", on: .adventure)
        XCTAssertTrue(g.fogEnabled)
        // the shroud on the map or in a town is the map's: no effect elsewhere
        XCTAssertEqual(g.enterCheat("nwcPrometheus", on: .town, town: 0), .nothing)
        XCTAssertTrue(g.fogEnabled)
    }

    func testWinAndLoseScenario() throws {
        let g = try loadGame()
        g.enterCheat("nwcValhalla", on: .adventure)
        XCTAssertEqual(g.outcome, true)
        let g2 = try loadGame()
        g2.enterCheat("nwcRagnarok", on: .combat)
        XCTAssertEqual(g2.outcome, false)
    }

    func testAutoPlayToggles() throws {
        let g = try loadGame()
        g.enterCheat("nwcGoSolo", on: .adventure)
        XCTAssertTrue(g.autoPlay); XCTAssertTrue(g.autoPlayPending)
        let day = g.day
        g.autoPlayTurn()
        XCTAssertEqual(g.day, day + 1)
        g.enterCheat("nwcGoSolo", on: .adventure)
        XCTAssertFalse(g.autoPlay); XCTAssertFalse(g.autoPlayPending)
    }

    func testGainSkill() throws {
        let (g, h) = try gameWithHero()
        h.skills = ["tactics": 1, "offense": 1]
        guard case .gainSkillMenu(let who) = g.enterCheat("nwcAthena", on: .adventure) else { return XCTFail("no menu") }
        XCTAssertTrue(who === h)
        XCTAssertEqual(g.gainSkillFamilies(h), Array(0..<9))
        XCTAssertEqual(g.gainSkillChoices(h, family: 0), [0, 9, 10, 11])   // tactics, offense, defense, leadership
        XCTAssertEqual(g.gainSkillLevels(h, skill: 9), [1, 2, 3, 4])
        // grandmaster Offense needs master Tactics (Hero.requirements): both learnt, the skill first
        let msg = g.gainSkill(h, skill: 9, level: 4)
        XCTAssertEqual(h.skill("offense"), 5)
        XCTAssertGreaterThanOrEqual(h.skill("tactics"), Hero.requirements[9][4].first!.1 + 1)
        XCTAssertTrue(msg.hasPrefix("\(h.name) learned "))
        XCTAssertTrue(msg.contains(g.skillName(9, level: 4)))
        XCTAssertTrue(g.gainSkillLevels(h, skill: 9).isEmpty)
        // five primaries known: the other families are gone
        h.skills = ["tactics": 1, "toughness": 1, "scouting": 1, "nobility": 1, "life": 1]
        XCTAssertEqual(g.gainSkillFamilies(h), [0, 1, 2, 3, 4])
        // everything at grandmaster: nothing to learn
        h.skills = Dictionary(uniqueKeysWithValues: RuleTables.skillIds.map { ($0, 5) })
        XCTAssertEqual(g.enterCheat("nwcAthena", on: .adventure), .message("\(h.name) can learn no skills"))
    }

    // MARK: combat

    func testCombatCodes() throws {
        let g = try loadGame()
        XCTAssertEqual(g.enterCheat("nwcAres", on: .combat), .combat(.winCombat))
        XCTAssertEqual(g.enterCheat("nwcAchilles", on: .combat), .combat(.loseCombat))
        XCTAssertEqual(g.enterCheat("nwcAphrodite", on: .combat), .combat(.tattooedWhiteTrash))
        XCTAssertEqual(g.enterCheat("nwcOldMan", on: .combat), .combat(.oldManJack))
        XCTAssertEqual(g.enterCheat("nwcHephaestus", on: .combat), .newGame)
        // the map's codes do nothing in combat
        g.resources["Gold"] = 0
        XCTAssertEqual(g.enterCheat("nwcAmbrosia", on: .combat), .nothing)
        XCTAssertEqual(g.resources["Gold"], 0)
    }

    func battle() -> Battle {
        let field = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
        func def(_ k: String) -> CreatureDef {
            CreatureDef(keyword: k, name: k, plural: k, level: 1, alignment: "life", hitPoints: 10, damageLow: 1, damageHigh: 2,
                        attack: 5, defense: 5, move: 5, speed: 5, growth: 1, gold: 1, experience: 1, shots: 0, spellPoints: 0, shortHelp: "", longHelp: "")
        }
        var hero = Combatant(hero: "Knight", level: 3)
        hero.speed = 50
        let a = [Battle.Fighter(stats: hero, keyword: "knight", actor: "hero.life_fighter_male", size: 4, move: 5, shots: 0),
                 Battle.Fighter(stats: Combatant(creature: def("squire"), count: 5), keyword: "squire", actor: "squire", size: 4, move: 5, shots: 0)]
        let d = [Battle.Fighter(stats: Combatant(creature: def("orc"), count: 9), keyword: "orc", actor: "orc", size: 4, move: 5, shots: 0)]
        return Battle(field: field, attackers: a, defenders: d, seed: 1)
    }

    func testWinCombatKillsTheOtherSide() {
        let b = battle()
        b.cheatEnd(playerWins: true)
        XCTAssertEqual(b.finished, true)
        XCTAssertTrue(b.units.filter { $0.side == 1 }.allSatisfy { !$0.alive })
        XCTAssertTrue(b.units.filter { $0.side == 0 }.allSatisfy { $0.alive })
        let b2 = battle()
        b2.cheatEnd(playerWins: false)
        XCTAssertEqual(b2.finished, false)
        XCTAssertTrue(b2.units.filter { $0.side == 0 }.allSatisfy { !$0.alive })
    }

    func testHeroModels() {
        let b = battle()
        b.putFirst(b.units.first { $0.keyword == "squire" }!.id)
        XCTAssertFalse(b.cheatHeroModel(1))   // "This only works on heroes."
        let hero = b.units.first { $0.stats.isHero }!
        b.putFirst(hero.id)
        XCTAssertTrue(b.cheatHeroModel(1))
        XCTAssertEqual(hero.actor, "hero.tattooed_white_trash")
        XCTAssertEqual(hero.modelOverride, 1)
        XCTAssertEqual(hero.shots, 10)
        XCTAssertTrue(b.cheatHeroModel(2))
        XCTAssertEqual(hero.actor, "hero.jack")
        XCTAssertEqual(hero.modelOverride, 2)
    }

    // MARK: the town screen

    func testTownCodes() throws {
        let g = try loadGame()
        guard let i = g.towns.indices.first else { throw XCTSkip("no town") }
        g.towns[i].owned = true; g.towns[i].owner = g.map.humanColour
        g.towns[i].buildings = []; g.towns[i].allowed = []   // the map's restrictions are not asked
        g.resources = [:]
        XCTAssertEqual(g.enterCheat("nwcCityOfTroy", on: .town, town: i), .done)
        let t = g.towns[i]
        XCTAssertTrue(t.buildings.contains("grail"))
        XCTAssertTrue(t.buildings.contains("castle") && t.buildings.contains("city hall"))
        // every building the alignment has is built or barred by a rival that was built
        for b in 0...42 where GameState.buildingExists(t.alignment, b) {
            XCTAssertTrue(g.isBuilt(t, b) || !g.met(t, GameState.buildingReq(t.alignment, b)), "\(b)")
        }
        XCTAssertEqual(g.resources, [:])   // free of charge
        XCTAssertFalse(t.builtToday)
        // the map's codes: Free Materials works in town, the rest not
        XCTAssertEqual(g.enterCheat("nwcAmbrosia", on: .town, town: i), .done)
        XCTAssertEqual(g.resources["Gold"], 200_000)
        XCTAssertEqual(g.enterCheat("nwcHermes", on: .town, town: i), .nothing)
        // someone else's town is refused
        g.towns[i].owned = false; g.towns[i].owner = (g.map.humanColour + 1) % 6
        XCTAssertEqual(g.enterCheat("nwcCityOfTroy", on: .town, town: i), .message("You can only build structures in your own towns."))
    }

    func testCheatedIsSaved() throws {
        let g = try loadGame()
        g.enterCheat("nwcPan", on: .adventure)
        let s = g.snapshot(mapPath: "x")
        XCTAssertEqual(s.cheated, true)
        let g2 = try loadGame()
        g2.restore(s)
        XCTAssertTrue(g2.cheated)
    }

    // MARK: fixtures (the installed game's data)

    static let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
    func tables() throws -> RuleTables {
        let url = CheatTests.data.appendingPathComponent("text.h4r")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("game data not installed") }
        return try RuleTables(archive: H4Archive(url: url))
    }
    func loadGame() throws -> GameState {
        let data = CheatTests.data
        let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/A Land without a King.h4c")
        guard FileManager.default.fileExists(atPath: mapURL.path) else { throw XCTSkip("game data not installed") }
        let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: data.appendingPathComponent(f)) { archive.supplement(with: a) } }
        let tables = try self.tables()
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
    func gameWithHero() throws -> (GameState, Hero) {
        let g = try loadGame()
        let h = Hero(actor: "hero.life_might_male", x: 10, y: 10)
        h.name = "Tester"; h.heroClass = 0; h.alignment = "life"; h.owner = g.map.humanColour
        g.heroes.insert(h, at: 0)
        return (g, h)
    }
}
