import Foundation
import H4Engine

/// The split dialog while open: which army and stack, how many the new stack takes, where it sits.
struct SplitState {
    var leader: Hero
    var stack: Int          // index into leader.army
    var total: Int
    var moved: Int
    var x: Int, y: Int      // the dialog's top-left on the canvas
}
var splitDialog: SplitState?

/// Split creatures (t_split_creatures 0x872ef0, layers.dialog.split_creatures; object_dialogs_spec §5):
/// opened by the army screen's split button with a creature stack chosen and a free ring. The
/// 561x432 frame opens above the pointer, centred on it, clamped into the screen; Background,
/// "Split %creatures" (34), the creature's model in left_box and right_box, the counts left and
/// moved (20), a horizontal scrollbar (control.horizontal_scroll) along `scrollbar`, OK (button.ok)
/// and Cancel (button.cancel) at their hotspots' corners. Texts black with the (200,200,200) halo,
/// centred, top-aligned.
extension Renderer {
    var splitLayout: LayerFile? { ui?.dialog("split_creatures") }

    /// The army screen's split button (Single_Split_Button, button.split_Single): the chosen stack
    /// into the split dialog, if it has more than one creature and the army has a free place.
    func armySplitClick(_ i: Int, x: Float, y: Float) -> Bool {
        guard let g = game, i < g.heroes.count, let d = ui?.dialog("army.layout"), let b = d["Single_Split_Button"] else { return false }
        let (ox, oy) = dialogOrigin800
        let (w, h) = dButtonSize("split_Single")
        guard DRect(ox + b.x, oy + b.y, max(w, b.width), max(h, b.height)).contains(x, y) else { return false }
        let leader = g.heroes[i]
        let heroes = 1 + leader.companions.count
        let k = heroShown - heroes
        guard k >= 0, k < leader.army.count, leader.army[k].count > 1, heroes + leader.army.count < Hero.armySlots else { return true }
        openSplit(leader, stack: k, at: (Int(x), Int(y)))
        return true
    }
    func openSplit(_ leader: Hero, stack: Int, at p: (Int, Int)) {
        let n = leader.army[stack].count
        let x = max(0, min(AdventureUI.width - 561, p.0 - 561 / 2)), y = max(0, min(AdventureUI.height - 432, p.1 - 432))
        splitDialog = SplitState(leader: leader, stack: stack, total: n, moved: n / 2, x: x, y: y)
        sound?.play("miscellaneous.button")
    }

    /// The scrollbar's pieces: the left arrow, the track, the right arrow, and the thumb's place.
    func splitScroll(_ s: SplitState, _ d: LayerFile) -> (bar: DRect, left: DRect, right: DRect, track: DRect, thumb: DRect)? {
        guard let sb = dRect(d, "scrollbar")?.offset(s.x, s.y), let hs = ui?.scrollControl(),
              let up = hs["Up_Released"], let dn = hs["Down_Released"], let th = hs["Thumb"] else { return nil }
        let left = DRect(sb.x, sb.y, up.width, up.height)
        let right = DRect(sb.x + sb.w - dn.width, sb.y, dn.width, dn.height)
        let track = DRect(left.x + left.w, sb.y, right.x - (left.x + left.w), max(up.height, dn.height))
        let span = max(1, track.w - th.width)
        let tx = track.x + (s.total > 0 ? span * s.moved / s.total : 0)
        return (sb, left, right, track, DRect(tx, sb.y + th.y, th.width, th.height))
    }

    func splitQuads() -> [Quad] {
        guard let s = splitDialog, let d = splitLayout, let ui = ui, s.stack < s.leader.army.count else { return [] }
        let st = s.leader.army[s.stack]
        let c = game?.tables?.creature(st.creature)
        var out = dImage(d, "split", "Background", s.x, s.y)
        let title = text("split_creatures.dialog", "Split %creatures").replacingOccurrences(of: "%creatures", with: c?.plural ?? st.creature)
        out += dText(title, dRect(d, "title"), font: dFont(41), halo: Renderer.halo200, s.x, s.y)
        for box in ["left_box", "right_box"] {
            if let l = dLayer(d, box) { out += creatureModelQuads(st.creature, box: l, s.x, s.y) }
        }
        out += dText("\(s.total - s.moved)", dRect(d, "source_number"), font: dFont(20), halo: Renderer.halo200, s.x, s.y)
        out += dText("\(s.moved)", dRect(d, "dest_number"), font: dFont(20), halo: Renderer.halo200, s.x, s.y)
        if let sc = splitScroll(s, d), let hs = ui.scrollControl() {
            if let bg = hs["Background"], bg.width > 0 {
                var x = sc.track.x
                while x < sc.track.x + sc.track.w {
                    let w = min(bg.width, sc.track.x + sc.track.w - x)
                    out.append(Quad(texture: uiTexture("dk|hscroll|bg|\(w)", {
                        var b = Bitmap(width: w, height: bg.height)
                        for yy in 0..<bg.height { for xx in 0..<w { for k in 0..<4 { b.pixels[(yy * w + xx) * 4 + k] = bg.bitmap.pixels[(yy * bg.width + xx) * 4 + k] } } }
                        return b
                    }), x: x, y: sc.track.y + bg.y, w: w, h: bg.height))
                    x += w
                }
            }
            out += dImageAt(hs["Up_Released"], "hscroll", x: sc.left.x, y: sc.left.y)
            out += dImageAt(hs["Down_Released"], "hscroll", x: sc.right.x, y: sc.right.y)
            out += dImageAt(hs["Thumb"], "hscroll", x: sc.thumb.x, y: sc.thumb.y)
        }
        if let ok = dRect(d, "ok_button") { out += dButton("ok", "Released", x: s.x + ok.x, y: s.y + ok.y) }
        if let cb = dRect(d, "cancel_button") { out += dButton("cancel", "Released", x: s.x + cb.x, y: s.y + cb.y) }
        return out
    }

    /// A click (or a drag on the bar) with the split dialog open; it takes every click.
    func splitClick(x: Float, y: Float, drag: Bool = false) {
        guard var s = splitDialog, let d = splitLayout, let sc = splitScroll(s, d) else { splitDialog = nil; return }
        if !drag, DRect(sc.left.x, sc.left.y, sc.left.w, sc.left.h).contains(x, y) { s.moved = max(0, s.moved - 1) }
        else if !drag, sc.right.contains(x, y) { s.moved = min(s.total, s.moved + 1) }
        else if DRect(sc.track.x, sc.bar.y, sc.track.w, sc.bar.h).contains(x, y) {
            let span = max(1, sc.track.w - sc.thumb.w)
            let v = (x - Float(sc.track.x) - Float(sc.thumb.w) / 2) / Float(span)
            s.moved = max(0, min(s.total, Int((v * Float(s.total)).rounded())))
        } else if drag { return }
        else if let ok = dRect(d, "ok_button"), DRect(s.x + ok.x, s.y + ok.y, 76, 44).contains(x, y) {
            if s.moved > 0, s.stack < s.leader.army.count {
                let st = s.leader.army[s.stack]
                if s.moved >= st.count { s.leader.army.remove(at: s.stack) } else { s.leader.army[s.stack].count -= s.moved }
                s.leader.army.append(Hero.Stack(creature: st.creature, count: s.moved))
            }
            sound?.play("miscellaneous.button"); splitDialog = nil; return
        } else if let cb = dRect(d, "cancel_button"), DRect(s.x + cb.x, s.y + cb.y, 76, 44).contains(x, y) {
            sound?.play("miscellaneous.button"); splitDialog = nil; return
        }
        splitDialog = s
    }
    func splitKey(_ code: UInt16) -> Bool {
        guard splitDialog != nil else { return false }
        if code == 53 { splitDialog = nil }
        if code == 36 || code == 76, let s = splitDialog, let d = splitLayout, let ok = dRect(d, "ok_button") {
            splitClick(x: Float(s.x + ok.x + 5), y: Float(s.y + ok.y + 5))
        }
        return true
    }
}
