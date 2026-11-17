import XCTest
@testable import H4Engine

/// Saving during combat (re/combat_save_spec.md): a battle saved between actions and loaded is the
/// same battle, and goes on to the same end.
final class CombatSaveTests: XCTestCase {
    func creature(_ keyword: String, hp: Int = 10, low: Int = 2, high: Int = 4, speed: Int = 5, shots: Int = 0, sp: Int = 0, power: Int = 0, move: Int = 10) -> CreatureDef {
        var c = CreatureDef(keyword: keyword, name: keyword, plural: keyword, level: 1, alignment: "might", hitPoints: hp, damageLow: low, damageHigh: high,
                            attack: 10, defense: 10, move: move, speed: speed, growth: 1, gold: 1, experience: 2, shots: shots, spellPoints: sp,
                            shortHelp: "", longHelp: "")
        c.spellPower = power
        return c
    }
    func fighter(_ c: CreatureDef, _ n: Int, slot: Int) -> Battle.Fighter {
        Battle.Fighter(stats: Combatant(creature: c, count: n), keyword: c.keyword, actor: c.keyword, size: 2, move: c.move, shots: c.shots, slot: slot)
    }
    var field: Battlefield { Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 7) }
    /// Two mixed armies: a casting hero, a creature caster, archers and melee stacks.
    func battle() -> Battle {
        var st = Combatant(hero: "hero", level: 8, skills: ["archery": 2])
        st.speed = 7
        let hero = Battle.Fighter(stats: st, keyword: "hero", actor: "hero", size: 2, move: 24, shots: st.shots, slot: 0,
                                  caster: Caster(level: 8, skills: ["order_magic": 3, "life_magic": 3], spells: [72, 10, 23, 57], spellPoints: 40))
        let mage = creature("mage", hp: 16, low: 2, high: 3, speed: 9, sp: 16, power: 24)
        let archer = creature("archer", hp: 10, speed: 6, shots: 12)
        let pike = creature("pikeman", hp: 15, low: 3, high: 5, speed: 5)
        let wolf = creature("wolf", hp: 20, low: 3, high: 6, speed: 8, move: 14)
        let orc = creature("orc", hp: 12, speed: 6, shots: 10)
        return Battle(field: field, attackers: [hero, fighter(mage, 6, slot: 1), fighter(archer, 15, slot: 2), fighter(pike, 20, slot: 3)],
                      defenders: [fighter(wolf, 18, slot: 0), fighter(orc, 14, slot: 1), fighter(pike, 22, slot: 2)], seed: 4242,
                      tables: RuleTables(creatures: [mage, archer, pike, wolf, orc]))
    }
    func json<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(data: try! e.encode(v), encoding: .utf8)!
    }
    /// Every stack acts as the computer would until the battle ends (or `actions` are done).
    @discardableResult
    func play(_ b: Battle, actions: Int = 2000) -> [String] {
        var log: [String] = []
        var n = 0
        while b.finished == nil, n < actions {
            b.autoAct()
            log += b.takeEvents().map { "\($0)" }
            n += 1
        }
        return log
    }

    func testSnapshotThroughJSONRestoresTheBattleExactly() throws {
        let b = battle()
        _ = b.takeEvents()
        play(b, actions: 9)
        XCTAssertNil(b.finished, "the battle should still be going")
        XCTAssertTrue(b.canSnapshot)
        let saved = b.snapshot()
        let data = try JSONEncoder().encode(saved)
        let loaded = try JSONDecoder().decode(Battle.Snapshot.self, from: data)

        let c = battle()   // the battle started again from the same adventure
        _ = c.takeEvents()
        c.restore(loaded)
        XCTAssertEqual(json(c.snapshot()), json(saved))
        XCTAssertEqual(c.round, b.round)
        XCTAssertEqual(c.current?.id, b.current?.id)
        XCTAssertEqual(c.order, b.order)
        for (u, v) in zip(b.units, c.units) {
            XCTAssertEqual(u.stats.count, v.stats.count); XCTAssertEqual(u.stats.wounds, v.stats.wounds)
            XCTAssertEqual(u.x, v.x); XCTAssertEqual(u.y, v.y); XCTAssertEqual(u.facing, v.facing)
            XCTAssertEqual(u.caster?.spellPoints, v.caster?.spellPoints); XCTAssertEqual(u.stats.effects, v.stats.effects)
        }

        // both go on to the same end, blow for blow
        let rest1 = play(b), rest2 = play(c)
        XCTAssertNotNil(b.finished)
        XCTAssertEqual(rest1, rest2)
        XCTAssertEqual(b.finished, c.finished)
        XCTAssertEqual(json(b.snapshot()), json(c.snapshot()))
    }

    /// Spell effects, durations and spell-made ground survive the save.
    func testLastingStateSurvives() throws {
        let b = battle()
        _ = b.takeEvents()
        let u = b.units.first { $0.side == 1 }!
        u.stats.effects.insert(23); u.durations[23] = 3; u.powers[23] = 5; u.poison = 7; u.retaliated = true; u.martyr = 2
        u.stats.castAtStart = [(spell: 10, power: 3)]; u.stats.spellsOnHit = [(spell: 23, melee: true, ranged: false)]
        b.quicksand = [Battlefield.key(50, 50)]; b.smoke = [Battlefield.key(40, 41)]
        b.field.blockCell(45, 45)
        let s = try JSONDecoder().decode(Battle.Snapshot.self, from: JSONEncoder().encode(b.snapshot()))
        let c = battle()
        c.restore(s)
        let v = c.unit(u.id)
        XCTAssertEqual(v.stats.effects, u.stats.effects); XCTAssertEqual(v.durations, u.durations); XCTAssertEqual(v.powers, u.powers)
        XCTAssertEqual(v.poison, 7); XCTAssertTrue(v.retaliated); XCTAssertEqual(v.martyr, 2)
        XCTAssertEqual(v.stats.castAtStart.map { $0.spell }, [10]); XCTAssertEqual(v.stats.spellsOnHit.map { $0.melee }, [true])
        XCTAssertEqual(c.quicksand, b.quicksand); XCTAssertEqual(c.smoke, b.smoke)
        XCTAssertFalse(c.field.isOpen(45, 45))
    }

    /// Older saves have no `combat` and no monster bank tag: they read as adventure saves.
    func testSaveFormatStaysCompatible() throws {
        let scripts = SaveGame.ScriptSave(numbers: [:], flags: [:], messages: [], victoryText: nil, lossText: nil, standardVictoryOn: true,
                                          mapEventsEnabled: [], townEventsEnabled: [:])
        var s = SaveGame(mapPath: "x.h4c", day: 3, resources: [:], heroes: [], towns: [], mines: [], dwellings: [],
                         monsters: [SaveGame.MonsterState(x: 1, y: 2, name: "m", creature: "wolf", count: 5, extra: [], bank: "mine.0")],
                         removed: [], scripts: scripts, outcome: nil, victoryDays: nil)
        let b = battle()
        _ = b.takeEvents()
        s.combat = SaveGame.SavedCombat(kind: .monster, hero: 0, monster: 0, placed: .init(x: 1, y: 2, z: 0, name: "m"), battle: b.snapshot(),
                                        screen: .init(hidden: [3], alpha: [4: 10], decor: [.init(name: "rock", x: 1, y: 2, w: 3, h: 3)]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("combat_save_test.h4s")
        try s.write(to: url)
        let r = try SaveGame.read(url)
        XCTAssertEqual(r.combat?.kind, .monster); XCTAssertEqual(r.monsters.first?.bank, "mine.0")
        XCTAssertEqual(json(r.combat!.battle), json(b.snapshot()))
        XCTAssertEqual(r.combat?.screen?.alpha, [4: 10])
        // an adventure save from before: no such keys
        var dict = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        dict["combat"] = nil
        var ms = dict["monsters"] as! [[String: Any]]; ms[0]["bank"] = nil; dict["monsters"] = ms
        try JSONSerialization.data(withJSONObject: dict).write(to: url)
        let old = try SaveGame.read(url)
        XCTAssertNil(old.combat); XCTAssertNil(old.monsters.first?.bank)
        try? FileManager.default.removeItem(at: url)
    }
}
