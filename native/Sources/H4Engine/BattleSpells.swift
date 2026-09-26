import Foundation

/// A spell caster in battle: a hero (its level, skills, spell book and points) or a creature
/// stack with spells of its own.
public struct Caster {
    public var level: Int
    public var skills: [String: Int]      // Hero.skills (1 basic ... 5 grandmaster)
    public var spells: [Int]
    public var spellPoints: Int
    public var creature = false           // a creature caster: level 0, Spell Power x count for damage
    public var spellPower = 0             // the creature's Spell Power column
    /// From worn items: spells castable without the school skill (scrolls), costs, power bonuses in percent.
    public var free: Set<Int> = []
    public var costs: [Int: Int] = [:]
    public var powerBonus: [Int: Int] = [:]
    public func cost(_ spell: Int) -> Int { costs[spell] ?? (spell < RuleTables.spells.count ? RuleTables.spells[spell].cost : 0) }
    public init(level: Int, skills: [String: Int], spells: [Int], spellPoints: Int) {
        self.level = level; self.skills = skills; self.spells = spells; self.spellPoints = spellPoints
    }
    /// A hero's book: known spells, those of worn spellbooks and scrolls, their costs and power.
    public init(hero h: Hero, spellPoints: Int) {
        let items = h.artifactSpells
        let all = h.spells.union(items.withSkill).union(items.free)
        self.init(level: h.level, skills: h.skills, spells: Array(all).sorted(), spellPoints: spellPoints)
        free = items.free
        for sp in all { costs[sp] = h.spellCost(sp); let b = h.spellPowerBonus(sp); if b != 0 { powerBonus[sp] = b } }
    }
    func skill(_ k: String) -> Int { skills[k] ?? 0 }
}

/// Casting in battle, as heroes4.exe does it (spells_spec: power 0x865200 / 0x72db90, damage
/// after resistance 0x40d000, resistance 0x5f2330 / 0x40cac0, mass spells 0x98bf08, summons
/// 0x87c750).
extension Battle {
    static let powerSkill = ["life": "spirit", "order": "mind", "death": "demonology", "chaos": "pyromancy", "nature": "meditation"]
    /// Mass spell -> the single spell it casts on every valid target (0x98bf08).
    static let massOf: [Int: Int] = [12: 13, 29: 58, 32: 61, 52: 47, 80: 10, 127: 109, 81: 15, 82: 23, 83: 27, 84: 35, 85: 45, 86: 48, 87: 104,
                                     88: 56, 89: 102, 90: 115, 91: 117, 92: 118, 93: 120, 94: 121, 95: 140, 96: 105, 97: 143, 98: 145, 99: 148, 100: 185]

    /// The spell's power for this caster: (base + increment x level) x pct / 100, pct = 100 + 20
    /// per level of the school's power skill (+ Sorcery 20...100 on damage spells); summons divide
    /// by the creature's gold cost; creatures cast at level 0, damage and summons scaled by their
    /// Spell Power x casters.
    public func power(_ spell: Int, by u: Unit, creatures: RuleTables? = nil) -> Int {
        guard spell < RuleTables.spells.count, let c = u.caster else { return 0 }
        let s = RuleTables.spells[spell]
        var pct = 100
        var level = c.level
        if c.creature {
            level = 0
            if s.kind == "damage" || s.kind == "summoning" || spell == 133 { pct = c.spellPower * pct * u.stats.count / 100 }
        } else {
            pct += 20 * c.skill(Battle.powerSkill[s.school] ?? "") + (c.powerBonus[spell] ?? 0)
            if s.kind == "damage" || s.has("Dmg") { pct += 20 * c.skill("sorcery") }
        }
        var p = s.base * pct / 100
        if s.increment != 0 { p = (s.base + s.increment * level) * pct / 100 }
        if spell == 53 || spell == 54 { p = (10 + level) * pct / 1000 }
        if s.kind == "summoning", let cr = creatures?.creature(s.creature), cr.gold > 0 { p = max(1, p / cr.gold) }
        return p
    }

    /// Resistance in percent of a stack to a spell (0x40cac0 / 0x5f2330): base (creature 50% etc.,
    /// hero Resistance skill), halved by the Magic Resistance spell and by a ward of the school.
    public func resistance(_ t: Unit, to spell: Int) -> Int {
        if t.stats.has("spell_vulnerability") { return 0 }
        if t.stats.has("magic_immunity") || t.stats.under(3) { return 100 }
        var k = 100 - t.stats.magicResistance
        if t.stats.under(75) { k -= k / 2 }
        let school = spell < RuleTables.spells.count ? RuleTables.spells[spell].school : ""
        let ward: [String: Bool] = ["life": t.stats.has("life_protection") || t.stats.under(119), "order": t.stats.under(121),
                                    "death": t.stats.has("death_protection") || t.stats.under(118), "chaos": t.stats.has("chaos_protection") || t.stats.under(117),
                                    "nature": t.stats.under(120)]
        if ward[school] == true { k -= k / 2 }
        return k > 0 ? 100 - k : 100
    }

    /// Can this spell land on that stack (its side, and the kinds the spell allows)?
    public func canTarget(_ spell: Int, by u: Unit, _ t: Unit) -> Bool {
        guard spell < RuleTables.spells.count, t.alive || RuleTables.spells[spell].has("Bodies") else { return false }
        let s = RuleTables.spells[spell]
        let enemy = side(of: t) != side(of: u)
        if enemy ? !s.has("Enemy") : !s.has("Friend") { return false }
        if t.stats.has("magic_immunity") && enemy { return false }
        if t.stats.has("undead"), !s.has("Undead") { return false }
        if t.stats.has("mechanical"), !s.has("Mech") { return false }
        if t.stats.has("elemental"), !s.has("Elem") { return false }
        if s.has("Mind"), t.stats.has("undead") || t.stats.has("mechanical") || t.stats.has("elemental") || t.stats.has("mind_immunity") { return false }
        if s.flags.contains("Fire"), t.stats.has("fire_resistance") || t.stats.under(40) { return false }
        if s.flags.contains("Cold"), t.stats.has("cold_resistance") || t.stats.under(20) { return false }
        if [61, 32].contains(spell), t.stats.alignment != "death" { return false }   // Holy Word / Holy Shout: death creatures only
        return true
    }
    /// Spells the unit can cast now: known, affordable, a combat spell, the school skill high enough.
    public func castable(_ u: Unit) -> [Int] {
        guard let c = u.caster else { return [] }
        return c.spells.filter { sp in
            guard sp < RuleTables.spells.count else { return false }
            let s = RuleTables.spells[sp]
            let skillOK = c.creature || c.free.contains(sp) || (s.schoolSkill >= 0 && (c.skills[RuleTables.skillIds[s.schoolSkill]] ?? 0) >= s.level)
            return s.has("Cmb") && c.cost(sp) <= c.spellPoints && skillOK
        }
    }
    /// A spell that needs no target (mass spells, Armageddon, summons...).
    public static func untargeted(_ spell: Int) -> Bool {
        guard spell < RuleTables.spells.count else { return false }
        let s = RuleTables.spells[spell]
        return s.has("Mass") || s.kind == "summoning" && !s.has("Bodies") || [4, 32, 110].contains(spell)
    }

    /// Cast by the current unit on a target stack (nil for untargeted spells). Ends the unit's turn.
    @discardableResult
    public func cast(_ spell: Int, on targetId: Int?, tables: RuleTables? = nil) -> Bool {
        guard finished == nil, let u = current, var c = u.caster, castable(u).contains(spell) else { return false }
        let s = RuleTables.spells[spell]
        var targets: [Unit] = []
        if let m = Battle.massOf[spell] {
            targets = units.filter { $0.alive && canTarget(m, by: u, $0) }
        } else if spell == 4 {   // Armageddon: every stack
            targets = units.filter { $0.alive }
        } else if spell == 32 || spell == 110 {
            targets = units.filter { $0.alive && canTarget(spell, by: u, $0) }
        } else if s.kind == "summoning" && !s.has("Bodies") {
            targets = []
        } else {
            guard let id = targetId, let t = units.first(where: { $0.id == id }), canTarget(spell, by: u, t) else { return false }
            targets = [t]
            // area spells: Fireball 3x3, Inferno 5x5, Fire Ring around the cell, the others single
            let radius = spell == 43 ? 1 : spell == 66 ? 2 : spell == 41 ? 1 : 0
            if radius > 0 {
                let cx = t.x + t.size / 2, cy = t.y + t.size / 2
                targets = units.filter { v in v.alive && v.x - radius <= cx && cx <= v.x + v.size - 1 + radius && v.y - radius <= cy && cy <= v.y + v.size - 1 + radius }
                if spell == 41 { targets.removeAll { $0.id == t.id } }
            }
        }
        c.spellPoints -= c.cost(spell)
        u.caster = c
        let p = power(spell, by: u, creatures: tables)
        events.append(.cast(unit: u.id, spell: spell, targets: targets.map { $0.id }))
        let effectSpell = Battle.massOf[spell] ?? spell
        switch s.kind {
        case "damage":
            var chainPower = p
            for (k, t) in targets.enumerated() {
                let r = resistance(t, to: spell)
                var dmg = r >= 100 ? 0 : (chainPower * (100 - r) + 99) / 100
                if t.stats.under(34) { dmg += dmg >> 2 }
                dmg = min(dmg, t.stats.totalHealth)
                let killed = t.stats.take(dmg)
                if side(of: t) != side(of: u), u.side == 0 { experience += killed * t.stats.experience }
                events.append(.spellHit(unit: t.id, spell: spell, damage: dmg, killed: killed, left: t.stats.count))
                if !t.alive { events.append(.die(unit: t.id)) }
                if spell == 17 { chainPower /= 2; if k >= 4 { break } }
            }
            if spell == 17, let first = targets.first {   // Chain Lightning jumps on to the nearest stacks, halving
                var hitIds: Set<Int> = [first.id], from = first, pw = p / 2
                for _ in 0..<4 {
                    guard let next = units.filter({ $0.alive && !hitIds.contains($0.id) }).min(by: { Battle.distance(from, $0) < Battle.distance(from, $1) }), pw > 0 else { break }
                    let r = resistance(next, to: spell)
                    let dmg = min(next.stats.totalHealth, r >= 100 ? 0 : (pw * (100 - r) + 99) / 100)
                    let killed = next.stats.take(dmg)
                    events.append(.spellHit(unit: next.id, spell: spell, damage: dmg, killed: killed, left: next.stats.count))
                    if !next.alive { events.append(.die(unit: next.id)) }
                    hitIds.insert(next.id); from = next; pw /= 2
                }
            }
        case "healing":
            for t in targets {
                // Heal restores the top creature's wounds (never the dead) and cures Poison and Plague
                let healed = min(p, t.stats.wounds)
                t.stats.wounds -= healed
                t.poison = 0; t.stats.effects.remove(111); t.stats.effects.remove(110)
                events.append(.spellHit(unit: t.id, spell: spell, damage: -healed, killed: 0, left: t.stats.count))
            }
        case "summoning" where !s.has("Bodies"):
            if let t = tables, let cr = t.creature(s.creature) {
                let st = Combatant(creature: cr, count: max(1, p))
                // next to the caster, as near as there is room
                let spot = freeSpot(near: u, size: 2)
                let nu = Unit(id: (units.map { $0.id }.max() ?? 0) + 1, side: u.side, stats: st, keyword: cr.keyword, actor: cr.name, size: 2,
                              move: cr.move, shots: cr.shots, x: spot.0, y: spot.1)
                nu.summoned = true; nu.acted = true
                units.append(nu)
                events.append(.summon(unit: nu.id))
            }
        default:
            for t in targets {
                // non-damage spells with Resisted (or Resisted-if-enemy on an enemy) are resisted outright at the resistance chance
                let enemy = side(of: t) != side(of: u)
                if s.has("Resisted") || (enemy && s.has("ResIfEnemy")) {
                    let r = resistance(t, to: spell)
                    if r >= 100 || rng.next() % 100 < r { events.append(.resisted(unit: t.id, spell: spell)); continue }
                }
                apply(effectSpell, to: t, power: p)
                events.append(.spellHit(unit: t.id, spell: effectSpell, damage: 0, killed: 0, left: t.stats.count))
            }
        }
        checkEnd()
        endAction(u)
        return true
    }

    /// A lasting spell on a stack: the stat getters read `effects`; some set the older flags.
    func apply(_ spell: Int, to t: Unit, power p: Int) {
        // opposites cancel: Bless / Curse, Haste / Slow, Fortune / Misfortune
        let opposite: [Int: [Int]] = [10: [23], 23: [10], 55: [105, 141], 104: [105, 141], 105: [55, 104], 141: [55, 104], 48: [102], 102: [48]]
        for o in opposite[spell] ?? [] { t.stats.effects.remove(o) }
        switch spell {
        case 27, 83:   // Dispel: every spell goes
            t.stats.effects = []; t.stats.cursed = false; t.stats.weakened = false; t.stats.aged = false
            return
        case 23: t.stats.cursed = true
        case 185: t.stats.weakened = true
        case 1: t.stats.aged = true
        case 9: t.stats.bound = true
        case 11: t.blind = 3
        case 154: t.stunned = max(t.stunned, 1)
        case 186: t.frozen = max(t.frozen, 2)
        case 21: t.stunned = max(t.stunned, 1)       // Confusion: loses its next action
        case 180: t.stunned = max(t.stunned, 2)      // Terror: the next two
        case 62, 138: t.hypnotized = true
        case 111: t.poison = max(t.poison, p)
        case 51, 57, 114:   // Giant Strength, Health, Prayer: a quarter more hit points
            if !t.stats.under(spell) { t.stats.hitPoints += (t.stats.hitPoints + 2) >> 2 }
        case 33: if !t.stats.under(33) { t.stats.hitPoints *= 2 }
        case 5:   // Banish: destroys summoned creatures up to its power in hit points
            if t.summoned { let k = t.stats.take(min(p, t.stats.totalHealth)); events.append(.spellHit(unit: t.id, spell: 5, damage: p, killed: k, left: t.stats.count)); if !t.alive { events.append(.die(unit: t.id)) } }
        case 54:   // Hand of Death: kills outright
            let k = t.stats.take(min(t.stats.totalHealth, p * t.stats.hitPoints)); _ = k
            if !t.alive { events.append(.die(unit: t.id)) }
        default: break
        }
        t.stats.effects.insert(spell)
    }

    /// A free footprint of `size` near a unit, for summoned stacks.
    func freeSpot(near u: Unit, size: Int) -> (Int, Int) {
        for r in 1..<20 {
            for dx in -r...r { for dy in -r...r where max(abs(dx), abs(dy)) == r {
                let x = u.x + dx, y = u.y + dy
                if field.fits(x, y, size: size), !overlaps(x, y, size, except: -1) { return (x, y) }
            } }
        }
        return (u.x, u.y)
    }
}
