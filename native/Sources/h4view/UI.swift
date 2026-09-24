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
