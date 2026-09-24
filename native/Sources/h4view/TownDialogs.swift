import Foundation
import Metal
import H4Engine

/// What is open on top of the town screen.
enum TownDialog {
    case buildList                         // layers.dialog.buy_building: every building of the town as a thumbnail
    case buildDetail(RuleTables.BuildingDef)   // layers.dialog.buy_building_detail: one building, Buy/Cancel
    case recruit(creature: String, count: Int) // layers.dialog.recruit: a dwelling's creature with a slider
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
    /// The requirement chain of a building as text.
    func requirements(of b: RuleTables.BuildingDef) -> String {
        let chain: [String: String] = ["town hall": "village hall", "city hall": "town hall", "citadel": "fort", "castle": "citadel",
                                       "mage guild 2": "mage guild 1", "mage guild 3": "mage guild 2", "mage guild 4": "mage guild 3", "mage guild 5": "mage guild 4"]
        guard let ui = ui, let g = game, let i = townOpen, let req = chain[b.keyword], let t = g.tables else { return "" }
        _ = ui
        let name = t.buildings(for: g.towns[i].alignment).first { $0.keyword == req }?.name ?? req
        return "Requires: \(name)"
    }

    // MARK: drawing

    static let buildCell = (w: 183, h: 101, cols: 4, rows: 5)

    func townDialogQuads() -> [Quad] {
        guard let dlg = townDialog, let ui = ui, let g = game, let i = townOpen, let t = g.tables else { return [] }
        let town = g.towns[i]
        var out: [Quad] = []
        switch dlg {
        case .buildList:
            guard let d = ui.dialog("buy_building") else { return [] }
            let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
            out += dialogImages(d, key: "buy", at: ox, oy, skip: ["Gold Bar", "Gray Bar", "Green Bar", "Red Bar", "Cannot Build"])
            out += centred("Build in \(town.name)", in: d["Title"], at: ox, oy, font: ui.dateFont)
            let list = t.buildings(for: town.alignment).filter { !$0.cost.isEmpty || $0.keyword == "prison" }
            let thumbs = ui.thumbnails(town.alignment)
            buildCells = []
            for (k, b) in list.prefix(Renderer.buildCell.cols * Renderer.buildCell.rows).enumerated() {
                let cx = ox + 33 + (k % Renderer.buildCell.cols) * Renderer.buildCell.w, cy = oy + 31 + (k / Renderer.buildCell.cols) * Renderer.buildCell.h
                let built = town.buildings.contains(b.keyword)
                let can = g.canBuild(b, in: town)
                let affordable = b.cost.allSatisfy { g.resources[$0.key, default: 0] >= $0.value }
                let bar = built ? "Gold Bar" : can ? "Green Bar" : affordable ? "Gray Bar" : "Red Bar"
                if let th = thumbs?.layers.first(where: { $0.name.lowercased() == b.name.lowercased() || $0.name.lowercased() == b.keyword }) {
                    out.append(Quad(texture: uiTexture("thumb|\(town.alignment)|\(th.name)", { th.bitmap }), x: cx + 6, y: cy + 5, w: th.width, h: th.height))
                }
                if let bl = d[bar] { out.append(Quad(texture: uiTexture("dlg|buy|\(bl.name)", { bl.bitmap }), x: cx + (bl.x - 33), y: cy + (bl.y - 31), w: bl.width, h: bl.height)) }
                if !built, !can, let x = d["Cannot Build"] { out.append(Quad(texture: uiTexture("dlg|buy|cannot", { x.bitmap }), x: cx + (x.x - 33), y: cy + (x.y - 31), w: x.width, h: x.height)) }
                let w = ui.numberFont.measure(b.name)
                out.append(Quad(texture: uiTexture("num|\(b.name)", { ui.numberFont.render(b.name, colour: (40, 24, 8)) }), x: cx + (183 - w) / 2, y: cy + 78, w: w, h: ui.numberFont.size))
                buildCells.append(((cx, cy, Renderer.buildCell.w, Renderer.buildCell.h), b))
            }
            for r in ui.resourceNames {   // the treasury along the bottom
                out += centred(String(g.resources[r] ?? 0), in: d["\(r)_Number"] ?? d["\(r)_number"], at: ox, oy, font: ui.numberFont)
            }
            if let ok = d["OK_Button"], let b = ui.button("ok") {
                out.append(Quad(texture: uiTexture("button|ok", { b.bitmap }), x: ox + ok.x + (ok.width - b.width) / 2, y: oy + ok.y + (ok.height - b.height) / 2, w: b.width, h: b.height))
            }
        case .buildDetail(let b):
            guard let d = ui.dialog("buy_building_detail") else { return [] }
            let ox = (AdventureUI.width - 583) / 2, oy = (AdventureUI.height - 559) / 2
            out += dialogImages(d, key: "detail", at: ox, oy)
            out += centred("Build Structure", in: d["Title"], at: ox, oy, font: ui.dateFont)
            if let th = ui.thumbnails(town.alignment)?.layers.first(where: { $0.name.lowercased() == b.name.lowercased() || $0.name.lowercased() == b.keyword }), let slot = d["thumbnail"] {
                out.append(Quad(texture: uiTexture("thumb|\(town.alignment)|\(th.name)", { th.bitmap }), x: ox + slot.x, y: oy + slot.y, w: th.width, h: th.height))
            }
            out += centred(b.name, in: d["Structure_Name"], at: ox, oy, font: ui.dateFont)
            out += paragraph(b.help, in: d["description"], at: ox, oy, font: ui.numberFont)
            let req = requirements(of: b)
            out += paragraph(town.buildings.contains(b.keyword) ? "Already built." : req.isEmpty ? "" : req, in: d["Requirements"], at: ox, oy, font: ui.numberFont)
            let costs = ui.resourceNames.filter { b.cost[$0] != nil }
            let slots = costs.count <= 3 ? Array(1...max(1, costs.count)) : Array(1...costs.count)
            for (k, r) in costs.enumerated() where k < 7 {
                let n = slots[k]
                if let slot = d["Resource_\(n)"], let icon = materialIcon(r, size: 32) {
                    out.append(Quad(texture: uiTexture("mat32|\(icon.name)", { icon.bitmap }), x: ox + slot.x + (slot.width - icon.width) / 2, y: oy + slot.y + (slot.height - icon.height) / 2, w: icon.width, h: icon.height))
                }
                let enough = g.resources[r, default: 0] >= b.cost[r]!
                out += centred(String(b.cost[r]!), in: d["Resource_\(n)_Text"], at: ox, oy, font: ui.numberFont, colour: enough ? (40, 24, 8) : (180, 30, 30))
            }
            if let buy = d["Buy_Button"], let img = ui.button("buy", state: g.canBuild(b, in: town) ? "Released" : "disabled") ?? ui.button("buy", state: "Disabled") {
                out.append(Quad(texture: uiTexture("button|buy|\(img.name)", { img.bitmap }), x: ox + buy.x + (buy.width - img.width) / 2, y: oy + buy.y + (buy.height - img.height) / 2, w: img.width, h: img.height))
            }
        case .recruit(let creature, let count):
            guard let d = ui.dialog("recruit"), let c = t.creature(creature) else { return [] }
            let ox = (AdventureUI.width - 553) / 2, oy = (AdventureUI.height - 600) / 2
            out += dialogImages(d, key: "recruit", at: ox, oy)
            func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
            out += centred("Recruit \(cap(c.plural))", in: d["Title"], at: ox, oy, font: ui.dateFont)
            if let box = d["Creature_Box"] {   // the creature's big portrait in the box
                if let big = ui.creatureIcon(c.keyword, size: 82) {
                    out.append(Quad(texture: uiTexture("cicon82|\(c.keyword)", { big.bitmap }), x: ox + box.x + (box.width - big.width * 2) / 2, y: oy + box.y + (box.height - big.height * 2) / 2, w: big.width * 2, h: big.height * 2))
                }
            }
            let stats: [(String, String)] = [("Damage_Text", "\(c.damageLow)-\(c.damageHigh)"), ("Hit_Points_Text", "\(c.hitPoints)"), ("Movement_Text", "\(c.move)"),
                                             ("Melee_Attack_Text", "\(c.attack)"), ("Melee_Defense_TExt", "\(c.defense)"), ("Speed_text", "\(c.speed)")]
            for (slot, v) in stats { out += centred(v, in: d[slot], at: ox, oy, font: ui.numberFont) }
            // cost per creature (Individual_Resource_1..3) and the total (Resource_1..3)
            let costs: [(String, Int)] = [("Gold", c.gold)].filter { $0.1 > 0 }
            for (k, (r, v)) in costs.enumerated() where k < 3 {
                for (prefix, textPrefix, mult) in [("Individual_Resource_", "Individual_Resource_Text_", 1), ("Resource_", "Resource_Text_", count)] {
                    if let slot = d["\(prefix)\(k + 1)"], let icon = materialIcon(r, size: 32) {
                        out.append(Quad(texture: uiTexture("mat32|\(icon.name)", { icon.bitmap }), x: ox + slot.x + (slot.width - icon.width) / 2, y: oy + slot.y + (slot.height - icon.height) / 2, w: icon.width, h: icon.height))
                    }
                    out += centred(String(v * mult), in: d["\(textPrefix)\(k + 1)"], at: ox, oy, font: ui.numberFont)
                }
            }
            let available = town.available[c.keyword] ?? 0
            out += centred("Available: \(available)", in: d["Available_Number"], at: ox, oy, font: ui.numberFont)
            out += centred("Recruit: \(count)", in: d["Recruit_Number"], at: ox, oy, font: ui.numberFont)
            out += centred("Total cost", in: d["Total_cost_text"], at: ox, oy, font: ui.numberFont)
            // the player's treasury in the resource box on the left
            for r in ui.resourceNames { out += centred(String(g.resources[r] ?? 0), in: d["\(r)_Text"], at: ox, oy, font: ui.numberFont) }
            if let bar = d["Scrollbar"], let sc = ui.scrollControl() {
                // the track tiled between the two arrows, the thumb along it by count/most
                let affordable = c.gold > 0 ? g.resources["Gold", default: 0] / c.gold : available
                let most = max(1, min(available, affordable))
                if let bg = sc["Background"] {
                    var x = ox + bar.x + 52
                    while x < ox + bar.x + bar.width - 56 { out.append(Quad(texture: uiTexture("scroll|bg", { bg.bitmap }), x: x, y: oy + bar.y, w: min(bg.width, ox + bar.x + bar.width - 56 - x), h: bg.height)); x += bg.width }
                }
                if let up = sc["Up_Released"] { out.append(Quad(texture: uiTexture("scroll|up", { up.bitmap }), x: ox + bar.x, y: oy + bar.y, w: up.width, h: up.height)) }
                if let dn = sc["Down_Released"] { out.append(Quad(texture: uiTexture("scroll|down", { dn.bitmap }), x: ox + bar.x + bar.width - dn.width, y: oy + bar.y, w: dn.width, h: dn.height)) }
                if let th = sc["Thumb"] {
                    let track = bar.width - 52 - 56 - th.width
                    let f = Float(count) / Float(most)
                    out.append(Quad(texture: uiTexture("scroll|thumb", { th.bitmap }), x: ox + bar.x + 52 + Int(Float(track) * f), y: oy + bar.y + (th.y - 2), w: th.width, h: th.height))
                }
            }
            let affordable = c.gold > 0 ? g.resources["Gold", default: 0] / c.gold : available
            let can = count > 0 && count <= min(available, affordable)
            if let buy = d["Buy_Button"], let img = ui.button("buy", state: can ? "Released" : "disabled") ?? ui.button("buy", state: "Disabled") {
                out.append(Quad(texture: uiTexture("button|buy|\(img.name)", { img.bitmap }), x: ox + buy.x + (buy.width - img.width) / 2, y: oy + buy.y + (buy.height - img.height) / 2, w: img.width, h: img.height))
            }
            if let cancel = d["Cancel_Button"], let img = ui.button("cancel") {
                out.append(Quad(texture: uiTexture("button|cancel", { img.bitmap }), x: ox + cancel.x + (cancel.width - img.width) / 2, y: oy + cancel.y + (cancel.height - img.height) / 2, w: img.width, h: img.height))
            }
        }
        return out
    }

    // MARK: clicks

    /// A click while a town dialog is open. Returns true when handled.
    func townDialogClick(x: Float, y: Float) -> Bool {
        guard let dlg = townDialog, let ui = ui, let g = game, let i = townOpen, let hero = g.heroes.first else { return false }
        switch dlg {
        case .buildList:
            let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
            if let d = ui.dialog("buy_building"), inside(d["OK_Button"], at: ox, oy, x, y) { townDialog = nil; return true }
            for cell in buildCells where x >= Float(cell.rect.0) && x < Float(cell.rect.0 + cell.rect.2) && y >= Float(cell.rect.1) && y < Float(cell.rect.1 + cell.rect.3) {
                townDialog = .buildDetail(cell.building); return true
            }
            if x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 600) { townDialog = nil }
            return true
        case .buildDetail(let b):
            let ox = (AdventureUI.width - 583) / 2, oy = (AdventureUI.height - 559) / 2
            guard let d = ui.dialog("buy_building_detail") else { townDialog = nil; return true }
            if inside(d["Buy_Button"], at: ox, oy, x, y) {
                if g.canBuild(b, in: g.towns[i]) { g.build(b, in: i); townDialog = nil }
                return true
            }
            if inside(d["Cancel_Button"], at: ox, oy, x, y) { townDialog = .buildList; return true }
            return true
        case .recruit(let creature, let count):
            let ox = (AdventureUI.width - 553) / 2, oy = (AdventureUI.height - 600) / 2
            guard let d = ui.dialog("recruit"), let c = g.tables?.creature(creature) else { townDialog = nil; return true }
            let available = g.towns[i].available[creature] ?? 0
            let affordable = c.gold > 0 ? g.resources["Gold", default: 0] / c.gold : available
            let most = min(available, affordable)
            if inside(d["Buy_Button"], at: ox, oy, x, y) {
                if count > 0, count <= most, g.add(creature, count, to: hero) {
                    g.towns[i].available[creature, default: 0] -= count
                    g.resources["Gold", default: 0] -= count * c.gold
                    g.log.append("recruited \(count) \(count == 1 ? c.name : c.plural) for \(count * c.gold) gold")
                    townDialog = nil
                }
                return true
            }
            if inside(d["Cancel_Button"], at: ox, oy, x, y) { townDialog = nil; return true }
            if let bar = d["Scrollbar"], inside(bar, at: ox, oy, x, y) {
                let lx = x - Float(ox + bar.x)
                var n = count
                if lx < 52 { n = max(0, count - 1) }
                else if lx > Float(bar.width - 56) { n = min(most, count + 1) }
                else if bar.width > 108 { n = Int((Float(most) * (lx - 52) / Float(bar.width - 108)).rounded()) }
                townDialog = .recruit(creature: creature, count: max(0, min(most, n)))
                return true
            }
            return true
        }
    }
}
