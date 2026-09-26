import Foundation

/// The town hall's build list and the building requirements (town_spec §1; heroes4.exe
/// t_buy_building_window 0x5a5d60, states 0x5a6670, requirement trees 0x8934b0).
public indirect enum BuildReq {
    case b(Int), not(Int), and([BuildReq]), or(BuildReq, BuildReq), none
}

extension GameState {
    /// The buildings each alignment has (0xacfbb0): prison and grail never; might no guilds.
    static func buildingExists(_ align: String, _ b: Int) -> Bool {
        let base: Set<Int> = Set(0...7).union([9, 10]).union(12...19)
        switch align {
        case "life": return base.contains(b) || (20...29).contains(b)
        case "order": return base.contains(b) || (20...26).contains(b) || b == 30 || b == 31
        case "death": return base.contains(b) || (20...26).contains(b) || b == 32 || b == 33
        case "chaos": return base.contains(b) || (20...26).contains(b) || (34...36).contains(b)
        case "nature": return base.contains(b) || (20...26).contains(b) || (37...39).contains(b)
        case "might": return base.contains(b) || [35, 40, 41, 42].contains(b)
        default: return false
        }
    }
    /// The requirement tree of building b in a town of this alignment.
    static func buildingReq(_ align: String, _ b: Int) -> BuildReq {
        func all(_ xs: BuildReq...) -> BuildReq { .and(xs) }
        let lo = BuildReq.or(.b(12), .b(13)), mid = BuildReq.or(.b(14), .b(15)), hi = BuildReq.or(.b(16), .b(17))
        switch b {
        case 0: return .none
        case 1: return .b(0)
        case 2: return .b(1)
        case 3: return .b(0)
        case 4: return .b(3)
        case 5: return .b(4)
        case 6, 7: return .b(3)
        case 9, 10: return .b(0)
        case 20: return .b(0)
        case 21...24: return .b(b - 1)
        case 25, 26: return .b(20)
        case 12: return .b(3)   // the level 1 dwellings: a fort
        case 13: return .b(3)
        default: break
        }
        switch align {
        case "life":
            switch b {
            case 14: return all(.b(3), .b(9), lo, .not(15))
            case 15: return all(.b(3), .b(13), .not(14))
            case 16: return all(.b(3), .b(10), mid, .not(17))
            case 17: return all(.b(3), .b(29), mid, .not(16))
            case 18: return all(.b(3), .b(28), .b(10), hi, .not(19))
            case 19: return all(.b(3), .b(27), hi, .not(18))
            case 27: return .b(29)
            case 28: return .b(0)
            case 29: return .b(3)
            default: return .none
            }
        case "order":
            switch b {
            case 14: return all(.b(3), .b(20), lo, .not(15))
            case 15: return all(.b(3), .b(20), lo, .not(14))
            case 16: return all(.b(3), .b(31), mid, .not(17))
            case 17: return all(.b(3), .b(25), mid, .not(16))
            case 18: return all(.b(3), .b(10), .b(30), hi, .not(19))
            case 19: return all(.b(5), hi, .not(18))
            case 30: return .b(3)
            case 31: return all(.b(1), .b(3))
            default: return .none
            }
        case "death":
            switch b {
            case 14: return all(.b(3), .b(32), lo, .not(15))
            case 15: return all(.b(3), .b(13), .not(14))
            case 16: return all(.b(3), .b(9), mid, .not(17))
            case 17: return all(.b(3), .b(20), mid, .not(16))
            case 18: return all(.b(3), .b(33), hi, .not(19))
            case 19: return all(.b(3), .b(26), hi, .not(18))
            case 32: return .b(12)
            case 33: return all(.b(3), .b(20))
            default: return .none
            }
        case "chaos":
            switch b {
            case 14: return all(.b(3), .b(20), lo, .not(15))
            case 15: return all(.b(3), .b(35), lo, .not(14))
            case 16: return all(.b(3), .b(7), mid, .not(17))
            case 17: return all(.b(3), .b(10), mid, .not(16))
            case 18: return all(.b(3), .b(26), hi, .not(19))
            case 19: return all(.b(3), .b(25), hi, .not(18))
            case 34, 35: return .b(3)
            case 36: return .b(21)
            default: return .none
            }
        case "nature":
            switch b {
            case 14: return all(.b(3), .b(39), lo, .not(15))
            case 15: return all(.b(3), .b(10), lo, .not(14))
            case 16: return all(.b(3), .b(4), mid, .not(17))
            case 17: return all(.b(3), .b(38), mid, .not(16))
            case 18: return all(.b(3), .b(37), hi, .not(19))
            case 19: return all(.b(3), .b(25), hi, .not(18))
            case 37: return all(.b(20), hi)
            case 38, 39: return .b(0)
            default: return .none
            }
        case "might":
            switch b {
            case 14: return all(.b(3), .b(7), lo, .not(15))
            case 15: return all(.b(3), .b(4), lo, .not(14))
            case 16: return all(.b(3), .b(9), mid, .not(17))
            case 17: return all(.b(3), .b(35), mid, .not(16))
            case 18: return all(.b(5), hi, .not(19))
            case 19: return all(.b(3), .b(42), .b(10), hi, .not(18))
            case 35: return .b(0)
            case 40: return hi
            case 41, 42: return .b(3)
            default: return .none
            }
        default: return .none
        }
    }
    /// The list's 20 places: {building, slot} (0x97e210, then 0x97e440[alignment]).
    static func buildSlots(_ align: String) -> [(b: Int, slot: Int)] {
        let common = [(0, 0), (1, 0), (2, 0), (3, 1), (4, 1), (5, 1), (9, 2), (10, 3), (12, 4), (13, 8), (14, 5), (15, 9), (16, 6), (17, 10), (18, 7), (19, 11), (7, 16), (6, 17)]
        let guild = [(20, 12), (21, 12), (22, 12), (23, 12), (24, 12), (25, 13), (26, 14)]
        let own: [(Int, Int)]
        switch align {
        case "life": own = guild + [(28, 15), (29, 18), (27, 19)]
        case "order": own = guild + [(31, 18), (30, 19)]
        case "death": own = guild + [(33, 15), (32, 18)]
        case "chaos": own = guild + [(36, 15), (34, 18), (35, 19)]
        case "nature": own = guild + [(37, 15), (38, 18), (39, 19)]
        case "might": own = [(40, 15), (41, 14), (42, 13), (35, 12)]
        default: own = []
        }
        return (common + own).map { (b: $0.0, slot: $0.1) }
    }

    public func buildingKeyword(_ align: String, _ b: Int) -> String? { RuleTables.buildingIds[align]?[b] }
    public func buildingId(_ align: String, _ keyword: String) -> Int? { RuleTables.buildingIds[align]?.first { $0.value == keyword }?.key }
    public func buildingDef(_ t: Town, _ b: Int) -> RuleTables.BuildingDef? {
        guard let k = buildingKeyword(t.alignment, b) else { return nil }
        return tables?.buildings(for: t.alignment).first { $0.keyword == k }
    }
    public func isBuiltPublic(_ t: Town, _ b: Int) -> Bool { isBuilt(t, b) }
    func isBuilt(_ t: Town, _ b: Int) -> Bool {
        if buildingKeyword(t.alignment, b).map({ t.buildings.contains($0) }) == true { return true }
        // a later link of a chain (hall, fort, guild) stands for the earlier ones
        for chain in [[0, 1, 2], [3, 4, 5], [20, 21, 22, 23, 24]] where chain.contains(b) {
            for later in chain where later > b { if buildingKeyword(t.alignment, later).map({ t.buildings.contains($0) }) == true { return true } }
        }
        return false
    }
    func isEnabled(_ t: Town, _ b: Int) -> Bool {
        guard let a = t.allowed, let k = buildingKeyword(t.alignment, b) else { return true }
        return a.contains(k)
    }
    /// Every requirement met now (0x894090).
    func met(_ t: Town, _ r: BuildReq) -> Bool {
        switch r {
        case .b(let x): return isBuilt(t, x)
        case .not(let x): return !isBuilt(t, x)
        case .and(let xs): return xs.allSatisfy { met(t, $0) }
        case .or(let a, let b): return met(t, a) || met(t, b)
        case .none: return true
        }
    }
    /// Can it ever be met (0x894b10): no needed building disabled, no excluding rival built.
    func possible(_ t: Town, _ r: BuildReq, depth: Int = 0) -> Bool {
        guard depth < 12 else { return true }
        switch r {
        case .b(let x): return isBuilt(t, x) || (isEnabled(t, x) && GameState.buildingExists(t.alignment, x) && possible(t, GameState.buildingReq(t.alignment, x), depth: depth + 1))
        case .not(let x): return !isBuilt(t, x)
        case .and(let xs): return xs.allSatisfy { possible(t, $0, depth: depth) }
        case .or(let a, let b): return possible(t, a, depth: depth) || possible(t, b, depth: depth)
        case .none: return true
        }
    }
    /// A building's state in the list (0x5a6670): 0 none, 1 built (gold), 2 impossible (gray),
    /// 3 requirements or built today (red X), 4 resources (red $), 5 not the owner (red), 6 can build.
    public func buildState(_ t: Town, _ b: Int) -> Int {
        guard GameState.buildingExists(t.alignment, b) else { return 0 }
        if isBuilt(t, b) { return 1 }
        let req = GameState.buildingReq(t.alignment, b)
        if !isEnabled(t, b) || !possible(t, req) { return 2 }
        if (t.owner ?? -1) != actingColour && !(t.owned && isHumanActing) { return 5 }
        if !met(t, req) { return 3 }
        if let d = buildingDef(t, b), d.cost.contains(where: { resources[$0.key, default: 0] < $0.value }) { return 4 }
        if t.builtToday { return 3 }
        return 6
    }
    /// The 20 places: the building each shows and its state (the highest state wins; on a tie the
    /// earlier entry, but the later among built ones -- so a chain shows its next step).
    public func buildList(_ t: Town) -> [(slot: Int, b: Int, state: Int)] {
        var best: [Int: (b: Int, state: Int)] = [:]
        for e in GameState.buildSlots(t.alignment) {
            let s = buildState(t, e.b)
            guard s > 0 else { continue }
            if let cur = best[e.slot] {
                if s > cur.state || (s == 1 && cur.state == 1) { best[e.slot] = (e.b, s) }
            } else { best[e.slot] = (e.b, s) }
        }
        return best.keys.sorted().map { (slot: $0, b: best[$0]!.b, state: best[$0]!.state) }
    }
    /// The requirement text (0x894920): "Requires: a, b or c. Cannot build if x is built."
    public func requirementText(_ t: Town, _ b: Int) -> String {
        func name(_ x: Int) -> String { buildingDef(t, x)?.name ?? buildingKeyword(t.alignment, x) ?? "?" }
        var needs: [String] = [], rivals: [String] = []
        func walk(_ r: BuildReq) {
            switch r {
            case .b(let x): if !isBuilt(t, x) { needs.append(name(x)) }
            case .not(let x): rivals.append(name(x))
            case .and(let xs): xs.forEach(walk)
            case .or(let a, let c):
                if !met(t, r) {
                    func flat(_ q: BuildReq) -> [String] { if case .b(let x) = q { return [name(x)] }; if case .or(let p, let q2) = q { return flat(p) + flat(q2) }; return [] }
                    needs.append((flat(a) + flat(c)).joined(separator: " \(text("or.town_build", "or")) "))
                }
            case .none: break
            }
        }
        walk(GameState.buildingReq(t.alignment, b))
        var out = ""
        if !needs.isEmpty { out = text("requires.town_build", "Requires: ") + needs.joined(separator: ", ") + "." }
        for r in rivals { out += (out.isEmpty ? "" : " ") + text("cannot_build_if.town_build", "Cannot build if ") + r + " " + text("is_built.town_build", "is built.") }
        if out.isEmpty || met(t, GameState.buildingReq(t.alignment, b)) { return text("all_requirements_met.town_build", "All requirements for this building have been met.") }
        return out
    }
}
