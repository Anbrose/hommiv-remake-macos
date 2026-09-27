import Foundation
import Metal
import H4Engine

/// What is open on top of the town screen.
enum TownDialog {
    case buildList                         // t_buy_building_window (dialog.buy_building): the town's buildings as tiles
    case buildDetail(RuleTables.BuildingDef)   // t_buy_building_detail (dialog.buy_building_detail) over the list
    case recruit(creature: String, count: Int, fromCastle: Bool = false) // t_recruit_dialog (dialog.recruit)
    case mageGuild(page: Int)                  // t_mage_guild_window: the index page (levels 1-2, 3-5)
    case guildSpell(spell: Int, heroTop: Int)  // the mage guild's detail page of one spell
    case castle                                // t_castle_window (dialog.Castle_Screen): every built dwelling
}

extension Renderer {
    /// Draw a dialog layout's image layers (except pressed/highlighted button states) at an origin.
    func dialogImages(_ d: LayerFile, key: String, at ox: Int, _ oy: Int, skip: Set<String> = []) -> [Quad] {
        var out: [Quad] = []
        for l in d.layers where l.isImage && !l.name.hasSuffix("_Pressed") && !l.name.hasSuffix("_Highlighted") && !skip.contains(l.name) {
            out.append(Quad(texture: uiTexture("dlg|\(key)|\(l.name)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height))
        }
        return out
    }
    /// Centred text in a layout hotspot.
    func centred(_ s: String, in l: UILayer?, at ox: Int, _ oy: Int, font: H4Font, colour: (UInt8, UInt8, UInt8) = (40, 24, 8)) -> [Quad] {
        guard let l = l, !s.isEmpty else { return [] }
        let w = font.measure(s)
        return [Quad(texture: uiTexture("dlgtext|\(font.size)|\(s)|\(colour.0)", { font.render(s, colour: colour) }), x: ox + l.x + (l.width - w) / 2, y: oy + l.y + (l.height - font.size) / 2, w: w, h: font.size)]
    }
    /// Wrapped left-aligned paragraph in a hotspot.
    func paragraph(_ s: String, in l: UILayer?, at ox: Int, _ oy: Int, font: H4Font, colour: (UInt8, UInt8, UInt8) = (40, 24, 8)) -> [Quad] {
        guard let l = l, !s.isEmpty else { return [] }
        var out: [Quad] = []
        for (i, line) in AdventureUI.wrap(s, font: font, width: l.width).enumerated() where i * font.lineHeight + font.size <= l.height + 4 {
            out.append(Quad(texture: uiTexture("dlgtext|\(font.size)|\(line)|\(colour.0)", { font.render(line, colour: colour) }), x: ox + l.x, y: oy + l.y + i * font.lineHeight, w: font.measure(line), h: font.size))
        }
        return out
    }
    func inside(_ l: UILayer?, at ox: Int, _ oy: Int, _ x: Float, _ y: Float) -> Bool {
        guard let l = l else { return false }
        return x >= Float(ox + l.x) && x < Float(ox + l.x + l.width) && y >= Float(oy + l.y) && y < Float(oy + l.y + l.height)
    }
    /// A resource icon from layers.icons.materials.<size>.
    func materialIcon(_ resource: String, size: Int) -> UILayer? {
        guard let ui = ui else { return nil }
        if ui.materials[size] == nil, let d = try? ui.archive.payload("layers.icons.materials.\(size).h4d") { ui.materials[size] = try? LayerFile(data: d) }
        return ui.materials[size]?.layers.first { $0.name.lowercased() == resource.lowercased() || ($0.name.lowercased() == "gem" && resource == "Gems") }
    }
    /// The detail dialog's requirement line (0x5a40e9): built, not owner, requirements, resources,
    /// built today, else "all met".
    func buildDetailText(_ b: RuleTables.BuildingDef) -> String {
        guard let g = game, let i = townOpen else { return "" }
        let t = g.towns[i], strings = g.tables?.strings ?? [:]
        guard let id = g.buildingId(t.alignment, b.keyword) else { return "" }
        let state = g.buildState(t, id)
        switch state {
        case 1: return (strings["built_building.dialog"] ?? "The %building has already been built.").replacingOccurrences(of: "%building", with: b.name)
        case 5: return strings["town.buy_building_not_owner"] ?? "You do not own this town."
        case 4: return strings["not_enough_resources_to_build.dialog"] ?? "You do not have enough resources to build this structure."
        case 3 where g.requirementText(t, id) == (strings["all_requirements_met.town_build"] ?? "All requirements for this building have been met."):
            return strings["already_built_for_day.dialog"] ?? "You've already built in this town for the day."
        default: return g.requirementText(t, id)
        }
    }
    /// A layer-less text rect in dialog coordinates.
    func rect(_ l: UILayer?, _ ox: Int, _ oy: Int) -> DRect? { l.map { DRect($0.x + ox, $0.y + oy, $0.width, $0.height) } }

    static let buildCell = (w: 183, h: 101, cols: 4, rows: 5)
    var buildListOrigin: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }
    var buildDetailOrigin: (Int, Int) { ((AdventureUI.width - 583) / 2, (AdventureUI.height - 559) / 2) }
    var recruitOrigin: (Int, Int) { ((AdventureUI.width - 553) / 2, (AdventureUI.height - 600) / 2) }

    func townDialogQuads() -> [Quad] {
        guard let dlg = townDialog else { return [] }
        switch dlg {
        case .castle: return castleQuads()
        case .mageGuild, .guildSpell: return mageGuildQuads()
        case .buildList: return buildListQuads()
        case .buildDetail(let b): return buildListQuads() + buildDetailQuads(b)
        case .recruit(let c, let n, let fromCastle): return (fromCastle ? castleQuads() : []) + recruitQuads(c, n)
        }
    }

    // MARK: the build list (t_buy_building_window 0x5a5d60, spec §2 B)

    /// The tiles of the list (0x5a67a0): per non-empty slot, tile (tx, ty) = (33 + xoff + (slot % 4) x 183, row y).
    func buildTiles() -> [(x: Int, y: Int, def: RuleTables.BuildingDef, id: Int, state: Int)] {
        guard let g = game, let i = townOpen, let d = ui?.dialog("buy_building") else { return [] }
        let town = g.towns[i], list = g.buildList(town)
        var out: [(Int, Int, RuleTables.BuildingDef, Int, Int)] = []
        for r in 0..<5 {
            let inRow = list.filter { $0.slot / 4 == r }
            guard !inRow.isEmpty, let row = dLayer(d, "row \(r + 1)") else { continue }
            let xoff = (732 - (inRow.count - 1) * 183 - 183) / 2
            for e in inRow {
                guard let def = g.buildingDef(town, e.b) else { continue }
                out.append((33 + xoff + (e.slot % 4) * 183, row.y, def, e.b, e.state))
            }
        }
        return out
    }
    func buildListQuads() -> [Quad] {
        guard let ui = ui, let g = game, let i = townOpen, let d = ui.dialog("buy_building") else { return [] }
        let town = g.towns[i]
        let (ox, oy) = buildListOrigin
        var out = dImage(d, "buy", "Background", ox, oy)
        out += dText(text("town_hall.title", "Town Hall"), rect(dLayer(d, "Title"), ox, oy), font: ui.font(20), centre: true, 0, 0)
        out += townButton("ok", x: ox + 710, y: oy + 546)
        let thumbs = ui.thumbnails(town.alignment)
        let frame = dLayer(d, "Frame"), cannot = dLayer(d, "Cannot Build"), f16 = ui.font(16)
        for t in buildTiles() {
            let tx = ox + t.x, ty = oy + t.y
            out += dImageAt(frame, "buy", x: tx, y: ty)
            if let th = thumbs?.layers.first(where: { $0.name.lowercased() == t.def.name.lowercased() || $0.name.lowercased() == t.def.keyword }) {
                out += dImageOffset(th, "thumb.\(town.alignment)", x: tx + 6, y: ty + 5)
            }
            if (2...4).contains(t.state), let x = cannot { out += dImageAt(x, "buy", x: tx + x.x - 33, y: ty + x.y - 31) }
            let bar = [1: "Gold Bar", 2: "Gray Bar", 6: "Green Bar"][t.state] ?? "Red Bar"
            out += dImageAt(dLayer(d, bar), "buy", x: tx, y: ty + 67)
            out += dText(t.def.name, DRect(tx + 6, ty + 68, 171, 32), font: f16, centre: true, vcentre: true, 0, 0)
        }
        out += materialDisplay(d, ox, oy, font: 14)
        return out
    }
    /// t_material_display (0x78fda0): the seven icons at their boxes, each followed by its amount (centred, top, halo, fitted).
    func materialDisplay(_ d: LayerFile, _ ox: Int, _ oy: Int, font size: Int) -> [Quad] {
        guard let g = game, let ui = ui else { return [] }
        var out: [Quad] = []
        let f = ui.font(size)
        for m in Renderer.townMaterials {
            out += dImage(d, "mat", m, ox, oy)
            guard let r = dRect(d, "\(m)_Number") else { continue }
            out += dText(Renderer.materialText(g.resources[m] ?? 0, font: f, width: r.w), r.offset(ox, oy), font: f, centre: true, halo: Renderer.halo200, 0, 0)
        }
        return out
    }

    // MARK: the building detail (t_buy_building_detail 0x5a3620, spec §2 D)

    func buildDetailQuads(_ b: RuleTables.BuildingDef) -> [Quad] {
        guard let ui = ui, let g = game, let i = townOpen, let d = ui.dialog("buy_building_detail") else { return [] }
        let town = g.towns[i]
        let (ox, oy) = buildDetailOrigin
        let halo = Renderer.halo200
        var out = dImage(d, "detail", "Background", ox, oy)
        out += dText(text("buy_building.title", "Purchase"), rect(dLayer(d, "Title"), ox, oy), font: ui.font(25), centre: true, vcentre: true, halo: halo, 0, 0)
        if let th = ui.thumbnails(town.alignment)?.layers.first(where: { $0.name.lowercased() == b.name.lowercased() || $0.name.lowercased() == b.keyword }), let slot = dLayer(d, "thumbnail") {
            out += dImageAt(th, "thumb.\(town.alignment)", x: ox + slot.x + (slot.width - th.width) / 2, y: oy + slot.y + (slot.height - th.height) / 2)
        }
        out += dText(b.name, rect(dLayer(d, "Structure_Name"), ox, oy), font: ui.font(14), centre: true, vcentre: true, halo: halo, 0, 0)
        out += dText(b.help, rect(dLayer(d, "description"), ox, oy), font: ui.font(18), centre: true, vcentre: true, halo: halo, 0, 0, clip: true)
        out += dText(buildDetailText(b), rect(dLayer(d, "Requirements"), ox, oy), font: ui.font(18), centre: true, vcentre: true, halo: halo, 0, 0)
        if g.canBuild(b, in: town) { out += townButton("buy", x: ox + 496, y: oy + 495) }
        out += townButton("cancel_button", x: ox + 29, y: oy + 495)
        // the cost (0x5a4c50): every material with a cost, in consecutive places, icons at Resource_k + (10,6)
        var k = 1
        for m in Renderer.townMaterials {
            guard let v = b.cost[m], v > 0 else { continue }
            if let r = dLayer(d, "Resource_\(k)") { out += dImageOffset(materialIcon(m, size: 32), "mat32", x: ox + r.x + 10, y: oy + r.y + 6) }
            out += dText("\(v)", rect(dLayer(d, "Resource_\(k)_Text"), ox, oy), font: ui.font(16), centre: true, 0, 0)
            k += 1
        }
        return out
    }

    // MARK: the recruit dialog (t_recruit_dialog 0x7f5b00, spec §3 B)

    /// The creature's price in every material, gold first (0x7f66e0's order).
    func creatureCost(_ c: CreatureDef) -> [(String, Int)] {
        let cost = c.cost.isEmpty ? ["Gold": c.gold] : c.cost
        return Renderer.townMaterials.compactMap { m in cost[m].flatMap { $0 != 0 || m == "Gold" ? (m, $0) : nil } }
    }
    /// The most that can be recruited: what waits, and what the treasury pays for (0x7fa822).
    func recruitMost(_ creature: String) -> Int {
        guard let g = game, let i = townOpen, let c = g.tables?.creature(creature) else { return 0 }
        var n = g.towns[i].available[creature] ?? 0
        for (m, v) in creatureCost(c) where v > 0 { n = min(n, (g.resources[m] ?? 0) / v) }
        return max(0, n)
    }
    func recruitQuads(_ creature: String, _ count: Int) -> [Quad] {
        guard let ui = ui, let g = game, let i = townOpen, let d = ui.dialog("recruit"), let c = g.tables?.creature(creature) else { return [] }
        let (ox, oy) = recruitOrigin
        let halo = Renderer.halo200
        var out = dImage(d, "recruit", "Background", ox, oy)
        let words = c.plural.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        out += dText(text("recruit_creatures.recruit", "Recruit %creatures").replacingOccurrences(of: "%creatures", with: words), rect(dLayer(d, "Title"), ox, oy), font: ui.font(25), centre: true, vcentre: true, halo: halo, 0, 0)
        if let box = dLayer(d, "Creature_Box") { out += creatureModelQuads(c.keyword, box: box, ox, oy) }
        let skills = iconSheet("skills.creature.52")
        let abilities = RuleTables.creatureAbilities[c.keyword.lowercased()] ?? []
        for k in 0..<4 {
            guard k < abilities.count, let l = skills[abilities[k].lowercased()], let slot = dLayer(d, "Ability_\(k + 1)") else { continue }
            out += dImageAt(l, "cskill", x: ox + slot.x, y: oy + slot.y)
        }
        // the label and the number under it (font = half the rect's height)
        let most = recruitMost(creature)
        let f18 = ui.font(18)
        for (slot, label, value) in [("Available_Number", text("available.recruit", "Available"), g.towns[i].available[creature] ?? 0), ("Recruit_Number", text("recruit.recruit", "Recruit"), count)] {
            guard let r = dRect(d, slot)?.offset(ox, oy) else { continue }
            out += dText(label, DRect(r.x, r.y, r.w, f18.lineHeight), font: f18, centre: true, halo: halo, 0, 0)
            out += dText("\(value)", DRect(r.x, r.y + f18.lineHeight, r.w, f18.lineHeight), font: f18, centre: true, halo: halo, 0, 0)
        }
        out += dText(text("total_cost.recruit", "Total Cost"), rect(dLayer(d, "Total_cost_text"), ox, oy), font: ui.font(23), centre: true, halo: halo, 0, 0)
        let f14 = ui.font(14)
        for (slot, v) in [("Damage_Text", "\(c.damageLow)-\(c.damageHigh)"), ("Hit_Points_Text", "\(c.hitPoints)"), ("Movement_Text", "\(c.move)"),
                          ("Melee_Attack_Text", "\(c.attack)"), ("Melee_Defense_TExt", "\(c.defense)"), ("Speed_text", "\(c.speed)")] {
            out += dText(v, rect(dLayer(d, slot), ox, oy), font: f14, centre: true, vcentre: true, 0, 0)
        }
        let f20 = ui.font(20)
        for m in Renderer.townMaterials {
            guard let r = dRect(d, "\(m)_Text") else { continue }
            out += dText(Renderer.materialText(g.resources[m] ?? 0, font: f20, width: r.w), r.offset(ox, oy), font: f20, centre: true, halo: halo, 0, 0)
        }
        for n in ["Damage", "Hit_Points", "Movement", "Melee_Attack", "Melee_Defense", "Speed", "Gold", "Sulfur", "Mercury", "Crystal", "Gems", "Wood", "Ore", "Abilities_Frame", "Animation_Frame"] {
            out += dImage(d, "recruit", n, ox, oy)
        }
        out += townButton("buy", x: ox + 454, y: oy + 541, disabled: count <= 0)
        out += townButton("cancel", x: ox + 12, y: oy + 542)
        if most > 0, let kit = kit, let r = dLayer(d, "Scrollbar") {
            out += quads(kit.hScrollbar(UIRect(ox + r.x, oy + r.y, r.width, r.height), value: Float(count) / Float(most)))
        }
        // the unit cost (Individual_Resource_k) and the total (Resource_k): icons centred, "%i" in 16 with the halo
        let f16 = ui.font(16)
        for (slot, textSlot, mult) in [("Individual_Resource_", "Individual_Resource_Text_", 1), ("Resource_", "Resource_Text_", count)] {
            for (k, (m, v)) in creatureCost(c).prefix(3).enumerated() {
                if let s = dLayer(d, "\(slot)\(k + 1)"), let icon = materialIcon(m, size: 32) {
                    out += dImageAt(icon, "mat32", x: ox + s.x + (s.width - icon.width) / 2, y: oy + s.y + (s.height - icon.height) / 2)
                }
                out += dText("\(v * mult)", rect(dLayer(d, "\(textSlot)\(k + 1)"), ox, oy), font: f16, centre: true, halo: halo, 0, 0)
            }
        }
        return out
    }

    // MARK: clicks

    /// A click while a town dialog is open. Returns true when handled.
    func townDialogClick(x: Float, y: Float) -> Bool {
        guard let dlg = townDialog, let ui = ui, let g = game, let i = townOpen else { return false }
        switch dlg {
        case .castle:
            castleClick(x: x, y: y); return true
        case .mageGuild, .guildSpell:
            mageGuildClick(x: x, y: y); return true
        case .buildList:
            let (ox, oy) = buildListOrigin
            if townButtonHit("ok", x: ox + 710, y: oy + 546, x, y) { townDialog = nil; return true }
            for t in buildTiles() where x >= Float(ox + t.x) && x < Float(ox + t.x + 183) && y >= Float(oy + t.y) && y < Float(oy + t.y + 101) {
                if t.state == 2 { prompt = (g.tables?.strings["disabled_building.dialog"] ?? "This building has been disabled.", false, nil); return true }
                townDialog = .buildDetail(t.def); return true
            }
            return true
        case .buildDetail(let b):
            let (ox, oy) = buildDetailOrigin
            if g.canBuild(b, in: g.towns[i]), townButtonHit("buy", x: ox + 496, y: oy + 495, x, y) { g.build(b, in: i); townDialog = nil; return true }
            if townButtonHit("cancel_button", x: ox + 29, y: oy + 495, x, y) { townDialog = .buildList }
            return true
        case .recruit(let creature, let count, let fromCastle):
            let (ox, oy) = recruitOrigin
            guard let d = ui.dialog("recruit"), let c = g.tables?.creature(creature) else { townDialog = nil; return true }
            let back: TownDialog? = fromCastle ? .castle : nil
            let most = recruitMost(creature)
            if townButtonHit("buy", x: ox + 454, y: oy + 541, x, y) {
                if count > 0, count <= most, g.addToGarrison(i, creature, count) {
                    g.towns[i].available[creature, default: 0] -= count
                    for (m, v) in creatureCost(c) { g.resources[m, default: 0] -= v * count }
                    g.log.append("recruited \(count) \(count == 1 ? c.name : c.plural)")
                    sound?.play("dialogue.recruit")
                    townDialog = back
                }
                return true
            }
            if townButtonHit("cancel", x: ox + 12, y: oy + 542, x, y) { townDialog = back; return true }
            if most > 0, let bar = dLayer(d, "Scrollbar"), let kit = kit {
                let r = UIRect(ox + bar.x, oy + bar.y, bar.width, bar.height)
                guard r.contains(x, y) else { return true }
                let f = kit.file("control.horizontal_scroll")
                let lw = MenuKit.find(f, "Up_Released")?.width ?? 52, rw = MenuKit.find(f, "Down_Released")?.width ?? 56
                var n = count
                if x < Float(r.x + lw) { n = count - 1 } else if x >= Float(r.x + r.w - rw) { n = count + 1 }
                else { n = Int((kit.hScrollbarValue(r, x) * Float(most)).rounded()) }
                townDialog = .recruit(creature: creature, count: max(0, min(most, n)), fromCastle: fromCastle)
            }
            return true
        }
    }
}
