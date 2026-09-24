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

    public var alive: Bool { count > 0 }
    public var totalHealth: Int { count * hitPoints - wounds }

    public init(creature c: CreatureDef, count: Int) {
        name = c.name; self.count = count; hitPoints = c.hitPoints; damageLow = c.damageLow; damageHigh = c.damageHigh
        attack = c.attack; defense = c.defense; speed = c.speed; experience = c.experience
        shooter = c.shots > 0; noMeleePenalty = c.shortHelp.lowercased().contains("no melee penalty")
    }

    /// A hero of the given level fights as one strong unit.
    public init(hero name: String, level: Int) {
        self.name = name; count = 1; hitPoints = 40 + 10 * level; damageLow = 6 + 2 * level; damageHigh = 10 + 3 * level
        attack = 10 + 2 * level; defense = 10 + 2 * level; speed = 5; experience = 0; isHero = true
    }

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
        if a.count >= 10 {
            var sum = 0
            for _ in 0..<10 { sum += rng.roll(a.damageLow, a.damageHigh) }
            return sum * a.count / 10
        }
        var sum = 0
        for _ in 0..<max(0, a.count) { sum += rng.roll(a.damageLow, a.damageHigh) }
        return sum
    }

    /// Damage of `a` hitting `b` with an already rolled base.
    public static func damage(_ a: Combatant, _ b: Combatant, base: Int, ranged: Bool) -> Int {
        var attack = Float(a.attack)
        if !ranged, a.shooter, !a.noMeleePenalty { attack *= 0.5 }
        let defense = Float(max(1, b.defense)) * (b.defending ? 2 : 1)
        let ratio = max(0.05, attack / defense)
        return max(1, Int((Float(base) * ratio).rounded()))
    }

    public static func damage(_ a: Combatant, _ b: Combatant, rng: inout GameRandom, ranged: Bool = false) -> Int {
        damage(a, b, base: rollBase(a, rng: &rng), ranged: ranged)
    }

    /// The damage range shown before an attack ("Attack X for N-M damage").
    public static func damageRange(_ a: Combatant, _ b: Combatant, ranged: Bool) -> (Int, Int) {
        (damage(a, b, base: a.damageLow * a.count, ranged: ranged), damage(a, b, base: a.damageHigh * a.count, ranged: ranged))
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
