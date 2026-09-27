import Foundation
import H4Engine

/// A sanctuary's dialog (layers.dialog.sanctuary, 571x365 centred; heroes4.exe 0x80c0d0,
/// object_dialogs_spec §3): Background, the object's name (25), the text (20: "initial", "paid"
/// when this day is paid for, "denied" when an army is inside), Enter (a layout-image button,
/// disabled when occupied or short of 200 gold unless paid), button.close at (476,299) and the
/// "Enter Sanctuary" label (16). Every text black, no halo, centred, top-aligned.
extension Renderer {
    var sanctuaryOrigin: (Int, Int) { ((AdventureUI.width - 571) / 2, (AdventureUI.height - 365) / 2) }

    func sanctuaryQuads() -> [Quad] {
        guard let o = sanctuary, let ui = ui, let d = ui.dialog("sanctuary") else { return [] }
        let (ox, oy) = sanctuaryOrigin
        var out = dImage(d, "sanctuary", "Background", ox, oy)
        out += dText(o.title, dRect(d, "title"), font: dFont(25), ox, oy)
        out += dText(o.text, dRect(d, "text"), font: dFont(20), ox, oy)
        out += dImage(d, "sanctuary", o.canEnter ? "enter_released" : "enter_disabled", ox, oy)
        if let c = dRect(d, "close_button") { out += dButton("close", "Released", x: ox + c.x, y: oy + c.y) }
        out += dText(text("sanctuary_entry.misc", "Enter Sanctuary"), dRect(d, "enter_text"), font: dFont(33 / 2), ox, oy)
        return out
    }

    func sanctuaryClick(x: Float, y: Float) {
        guard let o = sanctuary, let g = game, let d = ui?.dialog("sanctuary") else { sanctuary = nil; return }
        let (ox, oy) = sanctuaryOrigin
        if o.canEnter, inside(d["enter_released"], at: ox, oy, x, y) { g.enterSanctuary(o); sanctuary = nil; return }
        if let c = dRect(d, "close_button"), DRect(ox + c.x, oy + c.y, 76, 44).contains(x, y) { sanctuary = nil }
    }
}
