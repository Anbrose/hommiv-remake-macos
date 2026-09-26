import Foundation
import H4Engine

/// A sanctuary's dialog (layers.dialog.sanctuary; heroes4.exe 0x80c0d0): the text ("initial", or
/// "paid" when this day is paid for), Enter (disabled without 200 gold) with the
/// sanctuary_entry.misc label, and close.
extension Renderer {
    var sanctuaryOrigin: (Int, Int) { ((AdventureUI.width - 572) / 2, (AdventureUI.height - 366) / 2) }

    func sanctuaryQuads() -> [Quad] {
        guard let o = sanctuary, let ui = ui, let d = ui.dialog("sanctuary") else { return [] }
        let (ox, oy) = sanctuaryOrigin
        var out = dialogImages(d, key: "sanctuary", at: ox, oy, skip: ["enter_disabled", "enter_highlighted", "enter_pressed", "enter_released", "close_button"])
        if let l = d[o.canEnter ? "enter_released" : "enter_disabled"] {
            out.append(Quad(texture: uiTexture("dlg|sanctuary|\(l.name)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height))
        }
        out += centred(o.title, in: d["title"], at: ox, oy, font: ui.dateFont)
        out += paragraph(o.text, in: d["text"], at: ox, oy, font: ui.numberFont)
        out += centred(text("sanctuary_entry.misc", "Enter Sanctuary"), in: d["enter_text"], at: ox, oy, font: ui.numberFont)
        if let l = d["close_button"], let b = ui.button("close") {
            out.append(Quad(texture: uiTexture("button|\(b.name)|close", { b.bitmap }), x: ox + l.x + (l.width - b.width) / 2, y: oy + l.y + (l.height - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }

    func sanctuaryClick(x: Float, y: Float) {
        guard let o = sanctuary, let g = game, let d = ui?.dialog("sanctuary") else { sanctuary = nil; return }
        let (ox, oy) = sanctuaryOrigin
        if o.canEnter, inside(d["enter_released"], at: ox, oy, x, y) { g.enterSanctuary(o); sanctuary = nil; return }
        if inside(d["close_button"], at: ox, oy, x, y) { sanctuary = nil }
    }
}
