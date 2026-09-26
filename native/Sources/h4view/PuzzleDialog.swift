import Foundation
import H4Engine

/// The puzzle map (layers.Dialog.Puzzle; heroes4.exe 0x7e9300): a colour's obelisks visited of
/// those it needs, thirty pieces over the map around the treasure -- visited x 30 / needed of them
/// lifted -- the treasure's cell marked once the puzzle is whole; the colour buttons change colour.
extension Renderer {
    var puzzleLayout: LayerFile? {
        guard let ui = ui else { return nil }
        if let d = ui.dialogs["Puzzle"] { return d }
        let d = (try? ui.archive.payload("layers.Dialog.Puzzle.h4d")).flatMap { try? LayerFile(data: $0) }
        ui.dialogs["Puzzle"] = d
        return d
    }
    static let obeliskColours = ["gold", "red", "blue", "white", "black", "green", "purple", "orange", "yellow", "brown", "silver", "bronze"]

    func puzzleQuads() -> [Quad] {
        guard let c = puzzle, let g = game, let ui = ui, let d = puzzleLayout else { return [] }
        let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
        var out: [Quad] = []
        func img(_ n: String) { if let l = d[n] { out.append(Quad(texture: uiTexture("dlg|puzzle|\(n)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height)) } }
        img("Background")
        let need = g.obelisksRequired(c), seen = min(need, g.obeliskVisits[c] ?? 0)
        // the ground: the map around the treasure (or the obelisks while it is not found yet)
        if let area = d.layers.first(where: { $0.name.lowercased() == "puzzle_area" }) {
            let site = g.digSites[c]
            let centre: (Int, Int) = site.map { ($0[0], $0[1]) } ?? g.scene.placed.first(where: { $0.type == "obelisk" && $0.subtype == c }).map { ($0.cellX, $0.cellY) } ?? (g.map.size / 2, g.map.size / 2)
            let size = 1024, w = 128, h = 96
            let n = Float(g.map.size)
            // the view kept inside the map, the treasure marked where it falls in it
            let cx = Int((Float(centre.1 - centre.0) + n / 2) / n * Float(size)), cy = Int((Float(centre.0 + centre.1) - n / 2) / n * Float(size))
            let x0 = max(0, min(size - w, cx - w / 2)), y0 = max(0, min(size - h, cy - h / 2))
            let tex = uiTexture("puzzlemap|\(c)|\(centre.0),\(centre.1)", {
                let full = AdventureUI.minimap(game: g, size: size)
                var b = Bitmap(width: w, height: h)
                for y in 0..<h { for x in 0..<w {
                    let i = (y * w + x) * 4, j = ((y0 + y) * full.width + x0 + x) * 4
                    for k in 0..<3 { b.pixels[i + k] = full.pixels[j + k] }
                    b.pixels[i + 3] = 255
                } }
                return b
            })
            out.append(Quad(texture: tex, x: ox + area.x, y: oy + area.y, w: area.width, h: area.height))
            if site != nil {
                let mx = area.x + (cx - x0) * area.width / w, my = area.y + (cy - y0) * area.height / h
                out.append(Quad(texture: solid(200, 20, 20), x: ox + mx - 6, y: oy + my - 6, w: 12, h: 12))
            }
        }
        // the pieces not yet lifted cover it
        let lifted = need > 0 ? seen * 30 / need : 0
        for k in (lifted + 1)...max(lifted + 1, 30) where k <= 30 {
            if let l = d.layers.first(where: { $0.name.lowercased() == "piece_\(k)" }) {
                out.append(Quad(texture: uiTexture("dlg|puzzle|piece\(k)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height))
            }
        }
        out += centred(text("puzzle.dialog", "Puzzle Map"), in: d["Title"], at: ox, oy, font: ui.dateFont)
        out += centred("\(text("\(c).obelisk_color", c.capitalized)): \(seen) / \(need)", in: d["Text"], at: ox, oy, font: ui.dateFont)
        for col in Renderer.obeliskColours where g.obelisksRequired(col) > 0 {
            let n = col.prefix(1).uppercased() + col.dropFirst()
            img(col == c ? "\(n)_Pressed" : "\(n)_Released")
        }
        if let l = d["Close_Button"], let b = ui.button("close") {
            out.append(Quad(texture: uiTexture("button|\(b.name)|close", { b.bitmap }), x: ox + l.x + (l.width - b.width) / 2, y: oy + l.y + (l.height - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }
    func puzzleClick(x: Float, y: Float) {
        guard let g = game, let d = puzzleLayout else { puzzle = nil; return }
        let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
        for col in Renderer.obeliskColours where g.obelisksRequired(col) > 0 {
            let n = col.prefix(1).uppercased() + col.dropFirst()
            if inside(d["\(n)_Released"], at: ox, oy, x, y) { puzzle = col; return }
        }
        puzzle = nil
    }
}
