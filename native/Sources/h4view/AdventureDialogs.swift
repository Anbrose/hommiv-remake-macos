import Foundation
import Metal
import H4Engine

/// Dialogs over the adventure map.
enum AdventureDialog {
    case chest                  // layers.dialog.treasure_chest: keep the gold or take experience
    case hero(Int)              // layers.dialog.army.layout: the hero screen for game.heroes[i]
}

extension Renderer {
    /// The panel's button column (layers.button.<name> at the adventure.1024 hotspots).
    static let panelButtons: [(hotspot: String, button: String)] = [
        ("System_menu_button", "system_menu"), ("Game_menu_button", "game_menu"), ("underground_button", "underground"),
        ("spell_button", "spell"), ("move_army_button", "move_army"), ("Marketplace_button", "marketplace"), ("overview_button", "overview")]

    func panelButtonQuads() -> [Quad] {
        guard let ui = ui, let g = game else { return [] }
        var out: [Quad] = []
        for (hs, name) in Renderer.panelButtons {
            guard let slot = ui.hotspot(hs) else { continue }
            let btn = name == "underground" && g.map.levels < 2 ? "surface" : name
            let state = (name == "underground" && g.map.levels < 2) || name == "spell" || name == "marketplace" ? "Disabled" : "Released"
            guard let b = ui.button(btn, state: state) ?? ui.button(btn) else { continue }
            out.append(Quad(texture: uiTexture("button|\(btn)|\(state)", { b.bitmap }), x: slot.x + (slot.width - b.width) / 2, y: slot.y + (slot.height - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }

    /// Texts floating up over the map (pickups): started when the game reports them.
    func collectFloaters(now: Date) {
        guard let g = game else { return }
        for f in g.floaters { floaters.append((f.text, f.x, f.y, now)) }
        g.floaters.removeAll()
        floaters.removeAll { now.timeIntervalSince($0.since) > 2 }
        if g.chestOffer != nil, adventureDialog == nil { adventureDialog = .chest }
    }
    func floaterQuads() -> [Quad] {
        guard let ui = ui else { return [] }
        let now = Date()
        var out: [Quad] = []
        for f in floaters {
            let age = Float(now.timeIntervalSince(f.since))
            let (sx, sy) = screen(Float(f.x), Float(f.y))
            let canvasX = (sx - pan.x) * zoom / uiScale, canvasY = (sy - 40 - age * 18 - pan.y) * zoom / uiScale
            let w = ui.dateFont.measure(f.text)
            out.append(Quad(texture: uiTexture("date|\(f.text)|white", { ui.dateFont.render(f.text, colour: (255, 255, 255)) }), x: Int(canvasX) - w / 2, y: Int(canvasY), w: w, h: ui.dateFont.size))
        }
        return out
    }

    func adventureDialogQuads() -> [Quad] {
        guard let dlg = adventureDialog, let ui = ui, let g = game else { return [] }
        var out: [Quad] = []
        switch dlg {
        case .chest:
            guard let d = ui.dialog("treasure_chest"), let offer = g.chestOffer else { return [] }
            let ox = (AdventureUI.width - 404) / 2, oy = (AdventureUI.height - 457) / 2
            out += dialogImages(d, key: "chest", at: ox, oy, skip: ["Experience_Highlighted", "gold_highlighted", "gold_pressed", "Experience_Pressed"])
            out += centred("Treasure Chest", in: d["Title"], at: ox, oy, font: ui.dateFont)
            let text = g.tables?.objectText("treasure", "treasure_chest", "Initial") ?? "Keep the gold, or give it away for experience?"
            if let l = d["dialog_text"] {   // inset from the scroll's rollers
                let inner = UILayer(name: l.name, kind: 1, x: l.x + 18, y: l.y + 8, width: l.width - 36, height: l.height - 8, bitmap: l.bitmap)
                out += paragraph(text, in: inner, at: ox, oy, font: ui.numberFont)
            }
            if let icon = materialIcon("Gold", size: 64), let slot = d["gold_icon"] {
                out.append(Quad(texture: uiTexture("mat64|Gold", { icon.bitmap }), x: ox + slot.x + (slot.width - icon.width) / 2, y: oy + slot.y + 10, w: icon.width, h: icon.height))
            }
            out += centred("\(offer.gold) gold", in: d["gold_label"], at: ox, oy, font: ui.numberFont)
            out += centred("\(offer.experience) exp.", in: d["experience_label"], at: ox, oy, font: ui.numberFont)
            if let sel = chestChoice, let hl = d[sel ? "gold_highlighted" : "Experience_Highlighted"] {
                out.append(Quad(texture: uiTexture("dlg|chest|\(hl.name)", { hl.bitmap }), x: ox + hl.x, y: oy + hl.y, w: hl.width, h: hl.height))
            }
            if let ok = d["ok_button"], let b = ui.button("ok", state: chestChoice == nil ? "Disabled" : "Released") {
                out.append(Quad(texture: uiTexture("button|ok|\(b.name)", { b.bitmap }), x: ox + ok.x + (ok.width - b.width) / 2, y: oy + ok.y + (ok.height - b.height) / 2, w: b.width, h: b.height))
            }
        case .hero(let i):
            guard i < g.heroes.count, let d = ui.dialog("army.layout") else { return [] }
            let h = g.heroes[i]
            let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
            out += dialogImages(d, key: "army", at: ox, oy, skip: ["Ring_Pressed", "Move_Army_Up", "Move_Army_Down", "Move_Tombstone_up", "loose_pressed", "loose_Disabled", "tight_Pressed", "tight_Disabled", "square_Pressed", "square_Disabled", "Up_Disabled"])
            // the class picture with the equipment slots, inside the inventory area
            if let inv = d["hero_inventory"], let cls = ui.dialog("army.\(h.alignment)_might_male"), let bg = cls["Background"] {
                out.append(Quad(texture: uiTexture("dlg|army|\(h.alignment)|bg", { bg.bitmap }), x: ox + inv.x + (inv.width - bg.width) / 2, y: oy + inv.y + (inv.height - bg.height) / 2, w: bg.width, h: bg.height))
            }
            if let slot = d["creature_portrait"], let p = ui.portrait(keyword: h.keyword, alignment: h.alignment, size: 82) {
                out.append(Quad(texture: uiTexture("portrait82|\(h.alignment)|\(h.keyword)", { p.bitmap }), x: ox + slot.x + (slot.width - p.width) / 2, y: oy + slot.y + (slot.height - p.height) / 2, w: p.width, h: p.height))
            }
            out += centred(h.name, in: d["name_text"], at: ox, oy, font: ui.dateFont)
            let cls = RuleTables.classes[h.alignment]?.might.capitalized ?? "Knight"
            out += centred("Level \(h.level) \(cls)", in: d["class_text"], at: ox, oy, font: ui.dateFont)
            let s = g.heroStats(h)
            let values: [(String, String)] = [("Damage_Text", s.damage), ("Hit_Points_Text", "\(s.hitPoints)"), ("Melee_Attack_Text", "\(s.attack)"), ("Melee_Defense_Text", "\(s.defense)"),
                                              ("Ranged_Attack_Text", "\(s.attack)"), ("Ranged_Defense_Text", "\(s.defense)"), ("Speed_Text", "\(s.speed)"), ("Move_Text", "\(s.move)"),
                                              ("Experience_Text", "\(h.experience)"), ("Spell_Points_Text", "0"), ("Shots_Text", "0"), ("Morale_Text", "0"), ("Luck_Text", "0")]
            for (slot, v) in values { out += centred(v, in: d[slot], at: ox, oy, font: ui.numberFont) }
            // the army in the seven circles (the hero first), counts under the icons
            if let circles = d["creature_circles"] {
                var slots: [(UILayer?, String)] = [(ui.portrait(keyword: h.keyword, alignment: h.alignment), "")]
                slots += h.army.map { (ui.creatureIcon($0.creature), String($0.count)) }
                let step = circles.width / 7
                for (k, (icon, count)) in slots.prefix(7).enumerated() {
                    let cx = ox + circles.x + step * k + step / 2, cy = oy + circles.y + circles.height / 2
                    if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2 - 6, w: icon.width, h: icon.height)) }
                    if !count.isEmpty {
                        let w = ui.numberFont.measure(count)
                        out.append(Quad(texture: shade, x: cx - w / 2 - 4, y: cy + 22, w: w + 8, h: ui.numberFont.size + 2))
                        out.append(Quad(texture: uiTexture("count|\(count)", { ui.numberFont.render(count, colour: (255, 236, 200)) }), x: cx - w / 2, y: cy + 23, w: w, h: ui.numberFont.size))
                    }
                }
            }
            if let ok = d["ok_button"], let b = ui.button("ok") {
                out.append(Quad(texture: uiTexture("button|ok|\(b.name)", { b.bitmap }), x: ox + ok.x + (ok.width - b.width) / 2, y: oy + ok.y + (ok.height - b.height) / 2, w: b.width, h: b.height))
            }
        }
        return out
    }

    /// A click while an adventure dialog is open. Returns true when handled.
    func adventureDialogClick(x: Float, y: Float) -> Bool {
        guard let dlg = adventureDialog, let ui = ui, let g = game else { return false }
        switch dlg {
        case .chest:
            let ox = (AdventureUI.width - 404) / 2, oy = (AdventureUI.height - 457) / 2
            guard let d = ui.dialog("treasure_chest") else { adventureDialog = nil; return true }
            if inside(d["gold_released"], at: ox, oy, x, y) || inside(d["gold_icon"], at: ox, oy, x, y) { chestChoice = true }
            else if inside(d["Experience_Released"], at: ox, oy, x, y) || inside(d["experience_icon"], at: ox, oy, x, y) { chestChoice = false }
            else if inside(d["ok_button"], at: ox, oy, x, y), let c = chestChoice { g.resolveChest(gold: c); chestChoice = nil; adventureDialog = nil }
            return true
        case .hero:
            let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
            if let d = ui.dialog("army.layout"), inside(d["ok_button"], at: ox, oy, x, y) { adventureDialog = nil }
            else if x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 600) { adventureDialog = nil }
            return true
        }
    }
}
