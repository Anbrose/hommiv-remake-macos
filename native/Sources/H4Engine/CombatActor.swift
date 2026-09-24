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

    public init(data d: Data) throws {
        var r = ByteReader(d)
        guard d.count > 108, r.u16() == 6 else { throw H4Error.corrupt("combat_actor: bad header") }
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

/// A battlefield preset (battlefield_preset_map.<set>.<single|upper|lower>.h4d): a 75x64 grid
/// of 16x16-pixel cells over a 1180x1024 backdrop picture (drawn scaled 3/4 into the 885x768
/// battle scene of the 1024 layout). Layout: u32 1, u32 1, u32 102, u32 16, u32 1180, u32 1024,
/// 40 bytes, 75x64 cells (1 open, 255 blocked, 0 off the field, 2 the raised ground of
/// two-level fields), then one layers-style image record "backdrop".
public struct Battlefield {
    public static let columns = 75, rows = 64, cellSize = 16
    public static let backdropWidth = 1180, backdropHeight = 1024
    public private(set) var cells: [UInt8]           // rows x columns, row-major
    public let backdrop: UILayer?
    /// Obstacles of a generated field: sprite entry name, anchor cell (bottom-left of the footprint).
    public struct Obstacle { public let name: String; public let x: Int, y: Int; public let w: Int, h: Int }
    public private(set) var obstacles: [Obstacle] = []

    public init(data d: Data) throws {
        guard d.count > 4864 else { throw H4Error.corrupt("battlefield: too short") }
        cells = Array(d[(d.startIndex + 64)..<(d.startIndex + 64 + Battlefield.columns * Battlefield.rows)])
        var img = Data([1, 0])
        img.append(d[(d.startIndex + 4864)...])
        backdrop = (try? LayerFile(data: img))?.layers.first
    }

    /// A land battlefield generated the way the game builds one from the adventure terrain:
    /// the terrain's diamond tiles staggered over the backdrop, obstacles scattered outside the
    /// deployment columns, their footprints (w x h cells up from the anchor) blocked.
    /// `obstacleFootprints` gives the footprint of each candidate sprite name.
    public init(obstacles candidates: [(name: String, w: Int, h: Int)], seed: Int) {
        backdrop = nil   // the ground is the adventure map's own terrain around the fight
        var c = [UInt8](repeating: 1, count: Battlefield.columns * Battlefield.rows)
        for y in 0..<Battlefield.rows { for x in 0..<Battlefield.columns where x < 2 || x > 71 || y < 4 || y > 59 { c[y * Battlefield.columns + x] = 0 } }
        var rng = UInt64(truncatingIfNeeded: seed &* 6364136223846793005 &+ 1442695040888963407)
        func rand(_ n: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(max(1, n))) }
        var list: [Obstacle] = []
        if !candidates.isEmpty {
            let count = 8 + rand(6)
            var tries = 0
            while list.count < count, tries < 200 {
                tries += 1
                let cand = candidates[rand(candidates.count)]
                let x = 20 + rand(Battlefield.columns - 40), y = 8 + rand(Battlefield.rows - 16)
                var free = true
                for i in 0..<cand.w { for j in 0..<cand.h {
                    let cx = x + i, cy = y - j
                    if cx < 0 || cx >= Battlefield.columns || cy < 0 || cy >= Battlefield.rows || c[cy * Battlefield.columns + cx] != 1 { free = false }
                    // keep a one-cell gap between obstacles
                    for dx in -1...1 { for dy in -1...1 { let nx = cx + dx, ny = cy + dy
                        if nx >= 0, nx < Battlefield.columns, ny >= 0, ny < Battlefield.rows, c[ny * Battlefield.columns + nx] == 255 { free = false } } }
                } }
                guard free else { continue }
                for i in 0..<cand.w { for j in 0..<cand.h { c[(y - j) * Battlefield.columns + x + i] = 255 } }
                list.append(Obstacle(name: cand.name, x: x, y: y, w: cand.w, h: cand.h))
            }
        }
        cells = c
        obstacles = list
    }

    public func cell(_ x: Int, _ y: Int) -> UInt8 {
        x >= 0 && x < Battlefield.columns && y >= 0 && y < Battlefield.rows ? cells[y * Battlefield.columns + x] : 0
    }
    public func isOpen(_ x: Int, _ y: Int) -> Bool { let c = cell(x, y); return c == 1 || c == 2 }
}
