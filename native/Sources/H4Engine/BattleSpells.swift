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
    /// A creature stack's own spells (RuleTables.creatureSpells, 0x656ef0): level 0, its spell
    /// points per stack (creature record +0x68, not times the count), its Spell Power.
    public init?(creature keyword: String, spellPoints: Int, spellPower: Int) {
        guard let list = RuleTables.creatureSpells[keyword.lowercased()] else { return nil }
        self.init(level: 0, skills: [:], spells: list, spellPoints: spellPoints)
        creature = true
        self.spellPower = spellPower
    }
    /// The spell a click casts without opening the book: the first with the Default flag (0x656c20).
    public var defaultSpell: Int? { spells.first { $0 < RuleTables.spells.count && RuleTables.spells[$0].has("Default") } ?? spells.first }
}

/// Casting in battle, as heroes4.exe does it (spells_spec: power 0x865200 / 0x72db90, damage
/// after resistance 0x40d000, resistance 0x5f2330 / 0x40cac0, mass spells 0x98bf08, summons
/// 0x87c750).
extension Battle {
    static let powerSkill = ["life": "spirit", "order": "mind", "death": "demonology", "chaos": "pyromancy", "nature": "meditation"]
    /// Mass spell -> the single spell it casts on every valid target (0x98bf08).
    static let massOf: [Int: Int] = [12: 13, 29: 58, 32: 61, 52: 47, 80: 10, 127: 109, 81: 15, 82: 23, 83: 27, 84: 35, 85: 45, 86: 48, 87: 104,
                                     88: 56, 89: 102, 90: 115, 91: 117, 92: 118, 93: 120, 94: 121, 95: 140, 96: 105, 97: 143, 98: 145, 99: 148, 100: 185]

    /// The spell's power for this caster (0x865200): (base + increment x level) x pct / 100, pct =
    /// 100 + 20 per level of the school's power skill (+ Sorcery 20...100 on spells with the Dmg
    /// flag, 0x72db90); summons divide by the creature's Experience (+0x74); creatures cast at
    /// level 0, spells with the Dmg or Summ flag and Resurrection scaled by Spell Power x count
    /// (0x63dd90), Rebirth by the count.
    public func power(_ spell: Int, by u: Unit, creatures: RuleTables? = nil) -> Int {
        guard spell < RuleTables.spells.count, let c = u.caster else { return 0 }
        let s = RuleTables.spells[spell]
        var pct = 100
        var level = c.level
        if c.creature {
            level = 0
            if s.has("Dmg") || s.has("Summ") || spell == 133 { pct = c.spellPower * pct * u.stats.count / 100 }
            else if spell == 129 { pct *= u.initialCount }   // Rebirth: x the starting count
        } else {
            pct += 20 * c.skill(Battle.powerSkill[s.school] ?? "") + (c.powerBonus[spell] ?? 0)
            if s.has("Dmg") { pct += 20 * c.skill("sorcery") }
        }
        var p = s.base * pct / 100
        if s.increment != 0 { p = (s.base + s.increment * level) * pct / 100 }
        if spell == 53 || spell == 54 { p = (10 + level) * pct / 1000 }
        if s.has("Summ"), let cr = (creatures ?? tables)?.creature(s.creature), cr.experience > 0 { p = max(1, p / cr.experience) }
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
        guard spell < RuleTables.spells.count else { return false }
        let s = RuleTables.spells[spell]
        if !t.alive {
            // the dead: Bodies spells on bodies still on the field; Divine Intervention brings back heroes
            guard s.has("Bodies"), deadCount(t) > 0 else { return false }
            if spell == 30, !t.stats.isHero { return false }
        }
        switch spell {
        case 124, 125, 126, 2, 24:   // raising needs dead creatures and no Necromancy Ward (0x5f054c)
            if deadCount(t) == 0 || t.stats.under(135) { return false }
            if spell == 2, !t.stats.has("undead") { return false }   // Animate Dead: undead only
        case 133, 129: if deadCount(t) == 0 && t.stats.wounds == 0 { return false }
        default: break
        }
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
    /// Combat spells the exe registers no factory for (0x614220 / 0x614270): only abilities,
    /// artifacts or other spells apply them.
    static let noFactory: Set<Int> = [9, 20, 42, 107, 119, 152, 191, 194]
    /// Spells the unit can cast now: known, affordable, a combat spell, the school skill high enough.
    public func castable(_ u: Unit) -> [Int] {
        guard let c = u.caster else { return [] }
        return c.spells.filter { sp in
            guard sp < RuleTables.spells.count else { return false }
            let s = RuleTables.spells[sp]
            let skillOK = c.creature || c.free.contains(sp) || (s.schoolSkill >= 0 && (c.skills[RuleTables.skillIds[s.schoolSkill]] ?? 0) >= s.level)
            return s.has("Cmb") && !Battle.noFactory.contains(sp) && sp != 129 && c.cost(sp) <= c.spellPoints && skillOK
        }
    }
    /// How a spell is aimed (its factory's click handler): nothing, a stack (a body for the Bodies
    /// spells), a cell (Fireball 0x717dd0, the clouds, Smoke, Quicksand, Rock Growth), a stack or
    /// a cell (Fire Ring), a stack and the pointer's cell (Sparks, Displacement), two stacks
    /// (Sacrifice, Martyr), a stack then a destination cell (Teleport 0x87eef0).
    public enum Aim { case none, unit, cell, unitOrCell, unitAndPoint, twoUnits, unitThenCell }
    public static func aim(_ spell: Int) -> Aim {
        switch spell {
        case 43, 66, 67, 19, 25, 50, 142, 123, 134: return .cell
        case 41: return .unitOrCell
        case 14, 28: return .unitAndPoint
        case 136, 79: return .twoUnits
        case 178: return .unitThenCell
        default: return untargeted(spell) ? .none : .unit
        }
    }
    /// The dead stack whose bodies lie on a cell.
    public func corpse(at x: Int, _ y: Int) -> Unit? {
        units.last { !$0.alive && deadCount($0) > 0 && x >= $0.x && x < $0.x + $0.size && y >= $0.y && y < $0.y + $0.size }
    }
    /// A spell that needs no target (mass spells, Armageddon, summons...).
    public static func untargeted(_ spell: Int) -> Bool {
        guard spell < RuleTables.spells.count else { return false }
        let s = RuleTables.spells[spell]
        return s.has("Mass") || s.kind == "summoning" && !s.has("Bodies") && spell != 18 && spell != 64 || [4, 32, 110].contains(spell)
    }

    /// The stacks a cast at this target touches, or nil when the target is not a valid one.
    func castTargets(_ spell: Int, by u: Unit, target targetId: Int?, cell: (Int, Int)?) -> [Unit]? {
        let s = RuleTables.spells[spell]
        if let m = Battle.massOf[spell] { return units.filter { $0.alive && canTarget(m, by: u, $0) } }
        if spell == 4 { return units.filter { $0.alive } }   // Armageddon: every stack
        if spell == 32 || spell == 110 { return units.filter { $0.alive && canTarget(spell, by: u, $0) } }
        if spell == 30 { return units.filter { canTarget(spell, by: u, $0) } }   // Divine Intervention: friends, dead heroes too
        if Battle.untargeted(spell) { return [] }
        guard let id = targetId, let t = units.first(where: { $0.id == id }), canTarget(spell, by: u, t) else { return nil }
        // area spells: Fireball 3x3, Inferno 5x5, Fire Ring around the cell, the others single
        let radius = spell == 43 ? 1 : spell == 66 ? 2 : spell == 41 ? 1 : 0
        if radius > 0 {
            let cx = t.x + t.size / 2, cy = t.y + t.size / 2
            var targets = units.filter { v in v.alive && v.x - radius <= cx && cx <= v.x + v.size - 1 + radius && v.y - radius <= cy && cy <= v.y + v.size - 1 + radius }
            if spell == 41 { targets.removeAll { $0.id == t.id } }
            return targets
        }
        _ = s
        return [t]
    }

    /// Cast by the current unit on a target stack (nil for untargeted spells), a cell (area
    /// spells), a second stack (Sacrifice). Ends the unit's turn.
    @discardableResult
    public func cast(_ spell: Int, on targetId: Int?, cell: (Int, Int)? = nil, second: Int? = nil, tables: RuleTables? = nil) -> Bool {
        if let t = tables { self.tables = t }
        let tables = self.tables
        guard finished == nil, let u = current, var c = u.caster, castable(u).contains(spell) else { return false }
        let s = RuleTables.spells[spell]
        guard let targets = castTargets(spell, by: u, target: targetId, cell: cell) else { return false }
        if spell == 136 {   // Sacrifice: a second friendly stack to restore
            guard let sid = second, sid != targetId, let t2 = units.first(where: { $0.id == sid }), canTarget(spell, by: u, t2) else { return false }
        }
        c.spellPoints -= c.cost(spell)
        u.caster = c
        let p = power(spell, by: u, creatures: tables)
        events.append(.cast(unit: u.id, spell: spell, targets: targets.map { $0.id }))
        let effectSpell = Battle.massOf[spell] ?? spell
        // Poison and Plague deal nothing now: their damage after resistance is kept and dealt at the
        // start of each of the target's turns (0x61b980 / 0x78e320); Regeneration heals each turn
        let lasting: Set<Int> = [110, 111, 131, 112]
        switch lasting.contains(effectSpell) ? "lasting" : s.kind {
        case "lasting":
            for t in targets {
                let r = resistance(t, to: spell)
                var dmg = r >= 100 ? 0 : (p * (100 - r) + 99) / 100
                if t.stats.under(34) { dmg += dmg >> 2 }
                switch effectSpell {
                case 111: t.poison = dmg
                case 110: t.plague = dmg
                case 131: t.regeneration = p
                default: break
                }
                t.stats.effects.insert(effectSpell)
                events.append(.spellHit(unit: t.id, spell: effectSpell, damage: 0, killed: 0, left: t.stats.count))
            }
        case "damage":
            var chainPower = p
            for (k, t) in targets.enumerated() {
                let r = resistance(t, to: spell)
                var dmg = r >= 100 ? 0 : (chainPower * (100 - r) + 99) / 100
                if t.stats.under(34) { dmg += dmg >> 2 }
                dmg = min(dmg, t.stats.totalHealth)
                let killed = t.stats.take(dmg)
                if dmg > 0 { t.blind = 0 }   // any damage ends Blind (0x5ef290)
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
        case _ where spell == 30:   // Divine Intervention (0x78d5d0): curses off, the top creature healed, dead heroes back
            for t in targets {
                for e in t.stats.effects where RuleTables.spells.indices.contains(e) && RuleTables.spells[e].has("Curse") { remove(e, from: t) }
                let healed = t.alive ? min(p, t.stats.wounds) : restore(t, p)
                if t.alive { t.stats.wounds -= healed }
                events.append(.spellHit(unit: t.id, spell: spell, damage: -healed, killed: 0, left: t.stats.count))
            }
        case "resurrection":   // Resurrection (0x804020): back to the stack it was
            if let t = targets.first { resurrect(t, power: p, spell: spell) }
        case "summoning" where s.has("Bodies"):   // Raise Skeletons / Ghost / Vampires, Animate Dead, Death Call (0x8058f0)
            if let t = targets.first { raise(spell, power: p, by: u, from: t) }
        case "sacrifice":   // Sacrifice (0x808130): the first friend destroyed, the second restored by twice its hit points
            if let t = targets.first, let sid = second, let t2 = units.first(where: { $0.id == sid }) {
                let hp = t.stats.totalHealth
                let killed = t.stats.count
                t.stats.count = 0; t.stats.wounds = 0; t.permanentlyLost = t.initialCount
                events.append(.spellHit(unit: t.id, spell: spell, damage: hp, killed: killed, left: 0))
                events.append(.die(unit: t.id)); events.append(.bodiesGone(unit: t.id))
                resurrect(t2, power: 2 * hp, spell: spell)
            }
        case "healing":
            for t in targets {
                // Heal restores the top creature's wounds (never the dead) and cures Poison and Plague
                let healed = min(p, t.stats.wounds)
                t.stats.wounds -= healed
                t.poison = 0; t.plague = 0; t.stunned = 0; t.stats.effects.remove(111); t.stats.effects.remove(110); t.stats.effects.remove(154)
                events.append(.spellHit(unit: t.id, spell: spell, damage: -healed, killed: 0, left: t.stats.count))
            }
        case "summoning" where !s.has("Bodies"):
            if spell == 18 || spell == 64, let t = targets.first {
                phantom(of: t, spell: spell, power: p, by: u)
            } else if let cr = tables?.creature(s.creature) {
                summon(cr, count: p, spell: spell, by: u)
            }
        default:
            for t in targets {
                // non-damage spells with Resisted (or Resisted-if-enemy on an enemy) are resisted outright at the resistance chance
                let enemy = side(of: t) != side(of: u)
                if s.has("Resisted") || (enemy && s.has("ResIfEnemy")) {
                    let r = resistance(t, to: spell)
                    if r >= 100 || rng.next() % 100 < r { events.append(.resisted(unit: t.id, spell: spell)); continue }
                }
                if spell == 0, !t.alive {   // Acid on a dead stack destroys the bodies (0x806c80)
                    t.permanentlyLost = t.initialCount
                    events.append(.spellHit(unit: t.id, spell: spell, damage: 0, killed: 0, left: 0)); events.append(.bodiesGone(unit: t.id))
                    continue
                }
                apply(effectSpell, to: t, power: p)
                events.append(.spellHit(unit: t.id, spell: effectSpell, damage: 0, killed: 0, left: t.stats.count))
            }
        }
        checkEnd()
        endAction(u)
        return true
    }

    /// A spell taken off a stack (0x5f23d0), with what it set.
    func remove(_ spell: Int, from t: Unit) {
        t.stats.effects.remove(spell); t.durations[spell] = nil
        switch spell {
        case 23: t.stats.cursed = false
        case 185: t.stats.weakened = false
        case 1: t.stats.aged = false
        case 9: t.stats.bound = false
        case 62, 138: t.hypnotized = false
        case 111: t.poison = 0
        case 110: t.plague = 0
        case 131: t.regeneration = 0
        default: break
        }
    }

    /// A lasting spell on a stack: the stat getters read `effects`; some set the older flags.
    func apply(_ spell: Int, to t: Unit, power p: Int) {
        // opposites cancel: Bless / Curse, Haste / Slow, Fortune / Misfortune
        let opposite: [Int: [Int]] = [10: [23], 23: [10], 55: [105, 141], 146: [105, 141], 104: [105, 141], 105: [55, 104, 146], 141: [55, 104, 146],
                                      48: [102], 102: [48], 145: [103], 25: [103], 103: [145, 25], 6: [144], 21: [6], 154: [6], 144: [6]]
        for o in opposite[spell] ?? [] { t.stats.effects.remove(o); t.durations[o] = nil; if o == 23 { t.stats.cursed = false } }
        // the fixed lengths (§1), a turn more when it lands on the stack whose turn it is
        let lengths: [Int: Int] = [21: 1, 154: 1, 144: 1, 122: 2, 180: 2, 186: 2, 11: 3, 22: 3, 62: 3, 137: 6]
        if let n = lengths[spell] { t.durations[spell] = n + (current?.id == t.id ? 1 : 0) }
        switch spell {
        case 27, 83:   // Dispel: every spell goes
            t.stats.effects = []; t.stats.cursed = false; t.stats.weakened = false; t.stats.aged = false
            t.durations = [:]; t.poison = 0; t.plague = 0; t.regeneration = 0; t.hypnotized = false
            return
        case 23: t.stats.cursed = true
        case 185: t.stats.weakened = true
        case 1: t.stats.aged = true
        case 9: t.stats.bound = true
        case 62, 138: t.hypnotized = true
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

    /// Creatures of a stack that died and could come back (original - permanently lost - living).
    public func deadCount(_ t: Unit) -> Int { max(0, t.initialCount - t.permanentlyLost - t.stats.count) }
    /// Hit points back to a stack (0x5f38f0 with resurrection): the top creature's wounds first,
    /// then dead creatures back, never more than it started with. Returns the hit points restored.
    @discardableResult
    func restore(_ t: Unit, _ hp: Int) -> Int {
        let h = max(1, t.stats.hitPoints)
        let amt = max(0, min(hp, t.stats.wounds + h * deadCount(t)))
        guard amt > 0 else { return 0 }
        let wasDead = !t.alive
        let total = t.stats.totalHealth + amt
        t.stats.count = (total + h - 1) / h
        t.stats.wounds = t.stats.count * h - total
        if wasDead { t.deathHandled = false }
        return amt
    }
    /// Resurrection / Rebirth / Sacrifice's second stack (0x804020): power in hit points, the cap
    /// is its wounds plus the dead it can have back; a wiped stack rises where it fell.
    func resurrect(_ t: Unit, power p: Int, spell: Int) {
        let before = t.stats.count
        let amt = restore(t, p)
        events.append(.revive(unit: t.id, spell: spell, amount: t.stats.count - before, left: t.stats.count))
        if amt > 0 && before == t.stats.count { events.append(.spellHit(unit: t.id, spell: spell, damage: -amt, killed: 0, left: t.stats.count)) }
    }
    /// Raising (0x8058f0 / 0x8067b0): Raise Skeletons / Ghost / Vampires make min(power, the dead,
    /// ceil(dead x their hit points / the raised one's)) of their creature (power is already divided
    /// by its Experience); Animate Dead and Death Call raise the corpse's own creature, power in hit
    /// points. They join the caster's side as a summoned stack (merging with an earlier one of the
    /// same spell and creature); the bodies used are gone for good.
    func raise(_ spell: Int, power p: Int, by u: Unit, from t: Unit) {
        let dead = deadCount(t)
        let hpDead = max(1, t.stats.hitPoints)
        let made: Int, used: Int, cr: CreatureDef
        if spell == 2 || spell == 24 {
            guard let own = tables?.creature(t.keyword) else { return }
            cr = own
            let amt = min(p, dead * hpDead)
            made = (amt + hpDead - 1) / hpDead
            used = made
        } else {
            guard let r = tables?.creature(RuleTables.spells[spell].creature) else { return }
            cr = r
            let hpRaised = max(1, r.hitPoints)
            made = min(p, dead, (dead * hpDead + hpRaised - 1) / hpRaised)
            used = min(dead, (made * hpRaised + hpDead - 1) / hpDead)
        }
        guard made > 0 else { return }
        t.permanentlyLost += used
        let corpse = !t.alive && deadCount(t) == 0 ? t : nil
        if corpse != nil { events.append(.bodiesGone(unit: t.id)) }
        summon(cr, count: made, spell: spell, by: u, at: t)
    }

    /// A summoned or raised stack of `creature` on the caster's side (0x87bdd0): a second cast adds
    /// to the stack this spell brought before (0x577fc0); otherwise a new stack is placed next to
    /// the caster (0x87bac0). Returns the stack, or nil when there is no room.
    @discardableResult
    func summon(_ cr: CreatureDef, count: Int, spell: Int, by u: Unit, at corpse: Unit? = nil, phantomOf: Combatant? = nil) -> Unit? {
        if let old = units.first(where: { $0.alive && $0.summoned && $0.summonedBy == spell && $0.side == side(of: u) && $0.keyword == cr.keyword }) {
            old.stats.count += count
            old.initialCount += count
            events.append(.revive(unit: old.id, spell: spell, amount: count, left: old.stats.count))
            return old
        }
        let model: (actor: String, size: Int) = creatureModel?(cr) ?? (cr.name, 2)
        var st = phantomOf ?? Combatant(creature: cr, count: count)
        st.count = count; st.wounds = 0
        if phantomOf != nil { st.effects = [] ; st.cursed = false; st.weakened = false; st.aged = false; st.bound = false }
        st.effects.insert(spell)
        let spot: (Int, Int)?
        if let c = corpse, c.size == model.size, !overlaps(c.x, c.y, c.size, except: c.id) { spot = (c.x, c.y) }
        else { spot = freeSpot(near: corpse ?? u, size: model.size) }
        guard let (x, y) = spot else { return nil }
        let nu = Unit(id: (units.map { $0.id }.max() ?? 0) + 1, side: side(of: u), stats: st, keyword: cr.keyword, actor: model.actor, size: model.size,
                      move: cr.move, shots: cr.shots, x: x, y: y)
        nu.summoned = true; nu.summonedBy = spell; nu.acted = true
        nu.caster = Caster(creature: cr.keyword, spellPoints: cr.spellPoints, spellPower: cr.spellPower)
        units.append(nu)
        events.append(.summon(unit: nu.id))
        return nu
    }
    /// Phantom Image / Create Illusion (0x87d050): a copy of the target's creature, ceil(power /
    /// its hit points) of them, on the caster's side; it merges with an earlier copy.
    func phantom(of t: Unit, spell: Int, power p: Int, by u: Unit) {
        let hp = max(1, t.stats.hitPoints)
        let n = (p + hp - 1) / hp
        let cr = tables?.creature(t.keyword) ?? CreatureDef(keyword: t.keyword, name: t.stats.name, plural: t.stats.name, level: t.stats.level, alignment: t.stats.alignment,
                                                             hitPoints: t.stats.hitPoints, damageLow: t.stats.damageLow, damageHigh: t.stats.damageHigh, attack: t.stats.attack,
                                                             defense: t.stats.defense, move: t.move, speed: t.stats.speed, growth: 0, gold: 0, experience: 0, shots: t.shots,
                                                             spellPoints: 0, shortHelp: "", longHelp: "")
        var copy = t.stats
        copy.experience = 0
        summon(cr, count: n, spell: spell, by: u, phantomOf: copy)
    }

    /// A free footprint of `size` as near to a stack as there is room (0x87bac0): of the free
    /// places the ones whose centre is nearest the stack's centre, one of them at random.
    func freeSpot(near u: Unit, size: Int) -> (Int, Int)? {
        var best: [(Int, Int)] = [], bestD = Int.max
        let cx = u.x * 16 + u.size * 8, cy = u.y * 16 + u.size * 8
        for x in 0..<Battlefield.size { for y in 0..<Battlefield.size where field.fits(x, y, size: size) && !overlaps(x, y, size, except: -1) {
            let dx = x * 16 + size * 8 - cx, dy = y * 16 + size * 8 - cy
            let d = dx * dx + dy * dy
            if d < bestD { bestD = d; best = [(x, y)] } else if d == bestD { best.append((x, y)) }
        } }
        guard !best.isEmpty else { return nil }
        return best[rng.next() % best.count]
    }

    // MARK: the computer's spells

    /// Every target the spell could be cast at now: nil for spells without one, else the stacks it can land on.
    func aiTargets(_ spell: Int, by u: Unit) -> [(target: Int?, cell: (Int, Int)?)] {
        if Battle.untargeted(spell) { return [(nil, nil)] }
        return units.filter { canTarget(spell, by: u, $0) }.map { ($0.id, nil) }
    }
    /// The stacks a cast would touch (for the computer's estimate).
    func aiAffected(_ spell: Int, by u: Unit, target: Int?, cell: (Int, Int)?) -> [Unit] {
        if let m = Battle.massOf[spell] { return units.filter { $0.alive && canTarget(m, by: u, $0) } }
        if Battle.untargeted(spell) { return units.filter { $0.alive && canTarget(spell, by: u, $0) } }
        return units.filter { $0.id == target }
    }
    /// What a spell is worth to the caster's side, in hit points (the exe's AI was not traced: a
    /// value estimate -- damage done to enemies, healing and raising on friends, summoned hit
    /// points, a share of the target's hit points for a blessing or curse it does not have yet).
    func aiValue(_ spell: Int, by u: Unit, target: Int?, cell: (Int, Int)?) -> Int {
        let s = RuleTables.spells[spell]
        let effect = Battle.massOf[spell] ?? spell
        let p = power(spell, by: u)
        var v = 0
        if s.has("Summ"), !s.has("Bodies"), let cr = tables?.creature(s.creature) { return p * cr.hitPoints }
        for t in aiAffected(spell, by: u, target: target, cell: cell) {
            let enemy = side(of: t) != side(of: u)
            let r = resistance(t, to: spell)
            if s.kind == "damage" && ![111, 110, 112].contains(effect) || effect == 54 || effect == 5 {
                var d = r >= 100 ? 0 : (p * (100 - r) + 99) / 100
                if effect == 54 { d = d * t.stats.hitPoints }
                d = min(d, t.stats.totalHealth)
                v += enemy ? d : -2 * d
            } else if s.has("Summ"), s.has("Bodies") {   // raising works on either side's dead
                if let r = tables?.creature(s.creature) { v += min(p, deadCount(t)) * r.hitPoints }
                else { v += min(p, deadCount(t) * t.stats.hitPoints) }
            } else if s.kind == "healing" || s.kind == "resurrection" || s.has("Bodies") {
                let lost = max(0, t.initialCount - t.stats.count) * t.stats.hitPoints + t.stats.wounds
                v += enemy ? 0 : min(p, lost)
            } else {
                if t.stats.under(effect) || !t.alive { continue }
                let share = [11, 21, 154, 180, 186, 174, 62, 138].contains(effect) ? 2 : 5
                let hp = t.stats.totalHealth / share
                if enemy, s.has("Enemy") { v += (s.has("Resisted") || s.has("ResIfEnemy")) ? hp * (100 - r) / 100 : hp }
                else if !enemy, s.has("Friend") { v += hp }
            }
        }
        return v
    }
    /// The best spell the unit can cast now and what it is worth.
    func aiSpell(_ u: Unit) -> (spell: Int, target: Int?, cell: (Int, Int)?, value: Int)? {
        var best: (spell: Int, target: Int?, cell: (Int, Int)?, value: Int)? = nil
        for sp in castable(u) {
            for o in aiTargets(sp, by: u) {
                let v = aiValue(sp, by: u, target: o.target, cell: o.cell)
                if v > (best?.value ?? 0) { best = (sp, o.target, o.cell, v) }
            }
        }
        return best
    }
    /// What the unit's own blow or shot is worth now (its average damage on the enemy it would hit).
    func aiBlowValue(_ u: Unit, _ enemies: [Unit]) -> Int {
        let ranged = canShoot(u)
        return enemies.map { t -> Int in
            guard ranged || attackPosition(u, t) != nil else { return 0 }
            let (lo, hi) = damageRange(u, t, ranged: ranged)
            return min(t.stats.totalHealth, (lo + hi) / 2)
        }.max() ?? 0
    }
}
