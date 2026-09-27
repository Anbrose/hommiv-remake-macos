import Foundation
import H4Engine

/// The combat window's right side (combat_ui_spec §A): layers.combat.1024's Background and
/// Border, the buttons with their images' top-left at the hotspots' top-left, the one mode
/// button of five in the `melee` slot, the portrait ring of control.creature_select, and the
/// panel: the health / spell points / shots icons and numbers (Prose_Antique 14, black, centred,
/// top-aligned), which give way to the action message while one shows.
extension Renderer {
    /// The mode buttons' files by mode (0 shoot, 1 strike and return, 2 melee, 3 cast spell, 4 move).
    static let modeButtons = ["shoot", "strike_and_return", "melee", "cast_spell", "move"]

    /// A stack's full spell points (a hero's from the hero; a creature caster's what it started with).
    func maxSpellPoints(_ u: Battle.Unit) -> Int {
        if let h = combat?.heroFor(u), let g = game { return max(g.maxSpellPoints(h), u.caster?.spellPoints ?? 0) }
        return u.caster?.spellPoints ?? 0
    }
    /// A stack's portrait (vf48): a hero's from icons.hero.<alignment>.<size>, a creature's icon.
    func unitPortrait(_ u: Battle.Unit, size: Int) -> UILayer? {
        guard let ui = ui else { return nil }
        if u.stats.isHero {
            let a = combat?.heroFor(u)?.alignment ?? (u.actor.hasPrefix("hero.") ? String(u.actor.dropFirst(5).prefix { $0 != "_" }) : "life")
            return ui.portrait(keyword: u.keyword, alignment: a, size: size)
        }
        return ui.creatureIcon(u.keyword, size: size)
    }

    struct CombatButton { let hotspot: String, file: String, key: String, enabled: Bool, pressed: Bool }
    /// The buttons shown now and their states (0x5655e0): all enabled on the player's own turn
    /// (cast iff the stack can cast, wait iff it has not waited); while a spell is aimed only
    /// cancel_spell (in cast_spell's place) and options; otherwise all disabled, the auto toggle
    /// pressed and enabled while auto combat runs.
    func combatButtons(_ cs: CombatScreen, _ b: Battle) -> [CombatButton] {
        let cur = b.current
        let own = cur.map { $0.side == 0 && !$0.hypnotized } ?? false && !cs.busy && cs.result == nil && !cs.autoCombat
        let aiming = casting != nil
        let mode = cur.map { cs.shownMode($0) } ?? 0
        let canCast = own && cur.map { !b.castable($0).isEmpty } ?? false
        let canWait = own && cur.map { b.canWait($0) } ?? false
        let on = own && !aiming
        var out = [CombatButton(hotspot: "auto_attack", file: "combat.auto", key: "auto", enabled: on || cs.autoCombat, pressed: cs.autoCombat)]
        if aiming { out.append(CombatButton(hotspot: "cast_spell", file: "combat.cancel_spell", key: "cancel_spell", enabled: true, pressed: false)) }
        else { out.append(CombatButton(hotspot: "cast_spell", file: "combat.cast_spell", key: "cast_spell", enabled: on && canCast, pressed: false)) }
        out += [CombatButton(hotspot: "defend", file: "combat.defend", key: "defend", enabled: on, pressed: false),
                CombatButton(hotspot: "combat_options", file: "combat.options", key: "options", enabled: own, pressed: false),
                CombatButton(hotspot: "retreat", file: "combat.retreat", key: "retreat", enabled: on, pressed: false),
                CombatButton(hotspot: "surrender", file: "combat.surrender", key: "surrender", enabled: on, pressed: false),
                CombatButton(hotspot: "wait", file: "combat.wait", key: "wait", enabled: on && canWait, pressed: false),
                CombatButton(hotspot: "melee", file: "combat.\(Renderer.modeButtons[mode])", key: "mode", enabled: on, pressed: false)]
        return out
    }
    func inside(_ l: UILayer?, _ x: Float, _ y: Float) -> Bool {
        guard let l = l else { return false }
        return x >= Float(l.x) && x < Float(l.x + l.width) && y >= Float(l.y) && y < Float(l.y + l.height)
    }

    func combatPanelQuads(_ cs: CombatScreen, _ b: Battle, now: Date) -> [Quad] {
        let d = cs.frame
        var out: [Quad] = []
        let message = ProcessInfo.processInfo.environment["H4NOACTION"] == nil ? cs.actionMessage : nil   // (snapshots: the panel without the message)
        // the frame: Background and Border; the three icons only while no message shows
        for n in ["Background", "Border"] + (message == nil ? ["Health_Icon", "Spell_Points_Icon", "Shots_Icon"] : []) {
            if let l = d[n] { out.append(image(l, key: "combatframe|\(n)", l.x, l.y)) }
        }
        // the buttons
        let (px, py) = pointerCanvas
        for bt in combatButtons(cs, b) {
            guard let slot = cs.hotspot(bt.hotspot) else { continue }
            let state = !bt.enabled ? "Disabled" : bt.pressed ? "Pressed" : inside(slot, px, py) && prompt == nil && cs.info == nil ? "Highlighted" : "Released"
            out += buttonAt(bt.file, state, slot, 0, 0)
        }
        // the ring (t_creature_icon_window at creature_icon): the 52 portrait at hero_icon - Ring_Released,
        // control.creature_select's Ring_Released over it at the window's origin
        let shown = message.map { b.unit($0.unit) } ?? (cs.result == nil ? cs.shownCurrent.map { b.unit($0) } : nil)
        if let u = shown, let slot = d["creature_icon"], let sel = cs.layers("control.creature_select"), let ring = sel["Ring_Released"], let hi = sel["hero_icon"] {
            if let p = unitPortrait(u, size: 52) { out.append(image(p, key: "icon|\(p.name)", slot.x + hi.x - ring.x, slot.y + hi.y - ring.y)) }
            out.append(image(ring, key: "creature_select|Ring_Released", slot.x, slot.y))
        }
        let f = proseFont(14)
        if let m = message {
            out += textWindow(m.text, in: d["Action_Text"], font: f)
        } else if let u = shown {
            // hit points of the top creature; spell points (0 without); shots: "Inf", " %i Shots" or "N/A"
            out += textWindow("\(max(0, u.stats.hitPoints - u.stats.wounds))", in: d["Health_Text"], font: f)
            out += textWindow("\(u.caster?.spellPoints ?? 0)", in: d["Spell_Points_Text"], font: f)
            let shots = !u.stats.shooter ? text("not_applicable.dialog", "N/A")
                : u.stats.has("unlimited_shots") ? text("infinity_abbreviation.misc", "Inf")
                : " \(u.shots) " + text("shots.dialog", "Shots")
            out += textWindow(shots, in: d["Shots_Text"], font: f)
        }
        return out
    }

    /// A click on the combat screen (canvas coordinates).
    func combatClick(x: Float, y: Float) {
        guard let cs = combat, let b = cs.battle, let g = game else { return }
        if prompt != nil { _ = messageBoxClick(x: x, y: y); return }
        if cs.info != nil { combatInfoClick(x: x, y: y); return }
        if cs.showResults {
            if let d = ui?.dialog("Combat_results"), let ok = layer(d, "ok_button") {
                let (ox, oy) = resultsOrigin
                guard x >= Float(ox + ok.x), x < Float(ox + ok.x + 76), y >= Float(oy + ok.y), y < Float(oy + ok.y + 44) else { return }
            }
            closeCombat(); return
        }
        for bt in combatButtons(cs, b) where inside(cs.hotspot(bt.hotspot), x, y) {
            guard bt.enabled else { return }
            sound?.play("miscellaneous.button")
            switch bt.key {
            case "auto": cs.autoCombat.toggle(); cs.pump()
            case "cancel_spell": casting = nil
            case "cast_spell": openCombatBook()
            case "defend": b.defend(); cs.pump()
            case "wait": b.wait(); cs.pump()
            case "options": optionsOpen = settings
            case "retreat": askRetreat()
            case "surrender": askSurrender()
            case "mode":
                // the mode menu (0x565d30): the next mode the stack has
                if let u = b.current {
                    let list = cs.modes(u), k = cs.shownMode(u)
                    let next = list[((list.firstIndex(of: k) ?? -1) + 1) % list.count]
                    cs.attackMode[u.id] = next
                }
            default: break
            }
            return
        }
        guard !cs.busy, cs.result == nil, !cs.autoCombat, let cur = b.current, cur.side == 0 else { return }
        if let spell = casting {   // aiming a spell: a stack it can land on, anything else cancels
            casting = nil
            if x < 885, let t = unitUnder(b, x: x, y: y), b.canTarget(spell, by: cur, t) { b.cast(spell, on: t.id, tables: g.tables); cs.pump() }
            return
        }
        guard x < Float(cs.hotspot("battle_scene")?.width ?? 885) else { return }
        let mode = cs.shownMode(cur)
        if mode != 4, onGate(b, x: x, y: y), b.nextToGate(cur) || b.canShoot(cur) { b.attackGate(); cs.pump(); return }
        if mode != 4, let target = enemyUnder(b, x: x, y: y) {
            if mode == 3 { openCombatBook(); return }
            if b.canShoot(cur), mode == 0 { _ = b.shoot(target.id) } else { _ = b.attack(target.id) }
        } else {
            let c = footprintAt(cur, x: x, y: y)
            _ = b.move(to: c.0, c.1)
        }
        cs.pump()
    }
}
