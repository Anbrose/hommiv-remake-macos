import Foundation
import Metal
import H4Engine

/// Dialogs over the adventure map.
enum AdventureDialog {
    case chest                  // layers.dialog.treasure_chest: keep the gold or take experience
    case hero(Int)              // layers.dialog.army.layout: the hero screen for game.heroes[i]
}

extension Renderer {
    /// The panel's buttons (0x4aa200): hotspot, button file, help item (table.Interface adventure_map/<item>).
    static let panelButtons: [(hotspot: String, button: String, help: String)] = [
        ("System_menu_button", "system_menu", "system_menu"), ("Game_menu_button", "game_menu", "game_menu"),
        ("move_army_button", "move_army", "move_army"), ("overview_button", "overview", "kingdom_overview"),
        ("spell_button", "spell", "cast_spell"), ("Marketplace_button", "marketplace", "marketplace"),
        ("surface_button", "surface", "surface"), ("underground_button", "underground", "underground"), ("end_turn", "end_turn", "end_turn")]

    /// Each t_button window at its hotspot's top-left, the state image at its own box. States (0x4b59a0):
    /// move army needs an army, spell needs a caster; one level shows underground, disabled; two levels
    /// show the other level's button. End Turn gives way to the hourglass while it flips (0x4b2930).
    func panelButtonQuads() -> [Quad] {
        guard let ui = ui, let g = game else { return [] }
        var out: [Quad] = []
        let hero = g.heroes.first
        let canCast = hero.map { !$0.spells.isEmpty || !$0.artifactSpells.withSkill.isEmpty || !$0.artifactSpells.free.isEmpty } ?? false
        let flipping = endTurnFlip.map { Date().timeIntervalSince($0) < Double(hourglassFlip?.frames.count ?? 0) * 0.1 } ?? false
        var balloon: String?
        for (hs, name, help) in Renderer.panelButtons {
            guard let slot = frameLayer(ui, hs) else { continue }
            if name == "surface" && (g.map.levels < 2 || g.level == 0) { continue }
            if name == "underground" && g.map.levels >= 2 && g.level == 1 { continue }
            if name == "end_turn" && flipping {
                if let hg = hourglassFlip, let t0 = endTurnFlip {
                    let fr = hg.frames[min(hg.frames.count - 1, Int(Date().timeIntervalSince(t0) / 0.1))]
                    out.append(Quad(texture: uiTexture("hourglass|\(fr.name)", { fr.bitmap }), x: slot.x + fr.box.left - hg.frames[0].box.left, y: slot.y + fr.box.top - hg.frames[0].box.top, w: fr.bitmap.width, h: fr.bitmap.height))
                }
                continue
            }
            let disabled = (name == "underground" && g.map.levels < 2) || (name == "spell" && !canCast) || (name == "move_army" && hero == nil)
            let over = pointerCanvas.0 >= Float(slot.x) && pointerCanvas.0 < Float(slot.x + slot.width) && pointerCanvas.1 >= Float(slot.y) && pointerCanvas.1 < Float(slot.y + slot.height)
            let state = disabled ? "Disabled" : over ? "Highlighted" : "Released"
            if over, Date().timeIntervalSince(pointerSince) > 0.8 { balloon = g.tables?.interfaceTexts["adventure_map.\(help)"]?.balloon }
            guard let b = ui.button(name, state: state) ?? ui.buttonLayer(name, state) ?? ui.button(name) else { continue }
            out.append(Quad(texture: uiTexture("button|\(name)|\(b.name)", { b.bitmap }), x: slot.x + b.x, y: slot.y + b.y, w: b.width, h: b.height))
        }
        if let s = balloon, !s.isEmpty {   // the help balloon left of the pointer
            let f = ui.font(16), w = f.measure(s) + 12, h = f.size + 8, bx = Int(pointerCanvas.0) - w - 8, by = Int(pointerCanvas.1) - h - 4
            out += [Quad(texture: solid(20, 12, 4), x: bx - 1, y: by - 1, w: w + 2, h: h + 2), Quad(texture: solid(255, 252, 240), x: bx, y: by, w: w, h: h),
                    Quad(texture: uiTexture("dlgtext|16|\(s)|12", { f.render(s, colour: (12, 8, 4)) }), x: bx + 6, y: by + 4, w: w - 12, h: f.size)]
        }
        return out
    }

    /// Texts floating up over the map (pickups): started when the game reports them.
    func collectFloaters(now: Date) {
        guard let g = game else { return }
        for f in g.floaters { floaters.append((f.text, f.x, f.y, now)) }
        g.floaters.removeAll()
        floaters.removeAll { now.timeIntervalSince($0.since) > 2 }
        if g.chestOffer != nil, adventureDialog == nil { adventureDialog = .chest; chestChoice = true }   // gold is on at opening (0x5a2c00(0))
        // an object's yes/no question (a vein, the Tree of Knowledge) in the message box
        if let q = g.question, prompt == nil { prompt = (q.text, true, q.yes); g.question = nil }
        if let k = g.marketOpen { market = MarketState(k: k); g.marketOpen = nil }
        if let o = g.hireOpen { hire = o; g.hireOpen = nil }
        if let o = g.shopOpen { shop = ShopState(offer: o, panel: ui?.dialog("Blacksmith.\(o.panel)")); g.shopOpen = nil }
        if let o = g.sanctuaryOpen { sanctuary = o; g.sanctuaryOpen = nil }
        if let c = g.puzzleOpen, g.scripts.messages.isEmpty { puzzle = c; g.puzzleOpen = nil }
        if g.jumped, let h = g.heroes.first { g.jumped = false; centre(onCell: (h.x, h.y)) }
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
            // t_treasure_chest_window (0x8c7260): Background, OK at ok_button's corner, the gold and
            // experience toggles (gold on at opening), texts in font 20 / 14, black with the halo
            guard let d = ui.dialog("treasure_chest"), let offer = g.chestOffer else { return [] }
            let ox = (AdventureUI.width - 404) / 2, oy = (AdventureUI.height - 457) / 2
            out += layoutImage(d, "Background", ox, oy)
            out += buttonAt("ok", hoverButton((ox + (d["ok_button"]?.x ?? 0), oy + (d["ok_button"]?.y ?? 0), 76, 44)) ? "Highlighted" : "Released", d["ok_button"], ox, oy)
            for (gold, prefix) in [(true, "gold"), (false, "Experience")] {
                let on = (chestChoice ?? true) == gold
                let rel = d.layers.first { $0.name.lowercased() == "\(prefix.lowercased())_released" }
                let over = rel.map { hoverButton((ox + $0.x, oy + $0.y, $0.width, $0.height)) } ?? false
                let state = on ? "pressed" : over ? "highlighted" : "released"
                if let l = d.layers.first(where: { $0.name.lowercased() == "\(prefix.lowercased())_\(state)" }) {
                    out.append(Quad(texture: uiTexture("dlg|chest|\(l.name)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height))
                }
            }
            func text(_ key: String, _ fallback: String) -> String { g.tables?.objectText("treasure", "treasure_chest", key) ?? fallback }
            func win(_ s: String, _ name: String, _ size: Int) {
                guard let l = d.layers.first(where: { $0.name.lowercased() == name.lowercased() }) else { return }
                out += armyText(s, l, size: size, centre: true, vcentre: false, ox, oy)
            }
            win(text("name", "Treasure Chest"), "Title", 20)
            win(text("Initial", ""), "dialog_text", 20)
            win(text("gold", "Keep the %material for yourself.").replacingOccurrences(of: "%material", with: "\(offer.gold) gold"), "gold_label", 14)
            win(text("experience", "Donate the gold for %experience experience.").replacingOccurrences(of: "%experience", with: "\(offer.experience)"), "experience_label", 14)
        case .hero(let i):
            out += armyScreenQuads(i)
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
            if inside(d["gold_released"], at: ox, oy, x, y) { chestChoice = true }
            else if inside(d["Experience_Released"], at: ox, oy, x, y) { chestChoice = false }
            else if inside(d["ok_button"], at: ox, oy, x, y) { g.resolveChest(gold: chestChoice ?? true); chestChoice = nil; adventureDialog = nil }
            return true
        case .hero(let i):
            if armySplitClick(i, x: x, y: y) { return true }   // the split button: the split dialog
            let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
            // a ring shows that hero or stack
            if let d = ui.dialog("army.layout"), i < g.heroes.count {
                let n = 1 + g.heroes[i].companions.count + g.heroes[i].army.count
                for (k, o) in armyRingSlots(ox, oy).enumerated() where k < n {
                    if abs(x - Float(o.fx + 41)) < 33, abs(y - Float(o.fy + 41)) < 33 { heroShown = k; return true }
                }
            }
            // an artifact: worn ones come off into the backpack, backpack ones are put on where they fit
            if let d = ui.dialog("army.layout"), i < g.heroes.count, heroShown <= g.heroes[i].companions.count {
                let army = [g.heroes[i]] + g.heroes[i].companions
                let h = army[min(heroShown, army.count - 1)]
                if let hit = heroArtifactHit(h, d, ox, oy, x: x, y: y) {
                    switch hit {
                    case .worn(let s): h.unequip(slot: s)
                    case .backpack(let k):
                        if g.drink(h, backpackIndex: k) { break }   // a potion is drunk
                        if !h.equip(backpackIndex: k, tables: g.tables) { g.log.append("No free place to wear \(g.artifactName(h.backpack[k]))") }
                    }
                    g.refreshMovement(g.heroes[i])
                    sound?.play("miscellaneous.button")
                    return true
                }
            }
            if let d = ui.dialog("army.layout"), inside(d["ok_button"], at: ox, oy, x, y) { adventureDialog = nil; heroShown = 0 }
            else if x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 600) { adventureDialog = nil }
            return true
        }
    }
}

// MARK: script messages

extension Renderer {
    /// The texts the map's scripts show, one box at a time: layers.dialog.generic is a frame of
    /// corners, edges and a background tile (repeated to the size), the text wrapped inside, an OK
    /// button under it.
    struct MessageBox { var x, y, w, h: Int; var d: BasicDialog; var title: String?; var artifact: Int? }
    /// The box as t_basic_dialog lays it out: the text fitted and wrapped (font 18), the band, a
    /// title banner when the message has one, a found artifact's bare icon with its name under it,
    /// the buttons in creation order (a question: Cancel, then OK); centred on the screen.
    func messageBox() -> MessageBox? {
        guard let g = game, let text = prompt?.text ?? g.scripts.messages.first else { return nil }
        let title = prompt == nil ? g.messageTitles[text] : nil, artifact = prompt == nil ? g.messageArtifacts[text] : nil
        var items: [(picture: UILayer?, caption: String)] = []
        if let a = artifact { items.append((artifactIcon(a), g.artifactName(a))) }
        guard let d = basicDialog(text: text, title: title, items: items, buttons: prompt?.cancel == true ? ["cancel", "ok"] : ["ok"]) else { return nil }
        let x = max(0, (AdventureUI.width - d.W) / 2), y = max(0, (AdventureUI.height - d.H) / 2)
        return MessageBox(x: x, y: y, w: d.W, h: d.H, d: d, title: title, artifact: artifact)
    }
    func messageButton(_ name: String) -> (x: Int, y: Int, w: Int, h: Int)? {
        guard let m = messageBox(), let k = m.d.buttons.firstIndex(of: name) else { return nil }
        let r = m.d.buttonPlaces[k]
        return (m.x + r.x, m.y + r.y, r.w, r.h)
    }
    func okRect() -> (x: Int, y: Int, w: Int, h: Int)? { messageButton("ok") }
    func cancelRect() -> (x: Int, y: Int, w: Int, h: Int)? { messageButton("cancel") }
    func cropped(_ b: Bitmap, _ w: Int, _ h: Int) -> Bitmap { Renderer.crop(b, x: 0, y: 0, w: w, h: h) }
    /// The generic dialog frame (layers.dialog.generic as a t_window_background of that size).
    func frameQuads(x mx: Int, y my: Int, w mw: Int, h mh: Int) -> [Quad] {
        guard let ui = ui, let d = ui.dialog("generic"), mw > 0, mh > 0 else { return [] }
        return [Quad(texture: uiTexture("generic|\(mw)x\(mh)", { nineSlice(d, w: mw, h: mh) }), x: mx, y: my, w: mw, h: mh)]
    }
    func messageBoxQuads() -> [Quad] {
        guard let ui = ui, let m = messageBox() else { return [] }
        let key = m.d.lines.first ?? ""
        if messageKey != key { messageKey = key; messageScroll = 0 }
        messageScroll = max(0, min(max(0, m.d.lines.count - m.d.fit), messageScroll))
        var out = basicDialogQuads(m.d, x: m.x, y: m.y, scroll: messageScroll)
        // a button's balloon once the pointer rests on it (table.Interface shared.ok / cancel)
        for (rect, key, fallback) in [(okRect(), "shared.ok", "Okay"), (cancelRect(), "shared.cancel", "Cancel")] {
            guard let r = rect, hoverButton(r), balloonDue else { continue }
            out += helpBalloonQuads(game?.tables?.interfaceTexts[key]?.balloon ?? fallback, at: pointerCanvas)
        }
        // the item's help, when right-clicked: a popup of its own at the item
        if let help = messageItemHelp, let a = m.artifact, let r = itemRect(), let d = basicDialog(text: "\(game?.artifactName(a) ?? ""): \(help)") {
            let px = min(max(0, r.x + r.w / 2 - d.W / 2), AdventureUI.width - d.W), py = min(r.y + r.h / 2, AdventureUI.height - d.H)
            out += basicDialogQuads(d, x: px, y: max(0, py))
        }
        _ = ui
        return out
    }
    func itemRect() -> (x: Int, y: Int, w: Int, h: Int)? {
        guard let m = messageBox(), m.artifact != nil, let p = m.d.itemPlaces.first, let pic = m.d.items.first?.picture else { return nil }
        return (m.x + p.x, m.y + p.y, pic.width, pic.height)
    }
    /// The pointer over an OK / Cancel place (the button shows its highlighted face).
    func hoverButton(_ r: (x: Int, y: Int, w: Int, h: Int)) -> Bool {
        let p = pointerCanvas
        return p.0 >= Float(r.x) && p.0 < Float(r.x + r.w) && p.1 >= Float(r.y) && p.1 < Float(r.y + r.h)
    }
    /// A click while a script message is up: OK takes it away. Returns true when the box was open.
    func messageBoxClick(x: Float, y: Float) -> Bool {
        func on(_ r: (x: Int, y: Int, w: Int, h: Int)?) -> Bool {
            guard let r = r else { return false }
            return x >= Float(r.x) && x < Float(r.x + r.w) && y >= Float(r.y) && y < Float(r.y + r.h)
        }
        if let p = prompt {   // the game's own box comes first; it stays until OK or Cancel
            if on(okRect()) { prompt = nil; p.ok?() } else if on(cancelRect()) { prompt = nil }
            return true
        }
        guard let g = game, !g.scripts.messages.isEmpty else { return false }
        messageItemHelp = nil
        if let ok = okRect(), x >= Float(ok.x), x < Float(ok.x + ok.w), y >= Float(ok.y), y < Float(ok.y + ok.h) { g.scripts.messages.removeFirst() }
        return true
    }
}
