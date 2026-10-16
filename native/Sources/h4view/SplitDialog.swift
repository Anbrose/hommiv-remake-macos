import Foundation
import H4Engine

/// The split dialog while open (t_split_creatures_dialog 0x872ef0): the creature, the two stacks'
/// total, how many the destination gets (bounded to 1 ... total - 1), where it sits, what OK does.
struct SplitState {
    var creature: String
    var total: Int
    var moved: Int          // the destination's count
    var x: Int, y: Int      // the dialog's top-left on the canvas
    var apply: (Int) -> Void
    var low: Int { 1 }
    var high: Int { max(1, total - 1) }
}
var splitDialog: SplitState?

/// Split creatures (t_split_creatures 0x872ef0, layers.dialog.split_creatures; object_dialogs_spec §5,
/// army_split_spec.md §3): opened when a stack dragged with Shift or in split mode is dropped on an
/// empty place or one of the same creature. The 561x432 frame opens above the pointer, centred on
/// it, clamped into the screen; Background, "Split %creatures" (34), the creature's model in
/// left_box and right_box, the counts left and moved (20), a horizontal scrollbar
/// (control.horizontal_scroll) along `scrollbar` from 1 to total - 1, paging by (range + 4) / 5,
/// OK (button.ok) and Cancel (button.cancel) at their hotspots' corners. Texts black with the
/// (200,200,200) halo, centred, top-aligned.
extension Renderer {
    var splitLayout: LayerFile? { ui?.dialog("split_creatures") }

    /// Open it for a drop: the destination starts at max(1, its count) (0x872fe7 / 0x87303a).
    func openSplit(creature: String, source: Int, destination: Int, at p: (Int, Int)? = nil, apply: @escaping (Int) -> Void) {
        let total = source + destination
        guard total >= 2 else { return }
        let at = p ?? (Int(pointerCanvas.0), Int(pointerCanvas.1))
        let x = max(0, min(AdventureUI.width - 561, at.0 - 561 / 2)), y = max(0, min(AdventureUI.height - 432, at.1 - 432))
        splitDialog = SplitState(creature: creature, total: total, moved: max(1, min(total - 1, destination)), x: x, y: y, apply: apply)
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
        let tx = track.x + (s.high > s.low ? span * (s.moved - s.low) / (s.high - s.low) : 0)
        return (sb, left, right, track, DRect(tx, sb.y + th.y, th.width, th.height))
    }

    func splitQuads() -> [Quad] {
        guard let s = splitDialog, let d = splitLayout, let ui = ui else { return [] }
        let c = game?.tables?.creature(s.creature)
        var out = dImage(d, "split", "Background", s.x, s.y)
        let title = text("split_creatures.dialog", "Split %creatures").replacingOccurrences(of: "%creatures", with: c?.plural ?? s.creature)
        out += dText(title, dRect(d, "title"), font: dFont(41), halo: Renderer.halo200, s.x, s.y)
        for box in ["left_box", "right_box"] {
            if let l = dLayer(d, box) { out += creatureModelQuads(s.creature, box: l, s.x, s.y) }
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
        let page = max(1, (s.high - s.low + 4) / 5)
        if !drag, DRect(sc.left.x, sc.left.y, sc.left.w, sc.left.h).contains(x, y) { s.moved = max(s.low, s.moved - 1) }
        else if !drag, sc.right.contains(x, y) { s.moved = min(s.high, s.moved + 1) }
        else if !drag, DRect(sc.track.x, sc.bar.y, sc.track.w, sc.bar.h).contains(x, y), !sc.thumb.contains(x, y) {
            s.moved = x < Float(sc.thumb.x) ? max(s.low, s.moved - page) : min(s.high, s.moved + page)   // the track pages
        }
        else if DRect(sc.track.x, sc.bar.y, sc.track.w, sc.bar.h).contains(x, y) {
            let span = max(1, sc.track.w - sc.thumb.w)
            let v = (x - Float(sc.track.x) - Float(sc.thumb.w) / 2) / Float(span)
            s.moved = max(s.low, min(s.high, s.low + Int((v * Float(s.high - s.low)).rounded())))
        } else if drag { return }
        else if let ok = dRect(d, "ok_button"), DRect(s.x + ok.x, s.y + ok.y, 76, 44).contains(x, y) {
            sound?.play("miscellaneous.button"); splitDialog = nil
            s.apply(s.moved)
            return
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
