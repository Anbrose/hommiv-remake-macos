import Foundation
import H4Engine

/// The level-up dialog (t_skill_choice_dialog 0x84e780, layers.dialog.choose_skill;
/// object_dialogs_spec §7, dialogs_spec §6): the frame pieces and Background, the 82 px portrait
/// under Portrait_Frame, the hero's name (30), "Level Up" (34), "%hero_name will become a level
/// %level %hero_class." (18), damage and hit points at the new level (20, centred both ways), the
/// skill grid with the chosen offer applied under Current_Skills_Frame and the highlight on the
/// chosen skill's place; per offer a Text_Scroll with the skill's name (14) and a toggle of
/// button.skill_frame art with the 82 px icon at its `icon` box; OK (button.ok) at (634,496).
/// Every text is black without a halo. The first offer is chosen on opening; Enter takes it.
extension Renderer {
    static let levelUpSize = (w: 740, h: 570)
    var levelUpOrigin: (Int, Int) { ((AdventureUI.width - Renderer.levelUpSize.w) / 2, (AdventureUI.height - Renderer.levelUpSize.h) / 2) }

    func largeSkillIcon(_ id: Int, level: Int) -> [UILayer] {
        let sheet = iconSheet("skills.\(Renderer.primarySheets[RuleTables.primary(of: id)]).82")
        guard let icon = sheet[RuleTables.skillIds[id]] else { return skillIcon(id, level: level) }
        let badge = level >= 2 ? sheet[["advanced", "expert", "master", "grandmaster"][level - 2]] : nil
        return [icon] + (badge.map { [$0] } ?? [])
    }
    func offerFrames(_ n: Int, _ d: LayerFile) -> [UILayer] {
        (1...max(1, n)).compactMap { d["frame_\($0)_of_\(n)"] }
    }
    /// The grid (0x850be0): skill ids in order, a primary not seen yet opening the next row (5 at
    /// most), each skill in its primary's row at the next column (4 at most); `extra` applied first.
    func levelUpGrid(_ h: Hero, extra: (skill: Int, level: Int)?, _ d: LayerFile, _ ox: Int, _ oy: Int) -> [(id: Int, level: Int, x: Int, y: Int)] {
        var skills = h.skills
        if let e = extra { skills[RuleTables.skillIds[e.skill]] = e.level + 1 }
        let xs = (1...4).map { dRect(d, "Skill_\($0)")?.x ?? 0 }
        let ys = [dRect(d, "Skill_1")?.y ?? 0] + (2...5).map { dRect(d, "Row_\($0)")?.y ?? 0 }
        var rowOf: [Int: Int] = [:], used: [Int] = []
        var out: [(Int, Int, Int, Int)] = []
        for id in 0..<36 {
            let lv = skills[RuleTables.skillIds[id]] ?? 0
            guard lv > 0 else { continue }
            let p = RuleTables.primary(of: id)
            if rowOf[p] == nil { guard used.count < 5 else { continue }; rowOf[p] = used.count; used.append(0) }
            let r = rowOf[p]!
            guard used[r] < 4 else { continue }
            out.append((id, lv, ox + xs[used[r]], oy + ys[r]))
            used[r] += 1
        }
        return out
    }
    /// The chosen offer (the first one until another is picked).
    func levelUpChosen(_ offers: Int) -> Int? { offers == 0 ? nil : min(levelUpChoice ?? 0, offers - 1) }

    func levelUpQuads() -> [Quad] {
        guard let g = game, let lu = g.levelUp, !inCombat, let ui = ui, let d = ui.dialog("choose_skill") else { return [] }
        let (ox, oy) = levelUpOrigin
        let h = lu.hero
        var out: [Quad] = []
        func img(_ n: String, dx: Int = 0, dy: Int = 0) { out += dImage(d, "chooseskill", n, ox, oy, dx: dx, dy: dy) }
        for n in ["Top", "Left", "Bottom", "Right", "Background"] { img(n) }
        if let slot = dRect(d, "hero_portrait"), let p = ui.portrait(keyword: h.keyword, alignment: h.alignment, size: 82) {
            out += dImageAt(p, "portrait82.\(h.alignment)", x: ox + slot.x, y: oy + slot.y)
        }
        img("Portrait_Frame")
        let strings = g.tables?.strings ?? [:]
        out += dText(h.name, dRect(d, "hero_name"), font: dFont(32), ox, oy)
        out += dText(strings["skill_choice_choose_skill.misc"] ?? "Level Up", dRect(d, "dialog_text"), font: dFont(39), ox, oy)
        let k = levelUpChosen(lu.offer.count)
        let chosen = k.map { lu.offer[$0] }
        let cls = chosen.map { g.classAfter(h, choosing: $0) } ?? h.heroClass
        let clsKey = RuleTables.heroClasses.indices.contains(cls) ? RuleTables.heroClasses[cls].keyword : ""
        let clsName = strings[clsKey] ?? clsKey.capitalized
        let line = (strings["skill_choice_new_class.misc"] ?? "%hero_name will become a level %level %hero_class.")
            .replacingOccurrences(of: "%hero_name", with: h.name).replacingOccurrences(of: "%level", with: "\(h.level + 1)")
            .replacingOccurrences(of: "%hero_class", with: clsName)
        out += dText(line, dRect(d, "New_Level_Text"), font: dFont(19), ox, oy)
        // damage and hit points at the new level
        h.level += 1
        let s = g.heroStats(h)
        h.level -= 1
        img("Damage_Icon")
        out += dText(s.damage, dRect(d, "Damage_Text"), font: dFont(20), vcentre: true, ox, oy)
        img("Hit_Point_Icon")
        out += dText("\(s.hitPoints)", dRect(d, "Hit_Point_Text"), font: dFont(20), vcentre: true, ox, oy)
        // the skills with the choice applied, the frame over them, the highlight on the chosen one's place
        let grid = levelUpGrid(h, extra: chosen, d, ox, oy)
        for sl in grid {
            for l in skillIcon(sl.id, level: sl.level) { out += dImageAt(l, "skill52.\(sl.id)", x: sl.x + l.x, y: sl.y + l.y) }
        }
        img("Current_Skills_Frame")
        if let e = chosen, let sl = grid.first(where: { $0.id == e.skill }), let hl = dRect(d, "Skill_Location_Highlight"), let s1 = dRect(d, "Skill_1") {
            img("Skill_Location_Highlight", dx: sl.x - ox - s1.x, dy: sl.y - oy - s1.y)
            _ = hl
        }
        // the offers: a scroll with the name, the toggle (the icon under the frame's Released / Pressed)
        let f13 = dRect(d, "frame_1_of_3") ?? DRect(358, 219, 116, 115)
        let sf = dFile("button.skill_frame")
        let iconBox = dRect(sf, "icon") ?? DRect(18, 17, 82, 82)
        for (i, f) in offerFrames(lu.offer.count, d).enumerated() where i < lu.offer.count {
            let e = lu.offer[i]
            let dx = f.x - f13.x, dy = f.y - f13.y
            img("Text_Scroll", dx: dx, dy: dy)
            out += dText(skillName(e.skill, level: e.level + 1).name, dRect(d, "skill_text")?.offset(dx, dy), font: dFont(15), vcentre: true, ox, oy)
            for l in largeSkillIcon(e.skill, level: e.level + 1) {
                out += dImageAt(l, "skill82.\(e.skill)", x: ox + f.x + iconBox.x + l.x, y: oy + f.y + iconBox.y + l.y)
            }
            out += dImageOffset(dLayer(sf, i == k ? "Pressed" : "Released"), "skillframe", x: ox + f.x, y: oy + f.y)
        }
        if let okb = dRect(d, "ok_button") { out += dButton("ok", "Released", x: ox + okb.x, y: oy + okb.y) }
        return out
    }

    /// A click with the dialog open (it takes every click until a skill is chosen).
    func levelUpClick(x: Float, y: Float, double: Bool) -> Bool {
        guard let g = game, let lu = g.levelUp, !inCombat, let ui = ui, let d = ui.dialog("choose_skill") else { return false }
        let (ox, oy) = levelUpOrigin
        for (k, f) in offerFrames(lu.offer.count, d).enumerated() where k < lu.offer.count && inside(f, at: ox, oy, x, y) {
            levelUpChoice = k
            return true
        }
        if let okb = dRect(d, "ok_button"), DRect(ox + okb.x, oy + okb.y, 76, 44).contains(x, y) { sound?.play("miscellaneous.button"); confirmLevelUp() }
        return true
    }
    func confirmLevelUp() {
        guard let g = game, let lu = g.levelUp, let k = levelUpChosen(lu.offer.count) else { return }
        levelUpChoice = nil
        g.chooseSkill(k)
    }
    /// The help of an offered or known skill under the pointer, and of the stats and OK.
    func levelUpTip(x: Float, y: Float) -> String? {
        guard let g = game, let lu = g.levelUp, let ui = ui, let d = ui.dialog("choose_skill") else { return nil }
        let (ox, oy) = levelUpOrigin
        for (k, f) in offerFrames(lu.offer.count, d).enumerated() where k < lu.offer.count && inside(f, at: ox, oy, x, y) {
            let t = skillName(lu.offer[k].skill, level: lu.offer[k].level + 1); return "\(t.name): \(t.help)"
        }
        let chosen = levelUpChosen(lu.offer.count).map { lu.offer[$0] }
        for sl in levelUpGrid(lu.hero, extra: chosen, d, ox, oy) where x >= Float(sl.x) && x < Float(sl.x + 53) && y >= Float(sl.y) && y < Float(sl.y + 53) {
            return skillName(sl.id, level: sl.level).name
        }
        if inside(d["Damage_Icon"], at: ox, oy, x, y) { return interfaceText("shared", "damage")?.balloon }
        if inside(d["Hit_Point_Icon"], at: ox, oy, x, y) { return interfaceText("shared", "hit_points")?.balloon }
        if inside(d["hero_portrait"], at: ox, oy, x, y) { return lu.hero.name }
        if let okb = dRect(d, "ok_button"), DRect(ox + okb.x, oy + okb.y, 76, 44).contains(x, y) { return interfaceText("shared", "accept")?.balloon }
        return nil
    }
}
