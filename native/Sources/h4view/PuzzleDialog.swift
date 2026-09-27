import Foundation
import H4Engine

/// When each colour's puzzle was first seen whole (the pieces fade from then on).
var puzzleSolvedAt: [String: Date] = [:]

/// The puzzle map (t_puzzle_window 0x7e9300, layers.dialog.puzzle; object_dialogs_spec §4):
/// Background, "Puzzle Map" (18), button.ok at (725,545), a layout-image button per colour whose
/// oracles count, the text (18, left: "%visited out of %required oracles visited.", or "There are
/// no Oracles in this land."), and the pieces: the first visited x 30 / required of them shown (the
/// picture assembles as oracles are visited). Once complete the land around the dig site fills
/// puzzle_area and the thirty pieces fade out over it (alpha 15 down to 0).
extension Renderer {
    var puzzleLayout: LayerFile? { dFile("Dialog.Puzzle") ?? dFile("dialog.puzzle") }
    static let obeliskColours = ["gold", "red", "blue", "white", "black", "green", "purple", "orange", "yellow", "brown", "silver", "bronze"]
    static let puzzleFadeStep = 0.1   // seconds per alpha step [G]

    func puzzleQuads() -> [Quad] {
        guard let c = puzzle, let g = game, let d = puzzleLayout else { return [] }
        let (ox, oy) = dialogOrigin800
        var out = dImage(d, "puzzle", "Background", ox, oy)
        out += dText(text("puzzle_title.misc", "Puzzle Map"), dRect(d, "Title"), font: dFont(18), ox, oy)
        if let cb = dRect(d, "Close_Button") { out += dButton("ok", "Released", x: ox + cb.x, y: oy + cb.y) }
        let colours = Renderer.obeliskColours.filter { g.obelisksRequired($0) > 0 }
        for col in colours {
            let n = col.prefix(1).uppercased() + col.dropFirst()
            out += dImage(d, "puzzle", col == c ? "\(n)_Pressed" : "\(n)_Released", ox, oy)
        }
        let need = g.obelisksRequired(c), seen = min(need, g.obeliskVisits[c] ?? 0)
        let line: String = {
            if colours.isEmpty { return interfaceText("puzzle_map", "empty")?.rightClick ?? "There are no Oracles in this land." }
            return text("puzzle_visit.misc", "%visited out of %required oracles visited.")
                .replacingOccurrences(of: "%visited", with: "\(seen)").replacingOccurrences(of: "%required", with: "\(need)")
        }()
        out += dText(line, dRect(d, "Text"), font: dFont(18), centre: false, ox, oy)
        if need > 0, seen >= need, let site = g.digSites[c], let area = dRect(d, "puzzle_area") {
            // complete: the land around the dig site, the pieces fading over it
            out += puzzleMap(g, centre: (site[0], site[1]), area: area, ox, oy)
            let since = puzzleSolvedAt[c] ?? { let t = Date(); puzzleSolvedAt[c] = t; return t }()
            let alpha = max(0, 15 - Int(Date().timeIntervalSince(since) / Renderer.puzzleFadeStep))
            if alpha > 0 {
                for k in 1...30 { if let p = dLayer(d, "Piece_\(k)") { out += dImageAlpha(p, "puzzle", x: ox + p.x, y: oy + p.y, alpha: alpha) } }
            }
        } else if need > 0 {
            let shown = seen * 30 / need
            if shown > 0 { for k in 1...shown { out += dImage(d, "puzzle", "Piece_\(k)", ox, oy) } }
        }
        return out
    }
    /// The land around a cell, filling the area (the exe puts a real adventure-map view there; this is
    /// the minimap's picture of it, centred on the cell).
    func puzzleMap(_ g: GameState, centre: (Int, Int), area: DRect, _ ox: Int, _ oy: Int) -> [Quad] {
        let size = 2048
        let n = Float(g.map.size)
        let cx = Int((Float(centre.1 - centre.0) + n / 2) / n * Float(size)), cy = Int((Float(centre.0 + centre.1) - n / 2) / n * Float(size))
        let w = area.w / 3, h = area.h / 3
        let x0 = cx - w / 2, y0 = cy - h / 2
        let tex = uiTexture("puzzlemap|\(g.level)|\(centre.0),\(centre.1)", {
            let full = AdventureUI.minimap(game: g, size: size)
            var b = Bitmap(width: w, height: h)
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4, sx = x0 + x, sy = y0 + y
                b.pixels[i + 3] = 255
                guard sx >= 0, sy >= 0, sx < size, sy < size else { continue }
                let j = (sy * full.width + sx) * 4
                for k in 0..<3 { b.pixels[i + k] = full.pixels[j + k] }
            } }
            return b
        })
        return [Quad(texture: tex, x: ox + area.x, y: oy + area.y, w: area.w, h: area.h)]
    }
    func puzzleClick(x: Float, y: Float) {
        guard let g = game, let d = puzzleLayout else { puzzle = nil; return }
        let (ox, oy) = dialogOrigin800
        for col in Renderer.obeliskColours where g.obelisksRequired(col) > 0 {
            let n = col.prefix(1).uppercased() + col.dropFirst()
            if inside(dLayer(d, "\(n)_Released"), at: ox, oy, x, y) { puzzle = col; return }
        }
        if let cb = dRect(d, "Close_Button"), DRect(ox + cb.x, oy + cb.y, 76, 44).contains(x, y) { puzzle = nil }
    }
    func puzzleTip(x: Float, y: Float) -> String? {
        guard let g = game, let d = puzzleLayout else { return nil }
        let (ox, oy) = dialogOrigin800
        for col in Renderer.obeliskColours where g.obelisksRequired(col) > 0 {
            let n = col.prefix(1).uppercased() + col.dropFirst()
            if inside(dLayer(d, "\(n)_Released"), at: ox, oy, x, y) { return interfaceText("puzzle_map", col)?.balloon }
        }
        if let cb = dRect(d, "Close_Button"), DRect(ox + cb.x, oy + cb.y, 76, 44).contains(x, y) { return interfaceText("puzzle_map", "ok")?.balloon }
        return nil
    }
}
