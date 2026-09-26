import Foundation

/// Worn artifacts at work (heroes4.exe's walker 0x731c20: the 14 equipped slots -- never the
/// backpack -- then a set's bonus once all its pieces are worn, then the class's own bonuses).
extension Hero {
    /// Every effect working for this hero.
    public var artifactEffects: [ArtifactEffect] {
        var out: [ArtifactEffect] = []
        let worn = equipped.compactMap { $0 }
        var sets: [[Int]: [ArtifactEffect]] = [:]
        for id in worn {
            for e in RuleTables.effects(ofArtifact: id) {
                if e.type == 59 { sets[e.required] = e.subs } else { out.append(e) }
            }
        }
        for (req, subs) in sets where req.allSatisfy(worn.contains) { out += subs }
        out += RuleTables.classEffects[heroClass] ?? []
        return out
    }
    /// Sum of an effect type for the bearer (target 0, or 5 = everyone).
    public func artifactSum(_ type: Int, melee: Bool? = nil, ranged: Bool? = nil) -> Int {
        artifactEffects.filter { $0.type == type && ($0.target == 0 || $0.target == 5) && (melee == nil || $0.melee == melee! || (ranged != nil && $0.ranged == ranged!)) }
            .reduce(0) { $0 + $1.amount }
    }
    /// Sum for another target (1 enemy creatures, 2 enemy heroes, 3 friendly creatures, 4 other friendly heroes).
    public func artifactSum(_ type: Int, target: Int) -> Int {
        artifactEffects.filter { $0.type == type && ($0.target == target || $0.target == 5) }.reduce(0) { $0 + $1.amount }
    }
    /// Spells castable from worn items: spellbooks (with the school skill) and scrolls (without).
    public var artifactSpells: (withSkill: Set<Int>, free: Set<Int>) {
        var a: Set<Int> = [], b: Set<Int> = []
        for e in artifactEffects where e.target == 0 || e.target == 5 {
            if e.type == 0x2c { a.formUnion(e.spells) }
            if e.type == 0x04, e.spell >= 0 { b.insert(e.spell) }
        }
        return (a, b)
    }
    /// A spell's cost with the worn items (0x725300): percent and flat changes, at least 1; a
    /// scroll halves its own spell.
    public func spellCost(_ spell: Int) -> Int {
        guard spell < RuleTables.spells.count else { return 0 }
        var pct = 100, flat = 0
        for e in artifactEffects where e.type == 0x2f && (e.target == 0 || e.target == 5) && e.spells.contains(spell) {
            flat += e.amount; pct = pct * (100 + e.cost) / 100
        }
        var c = max(1, RuleTables.spells[spell].cost * pct / 100 + flat)
        if artifactSpells.free.contains(spell) && !spells.contains(spell) { c = max(1, c / 2) }
        return c
    }
    /// Spell power bonus in percent for a spell (0x725430).
    public func spellPowerBonus(_ spell: Int) -> Int {
        artifactEffects.filter { $0.type == 0x2d && ($0.target == 0 || $0.target == 5) && $0.spells.contains(spell) }.reduce(0) { $0 + $1.amount }
    }
    /// Abilities the worn items give the bearer.
    public var artifactAbilities: [String] { artifactEffects.filter { $0.type == 0x38 && ($0.target == 0 || $0.target == 5) }.map { $0.ability } }

    // MARK: equipping (0x72a4f0 / 0x537b00 / 0x72a330)

    static let slotIndex = ["bow": 0, "feet": 1, "head": 2, "left ring": 3, "neck": 8, "right ring": 9, "left hand": 10, "shoulders": 11, "torso": 12, "right hand": 13]
    /// The equip slot an artifact goes to now: rings right then left, miscellany the first free of
    /// four, two-handed ones in the right hand with both hands free; nil when there is no room or
    /// it cannot be worn (backpack items, potions).
    public func slot(for id: Int, tables: RuleTables?) -> Int? {
        let id = RuleTables.artifactBase(id)
        guard id < RuleTables.artifactIds.count, let a = tables?.artifacts[RuleTables.artifactIds[id]] else { return nil }
        let s = a.slot.lowercased()
        switch s {
        case "ring": return [9, 3].first { equipped[$0] == nil }
        case "miscellaneous": return [4, 5, 6, 7].first { equipped[$0] == nil }
        case "both hands": return equipped[13] == nil && equipped[10] == nil ? 13 : nil
        case "left hand": return equipped[10] == nil && !twoHanded(tables) ? 10 : nil
        default:
            guard let k = Hero.slotIndex[s] else { return nil }
            return equipped[k] == nil ? k : nil
        }
    }
    func twoHanded(_ tables: RuleTables?) -> Bool {
        guard let r = equipped[13].map(RuleTables.artifactBase), r < RuleTables.artifactIds.count else { return false }
        return tables?.artifacts[RuleTables.artifactIds[r]]?.slot.lowercased() == "both hands"
    }
    /// Put on a backpack item (index), if it has a free slot.
    @discardableResult
    public func equip(backpackIndex i: Int, tables: RuleTables?) -> Bool {
        guard backpack.indices.contains(i), let s = slot(for: backpack[i], tables: tables) else { return false }
        equipped[s] = backpack.remove(at: i)
        // a parchment teaches its spell when put on (0x7263a0) and is used up; one the hero cannot
        // learn yet stays where it was put
        if let a = equipped[s], RuleTables.artifactBase(a) == 0x7c, let sp = RuleTables.artifactSpell(a), !spells.contains(sp), canLearn(sp) {
            spells.insert(sp); equipped[s] = nil
        }
        return true
    }
    /// Take off an equipped item into the backpack.
    public func unequip(slot s: Int) {
        guard equipped.indices.contains(s), let a = equipped[s] else { return }
        equipped[s] = nil
        backpack.append(a)
    }
}

extension RuleTables {
    /// A parchment (0x7c) or scroll (0xa6) with its spell (0x664190 / 0x663d10): the base id in the
    /// low 16 bits, the spell + 1 above; every other artifact is its plain id.
    public static func artifact(_ base: Int, spell: Int) -> Int { base | ((spell + 1) << 16) }
    public static func artifactBase(_ id: Int) -> Int { id & 0xffff }
    public static func artifactSpell(_ id: Int) -> Int? { id >> 16 > 0 ? (id >> 16) - 1 : nil }
    /// The artifact's effects, a parchment's or scroll's naming its own spell.
    public static func effects(ofArtifact id: Int) -> [ArtifactEffect] {
        let base = artifactEffects[artifactBase(id)] ?? []
        guard let sp = artifactSpell(id) else { return base }
        return base.map { e in
            var e = e
            if e.spell >= 0 { e.spell = sp }
            if !e.spells.isEmpty { e.spells = [sp] }
            return e
        }
    }
}

extension GameState {
    /// Daily income of the worn items (0x12), for every hero.
    public var artifactIncome: [String: Int] {
        var out: [String: Int] = [:]
        for h in heroes.flatMap({ [$0] + $0.companions }) {
            for e in h.artifactEffects where e.type == 0x12 {
                for (m, n) in e.income.enumerated() where n > 0 && m < GameState.materialNames.count { out[GameState.materialNames[m], default: 0] += n }
            }
        }
        return out
    }
}
