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

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let scene: MapScene
    var chunkTextures: [(MTLTexture, Int, Int, Int, Int)] = []   // texture, x, y, w, h
    var spriteTextures: [String: MTLTexture] = [:]
    var draws: [(MTLTexture, Int, Int, Int, Int)] = []           // static draw list in map order
    var pan = SIMD2<Float>(0, 0)
    var zoom: Float = 1
    var viewSize = SIMD2<Float>(1, 1)
    var vertexBuffer: MTLBuffer

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
        vertexBuffer = device.makeBuffer(length: 6 * MemoryLayout<Vertex>.stride, options: .storageModeShared)!
        super.init()
        for c in scene.chunks {
            chunkTextures.append((makeTexture(c.bitmap), c.x, c.y, c.bitmap.width, c.bitmap.height))
        }
        for c in chunkTextures { draws.append(c) }
        for p in scene.placed {
            if let sh = p.shadow {
                let dx = p.x - p.image.box.left + sh.box.left, dy = p.y - p.image.box.top + sh.box.top
                draws.append((texture(for: sh, of: p.name), dx, dy, sh.bitmap.width, sh.bitmap.height))
            }
            draws.append((texture(for: p.image, of: p.name), p.x, p.y, p.image.bitmap.width, p.image.bitmap.height))
        }
        let needed = draws.count * 6 * MemoryLayout<Vertex>.stride
        vertexBuffer = device.makeBuffer(length: max(needed, 64), options: .storageModeShared)!
        var verts: [Vertex] = []
        verts.reserveCapacity(draws.count * 6)
        for (_, x, y, w, h) in draws {
            let x0 = Float(x), y0 = Float(y), x1 = Float(x + w), y1 = Float(y + h)
            verts += [Vertex(x: x0, y: y0, u: 0, v: 0), Vertex(x: x1, y: y0, u: 1, v: 0), Vertex(x: x0, y: y1, u: 0, v: 1),
                      Vertex(x: x1, y: y0, u: 1, v: 0), Vertex(x: x1, y: y1, u: 1, v: 1), Vertex(x: x0, y: y1, u: 0, v: 1)]
        }
        verts.withUnsafeBytes { vertexBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        pan = SIMD2(Float(scene.width) / 2 - 640, Float(scene.height) / 2 - 400)
    }

    func texture(for img: SpriteImage, of name: String) -> MTLTexture {
        let key = name + "|" + img.name
        if let t = spriteTextures[key] { return t }
        let t = makeTexture(img.bitmap)
        spriteTextures[key] = t
        return t
    }

    func makeTexture(_ bm: Bitmap) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: bm.width, height: bm.height, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        bm.pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, bm.width, bm.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bm.width * 4) }
        return t
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = SIMD2(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }
        encode(rpd: rpd, present: drawable)
    }

    func encode(rpd: MTLRenderPassDescriptor, present: MTLDrawable?) {
        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(pipeline)
        var cam = Camera(vw: viewSize.x, vh: viewSize.y, px: pan.x, py: pan.y, zoom: zoom, pad: 0)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&cam, length: MemoryLayout<Camera>.stride, index: 1)
        let minX = pan.x, minY = pan.y, maxX = pan.x + viewSize.x / zoom, maxY = pan.y + viewSize.y / zoom
        for (i, (tex, x, y, w, h)) in draws.enumerated() {
            if Float(x + w) < minX || Float(x) > maxX || Float(y + h) < minY || Float(y) > maxY { continue }
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
        }
        enc.endEncoding()
        if let p = present { cmd.present(p) }
        cmd.commit()
        if present == nil { cmd.waitUntilCompleted() }
    }
}
