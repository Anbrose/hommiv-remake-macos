import Foundation
import Metal
import H4Engine

/// The adventure screen chrome, laid out on the game's 1024x768 canvas: the frame and right
/// panel from layers.adventure.1024, the day scroll, the End Turn button, resource numbers and
/// the date in the game's fonts, and a minimap in the panel's minimap frame.
final class AdventureUI {
    static let width = 1024, height = 768
    /// The map is visible left of the panel; the borders overlap it with transparency.
    static let mapViewportWidth = 714

    let frame: LayerFile
    let dayScroll: LayerFile
    let endTurnButton: LayerFile
    let dateFont: H4Font
    let numberFont: H4Font
    let resourceNames = ["Wood", "Ore", "Mercury", "Sulfur", "Crystal", "Gems", "Gold"]

    let archive: H4Archive
    var portraitSheets: [String: LayerFile] = [:]

    /// A hero's 52x52 portrait, from layers.icons.hero.<alignment>.52 keyed by the hero's keyword.
    func portrait(keyword: String, alignment: String) -> UILayer? {
        if portraitSheets[alignment] == nil, let d = try? archive.payload("layers.icons.hero.\(alignment).52.h4d"), let f = try? LayerFile(data: d) {
            portraitSheets[alignment] = f
        }
        return portraitSheets[alignment]?[keyword.lowercased()]
    }

    /// Where the hero list's round slots are on the panel (centres, top to bottom).
    static let heroSlots = [(789, 393), (789, 465), (789, 537)]
    /// The seven rings of the army panel (the "IGNORE" image at 737,575), centres on the canvas.
    static let armySlots = [(769, 611), (833, 611), (897, 611), (961, 611), (801, 679), (865, 679), (929, 679)]

    var creatureIcons: LayerFile?
    /// A creature's 52x52 icon from layers.icons.creatures.52 (keyed by creature name, any case).
    func creatureIcon(_ keyword: String) -> UILayer? {
        if creatureIcons == nil, let d = try? archive.payload("layers.icons.creatures.52.h4d") { creatureIcons = try? LayerFile(data: d) }
        return creatureIcons?.layers.first { $0.name.lowercased() == keyword.lowercased() }
    }
    var armyRings: LayerFile?
    /// The ring drawn around a hero's portrait in the hero list (layers.control.army_rings).
    func heroRing() -> (frame: UILayer, portraitAt: (Int, Int))? {
        if armyRings == nil, let d = try? archive.payload("layers.control.army_rings.h4d") { armyRings = try? LayerFile(data: d) }
        guard let f = armyRings?["Army_Frame"], let p = armyRings?["portrait"] else { return nil }
        return (f, (p.x, p.y))
    }

    init(archive: H4Archive, index: RandomResolver) throws {
        self.archive = archive
        frame = try LayerFile(data: archive.payload("layers.adventure.1024.h4d"))
        dayScroll = try LayerFile(data: archive.payload("layers.adventure.day_scroll.h4d"))
        endTurnButton = try LayerFile(data: archive.payload("layers.button.end_turn.h4d"))
        dateFont = try H4Font(data: archive.payload("font.Prose_Antique.14.h4d"))
        numberFont = try H4Font(data: archive.payload("font.Prose_Antique.12.h4d"))
    }

    func hotspot(_ name: String) -> UILayer? { frame[name] }

    /// Other sizes of the game's font, loaded on demand.
    var fonts: [Int: H4Font] = [:]
    func font(_ size: Int) -> H4Font {
        if let f = fonts[size] { return f }
        let f = (try? H4Font(data: archive.payload("font.Prose_Antique.\(size).h4d"))) ?? dateFont
        fonts[size] = f
        return f
    }

    /// Three-state buttons (layers.button.*: Released/Highlighted/Pressed/Disabled), loaded on demand.
    var buttons: [String: LayerFile] = [:]
    func button(_ name: String, state: String = "Released") -> UILayer? {
        if buttons[name] == nil, let d = try? archive.payload("layers.button.\(name).h4d") { buttons[name] = try? LayerFile(data: d) }
        return buttons[name]?[state]
    }

    /// Dialog layouts (layers.dialog.*), loaded on demand.
    var dialogs: [String: LayerFile] = [:]
    func dialog(_ name: String) -> LayerFile? {
        if dialogs[name] == nil, let d = try? archive.payload("layers.dialog.\(name).h4d") { dialogs[name] = try? LayerFile(data: d) }
        return dialogs[name]
    }

    /// The right-click text box: layers.text_background.<small|large> is a nine-slice scroll
    /// (corners, tiled edges, a parchment tile for the middle) with a client_area hotspot.
    var popupFrames: [String: LayerFile] = [:]
    func popupFrame(_ size: String) -> LayerFile? {
        if popupFrames[size] == nil, let d = try? archive.payload("layers.text_background.\(size).h4d") { popupFrames[size] = try? LayerFile(data: d) }
        return popupFrames[size]
    }

    /// Break text into lines no wider than `width` pixels in the font (on spaces; a single
    /// overlong word stays on its own line).
    static func wrap(_ text: String, font: H4Font, width: Int) -> [String] {
        var out: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if font.measure(candidate) <= width || line.isEmpty { line = candidate }
                else { out.append(line); line = String(word) }
            }
            out.append(line)
        }
        return out
    }

    /// Alpha-blend `src` onto `dst` at (x, y), clipped.
    static func blend(_ src: Bitmap, onto dst: inout Bitmap, x: Int, y: Int) {
        for sy in 0..<src.height {
            let dy = y + sy
            guard dy >= 0, dy < dst.height else { continue }
            for sx in 0..<src.width {
                let dx = x + sx
                guard dx >= 0, dx < dst.width else { continue }
                let s = (sy * src.width + sx) * 4, d = (dy * dst.width + dx) * 4
                let a = Int(src.pixels[s + 3])
                if a == 0 { continue }
                if a == 255 { dst.pixels[d] = src.pixels[s]; dst.pixels[d + 1] = src.pixels[s + 1]; dst.pixels[d + 2] = src.pixels[s + 2]; dst.pixels[d + 3] = 255; continue }
                let da = Int(dst.pixels[d + 3])
                let oa = a + da * (255 - a) / 255
                for k in 0..<3 {
                    let sc = Int(src.pixels[s + k]), dc = Int(dst.pixels[d + k])
                    dst.pixels[d + k] = UInt8(oa == 0 ? 0 : (sc * a + dc * da * (255 - a) / 255) / oa)
                }
                dst.pixels[d + 3] = UInt8(oa)
            }
        }
    }

    /// A popup box with a client area of the given size, composed from the nine-slice frame.
    /// Returns the bitmap and where the client area sits in it.
    func popupBitmap(clientW: Int, clientH: Int) -> (bitmap: Bitmap, clientX: Int, clientY: Int)? {
        let size = clientH > 150 || clientW > 260 ? "large" : "small"
        guard let f = popupFrame(size), let client = f["client_area"],
              let tl = f.layers.first(where: { $0.name.lowercased() == "top_left" }), let tr = f.layers.first(where: { $0.name.lowercased() == "top_right" }),
              let bl = f.layers.first(where: { $0.name.lowercased() == "bottom_left" }), let br = f.layers.first(where: { $0.name.lowercased() == "bottom_right" }),
              let top = f.layers.first(where: { $0.name.lowercased() == "top" }), let bottom = f.layers.first(where: { $0.name.lowercased() == "bottom" }),
              let left = f.layers.first(where: { $0.name.lowercased() == "left" }), let right = f.layers.first(where: { $0.name.lowercased() == "right" }),
              let bg = f["Background"], let bgRect = f["background_rect"] else { return nil }
        // the reference layout: the frame's bounding box, the client inset inside it
        let x0 = min(tl.x, bl.x, left.x), y0 = min(tl.y, tr.y, top.y)
        let x1 = max(tr.x + tr.width, br.x + br.width, right.x + right.width), y1 = max(bl.y + bl.height, br.y + br.height, bottom.y + bottom.height)
        let insetL = client.x - x0, insetT = client.y - y0, insetR = x1 - (client.x + client.width), insetB = y1 - (client.y + client.height)
        let W = clientW + insetL + insetR, H = clientH + insetT + insetB
        var bm = Bitmap(width: W, height: H)
        // parchment: tile the background over the background_rect, offset as in the reference
        let bx0 = bgRect.x - x0, by0 = bgRect.y - y0, bx1 = W - (x1 - (bgRect.x + bgRect.width)), by1 = H - (y1 - (bgRect.y + bgRect.height))
        for y in by0..<by1 { for x in bx0..<bx1 where x >= 0 && y >= 0 && x < W && y < H {
            let s = ((y % bg.height) * bg.width + (x % bg.width)) * 4, d = (y * W + x) * 4
            for k in 0..<4 { bm.pixels[d + k] = bg.bitmap.pixels[s + k] }
        } }
        // edges, tiled between the corners
        var x = tl.x + tl.width - x0
        while x < W - (x1 - tr.x) { AdventureUI.blend(top.bitmap, onto: &bm, x: x, y: top.y - y0); x += top.width }
        x = bl.x + bl.width - x0
        while x < W - (x1 - br.x) { AdventureUI.blend(bottom.bitmap, onto: &bm, x: x, y: H - (y1 - bottom.y)); x += bottom.width }
        var y = tl.y + tl.height - y0
        while y < H - (y1 - bl.y) { AdventureUI.blend(left.bitmap, onto: &bm, x: left.x - x0, y: y); y += left.height }
        y = tr.y + tr.height - y0
        while y < H - (y1 - br.y) { AdventureUI.blend(right.bitmap, onto: &bm, x: W - (x1 - right.x), y: y); y += right.height }
        // corners last
        AdventureUI.blend(tl.bitmap, onto: &bm, x: tl.x - x0, y: tl.y - y0)
        AdventureUI.blend(tr.bitmap, onto: &bm, x: W - (x1 - tr.x), y: tr.y - y0)
        AdventureUI.blend(bl.bitmap, onto: &bm, x: bl.x - x0, y: H - (y1 - bl.y))
        AdventureUI.blend(br.bitmap, onto: &bm, x: W - (x1 - br.x), y: H - (y1 - br.y))
        return (bm, insetL, insetT)
    }

    /// Is a canvas point inside a named hotspot?
    func hit(_ name: String, x: Float, y: Float) -> Bool {
        guard let h = hotspot(name) else { return false }
        return x >= Float(h.x) && x < Float(h.x + h.width) && y >= Float(h.y) && y < Float(h.y + h.height)
    }

    /// Image layers of the frame in drawing order: opaque backgrounds, then the big translucent
    /// borders, then the small icons (the file order would bury the icons under the panel).
    var frameImages: [UILayer] {
        let imgs = frame.layers.filter { $0.isImage && $0.name != "DONTUSE" }   // "IGNORE" is the army panel's rings
        return imgs.sorted { a, b in
            if (a.kind == 0) != (b.kind == 0) { return a.kind == 0 }
            return a.width * a.height > b.width * b.height
        }
    }

    /// Minimap colours per terrain type.
    static let terrainColour: [UInt8: (UInt8, UInt8, UInt8)] = [
        0: (48, 96, 168), 1: (72, 128, 48), 2: (120, 118, 88), 3: (60, 92, 60), 4: (96, 48, 40), 5: (220, 224, 232),
        6: (200, 176, 104), 7: (128, 96, 56), 8: (72, 64, 64), 9: (64, 120, 190), 10: (200, 80, 40), 11: (160, 200, 230),
        12: (150, 100, 170), 13: (150, 100, 170), 14: (150, 100, 170), 15: (150, 100, 170), 16: (150, 100, 170), 17: (150, 100, 170), 18: (150, 100, 170),
    ]

    /// The whole map level as a small square image in screen layout (columns across, rows down),
    /// the way the game's minimap squashes the 2:1 map into its frame.
    static func minimap(map: MapFile, level: Int, size: Int) -> Bitmap {
        var bm = Bitmap(width: size, height: size)
        let n = map.size
        let cells = map.cells[level]
        for py in 0..<size {
            for px in 0..<size {
                // screen column y-x in -n/2..n/2, screen row x+y in n/2..3n/2
                let col = Float(px) / Float(size) * Float(n) - Float(n) / 2
                let row = Float(py) / Float(size) * Float(n) + Float(n) / 2
                let x = Int(((row - col) / 2).rounded()), y = Int(((row + col) / 2).rounded())
                guard x >= 0, x < n, y >= 0, y < n, let c = cells[x * n + y] else { continue }
                let rgb = terrainColour[c.type] ?? (255, 0, 255)
                let o = (py * size + px) * 4
                bm.pixels[o] = rgb.0; bm.pixels[o + 1] = rgb.1; bm.pixels[o + 2] = rgb.2; bm.pixels[o + 3] = 255
            }
        }
        return bm
    }
}
