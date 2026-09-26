import Foundation

public struct MapObject {
    public let name: String
    public let type: String
    public let subtype: String
    public let terrain: String
    public let x: Int
    public let y: Int
    public let level: Int
    /// Owning player (0 = the first player) for towns; nil when unowned or not ownable.
    public var owner: Int? = nil
    /// A carryover hero placeholder's hero (empty: the next one of its side).
    public var heroName: String? = nil
    /// A town's name set in the editor ("none" = pick a random one).
    public var customName: String? = nil
    /// A town's editor settings (garrison, built and allowed buildings).
    public var town: TownSettings? = nil
    /// A placed army's stacks (creature id, count; 0 = random), for type "army".
    public var army: [(creature: Int, count: Int)?]? = nil
    /// The heroes of a placed army (players' starting heroes are armies placed on the map).
    public var heroes: [MapHero] = []
    /// A random monster's size range in peasants (min, max), when the editor set one.
    public var monsterRange: (min: Int, max: Int)? = nil
    /// A sign's or bottle's message; the name of an event trigger's or Pandora's box's event.
    public var text: String? = nil
    /// A prison's hero.
    public var prisoner: MapHero? = nil
    /// An obelisk marker's radius for the dig site.
    public var markerRadius: Int? = nil
    /// A spell scroll's or parchment's spell.
    public var spell: Int? = nil
    /// A quest site's texts (0x7ed980: four strings), its reward action and condition.
    public var questTexts: [String] = []
    public var questAction: ScriptNode? = nil, questCondition: ScriptNode? = nil, questAction2: ScriptNode? = nil

    /// The town part of a town record as heroes4.exe reads it (0x417990, versions 6...8):
    /// u16 version, u8 owner (6 = none), string16 name, u8 custom garrison + creature array,
    /// u8 custom buildings + 6 bytes built + 6 bytes allowed (43-bit sets, 0x417c10) or u8 fort.
    /// Four event lists follow. A placed town (0x89a710) puts u16 version and, from version
    /// 4, two versioned 188-bit spell sets in front; a random town a u32 and a string16.
    static func parseTownBody(_ rd: inout ByteReader, random: Bool) -> TownSettings? {
        if random {
            guard rd.remaining >= 6 else { return nil }
            _ = rd.u32(); _ = rd.string16()
        } else {
            guard rd.remaining >= 2 else { return nil }
            let v = rd.u16()
            if v >= 4 {
                for _ in 0..<2 {
                    guard rd.remaining >= 25 else { return nil }
                    let bv = rd.u8(); rd.pos += bv == 0 ? 23 : 24
                }
            }
        }
        guard rd.remaining >= 4 else { return nil }
        let ver = Int(rd.u16())
        guard (6...8).contains(ver) else { return nil }
        var t = TownSettings()
        let o = Int(rd.u8())
        t.owner = o < 6 ? o : nil
        let n = rd.string16()
        if !n.isEmpty, n.lowercased() != "none" { t.name = n }
        guard rd.remaining >= 1 else { return t }
        if rd.u8() != 0 {
            guard let g = MapFile.parseCreatureArray(&rd) else { return t }
            t.garrison = g
        }
        guard rd.remaining >= 1 else { return t }
        if rd.u8() != 0 {
            guard rd.remaining >= 12 else { return t }
            func bits(_ d: Data) -> UInt64 { d.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }
            t.built = bits(rd.bytes(6)); t.allowed = bits(rd.bytes(6))
        } else if rd.remaining >= 1 {
            t.hasFort = rd.u8() != 0
        }
        // the town's events: 4 standard ones (slot 1 when captured, 3 when visited), then the
        // timed, triggerable and continuous lists (0x417e40 ... 0x418550)
        var sr = ScriptReader(rd.data, at: rd.pos)
        if let b = try? (0..<4).map({ try sr.builtinEvent(slot: $0) }), let timed = try? sr.list({ try $0.timedEvent() }),
           let trig = try? sr.list({ try $0.triggerableEvent() }), let cont = try? sr.list({ try $0.continuousEvent() }) {
            t.events = b + timed + trig + cont
        }
        return t
    }
}

/// A player slot of the map: its colour, whether a human may take it, and the alignments
/// (bit 0 life, 1 order, 2 death, 3 chaos, 4 nature, 5 might) its random heroes and towns may have.
public struct PlayerSpec { public let colour: Int, canBeHuman: Bool, alignments: UInt8 }

/// Editor settings of a town.
public struct TownSettings {
    public var owner: Int? = nil
    public var name: String? = nil
    /// (creature id in heroes4.exe's order, count; 0 = a random count) per slot, nil when empty.
    public var garrison: [(creature: Int, count: Int)?]? = nil
    /// Building ids (0...42, per town type: see RuleTables.buildingIds) as bit sets.
    public var built: UInt64? = nil, allowed: UInt64? = nil
    public var hasFort = false
    /// The town's scripted events.
    public var events: [MapEvent] = []
}

public struct Overlay {
    public let type: UInt8, variant: UInt8, mask: Int, order: UInt8
}

/// A road piece on a cell: `kind` 0 is the road body (drawn where the mask is CLEAR), 1..3 a
/// shoulder spilling from a neighbouring road of that type (1 stone, 2 dirt, 3 cobble; drawn
/// where the mask is SET); `order` (10..14) sorts it among the cell's terrain overlays.
public struct Road {
    public let kind: UInt8, mask: Int, order: UInt8
}

public struct Cell {
    public let type: UInt8
    public let variant: UInt8
    public let overlays: [Overlay]
    public let roads: [Road]
}

/// A decoded .h4c scenario. Format: tools/h4map.py.
public struct MapFile {
    public let version: Int
    public let size: Int
    public let levels: Int
    public let players: [UInt8]
    public let playerSpecs: [PlayerSpec]
    public let name: String
    public let description: String
    /// Team of each player colour (players on one team are allies).
    public let teams: [Int: Int]
    /// The editor's win/loss texts (nil = the standard ones) and whether the standard victory
    /// condition ("be the only player to own towns") is on.
    public let victoryText: String?, lossText: String?
    public let standardVictory: Bool
    /// A campaign scenario's cut scenes: text, 426x340 splash (layers.Campaign_Splashscreens.426x340.*),
    /// voice-over (sound.Voice_Over.*); and what carries over to the next scenario.
    public struct CutScene { public let text: String, image: String, voice: String }
    public var prologue: CutScene? = nil, epilogue: CutScene? = nil
    public var carryoverText = ""
    /// The map's own events (timed, triggerable, continuous).
    public let events: [MapEvent]
    /// The colour the human plays: the first player slot a human may take.
    public var humanColour: Int { playerSpecs.first { $0.canBeHuman }?.colour ?? playerSpecs.first?.colour ?? 0 }
    /// Map difficulty (0 easy ... 4 impossible), the byte after the name.
    public let difficulty: Int
    public let objects: [MapObject]
    /// The map's placed events (0x4d0200): what Pandora's boxes and event triggers run, by name.
    public private(set) var placedEvents: [MapEvent] = []
    /// cells[level][x * size + y]; nil outside the playable diamond
    public let cells: [[Cell?]]

    public static func diamond(_ size: Int) -> [(Int, Int)] {
        let mid = Double(size - 1) / 2
        var pts: [(Int, Int)] = []
        for r in 0..<size { for c in 0..<size where abs(Double(r) - mid) + abs(Double(c) - mid) <= Double(size) / 2 { pts.append((r, c)) } }
        return pts
    }

    public init(data raw: Data, objectNames: Set<String>) throws {
        var d = raw
        if raw.count > 10, raw.prefix(10) == Data("H4CAMPAIGN".utf8) {
            guard let g = raw.firstRange(of: Data([0x1f, 0x8b, 0x08])) else { throw H4Error.corrupt("map: no gzip") }
            d = try gunzip(raw.subdata(in: g.lowerBound..<raw.count), expected: raw.count * 12)
        }
        var r = ByteReader(d)
        version = Int(r.u16())
        if version >= 28 { _ = r.u16() }
        size = Int(r.u16())
        levels = Int(r.u8())
        _ = r.u32()
        // players (heroes4.exe 0x77a5f6): u8 colour, u8 can be human, u8 (unknown), then a
        // versioned bit set of the alignments its random heroes and towns may take
        let np = Int(r.u8())
        var pl: [UInt8] = [], specs: [PlayerSpec] = []
        for _ in 0..<np {
            let colour = r.u8(), human = r.u8() != 0
            _ = r.u8(); _ = r.u8()
            let mask = r.u8()
            pl.append(colour); specs.append(PlayerSpec(colour: Int(colour), canBeHuman: human, alignments: mask))
        }
        players = pl
        playerSpecs = specs
        name = r.string16()
        difficulty = Int(r.u8())
        description = r.string16()
        // teams, win/loss texts (heroes4.exe 0x77a74c): u16 version, u8 teams, per team u8 colour
        // mask; u8 + string16 custom victory text; u8 + string16 custom loss text; from version
        // 25 u8 "standard victory condition enabled"
        var tm: [Int: Int] = [:], vt: String? = nil, lt: String? = nil, std = true
        if r.remaining > 8 {
            _ = r.u16()
            let n = Int(r.u8())
            for team in 0..<min(n, 6) { let mask = r.u8(); for p in 0..<6 where mask & (1 << p) != 0 { tm[p] = team } }
            // (0x77a931 / 0x77a9c5: the loss text comes first, then the victory text)
            if r.u8() != 0 { lt = r.string16() }
            if r.u8() != 0 { vt = r.string16() }
            if version >= 25 { std = r.u8() != 0 }
        }
        teams = tm; victoryText = vt; lossText = lt; standardVictory = std
        // then (0x77aa49) prologue / epilogue flags (v >= 24; a set one carries a block not
        // decoded here), the carryover text (v >= 27), a flag (v >= 29): the map's event lists follow
        // a cut scene (0x816970): u16 0, the text, the 426x340 splash name, the voice-over name
        func cutScene() -> CutScene { _ = r.u16(); return CutScene(text: r.string16(), image: r.string16(), voice: r.string16()) }
        var exact = true
        if version >= 24, r.remaining >= 2 {
            if r.u8() != 0 { prologue = cutScene() }
            if r.u8() != 0 { epilogue = cutScene() }
        }
        if version >= 27, r.remaining >= 2 { carryoverText = r.string16() }
        if version >= 29, r.remaining >= 1 { _ = r.u8() }
        if r.remaining < 4 { exact = false }
        if exact {
            var sr = ScriptReader(d, at: r.pos)
            if let timed = try? sr.list({ try $0.timedEvent() }), let trig = try? sr.list({ try $0.triggerableEvent(trailer: false) }),
               let cont = try? sr.list({ try $0.continuousEvent(trailer: false) }) { events = timed + trig + cont } else { events = [] }
        } else {
            events = ScriptReader.mapEvents(d, from: r.pos)
        }
        let headerEnd = r.pos

        let pts = MapFile.diamond(size)
        let perLevel = pts.count
        guard let (cellsFlat, terrainPos) = MapFile.findTerrain(d, from: headerEnd, count: perLevel * levels) else {
            throw H4Error.corrupt("map: terrain not found")
        }
        objects = MapFile.parseObjects(d, end: terrainPos, names: objectNames) + MapFile.parseArmies(d, end: terrainPos, size: size)
        // the placed-event list lies before the objects; found where a whole list reads and its
        // names are those of the map's boxes and triggers
        let wanted = Set(objects.filter { $0.type == "pandoras_box" || $0.type == "event_trigger" }.compactMap { $0.text?.lowercased() })
        if !wanted.isEmpty {
            let b = [UInt8](d.prefix(terrainPos))
            var best: (Int, [MapEvent]) = (0, [])
            var p = headerEnd
            while p + 4 < b.count {
                defer { p += 1 }
                let n = Int(b[p]) | Int(b[p + 1]) << 8
                guard n > 0, n <= 200, b[p + 3] == 0, b[p + 2] <= 1 else { continue }
                var sr = ScriptReader(d, at: p + 2)
                var evs: [MapEvent] = []
                for _ in 0..<n { guard let e = try? sr.placedEvent() else { break }; evs.append(e) }
                guard evs.count == n else { continue }
                let k = evs.filter { wanted.contains($0.name.lowercased()) }.count
                if k > best.0 { best = (k, evs); if k == wanted.count { break } }
            }
            placedEvents = best.1
        }
        var grids: [[Cell?]] = []
        for lv in 0..<levels {
            var g = [Cell?](repeating: nil, count: size * size)
            for (i, (x, y)) in pts.enumerated() { g[x * size + y] = cellsFlat[lv * perLevel + i] }
            grids.append(g)
        }
        cells = grids
    }

    static func parseCells(_ d: Data, at start: Int, count: Int) -> ([Cell], Int)? {
        let r = ByteReader(d)
        var pos = start
        var out: [Cell] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard pos + 11 <= d.count else { return nil }
            let t = r.byte(at: pos), v = r.byte(at: pos + 1), n = Int(r.byte(at: pos + 9))
            guard t <= 18, v <= 3, n <= 8 else { return nil }
            var ov: [Overlay] = []
            for i in 0..<n {
                let p = pos + 10 + i * 5
                guard p + 5 <= d.count else { return nil }
                ov.append(Overlay(type: r.byte(at: p), variant: r.byte(at: p + 1), mask: Int(r.peekU16(at: p + 2)), order: r.byte(at: p + 4)))
            }
            let q = pos + 10 + 5 * n
            guard q < d.count else { return nil }
            let m = Int(r.byte(at: q))
            guard m <= 8, q + 1 + 4 * m <= d.count else { return nil }
            var rd: [Road] = []
            for i in 0..<m { let p = q + 1 + i * 4; rd.append(Road(kind: r.byte(at: p), mask: Int(r.byte(at: p + 1)), order: r.byte(at: p + 3))) }
            out.append(Cell(type: t, variant: v, overlays: ov, roads: rd))
            pos = q + 1 + 4 * m
        }
        return (out, pos)
    }

    static func findTerrain(_ d: Data, from: Int, count: Int) -> ([Cell], Int)? {
        let r = ByteReader(d)
        var p = from
        while p + 11 * count <= d.count {
            if let (cells, end) = parseCells(d, at: p, count: count) {
                if end >= d.count || r.peekU16(at: end + 7) != 8 { return (cells, p) }
            }
            p += 1
        }
        return nil
    }

    /// A creature array (0x640d00): u16 version 0, 7 slots of u8 kind (0xff empty, 0 creature:
    /// u16 version, i16 id, i16 count, version 1: u16 extra count). Heroes and extras are not read.
    static func parseCreatureArray(_ rd: inout ByteReader) -> [(creature: Int, count: Int)?]? {
        var heroes: [MapHero] = []
        return parseCreatureArray(&rd, heroes: &heroes)
    }
    /// A creature array (0x640d00): u16 0, then 7 slots -- 0xff empty, 0 a creature stack
    /// (u16 version, i16 creature, i16 count[, u16 0]), 1 a hero (parseHero).
    static func parseCreatureArray(_ rd: inout ByteReader, heroes: inout [MapHero]) -> [(creature: Int, count: Int)?]? {
        guard rd.remaining >= 2, rd.u16() == 0 else { return nil }
        var out: [(creature: Int, count: Int)?] = []
        for _ in 0..<7 {
            guard rd.remaining >= 1 else { return nil }
            let kind = rd.u8()
            if kind == 0xff { out.append(nil); continue }
            if kind == 1 {
                guard let (h, end) = MapFile.parseHero(rd.data, at: rd.pos) else { return nil }
                heroes.append(h); out.append(nil); rd.pos = end
                continue
            }
            guard kind == 0, rd.remaining >= 6 else { return nil }
            let v = rd.u16(), id = Int(Int16(bitPattern: rd.u16())), n = Int(Int16(bitPattern: rd.u16()))
            if v >= 1 {   // the stack's artifacts (0x653760)
                guard rd.remaining >= 2 else { return nil }
                let k = Int(rd.u16())
                guard k <= 100 else { return nil }
                for _ in 0..<k {
                    guard rd.remaining >= 2 else { return nil }
                    let a = rd.u16()
                    if a == 0x7c || a == 0xa6 { guard rd.remaining >= 2 else { return nil }; _ = rd.u16() }
                }
            }
            out.append(id >= 0 ? (id, n) : nil)
        }
        return out
    }

    /// A hero in a creature array (slot kind 1, t_hero's reader 0x72f4e0, versions 8...10):
    /// u16 version, i16 portrait, i8 class, i8 gender (-1: random), u8 level (v5+), four stat
    /// bytes (v10+; two u16 + two u8 before), string16 biography and name, u8 custom skills +
    /// 36 i8 levels (v3+), the spells (u8 version: 23 or 24 bytes, v4+), 14 equipped artifact
    /// slots (u8 flag + artifact), the backpack (u16 n + artifacts), then its events (three
    /// standard ones and the timed, triggerable and continuous lists) and u8 (v9+).
    /// An artifact (0x664640): u16 id, and for a scroll or a spell potion (0xa6, 0x7c) u16 spell.
    public static func parseHero(_ d: Data, at start: Int) -> (hero: MapHero, end: Int)? {
        var r = ByteReader(d, at: start)
        func ok(_ n: Int) -> Bool { r.remaining >= n }
        guard ok(2) else { return nil }
        let v = Int(r.u16())
        guard (8...10).contains(v), ok(5) else { return nil }
        var h = MapHero()
        h.portrait = Int(Int16(bitPattern: r.u16()))
        h.heroClass = Int(Int8(bitPattern: r.u8())); h.gender = Int(Int8(bitPattern: r.u8()))
        h.level = Int(r.u8())
        if v >= 10 { guard ok(4) else { return nil }; h.stats = (0..<4).map { _ in Int(r.u8()) } }
        else { guard ok(6) else { return nil }; h.stats = [Int(r.u16()), Int(r.u16()), Int(r.u8()), Int(r.u8())] }
        // (the biography comes first, then the name: the campaigns' named heroes show it)
        guard ok(2) else { return nil }; h.biography = r.string16()
        guard ok(2) else { return nil }; h.name = r.string16()
        guard ok(1) else { return nil }
        if r.u8() != 0 { guard ok(36) else { return nil }; h.skills = (0..<36).map { _ in Int(Int8(bitPattern: r.u8())) } }
        guard ok(1) else { return nil }
        let sv = Int(r.u8())
        guard sv <= 2, ok(sv == 0 ? 23 : 24) else { return nil }
        h.spells = [UInt8](r.bytes(sv == 0 ? 23 : 24))
        func artifact() -> Int? {
            guard ok(2) else { return nil }
            let id = Int(r.u16())
            guard id <= 0xf8 else { return nil }
            if id == 0xa6 || id == 0x7c { guard ok(2) else { return nil }; _ = r.u16() }
            return id
        }
        for _ in 0..<14 {
            guard ok(1) else { return nil }
            if r.u8() != 0 { guard let a = artifact() else { return nil }; h.equipped.append(a) } else { h.equipped.append(nil) }
        }
        guard ok(2) else { return nil }
        let n = Int(r.u16())
        guard n <= 200 else { return nil }
        for _ in 0..<n { guard let a = artifact() else { return nil }; h.backpack.append(a) }
        var sr = ScriptReader(d, at: r.pos)
        // three standard events (0x738700), then the timed, triggerable and continuous lists
        guard let b = try? (0..<3).map({ try sr.builtinEvent(slot: $0) }), let timed = try? sr.list({ try $0.timedEvent() }),
              let trig = try? sr.list({ try $0.triggerableEvent() }), let cont = try? sr.list({ try $0.continuousEvent() }) else { return nil }
        h.events = b + timed + trig + cont
        var end = sr.position
        if v >= 9 { end += 1 }
        return (h, end)
    }

    /// Armies placed in the editor (the object loop 0x4ced20 with flag 1: t_army, no model
    /// name): i32 x, i32 y, i32 level, u8 1, then t_army's record (0x523a30): u16 version,
    /// u8 owner (6 = neutral), the creature array. Found by that shape; neutral ones only.
    static func parseArmies(_ d: Data, end: Int, size: Int) -> [MapObject] {
        let r = ByteReader(d)
        var out: [MapObject] = []
        var p = 0
        while p + 30 < end {
            defer { p += 1 }
            guard r.byte(at: p + 12) == 1 else { continue }
            let x = Int(Int32(bitPattern: r.peekU32(at: p))), y = Int(Int32(bitPattern: r.peekU32(at: p + 4))), lv = Int(Int32(bitPattern: r.peekU32(at: p + 8)))
            guard (0..<size).contains(x), (0..<size).contains(y), lv == 0 || lv == 1 else { continue }
            let v = Int(r.peekU16(at: p + 13))
            let owner = Int(r.byte(at: p + 15))
            guard (3...9).contains(v), owner <= 6 else { continue }
            var rd = ByteReader(d, at: p + 16)
            var heroes: [MapHero] = []
            guard let stacks = MapFile.parseCreatureArray(&rd, heroes: &heroes), stacks.contains(where: { $0 != nil }) || !heroes.isEmpty else { continue }
            // a player's army carries its heroes; a neutral one is a stack to fight
            guard owner == 6 || !heroes.isEmpty else { continue }
            var o = MapObject(name: "army", type: owner == 6 ? "army" : "hero_army", subtype: "", terrain: "", x: x, y: y, level: lv)
            o.army = stacks; o.heroes = heroes
            o.owner = owner == 6 ? nil : owner
            out.append(o)
        }
        return out
    }

    static func parseObjects(_ d: Data, end: Int, names: Set<String>) -> [MapObject] {
        let r = ByteReader(d)
        var starts: [Int] = []
        var p = 0
        while p < end - 2 {
            let ln = Int(r.peekU16(at: p))
            if ln >= 4, ln <= 60, p + 2 + ln <= d.count,
               let s = String(bytes: d[(d.startIndex + p + 2)..<(d.startIndex + p + 2 + ln)], encoding: .isoLatin1), names.contains(s) {
                starts.append(p)
                p += 2 + ln
            } else {
                p += 1
            }
        }
        // Each record is `i32 x, i32 y, u8 level, u32 0` followed by the object's name and body:
        // the position comes BEFORE the name (reading it after the body shifts every object onto
        // the next record's cell -- it looked plausible because the editor saves neighbours together).
        var objs: [MapObject] = []
        for p in starts where p >= 13 {
            var rd = ByteReader(d, at: p)
            let name = rd.string16()
            rd.pos += 2
            var cats: [String] = []
            for _ in 0..<3 { _ = rd.u16(); cats.append(rd.string16()) }
            let x = Int(Int32(bitPattern: r.peekU32(at: p - 13))), y = Int(Int32(bitPattern: r.peekU32(at: p - 9)))
            var o = MapObject(name: name, type: cats[0], subtype: cats[1], terrain: cats[2], x: x, y: y, level: Int(r.byte(at: p - 5)))
            if cats[0] == "town" || cats[0] == "random_town" {
                let t = MapObject.parseTownBody(&rd, random: cats[0] == "random_town")
                o.town = t; o.owner = t?.owner; o.customName = t?.name
            }
            // the class's own body (vtable slot 36, objbodies_spec)
            var sr = ScriptReader(d, at: rd.pos)
            switch cats[0] {
            case "sign", "ocean_bottle", "event_trigger", "pandoras_box":
                if let v = try? sr.word(), v == 1, let t = try? sr.string() { o.text = t }
            case "mine", "garrison", "creature_dwelling", "shipyard", "lighthouse", "windmill", "weekly_material_generator", "random_weekly_material_generator":
                // owned objects (0x7d3fb0 / 0x7d7270): u16 version, v1+ u8 owner (6 = none)
                if let v = try? sr.word(), v >= 1, let ow = try? sr.byte(), ow < 6 { o.owner = ow }
            case "carryover_hero":   // 0x5bf4a0: u16 version; v >= 1 u8 owner, string16 hero name
                if let v = try? sr.word(), v >= 1, let ow = try? sr.byte(), let nm = try? sr.string() { o.owner = Int(ow); o.heroName = nm }
            case "obelisk_marker":   // 0x7c6a80: u16 version, v1 u16 radius
                if let v = try? sr.word(), v == 1, let r = try? sr.word() { o.markerRadius = r }
            case "prison":
                if let v = try? sr.word(), v == 1, let (h, _) = MapFile.parseHero(d, at: sr.position) { o.prisoner = h }
            case "artifact" where cats[1] == "parchment" || cats[1] == "scroll":
                if let v = try? sr.word(), v == 1, let sp = try? sr.long() { o.spell = sp }
            case "quest_gate", "quest_guard", "seers_hut":
                if let v = try? sr.word(), v >= 1 {
                    let texts = (0..<4).compactMap { _ in try? sr.string() }
                    if texts.count == 4 {
                        o.questTexts = texts
                        o.questAction = try? sr.versionedAction()
                        o.questCondition = try? sr.versionedBoolean()
                        if cats[0] != "quest_gate", let t = try? sr.string() {
                            o.questTexts.append(t)
                            if v >= 2, let a = try? sr.versionedAction() { o.questAction2 = a }
                            if cats[0] == "seers_hut", let t2 = try? sr.string() { o.questTexts.append(t2) }
                            if cats[0] == "seers_hut", v == 1, let a = try? sr.versionedAction() { o.questAction2 = a }
                        }
                    }
                }
            default: break
            }
            if cats[0] == "random_monster", let next = starts.first(where: { $0 > p }) {
                // version 4 records end with i32 min, i32 max (0x7f3710), just before the next
                // record's 13-byte header; 0, 0 = the level's default size
                let end = next - 13
                if end - 8 > rd.pos {
                    let lo = Int(Int32(bitPattern: r.peekU32(at: end - 8))), hi = Int(Int32(bitPattern: r.peekU32(at: end - 4)))
                    if lo > 0, hi >= lo, hi < 1_000_000 { o.monsterRange = (lo, hi) }
                }
            }
            objs.append(o)
        }
        return objs
    }
}

/// A hero as a map sets it up (heroes4.exe t_hero, 0x72f4e0); -1 fields are "random".
public struct MapHero {
    public var portrait = -1, heroClass = -1, gender = -1, level = 1
    public var stats: [Int] = []
    public var name = "", biography = ""
    /// 36 skill levels (-1 none, 0 basic ... 4 grandmaster), or nil: the class's own at random.
    public var skills: [Int]? = nil
    public var spells: [UInt8] = []
    /// Worn artifacts by slot (RuleTables.equipSlots), and the backpack.
    public var equipped: [Int?] = [], backpack: [Int] = []
    public var events: [MapEvent] = []
    public init() {}
}
