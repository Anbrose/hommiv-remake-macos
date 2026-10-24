import Foundation
import H4Engine

/// "The enemy turns to flee at your approach" (t_dialog_enemy_runs, ctor 0x6ae440; strings
/// registered by 0x6adef0; re/neutral_encounter_spec.md): layers.dialog.enemy_runs centred on the
/// adventure frame (0x6aec51..). Bitmap window "background"; the question enemy_runs_question.misc
/// in "text", font 0x875bc0(20), centred both ways (+0xc4, +0xd4); the three buttons Run / Fight /
/// Quick_Combat (Released, Highlighted under the pointer; images at their own boxes) and their labels
/// enemy_runs_run / _fight / _quick_combat.misc in run_text / fight_text / quick_combat_text,
/// in the font of the label's height, left and top. No picture of the stack: the dialog is given
/// nothing but its parent. Open while the game has a pendingFlee.
extension Renderer {
    static let enemyRunsButtons: [(layer: String, label: String, key: String, fallback: String, choice: GameState.FleeChoice)] = [
        ("Run", "run_text", "enemy_runs_run.misc", "Let Them Run", .letThemRun),
        ("Fight", "fight_text", "enemy_runs_fight.misc", "Fight", .fight),
        ("Quick_Combat", "quick_combat_text", "enemy_runs_quick_combat.misc", "Use Quick Combat", .quickCombat)]

    func enemyRunsOrigin(_ d: LayerFile) -> (Int, Int) {
        let bg = dLayer(d, "background")
        return ((AdventureUI.width - (bg?.width ?? 380)) / 2, (AdventureUI.height - (bg?.height ?? 419)) / 2)
    }

    func enemyRunsQuads() -> [Quad] {
        guard let g = game, g.pendingFlee != nil, let ui = ui, let d = ui.dialog("enemy_runs") else { return [] }
        let (ox, oy) = enemyRunsOrigin(d)
        var out = dImage(d, "enemy_runs", "background", ox, oy)
        out += dText(text("enemy_runs_question.misc", "The enemy turns to flee at your approach.  Do you:"), dRect(d, "text"),
                     font: dFont(20), centre: true, vcentre: true, ox, oy)
        for b in Renderer.enemyRunsButtons {
            let rel = dLayer(d, "\(b.layer)_Released")
            let over = rel.map { hoverButton((ox + $0.x, oy + $0.y, $0.width, $0.height)) } ?? false
            out += dImage(d, "enemy_runs", "\(b.layer)_\(over ? "Highlighted" : "Released")", ox, oy).button()
            let r = dRect(d, b.label)
            out += dText(text(b.key, b.fallback), r, font: dFont(r?.h ?? 19), centre: false, ox, oy)
        }
        return out
    }

    /// A click with the question up (it is modal): a button answers it.
    func enemyRunsClick(x: Float, y: Float) -> Bool {
        guard let g = game, g.pendingFlee != nil else { return false }
        guard let d = ui?.dialog("enemy_runs") else { g.resolveFlee(.fight); return true }
        let (ox, oy) = enemyRunsOrigin(d)
        for b in Renderer.enemyRunsButtons where dRect(d, "\(b.layer)_Released")?.offset(ox, oy).contains(x, y) == true {
            g.resolveFlee(b.choice)
            break
        }
        return true
    }
}
