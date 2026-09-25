import Foundation

/// The game's random numbers (heroes4.exe's LCG at 0xac16f8: x = x*214013+2531011, (x>>16)&0x7fff).
public struct H4Random {
    public var state: UInt32
    public init(seed: UInt32 = UInt32.random(in: 0...UInt32.max)) { state = seed }
    public mutating func next() -> Int { state = state &* 214013 &+ 2531011; return Int((state >> 16) & 0x7fff) }
}

/// Hero classes, skills and levels, as heroes4.exe does them.
///
/// Skills are the 36 of RuleTables.skillIds: nine primaries (0...8), each with three
/// secondaries (9...35 in threes). Hero.skills holds 1 basic ... 5 grandmaster (the exe's 0...4,
/// -1 unknown). A hero knows at most five primaries, and a skill level has prerequisites
/// (0x8559f0). A level gained offers up to three skills (0x72aa10); without the choice dialog
/// the pick keeps Combat at a third and Resistance at a sixth of the level, else is random
/// (0x72bca0). The class follows the skills (0x72b670). Verified against the exe run in an
/// emulator (9000 random heroes, identical offers and RNG state).
extension Hero {
    public var classKeyword: String { RuleTables.heroClasses.indices.contains(heroClass) ? RuleTables.heroClasses[heroClass].keyword : "" }
    public func skill(id: Int) -> Int { skill(RuleTables.skillIds[id]) }
    /// The exe's level of a skill: -1 unknown, 0 basic ... 4 grandmaster.
    func lv(_ id: Int) -> Int { skill(id: id) - 1 }
    func setLv(_ id: Int, _ l: Int) { skills[RuleTables.skillIds[id]] = l + 1 }

    /// Prerequisites of learning a skill at a level (0 basic ... 4): (skill, least level) pairs.
    static let requirements: [[[(Int, Int)]]] = {
        // tactics/scouting/nobility need their secondaries from expert; magic primaries theirs from advanced
        func sec(_ a: Int, _ b: Int?, _ lv: [Int?], _ lv2: [Int?]) -> [[(Int, Int)]] {
            (0..<5).map { l in [lv[l].map { (a, $0) }, b.flatMap { b in lv2[l].map { (b, $0) } }].compactMap { $0 } }
        }
        var r = [[[(Int, Int)]]](repeating: Array(repeating: [], count: 5), count: 36)
        r[0] = sec(9, 10, [nil, nil, 0, 1, 2], [nil, nil, 0, 1, 2])
        r[2] = sec(15, nil, [nil, nil, 0, 1, 3], [])
        r[3] = sec(18, 19, [nil, nil, 0, 1, 2], [nil, nil, 0, 1, 2])
        for (p, a, b) in [(4, 21, 22), (5, 24, 25), (6, 27, 28), (7, 30, 31), (8, 33, 34)] {
            r[p] = sec(a, b, [nil, 0, 1, 2, 4], [nil, nil, 0, 2, 4])
        }
        let normal = [0, 0, 1, 1, 2], same = [0, 1, 2, 3, 3], higher = [1, 2, 2, 3, 3], stealth = [0, 1, 2, 3, 4]
        for s in 9..<36 {
            let p = RuleTables.primary(of: s)
            let row: [Int]
            switch s {
            case 17: row = stealth
            case 21, 24, 27, 30, 33: row = same
            case 22, 25, 28, 31, 34: row = higher
            default: row = normal
            }
            r[s] = row.map { [(p, $0)] }
        }
        return r
    }()
    func meets(_ s: Int, _ l: Int) -> Bool { Hero.requirements[s][l].allSatisfy { lv($0.0) >= $0.1 } }

    // MARK: the offer (0x72aa10)

    private func weight(_ s: Int, _ w: [String: Int]) -> Int {
        let x = w[RuleTables.skillIds[s]] ?? 0
        return lv(s) > -1 && x < 2 ? 2 : x
    }
    private func weightedPick(_ c: [(Int, Int)], _ w: [String: Int], _ rng: inout H4Random) -> (Int, Int)? {
        let tot = c.reduce(0) { $0 + weight($1.0, w) }
        guard tot > 0 else { return nil }
        var r = rng.next() % tot
        for e in c { r -= weight(e.0, w); if r < 0 { return e } }
        return nil
    }
    private func pickPrimaryGroup(_ out: inout [(Int, Int)], _ excl: inout [Bool], _ allowed: UInt64, _ rng: inout H4Random) {
        var a = 0x1ff
        for (s, _) in out { a &= ~(1 << RuleTables.primary(of: s)) }
        var b = 0
        var local: [(Int, Int)] = []
        for i in 0..<36 where !excl[i] {
            let p = RuleTables.primary(of: i)
            guard lv(p) != -1 else { continue }
            let l = lv(i) + 1
            guard l < 5, meets(i, l), l != 0 || allowed >> i & 1 != 0 else { continue }
            local.append((i, l)); b |= 1 << p
        }
        guard !local.isEmpty else { return }
        if out.count < 2, RuleTables.heroClasses.indices.contains(heroClass) {
            var c = 0
            for s in RuleTables.heroClasses[heroClass].skills where s < 9 { c |= 1 << s }
            if c & b != 0 { b &= c }
        }
        if a & b != 0 { b &= a }
        _ = rng.next() % b.nonzeroBitCount   // the exe draws a primary and never uses it
        local = local.filter { b >> RuleTables.primary(of: $0.0) & 1 != 0 }
        let e = local[rng.next() % local.count]
        excl[e.0] = true; out.append(e)
    }
    private func candidates(_ excl: [Bool], _ allowed: UInt64, _ nprim: Int) -> [(Int, Int)] {
        (0..<36).compactMap { i in
            let l = lv(i) + 1
            guard !excl[i], l != 0 || allowed >> i & 1 != 0, !(nprim >= 5 && i < 9 && l == 0), l < 5, meets(i, l) else { return nil }
            return (i, l)
        }
    }

    /// The skills (id, new level 0...4) a level gained offers.
    public func levelUpOffer(weights w: [String: Int], allowed: UInt64 = (1 << 36) - 1, random rng: inout H4Random) -> [(skill: Int, level: Int)] {
        var excl = [Bool](repeating: false, count: 36), out: [(Int, Int)] = []
        let nprim = (0..<9).filter { lv($0) >= 0 }.count
        var stop = false
        pickPrimaryGroup(&out, &excl, allowed, &rng)
        pickPrimaryGroup(&out, &excl, allowed, &rng)
        if nprim == 5 { pickPrimaryGroup(&out, &excl, allowed, &rng) }
        if out.count < 3, !excl[1], lv(1) < 4, !(nprim >= 5 && lv(1) <= -1), level >= lastCombatOffer + 3, allowed >> 1 & 1 != 0 {
            excl[1] = true; out.append((1, lv(1) + 1))
        }
        if out.count < 3 {
            let total = (0..<36).reduce(0) { $0 + lv($1) + 1 }
            if total / 6 < nprim { pickPrimaryGroup(&out, &excl, allowed, &rng) }
            else if nprim < 5 {
                let c = (0..<9).filter { !excl[$0] && lv($0) == -1 && allowed >> $0 & 1 != 0 && meets($0, 0) }.map { ($0, 0) }
                if let e = weightedPick(c, w, &rng) { excl[e.0] = true; out.append(e) }
                stop = true
            }
        }
        // two or more offers already: returned as they are (the exe returns early, without
        // noting a Combat offer)
        if out.count >= 2 && !stop { return out.map { (skill: $0.0, level: $0.1) } }
        while out.count < 3, let e = weightedPick(candidates(excl, allowed, nprim), w, &rng) { excl[e.0] = true; out.append(e) }
        while out.count < 3 {
            let c = candidates(excl, allowed, nprim)
            guard !c.isEmpty else { break }
            let e = c[rng.next() % c.count]
            excl[e.0] = true; out.append(e)
        }
        if out.contains(where: { $0.0 == 1 }) { lastCombatOffer = level }
        return out.map { (skill: $0.0, level: $0.1) }
    }

    /// Learn a skill at a level (0x730a30; the spells it may grant are not there yet).
    public func learn(_ s: Int, level l: Int) {
        guard lv(s) < l else { return }
        if lv(RuleTables.primary(of: s)) == -1 && (0..<9).filter({ lv($0) >= 0 }).count >= 5 { return }
        setLv(s, l)
    }

    /// The level-up pick without the dialog (0x72bca0): Combat up to a third of the level,
    /// then Resistance up to a sixth, else one of the offers at random. `lvl` is the level before.
    static func autoPick(_ offer: [(skill: Int, level: Int)], level lvl: Int, _ rng: inout H4Random) -> (skill: Int, level: Int)? {
        guard !offer.isEmpty else { return nil }
        if let e = offer.first(where: { $0.skill == 1 && $0.level <= lvl / 3 - 1 }) { return e }
        if let e = offer.first(where: { $0.skill == 14 && $0.level <= lvl / 6 - 1 }) { return e }
        return offer[rng.next() % offer.count]
    }

    /// The level the experience allows (0x72bca0: thresholds reached, at most 70).
    public static func level(for exp: Int) -> Int { max(1, Hero.experienceTable.lastIndex { $0 <= exp } ?? 1) }

    /// Levels gained, each picking its skill without the dialog. Returns the skills learned.
    @discardableResult
    public func levelUp(to target: Int, tables: RuleTables?, random rng: inout H4Random) -> [Int] {
        var learned: [Int] = []
        let w = tables?.skillWeights[classKeyword] ?? [:]
        while level < target {
            let offer = levelUpOffer(weights: w, random: &rng)
            let pick = Hero.autoPick(offer, level: level, &rng)
            level += 1
            if let p = pick { learn(p.skill, level: p.level); learned.append(p.skill) }
        }
        return learned
    }

    /// Experience for the hero: the levels it reaches are gained at once, as the exe does for
    /// heroes without the level-up dialog (the choose_skill dialog is not there yet).
    @discardableResult
    public func gainExperience(_ n: Int, tables: RuleTables?, random rng: inout H4Random) -> [Int] {
        experience += n
        return levelUp(to: min(70, Hero.level(for: experience)), tables: tables, random: &rng)
    }

    // MARK: class (0x72b670)

    /// The class the skills make: each class scores the points in its primaries' families less a
    /// penalty for how many it has (0x989a3c); the best (ties to the higher id) replaces the
    /// current one when it scores more and is one of the promoted classes (11...47).
    public func reconsiderClass() {
        var fam = [Int](repeating: 0, count: 9)
        for s in 0..<36 where lv(s) >= 0 { fam[RuleTables.primary(of: s)] += lv(s) + 1 }
        let pen = [8, 0, 1, 3, 3, 3]
        func score(_ c: Int) -> Int {
            let p = RuleTables.heroClasses[c].skills.filter { $0 < 9 }
            return p.reduce(0) { $0 + fam[$1] } - pen[min(5, p.count)]
        }
        var best = -1, bestScore = 0
        for c in 0..<48 { let v = score(c); if v >= bestScore { best = c; bestScore = v } }
        let current = RuleTables.heroClasses.indices.contains(heroClass) ? score(heroClass) : Int.min
        if best >= 11, best != heroClass, bestScore > current { heroClass = best }
    }

    // MARK: map heroes (0x7315d0)

    /// A hero as the map places it: its class (the map's, or one of the alignment's two base
    /// classes), the class skills at basic unless the map gives skills, then one automatic
    /// level-up per level to the map's level, then the class the skills make.
    public static func fromMap(_ m: MapHero, alignment: String, x: Int, y: Int, tables: RuleTables?, random rng: inout H4Random) -> Hero {
        var cls = m.heroClass
        if !RuleTables.heroClasses.indices.contains(cls) {
            let base = (0..<11).filter { RuleTables.heroClasses[$0].alignment == alignment }
            cls = base.isEmpty ? 10 : base[rng.next() % base.count]
        }
        let def = RuleTables.heroClasses[cls]
        let gender = m.gender == 0 || m.gender == 1 ? m.gender : rng.next() % 2
        // the adventure model: the class's alignment, might for the fighting base classes
        let model = ["life", "order", "death", "chaos", "nature"].contains(def.alignment) ? def.alignment : "might"
        let might = model == "might" || [0, 2, 4, 6, 8].contains(cls) || def.skills.contains { $0 < 4 }
        let h = Hero(actor: "hero.\(model)_\(might ? "might" : "magic")_\(gender == 1 ? "female" : "male")", x: x, y: y, movement: Hero.baseMovement)
        h.heroClass = cls
        h.alignment = model == "might" ? (def.alignment == "might" ? "might" : alignment) : model
        // portrait and name: the map's (a row of table.heroes), else a hero of the class
        let all = tables?.heroes ?? []
        let pool = all.filter { $0.heroClass == def.keyword && $0.sex == (gender == 1 ? "female" : "male") }
        let pick = all.indices.contains(m.portrait) ? all[m.portrait] : pool.isEmpty ? nil : pool[rng.next() % pool.count]
        h.keyword = pick?.keyword ?? ""
        h.name = m.name.isEmpty ? (pick?.name ?? "Hero") : m.name
        if let s = m.skills, s.contains(where: { $0 >= 0 }) {
            for (i, v) in s.enumerated() where v >= 0 && i < 36 { h.setLv(i, v) }
        } else {
            for s in def.skills { h.learn(s, level: 0) }
        }
        let known = (0..<36).filter { h.lv($0) >= 0 }
        let start = min(40, 1 + known.reduce(0) { $0 + h.lv($1) + 1 } - def.skills.count)
        let preset = max(1, min(70, m.level))
        h.level = min(preset, max(1, start))
        h.experience = Hero.experienceTable[preset]
        h.levelUp(to: preset, tables: tables, random: &rng)
        h.reconsiderClass()
        for (i, a) in m.equipped.enumerated() where i < 14 { h.equipped[i] = a }
        h.backpack = m.backpack
        return h
    }
}
