import Foundation

/// A campaign (campaign_spec §1): "H4CAMPAIGN", u32 version, u8 1, then u16 header version, name,
/// description, the carry-in / carry-out flags (v >= 2), the position choice (v >= 3), u16 maps,
/// their compressed sizes and the gzip streams back to back. The shipped ones are the archives'
/// game_maps.* entries (a 16-byte wrapper before the file).
public struct CampaignFile {
    public let name: String, description: String
    public let carryIn: Bool, carryOut: Bool
    let slices: [Data]
    public var count: Int { slices.count }

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
        var cin = false, cout = false
        if hver >= 2 {
            cin = r.u8() != 0
            if cin { let n = Int(r.u16()); for _ in 0..<n { _ = r.string16() } }
            cout = r.u8() != 0
        }
        if hver >= 3 {   // the "choose your position" block (0x5ad6f0)
            let v = r.u16()
            if r.u8() != 0 {
                _ = r.string16(); _ = r.u8()
                for _ in 0..<6 where r.u8() != 0 {
                    _ = r.u32()
                    if v >= 1, r.u8() != 0 { _ = r.string16(); _ = r.string16() }
                }
            }
        }
        carryIn = cin; carryOut = cout
        let n = Int(r.u16())
        let sizes = (0..<n).map { _ in Int(r.u32()) }
        var at = r.pos, out: [Data] = []
        for s in sizes {
            guard at + s <= d.count else { throw H4Error.corrupt("campaign: short") }
            out.append(d.subdata(in: (d.startIndex + at)..<(d.startIndex + at + s))); at += s
        }
        slices = out
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
    public init() {}
}

extension GameState {
    /// The campaign being played: its standard id, this scenario's index, the player difficulty.
    public func carryOut() -> Carryover {
        var c = Carryover()
        func rank(_ h: Hero) -> Int { h.skills.values.reduce(0) { $0 + $1 + 1 } }
        var mine = heroes.flatMap { [$0] + $0.companions } + towns.filter(\.owned).flatMap { $0.garrisonHeroes } + sanctuaryGuests.values.flatMap { [$0] + $0.companions }
        mine.sort { rank($0) > rank($1) }
        c.human = mine.map { SaveGame.state(of: $0) }
        var theirs: [Int: [Hero]] = [:]
        for h in enemyHeroes { for m in [h] + h.companions { theirs[h.owner, default: []].append(m) } }
        for (col, hs) in theirs { c.byColour[col] = hs.sorted { rank($0) > rank($1) }.map { SaveGame.state(of: $0) } }
        return c
    }
    /// Put the carried heroes on their placeholders (0x5bf3c0 / 0x5bef90): named ones claim their
    /// hero first, the others take the next of their side; each becomes an army of its own there.
    public func placeCarried(_ c: Carryover) {
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
                if owner == map.humanColour { if !human.isEmpty { st = human.removeFirst() } }
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
