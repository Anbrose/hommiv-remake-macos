import Foundation
import AppKit
import H4Engine

/// The town screen's army rows (town_spec §4, town_screens_spec §1.3.4): the garrison (t_creature_array_window
/// 0x6439c0) at the Army_Display origin (500,583) -- one row of Left / Middle / Right pieces with its top at
/// 610 while nobody visits, else Top_* pieces over the visiting army's Bottom_* pieces at (500,655). A stack
/// is dragged to another place -- the same creature merges, an empty place takes it, anything else swaps;
/// with Shift or the split toggle half of it is split off -- or clicked and then the place clicked; the
/// Move buttons move everything up or down.
extension Renderer {
    /// Two rows while an army visits (or the spare row holds something), else the garrison alone.
    var townTwoRows: Bool {
        guard let g = game, let i = townOpen, i < g.towns.count else { return false }
        return g.visitingArmy(town: i) != nil || townSpare.contains { $0 != nil }
    }
    /// The two rows now (seven places each): the garrison and the visiting army or the spare row.
    func townRows() -> [[ArmySlot?]]? {
        guard let g = game, let i = townOpen, i < g.towns.count else { return nil }
        let v = g.visitingArmy(town: i)
        let spare = townSpare.count == GameState.rowSlots ? townSpare : [ArmySlot?](repeating: nil, count: GameState.rowSlots)
        return [g.garrisonSlots(i), v.map { g.armySlots($0) } ?? spare]
    }
    /// The shown rows' slots: each piece and its frame origin (the piece file's (0,0)).
    func townRowSlots() -> [[(piece: String, fx: Int, fy: Int)]] {
        townTwoRows ? [ringRow(x: 500, y: 583, style: 1), ringRow(x: 500, y: 655, style: 2)] : [ringRow(x: 500, y: 610, style: 0)]
    }
    /// The ring under a canvas point: (row, place).
    func townRing(at x: Float, _ y: Float) -> (row: Int, k: Int)? {
        for (row, slots) in townRowSlots().enumerated() {
            // (the rings' centres sit 41 px into their frames; a place is the 66 x 66 around it)
            for (k, s) in slots.enumerated() where abs(x - Float(s.fx + 41)) < 33 && abs(y - Float(s.fy + 41)) < 33 { return (row, k) }
        }
        return nil
    }
    func townPress(x: Float, y: Float) {
        townDragAt = nil
        guard townDialog == nil, let r = townRing(at: x, y), let rows = townRows(), rows[r.row][r.k] != nil else { townDrag = nil; return }
        townDrag = r
    }
    /// The pointer moved with the button down: the lifted stack follows it (the system pointer hides).
    func townDragged(x: Float, y: Float, split: Bool) {
        guard townDrag != nil else { return }
        if townDragAt == nil { NSCursor.hide() }
        townDragAt = (x, y); townDragSplit = split || townSplitOn
    }
    /// Apply a move; the army must keep a hero while it has creatures.
    func townMove(from: (row: Int, k: Int), to: (row: Int, k: Int), split: Bool) {
        guard let g = game, let i = townOpen, var rows = townRows() else { return }
        var n: Int? = nil
        if split || townSplitOn, let s = rows[from.row][from.k]?.stack, s.count > 1 { n = s.count / 2 }
        guard GameState.move(&rows, from: from, to: to, split: n) else { return }
        if let v = g.visitingArmy(town: i) {
            if !g.applyTownRows(i, rows, visitor: v) { prompt = ("An army needs a hero to lead it.", false, nil); return }
        } else {
            g.setGarrison(i, rows[0]); townSpare = rows[1]
        }
        townSelected = nil
        townSplitOn = false
    }
    func townDrop(x: Float, y: Float, split: Bool) {
        defer { townDrag = nil; if townDragAt != nil { NSCursor.unhide() }; townDragAt = nil }
        guard let from = townDrag, let to = townRing(at: x, y) else { return }
        townMove(from: from, to: to, split: split)
    }
    /// A click on the rows or the Move buttons: select a stack, or move the selected one here. True when handled.
    func townRowsClick(x: Float, y: Float) -> Bool {
        guard let g = game, let i = townOpen else { return false }
        if townTwoRows {
            let up = townButtonHit("move_up", x: Renderer.townMoveUp.0, y: Renderer.townMoveUp.1, x, y)
            let down = townButtonHit("move_garrison_down", x: Renderer.townMoveDown.0, y: Renderer.townMoveDown.1, x, y)
            if up || down {
                guard var rows = townRows() else { return true }
                GameState.moveAll(&rows, from: up ? 1 : 0, to: up ? 0 : 1)
                if let v = g.visitingArmy(town: i) {
                    if !g.applyTownRows(i, rows, visitor: v) { prompt = ("An army needs a hero to lead it.", false, nil) }
                } else { g.setGarrison(i, rows[0]); townSpare = rows[1] }
                return true
            }
        }
        guard let r = townRing(at: x, y), let rows = townRows() else { return false }
        if let s = townSelected {
            if s.row == r.row && s.k == r.k { townSelected = nil } else { townMove(from: s, to: r, split: false) }
        } else if rows[r.row][r.k] != nil { townSelected = r }
        return true
    }
    /// The town screen closes: a spare row with a hero becomes an army at the gate.
    func closeTown() {
        if let g = game, let i = townOpen, g.visitingArmy(town: i) == nil, townSpare.contains(where: { $0 != nil }) { g.leaveTown(i, spare: townSpare) }
        townSpare = []; townSelected = nil; townDrag = nil; townDragAt = nil; game?.townVisitor = nil
        townSplitOn = false
        townOpen = nil
    }

    func slotIcon(_ s: ArmySlot, ui: AdventureUI) -> (UILayer?, String?) {
        switch s {
        case .hero(let h): return (ui.portrait(keyword: h.keyword, alignment: h.alignment), nil)
        case .stack(let st): return (ui.creatureIcon(st.creature), String(st.count))
        }
    }
    /// The rows: per place the portrait, the piece over it (its _Highlight when selected), the label.
    func townRowQuads() -> [Quad] {
        guard let ui = ui, let rows = townRows() else { return [] }
        var out: [Quad] = []
        let lifting = townDragAt != nil ? townDrag : nil
        for (r, slots) in townRowSlots().enumerated() {
            var items: [(icon: UILayer?, count: String?, hero: Bool)] = []
            for (k, slot) in rows[r].enumerated() {
                guard var s = slot else { items.append((nil, nil, false)); continue }
                // a stack being dragged leaves its place (all of it, or the half a split takes)
                if let l = lifting, l.row == r, l.k == k {
                    guard townDragSplit, let st = s.stack, st.count > 1 else { items.append((nil, nil, false)); continue }
                    s = .stack(Hero.Stack(creature: st.creature, count: st.count - st.count / 2))
                }
                let (icon, count) = slotIcon(s, ui: ui)
                items.append((icon, count, s.hero != nil))
            }
            let sel = townSelected.flatMap { $0.row == r ? $0.k : nil }
            for (k, s) in slots.enumerated() {
                let cx = s.fx + 41, cy = s.fy + 41
                if let icon = items[k].icon {
                    out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height))
                }
                if let p = ui.creatureRing(k == sel ? s.piece + "_Highlight" : s.piece) ?? ui.creatureRing(s.piece) {
                    out.append(Quad(texture: uiTexture("cring|\(p.name)", { p.bitmap }), x: s.fx + p.x, y: s.fy + p.y, w: p.width, h: p.height))
                }
                if items[k].icon != nil { ringLabel(&out, ui: ui, cx: cx, cy: cy, count: items[k].count, hero: items[k].hero) }
            }
        }
        // the lifted stack under the pointer
        if let l = lifting, let at = townDragAt, l.row < rows.count, let s = rows[l.row][l.k] {
            var shown = s
            if townDragSplit, let st = s.stack, st.count > 1 { shown = .stack(Hero.Stack(creature: st.creature, count: st.count / 2)) }
            let (icon, count) = slotIcon(shown, ui: ui)
            if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: Int(at.0) - icon.width / 2, y: Int(at.1) - icon.height / 2, w: icon.width, h: icon.height)) }
            ringLabel(&out, ui: ui, cx: Int(at.0), cy: Int(at.1), count: count, hero: shown.hero != nil)
        }
        return out
    }
    // (the balloon's slot text)
    func townSlot(at x: Float, _ y: Float) -> ArmySlot? {
        guard let r = townRing(at: x, y), let rows = townRows() else { return nil }
        return rows[r.row][r.k]
    }
}

/// The help balloon (t_help_balloon 0x727490, town_screens_spec §1.3.5): after the pointer rests a
/// second on the town screen, the text of what is under it.
extension Renderer {
    func townBalloonText(x: Float, y: Float) -> String? {
        guard let ts = town, let g = game, let i = townOpen, townDialog == nil, menu == nil else { return nil }
        func b(_ key: String) -> String? { g.tables?.interfaceTexts[key]?.balloon }
        if townButtonHit("ok", x: Renderer.townOK.0, y: Renderer.townOK.1, x, y) { return b("town_screen.ok") }
        if ts.hit(ts.hotspot("Menu_Button_Released"), x, y) { return b("town_screen.main_menu") }
        if townTwoRows {
            if townButtonHit("move_up", x: Renderer.townMoveUp.0, y: Renderer.townMoveUp.1, x, y) { return b("shared.move_adjacent_to_garrison") }
            if townButtonHit("move_garrison_down", x: Renderer.townMoveDown.0, y: Renderer.townMoveDown.1, x, y) { return b("shared.move_garrison_to_adjacent") }
        }
        let sp = townSplitAt
        if townButtonHit(sp.file, x: sp.x, y: sp.y, x, y) { return b("town_screen.split") }
        if let lord = townGovernor(i), ts.hit(ts.hotspot("Lord_Portrait"), x, y) {
            let female = lord.actor.lowercased().contains("female")
            return text("town_lord_portrait_help_balloon.misc", "%Hero_name runs %town_name with %his %skill.")
                .replacingOccurrences(of: "%Hero_name", with: lord.name).replacingOccurrences(of: "%town_name", with: g.towns[i].name)
                .replacingOccurrences(of: "%his", with: female ? "her" : "his").replacingOccurrences(of: "%skill", with: skillName(3, level: lord.skill("nobility")).name)
        }
        for m in Renderer.townMaterials where ts.hit(ts.hotspot(m), x, y) { return b("material_display.\(m.lowercased())") }
        for d in townDwellings(i) where ts.hit(ts.hotspot("dwelling_\(d.slot + 1)"), x, y) {
            let c = g.tables?.creature(d.creature)
            return text("purchase_creature.town", "Purchase %creature_name").replacingOccurrences(of: "%creature_name", with: c?.plural ?? d.creature)
                .replacingOccurrences(of: "%growth", with: "\(townGrowth(i, d.creature))")
        }
        let towns = townListTowns
        for k in 0..<3 where x >= 82 && x < 232 && y >= Float(573 + 62 * k) && y < Float(633 + 62 * k) && townListTop + k < towns.count {
            return g.towns[towns[townListTop + k]].name
        }
        if let slot = townSlot(at: x, y) {
            switch slot {
            case .hero(let h): return h.name
            case .stack(let s):
                let c = g.tables?.creature(s.creature)
                return "\(s.count) \(s.count == 1 ? c?.name ?? s.creature : c?.plural ?? s.creature)"
            }
        }
        if y < 546, let bl = townBuildingAt(x, y) {
            let key = bl.name.lowercased()
            return g.tables?.buildings(for: g.towns[i].alignment).first { $0.keyword == key }?.name ?? bl.name
        }
        return nil
    }
    func townBalloonQuads() -> [Quad] {
        guard let b = townBalloon, Date().timeIntervalSince(b.since) >= 1, let s = townBalloonText(x: b.at.0, y: b.at.1), !s.isEmpty else { return [] }
        return helpBalloonQuads(s, at: b.at)
    }
}
