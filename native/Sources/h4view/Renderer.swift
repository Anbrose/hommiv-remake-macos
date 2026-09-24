import Foundation
import Metal
import MetalKit
import H4Engine

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct V { float2 pos; float2 uv; };
struct Out { float4 pos [[position]]; float2 uv; };
struct Camera { float2 view; float2 pan; float zoom; float pad; };
vertex Out vmain(const device V* v [[buffer(0)]], constant Camera& cam [[buffer(1)]], uint id [[vertex_id]]) {
    Out o;
    float2 p = (v[id].pos - cam.pan) * cam.zoom;
    o.pos = float4(p.x / cam.view.x * 2.0 - 1.0, 1.0 - p.y / cam.view.y * 2.0, 0.0, 1.0);
    o.uv = v[id].uv;
    return o;
}
fragment float4 fmain(Out i [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, mip_filter::linear);
    float4 c = tex.sample(s, i.uv);
    return float4(c.rgb * c.a, c.a);
}
"""

struct Vertex { var x: Float, y: Float, u: Float, v: Float }
struct Camera { var vw: Float, vh: Float, px: Float, py: Float, zoom: Float, pad: Float }

/// One textured quad on the map canvas.
struct Quad {
    var texture: MTLTexture
    var x: Int, y: Int, w: Int, h: Int
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let scene: MapScene
    var terrain: [Quad] = []
    var textures: [String: MTLTexture] = [:]
    var pan = SIMD2<Float>(0, 0)
    var zoom: Float = 1
    var viewSize = SIMD2<Float>(1, 1)
    var vertexBuffer: MTLBuffer
    let start = Date()
    var lastFrame = Date()
    var frameTimes: [Double] = []
    var game: GameState?
    var resolver: RandomResolver?
    var actorSprites: [String: Sprite] = [:]
    lazy var dot: MTLTexture = {   // path marker
        var bm = Bitmap(width: 8, height: 8)
        for y in 0..<8 { for x in 0..<8 where (x - 4) * (x - 4) + (y - 4) * (y - 4) <= 9 {
            let p = (y * 8 + x) * 4; bm.pixels[p] = 255; bm.pixels[p + 1] = 240; bm.pixels[p + 2] = 160; bm.pixels[p + 3] = 220 } }
        return makeTexture(bm)
    }()
    var onTitle: ((String) -> Void)?
    var showBlocked = false   // debug: mark every cell a hero cannot enter
    lazy var redDot: MTLTexture = {
        var bm = Bitmap(width: 6, height: 6)
        for i in 0..<36 { bm.pixels[i * 4] = 255; bm.pixels[i * 4 + 3] = 200 }
        return makeTexture(bm)
    }()

    init(device: MTLDevice, scene: MapScene, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.scene = scene
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        vertexBuffer = device.makeBuffer(length: 1 << 20, options: .storageModeShared)!
        super.init()
        for c in scene.chunks {
            terrain.append(Quad(texture: makeTexture(c.bitmap), x: c.x, y: c.y, w: c.bitmap.width, h: c.bitmap.height))
        }
        for p in scene.placed {   // upload every frame of every object up front
            for img in p.sprite.images { _ = texture(for: img, of: p.name) }
        }
        pan = SIMD2(Float(scene.width) / 2 - 640, Float(scene.height) / 2 - 400)
    }

    func texture(for img: SpriteImage, of name: String) -> MTLTexture {
        let key = name + "|" + img.name
        if let t = textures[key] { return t }
        let t = makeTexture(img.bitmap)
        textures[key] = t
        return t
    }

    func makeTexture(_ bm: Bitmap) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: bm.width, height: bm.height, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        bm.pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, bm.width, bm.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bm.width * 4) }
        return t
    }

    var timelines: [String: [(frame: SpriteImage, shadow: SpriteImage?)]] = [:]

    /// The object's current frame (and shadow) at time t.
    func frame(of p: MapScene.Placed, at t: Double) -> (SpriteImage, SpriteImage?) {
        if timelines[p.name] == nil { timelines[p.name] = p.sprite.timeline }
        let tl = timelines[p.name]!
        guard !tl.isEmpty else { return (p.image, p.shadow) }
        let speed = tl[0].frame.speed
        let period = speed > 0 ? Double(speed) / 60.0 : 0.125
        let e = tl[Int(t / period) % tl.count]
        return (e.frame, e.shadow ?? p.shadow)
    }

    /// The game's own path arrows: adv_object.internal.<green|red>_arrow.<straight|left|right>.<dir> / .dest
    func arrowSprite(_ name: String) -> Sprite? {
        if let s = actorSprites[name] { return s }
        guard let r = resolver, let e = r.entry("adv_object.internal.\(name).h4d"), let s = try? Sprite(data: r.archive.payload(e)) else { return nil }
        actorSprites[name] = s
        return s
    }

    /// Screen centre of a (fractional) cell.
    func screen(_ x: Float, _ y: Float) -> (Float, Float) {
        ((y - x) * 32 + Float(scene.map.size * 32 + 32), (x + y) * 16 + 32)
    }

    /// The quads of one hero at time t: its current sequence frame (and shadow) at its map position.
    func heroQuads(_ h: Hero, at t: Double) -> [Quad] {
        guard let r = resolver else { print("hero: no resolver"); return [] }
        let state = h.isWalking ? "walk" : "wait"
        guard let entry = r.sequence(actor: h.actor, state: state, facing: h.facing) else { print("hero: no sequence for \(h.actor) \(state) \(h.facing)"); return [] }
        if actorSprites[entry] == nil {
            do { actorSprites[entry] = try Sprite(data: r.archive.payload(entry)) } catch { print("hero: \(entry): \(error)") }
        }
        guard let s = actorSprites[entry] else { return [] }
        let tl = s.timeline
        var frame = s.frames.first, shadow = frame.flatMap { s.shadow(for: $0) }
        if !tl.isEmpty {
            // walking: one full cycle per cell so the gait matches the ground; otherwise by the file's speed
            let index: Int
            if h.isWalking { index = Int(h.distance * Float(tl.count)) % tl.count }
            else { index = Int(t / (tl[0].frame.speed > 0 ? Double(tl[0].frame.speed) / 60.0 : 0.125)) % tl.count }
            let e = tl[index]
            frame = e.frame; shadow = e.shadow
        }
        let (px, py) = h.position
        let (sx, sy0) = screen(px, py)
        let sy = sy0 - (game.map { h.elevation(in: $0.passability) } ?? 0)   // raised on bridges
        let ox = Int(sx) + Int(s.origin.x), oy = Int(sy) - 16 + Int(s.origin.y)   // origin is from the cell's top vertex
        var out: [Quad] = []
        if let sh = shadow { out.append(Quad(texture: texture(for: sh, of: entry), x: ox + sh.box.left, y: oy + sh.box.top, w: sh.bitmap.width, h: sh.bitmap.height)) }
        if let f = frame { out.append(Quad(texture: texture(for: f, of: entry), x: ox + f.box.left, y: oy + f.box.top, w: f.bitmap.width, h: f.bitmap.height)) }
        if ProcessInfo.processInfo.environment["H4DEBUG"] != nil {
            print("hero: \(entry) at cell (\(px),\(py)) screen (\(sx),\(sy)) origin \(s.origin) frame \(frame?.name ?? "-") box \(frame.map { "\($0.box)" } ?? "-") -> \(out.map { "(\($0.x),\($0.y) \($0.w)x\($0.h))" })")
        }
        return out
    }

    func quads(at t: Double) -> [Quad] {
        var out = terrain
        let minX = pan.x - 512, minY = pan.y - 512, maxX = pan.x + viewSize.x / zoom + 512, maxY = pan.y + viewSize.y / zoom + 512
        // heroes are sorted in among the objects by the same depth rule (cell row, then column)
        var pending: [(depth: Float, quads: [Quad])] = []
        if let g = game {
            for h in g.heroes {
                for a in g.arrows(for: h) {
                    // arrows sort with the objects (a tree in front hides them) and ride up onto bridges
                    guard let s = arrowSprite(a.name), let f = s.frames.first else { continue }
                    let raise = g.passability.elevation(a.x, a.y)
                    let (sx, sy) = screen(Float(a.x), Float(a.y))
                    let ox = Int(sx) + Int(s.origin.x), oy = Int(sy - raise) - 16 + Int(s.origin.y)
                    var q: [Quad] = []
                    if let sh = s.shadow(for: f) { q.append(Quad(texture: texture(for: sh, of: a.name), x: ox + sh.box.left, y: oy + sh.box.top, w: sh.bitmap.width, h: sh.bitmap.height)) }
                    q.append(Quad(texture: texture(for: f, of: a.name), x: ox + f.box.left, y: oy + f.box.top, w: f.bitmap.width, h: f.bitmap.height))
                    pending.append((Float((a.x + a.y) * 1000 + (a.y - a.x) + 499) + (raise > 0 ? 2500 : 0), q))
                }
                let (px, py) = h.position
                // on a bridge the hero is drawn after the bridge pieces around it
                let raised: Float = h.elevation(in: g.passability) > 0 ? 2500 : 0
                pending.append(((px + py) * 1000 + (py - px) + 500 + raised, heroQuads(h, at: t)))
            }
            pending.sort { $0.depth < $1.depth }
        }
        for p in scene.placed {
            while let first = pending.first, first.depth <= Float(p.depth) { out += first.quads; pending.removeFirst() }
            if Float(p.anchorX) < minX || Float(p.anchorX) > maxX || Float(p.anchorY) < minY || Float(p.anchorY) > maxY { continue }
            let (f, sh) = frame(of: p, at: t)
            let ox = p.anchorX + Int(p.sprite.origin.x), oy = p.anchorY + Int(p.sprite.origin.y)
            if let base = p.sprite.baseFrame, f.name != base.name {   // animated towns: frames are deltas over base_frame
                if let s = sh { out.append(Quad(texture: texture(for: s, of: p.name), x: ox + s.box.left, y: oy + s.box.top, w: s.bitmap.width, h: s.bitmap.height)) }
                out.append(Quad(texture: texture(for: base, of: p.name), x: ox + base.box.left, y: oy + base.box.top, w: base.bitmap.width, h: base.bitmap.height))
                out.append(Quad(texture: texture(for: f, of: p.name), x: ox + f.box.left, y: oy + f.box.top, w: f.bitmap.width, h: f.bitmap.height))
            } else {
                if let s = sh { out.append(Quad(texture: texture(for: s, of: p.name), x: ox + s.box.left, y: oy + s.box.top, w: s.bitmap.width, h: s.bitmap.height)) }
                out.append(Quad(texture: texture(for: f, of: p.name), x: ox + f.box.left, y: oy + f.box.top, w: f.bitmap.width, h: f.bitmap.height))
            }
        }
        for p in pending { out += p.quads }
        if let g = game, showBlocked {   // on top of everything so buildings do not hide their own cells
            let n = g.map.size
            for x in 0..<n { for y in 0..<n where g.map.cells[g.level][x * n + y] != nil && !g.passability.isFree(x, y) {
                let (sx, sy) = screen(Float(x), Float(y))
                if sx >= minX, sx <= maxX, sy >= minY, sy <= maxY { out.append(Quad(texture: redDot, x: Int(sx) - 3, y: Int(sy) - 3, w: 6, h: 6)) }
            } }
        }
        return out
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = SIMD2(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastFrame)
        frameTimes.append(dt)
        lastFrame = now
        if let g = game {
            g.update(dt: Float(min(dt, 0.1)))
            for line in g.log { print(line) }
            g.log.removeAll()
            if let h = g.heroes.first {
                onTitle?("\(g.dateText) — movement \(Int(h.movement.rounded()))/\(Int(h.maxMovement))  (click: plan / go, Return: end turn)")
            }
        }
        if frameTimes.count >= 300 {
            let avg = frameTimes.reduce(0, +) / Double(frameTimes.count)
            print(String(format: "%.1f fps (avg frame %.2f ms)", 1 / avg, avg * 1000))
            frameTimes.removeAll()
        }
        encode(rpd: rpd, present: drawable, time: now.timeIntervalSince(start))
    }

    func encode(rpd: MTLRenderPassDescriptor, present: MTLDrawable?, time: Double) {
        let list = quads(at: time)
        var verts: [Vertex] = []
        verts.reserveCapacity(list.count * 6)
        for q in list {
            let x0 = Float(q.x), y0 = Float(q.y), x1 = Float(q.x + q.w), y1 = Float(q.y + q.h)
            verts += [Vertex(x: x0, y: y0, u: 0, v: 0), Vertex(x: x1, y: y0, u: 1, v: 0), Vertex(x: x0, y: y1, u: 0, v: 1),
                      Vertex(x: x1, y: y0, u: 1, v: 0), Vertex(x: x1, y: y1, u: 1, v: 1), Vertex(x: x0, y: y1, u: 0, v: 1)]
        }
        let bytes = verts.count * MemoryLayout<Vertex>.stride
        if vertexBuffer.length < bytes { vertexBuffer = device.makeBuffer(length: bytes * 2, options: .storageModeShared)! }
        verts.withUnsafeBytes { vertexBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }

        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(pipeline)
        var cam = Camera(vw: viewSize.x, vh: viewSize.y, px: pan.x, py: pan.y, zoom: zoom, pad: 0)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&cam, length: MemoryLayout<Camera>.stride, index: 1)
        let minX = pan.x, minY = pan.y, maxX = pan.x + viewSize.x / zoom, maxY = pan.y + viewSize.y / zoom
        for (i, q) in list.enumerated() {
            if Float(q.x + q.w) < minX || Float(q.x) > maxX || Float(q.y + q.h) < minY || Float(q.y) > maxY { continue }
            enc.setFragmentTexture(q.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
        }
        enc.endEncoding()
        if let p = present { cmd.present(p) }
        cmd.commit()
        if present == nil { cmd.waitUntilCompleted() }
    }
}
