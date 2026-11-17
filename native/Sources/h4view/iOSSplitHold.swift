#if os(iOS)
import Foundation
import CoreGraphics
import H4Engine

/// A phone has no Shift key: holding a finger on a stack of two or more (the adventure panel's
/// rings, the town's army rows, the army screen) splits it into the first empty place -- its own
/// row first -- through the game's own split dialog, which opens at x - 1 / 1 as a Shift drop on
/// an empty place does (0x6467f0). With no empty place, or a single creature, the hold stays the
/// right button (the information box).
extension Renderer {
    /// The first empty place: the stack's own row first, then the other rows in order.
    private static func emptyPlace(_ rows: [[ArmySlot?]], near from: (row: Int, k: Int)) -> (row: Int, k: Int)? {
        let order = [from.row] + rows.indices.filter { $0 != from.row }
        for r in order { if let k = rows[r].firstIndex(where: { $0 == nil }) { return (r, k) } }
        return nil
    }

    /// True when the hold opened the split dialog.
    func holdSplit(x: Float, y: Float) -> Bool {
        guard splitDialog == nil, spellBook == nil, !inCombat else { return false }
        if let s = armySession {
            let rows = sessionRows(s)
            guard s.artDrag == nil, let from = armyRing(s, at: x, y), let st = rows[from.row][from.k]?.stack, st.count > 1,
                  let to = Renderer.emptyPlace(rows, near: from) else { return false }
            s.drag = nil; s.dragAt = nil; s.selected = from
            armyDrop(s, from: from, to: to, split: true)
            return splitDialog != nil
        }
        if townOpen != nil {
            guard townDialog == nil, caravanUI == nil, let from = townRing(at: x, y), let rows = townRows(),
                  let st = rows[from.row][from.k]?.stack, st.count > 1, let to = Renderer.emptyPlace(rows, near: from) else { return false }
            let o = townRowSlots()[to.row][to.k]
            townDragAt = nil
            townDrag = from
            townDrop(x: Float(o.fx + 41), y: Float(o.fy + 41), split: true)
            return splitDialog != nil
        }
        guard panelIdle, let g = game, let h = g.heroes.first, let k = panelRing(at: x, y) else { return false }
        let row = g.armySlots(h)
        guard let st = row[safe: k]??.stack, st.count > 1, let to = Renderer.emptyPlace([row], near: (0, k)) else { return false }
        panelDrag = nil
        panelDrop(from: k, to: to.k, split: true)
        return splitDialog != nil
    }
}

extension MapView {
    /// The hold's point on the frame's canvas pixels (the frame sits `pointerShift` right).
    func holdCanvas(_ p: CGPoint) -> (Float, Float) {
        let k: Float = bounds.height > 0 ? Float(AdventureUI.height) / Float(bounds.height) : 1
        return (Float(p.x) * k - renderer.pointerShift, Float(p.y) * k)
    }
}
#endif
