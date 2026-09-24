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

    public var alive: Bool { count > 0 }
    public var totalHealth: Int { count * hitPoints - wounds }

    public init(creature c: CreatureDef, count: Int) {
        name = c.name; self.count = count; hitPoints = c.hitPoints; damageLow = c.damageLow; damageHigh = c.damageHigh
        attack = c.attack; defense = c.defense; speed = c.speed; experience = c.experience
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

/// Quick (automatic) combat with the HoMM IV damage rule: a stack's damage is its units times
/// a roll between low and high, scaled by attack/defence (clamped to 1/4 .. 4).
public enum QuickCombat {
    public struct Result {
        public let attackerWon: Bool
        public let attackers: [Combatant]     // survivors (counts updated)
        public let defenders: [Combatant]
        public let rounds: Int
        public let experience: Int            // for the attacker, from every defender unit killed
        public let log: [String]
    }

    static func damage(_ a: Combatant, _ b: Combatant, roll: Float) -> Int {
        let per = Float(a.damageLow) + Float(a.damageHigh - a.damageLow) * roll
        let ratio = max(0.25, min(4, Float(a.attack) / Float(max(1, b.defense))))
        return max(1, Int((per * Float(a.count) * ratio).rounded()))
    }

    public static func fight(attackers: [Combatant], defenders: [Combatant], seed: Int) -> Result {
        var a = attackers, d = defenders
        var rng = UInt64(truncatingIfNeeded: seed &* 6364136223846793005 &+ 1442695040888963407)
        func rand() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float((rng >> 33) % 1000) / 1000 }
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
                let dmg = damage(attacker, targets[ti], roll: rand())
                var killed = 0
                if act.side == 0 { killed = d[ti].take(dmg); xp += killed * d[ti].experience } else { killed = a[ti].take(dmg) }
                log.append("\(attacker.name) x\(attacker.count) hits \(targets[ti].name) for \(dmg), kills \(killed)")
            }
        }
        return Result(attackerWon: !d.contains { $0.alive }, attackers: a, defenders: d, rounds: rounds, experience: xp, log: log)
    }

    static func threat(_ u: Combatant) -> Float { Float(u.count) * Float(u.damageLow + u.damageHigh) / 2 * Float(u.attack) }
}
