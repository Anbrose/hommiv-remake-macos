import Foundation
import Metal
import H4Engine

/// The shroud drawn over the map (fog_spec §6): layers.shroud's starfield tiled across the map,
/// fully over unexplored cells and at 9/16 over explored ones not seen now, blended smoothly
/// between cell centres; one overlay per terrain chunk, rebuilt where the vision changed.
final class ShroudCache {
    var star: Bitmap?
    /// Per level: chunk index -> overlay (nil when that chunk is clear).
    var overlays: [[Int: Quad?]] = []
    var last: [[UInt8]] = []
}

extension Renderer {
    static let fogAlpha: [UInt8: Int] = [0: 16, 1: 9, 2: 0]

    func shroudStar() -> Bitmap? {
        if let s = shroud.star { return s }
        guard let r = resolver, let d = try? r.archive.payload("layers.shroud.h4d"), let l = try? LayerFile(data: d), let img = l.layers.first(where: { $0.isImage }) else { return nil }
        shroud.star = img.bitmap
        return img.bitmap
    }

    /// Recompute the vision when what decides it has changed, and mark the chunks to redraw.
    func refreshShroud() {
        guard let g = game, g.fogEnabled else { return }
        let sig = g.visionSignature
        if sig != visionSignature || g.fog.isEmpty { g.updateVision(); visionSignature = sig }
        guard g.visionChanged || shroud.overlays.count != scenes.count else { return }
        g.visionChanged = false
        if shroud.overlays.count != scenes.count {
            shroud.overlays = Array(repeating: [:], count: scenes.count)
            shroud.last = []
        }
        let n = g.map.size
        for l in scenes.indices where l < g.fog.count {
            let now = g.fog[l]
            if shroud.last.count <= l { shroud.last.append([]) }
            let before = shroud.last[l]
            if before.count != now.count { shroud.overlays[l] = [:] }   // everything anew
            else {
                // the chunks near a changed cell
                var dirty = Set<Int>()
                let chunks = scenes[l].chunks
                for k in now.indices where now[k] != before[k] {
                    let x = k / n, y = k % n
                    let (sx, sy) = screen(Float(x), Float(y))
                    for (ci, c) in chunks.enumerated() where Float(c.x) - 64 <= sx && sx <= Float(c.x + c.bitmap.width) + 64 && Float(c.y) - 32 <= sy && sy <= Float(c.y + c.bitmap.height) + 32 {
                        dirty.insert(ci)
                    }
                }
                for ci in dirty { shroud.overlays[l][ci] = nil }
            }
            shroud.last[l] = now
        }
        minimapStamp = -1
    }

    /// The overlays of the level in play (built on demand).
    func shroudQuads() -> [Quad] {
        guard let g = game, g.fogEnabled, g.level < g.fog.count, g.level < shroud.overlays.count, let star = shroudStar() else { return [] }
        let l = g.level, n = g.map.size, fog = g.fog[l]
        var out: [Quad] = []
        let minX = pan.x - 64, minY = pan.y - 64, maxX = pan.x + viewSize.x / zoom + 64, maxY = pan.y + viewSize.y / zoom + 64
        for (ci, c) in scenes[l].chunks.enumerated() {
            if Float(c.x + c.bitmap.width) < minX || Float(c.x) > maxX || Float(c.y + c.bitmap.height) < minY || Float(c.y) > maxY { continue }
            if let q = shroud.overlays[l][ci] { if let q = q { out.append(q) }; continue }
            let bm = shroudBitmap(x: c.x, y: c.y, w: c.bitmap.width, h: c.bitmap.height, fog: fog, n: n, star: star)
            let q = bm.map { Quad(texture: makeTexture($0), x: c.x, y: c.y, w: c.bitmap.width, h: c.bitmap.height) }
            shroud.overlays[l][ci] = q
            if let q = q { out.append(q) }
        }
        return out
    }

    /// A chunk's overlay: the starfield at each pixel with the cell alpha interpolated between cell
    /// centres (premultiplied); nil when nothing of the chunk is covered.
    func shroudBitmap(x x0: Int, y y0: Int, w: Int, h: Int, fog: [UInt8], n: Int, star: Bitmap) -> Bitmap? {
        func alpha(_ x: Int, _ y: Int) -> Int {
            guard x >= 0, y >= 0, x < n, y < n else { return 16 }
            return Renderer.fogAlpha[fog[x * n + y]] ?? 16
        }
        // the cells the chunk spans: all clear means no overlay
        let corners = [(x0, y0), (x0 + w, y0), (x0, y0 + h), (x0 + w, y0 + h)].map { p -> (Float, Float) in
            let u = (Float(p.0) - Float(n * 32 + 32)) / 32, v = (Float(p.1) - 32) / 16
            return ((v - u) / 2, (v + u) / 2)
        }
        let cx0 = Int(corners.map(\.0).min()!.rounded(.down)) - 1, cx1 = Int(corners.map(\.0).max()!.rounded(.up)) + 1
        let cy0 = Int(corners.map(\.1).min()!.rounded(.down)) - 1, cy1 = Int(corners.map(\.1).max()!.rounded(.up)) + 1
        var any = false
        outer: for x in cx0...cx1 { for y in cy0...cy1 {
            // (cells off the map inside the chunk's box count only where the chunk shows them)
            if x >= 0, y >= 0, x < n, y < n, alpha(x, y) > 0 { any = true; break outer }
        } }
        if !any { return nil }
        var bm = Bitmap(width: w, height: h)
        let sw = star.width, sh = star.height
        star.pixels.withUnsafeBufferPointer { sp in
            bm.pixels.withUnsafeMutableBufferPointer { dp in
                for py in 0..<h {
                    let v = (Float(y0 + py) - 32) / 16
                    let srow = ((y0 + py) % sh) * sw
                    for px in 0..<w {
                        let u = (Float(x0 + px) - Float(n * 32 + 32)) / 32
                        let fx = (v - u) / 2, fy = (v + u) / 2
                        let ix = Int(fx.rounded(.down)), iy = Int(fy.rounded(.down))
                        let tx = fx - Float(ix), ty = fy - Float(iy)
                        let a00 = Float(alpha(ix, iy)), a10 = Float(alpha(ix + 1, iy)), a01 = Float(alpha(ix, iy + 1)), a11 = Float(alpha(ix + 1, iy + 1))
                        let a = (a00 * (1 - tx) + a10 * tx) * (1 - ty) + (a01 * (1 - tx) + a11 * tx) * ty
                        if a <= 0.01 { continue }
                        let f = min(1, a / 16)
                        let s = (srow + (x0 + px) % sw) * 4, o = (py * w + px) * 4
                        dp[o] = UInt8(Float(sp[s]) * f); dp[o + 1] = UInt8(Float(sp[s + 1]) * f); dp[o + 2] = UInt8(Float(sp[s + 2]) * f)
                        dp[o + 3] = UInt8(255 * f)
                    }
                }
            }
        }
        return bm
    }
}
