import Foundation

/// A combat actor definition (combat_actor.<creature>.h4d, combat_actor.hero.<align>_<fighter|archer|mage>_<sex>.h4d):
/// states block, cast_spell, die, fidget, flinch, melee, melee_down, melee_up, postwalk, prewalk,
/// ranged, base_frame, wait, walk; each names the actor_sequence for the eight facings.
///
/// Layout: u16 6, 8 bytes, 8 x (u32, u32, u32), u16 nstates; per state: string16 name, u8 speed,
/// u8 hitFrame (the frame on which a melee lands / a shot leaves), 8 x string16 sequences
/// (facings ne, e, se, s, sw, w, nw, n; four-facing states repeat entries). Then a trailer.
public struct CombatActor {
    public struct State {
        public let name: String
        public let speed: Int
        public let hitFrame: Int
        public let sequences: [String]
    }
    public let states: [State]
    /// Footprint on the combat grid, size x size cells (byte 2: sprite 3, peasant 4, dragon 7).
    public let size: Int

    public init(data d: Data) throws {
        var r = ByteReader(d)
        guard d.count > 108, r.u16() == 6 else { throw H4Error.corrupt("combat_actor: bad header") }
        size = max(1, Int(r.byte(at: 2)))
        r.pos = 106
        let n = Int(r.u16())
        var list: [State] = []
        for _ in 0..<n {
            guard r.remaining > 4 else { break }
            let name = r.string16()
            let speed = Int(r.u8()), hit = Int(r.u8())
            var seqs: [String] = []
            for _ in 0..<8 { seqs.append(r.string16()) }
            list.append(State(name: name, speed: speed, hitFrame: hit, sequences: seqs))
        }
        states = list
    }

    public func state(_ name: String) -> State? { states.first { $0.name == name } }

    /// Archive entry of a state's sequence for a facing ("actor_sequence.Squire.combat.walk.e.h4d"), or nil.
    public func sequenceEntry(state: String, facing: String) -> String? {
        guard let s = self.state(state), let i = AdvActor.facings.firstIndex(of: facing) else { return nil }
        let name = s.sequences[i]
        return name.isEmpty ? nil : "actor_sequence.\(name).h4d"
    }
}

/// A battlefield, as read from heroes4.exe and measured against the original: a square world
/// grid of combat cells, each 16 world units (distances in the damage code are world
/// coordinates >> 4) drawn as a 32x16 diamond, half an adventure tile; the 1180x1024 scene
/// shows the cells whose centres fall inside it, scaled 3/4 into the 885x768 battle scene of
/// the 1024 layout (the original's ground diamonds measure 24x12 there). Creatures occupy
/// size x size cells (byte 2 of combat_actor: sprite 3, peasant 4, orc 5, titan 6, dragon 7),
/// obstacles w x h cells (bytes 2, 3 of combat_object).
///
/// A world point (x, y) in cells is at scene ((y - x) * 16 + 590, (x + y) * 8 + 512 - 8 * 102). A land field is generated from the terrain: its tiles over the whole scene, a
/// checker of darker cells, obstacles of the terrain's kind scattered away from the two
/// deployment corners (bottom-left for the attacker, top-right for the defender).
public struct Battlefield {
    /// World cells along each axis: 102, the value in the preset files' header, is exactly what
    /// makes the 32x16 diamonds cover the whole 1180x1024 scene.
    public static let size = 102
    public static let backdropWidth = 1180, backdropHeight = 1024

    public let backdrop: UILayer?
    public let terrain: UInt8, variant: UInt8
    public struct Obstacle { public let name: String; public let x: Int, y: Int; public let w: Int, h: Int }
    public private(set) var obstacles: [Obstacle] = []
    var blocked = [Bool](repeating: false, count: Battlefield.size * Battlefield.size)

    /// Screen (scene) point of a world point in cell units: x runs down-left, y down-right,
    /// the grid centre in the middle of the scene.
    public static func screen(_ x: Float, _ y: Float) -> (Float, Float) {
        ((y - x) * 16 + Float(backdropWidth) / 2, (x + y) * 8 + Float(backdropHeight) / 2 - Float(size) * 8)
    }
    /// The world point (cell units) under a scene point.
    public static func world(_ sx: Float, _ sy: Float) -> (Float, Float) {
        let u = (sx - Float(backdropWidth) / 2) / 16          // y - x
        let v = (sy - Float(backdropHeight) / 2 + Float(size) * 8) / 8   // x + y
        return ((v - u) / 2, (v + u) / 2)
    }
    /// Is the cell on the field: inside the grid, its centre inside the scene with a margin.
    public static func onField(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        let (sx, sy) = screen(Float(x) + 0.5, Float(y) + 0.5)
        return sx > 24 && sx < Float(backdropWidth) - 24 && sy > 40 && sy < Float(backdropHeight) - 16
    }

    public init(data d: Data) throws {
        var img = Data([1, 0])
        img.append(d[(d.startIndex + 4864)...])
        backdrop = (try? LayerFile(data: img))?.layers.first
        terrain = 0; variant = 0
    }

    /// An obstacle kind from combat_header (heroes4.h4r): its combat_object sprite, footprint,
    /// whether it blocks movement and shots, and its group in table.combat_obstacles.
    public struct ObstacleKind {
        public let name: String, group: String
        public let w: Int, h: Int
        public let blocks: Bool
        public init(name: String, group: String, w: Int, h: Int, blocks: Bool) { self.name = name; self.group = group; self.w = w; self.h = h; self.blocks = blocks }
    }
    /// combat_header_table_cache.combat_header.h4d: u32 3, u32 1, u32 2002, u32 10, u32 45,
    /// u32 count, then per obstacle: u32 len + name, 14 header bytes (as combat_object's:
    /// byte 2, 3 footprint, byte 7 blocks), u16 len + group name.
    public static func obstacleKinds(_ d: Data) -> [ObstacleKind] {
        let r = ByteReader(d)
        guard d.count > 24 else { return [] }
        let count = Int(r.peekU32(at: 20))
        var p = 24, out: [ObstacleKind] = []
        for _ in 0..<count {
            guard p + 4 < d.count else { break }
            let n = Int(r.peekU32(at: p))
            guard n > 0, n < 100, p + 4 + n + 16 <= d.count else { break }
            let name = String(bytes: d[(d.startIndex + p + 4)..<(d.startIndex + p + 4 + n)], encoding: .isoLatin1) ?? ""
            let q = p + 4 + n
            let w = Int(r.byte(at: q + 2)), h = Int(r.byte(at: q + 3)), blocks = r.byte(at: q + 7) != 0
            let gl = Int(r.peekU16(at: q + 14))
            let group = String(bytes: d[(d.startIndex + q + 16)..<(d.startIndex + q + 16 + gl)], encoding: .isoLatin1) ?? ""
            out.append(ObstacleKind(name: "combat_object.\(name).h4d", group: group, w: max(1, w), h: max(1, h), blocks: blocks))
            p = q + 16 + gl
        }
        return out
    }

    /// A land battlefield: obstacles chosen by table.combat_obstacles for the terrain (groups
    /// weighted usually/common/seldom/rare), often clustered with the groups the Adjacent part
    /// of the table pairs them with; ground cover (non-blocking obstacles) blocks nothing.
    public init(terrain: UInt8, variant: UInt8, kinds: [ObstacleKind], frequency: [String: String], adjacency: [String: [String: String]], seed: Int) {
        backdrop = nil
        self.terrain = terrain; self.variant = variant
        var rng = GameRandom(seed: seed)
        let weight: [String: Int] = ["usually": 16, "common": 8, "seldom": 4, "rare": 1]
        let byGroup = Dictionary(grouping: kinds, by: { $0.group })
        func pick(_ weights: [String: String]) -> String? {
            let items = weights.compactMap { g, f -> (String, Int)? in
                guard let w = weight[f], w > 0, byGroup[g] != nil else { return nil }; return (g, w) }.sorted { $0.0 < $1.0 }
            let total = items.reduce(0) { $0 + $1.1 }
            guard total > 0 else { return nil }
            var r = rng.next() % total
            for (g, w) in items { if r < w { return g }; r -= w }
            return nil
        }
        let n = Battlefield.size
        var list: [Obstacle] = []
        var last: Obstacle? = nil, lastGroup = ""
        let count = 22 + rng.next() % 14
        var tries = 0
        while list.count < count, tries < 600 {
            tries += 1
            let cluster = last != nil && rng.next() % 2 == 0
            guard let group = (cluster ? pick(adjacency[lastGroup] ?? [:]) : nil) ?? pick(frequency), let options = byGroup[group] else { break }
            let kind = options[rng.next() % options.count]
            var x = rng.next() % n, y = rng.next() % n
            if cluster, let l = last { x = l.x + rng.next() % (l.w + kind.w + 2) - kind.w - 1; y = l.y + rng.next() % (l.h + kind.h + 2) - kind.h - 1 }
            // the deployment cells of every land formation stay clear
            func inZone(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Bool { x + kind.w > x0 && x <= x1 && y + kind.h > y0 && y <= y1 }
            if kind.blocks && (inZone(72, 95, 47, 82) || inZone(14, 37, 28, 63)) { continue }
            var ok = true
            for i in 0..<kind.w { for j in 0..<kind.h where !Battlefield.onField(x + i, y + j) || (kind.blocks && blocked[(x + i) * n + y + j]) { ok = false } }
            guard ok else { continue }
            if kind.blocks { for i in 0..<kind.w { for j in 0..<kind.h { blocked[(x + i) * n + y + j] = true } } }
            let o = Obstacle(name: kind.name, x: x, y: y, w: kind.w, h: kind.h)
            list.append(o); last = o; lastGroup = group
        }
        obstacles = list
    }

    public func isOpen(_ x: Int, _ y: Int) -> Bool {
        Battlefield.onField(x, y) && !blocked[x * Battlefield.size + y]
    }
    /// Is a size x size footprint with its top corner at (x, y) free of obstacles and on the field?
    public func fits(_ x: Int, _ y: Int, size: Int) -> Bool {
        for i in 0..<size { for j in 0..<size where !isOpen(x + i, y + j) { return false } }
        return true
    }
    /// Does the straight line between two world points cross an obstacle cell?
    public func obstructed(_ a: (Float, Float), _ b: (Float, Float)) -> Bool {
        let d = max(abs(b.0 - a.0), abs(b.1 - a.1))
        let steps = max(1, Int(d * 2))
        for k in 1..<steps {
            let t = Float(k) / Float(steps)
            let x = Int((a.0 + (b.0 - a.0) * t).rounded(.down)), y = Int((a.1 + (b.1 - a.1) * t).rounded(.down))
            if x >= 0, y >= 0, x < Battlefield.size, y < Battlefield.size, blocked[x * Battlefield.size + y] { return true }
        }
        return false
    }
}
