import Foundation
import H4Engine

/// The combat options dialog (heroes4.exe t_combat_options, builder 0x6a7fc0; re/combat_save_spec.md):
/// layers.dialog.combat.options (699x491) centred; the effects and music volumes and the combat
/// speed (t_scrollbars as in the game settings); five toggles (damage, death and other numbers,
/// movement shadow, grid); the large New / Load / Save / Quit Game buttons; OK and Cancel.
enum CombatOptionsView {
    enum Hit { case none, ok, cancel, check(Int), slider(Int, Float), speedStep(Int), button(Int) }
    static let size = (w: 699, h: 491)
    static let boxes: [(name: String, key: String, fallback: String)] = [
        ("Show_Damage", "combat_options_show_damage_numbers.misc", "Show Damage Numbers"),
        ("Show_Death", "combat_options_show_death_numbers.misc", "Show Death Numbers"),
        ("Show_Miscellaneous", "combat_options_show_other_numbers.misc", "Show Other Numbers"),
        ("Show_Movement_Grid", "combat_options_show_movement_shading.misc", "Show Movement Shadow"),
        ("Show_Grid", "combat_options_show_combat_grid.misc", "Show Combat Grid")]
    /// slot, text rect, title: effects volume, music volume, combat speed (0x6eb380's three).
    static let sliders: [(slot: String, text: String, key: String, fallback: String)] = [
        ("sound_volume", "sound_text", "sound.dialog", "Effects Volume"),
        ("music_volume", "Music_text", "music.dialog", "Music Volume"),
        ("combat_animation_speed", "Combat_Speed_text", "combat.dialog", "Combat Speed")]
    /// New (0x6a8d90), Load (0x6a8e10), Save (0x6a9650), Quit Game (0x6a9160).
    static let buttons: [(hotspot: String, key: String, fallback: String)] = [
        ("New_Game_Button", "combat_options_new.misc", "New"),
        ("Load_Game_Button", "combat_options_load.misc", "Load"),
        ("Save_Game_Button", "combat_options_save.misc", "Save"),
        ("Quit_Game_Button", "combat_options_quit.misc", "Quit Game")]

    static func checked(_ k: Int, _ s: GameSettings) -> Bool {
        [s.showDamageNumbers ?? true, s.showDeathNumbers ?? true, s.showOtherNumbers ?? true, s.showMovementShading ?? false, s.showCombatGrid ?? false][k]
    }
    static func thumb(_ k: Int, _ s: GameSettings) -> Float {
        if k == 0 { return s.sound }
        if k == 1 { return s.music }
        let r = SpeedOption.positions
        return Float(SpeedOption.position(percent: s.speeds[1]) - r.lowerBound) / Float(r.upperBound - r.lowerBound)
    }
    static func value(_ k: Int, _ s: GameSettings) -> String {
        if k < 2 { return "\(Int((2 * log2(Double(max(k == 0 ? s.sound : s.music, 1.0 / 1024)))).rounded()))" }
        return "\(SpeedOption.position(percent: s.speeds[1]))"
    }

    static func items(_ kit: MenuKit, _ s: GameSettings, ox: Int, oy: Int, hover: (Float, Float)?) -> [UIItem] {
        guard let d = kit.file("dialog.combat.options") else { return [] }
        func l(_ n: String) -> UILayer? { MenuKit.find(d, n) }
        var out = kit.image(l("Background"), "combat_options", ox, oy)
        if let r = l("Title") { out += kit.text(kit.t("combat_options_title.misc", "Combat Options"), UIRect(r, ox, oy), MenuKit.Style(r.height, just: 1), clip: false) }
        for (k, b) in boxes.enumerated() {
            if let c = l("\(b.name)_Checkbox") {
                let on = checked(k, s)
                let hot = hover.map { UIRect(ox + c.x, oy + c.y, 34, 29).contains($0.0, $0.1) } ?? false
                let f = kit.file("button.checkbox")
                let names = hot ? [on ? "Highlighted_Pressed" : "Highlighted", on ? "Pressed" : "Released"] : [on ? "Pressed" : "Released"]
                if let img = names.lazy.compactMap({ MenuKit.find(f, $0) }).first { out += kit.image(img, "button.checkbox", ox + c.x, oy + c.y).button(true) }
            }
            if let t = l("\(b.name)_Text") { out += kit.text(kit.t(b.key, b.fallback), UIRect(t, ox, oy), MenuKit.Style(t.height), clip: false) }
        }
        for (k, sl) in sliders.enumerated() {
            if let r = l(sl.slot) { out += kit.hScrollbar(UIRect(r, ox, oy), value: thumb(k, s)) }
            if let t = l(sl.text) {
                out += kit.text(kit.t(sl.key, sl.fallback), UIRect(t, ox, oy), MenuKit.Style(t.height), clip: false)
                out += kit.text(value(k, s), UIRect(t, ox, oy), MenuKit.Style(t.height, just: 2), clip: false)
            }
        }
        for b in buttons {
            guard let r = l(b.hotspot) else { continue }
            let hot = hover.map { UIRect(ox + r.x, oy + r.y, 166, 40).contains($0.0, $0.1) } ?? false
            out += kit.largeButton(kit.t(b.key, b.fallback), ox + r.x, oy + r.y, hot ? .highlighted : .released)
        }
        if let b = l("ok_button") { out += kit.button("ok", .released, ox + b.x, oy + b.y) }
        if let b = l("cancel_button") { out += kit.button("cancel", .released, ox + b.x, oy + b.y) }
        return out
    }

    static func hit(_ kit: MenuKit, ox: Int, oy: Int, _ x: Float, _ y: Float, settings s: GameSettings) -> Hit {
        guard let d = kit.file("dialog.combat.options") else { return .none }
        func inside(_ n: String, w: Int? = nil, h: Int? = nil) -> Bool {
            guard let l = MenuKit.find(d, n) else { return false }
            return UIRect(ox + l.x, oy + l.y, w ?? l.width, h ?? l.height).contains(x, y)
        }
        if inside("ok_button", w: 76, h: 44) { return .ok }
        if inside("cancel_button", w: 76, h: 44) { return .cancel }
        for (k, b) in buttons.enumerated() where inside(b.hotspot, w: 166, h: 40) { return .button(k) }
        for (k, b) in boxes.enumerated() where inside("\(b.name)_Checkbox", w: 34, h: 29) || inside("\(b.name)_Text") { return .check(k) }
        for (k, sl) in sliders.enumerated() {
            guard let r = MenuKit.find(d, sl.slot) else { continue }
            let rect = UIRect(ox + r.x, oy + r.y, r.width, 41)
            guard rect.contains(x, y) else { continue }
            if k == 2 { return .speedStep(kit.hScrollbarSide(rect, x, value: thumb(k, s))) }
            return .slider(k, kit.hScrollbarValue(rect, x))
        }
        return .none
    }
    static func apply(_ h: Hit, to s: inout GameSettings) {
        switch h {
        case .check(let k):
            switch k {
            case 0: s.showDamageNumbers = !(s.showDamageNumbers ?? true)
            case 1: s.showDeathNumbers = !(s.showDeathNumbers ?? true)
            case 2: s.showOtherNumbers = !(s.showOtherNumbers ?? true)
            case 3: s.showMovementShading = !(s.showMovementShading ?? false)
            default: s.showCombatGrid = !(s.showCombatGrid ?? false)
            }
        case .slider(let k, let v): if k == 0 { s.sound = v } else { s.music = v }
        case .speedStep(let d):
            var all = s.speeds
            all[1] = SpeedOption.stepped(percent: all[1], by: d)
            s.speeds = all
        default: break
        }
    }
}

extension Renderer {
    var combatOptionsOrigin: (Int, Int) { ((AdventureUI.width - CombatOptionsView.size.w) / 2, (AdventureUI.height - CombatOptionsView.size.h) / 2) }

    /// The panel's options button / "O" (combat_options.hot_keys): the dialog with the settings as they are.
    func openCombatOptions() {
        var s = settings
        if s.showCombatGrid == nil { s.showCombatGrid = showCombatGrid }
        if s.showMovementShading == nil { s.showMovementShading = showMovementShading }
        combatOptions = s
        quitAfterSave = false
    }

    func combatOptionsQuads() -> [Quad] {
        var out: [Quad] = []
        if let s = combatOptions, let kit = kit {
            let (ox, oy) = combatOptionsOrigin
            out += quads(CombatOptionsView.items(kit, s, ox: ox, oy: oy, hover: pointerCanvas))
        }
        if combatQuitOpen { out += combatQuitQuads() }
        return out
    }

    /// A click while the dialog (or its Quit question) is open; returns true when one was.
    func combatOptionsClick(x: Float, y: Float) -> Bool {
        if combatQuitOpen { combatQuitClick(x: x, y: y); return true }
        guard var s = combatOptions, let kit = kit else { return false }
        let (ox, oy) = combatOptionsOrigin
        let h = CombatOptionsView.hit(kit, ox: ox, oy: oy, x, y, settings: s)
        switch h {
        case .ok:
            combatOptions = nil
            settings = s; applySettings(); settings.save()
        case .cancel: combatOptions = nil
        case .button(let k):
            // New / Load / Save close the dialog first (vtable +0x6c), then the combat window acts;
            // Quit Game asks over it (0x6a9160 does not close it: Cancel comes back here)
            if k < 3 { combatOptions = nil }
            switch k {
            case 0:   // New: the scenario list (the adventure's New Scenario)
                if let a = archivePath { relaunch([a, "--menu", "--screen", "scenarios"]) }
            case 1: openSaveDialog(.load)
            case 2: combatSave()
            default: combatQuitOpen = true
            }
        case .none: break
        default:
            CombatOptionsView.apply(h, to: &s)
            combatOptions = s
        }
        return true
    }

    /// A line on a battle's state (debugging the combat saves).
    static func battleSummary(_ b: Battle) -> String {
        "round \(b.round) current \(b.current?.id ?? -1) order \(b.order) units \(b.units.map { "\($0.id):\($0.keyword)x\($0.stats.count)-\($0.stats.wounds)@\($0.x),\($0.y)" })"
    }
    /// The battle as a save keeps it, or nil where it cannot be saved (a map script's battle, a test).
    func combatRecord() -> SaveGame.SavedCombat? {
        guard let cs = combat, let b = cs.battle, let g = game, let h = cs.hero, !cs.busy else { return nil }
        var c = g.savedCombat(hero: h, enemy: cs.enemy, monster: cs.placed == nil ? nil : cs.monsterIndex, placed: cs.placed, town: cs.siegeTown, battle: b)
        c?.screen = cs.savedScreen
        return c
    }
    /// Save (0x632400): the ordinary save dialog, or "You cannot save combat here."
    func combatSave() {
        guard combatRecord() != nil else {
            prompt = (text("save_not_supported.misc", "You cannot save combat here."), false, nil); return
        }
        casting = nil; castFirst = nil
        openSaveDialog(.save)
    }

    // MARK: Quit Game (0x6a9160): a basic dialog titled Quit with Quit, Save and Cancel

    func combatQuitLayout() -> (d: BasicDialog, x: Int, y: Int, buttons: [(x: Int, y: Int)])? {
        guard var d = basicDialog(text: "", title: text("quit", "Quit")) else { return nil }
        let row = 3 * 166 + 2 * 10
        d.W = max(d.W, row + 29 + 20); d.H = 60 + 40 + 31 + 10
        let x = (AdventureUI.width - d.W) / 2, y = (AdventureUI.height - d.H) / 2
        let bx = (d.W - row) / 2
        return (d, x, y, (0..<3).map { (x + bx + $0 * 176, y + 70) })
    }
    static let quitButtons = [("quit", "Quit"), ("save.dialog", "Save"), ("cancel", "Cancel")]
    func combatQuitQuads() -> [Quad] {
        guard let m = combatQuitLayout(), let kit = kit else { return [] }
        var out = basicDialogQuads(m.d, x: m.x, y: m.y)
        for (k, b) in Renderer.quitButtons.enumerated() {
            let p = m.buttons[k]
            let hot = UIRect(p.x, p.y, 166, 40).contains(pointerCanvas.0, pointerCanvas.1)
            out += quads(kit.largeButton(text(b.0, b.1), p.x, p.y, hot ? .highlighted : .released))
        }
        return out.modal()
    }
    func combatQuitClick(x: Float, y: Float) {
        guard let m = combatQuitLayout(), let k = m.buttons.firstIndex(where: { UIRect($0.x, $0.y, 166, 40).contains(x, y) }) else { return }
        combatQuitOpen = false
        switch k {
        case 0: Platform.quit()   // 0x6a9000 -> 0x4b6da0: the program ends
        case 2: break             // Cancel: back to the options
        case 1:   // save, and quit only once saved (0x6a8e90)
            combatOptions = nil
            guard combatRecord() != nil else { prompt = (text("save_not_supported.misc", "You cannot save combat here."), false, nil); return }
            quitAfterSave = true
            openSaveDialog(.save)
        default: break
        }
    }
}
