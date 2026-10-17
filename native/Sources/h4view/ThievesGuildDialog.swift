import Foundation
import H4Engine

/// The Thieves Guild (t_thieves_guild_window 0x887b40, layers.Dialog.Thieves_Guild; re/thieves_guild_spec.md):
/// opened from the Game Menu or the hot key G. Background, the title (27), the intro text (18), the
/// labels Towns / Armies / Income (25), all centred and black, the ok button (Enter), and three bar
/// graphs with a bar per player in the map's player order. A bar is the bottom h rows of four layers
/// stacked - Black_Outline (h+8), Gold_Border (h+6), Inner_Outline (h+2), <colour>_Bar (h) - h being
/// 259 x value / max clamped to 1 ... 259 (0x888b30).
extension Renderer {
    var thievesGuildLayout: LayerFile? { dFile("Dialog.Thieves_Guild") ?? dFile("dialog.thieves_guild") }
    /// The bar image names by player colour (0x98ebb8).
    static let guildBarColours = ["red", "blue", "green", "orange", "purple", "teal", "gray"]

    func thievesGuildQuads() -> [Quad] {
        guard thievesGuildOpen, let g = game, let d = thievesGuildLayout else { return [] }
        let (ox, oy) = dialogOrigin800
        var out = dImage(d, "thieves", "Background", ox, oy)
        if let b = dRect(d, "ok_button") { out += dButton("ok", "Released", x: ox + b.x, y: oy + b.y) }
        out += dText(text("thieves_guild_title.misc", "Thieves Guild"), dRect(d, "Title"), font: dFont(27), ox, oy)
        out += dText(text("thieves_guild_intro.misc", ""), dRect(d, "Text"), font: dFont(18), ox, oy)
        out += dText(text("thieves_guild_towns.misc", "Towns"), dRect(d, "Town_Text"), font: dFont(25), ox, oy)
        out += dText(text("thieves_guild_armies.misc", "Armies"), dRect(d, "Army_Text"), font: dFont(25), ox, oy)
        out += dText(text("thieves_guild_income.misc", "Income"), dRect(d, "Income_Text"), font: dFont(25), ox, oy)
        let graphs = g.thievesGuild()
        out += guildBars(d, graph: graphs.towns, area: "Town_Graph", ox, oy)
        out += guildBars(d, graph: graphs.income, area: "Income_Graph", ox, oy)
        out += guildBars(d, graph: graphs.armies, area: "Army_Graph", ox, oy)
        return out
    }

    /// One graph's bars (0x889bb0 and its two siblings), centred in the graph's area.
    func guildBars(_ d: LayerFile, graph: ThievesGuild.Graph, area: String, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let red = dLayer(d, "Red_Bar"), let green = dLayer(d, "Green_Bar"), let town = dRect(d, "Town_Graph"), let r = dRect(d, area) else { return [] }
        let heights = graph.heights(full: red.height)
        let xs = ThievesGuild.barXs(count: heights.count, graphX: r.x, graphW: r.w, barW: red.width, stride: green.x - red.x)
        let y = r.y + (red.y - town.y)
        var out: [Quad] = []
        for (k, h) in heights.enumerated() {
            let colour = graph.colours[k] < Renderer.guildBarColours.count ? Renderer.guildBarColours[graph.colours[k]] : "gray"
            // the outlines keep their offsets from Red_Bar; the colour's own bar sits at the bar's place
            let dx = xs[k] - red.x, dy = y - red.y
            for (name, extra) in [("Black_Outline", 8), ("Gold_Border", 6), ("Inner_Outline", 2)] {
                if let l = dLayer(d, name) { out += guildBottom(l, rows: h + extra, x: ox + l.x + dx, y: oy + l.y + dy) }
            }
            if let l = dLayer(d, "\(colour)_Bar") { out += guildBottom(l, rows: h, x: ox + xs[k], y: oy + y) }
        }
        return out
    }
    /// A layer's bottom `rows` rows at its own place (a clip window whose top moved down, 0x71ef60 flag 0).
    func guildBottom(_ l: UILayer, rows: Int, x: Int, y: Int) -> [Quad] {
        let n = min(rows, l.height)
        guard n > 0, l.width > 0 else { return [] }
        let tex = uiTexture("tgbar|\(l.name)|\(n)", {
            let full = l.bitmap
            var b = Bitmap(width: full.width, height: n)
            let rowBytes = full.width * 4, skip = (full.height - n) * rowBytes
            b.pixels = Array(full.pixels[skip..<(skip + n * rowBytes)])
            return b
        })
        return [Quad(texture: tex, x: x, y: y + l.height - n, w: l.width, h: n)]
    }

    func thievesGuildClick(x: Float, y: Float) {
        let (ox, oy) = dialogOrigin800
        if let b = dRect(thievesGuildLayout, "ok_button"), b.offset(ox, oy).contains(x, y) {
            sound?.play("miscellaneous.button")
            thievesGuildOpen = false
        }
    }
    /// The ok button's balloon (table.Interface thieves_guild / ok: "Exit").
    func thievesGuildTip(x: Float, y: Float) -> String? {
        let (ox, oy) = dialogOrigin800
        if let b = dRect(thievesGuildLayout, "ok_button"), b.offset(ox, oy).contains(x, y) { return interfaceText("thieves_guild", "ok")?.balloon }
        return nil
    }
}
