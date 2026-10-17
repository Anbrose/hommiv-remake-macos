import Foundation

/// A place a month's creature may appear: a neutral stack was beaten there (heroes4.exe's
/// 40-byte record, ctor 0x802ce0, re/month_events_spec.md). The fields are the beaten army's
/// t_army +0xec.., -1 when it was not itself spawned by a month.
public struct MonthSpawnRecord: Codable, Equatable {
    /// The creature alignment (0 life ... 5 might), -1 unknown.
    public var alignment: Int
    /// The army's value and bonus (value capped at 700, value + bonus too), and the two fields
    /// the record only carries along (+8, +0x14) and the byte +0x11.
    public var value: Int, field8: Int, bonus: Int, field14: Int, flag11: Int
    /// The cell is not land (0x405350 false).
    public var water: Bool
    public var x: Int, y: Int, z: Int
    public init(alignment: Int, value: Int, field8: Int, bonus: Int, field14: Int, flag11: Int, water: Bool, x: Int, y: Int, z: Int) {
        self.alignment = alignment; self.field8 = field8; self.field14 = field14; self.flag11 = flag11
        self.water = water; self.x = x; self.y = y; self.z = z
        if value > 700 { self.value = 700; self.bonus = 0 }
        else { self.value = value; self.bonus = value + bonus > 700 ? 700 - value : bonus }
    }
    /// The record's worth (0x803030): ftol(value + 0.5) + bonus (ftol truncates: -1 + 0.5 -> 0).
    public var worth: Int { Int(Double(value) + 0.5) + bonus }
}

/// What a month-spawned stack keeps of its record (t_army +0xec alignment, +0xf0 value, +0xf4,
/// +0xf8 bonus, +0xb4, +0xb8), so that beating it leaves the same record behind.
public struct MonthOrigin: Codable, Equatable {
    public var alignment: Int, value: Int, field8: Int, bonus: Int, field14: Int, flag11: Int
}

/// "Month of the <Creature>" (heroes4.exe 0x4d8c50 spawn, 0x4d8ef0 pick, 0x4b3710 announcement).
extension GameState {
    /// The creature sets of the month code: W (0x4cb030: mermaid, pirate, sea monster, water
    /// elemental) for water places, L (everything but the first three) for land places.
    static let monthWater: Set<String> = ["mermaid", "pirate", "sea monster", "water elemental"]
    static func monthLand(_ kw: String) -> Bool { !["mermaid", "pirate", "sea monster"].contains(kw) }
    static let alignmentIds = ["life", "order", "death", "chaos", "nature", "might"]
    static func alignmentId(_ d: CreatureDef) -> Int { alignmentIds.firstIndex(of: d.alignment.lowercased()) ?? -1 }
    var monthExpansion: Int { max(0, min(2, map.version - 27)) }

    func monthCellIsWater(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        z < map.cells.count && x >= 0 && y >= 0 && x < map.size && y < map.size && map.cells[z][x * map.size + y]?.type == 0
    }

    /// The record a beaten neutral stack leaves (0x522f70 / 0x525c50).
    func monthRecord(of m: Monster) -> MonthSpawnRecord {
        let o = m.origin
        return MonthSpawnRecord(alignment: o?.alignment ?? -1, value: o?.value ?? -1, field8: o?.field8 ?? -1, bonus: o?.bonus ?? -1,
                                field14: o?.field14 ?? -1, flag11: o?.flag11 ?? 0xff, water: monthCellIsWater(m.x, m.y, m.z), x: m.x, y: m.y, z: m.z)
    }
    /// A neutral stack lost a battle: its place is remembered (0x522f3a, 0x4ce6c0).
    func rememberMonthSpawn(_ m: Monster) {
        guard m.bank == nil else { return }
        monthSpawns.append(monthRecord(of: m))
    }

    /// The game starts: the first draw (0x4d1db2). Month 1 is the peasant's (never announced).
    public func setupMonths() {
        monthCreature = "peasant"; nextMonthCreature = "peasant"
        pickNextMonthCreature()
    }

    /// 0x4d8ef0: this month becomes the drawn one and the next is drawn. `day` is the remake's
    /// (1-based) day; the exe's is one less.
    public func pickNextMonthCreature() {
        guard let t = tables else { return }
        let ids = RuleTables.creatureIds
        let defs = ids.map { t.creature($0) }
        let records = monthSpawns.isEmpty ? monsters.filter { $0.bank == nil }.map { monthRecord(of: $0) } : monthSpawns
        let monthStart = 28 * ((day - 1) / 28 + 1)
        // per bucket (alignment 0..5, 6 water): value sums, record counts; per creature: records it fits
        var sums = [Int](repeating: 0, count: 7), counts = [Int](repeating: 0, count: 7)
        var fits = [Int](repeating: 0, count: ids.count)
        var bits = Set<Int>()
        for r in records {
            let v = r.worth
            let b = r.water ? 6 : r.alignment
            if (0...6).contains(b) { sums[b] += v; counts[b] += 1 }
            else if b == -1 { sums[6] += 1 }   // the exe's N[-1] += 1 lands on S[6] (S[-1] is a dead local)
            for (i, d) in defs.enumerated() {
                guard let d = d, d.experience <= v else { continue }
                if r.water {
                    if GameState.monthWater.contains(ids[i]) { fits[i] += 1; bits.insert(6) }
                } else if GameState.monthLand(ids[i]), GameState.alignmentId(d) == r.alignment {
                    fits[i] += 1; bits.insert(r.alignment)
                }
            }
        }
        var list: [Int] = []
        let total = bits.reduce(0) { $0 + sums[$1] }
        if total > 0 {
            var r = random.next() % total
            var bucket = 5
            for b in 0..<7 where bits.contains(b) {
                r -= sums[b]
                if r <= 0 { bucket = b; break }
            }
            for pass in 0..<2 where list.isEmpty {
                for (i, d) in defs.enumerated() {
                    guard let d = d, d.expansion <= monthExpansion else { continue }
                    if bucket == 6 { guard GameState.monthWater.contains(ids[i]) else { continue } }
                    else { guard GameState.monthLand(ids[i]), GameState.alignmentId(d) == bucket else { continue } }
                    if pass == 0 {
                        guard 4 * fits[i] >= counts[bucket], d.level <= 2 || monthStart > 28 else { continue }
                    } else if fits[i] == 0 { continue }
                    list.append(i)
                }
            }
        }
        if list.isEmpty {   // the fallback: every level-1 creature the map allows
            list = defs.indices.filter { defs[$0].map { $0.level == 1 && $0.expansion <= monthExpansion } ?? false }
        }
        monthCreature = nextMonthCreature
        if !list.isEmpty { nextMonthCreature = ids[list[random.next() % list.count]] }
    }

    /// 0x4d8c50: the month starting now sends its creature to the remembered places, then the
    /// next month is drawn.
    public func newMonth() {
        if let t = tables, let c = t.creature(nextMonthCreature) {
            let kw = nextMonthCreature
            var spawned = false
            var i = 0
            while i < monthSpawns.count {
                let r = monthSpawns[i]
                let fits = r.water ? GameState.monthWater.contains(kw) : GameState.monthLand(kw) && r.alignment == GameState.alignmentId(c)
                if fits, r.worth >= c.experience, !spawned || random.next() % 100 + 1 <= 50, placeMonthStack(c, r) {
                    monthSpawns.remove(at: i); spawned = true
                    continue
                }
                i += 1
            }
        }
        pickNextMonthCreature()
    }

    /// 0x803060: a stack of the month's creature on a record's place. None when an army stands
    /// within 2 cells (either axis) on that level, or the cell is taken.
    func placeMonthStack(_ c: CreatureDef, _ r: MonthSpawnRecord) -> Bool {
        let armies = heroes + enemyHeroes
        if armies.contains(where: { $0.z == r.z && abs($0.x - r.x) <= 2 && abs($0.y - r.y) <= 2 }) { return false }
        let water = monthCellIsWater(r.x, r.y, r.z)
        let v = r.worth, e = max(1, c.experience)
        let count = max(1, (water ? v : 2 * v / 3) / e)
        let left = v - count * e
        guard r.z < passabilities.count, r.z < scenes.count else { return false }
        let pass = passabilities[r.z]
        guard water ? pass.isFreeWater(r.x, r.y) : pass.isFree(r.x, r.y),
              !monsters.contains(where: { $0.z == r.z && $0.x == r.x && $0.y == r.y }),
              let p = scenes[r.z].addCreature(c.keyword, x: r.x, y: r.y) else { return false }
        var m = Monster(x: r.x, y: r.y, name: p.name, creature: c.keyword, count: count)
        m.z = r.z
        m.origin = MonthOrigin(alignment: GameState.alignmentId(c), value: r.value, field8: r.field8, bonus: r.bonus, field14: r.field14, flag11: r.flag11)
        if left > 0 {   // the escort picker 0x7f32b0, as for a random monster
            var rng = GameRandom(seed: 0); rng.state = random.state
            if let q = pickCreature(alignment: c.alignment, water: water, cap: min(e, left), exclude: c.keyword,
                                    levels: (c.level - 1)...c.level, rng: &rng), q.experience > 0, left / q.experience > 0 {
                if q.keyword.lowercased() == c.keyword.lowercased() { m.count += left / q.experience }
                else { m.extra = [(q.keyword, left / q.experience)] }
            }
            random.state = rng.state
        }
        monsters.append(m)
        passabilities[r.z].block(r.x, r.y); passabilities[r.z].openTrigger(r.x, r.y, object: Int.max)
        return true
    }

    /// The human player's turn starts on a new month's first day (0x4b3710): "New Month".
    func announceMonth() {
        let name = tables?.creature(monthCreature)?.name ?? monthCreature
        let cap = name.prefix(1).uppercased() + name.dropFirst()
        let text = self.text("new_month.message", "Astrologers declare this the Month of the %capitalize_creature.")
            .replacingOccurrences(of: "%capitalize_creature", with: cap).replacingOccurrences(of: "%creature", with: name)
        scripts.messages.append(text)
        messageTitles[text] = self.text("new_month.title", "New Month")
    }

    /// The day as the exe's 0x4d8910 starts it: on every 28th day the month changes.
    func monthsNewDay() {
        guard (day - 1) % 28 == 0, day > 1 else { return }
        newMonth()
        announceMonth()
    }

    // MARK: town growth (0x899960 daily, 0x898310 the week, 0x894270 a new dwelling)

    /// The town's growth bonus in percent (0x898310): its governor's Nobility (10% a level,
    /// table 0x989248), +50 with building 40, +100 for a might town's own grail (building 11),
    /// else +25 when the owner holds a might town's grail.
    public func townGrowthBonus(_ i: Int) -> Int {
        let t = towns[i]
        var heroes = t.garrisonHeroes
        if let v = visitingArmy(town: i) { heroes += v.members }
        var bonus = [0, 10, 20, 30, 40, 50][min(5, max(0, heroes.map { $0.skill("nobility") }.max() ?? 0))]
        if isBuilt(t, 40) { bonus += 50 }
        if t.alignment == "might" && isBuilt(t, 11) { bonus += 100 }
        else if let o = t.owner, towns.contains(where: { $0.owner == o && $0.alignment == "might" && isBuilt($0, 11) }) { bonus += 25 }
        return bonus
    }
    /// A dwelling's week in 700ths of a creature (0x898310).
    public func townWeek700(_ i: Int, _ c: CreatureDef) -> Int {
        c.growth * 700 * (100 + townGrowthBonus(i)) / 100
    }
    /// Each day an owned town's dwellings grow by a seventh of their week (0x899960).
    func townsNewDay() {
        guard let t = tables else { return }
        for i in towns.indices where towns[i].owner != nil {
            for b in 12...19 where isBuilt(towns[i], b) {
                guard let kw = buildingDef(towns[i], b)?.creature, let c = t.creature(kw) else { continue }
                let total = towns[i].available[kw, default: 0] * 700 + towns[i].growthRemainder[kw, default: 0] + townWeek700(i, c) / 7
                towns[i].available[kw] = total / 700; towns[i].growthRemainder[kw] = total % 700
            }
        }
    }
    /// A dwelling just built has half a week's creatures, rounded up (0x894270).
    func dwellingBuilt(_ i: Int, _ key: String, _ c: CreatureDef) {
        let pop = (c.growth + 1) * 700 / 2
        towns[i].available[key] = pop / 700; towns[i].growthRemainder[key] = pop % 700
    }
}
