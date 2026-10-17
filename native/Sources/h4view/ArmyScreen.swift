import Foundation
import AppKit
import H4Engine

/// The army screen's working state (t_army_dialog, army_split_spec.md): the rows (the army, and
/// below it the empty new army a split makes, a trade partner, or in the town variant the garrison
/// over the visiting army), the selected place, split mode, a stack being dragged, a refusal note.
final class ArmySession {
    let leader: Hero
    var x: ArmyExchange
    /// Two rows (Double_Ring_Background) or one (Single_Ring_Background).
    let double: Bool
    /// The town variant (t_army_dialog_town, 0x538b70): the town's rows, applied as they change.
    let town: Int?
    var selected: (row: Int, k: Int) { didSet { if oldValue != selected { backpackRow = 0 } } }   // another member: the backpack from its top (0x5346b7)
    var splitMode = false
    /// The artifacts (hero_artifacts_spec.md): a press on one, the one in hand, the pointer, the
    /// backpack's scrollbar step, a parchment's message at the pointer, a held right-click text.
    var artPress: ArtifactPlace?
    var artDrag: ArtifactDrag?
    var artAt: (Float, Float)?
    var backpackRow = 0
    var artNote: (text: String, x: Int, y: Int)?
    var drag: (row: Int, k: Int)?
    var dragAt: (Float, Float)?
    var dragSplit = false
    var note: (text: String, x: Int, y: Int, since: Date)?
    init(leader: Hero, x: ArmyExchange, double: Bool, town: Int? = nil, selected: (row: Int, k: Int) = (0, 0)) {
        self.leader = leader; self.x = x; self.double = double; self.town = town; self.selected = selected
    }
}
var armySession: ArmySession?

/// The army screen (t_army_dialog; army_screen_spec.md), drawn as the exe builds it: the layout's
/// Background; the hero list (Hero_Background, the paper doll at 264,147, the skills in columns
/// 30/90/147/204 under Skill_Frame, the backpack) or the creature list (Creature_Background with
/// its scroll and model frame, the model window, the abilities under Abilities_Frame, Dismiss);
/// OK, the formation toggles, the potion button, the spell book; the ring rows (one row:
/// Single_Ring_Background, style 0 pieces from x 147 at y 480, split_Single; two rows:
/// Double_Ring_Background, Top_* pieces at y 456 over Bottom_* pieces at y 528, button.split, the
/// Move_Army buttons); the stat icons, morale and luck from icons.morale.34, the portrait under
/// Portrait_Border; the texts in Prose_Antique, black with the (200,200,200) halo; the army list
/// (4 rows, arrows only past 4 armies).
extension Renderer {
    static let armyHalo: (UInt8, UInt8, UInt8) = (200, 200, 200)

    /// A text window (0x8859f0): the font of `size`, left or centred, optionally centred vertically as a block.
    func armyText(_ s: String, _ l: UILayer?, size: Int, centre: Bool, vcentre: Bool, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let ui = ui, let l = l, !s.isEmpty else { return [] }
        let f = ui.font(size)
        let lines = s.components(separatedBy: "\n").flatMap { $0.isEmpty ? [""] : AdventureUI.wrap($0, font: f, width: l.width) }
        var y = l.y
        if vcentre, lines.count * f.lineHeight < l.height { y = l.y + (l.height - lines.count * f.lineHeight) / 2 }
        var out: [Quad] = []
        for (k, line) in lines.enumerated() where !line.isEmpty {
            let w = f.measure(line)
            let x = centre ? l.x + max(0, (l.width - w) / 2) : l.x
            out.append(Quad(texture: uiTexture("atext|\(size)|\(line)", { f.render(line, colour: (0, 0, 0), halo: Renderer.armyHalo) }), x: ox + x, y: oy + y + k * f.lineHeight, w: w, h: f.size))
        }
        return out
    }
    /// A layout layer at its own box (bitmap windows; kind-1 layers with a palette are images too).
    func layoutImage(_ d: LayerFile, _ name: String, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let l = d[name] ?? d.layers.first(where: { $0.name.lowercased() == name.lowercased() }) else { return [] }
        return [Quad(texture: uiTexture("army|\(l.name)|\(l.x),\(l.y),\(l.width)x\(l.height)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height)]
    }
    /// A button file's state image with its top-left at a hotspot's top-left.
    func buttonAt(_ file: String, _ state: String, _ l: UILayer?, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let ui = ui, let l = l else { return [] }
        let f = ((try? ui.archive.payload("layers.button.\(file).h4d")) ?? (try? ui.archive.payload("layers.Button.\(file).h4d"))).flatMap { try? LayerFile(data: $0) }
        guard let b = f?[state] ?? f?.layers.first(where: { $0.name.lowercased() == state.lowercased() }) else { return [] }
        return [Quad(texture: uiTexture("btn|\(file)|\(b.name)", { b.bitmap }), x: ox + l.x + b.x, y: oy + l.y + b.y, w: b.width, h: b.height)]
    }
    /// The single ring row's slot frames: pieces Left, Middle x5, Right laid from x 147, their tops at y 480.
    func armyRingSlots(_ ox: Int, _ oy: Int) -> [(piece: String, fx: Int, fy: Int)] {
        ringRow(x: ox + 147, y: oy + 480, style: 0)
    }
    /// The shown rows' slot frames: one row, or the Top_* row over the Bottom_* row.
    func armyRowSlots(_ s: ArmySession, _ ox: Int, _ oy: Int) -> [[(piece: String, fx: Int, fy: Int)]] {
        s.double ? [ringRow(x: ox + 147, y: oy + 456, style: 1), ringRow(x: ox + 147, y: oy + 528, style: 2)] : [armyRingSlots(ox, oy)]
    }
    var armyOrigin: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }

    // MARK: the session

    /// The army screen for an army (a double click in the army list or on the panel, 0x4b63e0):
    /// with the empty new army below when a split is possible; `item` picks the shown member
    /// (heroes, then stacks, as the panel orders them).
    func openArmyScreen(_ h: Hero, item: Int = 0) {
        guard let g = game else { return }
        g.select(h)
        let x = g.exchange(for: h) ?? g.singleRow(h)
        let s = ArmySession(leader: h, x: x, double: !x.isSingle)
        s.selected = slotOf(item: item, in: h, rows: x.rows) ?? firstFilled(x.rows) ?? (0, 0)
        armySession = s
        adventureDialog = .hero(0)
    }
    /// Two of the player's armies met: the trade (0x522c6a).
    func openTrade(_ a: Hero, _ b: Hero) {
        guard let g = game else { return }
        g.select(a)
        let x = g.exchange(a, with: b)
        armySession = ArmySession(leader: a, x: x, double: true, selected: firstFilled(x.rows) ?? (0, 0))
        adventureDialog = .hero(0)
    }
    /// A double click on a town row (0x8b0e90): t_army_dialog_town with that place selected.
    func openTownArmyScreen(_ i: Int, selected: (row: Int, k: Int)) {
        guard let g = game, let rows = townRows() else { return }
        let lead = g.visitingArmy(town: i) ?? Hero(actor: "", x: -1, y: -1)
        let x = ArmyExchange.rows(lead, rows)
        armySession = ArmySession(leader: lead, x: x, double: townTwoRows, town: i, selected: selected)
    }
    func slotOf(item: Int, in h: Hero, rows: [[ArmySlot?]]) -> (row: Int, k: Int)? {
        let heroes = h.members
        if item < heroes.count { return rows[0].firstIndex { $0?.hero === heroes[item] }.map { (0, $0) } }
        let j = item - heroes.count
        guard j < h.army.count else { return nil }
        let c = h.army[j].creature, nth = h.army.prefix(j).filter { $0.creature == c }.count
        let ks = rows[0].indices.filter { rows[0][$0]?.stack?.creature == c }
        return nth < ks.count ? (0, ks[nth]) : nil
    }
    func firstFilled(_ rows: [[ArmySlot?]]) -> (row: Int, k: Int)? {
        for (r, row) in rows.enumerated() { if let k = row.firstIndex(where: { $0 != nil }) { return (r, k) } }
        return nil
    }
    /// The session's rows now (the town variant reads the town's).
    func sessionRows(_ s: ArmySession) -> [[ArmySlot?]] {
        if s.town != nil, let rows = townRows() { return s.double ? rows : [rows[0], rows[1]] }
        return s.x.rows
    }
    /// The hero shown (the selected place's), if it holds one.
    var sessionHero: Hero? {
        guard let s = armySession else { return nil }
        let rows = sessionRows(s)
        guard s.selected.row < rows.count, s.selected.k < rows[s.selected.row].count else { return nil }
        return rows[s.selected.row][s.selected.k]?.hero
    }
    /// The army screen is done (OK, Escape, a click outside, another army picked): 0x529050.
    func closeArmyScreen() {
        if let s = armySession, let d = s.artDrag {   // closed with an artifact in hand: it goes home
            ArtifactRules.cancel(d, tables: game?.tables); s.artDrag = nil; NSCursor.unhide()
        }
        if let s = armySession, s.town == nil, let g = game { g.finishExchange(s.x) }
        armySession = nil
        splitDialog = nil
        if case .hero? = adventureDialog { adventureDialog = nil }
        heroShown = 0
    }

    /// The place under a canvas point: (row, k).
    func armyRing(_ s: ArmySession, at x: Float, _ y: Float) -> (row: Int, k: Int)? {
        let (ox, oy) = armyOrigin
        for (r, slots) in armyRowSlots(s, ox, oy).enumerated() {
            for (k, o) in slots.enumerated() where abs(x - Float(o.fx + 41)) < 33 && abs(y - Float(o.fy + 41)) < (s.double ? 32 : 36) { return (r, k) }
        }
        return nil
    }
    /// Apply a move between places; a refusal shows the needs_movement text over the place.
    func armyMove(_ s: ArmySession, from: (row: Int, k: Int), to: (row: Int, k: Int), count: Int? = nil) {
        guard let g = game else { return }
        if s.town != nil { townMove(from: from, to: to, split: false, count: count); s.selected = to; return }
        let rows = s.x.rows
        guard let src = rows[from.row][from.k] else { return }
        if let r = s.x.move(from: from, to: to, split: count) {
            guard case .needsMovement(let plural) = r else { return }
            let name: String = {
                if let h = src.hero { return h.name }
                let st = src.stack!, c = g.tables?.creature(st.creature)
                return plural ? "The " + (c?.plural ?? st.creature).lowercased() : "The " + (c?.name ?? st.creature).lowercased()
            }()
            let key = plural ? "needs_movement.do.dialog" : "needs_movement.does.dialog"
            let fallback = plural ? "%The_creatures do not have enough movement to make this transfer." : "%The_creature does not have enough movement to make this transfer."
            let t = text(key, fallback).replacingOccurrences(of: "%The_creatures", with: name).replacingOccurrences(of: "%The_creature", with: name)
            let (ox, oy) = armyOrigin
            let o = armyRowSlots(s, ox, oy)[min(from.row, s.double ? 1 : 0)][from.k]
            s.note = (t, o.fx + 41, o.fy, Date())
            return
        }
        s.selected = s.x.rows[to.row][to.k] != nil ? to : from
        sound?.play("miscellaneous.button")
    }
    /// A drop with Shift or in split mode onto an empty place or the same creature: the split dialog
    /// (0x6467f0); else a plain move.
    func armyDrop(_ s: ArmySession, from: (row: Int, k: Int), to: (row: Int, k: Int), split: Bool) {
        let rows = sessionRows(s)
        guard from != to, let src = rows[from.row][from.k] else { return }
        let dst = rows[to.row][to.k]
        if split, let a = src.stack, a.count > 1 || (dst?.stack?.creature == a.creature), dst == nil || dst?.stack?.creature == a.creature {
            let have = dst?.stack?.count ?? 0
            openSplit(creature: a.creature, source: a.count, destination: have) { [weak self] n in
                guard let self = self, let s = armySession else { return }
                let delta = n - have
                if delta > 0 { self.armyMove(s, from: from, to: to, count: delta) }
                else if delta < 0 { self.armyMove(s, from: to, to: from, count: -delta) }
            }
            return
        }
        armyMove(s, from: from, to: to)
    }

    // MARK: input

    func armyScreenPress(x: Float, y: Float) {
        guard let s = armySession, splitDialog == nil else { return }
        s.dragAt = nil
        s.artNote = nil
        s.artPress = nil
        // an artifact: carried once the pointer moves with the button down (source vtable[2], 0x706770)
        if let h = sessionHero, let d = ui?.dialog("army.layout") {
            let (ox, oy) = armyOrigin
            if let p = heroArtifactPlace(h, d, ox, oy, x: x, y: y), p.isBackpack ? h.backpack.indices.contains(p.index) : h.equipped[p.slot] != nil {
                s.artPress = p; s.drag = nil; return
            }
        }
        guard let r = armyRing(s, at: x, y), sessionRows(s)[r.row][r.k] != nil else { s.drag = nil; return }
        s.drag = r
        if s.selected != r { s.selected = r; heroShown = 0 }
    }
    func armyScreenDragged(x: Float, y: Float, shift: Bool) {
        if let s = armySession, s.artPress != nil || s.artDrag != nil {
            if s.artDrag == nil, let p = s.artPress {
                s.artPress = nil
                guard let d = ArtifactRules.pickUp(p) else { return }   // taken off at once (0x537650): the stats change
                s.artDrag = d
                refreshArtifactArmies(s)
                NSCursor.hide()
            }
            s.artAt = (x, y)
            return
        }
        guard let s = armySession, s.drag != nil else { return }
        if s.dragAt == nil { NSCursor.hide() }
        s.dragAt = (x, y)
        s.dragSplit = shift || s.splitMode
        if s.splitMode { s.splitMode = false }   // a drag ends split mode (0x6436fb)
    }
    /// Mouse up: a drop when dragging. True when it was a drag.
    func armyScreenRelease(x: Float, y: Float, shift: Bool) -> Bool {
        if let s = armySession, let d = s.artDrag {
            s.artDrag = nil; s.artAt = nil; s.artPress = nil
            NSCursor.unhide()
            artifactDrop(s, d, x: x, y: y)
            return true
        }
        armySession?.artPress = nil
        guard let s = armySession, let from = s.drag else { return false }
        defer { s.drag = nil; if s.dragAt != nil { NSCursor.unhide() }; s.dragAt = nil }
        guard s.dragAt != nil else { return false }
        if let to = armyRing(s, at: x, y) { armyDrop(s, from: from, to: to, split: shift || s.dragSplit) }
        return true
    }

    /// A click with the army screen open; it takes every click.
    func armyScreenClick(x: Float, y: Float) {
        guard let s = armySession, let g = game, let ui = ui, let d = ui.dialog("army.layout") else { closeArmyScreen(); return }
        let (ox, oy) = armyOrigin
        if s.note != nil { s.note = nil }
        // the split toggle (0x530e50)
        let split = s.double ? d["split_button"] : d["Single_Split_Button"]
        if inside(split, at: ox, oy, x, y) { s.splitMode.toggle(); sound?.play("miscellaneous.button"); return }
        if s.double, s.town == nil {
            if inside(d["Move_Army_Down"], at: ox, oy, x, y) { s.x.moveAll(from: 0, to: 1); sound?.play("miscellaneous.button"); return }
            if inside(d["Move_Army_Up"], at: ox, oy, x, y) { s.x.moveAll(from: 1, to: 0); sound?.play("miscellaneous.button"); return }
        }
        if let r = armyRing(s, at: x, y) {
            if sessionRows(s)[r.row][r.k] != nil { s.selected = r }
            return
        }
        // the backpack's scrollbar: a click above / below its middle steps it (rows of two)
        if sessionHero != nil, let sb = d["Scrollbar"], inside(sb, at: ox, oy, x, y) {
            scrollBackpack(s, by: y < Float(oy + sb.y + sb.height / 2) ? -1 : 1)
            return
        }
        // the army list: another army (the current one is finished first)
        if s.town == nil, let list = d["Army_list"] {
            let armies = g.armyList
            for k in 0..<min(4, armies.count) where inside(UILayer(name: "", kind: 1, x: list.x, y: list.y + 77 * k, width: list.width, height: 77, bitmap: Bitmap(width: 1, height: 1)), at: ox, oy, x, y) {
                let a = armies[k]
                guard a !== s.leader else { return }
                closeArmyScreen()
                if g.heroes.contains(where: { $0 === a }) { openArmyScreen(a) }
                return
            }
        }
        if inside(d["ok_button"], at: ox, oy, x, y) || x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 600) {
            sound?.play("miscellaneous.button")
            closeArmyScreen()
        }
    }
    func armyScreenKey(_ code: UInt16, chars: String) -> Bool {
        guard let s = armySession else { return false }
        if splitDialog != nil { return splitKey(code) }
        if code == 53 || code == 36 || code == 76 { closeArmyScreen(); return true }   // Escape / Enter: done
        if chars.lowercased() == text("split_creatures_army.hot_keys", "S").lowercased() { s.splitMode.toggle(); return true }
        return true
    }

    // MARK: drawing

    /// The rows on show, the selected place and what is in it.
    func armyScreenShown(_ s: ArmySession) -> (rows: [[ArmySlot?]], sel: (row: Int, k: Int), item: ArmySlot?) {
        let rows = sessionRows(s)
        let shownRows = s.double ? rows : [rows[0]]
        let sel: (row: Int, k: Int) = s.selected.row < shownRows.count ? s.selected : (0, 0)
        return (shownRows, sel, sel.k < shownRows[sel.row].count ? shownRows[sel.row][sel.k] : nil)
    }
    /// The creature's ability places (52x52, top-lefts relative to the screen).
    static let armyScreenAbilityColumns = [30, 90, 147, 204], armyScreenAbilityTop = 167

    func armyScreenQuads() -> [Quad] {
        guard let g = game, let ui = ui, let s = armySession, let d = ui.dialog("army.layout") else { return [] }
        let leader = s.leader
        let (ox, oy) = armyOrigin
        let (shownRows, sel, item) = armyScreenShown(s)
        let hero = item?.hero, stack = item?.stack
        // the army the shown one belongs to (its morale and bonuses)
        let owner: Hero = s.town != nil ? leader : sel.row == 1 ? (s.x.other ?? leader) : leader
        let creature = stack.flatMap { g.tables?.creature($0.creature) }
        var out = layoutImage(d, "Background", ox, oy)
        if let h = hero {
            out += layoutImage(d, "Hero_Background", ox, oy)
            out += heroThingsQuads(h, d, ox, oy)
        } else {
            out += layoutImage(d, "Creature_Background", ox, oy)
            if let st = stack { out += creatureModelQuads(st.creature, d, ox, oy) }
        }
        // buttons
        out += buttonAt("ok", "Released", d["ok_button"], ox, oy)
        for (n, on) in [("loose", true), ("tight", false), ("square", false)] { out += layoutImage(d, on ? "\(n)_pressed" : "\(n)_Released", ox, oy) }
        if stack != nil { out += buttonAt("dismiss", "Released", d["dismiss"], ox, oy) }
        out += buttonAt("hide_Potion", "Show_Potions_Released", d["Hide_Potions_Button"], ox, oy)
        if hero != nil || (creature?.spellPoints ?? 0) > 0 { out += layoutImage(d, "SpellBook_Released", ox, oy) }
        // the ring rows and the split toggle (pressed while split mode is on)
        let splitState = s.splitMode ? "Pressed" : "Released"
        if s.double {
            out += layoutImage(d, "Double_Ring_Background", ox, oy)
            out += buttonAt("split", splitState, d["split_button"], ox, oy)
            if s.town == nil {
                out += buttonAt("move_Down", "Released", d["Move_Army_Down"], ox, oy)
                out += buttonAt("move_Up", "Released", d["Move_Army_Up"], ox, oy)
            }
        } else {
            out += layoutImage(d, "Single_Ring_Background", ox, oy)
            out += buttonAt("split_Single", splitState, d["Single_Split_Button"], ox, oy)
        }
        let lifting = s.dragAt != nil ? s.drag : nil
        for (r, slots) in armyRowSlots(s, ox, oy).enumerated() {
            var items: [(icon: UILayer?, count: String?, hero: Bool)] = []
            for (k, slot) in shownRows[r].enumerated() {
                guard var it = slot else { items.append((nil, nil, false)); continue }
                if let l = lifting, l.row == r, l.k == k {   // a lifted stack leaves its place (a split drag keeps it)
                    guard s.dragSplit, it.stack.map({ $0.count > 1 }) ?? false else { items.append((nil, nil, false)); continue }
                    it = slot!
                }
                let (icon, count) = slotIcon(it, ui: ui)
                items.append((icon, count, it.hero != nil))
            }
            out += ringRowQuads(slots, items: items, selected: sel.row == r ? sel.k : nil)
        }
        if let l = lifting, let at = s.dragAt, let it = shownRows[safe: l.row]?[safe: l.k] ?? nil {
            let (icon, count) = slotIcon(it, ui: ui)
            if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: Int(at.0) - icon.width / 2, y: Int(at.1) - icon.height / 2, w: icon.width, h: icon.height)) }
            ringLabel(&out, ui: ui, cx: Int(at.0), cy: Int(at.1), count: s.dragSplit ? nil : count, hero: it.hero != nil)
        }
        // stat icons, always
        for n in ["Spell_Points", "Damage", "Hit Points", "Move", "Speed", "Experience", "Shots", "Melee_Attack", "Melee_Defense", "Ranged_Attack", "Ranged_Defense"] { out += layoutImage(d, n, ox, oy) }
        // morale and luck: icons.morale.34 "%i Morale" / "%i Luck", centred in their 39x39 places
        let members = owner.members
        let moraleArmy: [(alignment: String, undead: Bool)] = members.map { ($0.alignment, false) } + owner.army.compactMap { st in g.tables?.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        let bonus = ArmyBonuses(heroes: members)
        var morale = Battle.armyMorale(own: hero?.alignment ?? creature?.alignment ?? owner.alignment, army: moraleArmy)
        if let c = creature {
            if Combatant(creature: c, count: 1).has("undead") || Combatant(creature: c, count: 1).has("mechanical") { morale = 0 } else { morale += bonus.morale }
        }
        let luck = creature != nil ? bonus.luck : 0
        let icons = iconSheet("morale.34")
        for (slot, v, word) in [("Morale", min(10, max(-10, morale)), "morale"), ("Luck", min(10, max(-10, luck)), "luck")] {
            guard let l = d[slot], let ic = icons["\(v) \(word)"] else { continue }
            out.append(Quad(texture: uiTexture("moraleicon|\(ic.name)", { ic.bitmap }), x: ox + l.x + (l.width - ic.width) / 2, y: oy + l.y + (l.height - ic.height) / 2, w: ic.width, h: ic.height))
        }
        // the portrait (82 px, top-left at creature_portrait's) under Portrait_Border
        let portrait = hero.map { ui.portrait(keyword: $0.keyword, alignment: $0.alignment, size: 82) } ?? stack.map { ui.creatureIcon($0.creature, size: 82) }
        if let p = portrait ?? nil, let slot = d["creature_portrait"] {
            out.append(Quad(texture: uiTexture("p82|\(p.name)", { p.bitmap }), x: ox + slot.x, y: oy + slot.y, w: p.width, h: p.height))
        }
        out += layoutImage(d, "Portrait_Border", ox, oy)
        if hero == nil { out += layoutImage(d, "Abilities_Frame", ox, oy) } else { out += layoutImage(d, "Skill_Frame", ox, oy) }
        if let c = creature {
            let skills = iconSheet("skills.creature.52")
            let cols = Renderer.armyScreenAbilityColumns, top = Renderer.armyScreenAbilityTop
            for (k, ab) in abilityKeywords(c.keyword).prefix(4).enumerated() {
                if let l = skills[ab.lowercased()] { out.append(Quad(texture: uiTexture("skill|\(ab)", { l.bitmap }), x: ox + cols[k] + (52 - l.width) / 2, y: oy + top + (52 - l.height) / 2, w: l.width, h: l.height)) }
            }
        }
        // texts
        func t(_ str: String, _ slot: String, _ size: Int, centre: Bool = true, v: Bool = true) { out += armyText(str, d[slot], size: size, centre: centre, vcentre: v, ox, oy) }
        // the shown member's movement: its army's day minus what it spent (the exchange carries it)
        let rowMove: (left: Float, day: Float) = {
            if s.town == nil, sel.row < s.x.rows.count, sel.k < GameState.rowSlots {
                let day = sel.row == 0 ? s.x.main.maxMovement : (s.x.other?.maxMovement ?? s.x.main.maxMovement)
                return (max(0, day - s.x.spent[sel.row][sel.k]), day)
            }
            return (owner.movement, owner.maxMovement)
        }()
        if let h = hero {
            t(h.name, "name_text", 16, centre: false, v: false)
            t(classLine(h), "class_text", 16, centre: false, v: false)
            let st = g.heroStats(h)
            t(st.damage, "Damage_Text", 14); t("\(st.hitPoints)", "Hit_Points_Text", 14)
            t("\(Int(rowMove.left))\n(\(Int(rowMove.day)))", "Move_Text", 14); t("\(st.speed)", "Speed_Text", 14)
            t("\(st.shots)", "Shots_Text", 14); t(Renderer.grouped(h.experience), "Experience_Text", 20)
            t("\(st.attack)", "Melee_Attack_Text", 14); t("\(st.defense)", "Melee_Defense_Text", 14)
            t(st.shots > 0 ? "\(st.ranged)" : "N/A", "Ranged_Attack_Text", 14); t("\(st.defense)", "Ranged_Defense_Text", 14)
            t("\(g.spellPoints(h))\n(\(g.maxSpellPoints(h)))", "Spell_Points_Text", 14)
        } else if let c = creature, let st = stack {
            func tenths(_ v: Int, _ pct: Int) -> String {
                let x = Int((Double(v * (100 + pct)) / 10 + 0.5)); return x % 10 == 0 ? "\(x / 10)" : String(format: "%.1f", Double(x) / 10)
            }
            let ranged = c.shots > 0
            // the shown values (creature_info_spec §1): a shooter without normal melee strikes at half its
            // attack; insubstantial doubles defence, skeletal doubles it again against shots
            let ab = Set(RuleTables.creatureAbilities[c.keyword.lowercased()] ?? [])
            let melee = ranged && !ab.contains("normal_melee") ? c.attack / 2 : c.attack
            let defence = ab.contains("insubstantial") ? c.defense * 2 : c.defense
            let rangedDefence = ab.contains("skeletal") ? defence * 2 : defence
            t("\(st.count) \(st.count == 1 ? c.name : c.plural)", "name_text", 16, centre: false, v: false)
            t("\(c.damageLow)-\(c.damageHigh)", "Damage_Text", 14); t("\(c.hitPoints)", "Hit_Points_Text", 14)
            t("\(Int(rowMove.left))\n(\(Int(rowMove.day)))", "Move_Text", 14); t("\(c.speed + bonus.speed)", "Speed_Text", 14)
            t(ranged ? "\(c.shots)" : "N/A", "Shots_Text", 14)
            t(tenths(melee, bonus.attackPercent), "Melee_Attack_Text", 14); t(tenths(defence, bonus.defensePercent), "Melee_Defense_Text", 14)
            t(ranged ? tenths(c.attack, bonus.attackPercent) : "N/A", "Ranged_Attack_Text", 14); t(tenths(rangedDefence, bonus.defensePercent), "Ranged_Defense_Text", 14)
            if c.spellPoints > 0 { t("\(c.spellPoints)", "Spell_Points_Text", 14) }
            t(c.longHelp, "creature_text", 20, centre: false, v: true)
        }
        t(morale > 0 ? "+\(morale)" : "\(morale)", "Morale_Text", 18); t(luck > 0 ? "+\(luck)" : "\(luck)", "Luck_Text", 18)
        // the army list: 4 rows at (706, 210 + 77k) of adventure.army_rings; arrows only past 4 armies
        if s.town == nil, let list = d["Army_list"], let rings = (try? ui.archive.payload("layers.adventure.army_rings.h4d")).flatMap({ try? LayerFile(data: $0) }) {
            let armies = g.armyList
            for (k, h) in armies.prefix(4).enumerated() {
                let rx = ox + list.x, ry = oy + list.y + 77 * k
                if let p = rings["portrait"], let pic = armyPortrait(h) {
                    out.append(Quad(texture: uiTexture("icon|\(pic.name)", { pic.bitmap }), x: rx + p.x, y: ry + p.y, w: pic.width, h: pic.height))
                }
                if let f = rings[h === leader ? "Army_Frame_Highlight" : "Army_Frame"] ?? rings["Army_Frame"] {
                    out.append(Quad(texture: uiTexture("armyring|\(f.name)", { f.bitmap }), x: rx + f.x, y: ry + f.y, w: f.width, h: f.height))
                }
            }
            if armies.count > 4 { out += layoutImage(d, "Army_Up_Released", ox, oy); out += layoutImage(d, "Army_Down_Released", ox, oy) }
        }
        // the artifact in hand: its icon centred on the pointer (t_drag_artifact, hot spot w/2, h/2)
        if let a = s.artDrag, let at = s.artAt, let l = artifactIcon(a.artifact) {
            out.append(Quad(texture: uiTexture("art|\(a.artifact)", { l.bitmap }), x: Int(at.0) - l.width / 2, y: Int(at.1) - l.height / 2, w: l.width, h: l.height))
        }
        if let n = s.artNote { out += pointBoxQuads(n.text, cx: n.x, y: n.y) }
        out += heldHelpQuads()
        // a refused transfer's note over the place, for a few seconds
        if let n = s.note, Date().timeIntervalSince(n.since) < 4 { out += helpBalloonQuads(n.text, at: (Float(n.x), Float(n.y))) }
        return out
    }
    /// An army's picture in the lists: its leader's portrait, or a heroless army's strongest creature.
    func armyPortrait(_ h: Hero) -> UILayer? {
        guard let ui = ui else { return nil }
        if h.heroless {
            guard let g = game, let name = g.strongestCreature(h.army), let c = g.tables?.creatures.first(where: { $0.name == name }) else { return h.army.first.flatMap { ui.creatureIcon($0.creature) } }
            return ui.creatureIcon(c.keyword)
        }
        return ui.portrait(keyword: h.keyword, alignment: h.alignment)
    }
}
