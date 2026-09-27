import Foundation
import H4Engine

/// The blacksmith / conservatory shop (t_dialog_blacksmith 0x670b80 / 0x670d90,
/// layers.dialog.Blacksmith.Layout; object_dialogs_spec §2): Background and Border, the panel
/// Blacksmith.Generic's BG_Picture at Picture (49,42), four item rows and five potion rows -- the
/// art file's button state at the row's top-left + its own offset, a parchment's spell icon at
/// Icon_<row>, the arrows at their hotspots' corners, center_box with the count (20), the price (the
/// rect's height) -- the title (25), the kingdom's gold (16) and the total (20), button.ok and
/// button.buy (disabled until something is affordable), the visiting army's ring row at (148,479),
/// the chosen hero's portrait at (44,472) under large_portrait_frame. All black, no halo.
/// (A town's blacksmith (t_blacksmith_window) keeps its alignment panel with rows named after the
/// artifacts.)
struct ShopState {
    var offer: ShopOffer
    var counts = Array(repeating: 0, count: 12)
    var receiver = 0
    /// The rows: (artifact, row layer): the Generic panel's Item_1..4 and Potion_1..5 with the
    /// object's stock, or a town panel's rows named after the artifact each sells.
    var rows: [(artifact: Int, slot: String)] = []
    init(offer: ShopOffer, panel: LayerFile?) {
        self.offer = offer
        if let p = panel, p["Item_1"] == nil {
            func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "'", with: "") }
            let named = p.layers.filter { l in p.layers.contains { $0.name.lowercased() == "l_arrow_" + l.name.lowercased() } }
            rows = named.sorted { ($0.y / 100, $0.x) < ($1.y / 100, $1.x) }.compactMap { l in
                RuleTables.artifactIds.firstIndex(of: norm(l.name)).map { ($0, l.name) }
            }
        } else {
            // Item_2 shows the object's separate artifact (the weapon, the stock's 4th), Item_1/3/4 the stock's 0..2 (0x671671)
            var items = offer.items
            if items.count == 4 { items = [items[0], items[3], items[1], items[2]] }
            rows = items.enumerated().map { ($0.element, "Item_\($0.offset + 1)") } + offer.potions.enumerated().map { ($0.element, "Potion_\($0.offset + 1)") }
        }
    }
    var receivers: [Hero] { [offer.hero] + offer.hero.companions }
    var generic: Bool { rows.first.map { $0.slot.hasPrefix("Item_") || $0.slot.hasPrefix("Potion_") } ?? true }
}

extension Renderer {
    var shopOrigin: (Int, Int) { dialogOrigin800 }

    /// A shop picture (layers.dialog.Blacksmith.<keyword>[.<item|potion>]), matched without regard to case or apostrophes.
    func shopArt(_ artifact: Int, potionRow: Bool) -> LayerFile? {
        guard let ui = ui else { return nil }
        let base = RuleTables.artifactBase(artifact)
        guard base < RuleTables.artifactIds.count else { return nil }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "_") }
        let want = norm(RuleTables.artifactIds[base])
        if ui.shopNames == nil {
            var names: [String: String] = [:]
            for a in [ui.archive] + ui.overlays {
                for n in a.names(prefix: "layers.dialog.Blacksmith.") where n.hasSuffix(".h4d") {
                    let short = String(n.dropFirst("layers.dialog.".count).dropLast(4))
                    names[norm(String(short.dropFirst("Blacksmith.".count)))] = short
                }
            }
            ui.shopNames = names
        }
        let file = ui.shopNames?[want + (potionRow ? ".potion" : ".item")] ?? ui.shopNames?[want]
        return file.flatMap { ui.dialog($0) }
    }

    /// A panel layer by name, whatever its case.
    func shopLayer(_ p: LayerFile, _ name: String) -> UILayer? { dLayer(p, name) }
    func shopPanel(_ s: ShopState) -> LayerFile? { ui?.dialog("Blacksmith.\(s.offer.panel)") ?? ui?.dialog("Blacksmith.Generic") }
    func shopPicture(_ d: LayerFile) -> (Int, Int) {
        let (ox, oy) = shopOrigin
        let pic = d["Picture"]
        return (ox + (pic?.x ?? 49), oy + (pic?.y ?? 42))
    }
    func shopCanBuy(_ s: ShopState) -> Bool {
        let t = shopTotal(s)
        return s.receiver < s.receivers.count && t > 0 && t <= (game?.resources["Gold", default: 0] ?? 0)
    }

    func shopQuads() -> [Quad] {
        guard let s = shop, let g = game, let ui = ui, let d = ui.dialog("Blacksmith.Layout") else { return [] }
        let (ox, oy) = shopOrigin
        var out: [Quad] = []
        out += dImage(d, "shop", "Background", ox, oy)
        out += dImage(d, "shop", "Border", ox, oy)
        let (px, py) = shopPicture(d)
        if let panel = shopPanel(s) {
            out += dImage(panel, "shoppanel.\(s.offer.panel)", "BG_Picture", px, py)
            for (k, r) in s.rows.enumerated() {
                if s.generic {
                    let potion = r.slot.hasPrefix("Potion")
                    guard let box = shopLayer(panel, r.slot) else { continue }
                    // the row's button: the art's state image at the row's top-left + its own box
                    if let art = shopArt(r.artifact, potionRow: potion) {
                        out += dImageOffset(art["Released"] ?? dLayer(art, "released"), "shopart.\(RuleTables.artifactBase(r.artifact)).\(potion)", x: px + box.x, y: py + box.y)
                    }
                    // a parchment's spell (0x551de0 at Icon_<row>)
                    if let sp = RuleTables.artifactSpell(r.artifact), sp < RuleTables.spells.count, let ib = dRect(panel, "Icon_\(r.slot)"),
                       let ic = spellIcon(RuleTables.spells[sp].name) ?? spellIcon(RuleTables.spells[sp].keyword) {
                        out += dImageAt(ic, "spell52", x: px + ib.x, y: py + ib.y)
                    }
                    if let l = dRect(panel, "L_Arrow_\(r.slot)") { out += dImageOffset(dLayer(dFile("dialog.Blacksmith.l_arrow"), "Released"), "shoparrow.l", x: px + l.x, y: py + l.y) }
                    if let rr = dRect(panel, "R_Arrow_\(r.slot)") { out += dImageOffset(dLayer(dFile("dialog.Blacksmith.r_arrow"), "Released"), "shoparrow.r", x: px + rr.x, y: py + rr.y) }
                    if let n = dRect(panel, "Number_\(r.slot)"), let bx = dLayer(dFile("dialog.Blacksmith.center_box"), "Box") {
                        out += dImageAt(bx, "shopbox", x: px + n.x, y: py + n.y)
                        out += dText("\(s.counts[k])", DRect(n.x, n.y, bx.width, bx.height), font: dFont(2 * bx.height / 3), vcentre: true, px, py)
                    }
                    if let t = dRect(panel, "Text_\(r.slot)") {
                        out += dText("\(g.artifactCost(r.artifact))", t, font: dFont(t.h), vcentre: true, px, py)
                    }
                } else {
                    out += townShopRow(s, k, r, panel, px, py)
                }
            }
        }
        out += dText(s.offer.title, dRect(d, "title_banner"), font: dFont(26), ox, oy)
        out += dText("\(g.resources["Gold", default: 0])", dRect(d, "Kingdom_gold_text"), font: dFont(16), ox, oy)
        out += dText("\(shopTotal(s))", dRect(d, "total_spent_text"), font: dFont(22), vcentre: true, ox, oy)
        if let c = dRect(d, "Close_button") { out += dButton("ok", "Released", x: ox + c.x, y: oy + c.y) }
        if let b = dRect(d, "Purchase_Button_Pressed") { out += dButton("buy", shopCanBuy(s) ? "Released" : "disabled", x: ox + b.x, y: oy + b.y) }
        // the visiting army's ring row, the chosen hero's portrait under the frame
        out += ringRowQuads(shopRing(), items: ringItems(s.offer.hero), selected: s.receiver)
        if s.receiver < s.receivers.count, let slot = dRect(d, "Hero_Portrait") {
            let h = s.receivers[s.receiver]
            if let p = ui.portrait(keyword: h.keyword, alignment: h.alignment, size: 82) { out += dImageAt(p, "portrait82.\(h.alignment)", x: ox + slot.x, y: oy + slot.y) }
        }
        out += dImage(d, "shop", "large_portrait_frame", ox, oy)
        return out
    }
    /// The ring row: at x 148, centred on y 519 (80 high).
    func shopRing() -> [(piece: String, fx: Int, fy: Int)] {
        let (ox, oy) = shopOrigin
        return ringRow(x: ox + 148, y: oy + 519 - 40)
    }
    /// A town blacksmith's row (its panel names the rows after the artifacts, with the shelves drawn).
    func townShopRow(_ s: ShopState, _ k: Int, _ r: (artifact: Int, slot: String), _ panel: LayerFile, _ px: Int, _ py: Int) -> [Quad] {
        guard let g = game else { return [] }
        var out: [Quad] = []
        if let box = shopLayer(panel, r.slot), let art = shopArt(r.artifact, potionRow: false), let l = art["Released"] {
            let full = art["Layer 1"] ?? art["Box"] ?? l
            let x0 = px + box.x + (box.width - full.width) / 2, y0 = py + box.y + (box.height - full.height) / 2
            out += dImageAt(l, "shopart.\(RuleTables.artifactBase(r.artifact)).town", x: x0 + l.x - full.x, y: y0 + l.y - full.y)
        }
        if let t = dRect(panel, "Text_\(r.slot)") { out += dText("\(g.artifactCost(r.artifact))", t, font: dFont(t.h), vcentre: true, px, py) }
        if let n = dRect(panel, "Number_\(r.slot)") { out += dText("\(s.counts[k])", n, font: dFont(20), vcentre: true, px, py) }
        if let l = dRect(panel, "L_Arrow_\(r.slot)") { out += dImageOffset(dLayer(dFile("dialog.Blacksmith.l_arrow"), "Released"), "shoparrow.l", x: px + l.x, y: py + l.y) }
        if let rr = dRect(panel, "R_Arrow_\(r.slot)") { out += dImageOffset(dLayer(dFile("dialog.Blacksmith.r_arrow"), "Released"), "shoparrow.r", x: px + rr.x, y: py + rr.y) }
        return out
    }
    func shopTotal(_ s: ShopState) -> Int {
        guard let g = game else { return 0 }
        return s.rows.enumerated().reduce(0) { $0 + g.artifactCost($1.element.artifact) * s.counts[$1.offset] }
    }

    func shopClick(x: Float, y: Float) {
        guard var s = shop, let g = game, let d = ui?.dialog("Blacksmith.Layout") else { shop = nil; return }
        let (ox, oy) = shopOrigin
        let (px, py) = shopPicture(d)
        if let panel = shopPanel(s) {
            for (k, r) in s.rows.enumerated() {
                let lx = x - Float(px), ly = y - Float(py)
                if let l = dRect(panel, "L_Arrow_\(r.slot)"), DRect(l.x, l.y, 23, 34).contains(lx, ly), s.counts[k] > 0 { s.counts[k] -= 1 }
                let onItem: Bool = {
                    guard s.generic, let box = dRect(panel, r.slot), let art = shopArt(r.artifact, potionRow: r.slot.hasPrefix("Potion")), let rel = art["Released"] else {
                        return inside(shopLayer(panel, r.slot), at: px, py, x, y)
                    }
                    return DRect(box.x + rel.x, box.y + rel.y, rel.width, rel.height).contains(lx, ly)
                }()
                if let rr = dRect(panel, "R_Arrow_\(r.slot)"), DRect(rr.x, rr.y, 23, 34).contains(lx, ly) || onItem, s.counts[k] < 9999 { s.counts[k] += 1 }
            }
        }
        for (k, slot) in shopRing().enumerated() where k < s.receivers.count && DRect(slot.fx + 15, slot.fy + 15, 52, 52).contains(x, y) { s.receiver = k }
        if let b = dRect(d, "Purchase_Button_Pressed"), DRect(ox + b.x, oy + b.y, 78, 46).contains(x, y), shopCanBuy(s) {
            g.buy(s.rows.enumerated().map { ($0.element.artifact, s.counts[$0.offset]) }, for: s.receivers[s.receiver])
            s.counts = Array(repeating: 0, count: 12)
            sound?.play("dialogue.marketplace")
        }
        if let c = dRect(d, "Close_button"), DRect(ox + c.x, oy + c.y, 76, 44).contains(x, y) { shop = nil; return }
        shop = s
    }
    /// Balloons: the artifact's name on its picture, More / Less on the arrows, Okay / Buy.
    func shopTip(x: Float, y: Float) -> String? {
        guard let s = shop, let d = ui?.dialog("Blacksmith.Layout"), let panel = shopPanel(s) else { return nil }
        let (ox, oy) = shopOrigin
        let (px, py) = shopPicture(d)
        let lx = x - Float(px), ly = y - Float(py)
        for r in s.rows {
            if let l = dRect(panel, "L_Arrow_\(r.slot)"), DRect(l.x, l.y, 23, 34).contains(lx, ly) { return interfaceText("blacksmith", "item_down")?.balloon }
            if let l = dRect(panel, "R_Arrow_\(r.slot)"), DRect(l.x, l.y, 23, 34).contains(lx, ly) { return interfaceText("blacksmith", "item_up")?.balloon }
            if inside(shopLayer(panel, r.slot), at: px, py, x, y) { return artifactName(r.artifact).name }
        }
        if let c = dRect(d, "Close_button"), DRect(ox + c.x, oy + c.y, 76, 44).contains(x, y) { return interfaceText("shared", "ok")?.balloon }
        if let b = dRect(d, "Purchase_Button_Pressed"), DRect(ox + b.x, oy + b.y, 78, 46).contains(x, y) { return interfaceText("shared", "buy")?.balloon }
        return nil
    }
}
