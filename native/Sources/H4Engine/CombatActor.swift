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

/// A battlefield: a 1180x1024 picture (drawn scaled 3/4 into the 885x768 battle scene of the
/// 1024 layout) covered by an isometric lattice of 64x32 diamond cells like the adventure
/// map's: cell (col, row) is centred at (32 col + 16, 16 row + 8) with col + row even, so
/// edge-neighbours are (±1, ±1) and vertex-neighbours (±2, 0) / (0, ±2).
///
/// A preset (battlefield_preset_map.<set>.<single|upper|lower>.h4d, the ship decks) carries a
/// 75x64 byte map of 16-pixel squares (1 open, 255 blocked, 0 off the field, 2 raised) and a
/// layers-style "backdrop" image; a land field is generated from the terrain: its tiles
/// tiled diamond by diamond, alternate diamonds a shade darker, obstacles of the terrain's
/// kind scattered outside the deployment corners.
public struct Battlefield {
    public static let columns = 37, rows = 64
    public static let backdropWidth = 1180, backdropHeight = 1024
    public static let cellWidth = 64, cellHeight = 32

    public let backdrop: UILayer?
    public let terrain: UInt8, variant: UInt8
    public struct Obstacle { public let name: String; public let col: Int, row: Int; public let w: Int, h: Int }
    public private(set) var obstacles: [Obstacle] = []
    var blocked: Set<Int> = []           // lattice cells an obstacle or the deck edge covers
    var squares: [UInt8]? = nil          // a preset's 75x64 byte map

    public static func valid(_ col: Int, _ row: Int) -> Bool {
        col >= 0 && col < columns && row >= 0 && row < rows && (col + row) % 2 == 0
    }
    public static func centre(_ col: Int, _ row: Int) -> (Float, Float) { (Float(32 * col + 16), Float(16 * row + 8)) }
    public static func key(_ col: Int, _ row: Int) -> Int { row * columns + col }

    /// The lattice cell whose diamond contains a backdrop point.
    public static func cell(at x: Float, _ y: Float) -> (Int, Int) {
        let c0 = Int((x - 16) / 32), r0 = Int((y - 8) / 16)
        var best = (0, 0), bestD = Float.infinity
        for c in (c0 - 1)...(c0 + 1) { for r in (r0 - 1)...(r0 + 1) where (c + r) % 2 == 0 {
            let (cx, cy) = centre(c, r)
            let d = abs(x - cx) / 32 + abs(y - cy) / 16   // diamond metric
            if d < bestD { bestD = d; best = (c, r) }
        } }
        return best
    }

    public init(data d: Data) throws {
        guard d.count > 4864 else { throw H4Error.corrupt("battlefield: too short") }
        let sq = Array(d[(d.startIndex + 64)..<(d.startIndex + 64 + 75 * 64)])
        squares = sq
        var img = Data([1, 0])
        img.append(d[(d.startIndex + 4864)...])
        backdrop = (try? LayerFile(data: img))?.layers.first
        terrain = 0; variant = 0
        var b = Set<Int>()
        for row in 0..<Battlefield.rows { for col in 0..<Battlefield.columns where (col + row) % 2 == 0 {
            // the diamond's centre square and the two beside it must be open deck
            let sx = 2 * col + 1, sy = row
            for dx in -1...1 {
                let x = sx + dx
                if x < 0 || x >= 75 || sy >= 64 { b.insert(Battlefield.key(col, row)); continue }
                let v = sq[sy * 75 + x]
                if v != 1 && v != 2 { b.insert(Battlefield.key(col, row)) }
            }
        } }
        blocked = b
    }

    /// A land battlefield for a terrain type: obstacles of the given candidates (sprite entry,
    /// footprint in 16 px squares) scattered over the middle of the field.
    public init(terrain: UInt8, variant: UInt8, obstacles candidates: [(name: String, w: Int, h: Int)], seed: Int) {
        backdrop = nil
        self.terrain = terrain; self.variant = variant
        var rng = GameRandom(seed: seed)
        var b = Set<Int>()
        var list: [Obstacle] = []
        if !candidates.isEmpty {
            let count = 20 + rng.next() % 10
            var tries = 0
            while list.count < count, tries < 300 {
                tries += 1
                let cand = candidates[rng.next() % candidates.count]
                let col = 4 + rng.next() % (Battlefield.columns - 8), row = 4 + rng.next() % (Battlefield.rows - 8)
                guard Battlefield.valid(col, row) else { continue }
                // keep the deployment corners free: bottom-left and top-right
                if col < 12 && row > Battlefield.rows - 22 { continue }
                if col > Battlefield.columns - 13 && row < 22 { continue }
                let radius = max(0, (max(cand.w, cand.h) - 1) / 2)
                var cells: [Int] = []
                var free = true
                for dc in -radius...radius { for dr in -radius...radius where (dc + dr) % 2 == 0 {
                    let c = col + dc, r = row + dr
                    if !Battlefield.valid(c, r) { free = false; continue }
                    cells.append(Battlefield.key(c, r))
                    // a one-cell gap between obstacles
                    for (nc, nr) in [(c + 1, r + 1), (c - 1, r - 1), (c + 1, r - 1), (c - 1, r + 1)] where b.contains(Battlefield.key(nc, nr)) { free = false }
                } }
                guard free, !cells.contains(where: { b.contains($0) }) else { continue }
                for c in cells { b.insert(c) }
                list.append(Obstacle(name: cand.name, col: col, row: row, w: cand.w, h: cand.h))
            }
        }
        blocked = b
        obstacles = list
    }

    public func isOpen(_ col: Int, _ row: Int) -> Bool {
        Battlefield.valid(col, row) && !blocked.contains(Battlefield.key(col, row))
    }
}
