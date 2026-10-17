import Foundation

/// A caravan (heroes4.exe t_caravan, ctor 0x5b7990; re/caravans_logic_spec.md): seven army places
/// (creature stacks or heroes) on their way to a town. It has no place on the map -- it is never
/// drawn and cannot be intercepted -- only the day it arrives (fixed when it is sent), the town,
/// its owner and the origin's name (for the View Caravans dialog).
public final class Caravan {
    public let id: Int
    public var owner: Int
    /// The destination (index into GameState.towns).
    public var destination: Int
    /// The origin's name only: no link to the origin is kept (capturing it changes nothing).
    public var origin: String
    /// The absolute map day it arrives (map day + travel days when sent).
    public var arrivalDay: Int
    public var slots: [ArmySlot?]
    public init(id: Int, owner: Int, destination: Int, origin: String, arrivalDay: Int, slots: [ArmySlot?]) {
        self.id = id; self.owner = owner; self.destination = destination; self.origin = origin; self.arrivalDay = arrivalDay
        self.slots = slots + [ArmySlot?](repeating: nil, count: max(0, GameState.rowSlots - slots.count))
    }
    public var isEmpty: Bool { !slots.contains { $0 != nil } }
    public var heroes: [Hero] { slots.compactMap { $0?.hero } }
    public var stacks: [Hero.Stack] { slots.compactMap { $0?.stack } }
}

/// Where a caravan can start: one of the player's towns with a caravan, or a creature dwelling
/// the player owns (its creatures are bought straight into the caravan).
public enum CaravanSource: Equatable {
    case town(Int), dwelling(Int)
}

/// A route between an origin and a destination (0x68e990): reachable in some days, every route
/// crossing a hostile army's reach, or no route at all.
public enum CaravanRoute: Equatable {
    case days(Int), blockedByEnemy, blocked
    public var days: Int? { if case .days(let n) = self { return n }; return nil }
}

extension GameState {
    /// Movement a caravan covers in a day: the planner's 3000 hundredths (0x647dd0 dummy army).
    public static let caravanDailyMove = 3000

    /// Does the town have its caravan building (town+0xa4 bit 7, building id 7)?
    public func hasCaravan(_ i: Int) -> Bool { towns.indices.contains(i) && isBuilt(towns[i], 7) }

    /// Are two players on one side (the same player or the same team)?
    public func sameSide(_ a: Int?, _ b: Int?) -> Bool {
        guard let a = a, let b = b else { return false }
        if a == b { return true }
        guard let ta = map.teams[a], let tb = map.teams[b] else { return false }
        return ta == tb
    }

    /// The player's towns with a caravan building, in town order.
    public func caravanTowns(of colour: Int) -> [Int] {
        towns.indices.filter { towns[$0].owner == colour && hasCaravan($0) }
    }
    /// The creature dwellings the player owns (player+0x9c).
    public func ownedDwellings(of colour: Int) -> [Int] {
        dwellings.indices.filter { dwellings[$0].owner == colour }
    }

    public func dwellingPlaced(_ i: Int) -> MapScene.Placed? {
        guard dwellings.indices.contains(i), dwellings[i].z < scenes.count else { return nil }
        let d = dwellings[i]
        return scenes[d.z].placed.first { $0.cellX == d.x && $0.cellY == d.y && $0.name == d.name }
    }
    /// An origin's name as the dialogs show it.
    public func caravanSourceName(_ s: CaravanSource) -> String {
        switch s {
        case .town(let i): return towns[i].name
        case .dwelling(let i): return dwellingPlaced(i).map { dwellingName($0) } ?? dwellings[i].name
        }
    }

    // MARK: the creation dialog's lists (0x688220)

    static let townTypeOrder = ["life", "order", "death", "chaos", "nature", "might"]

    /// Why the creation dialog cannot open at this town for the player, or nil (0x688220):
    /// neither the town nor an army visiting it is the player's -> "no_owned_troops"; no other
    /// caravan town and no dwelling -> "no_other_locations" (its town) / "_allied" (an ally's).
    public func caravanCreateRefusal(town i: Int, player p: Int) -> String? {
        let mine = towns[i].owner == p
        if !mine, (visitingArmy(town: i)?.owner).map({ $0 != p }) ?? true {
            return text("caravan.no_owned_troops", "You don't have any troops in this town.")
        }
        let l = caravanLists(town: i, player: p)
        if l.origins.isEmpty && l.destinations.isEmpty {
            return mine ? text("caravan.no_other_locations", "Caravans must have a destination - either a creature dwelling or town with a caravan.  Currently, you don't own any structures capable of accepting a caravan.")
                        : text("caravan.no_other_locations_allied", "Caravans must have a town with a caravan building as a destination.  Currently, you don't own any towns capable of accepting a caravan.")
        }
        return nil
    }
    /// The dialog's two lists: destinations = the player's other towns with a caravan; origins =
    /// those towns, then every dwelling the player owns. Sorted (0x688170): towns before
    /// dwellings, towns by type, dwellings by creature alignment, level and experience value.
    public func caravanLists(town i: Int, player p: Int) -> (origins: [CaravanSource], destinations: [Int]) {
        func type(_ a: String) -> Int { GameState.townTypeOrder.firstIndex(of: a.lowercased()) ?? 6 }
        let ts = towns.indices.filter { $0 != i && towns[$0].owner == p && hasCaravan($0) }
            .enumerated().sorted { a, b in (type(towns[a.element].alignment), a.offset) < (type(towns[b.element].alignment), b.offset) }.map { $0.element }
        let ds = ownedDwellings(of: p).enumerated().sorted { a, b in
            let ca = tables?.creature(dwellings[a.element].creature), cb = tables?.creature(dwellings[b.element].creature)
            let ka = (type(ca?.alignment ?? ""), ca?.level ?? 0, ca?.experience ?? 0, a.offset), kb = (type(cb?.alignment ?? ""), cb?.level ?? 0, cb?.experience ?? 0, b.offset)
            return ka < kb
        }.map { $0.element }
        return (ts.map { .town($0) } + ds.map { .dwelling($0) }, ts)
    }
    /// The route text of a town origin or destination (0x68f1f0).
    public func caravanRouteText(_ r: CaravanRoute, origin: String, destination: String) -> String {
        let s: String
        switch r {
        case .days(1): s = text("caravan.reachable_1_day_text", "A caravan from %origin to %destination will arrive in 1 day.")
        case .days: s = text("caravan.reachable_multiple_days_text", "A caravan from %origin to %destination will arrive in %days days.")
        case .blockedByEnemy: s = text("caravan.blocked_by_enemy_text", "The caravan from %origin to %destination is blocked by the enemy.")
        case .blocked: s = text("caravan.permenantly_blocked_text", "You know of no route from %destination to %origin.")
        }
        return GameState.substitute(s, ["%origin": origin, "%destination": destination, "%days": "\(r.days ?? 0)"])
    }
    /// The buy text of a dwelling origin (sec. 7 of the creation spec): none / one / multiple by
    /// what waits, by the route.
    public func caravanBuyText(dwelling i: Int, route r: CaravanRoute, destination: String) -> String {
        guard let c = tables?.creature(dwellings[i].creature) else { return "" }
        let n = dwellings[i].available
        let amount = n <= 0 ? "none" : n == 1 ? "one" : "multiple"
        let way: String
        switch r { case .days(1): way = "1_day"; case .days: way = "multiple_days"; case .blockedByEnemy: way = "blocked_by_enemy"; case .blocked: way = "permenantly_blocked" }
        let fallback = "You can buy %creatures from this %origin and caravan them to %destination."
        let s = text("caravan.buy_\(amount)_\(way)", fallback)
        let origin = caravanSourceName(.dwelling(i))
        return GameState.substitute(s, ["%creature_name": c.plural, "%the_creatures": n == 1 ? "the \(c.name)" : "\(n) \(c.plural)",
                                        "%creatures": "\(n) \(n == 1 ? c.name : c.plural)", "%origin": origin, "%destination": destination,
                                        "%population": "\(n)", "%days": "\(r.days ?? 0)"])
    }
    /// Buy creatures at a dwelling straight into a new caravan (0x68c8d0 -> 0x43dee0): the normal
    /// price (no hero, so no discount), the dwelling's population drops. Returns the caravan.
    @discardableResult
    public func buyCaravan(dwelling i: Int, count: Int, to town: Int, days: Int) -> Caravan? {
        guard count > 0, dwellings.indices.contains(i), let c = tables?.creature(dwellings[i].creature) else { return nil }
        let cost = recruitCost(c, discount: 0)
        guard count <= recruitMost(available: dwellings[i].available, cost: cost) else { return nil }
        for (m, v) in cost { resources[m, default: 0] -= v * count }
        dwellings[i].available -= count
        return sendCaravan([.stack(Hero.Stack(creature: c.keyword, count: count))], from: .dwelling(i), to: town, days: days)
    }

    // MARK: the dialogs' lists

    /// The View Caravans list (0x6962a0): for a town every caravan headed there, whoever owns it;
    /// globally the player's own caravans, then the other players' caravans headed for each of
    /// its towns. (The exe keeps them in its containers' order: by destination.)
    public func viewedCaravans(town: Int?, player p: Int) -> [Caravan] {
        if let t = town { return caravans.filter { $0.destination == t } }
        var out = sortedCaravans(caravans.filter { $0.owner == p })
        for t in towns.indices where towns[t].owner == p { out += caravans.filter { $0.destination == t && $0.owner != p } }
        return out
    }

    // MARK: the route (0x68e990)

    /// The days a caravan needs between an origin and a town (the creation dialog, 0x68dee0 /
    /// 0x68e0d0): the plain planner from the origin with an empty army of 3000 movement a day --
    /// terrain and roads count, no creature's Move nor any hero's skill; no sea, no gateways.
    /// The cheapest route avoiding every hostile army's reach wins; when every route crosses one
    /// it is blocked by the enemy; with none at all it is blocked for good.
    /// days = max(1, ceil(cost / 3000)) (0x68e09a).
    public func caravanRoute(from s: CaravanSource, to town: Int, owner: Int? = nil) -> CaravanRoute {
        guard towns.indices.contains(town), let dp = townPlaced(town) else { return .blocked }
        let owner = owner ?? actingColour
        let z: Int, starts: [(Int, Int)]
        switch s {
        case .town(let i):
            guard let p = townPlaced(i) else { return .blocked }
            z = towns[i].z; starts = withLevel(z) { gateCells(p) }
        case .dwelling(let i):
            guard let p = dwellingPlaced(i) else { return .blocked }
            z = dwellings[i].z
            starts = withLevel(z) { aroundFootprint(p).filter { passability.isFree($0.0, $0.1) } }
        }
        guard z == towns[town].z, !starts.isEmpty, z < passabilities.count else { return .blocked }
        var pass = passabilities[z]
        pass.jumps = [:]; pass.forcedExit = [:]; pass.relief = 0   // no gateways, no guard rules, no Pathfinding
        let size = pass.size
        var goals = withLevel(z) { entryCells(dp) }.map { $0.0 * size + $0.1 }
        if goals.isEmpty { goals = withLevel(z) { gateCells(dp) }.map { $0.0 * size + $0.1 } }
        goals = goals.filter { $0 >= 0 && $0 < size * size }
        guard !goals.isEmpty else { return .blocked }
        func cheapest(_ r: (cost: [Int32], prev: [Int32])) -> Int? {
            goals.compactMap { r.cost[$0] < .max ? Int(r.cost[$0]) : nil }.min()
        }
        let danger = caravanDanger(level: z, owner: owner)
        if let c = cheapest(pass.search(fromAll: starts, goals: Set(goals), avoid: danger)) {
            return .days(max(1, (c + GameState.caravanDailyMove - 1) / GameState.caravanDailyMove))
        }
        return cheapest(pass.search(fromAll: starts, goals: Set(goals))) != nil ? .blockedByEnemy : .blocked
    }

    /// Cells a caravan's safe route keeps out of: the guard zones of wandering stacks and the
    /// cells around other sides' armies (the planner's danger bit 0x100) [I: the exact owner test].
    func caravanDanger(level z: Int, owner: Int) -> Set<Int> {
        let back = level; level = z; defer { level = back }
        var out = dangerCells
        let size = map.size
        let armies = (heroes + enemyHeroes).filter { $0.z == z && !sameSide($0.owner, owner) }
        for h in armies {
            for dx in -1...1 { for dy in -1...1 {
                let x = h.x + dx, y = h.y + dy
                if x >= 0, y >= 0, x < size, y < size { out.insert(x * size + y) }
            } }
        }
        return out
    }

    func withLevel<T>(_ z: Int, _ body: () -> T) -> T {
        let back = level; level = z; defer { level = back }
        return body()
    }
    /// The cells around an object's footprint.
    func aroundFootprint(_ p: MapScene.Placed) -> [(Int, Int)] {
        let w = p.sprite.footprint.w, h = p.sprite.footprint.h
        var out: [(Int, Int)] = []
        for x in (p.cellX - 1)...(p.cellX + w) { for y in (p.cellY - 1)...(p.cellY + h) {
            if x >= p.cellX && x < p.cellX + w && y >= p.cellY && y < p.cellY + h { continue }
            out.append((x, y))
        } }
        return out
    }

    // MARK: sending (0x68e5b0, 0x68c8d0)

    /// Send a caravan: arriving at day + days, owned by the player acting (no cost).
    @discardableResult
    public func sendCaravan(_ slots: [ArmySlot?], from s: CaravanSource, to town: Int, days: Int, owner: Int? = nil) -> Caravan? {
        guard slots.contains(where: { $0 != nil }), towns.indices.contains(town) else { return nil }
        let c = Caravan(id: nextCaravanId, owner: owner ?? actingColour, destination: town, origin: caravanSourceName(s),
                        arrivalDay: day + max(1, days), slots: slots)
        nextCaravanId += 1
        caravans.append(c)
        return c
    }

    /// The order the exe keeps a player's caravans in (0x5b9df0): destination town name, owner,
    /// arrival day, id.
    public func sortedCaravans(_ list: [Caravan]) -> [Caravan] {
        list.sorted { a, b in
            let na = towns[a.destination].name, nb = towns[b.destination].name
            if na != nb { return na < nb }
            if a.owner != b.owner { return a.owner < b.owner }
            if a.arrivalDay != b.arrivalDay { return a.arrivalDay < b.arrivalDay }
            return a.id < b.id
        }
    }
    /// The caravans that have arrived but wait outside the town (Manage Arrivals).
    public func waitingCaravans(town: Int, owner: Int) -> [Caravan] {
        sortedCaravans(caravans.filter { $0.destination == town && $0.owner == owner && $0.arrivalDay <= day })
    }

    // MARK: arriving (0x4b1010, at the start of each of the owner's turns)

    /// Move a caravan's places into an army row (0x5b7c90): each place into the same place if it
    /// takes it (empty, or the same creature), else the first place that does, else it stays;
    /// with something left, the row's duplicate stacks are joined and it is tried once more.
    /// Partial moves stick. True when the caravan is empty.
    @discardableResult
    public static func mergeCaravan(_ c: Caravan, into row: inout [ArmySlot?]) -> Bool {
        func takes(_ dst: ArmySlot?, _ src: ArmySlot) -> Bool {
            guard let d = dst else { return true }
            if let a = src.stack, let b = d.stack { return a.creature == b.creature }
            return false
        }
        func pass() {
            for i in c.slots.indices {
                guard let s = c.slots[i] else { continue }
                let k = i < row.count && takes(row[i], s) ? i : row.indices.first { takes(row[$0], s) }
                guard let j = k else { continue }
                if let a = s.stack, let b = row[j]?.stack { row[j] = .stack(Hero.Stack(creature: a.creature, count: a.count + b.count)) }
                else { row[j] = s }
                c.slots[i] = nil
            }
        }
        pass()
        if !c.isEmpty { consolidate(&row); pass() }
        return c.isEmpty
    }
    /// Join a row's stacks of the same creature into the first of them (0x641830).
    static func consolidate(_ row: inout [ArmySlot?]) {
        for i in row.indices {
            guard let a = row[i]?.stack else { continue }
            for j in (i + 1)..<row.count where row[j]?.stack?.creature == a.creature {
                row[i] = .stack(Hero.Stack(creature: a.creature, count: row[i]!.stack!.count + row[j]!.stack!.count)); row[j] = nil
            }
        }
    }
    /// Would everything of the caravan fit into the row (0x641970)?
    static func fits(_ c: Caravan, _ row: [ArmySlot?]) -> Bool {
        var free = row.filter { $0 == nil }.count
        var have = Set(row.compactMap { $0?.stack?.creature })
        for s in c.slots.compactMap({ $0 }) {
            if let a = s.stack, have.contains(a.creature) { continue }
            guard free > 0 else { return false }
            free -= 1
            if let a = s.stack { have.insert(a.creature) }
        }
        return true
    }

    /// The player's armies on the map (the 8 cap of list player+0x68).
    func armyCount(of colour: Int) -> Int {
        colour == map.humanColour ? heroes.count : enemyHeroes.filter { $0.owner == colour }.count
    }

    /// The arrivals of one player's turn (0x4b1010): its caravans whose day has come.
    /// 1. Into the garrison of a town the player owns (no message).
    /// 2. What is left forms an army on a free cell next to the town -- at the player's own town
    ///    only while it has fewer than 8 armies; later caravans to that town join it when they fit
    ///    ("arrived_full_dropped" at its own town, "arrived_occupied" at another's).
    /// 3. The human is told about the rest: they wait outside its own town ("arrived_full",
    ///    Manage Arrivals), are guests of an ally ("arrived_occupied_by_ally"), or hide until
    ///    tomorrow at an enemy's ("failed_occupied") -- all tried again next turn.
    /// Returns the message (nil for none or a computer player); it is also queued for the screen.
    @discardableResult
    public func caravanArrivals(for colour: Int) -> String? {
        let arrived = { self.sortedCaravans(self.caravans.filter { $0.owner == colour && $0.arrivalDay <= self.day }) }
        // phase 1 (0x4af290): into the garrison
        for c in arrived() where towns[c.destination].owner == colour {
            var row = garrisonSlots(c.destination)
            let empty = GameState.mergeCaravan(c, into: &row)
            setGarrison(c.destination, row)
            if empty { caravans.removeAll { $0 === c } }
        }
        // phase 2 (0x4af740): an army outside the town
        var dropped: [Caravan] = [], occupied: [Caravan] = []
        var formed: [Int: Hero] = [:]
        var progress = true
        while progress {
            progress = false
            for c in arrived() {
                let t = c.destination, own = towns[t].owner == colour
                if let a = formed[t] {
                    var row = armySlots(a)
                    guard GameState.fits(c, row) else { continue }
                    GameState.mergeCaravan(c, into: &row)
                    setCaravanArmy(a, row)
                } else {
                    if own && armyCount(of: colour) >= GameState.maxArmies { continue }
                    guard let a = formArmy(from: c, at: t) else { continue }
                    formed[t] = a
                }
                caravans.removeAll { $0 === c }
                if own { dropped.append(c) } else { occupied.append(c) }
                progress = true
            }
        }
        guard colour == map.humanColour else { return nil }
        // phase 3 (0x4afc50): the ones still waiting
        var full: [Caravan] = [], ally: [Caravan] = [], failed: [Caravan] = []
        for c in arrived() {
            let o = towns[c.destination].owner
            if o == colour { full.append(c) } else if sameSide(o, colour) { ally.append(c) } else { failed.append(c) }
        }
        var parts: [String] = []
        func group(_ list: [Caravan], _ key: String, _ fallback: [String]) {
            guard !list.isEmpty else { return }
            var names: [String] = []
            for c in list where !names.contains(towns[c.destination].name) { names.append(towns[c.destination].name) }
            let k = list.count == 1 ? 0 : names.count == 1 ? 1 : 2
            let suffix = ["singular", "plural_1_town", "plural_multiple_towns"][k]
            let s = text("caravan.\(key)_\(suffix)", fallback[k])
            parts.append(GameState.substitute(s, ["%count": "\(list.count)", "%town_list": townList(names)]))
        }
        group(occupied, "arrived_occupied", ["Your caravan arrived at %town_list only to find it occupied!  The troops have formed up in ranks outside the gates to await your instructions.",
                                             "%Count of your caravans have arrived at %town_list only to find it occupied!  The troops have formed up in ranks outside the gates to await your instructions.",
                                             "%Count of your caravans have arrived at %town_list only to find them occupied!  The troops have formed up in ranks outside the gates to await your instructions."])
        group(failed, "failed_occupied", ["Your caravan arrived at %town_list only to find it occupied by the enemy!  Unable to find a safe place to camp, your troops have hidden themselves until tomorrow.",
                                          "%Count of your caravans have arrived at %town_list only to find it occupied by the enemy!  Unable to find a safe place to camp, your troops have hidden themselves until tomorrow.",
                                          "%Count of your caravans have arrived at %town_list only to find them occupied by the enemy!  Unable to find a safe place to camp, your troops have hidden themselves until tomorrow."])
        group(dropped, "arrived_full_dropped", ["Your caravan arrived at %town_list, but the garrison was already full.  The troops have formed up in ranks outside the gates to await your instructions.",
                                                "%Count of your caravans have arrived at %town_list, but the garrisons were full.  The troops have formed in ranks outside the gates to await your instructions.",
                                                "%Count of your caravans have arrived at %town_list, but the garrisons were already full.  The troops have formed in ranks outside the gates to await your instructions."])
        group(full, "arrived_full", ["Your caravan arrived at %town_list, but there wasn't enough room in the garrison for the troops.  They have camped outside the town until you make room for them, but as your aides point out, they would be easy prey if the enemy takes the town.",
                                     "%Count of your caravans have arrived at %town_list, but there wasn't enough room in the garrison for the troops.  They have camped outside the town until you make room for them, but as your aides point out, they would be easy prey if the enemy takes the town.",
                                     "%Count of your caravans have arrived at %town_list, but there wasn't enough room in the garrisons for the troops.  They have camped outside the towns until you make room for them, but as your aides point out, they would be easy prey if the enemy takes one of the towns."])
        group(ally, "arrived_occupied_by_ally", ["Your caravan arrived at %town_list only to find it occupied!  The troops are staying as guests of the caravan master until there is room for them to form an army.",
                                                 "%Count of your caravans have arrived at %town_list only to find it occupied!  The troops are staying as guests of the caravan master until there is room for them to form an army.",
                                                 "%Count of your caravans have arrived at %town_list only to find them occupied!  The troops are staying as guests of the caravan master until there is room for them to form an army."])
        guard !parts.isEmpty else { return nil }
        let msg = parts.joined(separator: text("caravan.arrival_separator", "\n\n"))
        scripts.messages.append(msg)
        return msg
    }

    /// Replace placeholders whatever their case ("%Count" is replaced as "%count", [I]); a
    /// capitalised placeholder gets a capitalised value.
    public static func substitute(_ s: String, _ values: [String: String]) -> String {
        var out = s
        for (k, v) in values.sorted(by: { $0.key.count > $1.key.count }) {
            let cap = "%" + k.dropFirst().prefix(1).uppercased() + k.dropFirst(2)
            out = out.replacingOccurrences(of: cap, with: v.prefix(1).uppercased() + v.dropFirst())
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }
    /// "A", "A and B", "A, B and C" (0x74f2d0 [I]: the list formatter's joiners).
    func townList(_ names: [String]) -> String {
        if names.count <= 1 { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// A new army outside the town from a caravan's troops (0x4fa3e0, 0x51fcc0): its first hero
    /// leads it, else it is a heroless army; on a free cell near the gate.
    func formArmy(from c: Caravan, at t: Int) -> Hero? {
        guard let p = townPlaced(t) else { return nil }
        let back = level; level = towns[t].z; defer { level = back }
        let gates = gateCells(p)
        func free(_ x: Int, _ y: Int) -> Bool {
            passability.isFree(x, y) && enemyAt(x, y) == nil && !heroes.contains { $0.z == level && $0.x == x && $0.y == y }
        }
        var cell = gates.first { free($0.0, $0.1) }
        if cell == nil {
            // the nearest free cell within 3 of the gate [I: the search order of 0x4fa3e0]
            search: for r in 1...3 {
                for dx in -r...r { for dy in -r...r where max(abs(dx), abs(dy)) == r {
                    if free(gates[0].0 + dx, gates[0].1 + dy) { cell = (gates[0].0 + dx, gates[0].1 + dy); break search }
                } }
            }
        }
        guard let (x, y) = cell else { return nil }
        let hs = c.heroes
        let lead: Hero = hs.first ?? {
            let h = Hero(actor: "", x: 0, y: 0, movement: 0); h.heroless = true; h.name = ""; return h
        }()
        lead.x = x; lead.y = y; lead.z = towns[t].z; lead.owner = c.owner
        lead.companions = lead.heroless ? [] : Array(hs.dropFirst())
        lead.army = c.stacks; lead.rowKeys = GameState.keys(of: c.slots)
        lead.path = []; lead.plan = []; lead.target = nil
        if lead.heroless { lead.alignment = towns[t].alignment; lead.home = (x, y) }
        refreshHeroless(lead)
        lead.maxMovement = armyMovement(lead); lead.movement = lead.maxMovement
        c.slots = [ArmySlot?](repeating: nil, count: GameState.rowSlots)
        if c.owner == map.humanColour { lead.listRank = nextListRank(); heroes.insert(lead, at: 0) } else { place(enemy: lead) }
        return lead
    }
    /// Put a row into an army formed outside a town (the human's or a computer's).
    func setCaravanArmy(_ a: Hero, _ row: [ArmySlot?]) {
        if a.owner == map.humanColour { setArmy(a, row); return }
        let hs = row.compactMap { $0?.hero }
        a.companions = a.heroless ? [] : hs.filter { $0 !== a }
        a.army = row.compactMap { $0?.stack }; a.rowKeys = GameState.keys(of: row)
        refreshHeroless(a)
    }

    // MARK: the town is taken (0x89e810, 0x8a0200)

    /// A town changed hands: the caravans of other sides camped outside it are destroyed -- their
    /// creatures killed, their heroes taken to the town's prison -- with the victor's or the
    /// loser's message when that is the human; then the human new owner is warned of the other
    /// players' caravans still on their way. Caravans on the road are not touched.
    public func caravansAtCapture(town t: Int, newOwner: Int?) {
        guard towns.indices.contains(t) else { return }
        let human = map.humanColour
        let camped = caravans.filter { $0.destination == t && $0.arrivalDay <= day && !sameSide($0.owner, newOwner) && $0.owner != newOwner }
        if !camped.isEmpty {
            let hs = camped.flatMap { $0.heroes }
            let creatures = camped.contains { !$0.stacks.isEmpty }
            towns[t].prisoners += hs
            caravans.removeAll { c in camped.contains { $0 === c } }
            let kind = !hs.isEmpty && creatures ? "both" : !hs.isEmpty ? "heroes" : "creatures"
            let names = townList(hs.map { $0.name })
            let fallbacks: [String: String] = [
                "both_victor": "Your conquering army spots some troops camped near the town.  You fall upon them before they realize what is happening, and easily scatter the disorganized band to the four winds.  You also capture %hero_names.",
                "both_loser": "In the chaos surrounding the fall of %town, the occupying troops come upon some of your caravans still milling about.  Before your troops can form up and defend themselves, they are attacked!  %hero_names are captured and the rest of the troops are slaughtered.",
                "heroes_victor": "Your conquering army spots a disorganized mass of troops milling outside town.  You fall upon them before they can react, easily capturing %hero_names.",
                "heroes_loser": "In the chaos surrounding the fall of %town, the occupying troops come upon %hero_names hiding outside town, capturing them.",
                "creatures_victor": "Your conquering army spots enemy troops hiding outside town.  You fall upon them before they can react, easily scattering the disorganized creatures to the four winds.",
                "creatures_loser": "In the chaos surrounding the fall of %town, the occupying troops spot some of your caravans still camped outside town.  Your troops are caught unaware and either killed or scattered to the four winds."]
            let side = newOwner == human ? "victor" : camped.contains(where: { $0.owner == human }) ? "loser" : nil
            if let side = side {
                let key = "\(kind)_\(side)"
                scripts.messages.append(GameState.substitute(text("caravan_arrived.killed_\(key)", fallbacks[key]!), ["%town": towns[t].name, "%hero_names": names]))
            }
        }
        // 0x8a0200: the warning
        guard newOwner == human else { return }
        let coming = caravans.filter { $0.destination == t && $0.owner != human }
        guard let first = coming.map({ $0.arrivalDay }).min() else { return }
        let d = first - day
        let when = d <= 0 ? "today" : d == 1 ? "tomorrow" : "future"
        let key = "caravan.incoming_warning_\(coming.count == 1 ? "singular" : "plural")_\(when)"
        let fallback = coming.count == 1
            ? "Soon after your capture of %town, one of your aides reports that an enemy caravan is expected to arrive in %days days.  You can find out more about this force by visiting the Caravan and speaking with the caravan master."
            : "Soon after your capture of %town, one of your aides reports that %count armies are expected to arrive by caravan soon.  You can find out more about these forces by visiting the Caravan and speaking with the caravan master."
        scripts.messages.append(GameState.substitute(text(key, fallback), ["%town": towns[t].name, "%days": "\(d)", "%count": "\(coming.count)"]))
    }

    // MARK: the computer players (0x4838e0)

    /// A computer player's caravans, every fifth day while it has fewer than 8 armies and a town
    /// with a caravan: each dwelling it owns buys all it can afford and sends them to its caravan
    /// town of the cheapest safe route (0x4841f0). (Its towns' garrison caravans, 0x483c40, rest
    /// on the AI's own town values and are not modelled.) Run with its treasury (acting(as:)).
    func aiCaravans(_ colour: Int) {
        guard day % 5 == 0, armyCount(of: colour) < GameState.maxArmies, let t = tables else { return }
        let dests = caravanTowns(of: colour)
        guard !dests.isEmpty else { return }
        for i in ownedDwellings(of: colour) {
            guard let c = t.creature(dwellings[i].creature) else { continue }
            var best: (town: Int, days: Int)? = nil
            for d in dests { if let n = caravanRoute(from: .dwelling(i), to: d, owner: colour).days, best == nil || n < best!.days { best = (d, n) } }
            guard let dest = best else { continue }
            let cost = recruitCost(c, discount: 0)
            let n = recruitMost(available: dwellings[i].available, cost: cost)
            guard n > 0 else { continue }
            for (m, v) in cost { resources[m, default: 0] -= v * n }
            dwellings[i].available -= n
            sendCaravan([.stack(Hero.Stack(creature: c.keyword, count: n))], from: .dwelling(i), to: dest.town, days: dest.days, owner: colour)
        }
    }
}
