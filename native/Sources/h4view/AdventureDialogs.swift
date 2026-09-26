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
            // the level button shows the other level: "underground" on the surface, "surface" below
            let btn = name == "underground" && (g.map.levels < 2 || g.level == 1) ? "surface" : name
            let state = (name == "underground" && g.map.levels < 2) || (name == "spell" && (g.heroes.first?.spells.isEmpty ?? true)) ? "Disabled" : "Released"
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
            let leader = g.heroes[i], army = [leader] + leader.companions
            let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
            // a creature stack chosen in the rings: the screen's creature mode (0x534640)
            if heroShown >= army.count, heroShown - army.count < leader.army.count {
                out += creatureModeQuads(leader, stack: leader.army[heroShown - army.count], d, ox, oy)
            } else {
            let h = army[min(heroShown, army.count - 1)]
            // not drawn: text-area masks (name_text, creature_text: outlines only), the other states of
            // the buttons, the creature-only abilities frame, and the two-row ring backdrop (a hero
            // outside a town shows one row); the formation buttons show the army's (loose) pressed
            out += dialogImages(d, key: "herodlg", at: ox, oy, skip: ["Ring_Pressed", "Move_Army_Up", "Move_Army_Down", "Move_Tombstone_up", "loose_Released", "loose_Disabled",
                                                                    "tight_Pressed", "tight_Disabled", "square_Pressed", "square_Disabled", "Up_Disabled", "name_text", "creature_text",
                                                                    "Double_Ring_Background", "Abilities_Frame", "Army_Up_Highlighted", "Army_Up_Pressed", "Army_Down_Highlighted",
                                                                    "Army_Down_Pressed", "SpellBook_Highlighted", "SpellBook_Pressed", "Ranged", "Ranged_Text", "dismiss"])
            // skills, the class picture with the worn artifacts, the backpack
            out += heroThingsQuads(h, d, ox, oy)
            if let slot = d["creature_portrait"], let p = ui.portrait(keyword: h.keyword, alignment: h.alignment, size: 82) {
                out.append(Quad(texture: uiTexture("portrait82|\(h.alignment)|\(h.keyword)", { p.bitmap }), x: ox + slot.x + (slot.width - p.width) / 2, y: oy + slot.y + (slot.height - p.height) / 2, w: p.width, h: p.height))
            }
            out += centred(h.name, in: d["name_text"], at: ox, oy, font: ui.dateFont)
            out += centred(classLine(h), in: d["class_text"], at: ox, oy, font: ui.dateFont)
            let s = g.heroStats(h)
            // the hero's morale from the army's alignments (heroes4.exe 0x640310)
            let moraleArmy: [(alignment: String, undead: Bool)] = army.map { ($0.alignment, false) } + leader.army.compactMap { st in g.tables?.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
            let m = Battle.armyMorale(own: h.alignment, army: moraleArmy)
            let moraleText = m > 0 ? "+\(m)" : "\(m)"
            let values: [(String, String)] = [("Damage_Text", s.damage), ("Hit_Points_Text", "\(s.hitPoints)"), ("Melee_Attack_Text", "\(s.attack)"), ("Melee_Defense_Text", "\(s.defense)"),
                                              ("Ranged_Attack_Text", "\(s.ranged)"), ("Ranged_Defense_Text", "\(s.defense)"), ("Speed_Text", "\(s.speed)"), ("Move_Text", "\(s.move)"),
                                              ("Experience_Text", "\(h.experience)"), ("Spell_Points_Text", "\(s.spellPoints)"), ("Shots_Text", "\(s.shots)"), ("Morale_Text", moraleText), ("Luck_Text", "0")]
            for (slot, v) in values { out += centred(v, in: d[slot], at: ox, oy, font: ui.numberFont) }
            }
            // the army: one row of creature_rings pieces (Left, Middle x5, Right) tiled by width in
            // Single_Ring_Background, as t_creature_array_window lays them out; labels last
            if let row = d["Single_Ring_Background"] {
                var slots: [(UILayer?, String?)] = army.map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), nil) }
                slots += leader.army.map { (ui.creatureIcon($0.creature), String($0.count)) }
                var cursor = ox + row.x
                var centres: [(Int, Int)] = []
                for k in 0..<7 {
                    let name = k == 0 ? "Left" : k == 6 ? "Right" : "Middle"
                    guard let piece = ui.creatureRing(name) else { continue }
                    let o = (cursor - piece.x, oy + row.y - 1)
                    out.append(Quad(texture: uiTexture("cring|\(name)", { piece.bitmap }), x: o.0 + piece.x, y: o.1 + piece.y, w: piece.width, h: piece.height))
                    centres.append((o.0 + 41, o.1 + 41))
                    cursor += piece.width
                }
                for (k, (icon, _)) in slots.prefix(centres.count).enumerated() {
                    if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: centres[k].0 - icon.width / 2, y: centres[k].1 - icon.height / 2, w: icon.width, h: icon.height)) }
                }
                for (k, (_, count)) in slots.prefix(centres.count).enumerated() {
                    ringLabel(&out, ui: ui, cx: centres[k].0, cy: centres[k].1, count: count, hero: k < army.count)
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
        case .hero(let i):
            let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
            // a hero's ring shows that hero
            if let d = ui.dialog("army.layout"), let row = d["Single_Ring_Background"], i < g.heroes.count {
                let n = 1 + g.heroes[i].companions.count + g.heroes[i].army.count
                var cursor = ox + row.x
                for k in 0..<min(7, n) {
                    guard let piece = ui.creatureRing(k == 0 ? "Left" : k == 6 ? "Right" : "Middle") else { break }
                    let cx = cursor - piece.x + 41, cy = oy + row.y - 1 + 41
                    if abs(x - Float(cx)) < 38, abs(y - Float(cy)) < 38 { heroShown = k; return true }
                    cursor += piece.width
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
    static let messageWidth = 440
    func messageLayout() -> (x: Int, y: Int, w: Int, h: Int, lines: [String], font: H4Font)? {
        guard let g = game, let text = prompt?.text ?? g.scripts.messages.first, let ui = ui else { return nil }
        let font = ui.dateFont
        let w = Renderer.messageWidth
        let lines = text.components(separatedBy: "\n").flatMap { $0.isEmpty ? [""] : AdventureUI.wrap($0, font: font, width: w - 60) }
        let h = min(AdventureUI.height - 40, 40 + lines.count * font.lineHeight + 70)
        let across = inCombat ? AdventureUI.width : AdventureUI.mapViewportWidth
        return ((across - w) / 2, (AdventureUI.height - h) / 2, w, h, lines, font)
    }
    func okRect() -> (x: Int, y: Int, w: Int, h: Int)? {
        guard let m = messageLayout() else { return nil }
        if prompt?.cancel == true { return (m.x + m.w / 2 - 66 - 20, m.y + m.h - 54, 66, 32) }
        return (m.x + (m.w - 66) / 2, m.y + m.h - 54, 66, 32)
    }
    func cancelRect() -> (x: Int, y: Int, w: Int, h: Int)? {
        guard prompt?.cancel == true, let m = messageLayout() else { return nil }
        return (m.x + m.w / 2 + 20, m.y + m.h - 54, 66, 32)
    }
    func cropped(_ b: Bitmap, _ w: Int, _ h: Int) -> Bitmap {
        var out = Bitmap(width: w, height: h)
        for y in 0..<min(h, b.height) { for x in 0..<min(w, b.width) {
            let s = (y * b.width + x) * 4, d = (y * w + x) * 4
            out.pixels[d..<(d + 4)] = b.pixels[s..<(s + 4)]
        } }
        return out
    }
    /// The generic dialog frame (layers.dialog.generic): background tiled over the inside, edges
    /// between the corners, the corners.
    func frameQuads(x mx: Int, y my: Int, w mw: Int, h mh: Int) -> [Quad] {
        guard let ui = ui, let d = ui.dialog("generic") else { return [] }
        var out: [Quad] = []
        func piece(_ name: String, _ x: Int, _ y: Int, w: Int? = nil, h: Int? = nil) {
            guard let l = d[name] else { return }
            let ww = min(w ?? l.width, l.width), hh = min(h ?? l.height, l.height)
            let key = "gen|\(name)|\(ww)|\(hh)"
            out.append(Quad(texture: uiTexture(key, { ww == l.width && hh == l.height ? l.bitmap : cropped(l.bitmap, ww, hh) }), x: x, y: y, w: ww, h: hh))
        }
        if let bg = d["Background"] {
            var y = 6
            while y < mh - 6 {
                var x = 6
                while x < mw - 6 { piece("Background", mx + x, my + y, w: min(bg.width, mw - 6 - x), h: min(bg.height, mh - 6 - y)); x += bg.width }
                y += bg.height
            }
        }
        if let top = d["Top"], let left = d["Left"] {
            var x = 31
            while x < mw - 26 { let w = min(top.width, mw - 26 - x); piece("Top", mx + x, my, w: w); piece("Bottom", mx + x, my + mh - 12, w: w); x += top.width }
            var y = 28
            while y < mh - 36 { let h = min(left.height, mh - 36 - y); piece("Left", mx, my + y, h: h); piece("Right", mx + mw - 11, my + y, h: h); y += left.height }
        }
        piece("Top_Left", mx, my); piece("Top_Right", mx + mw - 26, my)
        piece("Bottom_Left", mx, my + mh - 36); piece("Bottom_Right", mx + mw - 26, my + mh - 36)
        _ = ui
        return out
    }
    func messageBoxQuads() -> [Quad] {
        guard let ui = ui, let m = messageLayout() else { return [] }
        var out = frameQuads(x: m.x, y: m.y, w: m.w, h: m.h)
        // a text longer than the box scrolls (the wheel); the lines that fit show
        let fit = max(1, (m.h - 100) / m.font.lineHeight)
        let key = m.lines.first ?? ""
        if messageKey != key { messageKey = key; messageScroll = 0 }
        messageScroll = max(0, min(max(0, m.lines.count - fit), messageScroll))
        for (i, line) in m.lines.dropFirst(messageScroll).prefix(fit).enumerated() where !line.isEmpty {
            let w = m.font.measure(line)
            out.append(Quad(texture: uiTexture("msg|\(line)", { m.font.render(line, colour: (40, 24, 8)) }), x: m.x + (m.w - w) / 2, y: m.y + 30 + i * m.font.lineHeight, w: w, h: m.font.size))
        }
        if m.lines.count > fit {   // more above / below: small marks at the box's right edge
            if messageScroll > 0 { out.append(Quad(texture: solid(120, 80, 30), x: m.x + m.w - 34, y: m.y + 30, w: 8, h: 8)) }
            if messageScroll + fit < m.lines.count { out.append(Quad(texture: solid(120, 80, 30), x: m.x + m.w - 34, y: m.y + m.h - 80, w: 8, h: 8)) }
        }
        if let ok = okRect(), let b = ui.button("ok") {
            out.append(Quad(texture: uiTexture("button|ok|\(b.name)", { b.bitmap }), x: ok.x + (ok.w - b.width) / 2, y: ok.y + (ok.h - b.height) / 2, w: b.width, h: b.height))
        }
        if let c = cancelRect(), let b = ui.button("cancel") {
            out.append(Quad(texture: uiTexture("button|cancel|\(b.name)", { b.bitmap }), x: c.x + (c.w - b.width) / 2, y: c.y + (c.h - b.height) / 2, w: b.width, h: b.height))
        }
        return out
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
        if let ok = okRect(), x >= Float(ok.x), x < Float(ok.x + ok.w), y >= Float(ok.y), y < Float(ok.y + ok.h) { g.scripts.messages.removeFirst() }
        return true
    }
}
