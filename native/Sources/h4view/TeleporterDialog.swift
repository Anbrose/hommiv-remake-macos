import Foundation
import H4Engine

/// t_dialog_teleporter_entrance (heroes4.exe 0x6f89e0; dialogs_spec.md §5a): layers.dialog.teleporter,
/// 453x600 centred: Background, Text_Scroll, Title_Scroll, Mini_Map_Frame over the chosen map,
/// OK (button.ok) and Cancel (button.cancel) at their corners, up to three destinations as
/// mini-map buttons with a marker and a name, the slide bar past three; texts in font 20, black,
/// no halo.
extension Renderer {
    static let teleporterSize = (w: 453, h: 600)
    var teleporterOrigin: (Int, Int) { ((AdventureUI.width - 453) / 2, (AdventureUI.height - 600) / 2) }

    func teleporterQuads() -> [Quad] {
        guard let g = game, let c = g.teleportChoice, let ui = ui, let d = ui.dialog("Teleporter") else { return [] }
        let (ox, oy) = teleporterOrigin
        var out: [Quad] = []
        for n in ["Background", "Text_Scroll", "Title_Scroll"] { out += layoutImage(d, n, ox, oy) }
        let first = teleporterScroll
        for i in 0..<3 where first + i < c.dests.count {
            guard let m = d["Mini_map_\(i + 1)"] else { continue }
            let parts = c.dests[first + i].split(separator: "|").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            let (lv, tx, ty) = (parts[0], parts[1], parts[2])
            // the map around the destination, at the adventure minimap's scale
            let tex = uiTexture("telemap|\(lv)|\(tx)|\(ty)|\(minimapStamp)", {
                let size = ui.hotspot("mini_map")?.width ?? 148
                let keep = g.level; g.level = lv
                let full = AdventureUI.minimap(game: g, size: size)
                g.level = keep
                let n = Float(g.map.size)
                let px = Int((Float(ty - tx) + n / 2) / n * Float(size)), py = Int((Float(tx + ty) - n / 2) / n * Float(size))
                return Renderer.crop(full, x: px - m.width / 2, y: py - m.height / 2, w: m.width, h: m.height)
            })
            out.append(Quad(texture: black, x: ox + m.x, y: oy + m.y, w: m.width, h: m.height))
            out.append(Quad(texture: tex, x: ox + m.x, y: oy + m.y, w: m.width, h: m.height))
            if let mk = d["marker"], let m1 = d["Mini_map_1"] {   // the destination point
                out.append(Quad(texture: solid(255, 0, 0), x: ox + m.x + m.width / 2 - mk.width / 2, y: oy + m.y + m.height / 2 - mk.height / 2, w: mk.width, h: mk.height))
                _ = m1
            }
            out += infoText(c.labels[first + i], d["Name_\(i + 1)"], size: 22, centre: true, halo: false, ox, oy)
        }
        // the selection frame on the chosen destination
        if let k = teleporterPicked, k >= first, k < first + 3, let f = d["Mini_Map_Frame"], let m1 = d["Mini_map_1"], let m = d["Mini_map_\(k - first + 1)"] {
            out.append(Quad(texture: uiTexture("dlg|tele|frame", { f.bitmap }), x: ox + f.x + m.x - m1.x, y: oy + f.y + m.y - m1.y, w: f.width, h: f.height))
        }
        out += infoText(c.title, d["Title"], size: 22, centre: true, halo: false, ox, oy)
        if let t = d["Text"] {
            let lines = AdventureUI.wrap(c.text, font: ui.font(22), width: t.width).joined(separator: "\n")
            out += infoText(lines, t, size: 22, centre: true, halo: false, ox, oy)
        }
        let okOver = d["OK_Button"].map { hoverButton((ox + $0.x, oy + $0.y, 76, 44)) } ?? false
        let cancelOver = d["cancel_button"].map { hoverButton((ox + $0.x, oy + $0.y, 76, 44)) } ?? false
        out += buttonAt("ok", teleporterPicked == nil ? "Disabled" : okOver ? "Highlighted" : "Released", d["OK_Button"], ox, oy)
        out += buttonAt("cancel", cancelOver ? "Highlighted" : "Released", d["cancel_button"], ox, oy)
        // the slide bar beyond three destinations (control.vertical_scroll)
        if c.dests.count > 3, let bar = d["Slide_Bar"], let sc = try? LayerFile(data: ui.archive.payload("layers.control.vertical_scroll.h4d")),
           let up = sc["Up_Released"], let down = sc["Down_Released"], let bg = sc["Background"], let thumb = sc["Thumb"] {
            let x = ox + bar.x, y0 = oy + bar.y, y1 = y0 + bar.height
            var y = y0 + up.height
            while y < y1 - down.height { let h = min(bg.height, y1 - down.height - y); out.append(Quad(texture: uiTexture("vs|bg|\(h)", { Renderer.crop(bg.bitmap, x: 0, y: 0, w: bg.width, h: h) }), x: x + bg.x, y: y, w: bg.width, h: h)); y += bg.height }
            out.append(Quad(texture: uiTexture("vs|up", { up.bitmap }), x: x + up.x, y: y0, w: up.width, h: up.height))
            out.append(Quad(texture: uiTexture("vs|down", { down.bitmap }), x: x + down.x, y: y1 - down.height, w: down.width, h: down.height))
            let track = bar.height - up.height - down.height - thumb.height
            let ty = y0 + up.height + track * first / max(1, c.dests.count - 3)
            out.append(Quad(texture: uiTexture("vs|thumb", { thumb.bitmap }), x: x + thumb.x, y: ty, w: thumb.width, h: thumb.height))
        }
        return out
    }

    /// A click with the teleporter dialog open; true when it was open.
    func teleporterClick(x: Float, y: Float, double: Bool) -> Bool {
        guard let g = game, let c = g.teleportChoice, let ui = ui, let d = ui.dialog("Teleporter") else { return false }
        let (ox, oy) = teleporterOrigin
        func close() { g.teleportChoice = nil; teleporterPicked = nil; teleporterScroll = 0 }
        for i in 0..<3 where teleporterScroll + i < c.dests.count && inside(d["Mini_map_\(i + 1)"], at: ox, oy, x, y) {
            teleporterPicked = teleporterScroll + i
            if double { let k = teleporterScroll + i; close(); c.pick(k) }
            return true
        }
        if let ok = d["OK_Button"], x >= Float(ox + ok.x), x < Float(ox + ok.x + 76), y >= Float(oy + ok.y), y < Float(oy + ok.y + 44), let k = teleporterPicked {
            sound?.play("miscellaneous.button"); close(); c.pick(k)
        } else if let cn = d["cancel_button"], x >= Float(ox + cn.x), x < Float(ox + cn.x + 76), y >= Float(oy + cn.y), y < Float(oy + cn.y + 44) {
            sound?.play("miscellaneous.button"); close()
        } else if c.dests.count > 3, let bar = d["Slide_Bar"], x >= Float(ox + bar.x), x < Float(ox + bar.x + bar.width) {
            teleporterScroll = max(0, min(c.dests.count - 3, teleporterScroll + (y < Float(oy + bar.y + bar.height / 2) ? -1 : 1)))
        }
        return true
    }
}
