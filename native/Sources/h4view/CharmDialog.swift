import Foundation
import H4Engine

/// The Charm / Diplomacy offer (ctor 0x699960, strings registered by 0x698ca0;
/// re/neutral_encounter_spec.md §2), centred on the adventure frame. One offer:
/// layers.dialog.charm_or_diplomacy with the Title "Charm" (no Diplomacy offer) or "Diplomacy";
/// both: layers.dialog.charm_and_diplomacy, no title. The text (font 20, centred):
/// diplomacy.charmdialog (%material = the cost), charm.charmdialog, or charm_and_diplomacy.charmdialog.
/// Diplomacy's part (0x69a9d0): Gold, Gold_Background, the cost "%i" in gold_text (font of its
/// height, centred), the skill's 82-px icon at Diplomacy, its creatures as rings in
/// diplomacy_creatures, buy_button (disabled when the gold is short). Charm's part (0x69b400): the
/// icon at Charm, its creatures in charm_creatures, ok_button. close_button refuses.
extension Renderer {
    func charmDialogFile(_ o: GameState.JoinOffer) -> LayerFile? {
        ui?.dialog(o.charm.isEmpty || o.diplomacy.isEmpty ? "charm_or_diplomacy" : "charm_and_diplomacy")
    }
    func charmOrigin(_ d: LayerFile) -> (Int, Int) {
        let w = d.layers.map { $0.x + $0.width }.max() ?? 557, h = d.layers.map { $0.y + $0.height }.max() ?? 560
        return ((AdventureUI.width - w) / 2, (AdventureUI.height - h) / 2)
    }
    /// The buttons there are: (hotspot, button file, answer, enabled).
    func charmButtons(_ o: GameState.JoinOffer) -> [(spot: String, file: String, pick: Int, enabled: Bool)] {
        var out: [(spot: String, file: String, pick: Int, enabled: Bool)] = [("close_button", "close", 0, true)]
        if !o.diplomacy.isEmpty { out.append(("buy_button", "buy", 2, (game?.resources["Gold"] ?? 0) >= o.cost)) }
        if !o.charm.isEmpty { out.append(("ok_button", "ok", 1, true)) }
        return out
    }

    func charmDialogQuads() -> [Quad] {
        guard let g = game, let o = g.pendingJoin, let d = charmDialogFile(o) else { return [] }
        let (ox, oy) = charmOrigin(d)
        var out: [Quad] = []
        for n in ["Top", "Left", "Right", "Bottom", "Background"] { out += dImage(d, "charm", n, ox, oy) }
        let both = !o.charm.isEmpty && !o.diplomacy.isEmpty
        if !both {
            out += dText(o.diplomacy.isEmpty ? text("charm_title.charmdialog", "Charm") : text("diplomacy_title.charmdialog", "Diplomacy"),
                         dRect(d, "Title"), font: dFont(20), centre: true, vcentre: true, ox, oy)
        }
        let material = "\(o.cost) gold"
        let body = both ? text("charm_and_diplomacy.charmdialog", "You can use either Charm or Diplomacy to sway the hostile creatures to your side.  Which creatures do you want?")
            : o.charm.isEmpty ? text("diplomacy.charmdialog", "Your diplomatic skills have swayed some of the hostile creatures to join you in exchange for %material.  Do you accept the new recruits?").replacingOccurrences(of: "%material", with: material)
            : text("charm.charmdialog", "Your powers of persuasion have swayed some of the hostile creatures to join you.  Do you accept the new recruits?")
        out += dText(body, dRect(d, "text"), font: dFont(20), centre: true, ox, oy)
        func part(_ skill: String, _ level: Int, icon: String, rings: String, _ stacks: [Hero.Stack]) {
            if let r = dRect(d, icon), let id = RuleTables.skillIds.firstIndex(of: skill) {
                let sheet = iconSheet("skills.\(Renderer.primarySheets[RuleTables.primary(of: id)]).82")
                for l in [sheet[skill], level >= 1 ? sheet[["advanced", "expert", "master", "grandmaster"][level - 1]] : nil].compactMap({ $0 }) {
                    out += dImageAt(l, "skill82", x: ox + r.x + l.x, y: oy + r.y + l.y)
                }
            }
            guard let origin = dRect(d, rings), let sel = dFile("control.creature_select"), let ring = sel["Ring_Released"] else { return }
            for (k, s) in stacks.enumerated() {
                guard let pos = sel["hero_\(k + 1)_of_\(stacks.count)"] else { continue }
                let bx = ox + origin.x + pos.x, by = oy + origin.y + pos.y
                if let hi = sel["hero_icon"], let p = ui?.creatureIcon(s.creature, size: 52) { out += dImageAt(p, "icon52", x: bx + hi.x - ring.x, y: by + hi.y - ring.y) }
                out += dImageAt(ring, "creature_select", x: bx, y: by)
                if let inset = sel["inset"], let box = sel["inset_text"] {
                    out += dImageAt(inset, "creature_select", x: bx + inset.x - ring.x, y: by + inset.y - ring.y)
                    out += dText("\(s.count)", DRect(bx + box.x - ring.x, by + box.y - ring.y, box.width, box.height), font: dFont(13), centre: true, 0, 0)
                }
            }
        }
        if !o.diplomacy.isEmpty {
            for n in ["Gold", "Gold_Background"] { out += dImage(d, "charm", n, ox, oy) }
            let r = dRect(d, "gold_text")
            out += dText("\(o.cost)", r, font: dFont(r?.h ?? 19), centre: true, ox, oy)
            part("diplomacy", o.diplomacyLevel, icon: "Diplomacy", rings: "diplomacy_creatures", o.diplomacy)
        }
        if !o.charm.isEmpty { part("charm", o.charmLevel, icon: "Charm", rings: "charm_creatures", o.charm) }
        for b in charmButtons(o) {
            guard let r = dRect(d, b.spot) else { continue }
            let over = hoverButton((ox + r.x, oy + r.y, r.w, r.h))
            out += dButton(b.file, !b.enabled ? "Disabled" : over ? "Highlighted" : "Released", x: ox + r.x, y: oy + r.y)
        }
        return out
    }

    /// A click with the offer up (modal): an enabled button answers it.
    func charmDialogClick(x: Float, y: Float) -> Bool {
        guard let g = game, let o = g.pendingJoin else { return false }
        guard let d = charmDialogFile(o) else { g.resolveJoin(0); return true }
        let (ox, oy) = charmOrigin(d)
        for b in charmButtons(o) where b.enabled && dRect(d, b.spot)?.offset(ox, oy).contains(x, y) == true {
            g.resolveJoin(b.pick)
            break
        }
        return true
    }
}
