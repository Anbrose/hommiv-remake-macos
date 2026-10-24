import Foundation
import AppKit
import H4Engine

/// The game settings (layers.dialog.options): Quick Combat, Show Coordinates, Movement Reminder,
/// Show Movement Path, Show Animations; army, combat and enemy speed; music and sound volume.
/// Kept in the user defaults between games.
struct GameSettings: Codable {
    var quickCombat = false, showCoordinates = false, movementReminder = true, showMovementPath = true, showAnimations = true
    var music: Float = 0.5, sound: Float = 0.8
    /// The speeds in percent as heroes4.exe keeps them (registry army_speed / combat_speed /
    /// enemy_speed, defaults 150 / 150 / 200; SpeedOption): nil until set.
    var armySpeedPercent: Int? = nil, combatSpeedPercent: Int? = nil, enemySpeedPercent: Int? = nil
    var fullScreen: Bool? = nil
    /// The combat options "Show Combat Grid" (show_combat_grid) and "Show Movement Shadow"
    /// (show_combat_movement_shading): both off unless set (heroes4.exe 0x7c91d0 defaults them to 0).
    var showCombatGrid: Bool? = nil, showMovementShading: Bool? = nil
    static func load() -> GameSettings {
        guard let d = UserDefaults.standard.data(forKey: "h4view.settings"), let s = try? JSONDecoder().decode(GameSettings.self, from: d) else { return GameSettings() }
        return s
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "h4view.settings") } }
    /// The three speeds (army, combat, enemy) in percent.
    var speeds: [Int] {
        get { [armySpeedPercent ?? SpeedOption.defaultArmy, combatSpeedPercent ?? SpeedOption.defaultCombat, enemySpeedPercent ?? SpeedOption.defaultEnemy] }
        set { armySpeedPercent = newValue[0]; combatSpeedPercent = newValue[1]; enemySpeedPercent = newValue[2] }
    }
}

/// The options dialog (t_options_dialog, menus_spec A.3), shared by the adventure screen and the main
/// menu's Options > Game Settings: layers.dialog.options (700x560) centred; checkboxes from
/// layers.button.checkbox at the `<name>_checkbox` hotspots' top-left with their labels in
/// `<name>_text` (Prose_Antique 20, black with the halo, left and top); the title (PA.24) and the two
/// headings (PA.20 / PA.18) centred; five horizontal t_scrollbars with a title (left) and a value
/// (right) in the same `*_Text` rect (PA.16); OK and Cancel at their hotspots' top-left.
enum OptionsView {
    enum Hit { case none, ok, cancel, check(Int), resolution(Int), fullScreen, slider(Int, Float), speedStep(Int, Int) }
    static let boxes: [(name: String, key: String, fallback: String)] = [
        ("Quick_Combat", "options_quick_combat.misc", "Quick Combat"),
        ("Coordinates", "options_show_coordinates.misc", "Show Coordinates"),
        ("Army_Reminder", "options_army_reminder.misc", "Movement Reminder"),
        ("Movement_Path", "options_movement_path.misc", "Show Movement Path"),
        ("Animation", "options_adventure_animations.misc", "Show Animations")]
    static let sliders: [(slot: String, text: String, key: String, fallback: String)] = [
        ("army_animation_speed", "Army_Speed_Text", "your_armies.options", "Army Speed"),
        ("combat_animation_speed", "Combat_Speed_text", "combat.dialog", "Combat Speed"),
        ("enemy_animation_speed", "Enemy_Speed_Text", "other_armies.options", "Enemy Speed"),
        ("music_volume", "Music_Text", "music.dialog", "Music Volume"),
        ("sound_volume", "sound_text", "sound.dialog", "Effects Volume")]
    static let resolutions = ["800", "1024", "1280"]
    static func origin(_ w: Int, _ h: Int) -> (Int, Int) { ((w - 700) / 2, (h - 560) / 2) }

    static func checked(_ k: Int, _ s: GameSettings) -> Bool { [s.quickCombat, s.showCoordinates, s.movementReminder, s.showMovementPath, s.showAnimations][k] }
    /// The number shown right of a slider's title: the volumes as round(2 log2(v)) (0 at full); a
    /// speed as its slider position -2...6 ("%d", 0x6ebde0), the enemy speed's last one "Off"
    /// (speed_off.options, 0x7cbde0).
    static func value(_ k: Int, _ s: GameSettings, _ kit: MenuKit) -> String {
        if k >= 3 { return "\(Int((2 * log2(Double(max(k == 3 ? s.music : s.sound, 1.0 / 1024)))).rounded()))" }
        let pos = SpeedOption.position(percent: s.speeds[k])
        if k == 2 && pos == SpeedOption.positions.upperBound { return kit.t("speed_off.options", "Off") }
        return "\(pos)"
    }
    /// The thumb's place, 0...1: a speed's position in -2...6 (0x83b1da), a volume as kept.
    static func thumb(_ k: Int, _ s: GameSettings) -> Float {
        if k == 3 { return s.music }
        if k == 4 { return s.sound }
        let r = SpeedOption.positions
        return Float(SpeedOption.position(percent: s.speeds[k]) - r.lowerBound) / Float(r.upperBound - r.lowerBound)
    }

    static func items(_ kit: MenuKit, _ s: GameSettings, ox: Int, oy: Int, hover: (Float, Float)?) -> [UIItem] {
        guard let d = kit.file("dialog.options") else { return [] }
        func l(_ n: String) -> UILayer? { MenuKit.find(d, n) }
        var out = kit.image(l("Background"), "options", ox, oy)
        func label(_ s: String, _ n: String, _ size: Int? = nil, just: Int = 0) {
            guard let r = l(n) else { return }
            out += kit.text(s, UIRect(r, ox, oy), MenuKit.Style(size ?? r.height, just: just), clip: false)
        }
        label(kit.t("options_title.misc", "Game Settings"), "Title", just: 1)
        label(kit.t("screen_resolution", "Screen Resolution"), "resolution_text", just: 1)
        label(kit.t("options_right_options.misc", "Options"), "Options", just: 1)
        func checkbox(_ name: String, _ on: Bool, stayDown: Bool = false) {   // t_toggle_buttons; a stay-down one that is down is silent (0x88d0b0)
            guard let c = l("\(name)_checkbox") else { return }
            let hot = hover.map { UIRect(ox + c.x, oy + c.y, 34, 29).contains($0.0, $0.1) } ?? false
            let f = kit.file("button.checkbox")
            let names = hot ? [on ? "Highlighted_Pressed" : "Highlighted", on ? "Pressed" : "Released"] : [on ? "Pressed" : "Released"]
            if let b = names.lazy.compactMap({ MenuKit.find(f, $0) }).first { out += kit.image(b, "button.checkbox", ox + c.x, oy + c.y).button(!(stayDown && on)) }
        }
        let names = ["800 x 600", "1024 x 768", "1280 x 1024"]
        for (k, r) in resolutions.enumerated() {
            checkbox(r, r == "1024", stayDown: true)
            label(names[k], "\(r)_text")
        }
        checkbox("full_screen", s.fullScreen ?? false)
        label(kit.t("full_screen", "Full Screen"), "full_screen_text")
        for (k, b) in boxes.enumerated() {
            checkbox(b.name, checked(k, s))
            label(kit.t(b.key, b.fallback), "\(b.name)_text")
        }
        for (k, sl) in sliders.enumerated() {
            if let r = l(sl.slot) { out += kit.hScrollbar(UIRect(r, ox, oy), value: thumb(k, s)) }
            if let t = l(sl.text) {
                out += kit.text(kit.t(sl.key, sl.fallback), UIRect(t, ox, oy), MenuKit.Style(t.height), clip: false)
                out += kit.text(value(k, s, kit), UIRect(t, ox, oy), MenuKit.Style(t.height, just: 2), clip: false)
            }
        }
        if let b = l("ok_button") { out += kit.button("ok", .released, ox + b.x, oy + b.y) }
        if let b = l("cancel_button") { out += kit.button("cancel", .released, ox + b.x, oy + b.y) }
        return out
    }

    static func hit(_ kit: MenuKit, ox: Int, oy: Int, _ x: Float, _ y: Float, settings s: GameSettings) -> Hit {
        guard let d = kit.file("dialog.options") else { return .none }
        func inside(_ n: String, w: Int? = nil, h: Int? = nil) -> Bool {
            guard let l = MenuKit.find(d, n) else { return false }
            return UIRect(ox + l.x, oy + l.y, w ?? l.width, h ?? l.height).contains(x, y)
        }
        if inside("ok_button", w: 76, h: 44) { return .ok }
        if inside("cancel_button", w: 76, h: 44) { return .cancel }
        for (k, b) in boxes.enumerated() where inside("\(b.name)_checkbox", w: 34, h: 29) || inside("\(b.name)_text") { return .check(k) }
        for (k, r) in resolutions.enumerated() where inside("\(r)_checkbox", w: 34, h: 29) || inside("\(r)_text") { return .resolution(k) }
        if inside("full_screen_checkbox", w: 34, h: 29) || inside("full_screen_text") { return .fullScreen }
        for (k, sl) in sliders.enumerated() {
            guard let r = MenuKit.find(d, sl.slot) else { continue }
            let rect = UIRect(ox + r.x, oy + r.y, r.width, 41)
            guard rect.contains(x, y) else { continue }
            // a speed's t_scrollbar: an arrow or the track either side of the thumb moves it by one
            // position (0x83c3b4 / 0x83af60, page (6 - -2) / 5 = 1)
            if k < 3 { return .speedStep(k, kit.hScrollbarSide(rect, x, value: thumb(k, s))) }
            return .slider(k, kit.hScrollbarValue(rect, x))
        }
        return .none
    }
    /// A click's effect on the settings being edited.
    static func apply(_ h: Hit, to s: inout GameSettings) {
        switch h {
        case .check(let k):
            switch k {
            case 0: s.quickCombat.toggle()
            case 1: s.showCoordinates.toggle()
            case 2: s.movementReminder.toggle()
            case 3: s.showMovementPath.toggle()
            default: s.showAnimations.toggle()
            }
        case .fullScreen: s.fullScreen = !(s.fullScreen ?? false)
        case .slider(let k, let v):
            if k == 3 { s.music = v } else if k == 4 { s.sound = v }
        case .speedStep(let k, let d):
            var all = s.speeds
            all[k] = SpeedOption.stepped(percent: all[k], by: d)
            s.speeds = all
        default: break
        }
    }
}

extension Renderer {
    var optionsOrigin: (Int, Int) { OptionsView.origin(AdventureUI.width, AdventureUI.height) }

    func optionsQuads() -> [Quad] {
        guard let s = optionsOpen, let kit = kit else { return [] }
        let (ox, oy) = optionsOrigin
        return quads(OptionsView.items(kit, s, ox: ox, oy: oy, hover: pointerCanvas))
    }

    func optionsClick(x: Float, y: Float) {
        guard var s = optionsOpen, let kit = kit else { optionsOpen = nil; return }
        let (ox, oy) = optionsOrigin
        let h = OptionsView.hit(kit, ox: ox, oy: oy, x, y, settings: s)
        switch h {
        case .ok:
            optionsOpen = nil
            if (s.fullScreen ?? false) != (settings.fullScreen ?? false) { NSApp.keyWindow?.toggleFullScreen(nil) }
            settings = s; applySettings(); settings.save(); return
        case .cancel: optionsOpen = nil; return
        case .none: break
        default: OptionsView.apply(h, to: &s)
        }
        optionsOpen = s
    }

    /// Put the settings to work.
    func applySettings() {
        sound?.effectVolume = settings.sound
        sound?.setMusicVolume(settings.music)
        game?.quickCombatOnly = settings.quickCombat
        // the speeds in percent as the exe keeps them (SpeedOption; 0x7cbe40 / 0x6ecb50)
        let sp = settings.speeds
        GameState.armySpeedPercent = sp[0]
        combat?.animationSpeed = sp[1]
        GameState.otherArmySpeedPercent = sp[2]
        GameState.showEnemyMoves = SpeedOption.showsEnemyMoves(sp[2])
    }
}
