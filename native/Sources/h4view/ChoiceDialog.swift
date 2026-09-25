import Foundation
import H4Engine

/// A choice an object offers (a teacher's skill for one of the heroes, a school's class, a
/// gateway's destination): the question in the generic frame, one line per option (the chosen
/// one highlighted), OK and Cancel.
extension Renderer {
    func choiceLayout() -> (x: Int, y: Int, w: Int, h: Int, lines: [String], options: [(x: Int, y: Int, w: Int, h: Int)])? {
        guard let g = game, let c = g.choice, let ui = ui else { return nil }
        let w = 460
        let font = ui.dateFont
        let lines = AdventureUI.wrap(c.text, font: font, width: w - 60)
        let top = 30 + lines.count * font.lineHeight + 12
        let rowH = font.lineHeight + 8
        let h = min(AdventureUI.height - 40, top + c.options.count * rowH + 70)
        let x = (AdventureUI.mapViewportWidth - w) / 2, y = (AdventureUI.height - h) / 2
        let options = c.options.indices.map { (x: x + 30, y: y + top + $0 * rowH, w: w - 60, h: rowH) }
        return (x, y, w, h, lines, options)
    }
    func choiceQuads() -> [Quad] {
        guard let g = game, let c = g.choice, let ui = ui, let m = choiceLayout() else { return [] }
        var out = frameQuads(x: m.x, y: m.y, w: m.w, h: m.h)
        let font = ui.dateFont
        for (i, line) in m.lines.enumerated() {
            let w = font.measure(line)
            out.append(Quad(texture: uiTexture("msg|\(line)", { font.render(line, colour: (40, 24, 8)) }), x: m.x + (m.w - w) / 2, y: m.y + 30 + i * font.lineHeight, w: w, h: font.size))
        }
        for (i, r) in m.options.enumerated() where i < c.options.count {
            let on = choicePicked == i
            if on { out.append(Quad(texture: shade, x: r.x, y: r.y, w: r.w, h: r.h)) }
            let colour: (UInt8, UInt8, UInt8) = on ? (255, 236, 160) : (40, 24, 8)
            let t = c.options[i], w = ui.numberFont.measure(t)
            out.append(Quad(texture: uiTexture("choice|\(t)|\(colour.0)", { ui.numberFont.render(t, colour: colour) }), x: r.x + (r.w - w) / 2, y: r.y + (r.h - ui.numberFont.size) / 2, w: w, h: ui.numberFont.size))
        }
        for (name, rect) in [("ok", choiceOK(m)), ("cancel", choiceCancel(m))] {
            guard let b = ui.button(name, state: name == "ok" && choicePicked == nil ? "Disabled" : "Released") ?? ui.button(name) else { continue }
            out.append(Quad(texture: uiTexture("button|\(name)|\(b.name)", { b.bitmap }), x: rect.x + (rect.w - b.width) / 2, y: rect.y + (rect.h - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }
    private func choiceOK(_ m: (x: Int, y: Int, w: Int, h: Int, lines: [String], options: [(x: Int, y: Int, w: Int, h: Int)])) -> (x: Int, y: Int, w: Int, h: Int) {
        (m.x + m.w / 2 - 86, m.y + m.h - 54, 66, 32)
    }
    private func choiceCancel(_ m: (x: Int, y: Int, w: Int, h: Int, lines: [String], options: [(x: Int, y: Int, w: Int, h: Int)])) -> (x: Int, y: Int, w: Int, h: Int) {
        (m.x + m.w / 2 + 20, m.y + m.h - 54, 66, 32)
    }
    /// A click with a choice open; true when it was open.
    func choiceClick(x: Float, y: Float, double: Bool) -> Bool {
        guard let g = game, let c = g.choice, let m = choiceLayout() else { return false }
        func on(_ r: (x: Int, y: Int, w: Int, h: Int)) -> Bool { x >= Float(r.x) && x < Float(r.x + r.w) && y >= Float(r.y) && y < Float(r.y + r.h) }
        for (i, r) in m.options.enumerated() where on(r) {
            choicePicked = i
            if double { g.choice = nil; choicePicked = nil; c.pick(i) }
            return true
        }
        if on(choiceOK(m)), let k = choicePicked { g.choice = nil; choicePicked = nil; sound?.play("miscellaneous.button"); c.pick(k) }
        else if on(choiceCancel(m)) { g.choice = nil; choicePicked = nil; sound?.play("miscellaneous.button") }
        return true
    }
}
