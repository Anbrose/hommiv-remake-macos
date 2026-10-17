import Foundation
import AppKit
import H4Engine

/// The Tab box (t_dialog_cheat 0x5cede0, re/cheats_spec.md §2): a t_text_edit_window of 300 x 50
/// centred on the screen, no background, the text in RGB(175,245,140) with a black halo in the
/// largest font <= 30, centred both ways, a 2 px cursor of the text's colour blinking every 500 ms.
/// Enter closes it and tries the text as a code (GameState.enterCheat); Esc only deactivates it
/// (the text stays shown, the key goes on to the screen); Tab opens a fresh one.
struct CheatBox {
    var text = ""
    var cursor = 0
    var active = true
    /// The cursor's blink phase starts again with each key.
    var since = Date()
    let screen: Cheats.Screen
}

extension Renderer {
    /// The box: the root window's centre +- (150, 25) (0x5cee9c).
    static var cheatRect: UIRect { UIRect(AdventureUI.width / 2 - 150, AdventureUI.height / 2 - 25, 300, 50) }
    static let cheatColour: MenuKit.RGB = (175, 245, 140)
    static let cheatStyle = MenuKit.Style(30, colour: Renderer.cheatColour, halo: (0, 0, 0), just: 1, vcentre: true)

    var cheatScreen: Cheats.Screen { inCombat ? .combat : townOpen != nil ? .town : .adventure }

    /// Tab (key 9 without Shift / Ctrl / Alt) in the adventure, combat and town key handlers: a
    /// fresh, empty box (the previous one closed).
    func openCheatBox(text: String = "") {
        cheatBox = CheatBox(text: text, cursor: text.count, active: true, since: Date(), screen: cheatScreen)
    }

    /// A key while the box is up. True when it was used (the screen does not see it).
    func cheatBoxKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.shift, .control, .option])
        if e.keyCode == 48, mods.isEmpty, game != nil, saveDialog == nil, prompt == nil {   // Tab
            openCheatBox()
            return true
        }
        guard var b = cheatBox, b.active else { return false }
        b.since = Date()
        var chars = Array(b.text)
        switch e.keyCode {
        case 36, 76:   // Enter: deactivate, then the on-enter handler 0x5cf240
            cheatBox = nil
            submitCheat(b)
            return true
        case 53:       // Esc (0x885274): inactive, no cursor, no focus; the key goes on
            b.active = false
            cheatBox = b
            return false
        case 51:       // Backspace
            if b.cursor > 0 { chars.remove(at: b.cursor - 1); b.cursor -= 1 }
        case 117:      // Delete
            if b.cursor < chars.count { chars.remove(at: b.cursor) }
        case 123: b.cursor = max(0, b.cursor - 1)
        case 124: b.cursor = min(chars.count, b.cursor + 1)
        default:
            // a character: inserted at the cursor, taken back when the text would need more lines
            // than the box holds (0x8853c6); control characters are swallowed
            for c in e.characters ?? "" where c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f || ($0.value >= 0xa0 && $0.value < 0x100) }) {
                var next = chars
                next.insert(c, at: b.cursor)
                if let kit = kit {
                    let r = Renderer.cheatRect, f = kit.font(Renderer.cheatStyle.size)
                    if kit.lines(String(next), Renderer.cheatStyle, width: r.w).count > max(1, r.h / max(1, f.lineHeight)) { continue }
                }
                chars = next; b.cursor += 1
            }
        }
        b.text = String(chars)
        cheatBox = b
        return true
    }

    /// A click on the box gives it the focus again.
    func cheatBoxClick(x: Float, y: Float) -> Bool {
        guard var b = cheatBox, !b.active, Renderer.cheatRect.contains(x, y) else { return false }
        b.active = true; b.since = Date(); b.cursor = b.text.count
        cheatBox = b
        return true
    }

    /// The text tried as a code, and what the screen does after.
    func submitCheat(_ b: CheatBox) {
        guard let g = game else { return }
        let town = b.screen == .town ? townOpen : nil
        switch g.enterCheat(b.text, on: b.screen, town: town) {
        case .nothing, .done: break
        case .message(let s): prompt = (s, false, nil)
        case .gainSkillMenu(let h): openGainSkillMenu(h)
        case .newGame:
            // (in combat 0x6320f0 only while the battle waits for orders)
            if b.screen == .combat, combat?.awaitingOrders != true { break }
            if let a = archivePath { relaunch([a, "--menu", "--screen", "scenarios"]) }
        case .dumpMapImage:
            toasts.append(("Dump Entire Map Image: not available", Date().addingTimeInterval(3)))
        case .combat(let c):
            guard let cs = combat, let bt = cs.battle else { break }
            switch c {
            case .winCombat, .loseCombat:
                bt.cheatEnd(playerWins: c == .winCombat)
                cs.pump()
            default:
                // 0x632900: only while the battle waits for the player's orders
                guard cs.awaitingOrders else { break }
                if !bt.cheatHeroModel(c == .tattooedWhiteTrash ? 1 : 2) {
                    prompt = (text("not_a_hero.misc", "This only works on heroes."), false, nil)
                }
            }
        }
    }

    // MARK: Gain Skill (0x4b7440): scroll menus at the pointer

    func openGainSkillMenu(_ h: Hero) {
        guard let g = game else { return }
        let items: [(String, () -> Void)] = g.gainSkillFamilies(h).map { p in (Cheats.familyLabels[p], { [weak self] in self?.openGainSkillSkills(h, p) }) }
        popupAtPointer(items)
    }
    func openGainSkillSkills(_ h: Hero, _ family: Int) {
        guard let g = game else { return }
        popupAtPointer(g.gainSkillChoices(h, family: family).map { s in (g.skillName(s), { [weak self] in self?.openGainSkillLevels(h, s) }) })
    }
    func openGainSkillLevels(_ h: Hero, _ s: Int) {
        guard let g = game else { return }
        popupAtPointer(g.gainSkillLevels(h, skill: s).map { l in (RuleTables.skillLevelNames[l].capitalized, { [weak self] in
            guard let self = self, let g = self.game else { return }
            self.prompt = (g.gainSkill(h, skill: s, level: l), false, nil)
        }) })
    }
    /// One entry runs at once; more open a scroll menu at the pointer (0x8d1470 -> 0x8390d0).
    func popupAtPointer(_ items: [(String, () -> Void)]) {
        if items.count == 1 { items[0].1(); return }
        guard !items.isEmpty else { return }
        let x = min(AdventureUI.width, max(212, Int(pointerCanvas.0))), y = max(0, min(AdventureUI.height - 200, Int(pointerCanvas.1)))
        menu = PopupMenu(items: items.map { (title: $0.0, action: $0.1) }, x: x, y: y)
    }

    // MARK: drawing

    func cheatBoxQuads(now: Date = Date()) -> [Quad] {
        guard let b = cheatBox, let kit = kit else { return [] }
        let r = Renderer.cheatRect, st = Renderer.cheatStyle
        var out = quads(kit.text(b.text, r, st, clip: false))
        // the cursor (0x885650): 2 px x the line height, after the character at the cursor
        guard b.active, Int(now.timeIntervalSince(b.since) / 0.5) % 2 == 0 else { return out }
        let f = kit.font(st.size)
        let lines = b.text.isEmpty ? [""] : kit.lines(b.text, st, width: r.w)
        var left = b.cursor, row = 0
        while row < lines.count - 1, left > lines[row].count { left -= lines[row].count + 1; row += 1 }   // the wrap ate one space
        let line = lines[row], w = f.measure(line)
        let x0 = r.x + max(0, (r.w - w) / 2) + f.measure(String(line.prefix(max(0, min(left, line.count)))))
        let total = lines.count * f.lineHeight
        let y0 = (total < r.h ? r.y + (r.h - total) / 2 : r.y) + row * f.lineHeight
        let c = Renderer.cheatColour
        out.append(Quad(texture: uiTexture("cheatcursor|\(c.0),\(c.1),\(c.2)", {
            var bm = Bitmap(width: 1, height: 1)
            bm.pixels = [c.0, c.1, c.2, 255]
            return bm
        }), x: x0, y: y0, w: 2, h: f.lineHeight))
        return out
    }
}
