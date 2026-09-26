import Foundation
import H4Engine

/// The town screen's army rows (town_spec §4): the garrison above, the visiting army (or a spare
/// empty one) below; a stack is dragged to another place -- the same creature merges, an empty
/// place takes it, anything else swaps; with Shift half of it is split off -- or clicked and then
/// the place clicked; the garrison button pair moves everything up or down.
extension Renderer {
    /// The two rows now: the garrison and the visiting army or the spare row.
    func townRows() -> [[ArmySlot]]? {
        guard let g = game, let i = townOpen, i < g.towns.count else { return nil }
        let v = g.visitingArmy(town: i)
        return [g.garrisonSlots(i), v.map { g.armySlots($0) } ?? townSpare]
    }
    /// The ring under a canvas point: (row, slot).
    func townRing(at x: Float, _ y: Float) -> (row: Int, k: Int)? {
        guard let ui = ui else { return nil }
        for row in 0...1 {
            // (the rings' centres sit 41 px into their origins; a place is the 66 x 67 around it)
            for (k, o) in townRingOrigins(row: row, ui: ui).enumerated() where abs(x - Float(o.x + 41)) < 33 && abs(y - Float(o.y + 41)) < 33 {
                return (row, k)
            }
        }
        return nil
    }
    func townPress(x: Float, y: Float) {
        guard townDialog == nil, let r = townRing(at: x, y), let rows = townRows(), r.k < rows[r.row].count else { townDrag = nil; return }
        townDrag = r
    }
    /// Apply a move; the army must keep a hero while it has creatures.
    func townMove(from: (row: Int, k: Int), to: (row: Int, k: Int), split: Bool) {
        guard let g = game, let i = townOpen, var rows = townRows() else { return }
        var n: Int? = nil
        if split, let s = rows[from.row][from.k].stack, s.count > 1 { n = s.count / 2 }
        let target = min(to.k, rows[to.row].count)
        guard GameState.move(&rows, from: from, to: (to.row, target), split: n) else { return }
        if let v = g.visitingArmy(town: i) {
            if !g.applyTownRows(i, rows, visitor: v) { prompt = ("An army needs a hero to lead it.", false, nil); return }
        } else {
            g.setGarrison(i, rows[0]); townSpare = rows[1]
        }
        townSelected = nil
    }
    func townDrop(x: Float, y: Float, split: Bool) {
        defer { townDrag = nil }
        guard let from = townDrag, let to = townRing(at: x, y) else { return }
        townMove(from: from, to: to, split: split)
    }
    /// A click on the rows: select a stack, or move the selected one here. True when handled.
    func townRowsClick(x: Float, y: Float) -> Bool {
        guard let ts = town, let g = game, let i = townOpen, let ui = ui else { return false }
        if ts.hit(ts.hotspot("Move_Up_Released"), x, y) || ts.hit(ts.hotspot("Move_Down_Released"), x, y) {
            guard var rows = townRows() else { return true }
            let up = ts.hit(ts.hotspot("Move_Up_Released"), x, y)
            GameState.moveAll(&rows, from: up ? 1 : 0, to: up ? 0 : 1)
            if let v = g.visitingArmy(town: i) {
                if !g.applyTownRows(i, rows, visitor: v) { prompt = ("An army needs a hero to lead it.", false, nil) }
            } else { g.setGarrison(i, rows[0]); townSpare = rows[1] }
            return true
        }
        guard let r = townRing(at: x, y), let rows = townRows() else { return false }
        if let s = townSelected {
            if s.row == r.row && s.k == r.k { townSelected = nil } else { townMove(from: s, to: r, split: false) }
        } else if r.k < rows[r.row].count { townSelected = r }
        return true
    }
    /// The town screen closes: a spare row with a hero becomes an army at the gate.
    func closeTown() {
        if let g = game, let i = townOpen, g.visitingArmy(town: i) == nil, !townSpare.isEmpty { g.leaveTown(i, spare: townSpare) }
        townSpare = []; townSelected = nil; townDrag = nil; game?.townVisitor = nil
        townOpen = nil
    }

    func townRowQuads() -> [Quad] {
        guard let ui = ui, let rows = townRows() else { return [] }
        var out: [Quad] = []
        for (r, row) in rows.enumerated() {
            let origins = townRingOrigins(row: r, ui: ui)
            for (k, s) in row.prefix(GameState.rowSlots).enumerated() {
                let cx = origins[k].x + 41, cy = origins[k].y + 41
                if let sel = townSelected, sel.row == r, sel.k == k { out.append(Quad(texture: solid(230, 200, 60), x: cx - 31, y: cy - 31, w: 62, h: 62)) }
                var icon: UILayer?, count: String? = nil
                switch s {
                case .hero(let h): icon = ui.portrait(keyword: h.keyword, alignment: h.alignment)
                case .stack(let st): icon = ui.creatureIcon(st.creature); count = String(st.count)
                }
                if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height)) }
                ringLabel(&out, ui: ui, cx: cx, cy: cy, count: count, hero: s.hero != nil)
            }
        }
        return out
    }
}

/// The help balloon (t_help_balloon 0x727490): after the pointer rests a second on the town screen,
/// the text of what is under it -- a building's name, the bottom bar's table.Interface balloon
/// texts, a stack's name and count -- in a small box at the pointer.
extension Renderer {
    func townBalloonText(x: Float, y: Float) -> String? {
        guard let ts = town, let g = game, let i = townOpen, townDialog == nil else { return nil }
        let texts = g.tables?.interfaceTexts ?? [:]
        func t(_ key: String) -> String? { texts[key]?.balloon }
        let items: [(String, String)] = [("OK_Button", "town_screen.ok"), ("Move_Up_Released", "shared.move_adjacent_to_garrison"),
                                         ("Move_Down_Released", "shared.move_garrison_to_adjacent"), ("Lord_Portrait", "town_screen.governer"),
                                         ("Split_Button", "town_screen.split"), ("Single_Split_Button", "town_screen.split"), ("menu_button", "town_screen.town_menu")]
        for (spot, key) in items where ts.hit(ts.hotspot(spot), x, y) { return t(key) }
        for name in ui?.resourceNames ?? [] where ts.hit(ts.hotspot("\(name)_Number") ?? ts.hotspot("\(name)_number"), x, y) || ts.hit(ts.hotspot(name), x, y) {
            return t("town_screen.\(name.lowercased())")
        }
        if let r = townRing(at: x, y), let rows = townRows(), r.k < rows[r.row].count {
            switch rows[r.row][r.k] {
            case .hero(let h): return h.name
            case .stack(let s):
                let c = g.tables?.creature(s.creature)
                return "\(s.count) \(s.count == 1 ? c?.name ?? s.creature : c?.plural ?? s.creature)"
            }
        }
        if y < 546, let b = townBuilding(at: x, y) {
            let key = b.name.lowercased()
            return g.tables?.buildings(for: g.towns[i].alignment).first { $0.keyword == key }?.name ?? b.name
        }
        return nil
    }
    func townBalloonQuads() -> [Quad] {
        guard let b = townBalloon, Date().timeIntervalSince(b.since) >= 1, let ui = ui,
              let s = townBalloonText(x: b.at.0, y: b.at.1), !s.isEmpty else { return [] }
        let w = ui.numberFont.measure(s) + 12, h = ui.numberFont.size + 8
        let x = min(AdventureUI.width - w - 2, Int(b.at.0) + 14), y = max(2, min(AdventureUI.height - h - 2, Int(b.at.1) + 18))
        return [Quad(texture: solid(60, 40, 20), x: x - 1, y: y - 1, w: w + 2, h: h + 2), Quad(texture: solid(245, 232, 190), x: x, y: y, w: w, h: h),
                Quad(texture: uiTexture("dlgtext|\(ui.numberFont.size)|\(s)|40", { ui.numberFont.render(s, colour: (40, 24, 8)) }), x: x + 6, y: y + 4, w: w - 12, h: ui.numberFont.size)]
    }
}
