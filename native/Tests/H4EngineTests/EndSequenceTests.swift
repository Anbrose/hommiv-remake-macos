import XCTest
@testable import H4Engine

/// The end of a scenario (re/end_sequence_spec.md): eliminations and the standard conditions
/// (0x4c4a50), the hold of every town (0x4b3710 / 0x4e5b00), the script actions, what follows the
/// movie (0x4c5850), the score (0x81ad30) and the high-score lists (0x7430a0).
final class EndSequenceTests: XCTestCase {
    // MARK: texts and steps

    func testEliminationText() {
        let s = ["eliminated.adventure_map": "%name (%color) has been eliminated!", "default_name.adventure_map": "A player",
                 "blue.adventure_map": "blue", "gray.adventure_map": "neutral"]
        XCTAssertEqual(GameState.eliminationText(colour: 2, strings: s), "A player (blue) has been eliminated!")
        XCTAssertEqual(GameState.eliminationText(colour: 6, strings: s), "A player (neutral) has been eliminated!")
        // without the table: the same words
        XCTAssertEqual(GameState.eliminationText(colour: 0, strings: [:]), "A player (red) has been eliminated!")
    }

    func testStepsAfterTheMovie() {
        XCTAssertEqual(EndStep.after(won: false, campaign: false, hasNextScenario: false, campaignFinished: false), [.mainMenu])
        XCTAssertEqual(EndStep.after(won: false, campaign: true, hasNextScenario: true, campaignFinished: false), [.mainMenu])   // no retry
        XCTAssertEqual(EndStep.after(won: true, campaign: false, hasNextScenario: false, campaignFinished: false), [.finalScore, .mainMenu])
        XCTAssertEqual(EndStep.after(won: true, campaign: true, hasNextScenario: true, campaignFinished: false), [.nextScenario])
        XCTAssertEqual(EndStep.after(won: true, campaign: true, hasNextScenario: false, campaignFinished: true), [.campaignComplete, .mainMenu])
        XCTAssertEqual(EndStep.after(won: true, campaign: true, hasNextScenario: false, campaignFinished: false), [.mainMenu])   // briefing cancelled
        XCTAssertEqual(EndStep.movie(won: true), "win_game")
        XCTAssertEqual(EndStep.movie(won: false), "lose_game")
    }

    func testVoiceOverKeys() {
        XCTAssertEqual(CampaignFile.voiceOver("chaos_a_prologue"), "Chaos A")
        XCTAssertEqual(CampaignFile.voiceOver("order_epilogue"), "Order H - Epilogue")
        XCTAssertEqual(CampaignFile.voiceOver("might_d_prologue"), "Might D - Intro")
        XCTAssertEqual(CampaignFile.voiceOver("H4x1_campaign_3_epilogue"), "H4x1_campaign_3_epilogue")
        XCTAssertEqual(CampaignFile.voiceOver("SpazzA"), "SpazzA")
    }

    // MARK: the score

    func testTimeScore() {
        // S0, intermediate (100), average map (100%): under 3 weeks the bonus, 3-7 the base, then the decline
        XCTAssertEqual(ScenarioScore.timeScore(days: 6, sizeClass: 0, playerDifficulty: 1, mapDifficulty: 2), 350)
        XCTAssertEqual(ScenarioScore.timeScore(days: 7, sizeClass: 0, playerDifficulty: 1, mapDifficulty: 2), 200)
        XCTAssertEqual(ScenarioScore.timeScore(days: 14, sizeClass: 0, playerDifficulty: 1, mapDifficulty: 2), 150)
        XCTAssertEqual(ScenarioScore.timeScore(days: 21, sizeClass: 0, playerDifficulty: 1, mapDifficulty: 2), 100)
        XCTAssertEqual(ScenarioScore.timeScore(days: 55, sizeClass: 0, playerDifficulty: 1, mapDifficulty: 2), 100)
        XCTAssertEqual(ScenarioScore.timeScore(days: 56, sizeClass: 0, playerDifficulty: 1, mapDifficulty: 2), 95)    // w 8: 5 x 19 %
        XCTAssertEqual(ScenarioScore.timeScore(days: 7 * 30, sizeClass: 0, playerDifficulty: 1, mapDifficulty: 2), 30) // floor 30 %
        // weeks are scaled by the map size; the map's difficulty percent comes last
        XCTAssertEqual(ScenarioScore.timeScore(days: 7 * 5, sizeClass: 1, playerDifficulty: 4, mapDifficulty: 4), (700 + 50) * 150 / 100)
        XCTAssertEqual(ScenarioScore.timeScore(days: 0, sizeClass: 3, playerDifficulty: 0, mapDifficulty: 0), (100 + 250) * 50 / 100)
    }

    func testCategoriesAndCaps() {
        var i = ScoreInputs()
        i.sizeClass = 1; i.levels = 2; i.playerDifficulty = 1; i.mapDifficulty = 2; i.days = 30
        i.towns = 3; i.quests = 5; i.battlePoints = 80; i.battlesWon = 4
        i.armyValue = 30_000
        i.artifactLevels = [0, 1, 2, 3, 4, 5, 6, 3]
        i.bestHero = ("Gauldoth", 12)
        i.resources = [25_000, 30, 20, 10, 10, 10, 10]
        i.startResources = [15_000, 15, 15, 7, 7, 7, 7]
        i.explored = 0.52
        let s = ScenarioScore.compute(i) { _ in 7 }
        XCTAssertEqual(s.townScore, 45)                       // 3 x 15
        XCTAssertEqual(s.questScore, 96)                      // 5 x 24 capped
        XCTAssertEqual(s.battleScore, 72)                     // capped
        XCTAssertEqual(s.armyScore, 15)                       // 30000 x 0.0005
        XCTAssertEqual(s.artifactScore, 76)                   // 5+10+20+45+45+20 capped; items and fragments none
        XCTAssertEqual(s.artifacts, 6)
        XCTAssertEqual(s.heroScore, 48)                       // (12 - 4) x 6
        // wealth: 10000 + 15x125/2 + 5x125/2 + 4 x 3x250/2 = 10000 + 937 + 312 + 4 x 375
        XCTAssertEqual(s.wealth, 10_000 + 937 + 312 + 1500)
        XCTAssertEqual(s.wealthScore, 12)                     // x 0.001
        XCTAssertEqual(s.exploreScore, 6)
        XCTAssertEqual(s.timeScore, 125 + 50)                 // w = 4 / 2 = 2: the third bonus
        XCTAssertEqual(s.total, 45 + 96 + 72 + 15 + 76 + 48 + 12 + 6 + 175)
        XCTAssertEqual(s.rank, 7)
        // a cheat: every score 0, the counts and the rank stay
        i.cheated = true
        let c = ScenarioScore.compute(i) { _ in 7 }
        XCTAssertEqual(c.total, 0); XCTAssertEqual(c.townScore, 0); XCTAssertEqual(c.timeScore, 0); XCTAssertEqual(c.heroScore, 0)
        XCTAssertEqual(c.towns, 3); XCTAssertEqual(c.rank, 7)
    }

    func testHeroThresholdOnLargeUndergroundMaps() {
        var i = ScoreInputs()
        i.sizeClass = 3; i.bestHero = ("X", 10)
        i.levels = 1
        XCTAssertEqual(ScenarioScore.compute(i) { _ in 0 }.heroScore, 12)   // (10 - 6) x 3
        i.levels = 2
        XCTAssertEqual(ScenarioScore.compute(i) { _ in 0 }.heroScore, 6)    // the fifth column: (10 - 7) x 2
        i.bestHero = ("X", 3)
        XCTAssertEqual(ScenarioScore.compute(i) { _ in 0 }.heroScore, 0)
    }

    func testRankBattlePointsAndCampaign() {
        // the experience order picks the creature; ties by id
        let exp: (Int) -> Int = { $0 % 10 }
        XCTAssertEqual(ScenarioScore.rank(score: 0, scale: 1000, experience: exp), 0)
        XCTAssertEqual(ScenarioScore.rank(score: 5000, scale: 1000, experience: exp), 69)   // past the end: the last (exp 9, highest id)
        XCTAssertEqual(ScenarioScore.battlePoints(winner: 100, loser: 400, sizeClass: 0), 60)
        XCTAssertEqual(ScenarioScore.battlePoints(winner: 100, loser: 100, sizeClass: 0), 20)
        XCTAssertEqual(ScenarioScore.battlePoints(winner: 140, loser: 100, sizeClass: 2), 5)
        XCTAssertEqual(ScenarioScore.battlePoints(winner: 200, loser: 100, sizeClass: 0), 0)
        XCTAssertEqual(ScenarioScore.battlePoints(winner: 200, loser: 0, sizeClass: 0), 0)
        let c = ScenarioScore.campaign([CampaignScore(score: 300, days: 20), CampaignScore(score: 251, days: 31)])
        XCTAssertEqual(c.average, 275); XCTAssertEqual(c.score, 1375); XCTAssertEqual(c.days, 51)
    }

    // MARK: high scores

    func testHighScoreInsertion() {
        var t = HighScores.defaults(strings: ["player_name_1.high_Score": "Maranthea", "Map_name_1.High_Score": "Beowulf Meets Grendel"]) { _ in 3 }
        XCTAssertEqual(t.standard[0].name, "Maranthea"); XCTAssertEqual(t.standard[0].map, "Beowulf Meets Grendel")
        XCTAssertEqual(t.standard.map { $0.score }.first, "294"); XCTAssertEqual(t.campaign.map { $0.score }.last, "555")
        XCTAssertNil(t.insert(map: "M", days: 9, score: 118, name: "Tie", standard: true, rank: 1))   // a tie with the last: out
        XCTAssertEqual(t.insert(map: "M", days: 9, score: 250, name: "A", standard: true, rank: 1), 2)  // above 249
        XCTAssertEqual(t.standard[2].name, "A"); XCTAssertTrue(t.standard[2].isNew)
        XCTAssertEqual(t.standard.count, 10); XCTAssertEqual(t.standard.last?.score, "130")            // 118 dropped
        XCTAssertEqual(t.insert(map: "M", days: 9, score: 250, name: "B", standard: true, rank: 99), 3) // a tie goes below
        XCTAssertFalse(t.standard[2].isNew)
        XCTAssertEqual(t.standard[3].rank, 73)
        XCTAssertEqual(t.insert(map: "C", days: 40, score: 1500, name: "Camp", standard: false, rank: 5), 0)
        XCTAssertEqual(t.campaign[0].days, "40")
        // the file: gzip of version 0 and the 20 entries
        let back = HighScores.decode(t.encoded())
        XCTAssertEqual(back?.standard.map { $0.name }, t.standard.map { $0.name })
        XCTAssertEqual(back?.campaign.map { $0.score }, t.campaign.map { $0.score })
        XCTAssertEqual(back?.standard[3].rank, 73)
        XCTAssertFalse(back?.standard[3].isNew ?? true)   // not stored
    }

    func testReadsTheInstalledHighScoreFile() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/data/high_scores.dat")
        guard let d = try? Data(contentsOf: url) else { throw XCTSkip("no installed high_scores.dat") }
        let t = try XCTUnwrap(HighScores.decode(d))
        XCTAssertEqual(t.standard.count, 10)
        XCTAssertEqual(t.campaign.count, 10)
    }

    // MARK: on a real map

    func testLastPlayerStandingWins() throws {
        let g = try loadGame()
        guard g.standardVictoryEnabled else { throw XCTSkip("standard victory off") }
        let me = g.map.humanColour
        let others = g.playerColours.filter { $0 != me }
        guard !others.isEmpty else { throw XCTSkip("one player") }
        // every other player loses everything at once
        for i in g.towns.indices where g.townOwner(g.towns[i]).map({ $0 != me }) ?? false { g.towns[i].owner = nil; g.towns[i].owned = false }
        g.enemyHeroes = []
        g.checkScenario()
        XCTAssertEqual(g.outcome, true)
        XCTAssertEqual(g.winningTeam, g.team(of: me))
        XCTAssertEqual(Set(g.eliminatedPlayers), Set(others))
        // one box names them all, joined by " and " and a line break
        XCTAssertEqual(g.scripts.messages.count, 1)
        let lines = g.scripts.messages[0].components(separatedBy: " and \n")
        XCTAssertEqual(lines.count, others.count)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("A player (") && $0.hasSuffix(") has been eliminated!") })
        // once over it stays over
        g.scriptWin(others[0])
        XCTAssertEqual(g.outcome, true)
    }

    func testHumanWithNothingLeftLoses() throws {
        let g = try loadGame()
        let me = g.map.humanColour
        for i in g.towns.indices where g.townOwner(g.towns[i]) == me { g.towns[i].owner = nil; g.towns[i].owned = false }
        g.heroes = []
        g.checkScenario()
        XCTAssertEqual(g.outcome, false)
        XCTAssertTrue(g.isEliminated(me))
        XCTAssertTrue(g.scripts.messages.first?.contains("has been eliminated!") ?? false)   // his own box first, then the movie
    }

    func testHoldingEveryTownForThreeDays() throws {
        let g = try loadGame()
        guard g.standardVictoryEnabled else { throw XCTSkip("standard victory off") }
        let me = g.map.humanColour
        guard g.enemyHeroes.contains(where: { $0.owner != me }) || !g.playerColours.filter({ $0 != me }).isEmpty else { throw XCTSkip("no foe") }
        // the human takes every town; a foe keeps an army so he is not eliminated
        let foe = g.playerColours.first { $0 != me }!
        if !g.enemyHeroes.contains(where: { $0.owner == foe }) {
            let h = Hero(actor: "x", x: 0, y: 0); h.owner = foe; g.enemyHeroes.append(h)
        }
        for i in g.towns.indices { g.towns[i].owner = me; g.towns[i].owned = true }
        g.checkScenario()
        XCTAssertNil(g.outcome)
        XCTAssertEqual(g.victoryTeam, g.team(of: me)); XCTAssertEqual(g.victoryDays, 3)
        XCTAssertEqual(g.scripts.messages.last, "Victory is at hand!  Hold your towns for 3 days and your foes will be defeated!")
        g.scripts.messages = []
        g.checkScenario()   // a hold already running: nothing new
        XCTAssertTrue(g.scripts.messages.isEmpty)
        // the days: 2, 1, then the win at the turn's start
        g.victoryNewDay(); g.victoryTurnStart()
        XCTAssertEqual(g.scripts.messages.last, "Hold your towns for another 2 days to win the game!")
        g.victoryNewDay(); g.victoryTurnStart()
        XCTAssertEqual(g.scripts.messages.last, "Hold your towns for one more day to win the game!")
        XCTAssertNil(g.outcome)
        g.victoryNewDay(); g.victoryTurnStart()
        XCTAssertEqual(g.outcome, true)
    }

    func testAHoldBrokenByAComputer() throws {
        let g = try loadGame()
        guard g.standardVictoryEnabled else { throw XCTSkip("standard victory off") }
        let me = g.map.humanColour
        guard let foe = g.playerColours.first(where: { $0 != me }), g.towns.count >= 2 else { throw XCTSkip("no foe") }
        let h = Hero(actor: "x", x: 0, y: 0); h.owner = foe; g.enemyHeroes.append(h)
        for i in g.towns.indices { g.towns[i].owner = me; g.towns[i].owned = true }
        g.checkScenario()
        XCTAssertNotNil(g.victoryTeam)
        g.scripts.messages = []
        // the computer takes a town on its move: the human is told, the days reset
        g.towns[0].owner = foe; g.towns[0].owned = false
        g.acting = foe
        g.checkScenario()
        g.acting = nil
        XCTAssertNil(g.victoryTeam); XCTAssertEqual(g.victoryDays, 3)
        XCTAssertEqual(g.scripts.messages.last, "Your opponent has taken steps to undermine your victory.  A town has been reclaimed!")
    }

    func testOnlyComputersOwningTownsIsNoHold() throws {
        let g = try loadGame()
        let me = g.map.humanColour
        guard let foe = g.playerColours.first(where: { $0 != me }) else { throw XCTSkip("no foe") }
        for i in g.towns.indices { g.towns[i].owner = foe; g.towns[i].owned = false }
        XCTAssertNil(g.soleTownTeam())   // 0x4d87d0: a computer never wins by holding towns
    }

    func testScriptLoseEliminatesAndScriptWinForAFoeLoses() throws {
        let g = try loadGame()
        let me = g.map.humanColour
        guard let foe = g.playerColours.first(where: { $0 != me && g.team(of: $0) != g.team(of: me) }) else { throw XCTSkip("no foe") }
        g.scriptLose(foe)
        XCTAssertTrue(g.isEliminated(foe))
        XCTAssertTrue(g.scripts.messages.contains { $0.contains("has been eliminated!") })
        let g2 = try loadGame()
        g2.scriptWin(foe)
        XCTAssertEqual(g2.outcome, false)
        XCTAssertEqual(g2.winningTeam, g2.team(of: foe))
        let g3 = try loadGame()
        g3.scriptLose(me)
        XCTAssertEqual(g3.outcome, false)
    }

    func testScoreOfARealGame() throws {
        let g = try loadGame()
        g.day = 22
        g.battlesWon[g.map.humanColour] = 2; g.battlePoints[g.map.humanColour] = 50
        let s = g.scenarioScore(team: g.team(of: g.map.humanColour))
        XCTAssertEqual(s.days, 21)
        XCTAssertEqual(s.battlesWon, 2); XCTAssertEqual(s.battleScore, 50)
        XCTAssertGreaterThan(s.explored, 0)
        XCTAssertEqual(s.total, s.timeScore + s.battleScore + s.questScore + s.wealthScore + s.exploreScore + s.armyScore + s.artifactScore + s.heroScore + s.townScore)
        g.cheated = true
        XCTAssertEqual(g.scenarioScore(team: g.team(of: g.map.humanColour)).total, 0)
    }

    // "The Unexpected Prize" (campaign 10, scenario 1): its continuous event wins once Dogwoggle's
    // side has the Frost Hammer (236) -- which Adram Blacksword wears, so beating him must win
    func testBeatingAdramWinsTheUnexpectedPrize() throws {
        let g = try loadGame(campaign: (10, 0))
        g.loadScripts()
        // the two armies as the session places them (main.swift): the heroes with their worn items
        func army(_ name: String) throws -> Hero {
            let o = try XCTUnwrap(g.map.objects.first { $0.heroes.contains { $0.name == name } })
            let h = Hero.fromMap(o.heroes[0], alignment: "might", x: o.x, y: o.y, tables: g.tables, random: &g.random)
            h.owner = o.owner ?? 0
            return h
        }
        let dog = try army("Dogwoggle"), adram = try army("Adram Blacksword")
        g.heroes = [dog]
        g.place(enemy: adram)
        g.runContinuous()
        XCTAssertNil(g.outcome)   // not yet
        let worn = adram.members.flatMap { $0.equipped.compactMap { $0 } + $0.backpack }
        XCTAssertTrue(worn.contains(236))
        g.finishHeroBattle(hero: dog, enemy: adram, won: true, army: dog.army, enemyArmy: [], value: 0)
        // the spoils dialog (0x7fcdb0 -> t_dialog_booty) holds everything Adram carried, and the
        // post-battle step (0x4d7800) waits for it
        let b = try XCTUnwrap(g.booty)
        XCTAssertEqual(b.artifacts, worn)
        XCTAssertTrue(adram.members.allSatisfy { $0.backpack.isEmpty && $0.equipped.allSatisfy { $0 == nil } })
        XCTAssertNil(g.outcome)
        // the Frost Hammer dragged onto Dogwoggle's portrait, the rest left to Okay (booty to the first hero)
        XCTAssertTrue(g.bootyGive(try XCTUnwrap(b.artifacts.firstIndex(of: 236)), to: dog))
        XCTAssertTrue(dog.equipped.contains(236) || dog.backpack.contains(236))
        if g.booty != nil { XCTAssertNil(g.outcome); g.closeBooty() }
        XCTAssertNil(g.booty)
        XCTAssertEqual(g.outcome, true)   // 0x4d7800 ran the continuous events (0x4ddf30) after the dialog
        XCTAssertTrue(g.scripts.messages.contains { $0.hasPrefix("After defeating Adram") })
    }

    /// A computer winner takes the beaten army's artifacts at once (0x7fdb96 -> 0x7fb560), no dialog.
    func testComputerWinnerTakesTheSpoils() throws {
        let g = try loadGame(campaign: (10, 0))
        func army(_ name: String) throws -> Hero {
            let o = try XCTUnwrap(g.map.objects.first { $0.heroes.contains { $0.name == name } })
            let h = Hero.fromMap(o.heroes[0], alignment: "might", x: o.x, y: o.y, tables: g.tables, random: &g.random)
            h.owner = o.owner ?? 0
            return h
        }
        let dog = try army("Dogwoggle"), adram = try army("Adram Blacksword")
        dog.backpack = [10]
        g.heroes = [dog]
        g.place(enemy: adram)
        g.finishHeroBattle(hero: dog, enemy: adram, won: false, army: [], enemyArmy: adram.army, value: 0)
        XCTAssertNil(g.booty)
        XCTAssertTrue(adram.equipped.contains(10) || adram.backpack.contains(10))
        XCTAssertTrue(dog.backpack.isEmpty)
    }

    func loadGame(campaign: (Int, Int)? = nil, allLevels: Bool = false) throws -> GameState {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/A Land without a King.h4c")
        guard FileManager.default.fileExists(atPath: mapURL.path) else { throw XCTSkip("game data not installed") }
        let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: data.appendingPathComponent(f)) { archive.supplement(with: a) } }
        let tables = try RuleTables(archive: H4Archive(url: data.appendingPathComponent("text.h4r")))
        RandomResolver.creaturePool = (1...4).map { lv in tables.creatures.filter { $0.level == lv && $0.expansion == 0 }.map { $0.keyword } }
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let map = try campaign.map { try MapFile(data: CampaignFile.load($0.0, from: archive).scenario($0.1), objectNames: names) }
            ?? MapFile(data: Data(contentsOf: mapURL), objectNames: names)
        let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
        let scenes = try (0..<(allLevels ? max(1, map.levels) : 1)).map { try MapScene(map: map, level: $0, archive: archive, masks: masks) }
        let g = GameState(map: map, level: 0, scenes: scenes)
        g.tables = tables
        g.registerObjects(townFactions: [:])
        g.quickCombatOnly = true
        return g
    }
}
