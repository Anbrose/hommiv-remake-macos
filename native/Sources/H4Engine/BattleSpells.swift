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
    public static let massOf: [Int: Int] = [12: 13, 29: 58, 32: 61, 52: 47, 80: 10, 127: 109, 81: 15, 82: 23, 83: 27, 84: 35, 85: 45, 86: 48, 87: 104,
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
        // the side's grail of the school (0x410040, table 0x9708ec): +50%, nature +25%, heroes and creatures
        if grails[u.side].contains(s.school) { pct += s.school == "nature" ? 25 : 50 }
        var p = s.base * pct / 100
        if s.increment != 0 { p = (s.base + s.increment * level) * pct / 100 }
        if spell == 53 || spell == 54 { p = (10 + level) * pct / 1000 }
        if s.has("Summ"), let cr = (creatures ?? tables)?.creature(s.creature), cr.experience > 0 { p = max(1, p / cr.experience) }
        return p
    }

    /// Resistance in percent of a stack to a spell (0x40cac0 / 0x5f2330): base (creature 50% etc.,
    /// hero Resistance skill), halved by the Magic Resistance spell and by a ward of the school.
    public func resistance(_ t: Unit, to spell: Int, by caster: Unit? = nil) -> Int {
        if t.stats.has("spell_vulnerability") { return 0 }
        if caster?.stats.has("ignore_magic_resistance") == true { return 0 }   // (0x40d000, ability 82)
        if t.stats.has("magic_immunity") || t.stats.under(3) { return 100 }
        var k = 100 - t.stats.magicResistance
        if t.stats.under(75) { k -= k / 2 }
        let school = spell < RuleTables.spells.count ? RuleTables.spells[spell].school : ""
        let ward: [String: Bool] = ["life": t.stats.has("life_protection") || t.stats.under(119), "order": t.stats.under(121),
                                    "death": t.stats.has("death_protection") || t.stats.under(118), "chaos": t.stats.has("chaos_protection") || t.stats.under(117),
                                    "nature": t.stats.under(120)]
        if ward[school] == true, caster?.stats.has("ignore_wards") != true { k -= k / 2 }   // (ability 31)
        return k > 0 ? 100 - k : 100
    }

    /// Can this spell land on that stack (its side, and the kinds the spell allows)?
    public func canTarget(_ spell: Int, by u: Unit, _ t: Unit, anySide: Bool = false) -> Bool {
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
        let enemy = hostile(t, u)
        if !anySide, enemy ? !s.has("Enemy") : !s.has("Friend") { return false }
        if !anySide, enemy {
            // Song of Peace: no curse or damage on the other side (0x5b407a); Cowardice: not on a
            // stack with at least its total hit points (0x5b7800)
            if u.stats.under(144), s.has("Curse") || s.has("Dmg") { return false }
            if afraid(u, of: t), Battle.aim(spell) != .none { return false }
        }
        if spell == 60, !enemy, t.id != u.id { return false }   // Holy Water: the caster itself, or an enemy
        if spell == 16, t.id != u.id { return false }           // Heavenly Shield: the caster only
        if [59, 36, 182, 106].contains(spell), enemy, !anySide { return false }   // cast on friends (the Enemy flag is for the struck attacker)
        // magic immunity, Anti-Magic and Sanctuary turn every spell away, friendly ones too (0x5b37d0)
        if t.stats.has("magic_immunity") || t.stats.under(3) || t.stats.under(137) { return false }
        // the creature types (0x5b3ca0): phantoms are not mechanical here, and a caster with
        // negate_mind_immunity skips the checks for Mind spells
        let negate = s.has("Mind") && u.stats.has("negate_mind_immunity")
        if !negate {
        if t.stats.has("undead"), !s.has("Undead") { return false }
        if t.stats.has("mechanical"), !t.stats.under(18), !t.stats.under(64), !s.has("Mech") { return false }
        if t.stats.has("elemental"), !s.has("Elem") { return false }
        }
        if s.has("Mind"), !negate, t.stats.has("undead") || t.stats.has("mechanical") || t.stats.has("elemental") || t.stats.has("mind_immunity") { return false }
        if s.has("Fire"), t.stats.has("fire_resistance") { return false }
        if s.has("Cold"), t.stats.has("cold_resistance") { return false }
        // Line of sight (0x5b6c60 -> 0x5707f0): only castle walls block it
        if s.has("LoS"), !anySide, t.id != u.id, field.castleLevel > 0, !onTower(u), field.crossesWall(u.centre, t.centre) { return false }
        switch spell {
        case 61, 32: if t.stats.isHero || !(t.stats.alignment == "death" || t.stats.has("undead")) { return false }   // Holy Word / Shout: death or undead, no heroes (0x5b4f4a)
        case 114, 34: if t.stats.alignment != "life" { return false }   // Prayer, Unholy Song: Life stacks (0x5b4fdf)
        case 68: if t.id == u.id || !["life", "nature"].contains(t.stats.alignment) { return false }   // Life Drain (0x78ec60)
        case 110: if t.stats.alignment == "death" { return false }   // Plague (0x5b550f)
        case 5:   // Banish: summoned creatures, at least one of them (0x61b698)
            if !t.summoned || spellDamage(t, power(5, by: u), 5, by: u) < t.stats.hitPoints { return false }
        case 115: if !t.stats.shooter { return false }                     // Precision: shooters (0x5b5192)
        case 7: if !t.stats.has("flying") { return false }                 // Bind Flyer: flyers (0x5b4c45)
        case 10, 23: if t.stats.damageLow == t.stats.damageHigh { return false }   // Bless / Curse change nothing (0x5b4be0)
        case 11: if t.stats.has("blind") { return false }                  // (0x5b4d16)
        default: break
        }
        return true
    }
    /// A cast's cost in combat (0x5ebe10, heroes and creatures): the book's cost, + the spell's cost
    /// under Power Drain, + again under Magic Leech, - 2 when Mana Flare is on the caster, at least 1.
    public func cost(_ spell: Int, by u: Unit) -> Int {
        guard let c = u.caster, spell < RuleTables.spells.count else { return 0 }
        let base = RuleTables.spells[spell].cost
        var k = c.cost(spell)
        if u.stats.under(113) { k += base }
        if u.stats.under(73) { k += base }
        if u.stats.under(77) { k -= 2 }
        return max(1, k)
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
            return s.has("Cmb") && !Battle.noFactory.contains(sp) && sp != 129 && cost(sp, by: u) <= c.spellPoints && skillOK
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
        if [19, 25, 50].contains(spell) { return false }   // the clouds are aimed at a cell
        return s.has("Mass") || massOf[spell] != nil || massOnly.contains(spell) || s.kind == "summoning" && !s.has("Bodies") && spell != 18 && spell != 64 || [4, 16].contains(spell)
    }

    /// The stacks a cast at this target touches, or nil when the target is not a valid one.
    func castTargets(_ spell: Int, by u: Unit, target targetId: Int?, cell: (Int, Int)?) -> [Unit]? {
        if let m = Battle.massOf[spell] { return units.filter { $0.alive && canTarget(m, by: u, $0) } }
        if spell == 4 { return units.filter { $0.alive && $0.id != u.id && canTarget(spell, by: u, $0) } }   // Armageddon: all but the caster (0x5b4b26)
        if spell == 30 { return units.filter { canTarget(spell, by: u, $0) } }   // Divine Intervention: friends, dead heroes too
        if Battle.massOnly.contains(spell) { return units.filter { $0.alive && canTarget(spell, by: u, $0) } }
        switch Battle.aim(spell) {
        case .none: return spell == 16 ? [u] : []   // Heavenly Shield: the caster
        case .cell:
            guard let c = cell, c.0 >= 0, c.1 >= 0, c.0 < Battlefield.size, c.1 < Battlefield.size else { return nil }
            if Battle.areaRadius(spell) != nil { return areaMembers(spell, by: u, cell: c) }
            return []
        case .unitOrCell where targetId == nil:   // Fire Ring on a cell: 72 around it
            guard let c = cell, c.0 >= 0, c.1 >= 0, c.0 < Battlefield.size, c.1 < Battlefield.size else { return nil }
            return areaMembers(spell, by: u, centre: (c.0 * 16 + 8, c.1 * 16 + 8), radius: 72)
        default: break
        }
        guard let id = targetId, let t = units.first(where: { $0.id == id }), canTarget(spell, by: u, t) else { return nil }
        if spell == 41 {   // Fire Ring round a stack: 48 + its size x 8, the stack itself spared (0x715c50)
            return areaMembers(spell, by: u, centre: (t.x * 16 + t.size * 8, t.y * 16 + t.size * 8), radius: 48 + t.size * 8).filter { $0.id != t.id }
        }
        return [t]
    }
    /// The radius of an area spell in world units, 16 a cell (slot 18): Fireball, Kreegan Fire, Cloud
    /// of Confusion, Despair and Choking Gas 64, Inferno 112 (0x718870); nil for the others.
    public static func areaRadius(_ spell: Int) -> Int? {
        [43: 64, 67: 64, 19: 64, 25: 64, 50: 64, 66: 112][spell]
    }
    /// The stacks an area spell aimed at a cell takes in (0x717030): the centre is the cell's middle
    /// (cell x 16 + 8), a stack is in when round(distance to its footprint centre) - size x 8 < radius
    /// and the spell can land on it; friend and foe alike, in the battle's list order.
    public func areaMembers(_ spell: Int, by caster: Unit, cell: (Int, Int)) -> [Unit] {
        guard let radius = Battle.areaRadius(spell) else { return [] }
        return areaMembers(spell, by: caster, centre: (cell.0 * 16 + 8, cell.1 * 16 + 8), radius: radius)
    }
    /// The mass spells with a class of their own (0x78d5xx-0x78e8xx): every stack they can affect.
    static let massOnly: Set<Int> = [31, 34, 68, 77, 110, 114, 135, 137, 149, 32]
    /// The stacks an area holds (0x717030): round(distance from the centre to the footprint's
    /// centre) - size x 8 < radius, and the spell can affect them (0x5b63d0), friend or foe.
    func areaMembers(_ spell: Int, by u: Unit, centre: (Int, Int), radius: Int) -> [Unit] {
        units.filter { v in
            guard v.alive else { return false }
            let dx = Double(v.x * 16 + v.size * 8 - centre.0), dy = Double(v.y * 16 + v.size * 8 - centre.1)
            return Int((dx * dx + dy * dy).squareRoot().rounded()) - v.size * 8 < radius && canTarget(spell, by: u, v)
        }
    }
    /// Sparks (0x866160 / 0x8670a0): the half disc in front of the caster -- the cells (i, j) of the
    /// (size + 6)-square box from its corner - 3 with (2i + 1 - n)^2 + (2j + 1 - n)^2 <= n^2 + 2,
    /// within 90 degrees of its facing; every stack on one (not the caster) the spell can affect.
    func sparksTargets(by u: Unit, facing d: Int) -> [Unit] {
        let n = u.size + 6
        let cx = Double(u.x * 16 + u.size * 8), cy = Double(u.y * 16 + u.size * 8)
        var hit: [Unit] = []
        for i in 0..<n { for j in 0..<n where (2 * i + 1 - n) * (2 * i + 1 - n) + (2 * j + 1 - n) * (2 * j + 1 - n) <= n * n + 2 {
            let x = u.x - 3 + i, y = u.y - 3 + j
            let a = atan2(Double(y * 16 + 8) - cy, Double(x * 16 + 8) - cx) * 180 / .pi
            var diff = abs(a - Double(d) * 45).truncatingRemainder(dividingBy: 360)
            if diff > 180 { diff = 360 - diff }
            guard 2 * diff <= 180 else { continue }
            for v in units where v.alive && v.id != u.id && !hit.contains(where: { $0.id == v.id }) && x >= v.x && x < v.x + v.size && y >= v.y && y < v.y + v.size {
                if canTarget(14, by: u, v) { hit.append(v) }
            }
        } }
        return hit
    }
    /// Sparks aims like a melee attack (0x8674a0 / 0x867720): of the places the caster can strike
    /// the target from this turn, the one whose direction from the target is nearest the pointer's;
    /// it walks there, faces the target and casts.
    func sparksPosition(_ u: Unit, _ t: Unit, pointer: (Int, Int)?) -> (Int, Int)? {
        let tc = (Double(t.x * 16 + t.size * 8), Double(t.y * 16 + t.size * 8))
        let p = pointer.map { (Double($0.0 * 16 + 8), Double($0.1 * 16 + 8)) } ?? (Double(u.x * 16 + u.size * 8), Double(u.y * 16 + u.size * 8))
        let want = atan2(p.1 - tc.1, p.0 - tc.0)
        var best: (Int, Int)? = nil, bestDiff = Double.infinity
        var places = Array(reachable(u).keys).map { ($0 / Battlefield.size, $0 % Battlefield.size) }
        places.append((u.x, u.y))
        for (x, y) in places where Battle.inReach(x, y, u.size, t, reach: 0) && !overlaps(x, y, u.size, except: u.id) {
            let a = atan2(Double(y * 16 + u.size * 8) - tc.1, Double(x * 16 + u.size * 8) - tc.0)
            var diff = abs(a - want).truncatingRemainder(dividingBy: 2 * .pi)
            if diff > .pi { diff = 2 * .pi - diff }
            if diff < bestDiff { bestDiff = diff; best = (x, y) }
        }
        return best
    }

    /// Cast by the current unit on a target stack (nil for untargeted spells), a cell (area
    /// spells), a second stack (Sacrifice). Ends the unit's turn.
    @discardableResult
    public func cast(_ spell: Int, on targetId: Int?, at cell: (Int, Int)? = nil, second: Int? = nil, tables: RuleTables? = nil) -> Bool {
        if let t = tables { self.tables = t }
        let tables = self.tables
        guard finished == nil, let u = current, var c = u.caster, castable(u).contains(spell) else { return false }
        let s = RuleTables.spells[spell]
        guard let targets = castTargets(spell, by: u, target: targetId, cell: cell) else { return false }
        // where the field spells go must be good before anything is spent
        switch spell {
        case 178: guard let t = targets.first, let c = cell, teleportOK(t, to: c) else { return false }
        case 134: guard let c = cell, rockOK(c, by: u) else { return false }
        case 123: guard let c = cell, quicksandOK(c.0, c.1) else { return false }
        case 142: guard let c = cell, Battlefield.onField(c.0, c.1) else { return false }
        default: break
        }
        if spell == 136 || spell == 79 {   // Sacrifice, Martyr: a second friendly stack
            guard let sid = second, sid != targetId, let t2 = units.first(where: { $0.id == sid }), canTarget(spell, by: u, t2) else { return false }
        }
        beginAction(u)
        let cost = self.cost(spell, by: u)
        c.spellPoints -= cost
        u.caster = c
        // Magic Leech: its caster gets 1 spell point per 2 the target spends
        if u.stats.under(73), let lid = u.leechedBy, let l = units.first(where: { $0.id == lid }), l.alive, var lc = l.caster { lc.spellPoints += cost / 2; l.caster = lc }
        let p = power(spell, by: u, creatures: tables)
        events.append(.cast(unit: u.id, spell: spell, targets: targets.map { $0.id }))
        let mark = events.count
        if Battle.areaRadius(spell) != nil || spell == 41,
           let c = cell ?? targets.first(where: { $0.id == targetId }).map({ ($0.x + $0.size / 2, $0.y + $0.size / 2) }) ?? units.first(where: { $0.id == targetId }).map({ ($0.x + $0.size / 2, $0.y + $0.size / 2) }) {
            events.append(.castAt(unit: u.id, spell: spell, cell: c))
        }
        // the effect it leaves: the mass spell's single one, Cloud of Confusion's Confusion, and the
        // remap 0x865580 (Luck -> Fortune, Morale -> Mirth, Immortality -> Guardian Angel)
        let effectSpell = Battle.massOf[spell] ?? [19: 21, 70: 48, 103: 148, 116: 53][spell] ?? spell
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
        case "damage" where spell == 60 && targets.first.map({ side(of: $0) == side(of: u) }) == true:
            // Holy Water on the caster: Bless and Death Ward (0x61d850 / 0x61d943)
            if let t = targets.first {
                for e in [10, 118] { apply(e, to: t, power: p); events.append(.spellHit(unit: t.id, spell: e, damage: 0, killed: 0, left: t.stats.count)) }
            }
        case "damage":
            if spell == 14, let t = targets.first {   // Sparks: walk to the striking place, then the half disc
                guard let pos = sparksPosition(u, t, pointer: cell) else { break }
                if pos != (u.x, u.y), let path = path(u, to: pos.0, pos.1) {
                    events.append(.move(unit: u.id, path: path, from: (u.x, u.y), flying: u.stats.has("flying")))
                    u.x = pos.0; u.y = pos.1; release(by: u)
                }
                Battle.face(u, towards: t)
                let a = atan2(t.centre.1 - u.centre.1, t.centre.0 - u.centre.0)
                let d = (Int((a / (.pi / 4)).rounded()) % 8 + 8) % 8
                for v in sparksTargets(by: u, facing: d) { strike(v, spellDamage(v, p, spell), spell: spell, by: u) }
                break
            }
            var drained = 0
            for t in targets {
                let d = min(spellDamage(t, p, spell), t.stats.totalHealth)
                strike(t, d, spell: spell, by: u)
                drained += d / 2
            }
            if spell == 68, drained > 0 {   // Life Drain: the caster gets half of what each lost (0x78ec60)
                let before = u.stats.totalHealth
                restore(u, drained)
                events.append(.spellHit(unit: u.id, spell: spell, damage: before - u.stats.totalHealth, killed: 0, left: u.stats.count))
            }
            // Chain Lightning (0x5c7bf0): the power halves before each jump, to the nearest stack not
            // yet struck the spell can affect (squared distance between centres from the last one,
            // ties at random), at most five stacks, until the power is gone
            if spell == 17, let first = targets.first {
                var hit: Set<Int> = [first.id], from = first, pw = p
                while hit.count < 5 {
                    pw /= 2
                    guard pw > 0 else { break }
                    let cands = units.filter { $0.alive && !hit.contains($0.id) && canTarget(17, by: u, $0) }
                    func d2(_ v: Unit) -> Int { let dx = v.x * 16 + v.size * 8 - from.x * 16 - from.size * 8, dy = v.y * 16 + v.size * 8 - from.y * 16 - from.size * 8; return dx * dx + dy * dy }
                    guard let m = cands.map(d2).min() else { break }
                    let ties = cands.filter { d2($0) == m }
                    let next = ties[rng.next() % ties.count]
                    strike(next, spellDamage(next, pw, spell), spell: spell, by: u)
                    hit.insert(next.id); from = next
                }
            }
        case _ where spell == 30:   // Divine Intervention (0x78d5d0): curses off, the top creature healed, dead heroes back
            for t in targets {
                for e in t.stats.effects where RuleTables.spells.indices.contains(e) && RuleTables.spells[e].has("Curse") { remove(e, from: t) }
                let healed = t.alive ? min(p, t.stats.wounds) : restore(t, p)
                if t.alive { t.stats.wounds -= healed }
                events.append(.spellHit(unit: t.id, spell: spell, damage: -healed, killed: 0, left: t.stats.count))
            }
        case _ where spell == 5:   // Banish (0x61b698): whole summoned creatures, after resistance
            for t in targets {
                let hp = max(1, t.stats.hitPoints)
                strike(t, spellDamage(t, p, spell, by: u) / hp * hp, spell: spell, by: u)
            }
        case _ where [27, 83, 15, 81, 35, 84, 3].contains(spell):
            // Dispel: every spell without NoDispel (0x5f03d8); Cancellation the dispellable Bless and
            // Summ ones (0x5f02fc); Exorcism the dispellable Curse ones (0x61ca30); Anti-Magic
            // dispels, then makes the stack immune (0x5f025d)
            for t in targets {
                if side(of: t) != side(of: u), s.has("Resisted") || s.has("ResIfEnemy") {
                    let r = resistance(t, to: spell, by: u)
                    if r >= 100 || rng.next() % 100 < r { events.append(.resisted(unit: t.id, spell: spell)); continue }
                }
                dispel(t, kind: [27: 0, 83: 0, 3: 0, 15: 1, 81: 1, 35: 2, 84: 2][spell] ?? 0)
                if spell == 3 { apply(3, to: t, power: p) }
                events.append(.spellHit(unit: t.id, spell: effectSpell, damage: 0, killed: 0, left: t.stats.count))
            }
        case _ where spell == 150 || spell == 149:
            // Steal Enchantment (0x878040): a random blessing without NoDispel that some friend of the
            // caster can take goes to a random such friend, with its power; Steal All Enchantments
            // (0x878950) steals from every enemy until nothing is left
            for t in targets {
                while true {
                    let friends = units.filter { $0.alive && !hostile($0, u) }
                    let eligible = t.stats.effects.sorted().filter { e in
                        e < RuleTables.spells.count && RuleTables.spells[e].has("Bless") && !RuleTables.spells[e].has("NoDispel") && friends.contains { canTarget(e, by: u, $0) }
                    }
                    guard !eligible.isEmpty else { break }
                    let e = eligible[rng.next() % eligible.count]
                    let takers = friends.filter { canTarget(e, by: u, $0) }
                    let r = takers[rng.next() % takers.count]
                    let pw = t.powers[e] ?? 0
                    remove(e, from: t)
                    apply(e, to: r, power: pw)
                    events.append(.spellHit(unit: r.id, spell: e, damage: 0, killed: 0, left: r.stats.count))
                    if spell == 150 { break }
                }
            }
        case _ where spell == 178 || spell == 28:
            // Teleport (0x87e840 / 0x87f300): to the chosen cell; Displacement (0x8604e0 / 0x8602a0):
            // pushed away from the pointer, a cell a step, as far as 8 cells while the way is free.
            // An enemy resists first (Resisted if Enemy)
            for t in targets {
                if hostile(t, u) {
                    let r = resistance(t, to: spell, by: u)
                    if r >= 100 || rng.next() % 100 < r { events.append(.resisted(unit: t.id, spell: spell)); continue }
                }
                let from = (t.x, t.y)
                let to = spell == 178 ? cell ?? from : displacement(t, pointer: cell ?? from)
                guard to != from else { continue }
                release(by: t); t.boundBy = nil
                t.x = to.0; t.y = to.1
                events.append(spell == 178 ? .teleported(unit: t.id, from: from, to: to) : .displaced(unit: t.id, from: from, to: to))
            }
        case _ where spell == 123:   // Quicksand: power cells painted from the chosen one (0x7f2dd0 / 0x7f27f0)
            if let c = cell {
                var painted: [Int] = []
                var ring = [(c.0, c.1)], seen: Set<Int> = [Battlefield.key(c.0, c.1)]
                while painted.count < p, !ring.isEmpty {
                    ring.sort { ($0.0 - c.0) * ($0.0 - c.0) + ($0.1 - c.1) * ($0.1 - c.1) < ($1.0 - c.0) * ($1.0 - c.0) + ($1.1 - c.1) * ($1.1 - c.1) }
                    let (x, y) = ring.removeFirst()
                    if quicksandOK(x, y) { painted.append(Battlefield.key(x, y)); quicksand.insert(Battlefield.key(x, y)) }
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where Battlefield.onField(x + dx, y + dy) && !seen.contains(Battlefield.key(x + dx, y + dy)) {
                        seen.insert(Battlefield.key(x + dx, y + dy)); ring.append((x + dx, y + dy))
                    }
                }
                events.append(.obstacle(spell: spell, cells: painted.map { ($0 / Battlefield.size, $0 % Battlefield.size) }))
            }
        case _ where spell == 142:   // Smoke (0x87b630): a 4 x 4 cloud from the cell - 1, halving shots through it
            if let c = cell {
                var cells: [(Int, Int)] = []
                for i in -1...2 { for j in -1...2 where Battlefield.onField(c.0 + i, c.1 + j) { smoke.insert(Battlefield.key(c.0 + i, c.1 + j)); cells.append((c.0 + i, c.1 + j)) } }
                events.append(.obstacle(spell: spell, cells: cells))
            }
        case _ where spell == 134:   // Rock Growth (0x87a770): a 3 x 3 rock from the cell - 1, blocking
            if let c = cell {
                var cells: [(Int, Int)] = []
                for i in -1...1 { for j in -1...1 { field.blockCell(c.0 + i, c.1 + j); cells.append((c.0 + i, c.1 + j)) } }
                events.append(.obstacle(spell: spell, cells: cells))
            }
        case "resurrection":   // Resurrection (0x804020): back to the stack it was
            if let t = targets.first { resurrect(t, power: p, spell: spell) }
        case "summoning" where s.has("Bodies"):   // Raise Skeletons / Ghost / Vampires, Animate Dead, Death Call (0x8058f0)
            if let t = targets.first { raise(spell, power: p, by: u, from: t) }
        case _ where spell == 79:   // Martyr (0x78b620): the second pick's damage goes to the first
            if let t = targets.first, let sid = second, let t2 = units.first(where: { $0.id == sid }) {
                apply(79, to: t2, power: p); t2.martyr = t.id
                events.append(.spellHit(unit: t2.id, spell: spell, damage: 0, killed: 0, left: t2.stats.count))
            }
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
                // the top creature's wounds (never the dead); only Heal (t_heal 0x61c650) also cures Poison,
                // Stun and Plague, Bind Wound heals and nothing more (0x61c190)
                let healed = min(p, t.stats.wounds)
                t.stats.wounds -= healed
                if [56, 88, 139].contains(spell) { for e in [111, 154, 110] { remove(e, from: t) } }
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
                if effectSpell == 73 { t.leechedBy = u.id }
                if effectSpell != 54 { events.append(.spellHit(unit: t.id, spell: effectSpell, damage: 0, killed: 0, left: t.stats.count)) }
            }
        }
        // Magic Mirror (0x614b10 / 0x61ab00): a curse or damage spell that landed on a stack with
        // the mirror comes back on its caster at half strength, unless the caster is already under it
        if s.has("Curse") || s.has("Dmg"), u.alive {
            let resisted = Set(events[mark...].compactMap { e -> Int? in if case .resisted(let id, _) = e { return id }; return nil })
            for t in targets where t.stats.has("magic_mirror") && !resisted.contains(t.id) && hostile(t, u) && u.alive && !u.stats.under(effectSpell) && canTarget(spell, by: t, u, anySide: true) {
                events.append(.effect(unit: t.id, name: "magic mirror", damage: 0, killed: 0, left: t.stats.count))
                if s.kind == "damage" { strike(u, spellDamage(u, p / 2, spell), spell: spell, by: t) }
                else { apply(effectSpell, to: u, power: p / 2); events.append(.spellHit(unit: u.id, spell: effectSpell, damage: 0, killed: 0, left: u.stats.count)) }
            }
        }
        // Spell Shackle: 10 x the cost burns the caster, after its own resistance (0x612290 / 0x612600)
        if u.stats.under(147), u.alive { strike(u, spellDamage(u, 10 * cost, 147), spell: 147, by: u) }
        checkEnd()
        endAction(u)
        return true
    }

    /// Spell damage after resistance (0x40d000): ((100 - r) x power + 99) / 100, nothing at 100%,
    /// a quarter more under Unholy Song.
    func spellDamage(_ t: Unit, _ p: Int, _ spell: Int, by caster: Unit? = nil) -> Int {
        let r = resistance(t, to: spell, by: caster)
        var d = r >= 100 ? 0 : ((100 - r) * p + 99) / 100
        if t.stats.under(34) { d += d >> 2 }
        return d
    }
    /// A spell's damage landing on a stack, with its hit event.
    @discardableResult
    func strike(_ t: Unit, _ dmg: Int, spell: Int, by u: Unit) -> Int {
        let d = min(dmg, t.stats.totalHealth)
        let killed = wound(t, d, by: nil)
        events.append(.spellHit(unit: t.id, spell: spell, damage: d, killed: killed, left: t.stats.count))
        if !t.alive { events.append(.die(unit: t.id)) }
        flushDeferred()
        return killed
    }

    /// Teleport's destination (0x87eef0): a free place for the stack it can get to over the field,
    /// any distance, walls, obstacles and stacks in between being barriers.
    func teleportOK(_ t: Unit, to c: (Int, Int)) -> Bool {
        func free(_ x: Int, _ y: Int) -> Bool { field.fits(x, y, size: t.size) && !overlaps(x, y, t.size, except: t.id) }
        guard free(c.0, c.1) else { return false }
        var seen: Set<Int> = [Battle.key(t.x, t.y)], queue = [(t.x, t.y)]
        while !queue.isEmpty {
            let (x, y) = queue.removeLast()
            if (x, y) == c { return true }
            for st in Battle.steps {
                let nx = x + st.dx, ny = y + st.dy, k = Battle.key(nx, ny)
                guard nx >= 0, ny >= 0, nx < Battlefield.size, ny < Battlefield.size, !seen.contains(k), free(nx, ny) else { continue }
                seen.insert(k); queue.append((nx, ny))
            }
        }
        return false
    }
    /// Displacement's push (0x8609f0 / 0x860120): the vector from the pointer to the stack's
    /// centre, 10 long (truncated); k = 1...8 steps of k x v / max(|vx|, |vy|) while within 8 cells
    /// and free; it ends on the last free one.
    func displacement(_ t: Unit, pointer: (Int, Int)) -> (Int, Int) {
        let dx = Double(t.x * 16 + t.size * 8 - (pointer.0 * 16 + 8)), dy = Double(t.y * 16 + t.size * 8 - (pointer.1 * 16 + 8))
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0 else { return (t.x, t.y) }
        let vx = Int(10 * dx / len), vy = Int(10 * dy / len), m = max(abs(vx), abs(vy))
        guard m > 0 else { return (t.x, t.y) }
        var end = (t.x, t.y)
        for k in 1...8 {
            let ox = k * vx / m, oy = k * vy / m
            if ox * ox + oy * oy > 64 { break }
            let x = t.x + ox, y = t.y + oy
            guard field.fits(x, y, size: t.size), !overlaps(x, y, t.size, except: t.id) else { break }
            end = (x, y)
        }
        return end
    }
    /// A cell quicksand can go on (0x7f2210): on the field, passable, no living stack on it, not yet quicksand.
    func quicksandOK(_ x: Int, _ y: Int) -> Bool {
        field.isOpen(x, y) && !quicksand.contains(Battlefield.key(x, y)) && !overlaps(x, y, 1, except: -1)
    }
    /// Rock Growth's place (0x87a590): the 3 x 3 cells free and on the field, every enemy stack at
    /// least 5 cells from its edge.
    func rockOK(_ c: (Int, Int), by u: Unit) -> Bool {
        for i in -1...1 { for j in -1...1 where !field.isOpen(c.0 + i, c.1 + j) || overlaps(c.0 + i, c.1 + j, 1, except: -1) { return false } }
        for v in units where v.alive && hostile(v, u) {
            let gx = max(0, max(v.x - (c.0 + 1), (c.0 - 1) - (v.x + v.size - 1))), gy = max(0, max(v.y - (c.1 + 1), (c.1 - 1) - (v.y + v.size - 1)))
            if max(gx, gy) < 5 { return false }
        }
        return true
    }

    /// Spells a dispel takes off (kind 0 all, 1 the Bless and Summ ones, 2 the Curse ones), never
    /// those with NoDispel; a summoned stack whose summon goes vanishes.
    func dispel(_ t: Unit, kind: Int) {
        for e in t.stats.effects where e < RuleTables.spells.count {
            let d = RuleTables.spells[e]
            guard !d.has("NoDispel") else { continue }
            if kind == 1, !(d.has("Bless") || d.has("Summ")) { continue }
            if kind == 2, !d.has("Curse") { continue }
            remove(e, from: t)
            if t.summoned, t.summonedBy == e, t.alive {
                t.permanentlyLost = t.initialCount; t.stats.count = 0; t.stats.wounds = 0
                events.append(.die(unit: t.id)); events.append(.bodiesGone(unit: t.id))
            }
        }
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
        // what it takes off (add_spell 0x5f0220): Bless / Curse, Fortune / Misfortune, Haste and
        // Speed / Slow and Fatigue, Despair and Sorrow take Mirth off, Mirth Sorrow, Berserk / Song
        // of Peace, Necromancy Ward the raising spells
        let opposite: [Int: [Int]] = [10: [23], 23: [10], 48: [102], 102: [48], 55: [105, 141], 104: [105, 141], 105: [55, 104], 141: [55, 104],
                                      25: [148], 145: [148], 148: [145], 6: [144], 144: [6], 135: [2, 24, 124, 125, 126]]
        for o in opposite[spell] ?? [] { remove(o, from: t) }
        // the fixed lengths (§1), a turn more when it lands on the stack whose turn it is
        let lengths: [Int: Int] = [21: 1, 154: 1, 144: 1, 138: 1, 174: 1, 122: 2, 180: 2, 186: 2, 11: 3, 22: 3, 62: 3, 137: 6]
        if let n = lengths[spell] { t.durations[spell] = n + (current?.id == t.id ? 1 : 0) }
        switch spell {
        case 23: t.stats.cursed = true
        case 185: t.stats.weakened = true
        case 1: t.stats.aged = true
        case 9: t.stats.bound = true
        case 62, 138:   // on a stack already hypnotized it frees it (0x5f05d7)
            if t.hypnotized || t.stats.under(62) || t.stats.under(138) { remove(62, from: t); remove(138, from: t); return }
            t.hypnotized = true
        case 53: t.powers[53] = min(p, t.stats.count); t.stats.effects.insert(53); return   // lives, at most its count (0x5f0382)
        case 54:   // Hand of Death (0x61d6af): exactly min(power, count) creatures die (0x5f3cb0)
            let n = min(p, t.stats.count)
            t.stats.count -= n
            if t.stats.count == 0 { t.stats.wounds = 0 }
            if t.side == 1 { experience += n * t.stats.experience }
            events.append(.spellHit(unit: t.id, spell: 54, damage: 0, killed: n, left: t.stats.count))
            if !t.alive { events.append(.die(unit: t.id)) }
            return
        case 76:   // Mana (0x5f0505): spell points for the target, 25 x pct / 100
            if var c = t.caster { c.spellPoints += p; t.caster = c }
            return
        default: break
        }
        t.stats.effects.insert(spell)
        t.powers[spell] = p
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
        if t.stats.count > before { events.append(.revived(unit: t.id, spell: spell, count: t.stats.count - before, rose: before == 0)) }
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
    func summon(_ cr: CreatureDef, count: Int, spell: Int, by u: Unit, at corpse: Unit? = nil, phantomOf: Combatant? = nil, copyOf: Int? = nil) -> Unit? {
        if let old = units.first(where: { $0.alive && $0.summoned && $0.summonedBy == spell && $0.side == side(of: u) && $0.keyword == cr.keyword }) {
            old.stats.count += count
            old.initialCount += count
            events.append(.revived(unit: old.id, spell: spell, count: count, rose: false))
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
        // a phantom slides off its original, a raised stack rises from the bodies, a summon fades in
        if let o = copyOf { events.append(.phantom(unit: nu.id, of: o)) }
        else if RuleTables.spells[spell].has("Bodies") { events.append(.revived(unit: nu.id, spell: spell, count: count, rose: true)) }
        else { events.append(.summon(unit: nu.id)) }
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
        summon(cr, count: n, spell: spell, by: u, phantomOf: copy, copyOf: t.id)
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

    /// Every target the spell could be cast at now: nil for spells without one, the stacks it can
    /// land on, the centre cells of the stacks for the area spells.
    func aiTargets(_ spell: Int, by u: Unit) -> [(target: Int?, cell: (Int, Int)?)] {
        switch Battle.aim(spell) {
        case .none: return [(nil, nil)]
        case .cell: return units.filter { $0.alive }.map { (nil, ($0.x + $0.size / 2, $0.y + $0.size / 2)) }
        case .unit, .unitOrCell, .unitAndPoint: return units.filter { canTarget(spell, by: u, $0) }.map { ($0.id, nil) }
        case .twoUnits, .unitThenCell: return []
        }
    }
    /// The stacks a cast would touch (for the computer's estimate).
    func aiAffected(_ spell: Int, by u: Unit, target: Int?, cell: (Int, Int)?) -> [Unit] {
        if spell == 14, let t = units.first(where: { $0.id == target }) {
            guard let pos = sparksPosition(u, t, pointer: nil) else { return [] }
            let (ox, oy) = (u.x, u.y); u.x = pos.0; u.y = pos.1
            let a = atan2(t.centre.1 - u.centre.1, t.centre.0 - u.centre.0)
            let list = sparksTargets(by: u, facing: (Int((a / (.pi / 4)).rounded()) % 8 + 8) % 8)
            u.x = ox; u.y = oy
            return list
        }
        return castTargets(spell, by: u, target: target, cell: cell) ?? []
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

extension Battlefield {
    /// A cell made impassable during the battle (Rock Growth).
    mutating func blockCell(_ x: Int, _ y: Int) {
        guard Battlefield.onField(x, y) else { return }
        blocked[x * Battlefield.size + y] = true
    }
}
