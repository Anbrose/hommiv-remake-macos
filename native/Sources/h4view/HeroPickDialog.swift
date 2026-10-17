import Foundation
import H4Engine

/// The hero pick of an altar (t_dialog_altar 0x66cf80, layers.dialog.altars 560x500) or a magic gem
/// (t_dialog_magic_gem 0x6c0250, layers.dialog.pick_hero 560x560), centred (re/altar_gem_spec.md):
/// Background; the object's name in Title and its text in Text (altar 20, gem 18; black, centred);
/// the gift's picture: an altar's 82-px skill icon at basic in Icon under button.skill_frame's
/// Released (its `icon` box on Icon), a gem's layers.icons.stats.82 image at Icon_Frame; its caption
/// in Icon_Text, centred both ways (the altar's skill name in box height / 2, a gem's "+6" / "+2" in
/// the box height); the heroes as control.creature_select rings at hero_i_of_n inside Hero_Rings
/// (52-px portrait, Ring_Pressed on the chosen one, Ring_Disabled on one that cannot be chosen; the
/// first enabled ring is chosen on opening); OK and Cancel at their hotspots.
extension Renderer {
    private var heroPickFile: LayerFile? {
        guard let hp = game?.heroPick else { return nil }
        if case .altar = hp.kind { return dFile("Dialog.Altars") ?? dFile("dialog.altars") }
        return dFile("Dialog.pick_hero") ?? dFile("dialog.pick_hero")
    }
    private func heroPickOrigin(_ d: LayerFile) -> (Int, Int) {
        let bg = dLayer(d, "Background")
        let w = bg.map { $0.x + $0.width } ?? 560, h = bg.map { $0.y + $0.height } ?? 500
        return ((AdventureUI.width - w) / 2, (AdventureUI.height - h) / 2)
    }
    /// The chosen ring: the one picked, else the first enabled one (0x650910 then 0x650880).
    func heroPickChosen(_ hp: HeroPick) -> Int? {
        if let k = heroPickSelected, k < hp.heroes.count, hp.enabled[k] { return k }
        return hp.enabled.firstIndex(of: true)
    }
    /// Each ring's window: its top-left at hero_i_of_n (control.creature_select) inside Hero_Rings.
    private func heroPickRings(_ hp: HeroPick, _ d: LayerFile, _ ox: Int, _ oy: Int) -> [DRect] {
        guard let area = dRect(d, "Hero_Rings"), let sel = dFile("control.creature_select") else { return [] }
        let n = min(hp.heroes.count, 7)
        return (0..<n).compactMap { k in dRect(sel, "hero_\(k + 1)_of_\(n)").map { DRect(ox + area.x + $0.x, oy + area.y + $0.y, $0.w, $0.h) } }
    }

    func heroPickQuads() -> [Quad] {
        guard let g = game, let hp = g.heroPick, let ui = ui, let d = heroPickFile else { return [] }
        let (ox, oy) = heroPickOrigin(d)
        var out = dImage(d, "heropick", "Background", ox, oy)
        // the rings
        if let sel = dFile("control.creature_select"), let ring = dLayer(sel, "Ring_Released") {
            let chosen = heroPickChosen(hp)
            for (k, r) in heroPickRings(hp, d, ox, oy).enumerated() {
                let h = hp.heroes[k]
                if let hi = dLayer(sel, "hero_icon"), let p = ui.portrait(keyword: h.keyword, alignment: h.alignment, size: 52) {
                    out += dImageAt(p, "portrait52.\(h.alignment)", x: r.x + hi.x - ring.x, y: r.y + hi.y - ring.y)
                }
                let state = !hp.enabled[k] ? "Ring_Disabled" : k == chosen ? "Ring_Pressed" : "Ring_Released"
                out += dImageAt(dLayer(sel, state) ?? ring, "creature_select", x: r.x, y: r.y)
            }
        }
        // the gift's picture and caption
        switch hp.kind {
        case .altar(let s):
            if let icon = dRect(d, "Icon") {
                for l in largeSkillIcon(s, level: 1) { out += dImageAt(l, "skill82.\(s)", x: ox + icon.x + l.x, y: oy + icon.y + l.y) }
                let sf = dFile("button.skill_frame")
                let box = dRect(sf, "icon") ?? DRect(18, 17, 82, 82)
                out += dImageOffset(dLayer(sf, "Released"), "skillframe", x: ox + icon.x - box.x, y: oy + icon.y - box.y)
            }
            let r = dRect(d, "Icon_Text")
            let name = g.tables?.strings["\(Renderer.skillStringKeys[s]).skill"] ?? skillName(s, level: 1).name
            out += dText(name, r, font: dFont((r?.h ?? 34) / 2), vcentre: true, ox, oy)
            out += dText(hp.title, dRect(d, "Title"), font: dFont(20), ox, oy)
            out += dText(hp.text, dRect(d, "Text"), font: dFont(20), ox, oy)
        case .gem(let kind):
            let icons = ["spell_points", "melee_defense", "melee_attack", "speed"]
            if let f = dRect(d, "Icon_Frame"), let l = iconSheet("stats.82")[icons[min(kind, 3)]] {
                out += dImageAt(l, "stats82", x: ox + f.x + l.x, y: oy + f.y + l.y)
            }
            let r = dRect(d, "Icon_Text")
            out += dText(kind == 3 ? "+2" : "+6", r, font: dFont(r?.h ?? 34), vcentre: true, ox, oy)
            out += dText(hp.title, dRect(d, "Title"), font: dFont(18), ox, oy)
            out += dText(hp.text, dRect(d, "Text"), font: dFont(18), ox, oy)
        }
        for (name, file) in [("OK_Button", "ok"), ("Cancel_button", "cancel")] {
            guard let b = dRect(d, name) else { continue }
            let (w, h) = dButtonSize(file)
            let over = DRect(ox + b.x, oy + b.y, w, h).contains(pointerCanvas.0, pointerCanvas.1)
            out += dButton(file, over ? "Highlighted" : "Released", x: ox + b.x, y: oy + b.y)
        }
        return out
    }

    /// A click with the dialog open (it takes every click): a ring chooses its hero, OK gives the
    /// gift to the chosen hero, Cancel leaves the object as it is.
    func heroPickClick(x: Float, y: Float) -> Bool {
        guard let g = game, let hp = g.heroPick, let d = heroPickFile else { return false }
        let (ox, oy) = heroPickOrigin(d)
        for (k, r) in heroPickRings(hp, d, ox, oy).enumerated() where r.contains(x, y) {
            if hp.enabled[k] { heroPickSelected = k }
            return true
        }
        func on(_ name: String, _ file: String) -> Bool {
            guard let b = dRect(d, name) else { return false }
            let (w, h) = dButtonSize(file)
            return DRect(ox + b.x, oy + b.y, max(w, b.w), max(h, b.h)).contains(x, y)
        }
        if on("OK_Button", "ok"), let k = heroPickChosen(hp) {
            sound?.play("miscellaneous.button")
            g.heroPick = nil; heroPickSelected = nil
            hp.ok(hp.heroes[k])
        } else if on("Cancel_button", "cancel") {
            sound?.play("miscellaneous.button")
            g.heroPick = nil; heroPickSelected = nil
        }
        return true
    }
    /// The balloons: a ring's hero name, OK (shared.accept), Cancel (shared.cancel), the gem's stat.
    func heroPickTip(x: Float, y: Float) -> String? {
        guard let hp = game?.heroPick, let d = heroPickFile else { return nil }
        let (ox, oy) = heroPickOrigin(d)
        for (k, r) in heroPickRings(hp, d, ox, oy).enumerated() where r.contains(x, y) { return hp.heroes[k].name }
        if let b = dRect(d, "OK_Button"), b.offset(ox, oy).contains(x, y) { return interfaceText("shared", "accept")?.balloon }
        if let b = dRect(d, "Cancel_button"), b.offset(ox, oy).contains(x, y) { return interfaceText("shared", "cancel")?.balloon }
        if case .gem(let kind) = hp.kind, let f = dRect(d, "Icon_Frame"), f.offset(ox, oy).contains(x, y) {
            return interfaceText("shared", ["spell_points", "defense_skill", "attack_skill", "speed"][min(kind, 3)])?.balloon
        }
        return nil
    }
    /// strings.Text keys of the plain skill names (0x8547c0: "Tactics.skill", ...), by primary.
    static let skillStringKeys = ["Tactics", "Toughness", "Scouting", "Nobility", "Life_Magic", "Order_Magic", "Death_Magic", "Chaos_Magic", "Nature_Magic"]
}
