import Foundation
import H4Engine

/// The teaching objects' dialogs as heroes4.exe lays them out (re/schools_spec.md "Dialog render
/// detail" and "t_seminary_window render detail"), centred on the screen (their inits centre the
/// layers' bounding box, re/dialog_placement_spec.md §2):
/// - t_dialog_beastmaster (huts, layers.dialog.beastmaster): Title (20), text_dialog (20, left, top),
///   the skill's 82-px icon under button.skill_frame and "Basic X" (16), the hero strip, Learn
///   (button.learn), close (button.ok, Enter);
/// - t_dialog_school_of_magic (schools): text_title (22), text_dialog (18), the two skills as a
///   radio of skill_frame buttons with their names (box height / 2), the total in text_gold (box
///   height, grey halo), the hero strip, Learn, close (button.ok, Enter);
/// - t_seminary_window (universities, layers.dialog.Magic_University): the hero ring row on
///   Single_Ring_Background, four slot buttons with their names, the status line (20), the cost,
///   Learn, close (button.ok, Enter);
/// - t_dialog_war_institute (Library / Veteran's Guild): title (22), text (18), the 64-px gold in
///   gold_icon, the total, the hero strip, Learn, close (button.ok, Escape);
/// - t_dialog_tree_of_knowledge: title and text (22), the gold or gems under icon_1_frame with the
///   total (24, halo), the Experience picture with plus_1_level (26), the hero strip, Buy
///   (button.buy), Cancel (button.cancel, Escape).
/// The hero strip is control.creature_select in toggle mode: a ring per hero at hero_i_of_n from
/// hero_portraits' top-left, the 52-px portrait in it, Ring_Pressed when ticked, Ring_Disabled
/// when it cannot be.
extension Renderer {
    var skillDialogFile: LayerFile? {
        guard let d = game?.skillDialog else { return nil }
        switch d.kind {
        case .hut: return dFile("dialog.beastmaster")
        case .school: return dFile("dialog.school_of_magic") ?? dFile("dialog.School_of_Magic")
        case .university: return dFile("dialog.Magic_University") ?? dFile("dialog.magic_university")
        case .library: return dFile("dialog.War_Institute") ?? dFile("dialog.war_institute")
        case .tree: return dFile("dialog.Tree_of_Knowledge") ?? dFile("dialog.tree_of_knowledge")
        }
    }
    /// The window's origin: the layers' bounding box centred on the screen (0x58e7d0, 0x71e980).
    func skillDialogOrigin(_ f: LayerFile) -> (Int, Int) {
        let ls = f.layers.filter { $0.width > 0 && $0.height > 0 }
        let x0 = ls.map { $0.x }.min() ?? 0, y0 = ls.map { $0.y }.min() ?? 0
        let x1 = ls.map { $0.x + $0.width }.max() ?? 560, y1 = ls.map { $0.y + $0.height }.max() ?? 560
        return ((AdventureUI.width - (x1 - x0)) / 2 - x0, (AdventureUI.height - (y1 - y0)) / 2 - y0)
    }
    /// The ring windows of the hero strip (0x64fe00 / 0x650150): hero_i_of_n from hero_portraits' top-left.
    func skillDialogRings(_ d: SkillDialog, _ f: LayerFile, _ ox: Int, _ oy: Int) -> [DRect] {
        guard let area = dRect(f, "hero_portraits"), let sel = dFile("control.creature_select") else { return [] }
        let n = min(d.heroes.count, 7)
        return (0..<n).compactMap { k in dRect(sel, "hero_\(k + 1)_of_\(n)").map { DRect(ox + area.x + $0.x, oy + area.y + $0.y, $0.w, $0.h) } }
    }
    /// The university's ring row (t_creature_array_window 0x6439c0 style 0) from Single_Ring_Background's top-left.
    func universityRings(_ f: LayerFile, _ ox: Int, _ oy: Int) -> [(piece: String, fx: Int, fy: Int)] {
        guard let bg = dRect(f, "Single_Ring_Background") else { return [] }
        return ringRow(x: ox + bg.x, y: oy + bg.y)
    }
    /// The skill buttons: the school's icon_1 / icon_2, the university's icon_1 ... icon_4, with what each shows.
    func skillDialogIcons(_ d: SkillDialog, _ f: LayerFile) -> [(box: DRect, skill: Int, level: Int)] {
        guard let g = game else { return [] }
        switch d.kind {
        case .school(let s):
            return s.indices.compactMap { i in dRect(f, "icon_\(i + 1)").map { ($0, s[i], 0) } }
        case .university(let s):
            return s.indices.compactMap { i in
                guard let r = dRect(f, "icon_\(i + 1)") else { return nil }
                if let k = d.hero, k < d.heroes.count, let o = g.universitySlot(d.heroes[k], d.place, i) { return (r, o.skill, o.level) }
                return (r, s[i], 0)
            }
        default: return []
        }
    }
    /// The Learn / Buy and close buttons: hotspot, button file.
    func skillDialogButtons(_ d: SkillDialog) -> (learn: (String, String), close: (String, String)) {
        switch d.kind {
        case .hut: return (("learn_button", "learn"), ("close_button", "ok"))
        case .school, .library: return (("purchase_icon", "learn"), ("close_button", "ok"))
        case .university: return (("purchase_button", "learn"), ("close_button", "ok"))
        case .tree: return (("purchase_icon", "buy"), ("close_button", "cancel"))
        }
    }
    private func skillButtonRect(_ f: LayerFile, _ b: (String, String), _ ox: Int, _ oy: Int) -> DRect? {
        guard let r = dRect(f, b.0) else { return nil }
        let (w, h) = dButtonSize(b.1)
        return DRect(ox + r.x, oy + r.y, max(w, r.w), max(h, r.h))
    }

    func skillDialogQuads() -> [Quad] {
        guard let g = game, let d = g.skillDialog, let ui = ui, let f = skillDialogFile else { return [] }
        let (ox, oy) = skillDialogOrigin(f)
        var out: [Quad] = []
        // the frame (0x597e50 at their own boxes, whatever their kind)
        for name in ["Background", "Top", "Left", "Bottom", "Right"] { out += dImage(f, "skilldlg.\(d.kind)", name, ox, oy) }
        // the heroes
        if case .university = d.kind {
            out += dImage(f, "skilldlg.university", "Single_Ring_Background", ox, oy)
            let slots = universityRings(f, ox, oy)
            let items = d.heroes.prefix(7).map { h in (icon: ui.portrait(keyword: h.keyword, alignment: h.alignment), count: String?.none, hero: true) }
            out += ringRowQuads(slots, items: Array(items), selected: d.hero)
        } else if let sel = dFile("control.creature_select"), let ring = dLayer(sel, "Ring_Released") {
            for (k, r) in skillDialogRings(d, f, ox, oy).enumerated() {
                let h = d.heroes[k]
                if let hi = dLayer(sel, "hero_icon"), let p = ui.portrait(keyword: h.keyword, alignment: h.alignment, size: 52) {
                    out += dImageAt(p, "portrait52.\(h.alignment)", x: r.x + hi.x - ring.x, y: r.y + hi.y - ring.y)
                }
                let state = !g.skillDialogEnabled(d, k) ? "Ring_Disabled" : d.ticked[k] ? "Ring_Pressed" : "Ring_Released"
                out += dImageAt(dLayer(sel, state) ?? ring, "creature_select", x: r.x, y: r.y)
            }
        }
        // the skill buttons (0x84d7a0: the 82-px icon at skill_frame's icon box, the frame over it)
        let sf = dFile("button.skill_frame")
        let iconBox = dRect(sf, "icon") ?? DRect(18, 17, 82, 82)
        for (i, b) in skillDialogIcons(d, f).enumerated() {
            for l in largeSkillIcon(b.skill, level: b.level + 1) { out += dImageAt(l, "skill82.\(b.skill).\(l.name)", x: ox + b.box.x + iconBox.x + l.x, y: oy + b.box.y + iconBox.y + l.y) }
            out += dImageOffset(dLayer(sf, i == d.choice ? "Pressed" : "Released"), "skillframe", x: ox + b.box.x, y: oy + b.box.y)
            out += dText(skillName(b.skill, level: b.level + 1).name, dRect(f, "text_icon_\(i + 1)"), font: dFont((dRect(f, "text_icon_\(i + 1)")?.h ?? 34) / 2), ox, oy)
        }
        let cost = g.skillDialogCost(d)
        func gold(_ name: String, _ n: Int) {
            let r = dRect(f, name)
            out += dText("\(n)", r, font: dFont(r?.h ?? 18), halo: Renderer.halo200, ox, oy)
        }
        /// A materials.64 picture centred across the box's width at its top (0x597e50 adds the image's own box).
        func material(_ name: String, in box: String) {
            guard let r = dRect(f, box), let l = materialIcon(name, size: 64) else { return }
            out += dImageAt(l, "mat64.\(name)", x: ox + r.x + abs(r.w / 2 - l.width / 2) + l.x, y: oy + r.y + l.y)
        }
        switch d.kind {
        case .hut(let s):
            out += dText(d.title, dRect(f, "Title"), font: dFont(dRect(f, "Title")?.h ?? 20), ox, oy)
            out += dText(d.text, dRect(f, "text_dialog"), font: dFont(20), centre: false, ox, oy)
            if let icon = dRect(f, "skill_icon") {
                out += dImageOffset(dLayer(sf, "Released"), "skillframe", x: ox + icon.x - iconBox.x, y: oy + icon.y - iconBox.y)
                for l in largeSkillIcon(s, level: 1) { out += dImageAt(l, "skill82.\(s).\(l.name)", x: ox + icon.x + l.x, y: oy + icon.y + l.y) }
            }
            let r = dRect(f, "skill_text")
            out += dText(skillName(s, level: 1).name, r, font: dFont((r?.h ?? 32) / 2), vcentre: true, ox, oy)
        case .school:
            out += dText(d.title, dRect(f, "text_title"), font: dFont(22), ox, oy)
            out += dText(d.text, dRect(f, "text_dialog"), font: dFont(18), ox, oy)
            gold("text_gold", cost.amount)
        case .university:
            out += dText(d.title, dRect(f, "text_title"), font: dFont(dRect(f, "text_title")?.h ?? 26), ox, oy)
            out += dText(g.universityStatus(d).text, dRect(f, "text_dialog"), font: dFont(20), ox, oy)
            gold("text_gold", cost.amount)
        case .library:
            out += dText(d.title, dRect(f, "text_title"), font: dFont(22), ox, oy)
            out += dText(d.text, dRect(f, "text_dialog"), font: dFont(18), ox, oy)
            material("Gold", in: "gold_icon")
            gold("text_gold", cost.amount)
        case .tree(let m, _):
            out += dText(d.title, dRect(f, "text_title"), font: dFont(22), ox, oy)
            out += dText(d.text, dRect(f, "text_dialog"), font: dFont(22), ox, oy)
            material(m == 0 ? "Gold" : "Gems", in: "icon_1")
            out += dImage(f, "skilldlg.tree", "icon_1_frame", ox, oy)
            gold("text_icon_1", cost.amount)
            if let r = dRect(f, "icon_2"), let l = iconSheet("stats.82")["experience"] { out += dImageAt(l, "stats82.experience", x: ox + r.x + l.x, y: oy + r.y + l.y) }
            let r2 = dRect(f, "text_icon_2")
            out += dText(g.tables?.strings["plus_1_level.tree_of_knowledge"] ?? "+1 Level", r2, font: dFont(r2?.h ?? 26), ox, oy)
        }
        // Learn / Buy and close
        let (learn, close) = skillDialogButtons(d)
        for (b, enabled) in [(learn, g.skillDialogCanLearn(d)), (close, true)] {
            guard let r = skillButtonRect(f, b, ox, oy), let hot = dRect(f, b.0) else { continue }
            let over = r.contains(pointerCanvas.0, pointerCanvas.1)
            out += dButton(b.1, !enabled ? "Disabled" : over ? "Highlighted" : "Released", x: ox + hot.x, y: oy + hot.y)
        }
        return out
    }

    /// A click with the dialog open (it takes every click): a ring ticks its hero (the university's
    /// row chooses it), a skill button chooses that skill, Learn / Buy, close.
    func skillDialogClick(x: Float, y: Float) -> Bool {
        guard let g = game, let d = g.skillDialog, let f = skillDialogFile else { return false }
        let (ox, oy) = skillDialogOrigin(f)
        if case .university = d.kind {
            for (k, s) in universityRings(f, ox, oy).prefix(d.heroes.count).enumerated() where DRect(s.fx, s.fy, 82, 82).contains(x, y) {
                d.hero = k
                return true
            }
        }
        for (k, r) in skillDialogRings(d, f, ox, oy).enumerated() where r.contains(x, y) {
            if case .university = d.kind { break }
            g.skillDialogToggle(d, k)
            return true
        }
        for (i, b) in skillDialogIcons(d, f).enumerated() where DRect(ox + b.box.x, oy + b.box.y, b.box.w, b.box.h).contains(x, y) {
            g.skillDialogChoose(d, i)
            return true
        }
        let (learn, close) = skillDialogButtons(d)
        if let r = skillButtonRect(f, learn, ox, oy), r.contains(x, y), g.skillDialogCanLearn(d) {
            sound?.play("miscellaneous.button")
            g.skillDialogLearn(d)
        } else if let r = skillButtonRect(f, close, ox, oy), r.contains(x, y) {
            sound?.play("miscellaneous.button")
            g.skillDialog = nil
        }
        return true
    }
    /// The close button's hot key: Enter (huts, schools, universities) or Escape (library, tree).
    func skillDialogKey(_ code: UInt16) -> Bool {
        guard let d = game?.skillDialog else { return false }
        let enter = code == 36 || code == 76, escape = code == 53
        switch d.kind {
        case .library, .tree: if escape { game?.skillDialog = nil }
        default: if enter { game?.skillDialog = nil }
        }
        return true
    }
    /// The balloons: a ring's hero (or why it cannot be ticked), the buttons, the tree's pictures.
    func skillDialogTip(x: Float, y: Float) -> String? {
        guard let g = game, let d = g.skillDialog, let f = skillDialogFile else { return nil }
        let (ox, oy) = skillDialogOrigin(f)
        if case .university = d.kind {
            for (k, s) in universityRings(f, ox, oy).prefix(d.heroes.count).enumerated() where DRect(s.fx, s.fy, 82, 82).contains(x, y) { return d.heroes[k].name }
        } else {
            for (k, r) in skillDialogRings(d, f, ox, oy).enumerated() where r.contains(x, y) { return g.skillDialogTip(d, k) }
        }
        let (learn, close) = skillDialogButtons(d)
        if let r = skillButtonRect(f, learn, ox, oy), r.contains(x, y) { return g.skillDialogLearnTip(d) ?? interfaceText("shared", learn.1)?.balloon }
        if let r = skillButtonRect(f, close, ox, oy), r.contains(x, y) { return interfaceText("shared", close.1)?.balloon }
        if case .tree(let m, _) = d.kind {
            if let r = dRect(f, "icon_1"), r.offset(ox, oy).contains(x, y) { return interfaceText("shared", m == 0 ? "gold" : "gems")?.balloon }
            if let r = dRect(f, "icon_2"), r.offset(ox, oy).contains(x, y) { return interfaceText("shared", "experience")?.balloon }
        }
        return nil
    }
}
