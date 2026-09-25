import Foundation
import H4Engine

/// The level-up dialog (layers.dialog.choose_skill): the hero's portrait, name and skills as they
/// are, "Level Up", the new level and class, and the offered skills as large icons
/// (layers.icons.skills.<primary>.82) in the frame_k_of_n places; the chosen one's name shows on
/// the scroll and its place in the skill grid is highlighted. OK takes it.
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
    /// The grid places of the dialog: (skill, x, y) for the hero's skills with `extra` learned.
    func levelUpGrid(_ h: Hero, extra: (skill: Int, level: Int)?, _ d: LayerFile, _ ox: Int, _ oy: Int) -> [(id: Int, x: Int, y: Int)] {
        var skills = h.skills
        if let e = extra { skills[RuleTables.skillIds[e.skill]] = max(skills[RuleTables.skillIds[e.skill]] ?? 0, e.level + 1) }
        func has(_ id: Int) -> Bool { (skills[RuleTables.skillIds[id]] ?? 0) > 0 }
        let rows = (0..<9).filter(has).map { p in [p] + (9..<36).filter { RuleTables.primary(of: $0) == p && has($0) } }
        var out: [(Int, Int, Int)] = []
        let firstRow = (1...4).compactMap { d["Skill_\($0)"] }
        for (r, ids) in rows.prefix(5).enumerated() {
            for (k, id) in ids.prefix(4).enumerated() {
                if r == 0 { if k < firstRow.count { out.append((id, ox + firstRow[k].x, oy + firstRow[k].y)) } }
                else if let row = d["Row_\(r + 1)"], firstRow.count == 4 { out.append((id, ox + firstRow[k].x, oy + row.y)) }
            }
        }
        return out
    }

    func levelUpQuads() -> [Quad] {
        guard let g = game, let lu = g.levelUp, !inCombat, let ui = ui, let d = ui.dialog("choose_skill") else { return [] }
        let (ox, oy) = levelUpOrigin
        let h = lu.hero
        var out = dialogImages(d, key: "chooseskill", at: ox, oy, skip: ["Skill_Location_Highlight"])
        let strings = g.tables?.strings ?? [:]
        if let slot = d["hero_portrait"], let p = ui.portrait(keyword: h.keyword, alignment: h.alignment, size: 82) {
            out.append(Quad(texture: uiTexture("portrait82|\(h.alignment)|\(h.keyword)", { p.bitmap }), x: ox + slot.x + (slot.width - p.width) / 2, y: oy + slot.y + (slot.height - p.height) / 2, w: p.width, h: p.height))
        }
        out += centred(h.name, in: d["hero_name"], at: ox, oy, font: ui.dateFont)
        out += centred(strings["skill_choice_choose_skill.misc"] ?? "Level Up", in: d["dialog_text"], at: ox, oy, font: ui.font(24))
        // the new level, with the class the chosen skill would make
        let chosen = levelUpChoice.flatMap { lu.offer.indices.contains($0) ? lu.offer[$0] : nil }
        let cls = chosen.map { g.classAfter(h, choosing: $0) } ?? h.heroClass
        let clsKey = RuleTables.heroClasses.indices.contains(cls) ? RuleTables.heroClasses[cls].keyword : ""
        let clsName = strings[clsKey] ?? clsKey.capitalized
        let line = (strings["hero_level.dialog"] ?? "Level %level %class_name").replacingOccurrences(of: "%level", with: "\(h.level + 1)").replacingOccurrences(of: "%class_name", with: clsName)
        out += centred(line, in: d["New_Level_Text"], at: ox, oy, font: ui.dateFont)
        let s = g.heroStats(h)
        out += centred(s.damage, in: d["Damage_Text"], at: ox, oy, font: ui.dateFont)
        out += centred("\(s.hitPoints)", in: d["Hit_Point_Text"], at: ox, oy, font: ui.dateFont)
        // the skills now
        for sl in levelUpGrid(h, extra: nil, d, ox, oy) {
            for l in skillIcon(sl.id, level: h.skill(id: sl.id)) {
                out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(sl.id)", { l.bitmap }), x: sl.x + l.x, y: sl.y + l.y, w: l.width, h: l.height))
            }
        }
        // the offers
        for (k, f) in offerFrames(lu.offer.count, d).enumerated() where k < lu.offer.count {
            let e = lu.offer[k]
            for l in largeSkillIcon(e.skill, level: e.level + 1) {
                out.append(Quad(texture: uiTexture("skill82|\(l.name)|\(e.skill)", { l.bitmap }), x: ox + f.x + (f.width - 82) / 2 + l.x, y: oy + f.y + (f.height - 82) / 2 + l.y, w: l.width, h: l.height))
            }
            if levelUpChoice == k, let hl = d["Skill_Location_Highlight"] {   // the chosen offer's ring
                let sx = Float(hl.width) / 63, sy = Float(hl.height) / 66
                _ = (sx, sy)
                out.append(Quad(texture: uiTexture("dlg|chooseskill|hl", { hl.bitmap }), x: ox + f.x + (f.width - 104) / 2, y: oy + f.y + (f.height - 108) / 2, w: 104, h: 108))
            }
        }
        if let e = chosen {
            out += centred(skillName(e.skill, level: e.level + 1).name, in: d["skill_text"], at: ox, oy, font: ui.numberFont)
            // where it goes in the grid
            if let sl = levelUpGrid(h, extra: e, d, ox, oy).first(where: { $0.id == e.skill }), let hl = d["Skill_Location_Highlight"], let s1 = d["Skill_1"] {
                out.append(Quad(texture: uiTexture("dlg|chooseskill|hl", { hl.bitmap }), x: sl.x + hl.x - s1.x, y: sl.y + hl.y - s1.y, w: hl.width, h: hl.height))
                for l in skillIcon(e.skill, level: e.level + 1) {
                    out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(e.skill)", { l.bitmap }), x: sl.x + l.x, y: sl.y + l.y, w: l.width, h: l.height))
                }
            }
        }
        if let ok = d["ok_button"], let b = ui.button("ok", state: chosen == nil ? "Disabled" : "Released") ?? ui.button("ok") {
            out.append(Quad(texture: uiTexture("button|ok|\(b.name)", { b.bitmap }), x: ox + ok.x + (ok.width - b.width) / 2, y: oy + ok.y + (ok.height - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }

    /// A click with the dialog open (it takes every click until a skill is chosen).
    func levelUpClick(x: Float, y: Float, double: Bool) -> Bool {
        guard let g = game, let lu = g.levelUp, !inCombat, let ui = ui, let d = ui.dialog("choose_skill") else { return false }
        let (ox, oy) = levelUpOrigin
        for (k, f) in offerFrames(lu.offer.count, d).enumerated() where k < lu.offer.count && inside(f, at: ox, oy, x, y) {
            levelUpChoice = k
            if double { confirmLevelUp() }
            return true
        }
        if inside(d["ok_button"], at: ox, oy, x, y) { sound?.play("miscellaneous.button"); confirmLevelUp() }
        return true
    }
    func confirmLevelUp() {
        guard let k = levelUpChoice, let g = game else { return }
        levelUpChoice = nil
        g.chooseSkill(k)
    }
    /// The help of an offered or known skill under the pointer.
    func levelUpTip(x: Float, y: Float) -> String? {
        guard let g = game, let lu = g.levelUp, let ui = ui, let d = ui.dialog("choose_skill") else { return nil }
        let (ox, oy) = levelUpOrigin
        for (k, f) in offerFrames(lu.offer.count, d).enumerated() where k < lu.offer.count && inside(f, at: ox, oy, x, y) {
            let t = skillName(lu.offer[k].skill, level: lu.offer[k].level + 1); return "\(t.name): \(t.help)"
        }
        for sl in levelUpGrid(lu.hero, extra: nil, d, ox, oy) where x >= Float(sl.x) && x < Float(sl.x + 52) && y >= Float(sl.y) && y < Float(sl.y + 52) {
            let t = skillName(sl.id, level: lu.hero.skill(id: sl.id)); return "\(t.name): \(t.help)"
        }
        return nil
    }
}
