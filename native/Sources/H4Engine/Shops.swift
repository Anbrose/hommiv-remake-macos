import Foundation

/// A blacksmith's or conservatory's shop to open (t_dialog_blacksmith, 0x670b80): four item rows
/// and five potion rows, each with the artifact it sells, for the visiting army.
public struct ShopOffer {
    public let key: String
    public let title: String
    /// The layer file of the shop picture (layers.dialog.Blacksmith.<panel>).
    public let panel: String
    public let items: [Int], potions: [Int]
    public let hero: Hero
    public init(key: String, title: String, panel: String, items: [Int], potions: [Int], hero: Hero) {
        self.key = key; self.title = title; self.panel = panel; self.items = items; self.potions = potions; self.hero = hero
    }
}

/// What a sanctuary's dialog shows (layers.dialog.sanctuary; 0x80c0d0).
public struct SanctuaryOffer {
    public let key: String
    public let title: String, text: String
    public let canEnter: Bool
    public let hero: Hero
}

extension GameState {
    static let blacksmithArmour = [14, 36, 47, 96, 126, 170, 195]   // axe .. telescope (0xa4c7cc)
    static let blacksmithWeapons = [79, 104, 105, 107]               // greatsword, longbow, longsword, mage's staff (0xa4c7e8)
    static let schools = ["life", "order", "death", "chaos", "nature"]

    func artifactAllowed(_ id: Int) -> Bool {
        id < RuleTables.artifactIds.count && tables?.artifacts[RuleTables.artifactIds[id]]?.allowedByDefault == true
    }
    /// updates.h4r's table.spell_artifact_costs: a parchment's and a scroll's price by spell level 1-5.
    static let parchmentCosts = [250, 500, 750, 1000, 1500], scrollCosts = [500, 750, 1000, 1500, 2000]
    /// An artifact's price in gold (0x548710): its table.Artifacts cost; a parchment or scroll costs
    /// at least its spell level's price (0x5486e0 / 0x85f2f0).
    public func artifactCost(_ id: Int) -> Int {
        let b = RuleTables.artifactBase(id)
        guard b < RuleTables.artifactIds.count else { return 0 }
        let cost = tables?.artifacts[RuleTables.artifactIds[b]]?.cost ?? 0
        if let sp = RuleTables.artifactSpell(id), sp < RuleTables.spells.count, b == 0x7c || b == 0xa6 {
            let lv = min(5, max(1, RuleTables.spells[sp].level))
            return max(cost, (b == 0x7c ? GameState.parchmentCosts : GameState.scrollCosts)[lv - 1])
        }
        return cost
    }
    /// n different entries of a pool (0x437040): each draw rng() % count, drawn again while taken,
    /// or while not allowed on the map and some allowed one is still free.
    func drawDifferent(_ pool: [Int], _ n: Int) -> [Int] {
        var taken = Set<Int>(), out: [Int] = []
        for _ in 0..<min(n, pool.count) {
            while true {
                let i = rng(pool.count)
                if taken.contains(i) { continue }
                if !artifactAllowed(pool[i]) && pool.indices.contains(where: { !taken.contains($0) && artifactAllowed(pool[$0]) }) { continue }
                taken.insert(i); out.append(pool[i]); break
            }
        }
        return out
    }
    /// The stock, rolled once at placement: a blacksmith (0x436940) three armour pieces, one weapon
    /// and five potions; a conservatory (0x437830) parchments of its school, two each of spell
    /// levels 1-4 and one of level 5, drawn without repeats.
    /// A conservatory is a blacksmith record with its school (or "random") as the subtype.
    func isConservatory(_ p: MapScene.Placed) -> Bool { p.type != "blacksmith" || !p.subtype.isEmpty }
    func setupShop(_ p: MapScene.Placed, _ st: inout ObjectState) {
        if !isConservatory(p) {
            let potions = RuleTables.artifactIds.indices.filter { tables?.artifacts[RuleTables.artifactIds[$0]]?.slot.lowercased() == "potion" }
            st.artifacts = drawDifferent(potions, 5)
            st.artifacts = drawDifferent(GameState.blacksmithArmour, 3) + drawDifferent(GameState.blacksmithWeapons, 1) + st.artifacts
            return
        }
        let lower = (p.subtype + " " + p.name).lowercased()
        let school = GameState.schools.first { lower.contains($0) } ?? GameState.schools[rng(5)]
        st.partner = school
        var spells: [Int] = []
        for (lv, n) in [(1, 2), (2, 2), (3, 2), (4, 2), (5, 1)] {
            var pool = RuleTables.spells.indices.filter { RuleTables.spells[$0].school == school && RuleTables.spells[$0].level == lv && RuleTables.spells[$0].has("Teach") }
            for _ in 0..<n where !pool.isEmpty { spells.append(pool.remove(at: rng(pool.count))) }
        }
        st.artifacts = spells.map { RuleTables.artifact(0x7c, spell: $0) }
    }

    func visitShop(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        guard isHumanActing else { return }
        dialogueSound(9)
        let panel = "Generic"
        let title = tables?.objectText(p.type, p.subtype, "name") ?? tables?.objectText(p.type, "", "name") ?? (isConservatory(p) ? "Conservatory" : "Blacksmith")
        shopOpen = ShopOffer(key: objectKey(p), title: title, panel: panel, items: Array(st.artifacts.prefix(4)), potions: Array(st.artifacts.dropFirst(4).prefix(5)), hero: hero)
    }
    /// Purchase (0x673dc0): count copies of each row's artifact to the chosen hero, the total paid in
    /// gold; the stock stays as it was.
    @discardableResult
    public func buy(_ rows: [(artifact: Int, count: Int)], for hero: Hero) -> Bool {
        let total = rows.reduce(0) { $0 + artifactCost($1.artifact) * $1.count }
        guard total > 0, total <= resources["Gold", default: 0] else { return false }
        for r in rows { for _ in 0..<r.count { hero.backpack.append(r.artifact) } }
        resources["Gold", default: 0] -= total
        return true
    }

    // MARK: sanctuary (0x80b120)

    static let sanctuaryFee = 200
    func sanctuaryOwner(_ key: String) -> Int? { sanctuaryGuests[key]?.owner }

    /// A visit: the heroes are healed first (heroes carry no wounds between battles here); an
    /// occupied sanctuary is denied, else the dialog offers to enter for 200 gold a day.
    func visitSanctuary(_ hero: Hero, _ p: MapScene.Placed) {
        let key = objectKey(p)
        guard isHumanActing else { return }
        dialogueSound(19)
        if sanctuaryGuests[key] != nil { say(p, "denied"); return }
        let paid = sanctuaryPaid.contains(key)
        let title = tables?.objectText(p.type, p.subtype, "name") ?? tables?.objectText("sanctuary", "", "name") ?? "Sanctuary"
        let body = objectText(p, paid ? "paid" : "initial") ?? objectText(p, paid ? "Paid" : "Initial") ?? "Enter the sanctuary for 200 gold a day?"
        sanctuaryOpen = SanctuaryOffer(key: key, title: title, text: body, canEnter: paid || resources["Gold", default: 0] >= GameState.sanctuaryFee, hero: hero)
    }
    /// Enter (0x80b120 result 1): pay unless paid today, and the army leaves the map into the sanctuary.
    public func enterSanctuary(_ o: SanctuaryOffer) {
        guard sanctuaryGuests[o.key] == nil else { return }
        if !sanctuaryPaid.contains(o.key) {
            guard resources["Gold", default: 0] >= GameState.sanctuaryFee else { return }
            resources["Gold", default: 0] -= GameState.sanctuaryFee
            sanctuaryPaid.insert(o.key)
        }
        o.hero.path = []
        heroes.removeAll { $0 === o.hero }
        sanctuaryGuests[o.key] = o.hero
        log.append("\(o.hero.name) enters the sanctuary")
    }
    /// The guest leaves (0x80b630) onto a free cell next to the sanctuary.
    public func leaveSanctuary(_ key: String) {
        guard let h = sanctuaryGuests[key] else { return }
        let parts = key.split(separator: "|").compactMap { Int($0) }
        guard parts.count == 3, parts[0] < scenes.count,
              let p = scenes[parts[0]].placed.first(where: { $0.cellX == parts[1] && $0.cellY == parts[2] }) else { return }
        let pass = passabilities[parts[0]]
        var spot: (Int, Int)?
        search: for r in 1...3 {
            for dx in -r...(p.sprite.footprint.w - 1 + r) { for dy in -r...(p.sprite.footprint.h - 1 + r) {
                let x = p.cellX + dx, y = p.cellY + dy
                if pass.isFree(x, y), !heroes.contains(where: { $0.x == x && $0.y == y && $0.z == parts[0] }) { spot = (x, y); break search }
            } }
        }
        guard let s = spot else { log.append("There is no room to leave the sanctuary"); return }
        sanctuaryGuests[key] = nil
        h.x = s.0; h.y = s.1; h.z = parts[0]
        heroes.insert(h, at: 0)
    }
    /// The owner uses the sanctuary on their turn (slot 20): leave?
    public func askLeaveSanctuary(_ key: String) {
        guard sanctuaryGuests[key] != nil else { return }
        let parts = key.split(separator: "|").compactMap { Int($0) }
        let p = parts.count == 3 && parts[0] < scenes.count ? scenes[parts[0]].placed.first(where: { $0.cellX == parts[1] && $0.cellY == parts[2] }) : nil
        let t = p.flatMap { objectText($0, "exit") ?? objectText($0, "Exit") } ?? "Leave the sanctuary?"
        question = (t, { [weak self] in self?.leaveSanctuary(key) })
    }
    /// New day (slot 31, 0x80b7c0): a guest whose owner cannot pay 200 gold is put out; the day's
    /// payments are forgotten.
    func sanctuariesNewDay() {
        for key in sanctuaryGuests.keys.sorted() {
            if resources["Gold", default: 0] < GameState.sanctuaryFee { leaveSanctuary(key) }
            else { resources["Gold", default: 0] -= GameState.sanctuaryFee }
        }
        sanctuaryPaid = []
        for h in sanctuaryGuests.values { refreshMovement(h) }
    }
}
