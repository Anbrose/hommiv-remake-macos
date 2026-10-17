import Foundation
import H4Engine

/// A right-click text held on screen while the button is down (t_popup_window, 0x845290).
var heldHelp: (text: String, cx: Int, y: Int)?

/// The army screen's artifact hand (re/hero_artifacts_spec.md): drops, the backpack's scrolling,
/// right-click texts, a parchment's message.
extension Renderer {
    /// The artifact in hand is let go at a point (0x8d1c00): a worn slot or backpack place of the
    /// shown hero (0x5370f0), an army ring holding a hero (0x6430bb: into its backpack), or
    /// nothing / a refusal -- then it goes back where it came from (0x706960).
    func artifactDrop(_ s: ArmySession, _ d: ArtifactDrag, x: Float, y: Float) {
        let tables = game?.tables
        var note: ParchmentNote? = nil
        if let h = sessionHero, let dl = ui?.dialog("army.layout") {
            let (ox, oy) = armyOrigin
            if let p = heroArtifactPlace(h, dl, ox, oy, x: x, y: y) { note = ArtifactRules.drop(d, on: p, tables: tables).note }
        }
        if !d.consumed, let r = armyRing(s, at: x, y), let slot = sessionRows(s)[r.row][r.k], let h = slot.hero {
            ArtifactRules.drop(d, onto: h)
        }
        // (a creature's ring would take it into the creatures' backpack; the remake's stacks have none)
        ArtifactRules.cancel(d, tables: tables)
        if let n = note, let h = sessionHero { s.artNote = (parchmentText(n, h), Int(x), Int(y)) }
        refreshArtifactArmies(s)
    }

    /// What a parchment put on said (0x7260a0: damage_modifier_*.misc).
    func parchmentText(_ n: ParchmentNote, _ h: Hero) -> String {
        let t: String, sp: Int
        var skill = ""
        switch n {
        case .alreadyKnown(let s): sp = s; t = text("damage_modifier_already_known.misc", "%Hero_name already knows %spell_name.")
        case .needsSkill(let s, let k):
            sp = s; t = text("damage_modifier_insufficient_skill.misc", "%Hero_name must know %skill_name to learn %spell_name.")
            if k >= 0 { skill = skillName(k, level: max(1, RuleTables.spells[s].level)).name }
        case .learned(let s): sp = s; t = text("damage_modifier_learned.misc", "%Hero_name learns %spell_name.")
        }
        let spell = sp < RuleTables.spells.count ? RuleTables.spells[sp].name : ""
        return t.replacingOccurrences(of: "%Hero_name", with: h.name).replacingOccurrences(of: "%hero_name", with: h.name)
            .replacingOccurrences(of: "%spell_name", with: spell).replacingOccurrences(of: "%skill_name", with: skill)
    }

    /// After an artifact moved: the armies' movement follows their worn items (boots), and the
    /// backpack's scrollbar keeps inside its range (0x5362c0).
    func refreshArtifactArmies(_ s: ArmySession) {
        if let g = game {
            for a in [s.leader, s.x.other].compactMap({ $0 }) where g.heroes.contains(where: { $0 === a }) { g.refreshMovement(a) }
        }
        s.backpackRow = min(s.backpackRow, backpackRows(sessionHero))
    }
    /// The scrollbar's last step: (count - 9) / 2 once the backpack holds more than ten, else none.
    func backpackRows(_ h: Hero?) -> Int {
        guard let n = h?.backpack.count, n > 10 else { return 0 }
        return (n - 9) / 2
    }
    func scrollBackpack(_ s: ArmySession, by step: Int) {
        s.backpackRow = max(0, min(backpackRows(sessionHero), s.backpackRow + step))
    }
    /// The wheel over the army screen scrolls the backpack.
    func armyScreenScroll(_ dy: CGFloat) {
        guard let s = armySession, sessionHero != nil, abs(dy) > 1 else { return }
        scrollBackpack(s, by: dy < 0 ? 1 : -1)
    }

    /// A right click on the army screen: a worn or backpack artifact's text while the button is held.
    func armyScreenRightDown(x: Float, y: Float) -> Bool {
        guard let s = armySession, s.artDrag == nil, let h = sessionHero, let d = ui?.dialog("army.layout") else { return false }
        let (ox, oy) = armyOrigin
        guard let t = heroArtifactHelp(h, d, ox, oy, x: x, y: y) else { return false }
        heldHelp = (t.text, t.x, t.y)
        return true
    }
    /// A right click on a blacksmith's artifact: its help text (0x6728d6 sets it as the right-click text).
    func shopRightDown(x: Float, y: Float) -> Bool {
        guard let s = shop, let d = ui?.dialog("Blacksmith.Layout"), let panel = shopPanel(s) else { return false }
        let (px, py) = shopPicture(d)
        for r in s.rows {
            guard let l = shopLayer(panel, r.slot), inside(l, at: px, py, x, y) else { continue }
            let t = artifactName(r.artifact)
            heldHelp = (t.help.isEmpty ? t.name : t.help, px + l.x + l.width / 2, py + l.y + l.height)
            return true
        }
        return false
    }

    /// A t_basic_dialog with a text, centred on a point and kept on the screen (0x844fd0, 0x721a40);
    /// the text starts with a capital (0x8e135e).
    func pointBoxQuads(_ text: String, cx: Int, y: Int) -> [Quad] {
        let t = text.prefix(1).uppercased() + text.dropFirst()
        guard let d = basicDialog(text: t) else { return [] }
        let px = max(0, min(cx - d.W / 2, AdventureUI.width - d.W)), py = max(0, min(y - d.H / 2, AdventureUI.height - d.H))
        return basicDialogQuads(d, x: px, y: py)
    }
    func heldHelpQuads() -> [Quad] {
        guard let h = heldHelp else { return [] }
        return pointBoxQuads(h.text, cx: h.cx, y: h.y)
    }
}
