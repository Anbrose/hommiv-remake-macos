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
                                              ("Ranged_Attack_Text", "\(s.ranged)"), ("Ranged_Defense_Text", "\(s.defense)"), ("Speed_Text", "\(s.speed)"), ("Move_Text", "\(Int(h.movement))\n(\(Int(h.maxMovement)))"),
                                              ("Experience_Text", "\(h.experience)"), ("Spell_Points_Text", "\(g.spellPoints(h))\n(\(g.maxSpellPoints(h)))"), ("Shots_Text", "\(s.shots)"), ("Morale_Text", moraleText), ("Luck_Text", "0")]
            out += statTexts(values, d, ox, oy)
            }
            out += armyScreenChrome(g.heroes[i], d, ox, oy, selected: heroShown)
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
            // a ring shows that hero or stack
            if let d = ui.dialog("army.layout"), i < g.heroes.count {
                let n = 1 + g.heroes[i].companions.count + g.heroes[i].army.count
                for (k, o) in armyRingOrigins(d, row: 0, ox: ox, oy: oy).enumerated() where k < n {
                    if abs(x - Float(o.x + 41)) < 33, abs(y - Float(o.y + 41)) < 33 { heroShown = k; return true }
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
    static let messageWidth = 560
    struct MessageBox { var x, y, w, h: Int; var lines: [String]; var font: H4Font; var title: String?; var artifact: Int?; var bandY, bandH, fit: Int }
    /// The box as the original draws it: the parchment frame (dialog.generic), a title banner when
    /// the message has one, the text in a scroll band with rolls at both ends (text_background.large),
    /// a found artifact in its frame with its name, OK under it.
    func messageLayout() -> (x: Int, y: Int, w: Int, h: Int, lines: [String], font: H4Font)? {
        messageBox().map { ($0.x, $0.y, $0.w, $0.h, $0.lines, $0.font) }
    }
    func messageBox() -> MessageBox? {
        guard let g = game, let text = prompt?.text ?? g.scripts.messages.first, let ui = ui else { return nil }
        let font = ui.font(20)
        let w = Renderer.messageWidth
        let title = prompt == nil ? g.messageTitles[text] : nil, artifact = prompt == nil ? g.messageArtifacts[text] : nil
        let lines = text.components(separatedBy: "\n").flatMap { $0.isEmpty ? [""] : AdventureUI.wrap($0, font: font, width: w - 150) }
        let extra = (title != nil ? 46 : 0) + (artifact != nil ? 120 : 0) + 30 + 64
        let fit = max(1, min(lines.count, (AdventureUI.height - 60 - extra - 40) / font.lineHeight))
        let bandH = fit * font.lineHeight + 40
        let h = extra + bandH
        let across = inCombat ? AdventureUI.width : AdventureUI.mapViewportWidth
        let x = (across - w) / 2, y = (AdventureUI.height - h) / 2
        return MessageBox(x: x, y: y, w: w, h: h, lines: lines, font: font, title: title, artifact: artifact, bandY: y + 26 + (title != nil ? 46 : 0), bandH: bandH, fit: fit)
    }
    func okRect() -> (x: Int, y: Int, w: Int, h: Int)? {
        guard let m = messageLayout() else { return nil }
        if prompt?.cancel == true { return (m.x + m.w / 2 - 66 - 20, m.y + m.h - 58, 66, 40) }
        return (m.x + (m.w - 66) / 2, m.y + m.h - 58, 66, 40)
    }
    func cancelRect() -> (x: Int, y: Int, w: Int, h: Int)? {
        guard prompt?.cancel == true, let m = messageLayout() else { return nil }
        return (m.x + m.w / 2 + 20, m.y + m.h - 58, 66, 40)
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
        guard let ui = ui, let m = messageBox() else { return [] }
        var out = frameQuads(x: m.x, y: m.y, w: m.w, h: m.h)
        // the title on its banner (adventure.day_scroll: its ends and middle stretched to the title)
        if let t = m.title { let banner = ui.dayScroll
            let tw = ui.font(20).measure(t) + 80, bx = m.x + (m.w - tw) / 2, by = m.y + 10
            if let mid = banner["Background"] { out.append(Quad(texture: uiTexture("banner|mid", { mid.bitmap }), x: bx + 10, y: by, w: tw - 20, h: mid.height)) }
            if let l = banner["left"] ?? banner["Left"] { out.append(Quad(texture: uiTexture("banner|l", { l.bitmap }), x: bx, y: by, w: l.width, h: l.height)) }
            if let r = banner["Right"] { out.append(Quad(texture: uiTexture("banner|r", { r.bitmap }), x: bx + tw - r.width, y: by, w: r.width, h: r.height)) }
            let f = ui.font(20), w = f.measure(t)
            out.append(Quad(texture: uiTexture("dlgtext|20|\(t)|12", { f.render(t, colour: (12, 8, 4)) }), x: m.x + (m.w - w) / 2, y: by + 12, w: w, h: f.size))
        }
        // the band
        let bandW = m.w - 60
        if let box = ui.popupBitmap(clientW: bandW - 70, clientH: m.bandH - 40, size: "large") {
            out.append(Quad(texture: uiTexture("band|\(box.bitmap.width)x\(box.bitmap.height)", { box.bitmap }), x: m.x + (m.w - box.bitmap.width) / 2, y: m.bandY + (m.bandH - box.bitmap.height) / 2, w: box.bitmap.width, h: box.bitmap.height))
        }
        let key = m.lines.first ?? ""
        if messageKey != key { messageKey = key; messageScroll = 0 }
        messageScroll = max(0, min(max(0, m.lines.count - m.fit), messageScroll))
        for (i, line) in m.lines.dropFirst(messageScroll).prefix(m.fit).enumerated() where !line.isEmpty {
            let w = m.font.measure(line)
            out.append(Quad(texture: uiTexture("msg|\(m.font.size)|\(line)", { m.font.render(line, colour: (12, 8, 4)) }), x: m.x + (m.w - w) / 2, y: m.bandY + 20 + i * m.font.lineHeight, w: w, h: m.font.size))
        }
        if m.lines.count > m.fit {
            if messageScroll > 0 { out.append(Quad(texture: solid(120, 80, 30), x: m.x + m.w - 70, y: m.bandY + 16, w: 8, h: 8)) }
            if messageScroll + m.fit < m.lines.count { out.append(Quad(texture: solid(120, 80, 30), x: m.x + m.w - 70, y: m.bandY + m.bandH - 24, w: 8, h: 8)) }
        }
        // a found artifact: its frame (button.Frame_52), icon and name
        if let a = m.artifact, let r = itemRect() {
            if let fr = ui.button("Frame_52") { out.append(Quad(texture: uiTexture("frame52", { fr.bitmap }), x: r.x, y: r.y, w: fr.width, h: fr.height)) }
            if let ic = artifactIcon(a) { out.append(Quad(texture: uiTexture("art|\(a & 0xffff)", { ic.bitmap }), x: r.x + (77 - ic.width) / 2, y: r.y + (77 - ic.height) / 2, w: ic.width, h: ic.height)) }
            let n = game?.artifactName(a) ?? "", f = ui.font(18), w = f.measure(n)
            out.append(Quad(texture: uiTexture("dlgtext|18|\(n)|12", { f.render(n, colour: (12, 8, 4)) }), x: m.x + (m.w - w) / 2, y: r.y + 84, w: w, h: f.size))
        }
        for (rect, name) in [(okRect(), "ok"), (cancelRect(), "cancel")] {
            guard let r = rect, let b = ui.button(name, state: hoverButton(r) ? "Highlighted" : "Released") ?? ui.button(name) else { continue }
            out.append(Quad(texture: uiTexture("button|\(name)|\(b.name)", { b.bitmap }), x: r.x + (r.w - b.width) / 2, y: r.y + (r.h - b.height) / 2, w: b.width, h: b.height))
        }
        // a button's balloon once the pointer rests on it (table.Interface shared.ok / cancel)
        for (rect, key, fallback) in [(okRect(), "shared.ok", "Okay"), (cancelRect(), "shared.cancel", "Cancel")] {
            guard let r = rect, hoverButton(r), Date().timeIntervalSince(pointerSince) > 0.8 else { continue }
            let s = game?.tables?.interfaceTexts[key]?.balloon ?? fallback
            let f = ui.font(16), w = f.measure(s) + 12, h = f.size + 8, bx = Int(pointerCanvas.0) + 12, by = Int(pointerCanvas.1) - h - 4
            out += [Quad(texture: solid(20, 12, 4), x: bx - 1, y: by - 1, w: w + 2, h: h + 2), Quad(texture: solid(255, 252, 240), x: bx, y: by, w: w, h: h),
                    Quad(texture: uiTexture("dlgtext|16|\(s)|12", { f.render(s, colour: (12, 8, 4)) }), x: bx + 6, y: by + 4, w: w - 12, h: f.size)]
        }
        // the item's help, when right-clicked, in a band of its own below
        if let help = messageItemHelp, let a = m.artifact {
            let text = "\(game?.artifactName(a) ?? ""): \(help)"
            let f = ui.font(18), lines = AdventureUI.wrap(text, font: f, width: m.w - 150)
            if let box = ui.popupBitmap(clientW: m.w - 130, clientH: lines.count * f.lineHeight, size: "large") {
                let by = min(AdventureUI.height - box.bitmap.height - 4, (itemRect()?.y ?? m.y) + 60)
                out += frameQuads(x: m.x, y: by - 14, w: m.w, h: box.bitmap.height + 28)
                out.append(Quad(texture: uiTexture("band|\(box.bitmap.width)x\(box.bitmap.height)", { box.bitmap }), x: m.x + (m.w - box.bitmap.width) / 2, y: by, w: box.bitmap.width, h: box.bitmap.height))
                for (i, line) in lines.enumerated() {
                    let w = f.measure(line)
                    out.append(Quad(texture: uiTexture("msg|18|\(line)", { f.render(line, colour: (12, 8, 4)) }), x: m.x + (m.w - w) / 2, y: by + box.clientY + i * f.lineHeight, w: w, h: f.size))
                }
            }
        }
        return out
    }
    func itemRect() -> (x: Int, y: Int, w: Int, h: Int)? {
        guard let m = messageBox(), m.artifact != nil else { return nil }
        return (m.x + (m.w - 77) / 2, m.bandY + m.bandH + 10, 77, 77)
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
