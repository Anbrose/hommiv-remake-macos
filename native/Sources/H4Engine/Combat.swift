import Foundation

/// A unit in a fight: a creature stack or a hero.
public struct Combatant {
    public var name: String
    public var count: Int
    public var hitPoints: Int
    public var damageLow: Int, damageHigh: Int
    public var attack: Int, defense: Int
    public var speed: Int
    public var experience: Int          // awarded per unit killed
    public var wounds = 0               // damage already taken by the front unit
    public var isHero = false
    public var shooter = false          // has shots: its melee attack is halved unless it has "No Melee Penalty"
    public var noMeleePenalty = false
    public var defending = false        // Defend doubles the defense until the next turn
    /// Morale from the army's sources (heroes4.exe keeps two, +0xae8 and +0xaec on the combat creature).
    public var morale = 0
    /// The game's ability keywords ("first_strike", "no_retaliation", ...), from heroes4.exe's
    /// per-creature table (RuleTables.creatureAbilities).
    public var abilities: Set<String> = []
    public func has(_ ability: String) -> Bool { abilities.contains(ability.lowercased()) }
    public var level = 0
    public var alignment = ""
    /// Spell effects the creature abilities put on a stack (they last the battle unless noted).
    public var cursed = false          // Curse: minimum damage
    public var weakened = false        // Weakness: 25% less damage
    public var aged = false            // Aging: 25% less damage, defense -20%, speed and move halved
    public var bound = false           // Binding: half damage, cannot move

    public var alive: Bool { count > 0 }
    public var totalHealth: Int { count * hitPoints - wounds }

    /// Ability keywords of the game (normal_melee, siege_machine, ...), from the display names.
    public static var abilityKeywords: [String: String] = [:]

    public init(creature c: CreatureDef, count: Int) {
        name = c.name; self.count = count; hitPoints = c.hitPoints; damageLow = c.damageLow; damageHigh = c.damageHigh
        attack = c.attack; defense = c.defense; speed = c.speed; experience = c.experience
        level = c.level; alignment = c.alignment
        if let list = RuleTables.creatureAbilities[c.keyword.lowercased()] {
            abilities = Set(list)
        } else {   // not one of the exe's creatures: the table's display names
            let names = c.shortHelp.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            abilities = Set(names.compactMap { Combatant.abilityKeywords[$0]?.lowercased() })
        }
        shooter = c.shots > 0 || abilities.contains("ranged")
        noMeleePenalty = abilities.contains("normal_melee")
    }

    /// A hero as heroes4.exe rates one (verified in an emulator against the exe): hit points
    /// 10 x level + 90 (0x72a1f0), damage (16L-16)/10+16 to (24L-24)/10+24 (0x72a090 / 0x72a130),
    /// attack and defense from the Melee, Archery and Combat skills (0x732090 / 0x731ff0, shown x10:
    /// melee 1, 1.5, 2, 3, 4, 4; ranged 0.7, 1, 1.5, 2, 3, 3; defense 1, 1.5, 2, 3, 4, 6), speed 6
    /// (0x72a270), 12 shots with Archery, 24 at grandmaster (0x72a2f0).
    public init(hero name: String, level: Int, skills: [String: Int] = [:]) {
        func sk(_ k: String) -> Int { max(0, min(5, skills[k] ?? 0)) }
        let melee = [10, 15, 20, 30, 40, 40], ranged = [7, 10, 15, 20, 30, 30], def = [10, 15, 20, 30, 40, 60]
        self.name = name; count = 1
        hitPoints = 10 * level + 90
        damageLow = (16 * level - 16) / 10 + 16; damageHigh = (24 * level - 24) / 10 + 24
        attack = melee[sk("combat")]; defense = def[sk("toughness")]; speed = 6; experience = 0; isHero = true
        rangedAttack = ranged[sk("archery")]
        shooter = sk("archery") > 0; noMeleePenalty = true
        shots = sk("archery") == 0 ? 0 : sk("archery") == 5 ? 24 : 12
    }
    /// A hero's ranged attack (its Archery), when it differs from the melee one.
    public var rangedAttack: Int? = nil
    public var shots = 0

    /// Take `damage` hit points, killing whole units from the front.
    public mutating func take(_ damage: Int) -> Int {
        var d = damage + wounds
        let killed = min(count, d / hitPoints)
        count -= killed
        d -= killed * hitPoints
        wounds = count > 0 ? d : 0
        return killed
    }
}

/// The game's random stream: the C runtime's LCG (x = x * 214013 + 2531011, take bits 16..30),
/// as heroes4.exe uses for its rolls (the combat one is seeded per battle and seekable so that
/// replays and network games agree).
public struct GameRandom {
    var state: UInt32
    public init(seed: Int) { state = UInt32(truncatingIfNeeded: seed) }
    public mutating func next() -> Int {
        state = state &* 214013 &+ 2531011
        return Int((state >> 16) & 0x7fff)
    }
    /// A roll in low...high, as the game does it: `next() % (high - low + 1) + low`.
    public mutating func roll(_ low: Int, _ high: Int) -> Int { high > low ? next() % (high - low + 1) + low : low }
}

/// Combat with the damage rules read from heroes4.exe (the creature's damage routine):
/// - the base damage is one roll between the creature's low and high damage per unit,
///   summed; a stack of ten or more rolls ten times and scales the sum by count / 10
/// - the base is scaled by attack / defense (attack and defense already carry their
///   percentage bonuses, a defending creature's defense is doubled, a shooter's melee attack
///   is halved unless it has No Melee Penalty); the ratio has a floor of 0.05 and no ceiling
/// - the result is rounded, at least 1
public enum QuickCombat {
    /// The rolled base damage of a stack (before attack/defense).
    public static func rollBase(_ a: Combatant, rng: inout GameRandom) -> Int {
        let high = a.cursed ? a.damageLow : a.damageHigh   // Curse: minimum damage
        if a.count >= 10 {
            var sum = 0
            for _ in 0..<10 { sum += rng.roll(a.damageLow, high) }
            return sum * a.count / 10
        }
        var sum = 0
        for _ in 0..<max(0, a.count) { sum += rng.roll(a.damageLow, high) }
        return sum
    }

    /// Damage of `a` hitting `b` with an already rolled base (heroes4.exe 0x5ee380):
    /// - Charge: a melee blow after moving more than 5 cells (500 move points, a cell being 100)
    ///   does (85 + points / 35)% of the base
    /// - Giantslayer (melee or ranged kind) doubles the base against 4th level creatures
    /// - the attack / defense ratio (floor 0.05): a shooter's melee attack is halved without
    ///   Normal Melee, Weakness and Aging take 25% off, Binding half; defense doubles when
    ///   defending, for Insubstantial, and against shots for Skeletal, Aging takes 20% off
    /// - a Ward against the attacker's alignment leaves 2/3; Fire (fire, breath attacks, Greek
    ///   fire) against Fire Resistance and Cold against Cold Resistance halve
    /// - Block takes 30% off what lands (0x5ee990: x 7 / 10, rounded), at least 1
    public static func damage(_ a: Combatant, _ b: Combatant, base: Int, ranged: Bool, moved: Int = 0) -> Int {
        var base = base
        let points = moved * 100
        if !ranged, a.has("charging"), points > 500 { base = base * (points * 10 / 350 + 85) / 100 }
        if b.level == 4, a.has("giantslayer") || a.has(ranged ? "ranged_giantslayer" : "melee_giantslayer") { base *= 2 }
        var attack = Float(ranged ? (a.rangedAttack ?? a.attack) : a.attack)
        if !ranged, a.shooter, !a.noMeleePenalty { attack *= 0.5 }
        if a.weakened { attack *= 0.75 }
        if a.aged { attack *= 0.75 }
        if a.bound { attack *= 0.5 }
        var defense = Float(max(1, b.defense)) * (b.defending ? 2 : 1)
        if b.has("insubstantial") { defense *= 2 }
        if ranged, b.has("skeletal") { defense *= 2 }
        if b.aged { defense *= 0.8 }
        let ratio = max(0.05, attack / defense)
        var d = Int((Float(base) * ratio).rounded())
        let ward = ["life": "life_protection", "death": "death_protection", "chaos": "chaos_protection"][a.alignment]
        if let w = ward, b.has(w) { d = d * 100 / 150 }
        if a.has("fire_attack") || a.has("breath_attack") || a.has("arc_breath_attack") || (ranged && a.has("large_area_effect")), b.has("fire_resistance") { d >>= 1 }
        if a.has("cold_attack"), b.has("cold_resistance") { d >>= 1 }
        d = max(1, d)
        if b.has("block") { d = (d * 7 + 5) / 10 }
        return max(1, d)
    }

    public static func damage(_ a: Combatant, _ b: Combatant, rng: inout GameRandom, ranged: Bool = false, moved: Int = 0) -> Int {
        damage(a, b, base: rollBase(a, rng: &rng), ranged: ranged, moved: moved)
    }

    /// The damage range shown before an attack ("Attack X for N-M damage").
    public static func damageRange(_ a: Combatant, _ b: Combatant, ranged: Bool) -> (Int, Int) {
        (damage(a, b, base: a.damageLow * a.count, ranged: ranged), damage(a, b, base: (a.cursed ? a.damageLow : a.damageHigh) * a.count, ranged: ranged))
    }
    public struct Result {
        public let attackerWon: Bool
        public let attackers: [Combatant]     // survivors (counts updated)
        public let defenders: [Combatant]
        public let rounds: Int
        public let experience: Int            // for the attacker, from every defender unit killed
        public let log: [String]
    }

    public static func fight(attackers: [Combatant], defenders: [Combatant], seed: Int) -> Result {
        var a = attackers, d = defenders
        var rng = GameRandom(seed: seed)
        var log: [String] = []
        var xp = 0
        var rounds = 0
        while rounds < 50, a.contains(where: { $0.alive }), d.contains(where: { $0.alive }) {
            rounds += 1
            // every living unit acts once per round, fastest first; it hits the enemy stack that hurts most
            var order: [(side: Int, index: Int, speed: Int)] = []
            for (i, u) in a.enumerated() where u.alive { order.append((0, i, u.speed)) }
            for (i, u) in d.enumerated() where u.alive { order.append((1, i, u.speed)) }
            order.sort { $0.speed > $1.speed }
            for act in order {
                let attacker = act.side == 0 ? a[act.index] : d[act.index]
                guard attacker.alive else { continue }
                let targets = act.side == 0 ? d : a
                guard let ti = targets.indices.filter({ targets[$0].alive }).max(by: { threat(targets[$0]) < threat(targets[$1]) }) else { break }
                let dmg = damage(attacker, targets[ti], rng: &rng, ranged: attacker.shooter)
                var killed = 0
                if act.side == 0 { killed = d[ti].take(dmg); xp += killed * d[ti].experience } else { killed = a[ti].take(dmg) }
                log.append("\(attacker.name) x\(attacker.count) hits \(targets[ti].name) for \(dmg), kills \(killed)")
            }
        }
        return Result(attackerWon: !d.contains { $0.alive }, attackers: a, defenders: d, rounds: rounds, experience: xp, log: log)
    }

    static func threat(_ u: Combatant) -> Float { Float(u.count) * Float(u.damageLow + u.damageHigh) / 2 * Float(u.attack) }
}
