import Foundation
import H4Engine

/// The parts of the hero screen (layers.dialog.army.layout) and the right-click window that show
/// a hero's own things: skills, worn artifacts and the backpack.
///
/// Skills: one row of the Skill_Frame per primary skill the hero knows (at most five), the
/// primary first and its known secondaries after it; icons from layers.icons.skills.<primary>.52
/// named by skill keyword, with the level's badge (Advanced / Expert / Master / Grandmaster
/// layers of the same sheet) over them. Artifacts: the class picture layers.dialog.army.<model>
/// has a hotspot per slot (Head, Neck, Left Hand, ...); icons are in layers.icons.artifacts.*
/// by artifact keyword.
extension Renderer {
    static let primarySheets = ["tactics", "combat", "scouting", "nobility", "life", "order", "death", "chaos", "nature"]

    /// The skill icon with its level badge, as layers to draw at a slot's origin.
    func skillIcon(_ id: Int, level: Int) -> [UILayer] {
        let sheet = iconSheet("skills.\(Renderer.primarySheets[RuleTables.primary(of: id)]).52")
        guard let icon = sheet[RuleTables.skillIds[id]] else { return [] }
        let badge = level >= 2 ? sheet[["advanced", "expert", "master", "grandmaster"][level - 2]] : nil
        return [icon] + (badge.map { [$0] } ?? [])
    }

    /// The rows of skills: each known primary with its known secondaries.
    func skillRows(_ h: Hero) -> [[Int]] {
        (0..<9).filter { h.skill(id: $0) > 0 }.map { p in [p] + (9..<36).filter { RuleTables.primary(of: $0) == p && h.skill(id: $0) > 0 } }
    }
    func skillName(_ id: Int, level: Int) -> (name: String, help: String) {
        let k = RuleTables.skillIds[id], l = RuleTables.skillLevelNames[max(0, min(4, level - 1))]
        return game?.tables?.skillTexts["\(k)_\(l)"] ?? (k.capitalized, "")
    }

    /// The artifact's icon (any of the four sheets) by id.
    func artifactIcon(_ id: Int) -> UILayer? {
        guard id < RuleTables.artifactIds.count else { return nil }
        let k = RuleTables.artifactIds[id]
        for s in ["armor", "item", "weapon", "special"] { if let l = iconSheet("artifacts.\(s)")[k] { return l } }
        return nil
    }
    func artifactName(_ id: Int) -> (name: String, help: String) {
        guard id < RuleTables.artifactIds.count else { return ("?", "") }
        let k = RuleTables.artifactIds[id]
        let a = game?.tables?.artifacts[k]
        return (a?.name ?? k, a?.help ?? "")
    }
    /// The hero's paper doll layout (layers.dialog.army.<model>, e.g. death_might_male).
    func dollLayout(_ h: Hero) -> LayerFile? {
        ui?.dialog("army." + h.actor.replacingOccurrences(of: "hero.", with: ""))
    }
    static let slotLayers = ["Bow", "Feet", "Head", "Left Ring", "Misc_1", "Misc_2", "Misc_3", "Misc_4", "Neck", "Right Ring", "Left Hand", "shoulders", "torso", "Right Hand"]

    /// Where the skill icons of the hero screen go: (skill, level, x, y) in canvas coordinates.
    func heroSkillSlots(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int) -> [(id: Int, x: Int, y: Int)] {
        var out: [(Int, Int, Int)] = []
        let rows = [d["skill_1"]] + (2...5).map { d["skill_row_\($0)"] }
        for (r, ids) in skillRows(h).prefix(5).enumerated() {
            guard let row = rows[r] else { continue }
            let step = r == 0 ? ((d["skill_2"]?.x ?? row.x + 60) - row.x) : 57
            for (k, id) in ids.prefix(4).enumerated() { out.append((id, ox + row.x + k * step, oy + row.y)) }
        }
        return out
    }
    /// Where the paper doll and backpack artifacts go: (artifact id, x, y) of 44x44 slots.
    func heroArtifactSlots(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int) -> (doll: (x: Int, y: Int)?, items: [(id: Int, x: Int, y: Int)]) {
        var items: [(Int, Int, Int)] = []
        var doll: (Int, Int)? = nil
        if let inv = d["hero_inventory"], let m = dollLayout(h), let bg = m["Background"] {
            let dx = ox + inv.x + (inv.width - bg.width) / 2, dy = oy + inv.y + (inv.height - bg.height) / 2
            doll = (dx, dy)
            for (i, a) in h.equipped.enumerated() where i < 14 {
                if let a = a, let s = m[Renderer.slotLayers[i]] { items.append((a, dx + s.x, dy + s.y)) }
            }
        }
        for (k, a) in h.backpack.prefix(10).enumerated() {
            if let s = d["backpack \(k + 1) slot"] { items.append((a, ox + s.x, oy + s.y)) }
        }
        return (doll, items)
    }

    func heroThingsQuads(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int) -> [Quad] {
        var out: [Quad] = []
        for s in heroSkillSlots(h, d, ox, oy) {
            for l in skillIcon(s.id, level: h.skill(id: s.id)) {
                out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(s.id)", { l.bitmap }), x: s.x + l.x, y: s.y + l.y, w: l.width, h: l.height))
            }
        }
        let (doll, items) = heroArtifactSlots(h, d, ox, oy)
        if let (dx, dy) = doll, let m = dollLayout(h), let bg = m["Background"] {
            out.append(Quad(texture: uiTexture("doll|\(h.actor)", { bg.bitmap }), x: dx, y: dy, w: bg.width, h: bg.height))
        }
        for it in items {
            guard let l = artifactIcon(it.id) else { continue }
            out.append(Quad(texture: uiTexture("art|\(it.id)", { l.bitmap }), x: it.x + l.x, y: it.y + l.y, w: l.width, h: l.height))
        }
        return out
    }

    /// The name and help of a skill or artifact under the pointer on the hero screen.
    func heroThingTip(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int, x: Float, y: Float) -> String? {
        func at(_ sx: Int, _ sy: Int, _ size: Int) -> Bool { x >= Float(sx) && x < Float(sx + size) && y >= Float(sy) && y < Float(sy + size) }
        for s in heroSkillSlots(h, d, ox, oy) where at(s.x, s.y, 52) {
            let t = skillName(s.id, level: h.skill(id: s.id)); return t.help.isEmpty ? t.name : "\(t.name): \(t.help)"
        }
        for it in heroArtifactSlots(h, d, ox, oy).items where at(it.x, it.y, 44) {
            let t = artifactName(it.id); return t.help.isEmpty ? t.name : "\(t.name): \(t.help)"
        }
        return nil
    }

    /// "Level 15 General" (the class names are strings.Text rows keyed by class keyword).
    func classLine(_ h: Hero) -> String {
        let k = h.classKeyword
        let name = game?.tables?.strings[k] ?? k.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        return "Level \(h.level) \(name)"
    }

    enum ArtifactHit { case worn(Int), backpack(Int) }
    /// Which worn slot or backpack place is under the pointer (a place holding an artifact).
    func heroArtifactHit(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int, x: Float, y: Float) -> ArtifactHit? {
        func at(_ sx: Int, _ sy: Int) -> Bool { x >= Float(sx) && x < Float(sx + 44) && y >= Float(sy) && y < Float(sy + 44) }
        if let inv = d["hero_inventory"], let m = dollLayout(h), let bg = m["Background"] {
            let dx = ox + inv.x + (inv.width - bg.width) / 2, dy = oy + inv.y + (inv.height - bg.height) / 2
            for (i, a) in h.equipped.enumerated() where i < 14 && a != nil {
                if let s = m[Renderer.slotLayers[i]], at(dx + s.x, dy + s.y) { return .worn(i) }
            }
        }
        for k in h.backpack.indices.prefix(10) {
            if let s = d["backpack \(k + 1) slot"], at(ox + s.x, oy + s.y) { return .backpack(k) }
        }
        return nil
    }
}
