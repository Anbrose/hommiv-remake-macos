import Foundation

/// A campaign (campaign_spec §1): "H4CAMPAIGN", u32 version, u8 1, then u16 header version, name,
/// description, the carry-in / carry-out flags (v >= 2), the position choice (v >= 3), u16 maps,
/// their compressed sizes and the gzip streams back to back. The shipped ones are the archives'
/// game_maps.* entries (a 16-byte wrapper before the file).
public struct CampaignFile {
    public let name: String, description: String
    public let carryIn: Bool, carryOut: Bool
    /// The campaigns whose results a carry-in campaign starts from (header +8, read with the
    /// carry-in flag +0x38; 0x5a9d1a).
    public let carryInCampaigns: [String]
    /// The "choose your position" block is on (header +0x4c, 0x5ad6f0; The Last Bastion's
    /// "Choose your conqueror!"): at map start the carried human heroes go to the lists of the
    /// colour they played (0x5bd290 from 0x4d12d0) and human placeholders take from their colour's.
    public let choosesPosition: Bool
    let slices: [Data]
    public var count: Int { slices.count }

    /// A cut scene's voice key to its sound (sound.Voice_Over.<name>): the table 0x813b70 matched by
    /// 0x816cd0; the expansions' keys are their sounds' names.
    public static func voiceOver(_ key: String) -> String { voiceOverNames[key.lowercased()] ?? key }
    static let voiceOverNames: [String: String] = [
        "chaos_a_prologue": "Chaos A", "chaos_b_prologue": "Chaos B", "chaos_c_prologue": "Chaos C", "chaos_d_prologue": "Chaos D",
        "chaos_e_prologue": "Chaos E - Intro", "chaos_epilogue": "Chaos E - Epilogue",
        "death_a_prologue": "Death A", "death_b_prologue": "Death B", "death_c_prologue": "Death C", "death_d_prologue": "Death D",
        "death_e_prologue": "Death E - Intro", "death_epilogue": "Death E - Epilogue",
        "life_a_prologue": "Life A", "life_b_prologue": "Life B", "life_c_prologue": "Life C", "life_d_prologue": "Life D",
        "life_e_prologue": "Life E - Intro", "life_epilogue": "Life E - Epilogue",
        "might_a_prologue": "Might A", "might_b_prologue": "Might B", "might_c_prologue": "Might C",
        "might_d_prologue": "Might D - Intro", "might_epilogue": "Might D - Epilogue",
        "nature_a_prologue": "Nature A", "nature_b_prologue": "Nature B", "nature_c_prologue": "Nature C", "nature_d_prologue": "Nature D",
        "nature_e_prologue": "Nature E - Intro", "nature_epilogue": "Nature E - Epilogue",
        "order_a_prologue": "Order A", "order_b_prologue": "Order B", "order_c_prologue": "Order C", "order_d_prologue": "Order D",
        "order_e_prologue": "Order E", "order_f_prologue": "Order F", "order_g_prologue": "Order G",
        "order_h_prologue": "Order H - Intro", "order_epilogue": "Order H - Epilogue"]

    public init(data raw: Data) throws {
        var d = raw
        if d.prefix(10) != Data("H4CAMPAIGN".utf8), d.count > 16, d.dropFirst(16).prefix(10) == Data("H4CAMPAIGN".utf8) { d = d.subdata(in: (d.startIndex + 16)..<d.endIndex) }
        guard d.prefix(10) == Data("H4CAMPAIGN".utf8) else { throw H4Error.corrupt("campaign: no header") }
        var r = ByteReader(d)
        r.pos = 10
        _ = r.u32()
        guard r.u8() == 1 else { throw H4Error.corrupt("campaign: a single scenario") }
        let hver = Int(r.u16())
        name = r.string16()
        description = hver >= 1 ? r.string16() : ""
        var cin = false, cout = false, sources: [String] = []
        if hver >= 2 {
            cin = r.u8() != 0
            if cin { let n = Int(r.u16()); sources = (0..<n).map { _ in r.string16() } }
            cout = r.u8() != 0
        }
        var position = false
        if hver >= 3 {   // the "choose your position" block (0x5ad6f0)
            let v = r.u16()
            position = r.u8() != 0
            if position {
                _ = r.string16(); _ = r.u8()
                for _ in 0..<6 where r.u8() != 0 {
                    _ = r.u32()
                    if v >= 1, r.u8() != 0 { _ = r.string16(); _ = r.string16() }
                }
            }
        }
        carryIn = cin; carryOut = cout; carryInCampaigns = sources; choosesPosition = position
        let n = Int(r.u16())
        let sizes = (0..<n).map { _ in Int(r.u32()) }
        var at = r.pos, out: [Data] = []
        for s in sizes {
            guard at + s <= d.count else { throw H4Error.corrupt("campaign: short") }
            out.append(d.subdata(in: (d.startIndex + at)..<(d.startIndex + at + s))); at += s
        }
        slices = out
    }
    /// The carry-in campaigns without stored results (0x5aa330, the campaign's vtable +0x2c), in
    /// header order: none unless the carry-in flag is set; else each name needs its entry in
    /// data/carryover.dat (`stored`; without the file every name is missing).
    public func missingCarryIn(stored: Set<String>) -> [String] {
        carryIn ? carryInCampaigns.filter { !stored.contains($0) } : []
    }
    /// What 0x76c110 shows before it abandons the start when results are missing:
    /// campaign.carryin_data_not_available with %campaign_name and %other_campaigns, the list as
    /// 0x74f2d0 builds it (each name put in front of the ones before: the second with " and ",
    /// every further one with ", ", so the last comes first).
    public func carryInRefusal(missing: [String], strings: [String: String]) -> String {
        let template = strings["campaign.carryin_data_not_available"] ?? "You must complete %other_campaigns before your heroes will be ready for %campaign_name."
        let and = strings["and.dialog"] ?? "and"
        var list = ""
        for (k, n) in missing.enumerated() { list = k == 0 ? n : n + (k == 1 ? " \(and) " : ", ") + list }
        return template.replacingOccurrences(of: "%other_campaigns", with: list).replacingOccurrences(of: "%campaign_name", with: name)
    }
    /// Scenario i's map bytes (what MapFile reads).
    public func scenario(_ i: Int) throws -> Data { try gunzip(slices[i], expected: slices[i].count * 12) }

    /// The campaigns by their standard id (0x5a8ab0): the resource under game_maps.*, and the set
    /// (0 Heroes IV, 1 Gathering Storm, 2 Winds of War) in the selection screens' button order (0x985f50).
    public static let resources: [Int: String] = [
        0: "single.Tutorial",
        1: "Campaign.Life_Campaign", 2: "Campaign.Order_Campaign", 3: "Campaign.Death_Campaign", 4: "Campaign.Chaos_Campaign",
        5: "Campaign.Nature_Campaign", 6: "Campaign.Might_Campaign",
        7: "storm_campaign.Death-Life", 8: "storm_campaign.ChaosOrder", 9: "storm_campaign.Archmage", 10: "storm_campaign.Dogwoggle Campaign",
        11: "storm_campaign.Bard", 12: "storm_campaign.GatheringStorm",
        13: "wow_campaign.Erutan_Nature", 14: "wow_campaign.Mongo_Might", 15: "wow_campaign.Mysterio_Order", 16: "wow_campaign.Spazz_Chaos",
        17: "wow_campaign.Tarkin_Death", 18: "wow_campaign.winds_of_war",
    ]
    public static let sets: [[Int]] = [[1, 6, 2, 5, 3, 4], [9, 8, 11, 10, 7, 12], [16, 14, 15, 13, 17, 18]]
    /// The archive entry holding a campaign (case-insensitive; the updates.h4r copies of the base six first).
    public static func entry(_ id: Int, in archive: H4Archive) -> String? {
        guard let r = resources[id] else { return nil }
        let want = "game_maps.\(r).h4d".lowercased()
        let names = archive.entries.map(\.name)
        return names.first { $0 == "game_maps.\(r).h4d" } ?? names.first { $0.lowercased() == want }
            ?? (id <= 6 ? names.first { $0.lowercased() == want.replacingOccurrences(of: "game_maps.campaign.", with: "game_maps.campaign.") } : nil)
    }
    public static func load(_ id: Int, from archive: H4Archive) throws -> CampaignFile {
        guard let e = entry(id, in: archive) else { throw H4Error.missing("campaign \(id)") }
        return try CampaignFile(data: archive.payload(e))
    }
}

/// Heroes carried from one scenario to the next (campaign_spec §2.4): the human's heroes and each
/// computer colour's, most skilled first; only the heroes (no creatures, towns or resources).
public struct Carryover: Codable {
    public var human: [SaveGame.HeroState] = []
    public var byColour: [Int: [SaveGame.HeroState]] = [:]
    /// Each won scenario's {score, days} so far (t_carryover_data +0xffc, 0x4e6020).
    public var scores: [CampaignScore]? = nil
    /// The human's carried artifact pool (t_carryover_data +8, one list per artifact id): the
    /// won map's carry-out artifacts taken off its heroes, for the next map's strongest hero.
    public var artifacts: [Int]? = nil
    /// The colour the `human` heroes played (each carried hero's +0x598, the owner's colour when
    /// 0x4e5470 builds the carry); nil once merged or redistributed.
    public var humanColour: Int? = nil
    public init() {}

    /// 0x5bd290 (map start in a campaign with the position choice): every human-list hero whose
    /// colour is a player colour moves to the end of that colour's list.
    public mutating func distributeHumanByColour() {
        guard let col = humanColour, (0..<6).contains(col) else { return }
        byColour[col, default: []] += human
        human = []; humanColour = nil
    }
}

/// The finished campaigns' carry-out (data/carryover.dat, re/campaign_carryover_store_spec.md):
/// one entry per campaign name, "cross_campaign_carryover.<name>.h4d" in the exe's H4R archive.
/// The remake keeps the same contents as JSON (the exe's payload is its t_hero serialization).
public struct CarryoverStore: Codable {
    public struct Entry: Codable {
        /// The entry's flag (u8 after the u16 1, entry +8): the campaign's carry-out flag +0x39.
        public var carries: Bool
        /// The carry written in the cross-campaign mode (0x5bcf60 with 0: no scores); nil without the flag.
        public var carry: Carryover?
        /// The entry's time stamp (time(0), 0x8020b0 / 0x8012d0).
        public var time: Date
    }
    public var entries: [String: Entry] = [:]
    public init() {}

    /// 0x5aa960 (from 0x771070 when the won scenario was the campaign's last): the campaign's
    /// entry is replaced (or added), the others stay.
    public mutating func record(_ c: CampaignFile, carry: Carryover, at time: Date = Date()) {
        var stored: Carryover? = nil
        if c.carryOut { var k = carry; k.scores = nil; stored = k }
        entries[c.name] = Entry(carries: c.carryOut, carry: stored, time: time)
    }
    /// The names a carry-in check counts as present (0x5aa330: the entry exists and its flag is set).
    public var stored: Set<String> { Set(entries.filter { $0.value.carries }.map(\.key)) }

    /// 0x5aa580 (the campaign's vtable +0x10, from 0x76f320 after the check): a campaign without
    /// the carry-in flag starts from an empty carry; else every imported campaign's entry, in header
    /// order, is appended (0x5bc000: the artifact pool, each colour's list, the human list). A
    /// missing or flagless entry gives no carry at all (nil). With the position choice each entry's
    /// human heroes then join the list of the colour they played (0x5bd290).
    public func carryIn(for c: CampaignFile) -> Carryover? {
        guard c.carryIn else { return Carryover() }
        var out = Carryover(), parts: [Carryover] = []
        for name in c.carryInCampaigns {
            guard let e = entries[name], e.carries, let k = e.carry else { return nil }
            parts.append(k)
            for (col, hs) in k.byColour.sorted(by: { $0.key < $1.key }) { out.byColour[col, default: []] += hs }
            if let a = k.artifacts { out.artifacts = (out.artifacts ?? []) + a }
        }
        // the human list in entry order; with the position choice 0x5bd290 later moves each hero
        // to the end of its colour's list (after every entry's computer heroes of that colour)
        for k in parts {
            if c.choosesPosition, let col = k.humanColour, (0..<6).contains(col) { out.byColour[col, default: []] += k.human }
            else { out.human += k.human }
        }
        return out
    }
    public static func load(_ url: URL) -> CarryoverStore {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CarryoverStore.self, from: $0) } ?? CarryoverStore()
    }
    public func save(_ url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

extension GameState {
    /// The campaign being played: its standard id, this scenario's index, the player difficulty.
    public func carryOut() -> Carryover {
        var c = Carryover()
        func rank(_ h: Hero) -> Int { h.skills.values.reduce(0) { $0 + $1 + 1 } }
        var mine = heroes.flatMap { $0.members } + towns.filter(\.owned).flatMap { $0.garrisonHeroes } + sanctuaryGuests.values.flatMap { $0.members }
        mine.sort { rank($0) > rank($1) }
        c.human = mine.map { SaveGame.state(of: $0) }
        c.humanColour = map.humanColour
        // the map's carry-out artifacts leave their holders for the pool (0x5be4a0: the slot is
        // emptied after 0x5bbd20 records it), worn ones first, then the backpack
        let out = map.carryOutArtifacts
        if !out.isEmpty {
            var pool: [Int] = []
            func pulls(_ id: Int) -> Bool { out.contains(RuleTables.artifactBase(id)) }
            for k in c.human.indices {
                if var eq = c.human[k].equipped {
                    for s in eq.indices { if let a = eq[s], pulls(a) { pool.append(a); eq[s] = nil } }
                    c.human[k].equipped = eq
                }
                if let bp = c.human[k].backpack { pool += bp.filter(pulls); c.human[k].backpack = bp.filter { !pulls($0) } }
            }
            c.artifacts = pool
        }
        var theirs: [Int: [Hero]] = [:]
        for h in enemyHeroes { for m in h.members { theirs[h.owner, default: []].append(m) } }
        for (col, hs) in theirs { c.byColour[col] = hs.sorted { rank($0) > rank($1) }.map { SaveGame.state(of: $0) } }
        return c
    }
    /// Put the carried heroes on their placeholders (0x5bf3c0 / 0x5bef90): named ones claim their
    /// hero first, the others take the next of their side; each becomes an army of its own there.
    /// With the campaign's position choice (`byColour`, game +0x398 with +0x399) the human list is
    /// first redistributed by colour (0x5bd290) and a human placeholder takes the next of its colour.
    public func placeCarried(_ c: Carryover, positionChoice: Bool = false) {
        var c = c
        if positionChoice { c.distributeHumanByColour() }
        var human = c.human, byColour = c.byColour
        let holders = scenes.indices.flatMap { l in scenes[l].placed.filter { $0.type == "carryover_hero" }.map { (l, $0) } }
        var claimed: [String: SaveGame.HeroState] = [:]
        for (l, p) in holders {
            guard let rec = map.objects.first(where: { $0.type == "carryover_hero" && $0.x == p.cellX && $0.y == p.cellY && $0.level == l }), let name = rec.heroName, !name.isEmpty else { continue }
            if let k = human.firstIndex(where: { $0.name == name }) { claimed["\(l)|\(p.cellX)|\(p.cellY)"] = human.remove(at: k); continue }
            for col in byColour.keys { if let k = byColour[col]!.firstIndex(where: { $0.name == name }) { claimed["\(l)|\(p.cellX)|\(p.cellY)"] = byColour[col]!.remove(at: k); break } }
        }
        let back = level
        for (l, p) in holders {
            let rec = map.objects.first { $0.type == "carryover_hero" && $0.x == p.cellX && $0.y == p.cellY && $0.level == l }
            let owner = rec?.owner ?? map.humanColour
            let key = "\(l)|\(p.cellX)|\(p.cellY)"
            var st = claimed[key]
            if st == nil {
                if owner == map.humanColour, !positionChoice { if !human.isEmpty { st = human.removeFirst() } }
                else if var list = byColour[owner], !list.isEmpty { st = list.removeFirst(); byColour[owner] = list }
            }
            level = l
            scene.remove(p)
            guard let s = st else { continue }
            let h = SaveGame.hero(from: s)
            h.x = p.cellX; h.y = p.cellY; h.z = l; h.owner = owner
            h.army = []; h.companions = []; h.path = []; h.plan = []
            h.maxMovement = armyMovement(h); h.movement = h.maxMovement
            if owner == map.humanColour { heroes.append(h) } else { enemyHeroes.append(h); passabilities[l].block(h.x, h.y) }
        }
        level = back
        giveCarriedArtifacts(c.artifacts ?? [])
    }
    /// The carried pool at map start (0x4cb680, from 0x4cf1c0 when carry-over data exists): every
    /// item this map lets in (`carryInArtifacts`, 0x5bcb20) goes to the human's hero with the most
    /// skill levels (0x4cb7f0: the sum over the 36 skills of level + 1, the first of equals), put
    /// on where its slot is free, else into the backpack (hero vtable+4 with "equip", 0x72a6f0).
    /// With no hero the exe gives them to a creature stack's backpack, which the remake lacks.
    public func giveCarriedArtifacts(_ pool: [Int]) {
        let items = pool.filter { map.carryInArtifacts.contains(RuleTables.artifactBase($0)) }
        guard !items.isEmpty else { return }
        func rank(_ h: Hero) -> Int { h.skills.values.reduce(0) { $0 + $1 + 1 } }
        var best: Hero? = nil
        for h in heroes.flatMap({ $0.members }) + towns.filter(\.owned).flatMap({ $0.garrisonHeroes }) where best == nil || rank(h) > rank(best!) { best = h }
        guard let h = best else { return }
        for a in items { h.receive(a, tables: tables) }
    }
}

/// What the new-game list shows of a map without loading it (the header, 0x77a420).
public struct MapSummary {
    public let name: String, description: String
    public let size: Int, levels: Int, difficulty: Int
    public let players: Int, humans: Int, version: Int
    public var scenarios = 1
    public init?(data raw: Data) {
        var d = raw
        if raw.prefix(10) == Data("H4CAMPAIGN".utf8) {
            if raw.count > 15, raw[raw.startIndex + 14] == 1, let c = try? CampaignFile(data: raw), let s = try? c.scenario(0) {
                d = s; scenarios = c.count
            } else {
                guard let g = raw.firstRange(of: Data([0x1f, 0x8b, 0x08])), let u = try? gunzip(raw.subdata(in: g.lowerBound..<raw.count), expected: raw.count * 12) else { return nil }
                d = u
            }
        }
        var r = ByteReader(d)
        guard d.count > 64 else { return nil }
        version = Int(r.u16())
        if version >= 28 { _ = r.u16() }
        size = Int(r.u16()); levels = Int(r.u8()); _ = r.u32()
        let np = Int(r.u8())
        var h = 0
        for _ in 0..<np { _ = r.u8(); if r.u8() != 0 { h += 1 }; _ = r.u8(); _ = r.u8(); _ = r.u8() }
        players = np; humans = h
        name = r.string16(); difficulty = Int(r.u8()); description = r.string16()
    }
}
