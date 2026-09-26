import Foundation
import AppKit
import H4Engine

/// The game settings (layers.dialog.options): Quick Combat, Show Coordinates, Movement Reminder,
/// Show Movement Path, Show Animations; army, combat and enemy speed; music and sound volume.
/// Kept in the user defaults between games.
struct GameSettings: Codable {
    var quickCombat = false, showCoordinates = false, movementReminder = true, showMovementPath = true, showAnimations = true
    var armySpeed: Float = 0.5, combatSpeed: Float = 0.5, enemySpeed: Float = 0.5, music: Float = 0.5, sound: Float = 0.8
    static func load() -> GameSettings {
        guard let d = UserDefaults.standard.data(forKey: "h4view.settings"), let s = try? JSONDecoder().decode(GameSettings.self, from: d) else { return GameSettings() }
        return s
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "h4view.settings") } }
}

extension Renderer {
    var optionsOrigin: (Int, Int) { ((AdventureUI.width - 700) / 2, (AdventureUI.height - 560) / 2) }
    static let optionBoxes: [(box: String, text: String, key: String, fallback: String)] = [
        ("Quick_Combat_Checkbox", "Quick_Combat_Text", "options_quick_combat.misc", "Quick Combat"),
        ("Coordinates_Checkbox", "Coordinates_Text", "options_show_coordinates.misc", "Show Coordinates"),
        ("Army_Reminder_Checkbox", "Army_Reminder_Text", "options_army_reminder.misc", "Movement Reminder"),
        ("Movement_Path_Checkbox", "Movement_Path_Text", "options_movement_path.misc", "Show Movement Path"),
        ("Animation_Checkbox", "Animation_Text", "options_adventure_animations.misc", "Show Animations")]
    static let optionSliders: [(slot: String, text: String, key: String, fallback: String)] = [
        ("army_animation_speed", "Army_Speed_Text", "your_armies.options", "Army Speed"),
        ("combat_animation_speed", "Combat_Speed_text", "combat_speed.options", "Combat Speed"),
        ("enemy_animation_speed", "Enemy_Speed_Text", "other_armies.options", "Enemy Speed"),
        ("music_volume", "Music_Text", "music_volume.options", "Music Volume"),
        ("sound_volume", "sound_text", "sound_volume.options", "Sound Volume")]

    func checkbox(_ k: Int, _ s: GameSettings) -> Bool {
        [s.quickCombat, s.showCoordinates, s.movementReminder, s.showMovementPath, s.showAnimations][k]
    }
    func sliderValue(_ k: Int, _ s: GameSettings) -> Float { [s.armySpeed, s.combatSpeed, s.enemySpeed, s.music, s.sound][k] }

    func optionsQuads() -> [Quad] {
        guard let s = optionsOpen, let ui = ui, let d = ui.dialog("options") else { return [] }
        let (ox, oy) = optionsOrigin
        var out = dialogImages(d, key: "options", at: ox, oy)
        out += centred(text("options_title.misc", "Game Settings"), in: d["Title"], at: ox, oy, font: ui.dateFont)
        out += centred(text("options_right_options.misc", "Options"), in: d["Options"], at: ox, oy, font: ui.dateFont)
        out += centred("1024 x 768", in: d["1024_text"], at: ox, oy, font: ui.numberFont)
        out += centred(text("resolution.options", "Resolution"), in: d["resolution_text"], at: ox, oy, font: ui.dateFont)
        for (k, o) in Renderer.optionBoxes.enumerated() {
            if let box = d[o.box], let b = ui.button("checkbox", state: checkbox(k, s) ? "Pressed" : "Released") {
                out.append(Quad(texture: uiTexture("button|checkbox|\(checkbox(k, s))", { b.bitmap }), x: ox + box.x + (box.width - b.width) / 2, y: oy + box.y + (box.height - b.height) / 2, w: b.width, h: b.height))
            }
            if let t = d[o.text] { out += paragraph(text(o.key, o.fallback), in: t, at: ox, oy, font: ui.numberFont) }
        }
        if let box = d["1024_checkbox"], let b = ui.button("checkbox", state: "Pressed") {
            out.append(Quad(texture: uiTexture("button|checkbox|true", { b.bitmap }), x: ox + box.x + (box.width - b.width) / 2, y: oy + box.y + (box.height - b.height) / 2, w: b.width, h: b.height))
        }
        // the sliders: layers.control.horizontal_scroll's arrows, track and thumb
        let scroll = (try? ui.archive.payload("layers.control.horizontal_scroll.h4d")).flatMap { try? LayerFile(data: $0) }
        for (k, o) in Renderer.optionSliders.enumerated() {
            // (the layout's label names differ in case between the archives)
            let label = d[o.text] ?? d.layers.first { $0.name.lowercased() == o.text.lowercased() }
            out += centred(text(o.key, o.fallback), in: label, at: ox, oy, font: ui.numberFont)
            guard let r = d[o.slot], let sc = scroll, let up = sc["Up_Released"], let down = sc["Down_Released"], let bg = sc["Background"], let th = sc["Thumb"] else { continue }
            let x0 = ox + r.x, y0 = oy + r.y + (r.height - up.height) / 2
            let scale = Float(r.height) / Float(up.height)
            func q(_ l: UILayer, _ x: Int, _ w: Int? = nil) -> Quad {
                Quad(texture: uiTexture("hscroll|\(l.name)", { l.bitmap }), x: x, y: oy + r.y, w: w ?? Int(Float(l.width) * scale), h: r.height)
            }
            let uw = Int(Float(up.width) * scale), dw = Int(Float(down.width) * scale)
            out.append(q(bg, x0 + uw, r.width - uw - dw))
            out.append(q(up, x0)); out.append(q(down, x0 + r.width - dw))
            let tw = Int(Float(th.width) * scale)
            let tx = x0 + uw + Int(Float(r.width - uw - dw - tw) * sliderValue(k, s))
            out.append(q(th, tx))
            _ = y0
        }
        for (slot, name) in [("ok_button", "ok"), ("cancel_button", "cancel")] {
            if let l = d[slot], let b = ui.button(name) {
                out.append(Quad(texture: uiTexture("button|\(name)|\(b.name)", { b.bitmap }), x: ox + l.x + (l.width - b.width) / 2, y: oy + l.y + (l.height - b.height) / 2, w: b.width, h: b.height))
            }
        }
        return out
    }

    func optionsClick(x: Float, y: Float) {
        guard var s = optionsOpen, let d = ui?.dialog("options") else { optionsOpen = nil; return }
        let (ox, oy) = optionsOrigin
        for (k, o) in Renderer.optionBoxes.enumerated() where inside(d[o.box], at: ox, oy, x, y) || inside(d[o.text], at: ox, oy, x, y) {
            switch k {
            case 0: s.quickCombat.toggle()
            case 1: s.showCoordinates.toggle()
            case 2: s.movementReminder.toggle()
            case 3: s.showMovementPath.toggle()
            default: s.showAnimations.toggle()
            }
            sound?.play("miscellaneous.button")
        }
        for (k, o) in Renderer.optionSliders.enumerated() {
            guard let r = d[o.slot], inside(r, at: ox, oy, x, y) else { continue }
            let v = max(0, min(1, (x - Float(ox + r.x + 30)) / Float(max(1, r.width - 60))))
            switch k {
            case 0: s.armySpeed = v
            case 1: s.combatSpeed = v
            case 2: s.enemySpeed = v
            case 3: s.music = v
            default: s.sound = v
            }
        }
        if inside(d["ok_button"], at: ox, oy, x, y) { optionsOpen = nil; settings = s; applySettings(); settings.save(); sound?.play("miscellaneous.button"); return }
        if inside(d["cancel_button"], at: ox, oy, x, y) { optionsOpen = nil; sound?.play("miscellaneous.button"); return }
        optionsOpen = s
    }

    /// Put the settings to work.
    func applySettings() {
        sound?.effectVolume = settings.sound
        sound?.setMusicVolume(settings.music)
        game?.quickCombatOnly = settings.quickCombat
        GameState.cellsPerSecond = 2 + settings.armySpeed * 8
        combat?.animationSpeed = Int(50 + settings.combatSpeed * 250)
    }
}
