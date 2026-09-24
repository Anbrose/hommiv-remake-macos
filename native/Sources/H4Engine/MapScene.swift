import Foundation

/// Everything a renderer needs to draw one level of a map: terrain composited into
/// square chunk bitmaps, and the objects as sprite images with screen positions.
/// Projection (see tools/h4render.py): cell (x, y) is a 64x32 diamond centred at
/// ((y - x) * 32 + size * 32 + 32, (x + y) * 16 + 32).
public final class MapScene {
    public struct Chunk {
        public let x: Int, y: Int      // pixel origin on the map canvas
        public let bitmap: Bitmap
    }
    public struct Placed {
        public let name: String        // archive entry of the sprite file (random placeholders already resolved)
        public let sprite: Sprite
        public let image: SpriteImage  // base frame (or first frame)
        public let shadow: SpriteImage?
        public let x: Int, y: Int      // screen position of the image's top-left
        public let anchorX: Int, anchorY: Int   // screen position of the anchor cell centre
        public let cellX: Int, cellY: Int       // anchor cell (top corner of the footprint)
        public let category: String             // first component of the adv_object name
        public let depth: Int
        public let type: String, subtype: String   // the map record's kind ("mine"/"gold_mine", "random_monster"/"level_2")
    }

    public static let chunkSize = 512
    public let map: MapFile
    public let level: Int
    public let width: Int, height: Int
    public private(set) var chunks: [Chunk] = []
    public private(set) var placed: [Placed] = []
    public private(set) var spriteCache: [String: Sprite] = [:]

    /// Terrain types with two variants (dry/lush grass, shallow/deep water, ...) have patches
    /// <name>.<variant+1>.<alt>, alt 1 or 2 being two different patches of the same look.
    static let terrainBase: [UInt8: String] = [0: "water", 1: "grass", 2: "rough", 3: "swamp", 4: "lava", 5: "snow",
                                              6: "sand", 7: "dirt", 8: "subterranean"]
    static let terrainSingle: [UInt8: String] = [9: "river.water", 10: "river.lava", 11: "river.ice", 12: "magic.all", 13: "magic.life",
                                                14: "magic.order", 15: "magic.death", 16: "magic.chaos", 17: "magic.nature", 18: "magic.all"]
    /// Road textures by road type (the strings table names them Road_1 "Road, Stone", Road_2
    /// "Road, Dirt", road_3 "Road, Cobble").
    static let roadFile: [UInt8: String] = [1: "road.gravel", 2: "road.dirt", 3: "road.cobblestone"]
    /// Debug: swap which soft mask set the shorelines use (H4SHORESWAP=1).
    static let shoreSwap = ProcessInfo.processInfo.environment["H4SHORESWAP"] != nil

    /// The road type on every cell of a level (0 = none). Shoulder pieces carry their type;
    /// body pieces are stored as type 0, so a body cell takes the type its neighbouring
    /// shoulders (then neighbouring bodies) have.
    public static func roadTypes(map: MapFile, level: Int) -> [UInt8] {
        let n = map.size
        let cells = map.cells[level]
        var types = [UInt8](repeating: 0, count: n * n)
        var body = [Bool](repeating: false, count: n * n)
        for i in 0..<(n * n) {
            guard let c = cells[i] else { continue }
            for rd in c.roads {
                if rd.kind >= 1, rd.kind <= 3 { types[i] = max(types[i], rd.kind) }
                if rd.kind == 0 { body[i] = true }
            }
        }
        var pending = (0..<(n * n)).filter { body[$0] && types[$0] == 0 }
        var changed = true
        while changed, !pending.isEmpty {
            changed = false
            var next: [Int] = []
            for i in pending {
                let x = i / n, y = i % n
                var votes = [UInt8: Int]()
                for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < n, ny >= 0, ny < n else { continue }
                    let t = types[nx * n + ny]
                    if t > 0 { votes[t, default: 0] += 1 }
                } }
                if let best = votes.max(by: { $0.value < $1.value })?.key { types[i] = best; changed = true } else { next.append(i) }
            }
            pending = next
        }
        for i in pending { types[i] = 2 }   // an isolated body: dirt
        return types
    }

    /// Patch file name for a terrain type/variant at cell (x, y); nil for unknown types.
    static func terrainFile(type: UInt8, variant: UInt8, x: Int, y: Int) -> String? {
        let alt = ((x / 10) + (y / 10)) % 2 + 1
        if let b = terrainBase[type] { return "\(b).\(min(Int(variant), 1) + 1).\(alt)" }
        if let s = terrainSingle[type] { return s.hasPrefix("river") || s == "magic.death" || s == "magic.chaos" || s == "magic.nature" ? "\(s).\(alt)" : s }
        return nil
    }

    public init(map: MapFile, level: Int, archive: H4Archive, masks: TransitionMasks) throws {
        self.map = map
        self.level = level
        let n = map.size
        width = 2 * n * 32 + 64
        height = n * 32 + 96
        try buildTerrain(archive: archive, masks: masks)
        try placeObjects(archive: archive)
    }

    /// Cell (x, y) -> screen centre. x runs down-left, y runs down-right (checked against the
    /// game on "Beyond the lake": the two towns mirror each other across the river).
    public func screen(x: Int, y: Int) -> (Int, Int) {
        ((y - x) * 32 + map.size * 32 + 32, (x + y) * 16 + 32)
    }

    private func buildTerrain(archive: H4Archive, masks: TransitionMasks) throws {
        let n = map.size, cs = MapScene.chunkSize
        var canvas = Bitmap(width: width, height: height)
        var patches: [String: TerrainPatch] = [:]
        func patch(_ name: String) throws -> TerrainPatch {
            if let p = patches[name] { return p }
            let p = try TerrainPatch(data: archive.payload("terrain.\(name).h4d"))
            patches[name] = p
            return p
        }
        let land = masks.sets["land 1"] ?? []
        let road = masks.sets["road 1"] ?? []
        let cells = map.cells[level]
        let roadTypes = MapScene.roadTypes(map: map, level: level)
        for x in 0..<n {
            for y in 0..<n {
                guard let cell = cells[x * n + y] else { continue }
                let row = x + y, col = (y - x - (x + y) % 2) / 2
                let ti = (MapScene.mod(row, 6) + 2) * 10 + (MapScene.mod(col, 6) + 2)
                let (sx, sy) = screen(x: x, y: y)
                let left = sx - 32, top = sy - 16
                let base = try patch(MapScene.terrainFile(type: cell.type, variant: cell.variant, x: x, y: y) ?? "grass.2.1")
                MapScene.blit(&canvas, base.tiles[ti], left, top, mask: nil)
                // overlays and road pieces interleave by their order byte (roads sit at 10..14,
                // overlays at 0..9 and 15..19, so terrain drawn after a road nibbles its edges)
                enum Item { case overlay(Overlay), road(Road) }
                var items: [(order: UInt8, item: Item)] = cell.overlays.map { ($0.order, .overlay($0)) }
                items += cell.roads.map { ($0.order, .road($0)) }
                for (_, item) in items.sorted(by: { $0.order < $1.order }) {
                    switch item {
                    case .overlay(let ov):
                        guard ov.mask < land.count, let f = MapScene.terrainFile(type: ov.type, variant: ov.variant, x: x, y: y) else { continue }
                        // land on water / water on land take the soft shoreline sets; the three
                        // variants of each set alternate by position
                        let baseWater = cell.type == 0 || cell.type == 9, overWater = ov.type == 0 || ov.type == 9
                        let variant = MapScene.mod(x * 3 + y * 5, 3) + 1
                        let setName = baseWater == overWater ? (overWater ? "water \(min(variant, 2))" : "land \(variant)")
                            : (overWater ? (MapScene.shoreSwap ? "land_to_water \(variant)" : "water_to_land \(variant)")
                                         : (MapScene.shoreSwap ? "water_to_land \(variant)" : "land_to_water \(variant)"))
                        let set = masks.sets[setName] ?? land
                        MapScene.blit(&canvas, try patch(f).tiles[ti], left, top, mask: set[min(ov.mask, set.count - 1)])
                    case .road(let rd):
                        guard rd.mask < road.count else { continue }
                        let type = rd.kind == 0 ? roadTypes[x * n + y] : rd.kind
                        guard let f = MapScene.roadFile[type] else { continue }
                        // the body is the cell minus the mask (terrain shows in the mask), a shoulder is the mask itself
                        MapScene.blit(&canvas, try patch("\(f).\(((x / 10) + (y / 10)) % 2 + 1)").tiles[ti], left, top, mask: road[rd.mask], invert: rd.kind == 0)
                    }
                }
            }
        }
        var list: [Chunk] = []
        var cy = 0
        while cy < height {
            var cx = 0
            while cx < width {
                let w = min(cs, width - cx), h = min(cs, height - cy)
                var b = Bitmap(width: w, height: h)
                for yy in 0..<h {
                    let src = ((cy + yy) * width + cx) * 4, dst = yy * w * 4
                    b.pixels.replaceSubrange(dst..<(dst + w * 4), with: canvas.pixels[src..<(src + w * 4)])
                }
                list.append(Chunk(x: cx, y: cy, bitmap: b))
                cx += cs
            }
            cy += cs
        }
        chunks = list
    }

    private func placeObjects(archive: H4Archive) throws {
        let n = map.size
        var out: [Placed] = []
        let objs = map.objects.filter { $0.level == level && $0.x >= -2 && $0.x < n + 2 && $0.y >= -2 && $0.y < n + 2 }
        let resolver = RandomResolver(archive: archive)
        let debug = ProcessInfo.processInfo.environment["H4DEBUG"] != nil
        // random towns get factions in order: the first player's town first (Haven), then left to right on screen
        let townOrder = objs.filter { $0.type == "random_town" }.sorted { (($0.owner ?? 99), $0.y - $0.x, $0.x + $0.y) < (($1.owner ?? 99), $1.y - $1.x, $1.x + $1.y) }
        for o in objs {
            var key = "adv_object.\(o.name).h4d"
            let ordinal = townOrder.firstIndex { $0.x == o.x && $0.y == o.y && $0.level == o.level } ?? 0
            let candidates = resolver.resolve(o, townOrdinal: ordinal)
            // the first candidate that decodes to a real (non-placeholder) sprite wins
            for c in candidates {
                if spriteCache[c] == nil, let d = try? archive.payload(c), let s = try? Sprite(data: d) { spriteCache[c] = s }
                if let s = spriteCache[c], !s.isPlaceholder { key = c; break }
            }
            if debug, o.type.hasPrefix("random") { print("resolve \(o.name) [\(o.type)/\(o.subtype)] -> \(candidates) => \(key)") }
            if spriteCache[key] == nil {
                guard let d = try? archive.payload(key), let s = try? Sprite(data: d) else { continue }
                spriteCache[key] = s
            }
            guard let s = spriteCache[key], !s.isPlaceholder, let img = s.baseFrame ?? s.frames.first else { continue }
            // The sprite origin is measured from the TOP VERTEX of the anchor cell (16 px above its
            // centre): a 6x6 town's base then lands on the footprint's bottom vertex, a creature's
            // feet on its cell's bottom vertex.
            let (sx, sy0) = screen(x: o.x, y: o.y)
            let sy = sy0 - 16
            // (x, y) is the top corner of the footprint; paint order follows the bottom corner
            let depth = (o.x + o.y + s.footprint.w + s.footprint.h - 2) * 1000 + (o.y - o.x) + 500
            if let pick = ProcessInfo.processInfo.environment["H4PICK"] {   // H4PICK=x,y (map cell): list sprites covering that cell's centre
                let c = pick.split(separator: ",").compactMap { Int($0) }
                if c.count == 2 {
                    let (px, py0) = screen(x: c[0], y: c[1])
                    let py = py0 - 16
                    let ix = sx + Int(s.origin.x) + img.box.left, iy = sy + Int(s.origin.y) + img.box.top
                    if px >= ix, px < ix + img.bitmap.width, py >= iy, py < iy + img.bitmap.height {
                        print("pick: \(o.name) at (\(o.x),\(o.y)) -> \(key) image \(img.name) \(img.bitmap.width)x\(img.bitmap.height) origin \(s.origin)")
                    }
                }
            }
            out.append(Placed(name: key, sprite: s, image: img, shadow: s.shadow(for: img),
                              x: sx + Int(s.origin.x) + img.box.left, y: sy + Int(s.origin.y) + img.box.top,
                              anchorX: sx, anchorY: sy, cellX: o.x, cellY: o.y,
                              category: String(o.name.split(separator: ".").first ?? ""), depth: depth,
                              type: o.type, subtype: o.subtype))
        }
        placed = out.sorted { $0.depth < $1.depth }
    }

    /// Take an object off the map (a pickup that was collected).
    public func remove(_ p: Placed) {
        placed.removeAll { $0.cellX == p.cellX && $0.cellY == p.cellY && $0.name == p.name && $0.depth == p.depth }
    }

    static func mod(_ a: Int, _ m: Int) -> Int { ((a % m) + m) % m }

    /// Copy a 64x32 tile onto the canvas at (left, top), optionally through a 64x32 1-bit mask.
    static func blit(_ canvas: inout Bitmap, _ tile: Bitmap, _ left: Int, _ top: Int, mask: [UInt8]?, invert: Bool = false) {
        for y in 0..<32 {
            let yy = top + y
            guard yy >= 0, yy < canvas.height else { continue }
            for x in 0..<64 {
                let xx = left + x
                guard xx >= 0, xx < canvas.width else { continue }
                let s = (y * 64 + x) * 4
                guard tile.pixels[s + 3] != 0 else { continue }
                var a = 15
                if let m = mask { a = Int(m[y * 64 + x]); if invert { a = 15 - a } }
                if a == 0 { continue }
                let d = (yy * canvas.width + xx) * 4
                if a >= 15 {
                    canvas.pixels[d] = tile.pixels[s]; canvas.pixels[d + 1] = tile.pixels[s + 1]; canvas.pixels[d + 2] = tile.pixels[s + 2]
                } else {   // the soft shoreline masks: blend by the 4-bit coverage
                    for k in 0..<3 { canvas.pixels[d + k] = UInt8((Int(tile.pixels[s + k]) * a + Int(canvas.pixels[d + k]) * (15 - a)) / 15) }
                }
                canvas.pixels[d + 3] = 255
            }
        }
    }
}
