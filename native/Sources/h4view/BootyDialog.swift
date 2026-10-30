import Foundation
import AppKit
import H4Engine

/// The "Spoils of War" dialog (t_dialog_booty, heroes4.exe ctor 0x674e90; re/booty_spec.md),
/// layers.dialog.booty (600x482, centred [inferred: 0x720c80 run without a position]):
/// Background at its box; "post_combat_booty_title" in font 20 at Title, the singular / plural
/// text in font 16 at Text, both black, centred, no halo (0x8859f0, +0xc4 = 1, 0x886b10(0));
/// button.ok at OK_Button (0x5a0010; help booty/ok; Enter, 0x7d2970(0xd)); the winning army's ring
/// row at Creature_Rings (t_creature_array_window 0x6439c0); the artifact places Icon_1..5 --
/// only those the table 0x985bcb marks for min(n, 5) artifacts (1: 3; 2: 2, 4; 3: 2-4; 4: 2-5;
/// 5: all) -- each a layers.button.frame_44 frame (Released, or Highlighted on the place whose
/// artifact is in hand) with the artifact (t_artifact_icon 0x705fa0) in the frame's `icon` box;
/// Left / Right (0x5a2250) while more than 5 are left, scrolling by one (0x676120 / 0x676140).
/// The places show list[first...] in order, skipping none (0x676190); an emptied list closes it.
struct BootyView {
    let booty: ObjectIdentifier
    /// The Icon_<n> places in use (1-based), fixed when the dialog opens.
    let places: [Int]
    var first = 0
    /// The artifact pressed (its list index) and, once the pointer moved, where it is carried.
    var pressed: Int? = nil
    var at: (Float, Float)? = nil
    /// 0x985bcb: which of the 5 places n (<= 5) artifacts use.
    static let mask: [[Int]] = [[], [3], [2, 4], [2, 3, 4], [2, 3, 4, 5], [1, 2, 3, 4, 5]]
}

extension Renderer {
    func bootyFile() -> LayerFile? { dFile("dialog.booty") }
    var bootyOrigin: (Int, Int) {
        let bg = dLayer(bootyFile(), "Background")
        return ((AdventureUI.width - (bg?.width ?? 600)) / 2, (AdventureUI.height - (bg?.height ?? 482)) / 2)
    }
    /// The dialog's view of the game's open spoils (made when they first show).
    func bootyState() -> (Booty, BootyView)? {
        guard let b = game?.booty else { bootyView = nil; return nil }
        if bootyView?.booty != ObjectIdentifier(b) { bootyView = BootyView(booty: ObjectIdentifier(b), places: BootyView.mask[min(5, b.artifacts.count)]) }
        guard var v = bootyView else { return nil }
        v.first = max(0, min(v.first, b.artifacts.count - 5))   // 0x676190
        bootyView = v
        return (b, v)
    }
    /// What each place shows (0x676190): its list index, nil when empty; true when its artifact is in hand.
    func bootyPlaces(_ b: Booty, _ v: BootyView) -> [(place: Int, index: Int?, held: Bool)] {
        var k = v.first
        return v.places.map { p in
            defer { k += 1 }
            if k < b.artifacts.count, k != (v.at != nil ? v.pressed : nil) { return (p, k, false) }
            return (p, nil, k < b.artifacts.count)
        }
    }
    func bootyRing() -> [(piece: String, fx: Int, fy: Int)] {
        let (ox, oy) = bootyOrigin
        guard let r = dRect(bootyFile(), "Creature_Rings") else { return [] }
        return ringRow(x: ox + r.x, y: oy + r.y)
    }
    /// The artifact box of a place: the frame's `icon` box at the Icon_<n> corner.
    func bootyIconRect(_ place: Int) -> DRect? {
        let (ox, oy) = bootyOrigin
        guard let p = dRect(bootyFile(), "Icon_\(place)") else { return nil }
        let ib = dRect(dFile("Button.Frame_44") ?? dFile("button.frame_44"), "icon") ?? DRect(10, 9, 49, 49)
        return DRect(ox + p.x + ib.x, oy + p.y + ib.y, ib.w, ib.h)
    }

    func bootyQuads() -> [Quad] {
        guard let (b, v) = bootyState(), let d = bootyFile(), let ui = ui else { return [] }
        let (ox, oy) = bootyOrigin
        var out = dImage(d, "booty", "Background", ox, oy)
        out += dText(text("post_combat_booty_title", "Spoils of War"), dRect(d, "Title"), font: dFont(20), ox, oy)
        let body = b.artifacts.count == 1
            ? text("post_combat_booty_text_singular", "You have captured an artifact from your enemy.")
            : text("post_combat_booty_text_plural", "You have captured some artifacts from your enemy.")
        out += dText(body, dRect(d, "Text"), font: dFont(16), ox, oy)
        let frame = dFile("Button.Frame_44") ?? dFile("button.frame_44")
        for s in bootyPlaces(b, v) {
            guard let p = dRect(d, "Icon_\(s.place)") else { continue }
            out += dImageOffset(dLayer(frame, s.held ? "Highlighted" : "Released"), "frame44", x: ox + p.x, y: oy + p.y)
            if let k = s.index, let r = bootyIconRect(s.place), let l = artifactIcon(b.artifacts[k]) {
                out += dImageAt(l, "art", x: r.x + (r.w - l.width) / 2, y: r.y + (r.h - l.height) / 2)
            }
        }
        if b.artifacts.count > 5 {
            out += dImage(d, "booty", "Left_Released", ox, oy).button()
            out += dImage(d, "booty", "Right_Released", ox, oy).button()
        }
        if let r = dRect(d, "OK_Button") { out += dButton("ok", "Released", x: ox + r.x, y: oy + r.y) }
        out += ringRowQuads(bootyRing(), items: ringItems(b.army), selected: nil)
        // the artifact in hand: centred on the pointer (t_drag_artifact)
        if let k = v.pressed, let at = v.at, k < b.artifacts.count, let l = artifactIcon(b.artifacts[k]) {
            out.append(Quad(texture: uiTexture("art|\(b.artifacts[k])", { l.bitmap }), x: Int(at.0) - l.width / 2, y: Int(at.1) - l.height / 2, w: l.width, h: l.height))
        }
        _ = ui
        return out + heldHelpQuads()
    }

    /// The place under the pointer with an artifact in it.
    func bootyPlace(at x: Float, _ y: Float) -> (place: Int, index: Int)? {
        guard let (b, v) = bootyState() else { return nil }
        for s in bootyPlaces(b, v) { if let k = s.index, bootyIconRect(s.place)?.contains(x, y) == true { return (s.place, k) } }
        return nil
    }
    /// A press: on an artifact it may be carried off (the drag starts once the pointer moves).
    func bootyPress(x: Float, y: Float) {
        guard bootyState() != nil else { return }
        bootyView?.pressed = bootyPlace(at: x, y)?.index
        bootyView?.at = nil
    }
    func bootyDragged(x: Float, y: Float) {
        guard bootyView?.pressed != nil else { return }
        if bootyView?.at == nil { NSCursor.hide() }
        bootyView?.at = (x, y)
    }
    /// The release: a carried artifact goes to the hero whose portrait it is dropped on (0x676540),
    /// anywhere else back to its place (0x676520); a click works the buttons.
    func bootyRelease(x: Float, y: Float) {
        guard let (b, v) = bootyState(), let g = game, let d = bootyFile() else { return }
        bootyView?.pressed = nil; bootyView?.at = nil
        if let k = v.pressed, v.at != nil {
            NSCursor.unhide()
            let members = b.army.members
            for (n, slot) in bootyRing().enumerated() where n < members.count && DRect(slot.fx + 15, slot.fy + 15, 52, 52).contains(x, y) {
                if g.bootyGive(k, to: members[n]) { buttonClick() }
            }
            return
        }
        let (ox, oy) = bootyOrigin
        if let r = dRect(d, "OK_Button"), r.offset(ox, oy).contains(x, y) { buttonClick(); g.closeBooty(); return }
        if b.artifacts.count > 5 {
            if let r = dRect(d, "Left_Released"), r.offset(ox, oy).contains(x, y), v.first > 0 { buttonClick(); bootyView?.first -= 1 }
            if let r = dRect(d, "Right_Released"), r.offset(ox, oy).contains(x, y), v.first + 5 < b.artifacts.count { buttonClick(); bootyView?.first += 1 }
        }
    }
    /// Enter is Okay's hot key.
    func bootyKey(_ code: UInt16) -> Bool {
        guard game?.booty != nil else { return false }
        if code == 36 || code == 76 { buttonClick(); game?.closeBooty() }
        return true
    }
    /// A held right click on an artifact: its help text (t_artifact_icon, hero_artifacts_spec §9).
    func bootyRightDown(x: Float, y: Float) -> Bool {
        guard let b = game?.booty else { return false }
        guard let p = bootyPlace(at: x, y), let r = bootyIconRect(p.place) else { return true }
        let t = artifactName(b.artifacts[p.index])
        heldHelp = (t.help.isEmpty ? t.name : t.help, r.x + r.w / 2, r.y + r.h)
        return true
    }
    /// Balloons: the artifact's name, Okay.
    func bootyTip(x: Float, y: Float) -> String? {
        guard let b = game?.booty, let d = bootyFile() else { return nil }
        if let p = bootyPlace(at: x, y) { return artifactName(b.artifacts[p.index]).name }
        let (ox, oy) = bootyOrigin
        if let r = dRect(d, "OK_Button"), r.offset(ox, oy).contains(x, y) { return (interfaceText("booty", "ok") ?? interfaceText("shared", "ok"))?.balloon }
        return nil
    }
}
