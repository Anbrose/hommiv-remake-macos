import XCTest
@testable import H4Engine

/// The order of the blows of an exchange (heroes4.exe 0x56ef40 melee, 0x5695b0 ranged; re/blow_sequence_spec.md).
final class BlowOrderTests: XCTestCase {
    func creature(_ keyword: String, hp: Int = 50, dmg: Int = 2, shots: Int = 0, fast: Bool = true) -> CreatureDef {
        CreatureDef(keyword: keyword, name: keyword, plural: keyword, level: 1, alignment: "might", hitPoints: hp, damageLow: dmg, damageHigh: dmg,
                    attack: 10, defense: 10, move: 10, speed: fast ? 5 : 1, growth: 1, gold: 1, experience: 1, shots: shots, spellPoints: 0,
                    shortHelp: "", longHelp: "")
    }
    func fighter(_ k: String, _ n: Int, hp: Int = 50, dmg: Int = 2, shots: Int = 0, fast: Bool) -> Battle.Fighter {
        Battle.Fighter(stats: Combatant(creature: creature(k, hp: hp, dmg: dmg, shots: shots, fast: fast), count: n), keyword: k, actor: k, size: 2, move: 60, shots: shots)
    }
    /// A battle of one attacker at `from` against one defender at (50, 50), the attacker to act.
    func battle(_ a: Battle.Fighter, _ d: Battle.Fighter, from: (Int, Int)) -> (Battle, Battle.Unit, Battle.Unit) {
        let field = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
        let b = Battle(field: field, attackers: [a], defenders: [d], seed: 3)
        _ = b.takeEvents()
        let u = b.units.first { $0.side == 0 }!, t = b.units.first { $0.side == 1 }!
        t.x = 50; t.y = 50; u.x = from.0; u.y = from.1
        return (b, u, t)
    }
    /// The blows and markers in order: "A>B" a melee blow, "A)B" a shot, "+" together, "xB" a death, "fx:name@B".
    func order(_ b: Battle, _ names: [Int: String]) -> [String] {
        b.takeEvents().compactMap { e in
            switch e {
            case .melee(let a, let t, _, _, _): return "\(names[a]!)>\(names[t]!)"
            case .shoot(let a, let t, _, _, _): return "\(names[a]!))\(names[t]!)"
            case .together: return "+"
            case .die(let u): return "x\(names[u]!)"
            case .effect(let u, let n, _, _, _): return "fx:\(n)@\(names[u]!)"
            case .blocked(let u): return "block\(names[u]!)"
            default: return nil
            }
        }
    }

    /// Without First Strike both strike together; a First Strike defender strikes first only when the
    /// attacker moved to attack (bf+0x314 >= 4, 0x56f0b5).
    func testFirstStrikeDefenderOnlyAgainstAMovedAttacker() {
        do {
            let (b, u, t) = battle(fighter("squire", 5, fast: true), fighter("nomad", 5, fast: false), from: (48, 50))
            let facing = t.facing
            XCTAssertTrue(b.attack(t.id))
            XCTAssertEqual(order(b, [u.id: "A", t.id: "B"]), ["A>B", "+", "B>A"])
            XCTAssertEqual(t.facing, facing)   // the target turns only as its swing plays (the playback turns it)
        }
        do {
            let (b, u, t) = battle(fighter("squire", 5, fast: true), fighter("nomad", 5, fast: false), from: (40, 50))
            XCTAssertTrue(b.attack(t.id))
            XCTAssertEqual(order(b, [u.id: "A", t.id: "B"]), ["B>A", "A>B"])
        }
    }

    /// The simultaneous exchange rolls both blows before either aftermath (0x575fe0 at each swing's start,
    /// bf+0x478 after): Fire Shield's burn of the attacker comes after the target's blow back.
    func testSimultaneousAftermathAfterBothBlows() {
        let (b, u, t) = battle(fighter("squire", 5, fast: true), fighter("efreet", 5, fast: false), from: (48, 50))
        XCTAssertTrue(b.attack(t.id))
        let o = order(b, [u.id: "A", t.id: "B"])
        XCTAssertEqual(Array(o.prefix(3)), ["A>B", "+", "B>A"])
        XCTAssertTrue(o.dropFirst(3).contains("fx:fire shield@A"), "\(o)")
    }

    /// A shooter shot at shoots back at once, with the stack it had before the shot landed, even when the
    /// shot kills it (0x5695b0 -> 0x568ee0).
    func testRangedRetaliationIsSimultaneous() {
        let (b, u, t) = battle(fighter("crossbowman", 10, hp: 10, dmg: 50, shots: 10, fast: true), fighter("crossbowman", 1, hp: 1, dmg: 1, shots: 10, fast: false), from: (20, 50))
        let health = u.stats.totalHealth
        XCTAssertTrue(b.shoot(t.id))
        XCTAssertFalse(t.alive)
        XCTAssertEqual(order(b, [u.id: "A", t.id: "B"]), ["A)B", "+", "B)A", "xB"])
        XCTAssertLessThan(u.stats.totalHealth, health)
    }

    /// Ranged First Strike puts the shooter that has it first, answered afterwards (0x5696f2); on the
    /// target it only cancels the other's priority: the two shoot together.
    func testRangedFirstStrike() {
        do {
            let (b, u, t) = battle(fighter("elf", 5, shots: 10, fast: true), fighter("crossbowman", 5, shots: 10, fast: false), from: (20, 50))
            XCTAssertTrue(b.shoot(t.id))
            XCTAssertEqual(Array(order(b, [u.id: "A", t.id: "B"]).prefix(2)), ["A)B", "B)A"])
        }
        do {
            let (b, u, t) = battle(fighter("crossbowman", 5, shots: 10, fast: true), fighter("elf", 5, shots: 10, fast: false), from: (20, 50))
            XCTAssertTrue(b.shoot(t.id))
            XCTAssertEqual(order(b, [u.id: "A", t.id: "B"]), ["A)B", "+", "B)A"])
        }
    }

    /// Block (0x5f3f20 / 0x575fe0): the stack about to be struck blocks 30% of blows with the ability, a
    /// blocked blow does nothing, and a block puts the attacker first, answered after (0x56f08d).
    func testBlock() {
        var blocks = 0, trials = 0
        for seed in 1...200 {
            let field = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
            let b = Battle(field: field, attackers: [fighter("squire", 5, fast: true)], defenders: [fighter("minotaur", 5, fast: false)], seed: seed)
            _ = b.takeEvents()
            let u = b.units.first { $0.side == 0 }!, t = b.units.first { $0.side == 1 }!
            t.x = 50; t.y = 50; u.x = 48; u.y = 50
            let health = t.stats.totalHealth
            XCTAssertTrue(b.attack(t.id))
            let o = order(b, [u.id: "A", t.id: "B"])
            trials += 1
            if o.contains("blockB") {
                blocks += 1
                XCTAssertEqual(Array(o.prefix(3)), ["A>B", "blockB", "B>A"], "\(o)")
                XCTAssertEqual(t.stats.totalHealth, health)
            } else {
                XCTAssertEqual(Array(o.prefix(3)), ["A>B", "+", "B>A"], "\(o)")
            }
        }
        XCTAssertGreaterThan(blocks, trials / 5); XCTAssertLessThan(blocks, trials * 2 / 5)
        // no block chance without the ability
        let (b, u, t) = battle(fighter("squire", 5, fast: true), fighter("skeleton", 5, fast: false), from: (48, 50))
        for _ in 0..<50 { b.rollBlock(t); XCTAssertFalse(t.blocking) }
        _ = u
    }

    /// In a melee exchange a stack wiped out before its own swing reaches its hit frame lands nothing
    /// (its die resets its pose at once, 0x564480, and the cut swing ends without its hit, 0x7dd1b5).
    func testWipedOutBeforeItsHitLandsNothing() {
        for (peasantFirst, struck) in [(false, false), (true, true)] {
            let (b, u, t) = battle(fighter("squire", 10, hp: 100, dmg: 100, fast: true), fighter("peasant", 3, hp: 1, dmg: 10, fast: false), from: (48, 50))
            b.meleeHitTime = { $0.keyword == "peasant" ? (peasantFirst ? 0.2 : 0.5) : 0.4 }
            let health = u.stats.totalHealth
            XCTAssertTrue(b.attack(t.id))
            XCTAssertFalse(t.alive)
            XCTAssertEqual(order(b, [u.id: "A", t.id: "B"]).prefix(4), ["A>B", "+", "B>A", "xB"])
            XCTAssertEqual(u.stats.totalHealth < health, struck)
        }
    }
}
