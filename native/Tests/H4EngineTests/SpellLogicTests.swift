import XCTest
@testable import H4Engine

/// Combat spell rules read from heroes4.exe (combat_spell_logic_audit: power 0x865200, creature
/// casters 0x656c20, summons 0x87c750, raising 0x8058f0, areas 0x717030, ...).
final class SpellLogicTests: XCTestCase {
    func creature(_ keyword: String, level: Int = 1, alignment: String = "might", hp: Int = 10, low: Int = 2, high: Int = 2,
                  attack: Int = 10, defense: Int = 10, speed: Int = 5, exp: Int = 1, sp: Int = 0, power: Int = 0, move: Int = 10) -> CreatureDef {
        var c = CreatureDef(keyword: keyword, name: keyword, plural: keyword, level: level, alignment: alignment, hitPoints: hp, damageLow: low, damageHigh: high,
                            attack: attack, defense: defense, move: move, speed: speed, growth: 1, gold: 1, experience: exp, shots: 0, spellPoints: sp,
                            shortHelp: "", longHelp: "")
        c.spellPower = power
        return c
    }
    func fighter(_ c: CreatureDef, _ n: Int, size: Int = 2) -> Battle.Fighter {
        Battle.Fighter(stats: Combatant(creature: c, count: n), keyword: c.keyword, actor: c.keyword, size: size, move: c.move, shots: 0)
    }
    var field: Battlefield { Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1) }
    func hero(level: Int = 10, skills: [String: Int] = [:], spells: [Int], sp: Int = 100) -> Battle.Fighter {
        var st = Combatant(hero: "hero", level: level)
        st.speed = 30
        return Battle.Fighter(stats: st, keyword: "hero", actor: "hero", size: 2, move: 10, shots: 0,
                              caster: Caster(level: level, skills: skills, spells: spells, spellPoints: sp))
    }

    // MARK: creature casters

    /// Creature casters come from 0x656c20, with the stack's own spell points (not per creature).
    func testCreatureCastersFromTheExeTable() {
        let mage = creature("mage", hp: 16, speed: 9, sp: 16, power: 24)
        let b = Battle(field: field, attackers: [fighter(mage, 10)], defenders: [fighter(creature("peasant"), 5)], seed: 1)
        let u = b.units.first { $0.side == 0 }!
        XCTAssertEqual(u.caster?.spells, [72, 23, 111, 125, 109])
        XCTAssertEqual(u.caster?.spellPoints, 16)
        XCTAssertEqual(u.caster?.defaultSpell, 72)
        XCTAssertTrue(u.caster?.creature == true)
        // Magic Fist (20 + 2 x level, Dmg): level 0, pct = Spell Power x pct x count / 100 = 240
        XCTAssertEqual(b.power(72, by: u), 48)
        // Curse has no Dmg / Summ flag: plain pct
        XCTAssertEqual(b.power(23, by: u), 0)
        XCTAssertNil(b.units.first { $0.side == 1 }!.caster)
    }

    /// The computer casts with creature casters too (the mages open with a spell).
    func testCreatureCasterAICasts() {
        let mage = creature("mage", hp: 16, low: 1, high: 1, speed: 9, sp: 16, power: 24)
        let b = Battle(field: field, attackers: [fighter(mage, 20)], defenders: [fighter(creature("peasant", speed: 1), 30)], seed: 1)
        _ = b.takeEvents()
        b.autoAct()
        let cast = b.takeEvents().contains { if case .cast = $0 { return true }; return false }
        XCTAssertTrue(cast)
        XCTAssertLessThan(b.units.first { $0.side == 0 }!.caster!.spellPoints, 16)
    }

    // MARK: summons

    /// A battle whose rule tables know the given creatures.
    func tables(_ cs: [CreatureDef]) -> RuleTables { RuleTables(creatures: cs) }

    /// Summons divide by the creature's Experience (0x865284: Earth Elemental 77): a level 10 hero
    /// with no Nature power summons (150 + 15 x 10) / 77 = 3; a second cast adds to that stack (0x577fc0).
    func testSummonCountUsesExperienceAndMerges() {
        let earth = creature("earth elemental", level: 3, hp: 50, exp: 77)
        let b = Battle(field: field, attackers: [hero(level: 10, skills: ["nature": 3], spells: [163])], defenders: [fighter(creature("peasant", speed: 1), 5)],
                       seed: 1, tables: tables([earth]))
        let h = b.units.first { $0.side == 0 }!
        XCTAssertEqual(b.power(163, by: h), 3)
        XCTAssertTrue(b.cast(163, on: nil))
        let summoned = b.units.filter { $0.summoned }
        XCTAssertEqual(summoned.count, 1)
        XCTAssertEqual(summoned.first?.stats.count, 3)
        // round 2: the hero again
        while let u = b.current, u.id != h.id { b.defend() }
        XCTAssertTrue(b.cast(163, on: nil))
        XCTAssertEqual(b.units.filter { $0.summoned }.count, 1)
        XCTAssertEqual(b.units.first { $0.summoned }?.stats.count, 6)
    }

    /// The archdevil's Summon Ice Demon (base 157 = the ice demon's Experience): one ice demon per devil.
    func testArchdevilSummonsOneIceDemonPerDevil() {
        let devil = creature("archdevil", level: 4, hp: 210, speed: 9, exp: 614, sp: 8, power: 100)
        let ice = creature("ice demon", level: 3, hp: 70, exp: 157)
        let b = Battle(field: field, attackers: [fighter(devil, 7)], defenders: [fighter(creature("peasant", speed: 1), 5)], seed: 1, tables: tables([ice]))
        XCTAssertEqual(b.power(160, by: b.units.first { $0.side == 0 }!), 7)
    }

    /// Phantom Image (0x87d050): ceil(power / the copied creature's hit points) copies, on the caster's side.
    func testPhantomImageCount() {
        let troll = creature("troll", level: 3, hp: 40)
        let b = Battle(field: field, attackers: [hero(level: 10, skills: ["order": 4], spells: [18])], defenders: [fighter(troll, 5)], seed: 1, tables: tables([troll]))
        let h = b.units.first { $0.side == 0 }!, t = b.units.first { $0.side == 1 }!
        XCTAssertEqual(b.power(18, by: h), 160)             // (80 + 8 x 10) x (100 + 0) / 100
        XCTAssertTrue(b.cast(18, on: t.id))
        let ph = b.units.first { $0.summoned }!
        XCTAssertEqual(ph.side, 0)
        XCTAssertEqual(ph.stats.count, 4)
        XCTAssertEqual(ph.keyword, "troll")
    }

    // MARK: raising and resurrection

    /// Raise Skeletons (0x8067b0): min(power / Experience, the dead, ceil(dead x HP / skeleton HP));
    /// the bodies used are gone and the skeletons join the caster.
    func testRaiseSkeletonsCapsByHitPoints() {
        let skel = creature("skeleton", hp: 8, exp: 6), imp = creature("imp", hp: 4)
        let b = Battle(field: field, attackers: [hero(level: 10, skills: ["death": 1], spells: [125])], defenders: [fighter(imp, 20), fighter(creature("peasant", speed: 1), 5)],
                       seed: 1, tables: tables([skel, imp]))
        let h = b.units.first { $0.side == 0 }!, corpse = b.units.first { $0.keyword == "imp" }!
        corpse.stats.count = 0; corpse.deathHandled = true
        XCTAssertEqual(b.power(125, by: h), 13)               // (40 + 4 x 10) / 6
        XCTAssertTrue(b.canTarget(125, by: h, corpse))
        XCTAssertTrue(b.cast(125, on: corpse.id))
        let raised = b.units.first { $0.keyword == "skeleton" }!
        XCTAssertEqual(raised.side, 0)
        XCTAssertEqual(raised.stats.count, 10)                // ceil(20 x 4 / 8)
        XCTAssertEqual(b.deadCount(corpse), 0)                // all 20 bodies used
        XCTAssertFalse(b.canTarget(125, by: h, corpse))
    }

    /// Resurrection (0x804020): power 92 x pct, capped by the wounds plus the dead it can have back.
    func testResurrectionCap() {
        let squire = creature("squire", alignment: "life", hp: 10)
        let b = Battle(field: field, attackers: [hero(level: 10, skills: ["life": 5], spells: [133]), fighter(squire, 10)], defenders: [fighter(creature("peasant", speed: 1), 5)],
                       seed: 1, tables: tables([squire]))
        let h = b.units.first { $0.stats.isHero }!, sq = b.units.first { $0.keyword == "squire" }!
        sq.stats.count = 7; sq.stats.wounds = 4
        XCTAssertEqual(b.power(133, by: h), 92)
        XCTAssertTrue(b.cast(133, on: sq.id))
        XCTAssertEqual(sq.stats.count, 10)
        XCTAssertEqual(sq.stats.wounds, 0)
    }

    /// Archangels resurrect Spell Power x count: 92 x 100 x 2 / 100 per cast for two of them.
    func testArchangelResurrectionPower() {
        let angel = creature("archangel", level: 4, hp: 230, speed: 9, sp: 20, power: 100)
        let b = Battle(field: field, attackers: [fighter(angel, 2)], defenders: [fighter(creature("peasant", speed: 1), 5)], seed: 1)
        XCTAssertEqual(b.power(133, by: b.units.first { $0.side == 0 }!), 184)
    }

    /// Rebirth (0x5f53c0 / 0x5ebed0): a wiped Phoenix stack gets 55 x its starting count hit
    /// points back once (it costs all 12 of its spell points).
    func testPhoenixRebirth() {
        let phoenix = creature("phoenix", level: 4, hp: 275, speed: 1, sp: 12)
        let b = Battle(field: field, attackers: [fighter(creature("peasant", speed: 9), 5)], defenders: [fighter(phoenix, 5)], seed: 1)
        let ph = b.units.first { $0.side == 1 }!
        ph.stats.count = 0
        b.checkEnd()
        XCTAssertEqual(ph.stats.count, 1)                     // 275 hit points = one phoenix
        XCTAssertEqual(ph.caster?.spellPoints, 0)
        ph.stats.count = 0
        b.checkEnd()
        XCTAssertEqual(ph.stats.count, 0)                     // no spell points left
    }

    /// Animate Dead raises the corpse's own undead creature, power in hit points.
    func testAnimateDeadUndeadOnly() {
        let skel = creature("skeleton", hp: 8), peasant = creature("peasant", speed: 1)
        let b = Battle(field: field, attackers: [hero(level: 10, skills: ["death": 2], spells: [2])], defenders: [fighter(skel, 20), fighter(peasant, 5)],
                       seed: 1, tables: tables([skel, peasant]))
        let h = b.units.first { $0.side == 0 }!
        let sk = b.units.first { $0.keyword == "skeleton" }!, pe = b.units.first { $0.keyword == "peasant" }!
        sk.stats.count = 0; sk.deathHandled = true; pe.stats.count = 0; pe.deathHandled = true
        XCTAssertFalse(b.canTarget(2, by: h, pe))
        XCTAssertTrue(b.canTarget(2, by: h, sk))
        XCTAssertTrue(b.cast(2, on: sk.id))                    // 100 hit points: 13 skeletons
        XCTAssertEqual(b.units.first { $0.keyword == "skeleton" && $0.side == 0 }?.stats.count, 13)
    }

    // MARK: areas

    /// A battle with the hero and three stacks placed by hand.
    func areaBattle(spells: [Int], enemies: [CreatureDef]) -> (Battle, Battle.Unit, [Battle.Unit]) {
        let b = Battle(field: field, attackers: [hero(level: 10, skills: ["chaos": 5, "order": 5], spells: spells, sp: 200)], defenders: enemies.map { fighter($0, 10) }, seed: 1)
        let h = b.units.first { $0.side == 0 }!
        let es = b.units.filter { $0.side == 1 }
        return (b, h, es)
    }

    /// Fireball (0x717030 / 0x718320): any cell, round(distance to the footprint centre) - size x 8 < 64;
    /// Inferno 112; fire-immune stacks are left out (validity 0x5b63d0).
    func testFireballAndInfernoRadii() {
        let (b, h, es) = areaBattle(spells: [43, 66], enemies: [creature("peasant", speed: 1), creature("fire elemental", speed: 1), creature("orc", speed: 1)])
        h.x = 10; h.y = 10
        es[0].x = 50; es[0].y = 50          // centre (816, 816)
        es[1].x = 53; es[1].y = 50          // fire elemental, right next to it
        es[2].x = 70; es[2].y = 70
        let near = b.castTargets(43, by: h, target: nil, cell: (55, 51))!.map { $0.id }   // 72 away: 72 - 16 = 56 < 64
        XCTAssertEqual(near, [es[0].id])
        XCTAssertEqual(b.castTargets(43, by: h, target: nil, cell: (56, 51))!.map { $0.id }.contains(es[0].id), false)   // 88 - 16 = 72
        XCTAssertTrue(b.castTargets(66, by: h, target: nil, cell: (56, 51))!.contains { $0.id == es[0].id })              // Inferno: 112
        XCTAssertTrue(b.cast(43, on: nil, cell: (55, 51)))
        XCTAssertLessThan(es[0].stats.totalHealth, 100)
        XCTAssertEqual(es[1].stats.totalHealth, 100)
    }

    /// Fire Ring on a stack: 48 + its size x 8 around its centre, the stack itself spared (0x715c50).
    func testFireRingSparesItsTarget() {
        let (b, h, es) = areaBattle(spells: [41], enemies: [creature("peasant", speed: 1), creature("orc", speed: 1), creature("troll", speed: 1)])
        h.x = 10; h.y = 10
        es[0].x = 50; es[0].y = 50; es[1].x = 52; es[1].y = 52; es[2].x = 60; es[2].y = 50
        XCTAssertEqual(b.castTargets(41, by: h, target: es[0].id, cell: nil)!.map { $0.id }, [es[1].id])
    }

    /// Armageddon spares the caster (0x5b4b26); Chain Lightning jumps only to stacks it can affect.
    func testArmageddonAndChainLightningTargets() {
        let (b, h, es) = areaBattle(spells: [4, 17], enemies: [creature("peasant", speed: 1), creature("black dragon", speed: 1), creature("orc", speed: 1)])
        XCTAssertFalse(b.castTargets(4, by: h, target: nil, cell: nil)!.contains { $0.id == h.id })
        h.x = 10; h.y = 10
        es[0].x = 50; es[0].y = 50; es[1].x = 53; es[1].y = 50; es[2].x = 60; es[2].y = 50
        XCTAssertTrue(b.cast(17, on: es[0].id))
        XCTAssertEqual(es[1].stats.totalHealth, 100)             // magic immune: skipped
        XCTAssertLessThan(es[2].stats.totalHealth, 100)          // the jump goes on past it
    }

    /// Sparks (0x866160): the half disc in front of the caster, not behind it.
    func testSparksHalfDisc() {
        let (b, h, es) = areaBattle(spells: [14], enemies: [creature("peasant", speed: 1), creature("orc", speed: 1), creature("troll", speed: 1)])
        h.x = 50; h.y = 50
        es[0].x = 52; es[0].y = 50; es[1].x = 47; es[1].y = 50; es[2].x = 52; es[2].y = 52
        let ids = Set(b.sparksTargets(by: h, facing: 0).map { $0.id })
        XCTAssertEqual(ids, [es[0].id, es[2].id])
    }

    // MARK: speed

    /// Haste / Speed: +3 speed, +900 move points = 9 cells (0x5edac7 / 0x5efc13); the Speed
    /// Potion +3 speed more, no move (0x5edac4); Slow halves after.
    func testHasteMovesNineCellsMore() {
        let b = Battle(field: field, attackers: [fighter(creature("squire", speed: 5, move: 5), 1)], defenders: [fighter(creature("peasant", speed: 1), 1)], seed: 1)
        let u = b.units.first { $0.side == 0 }!
        u.stats.effects = [55]
        XCTAssertEqual(b.speed(u), 8); XCTAssertEqual(b.moveCells(u), 14)
        u.stats.effects = [55, 146]
        XCTAssertEqual(b.speed(u), 11); XCTAssertEqual(b.moveCells(u), 14)
        u.stats.effects = [104, 105]
        XCTAssertEqual(b.speed(u), 4); XCTAssertEqual(b.moveCells(u), 7)
    }
}
