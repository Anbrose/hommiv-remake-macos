import Foundation
import H4Engine

/// The blacksmith / conservatory shop (layers.dialog.Blacksmith.Layout, the panel
/// Blacksmith.<Generic|school> drawn in its Picture; heroes4.exe 0x670b80): four item rows and five
/// potion rows, each its artifact's picture, price and a count set with the arrows (0..9999); the
/// visiting army below to pick who receives them; Purchase pays the total from the kingdom's gold.
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
            rows = offer.items.enumerated().map { ($0.element, "Item_\($0.offset + 1)") } + offer.potions.enumerated().map { ($0.element, "Potion_\($0.offset + 1)") }
        }
    }
    var receivers: [Hero] { [offer.hero] + offer.hero.companions }
}

extension Renderer {
    var shopOrigin: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }

    /// A shop picture (layers.dialog.Blacksmith.<name>), matched without regard to case or apostrophes.
    func shopArt(_ artifact: Int, potionRow: Bool) -> LayerFile? {
        guard let ui = ui else { return nil }
        if RuleTables.artifactBase(artifact) == 0x7c { return ui.dialog(potionRow ? "Blacksmith.parchment.potion" : "Blacksmith.parchment.item") }
        let base = RuleTables.artifactBase(artifact)
        guard base < RuleTables.artifactIds.count else { return nil }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "'", with: "") }
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
        return ui.shopNames?[want].flatMap { ui.dialog($0) }
    }

    /// A panel layer by name, whatever its case.
    func shopLayer(_ p: LayerFile, _ name: String) -> UILayer? { p[name] ?? p.layers.first { $0.name.lowercased() == name.lowercased() } }
    func shopPanel(_ s: ShopState) -> LayerFile? { ui?.dialog("Blacksmith.\(s.offer.panel)") ?? ui?.dialog("Blacksmith.Generic") }

    func shopQuads() -> [Quad] {
        guard let s = shop, let g = game, let ui = ui, let d = ui.dialog("Blacksmith.Layout") else { return [] }
        let (ox, oy) = shopOrigin
        var out = dialogImages(d, key: "shop", at: ox, oy, skip: ["DONT USE", "DONTUSE", "Picture", "Army_display", "Army_display_single"])
        // the shop panel inside Picture
        let pic = d["Picture"]
        let px = ox + (pic?.x ?? 49), py = oy + (pic?.y ?? 42)
        if let panel = shopPanel(s) {
            out += dialogImages(panel, key: "shoppanel|\(s.offer.panel)", at: px, py, skip: Set(panel.layers.map(\.name).filter { $0 != "BG_Picture" }))
            for (k, r) in s.rows.enumerated() {
                let potion = r.slot.hasPrefix("Potion") || (r.slot.lowercased().contains("potion") || r.slot.lowercased().contains("vial"))
                if let box = shopLayer(panel, r.slot), let art = shopArt(r.artifact, potionRow: potion) {
                    let artName = art.layers.first?.name ?? ""
                    // an item's picture fills its 160 x 160 box; a potion's bottle alone stands in its smaller one
                    // (a town's panel has its shelves drawn already: the picture alone, placed by its frame)
                    let named = panel["Item_1"] == nil
                    for n in potion || named ? ["Released"] : ["Layer 1", "Released"] {
                        guard let l = art[n] else { continue }
                        let full = potion && !named ? l : art["Layer 1"] ?? art["Box"] ?? art["Black Outline"] ?? l
                        let x0 = px + box.x + (box.width - full.width) / 2, y0 = py + box.y + (box.height - full.height) / 2
                        out.append(Quad(texture: uiTexture("shopart|\(r.artifact & 0xffff)|\(artName)|\(n)", { l.bitmap }), x: x0 + l.x - full.x, y: y0 + l.y - full.y, w: l.width, h: l.height))
                    }
                    // a parchment shows its spell
                    if let sp = RuleTables.artifactSpell(r.artifact), sp < RuleTables.spells.count,
                       let ic = spellIcon(RuleTables.spells[sp].name) ?? spellIcon(RuleTables.spells[sp].keyword) {
                        let cx = px + box.x + box.width / 2, cy = py + box.y + box.height / 2 + (potion ? 10 : 18)
                        out.append(Quad(texture: uiTexture("spellicon|\(ic.name)", { ic.bitmap }), x: cx - ic.width / 2, y: cy - ic.height / 2, w: ic.width, h: ic.height))
                    }
                } else if let box = shopLayer(panel, r.slot), let icon = artifactIcon(r.artifact) {
                    out.append(Quad(texture: uiTexture("art|\(r.artifact & 0xffff)", { icon.bitmap }), x: px + box.x + (box.width - icon.width) / 2, y: py + box.y + (box.height - icon.height) / 2, w: icon.width, h: icon.height))
                }
                out += centred("\(g.artifactCost(r.artifact))", in: shopLayer(panel, "Text_\(r.slot)"), at: px, py, font: ui.numberFont)
                out += centred("\(s.counts[k])", in: shopLayer(panel, "Number_\(r.slot)"), at: px, py, font: ui.numberFont, colour: (255, 230, 160))
                for (arrow, file, on) in [("L_Arrow_", "l_arrow", s.counts[k] > 0), ("R_Arrow_", "r_arrow", s.counts[k] < 9999)] {
                    guard let box = shopLayer(panel, "\(arrow)\(r.slot)"), let a = ui.dialog("Blacksmith.\(file)"), let l = a[on ? "Released" : "Disbaled"] ?? a["Released"] else { continue }
                    out.append(Quad(texture: uiTexture("shoparrow|\(file)|\(on)", { l.bitmap }), x: px + box.x + (box.width - l.width) / 2, y: py + box.y + (box.height - l.height) / 2, w: l.width, h: l.height))
                }
            }
        }
        out += centred(s.offer.title, in: d["title_banner"], at: ox, oy, font: ui.dateFont)
        // the army: heroes first, then creatures; the chosen receiver framed
        if let box = d["Army_display_single"] {
            let slotW = box.width / 7
            var icons: [(UILayer?, String)] = s.receivers.map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), "") }
            icons += s.offer.hero.army.map { (ui.creatureIcon($0.creature), String($0.count)) }
            for (k, ic) in icons.prefix(7).enumerated() {
                let cx = ox + box.x + k * slotW + slotW / 2, cy = oy + box.y + box.height / 2
                if k == s.receiver {
                    out.append(Quad(texture: solid(230, 200, 60), x: cx - 29, y: cy - 29, w: 58, h: 58))
                }
                if let l = ic.0 {
                    out.append(Quad(texture: uiTexture("shopicon|\(k)|\(l.name)|\(ic.1)", { l.bitmap }), x: cx - l.width / 2, y: cy - l.height / 2, w: l.width, h: l.height))
                }
                if !ic.1.isEmpty {
                    let w = ui.numberFont.measure(ic.1)
                    out.append(Quad(texture: uiTexture("dlgtext|\(ui.numberFont.size)|\(ic.1)|255", { ui.numberFont.render(ic.1, colour: (255, 255, 255)) }), x: cx + 26 - w, y: cy + 26 - ui.numberFont.size, w: w, h: ui.numberFont.size))
                }
            }
        }
        if s.receiver < s.receivers.count, let slot = d["Hero_Portrait"] {
            let h = s.receivers[s.receiver]
            if let p = ui.portrait(keyword: h.keyword, alignment: h.alignment, size: 82) {
                out.append(Quad(texture: uiTexture("portrait82|\(h.keyword)", { p.bitmap }), x: ox + slot.x + (slot.width - p.width) / 2, y: oy + slot.y + (slot.height - p.height) / 2, w: p.width, h: p.height))
            }
        }
        out += centred("\(g.resources["Gold", default: 0])", in: d["Kingdom_gold_text"], at: ox, oy, font: ui.numberFont)
        out += centred("\(shopTotal(s))", in: d["total_spent_text"], at: ox, oy, font: ui.numberFont)
        if let l = d["Close_button"], let b = ui.button("close") {
            out.append(Quad(texture: uiTexture("button|\(b.name)|close", { b.bitmap }), x: ox + l.x + (l.width - b.width) / 2, y: oy + l.y + (l.height - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }
    func shopTotal(_ s: ShopState) -> Int {
        guard let g = game else { return 0 }
        return s.rows.enumerated().reduce(0) { $0 + g.artifactCost($1.element.artifact) * s.counts[$1.offset] }
    }

    func shopClick(x: Float, y: Float) {
        guard var s = shop, let g = game, let d = ui?.dialog("Blacksmith.Layout") else { shop = nil; return }
        let (ox, oy) = shopOrigin
        let pic = d["Picture"]
        let px = ox + (pic?.x ?? 49), py = oy + (pic?.y ?? 42)
        if let panel = shopPanel(s) {
            for (k, r) in s.rows.enumerated() {
                if inside(shopLayer(panel, "L_Arrow_\(r.slot)"), at: px, py, x, y), s.counts[k] > 0 { s.counts[k] -= 1 }
                if inside(shopLayer(panel, "R_Arrow_\(r.slot)"), at: px, py, x, y) || inside(shopLayer(panel, r.slot), at: px, py, x, y), s.counts[k] < 9999 { s.counts[k] += 1 }
            }
        }
        if let box = d["Army_display_single"], inside(box, at: ox, oy, x, y) {
            let k = Int((x - Float(ox + box.x)) / Float(box.width / 7))
            if k < s.receivers.count { s.receiver = k }
        }
        if inside(d["Purchase_Button_Released"], at: ox, oy, x, y), s.receiver < s.receivers.count {
            let total = shopTotal(s)
            if total > 0, total <= g.resources["Gold", default: 0] {
                g.buy(s.rows.enumerated().map { ($0.element.artifact, s.counts[$0.offset]) }, for: s.receivers[s.receiver])
                s.counts = Array(repeating: 0, count: 12)
                sound?.play("dialogue.marketplace")
            }
        }
        if inside(d["Close_button"], at: ox, oy, x, y) { shop = nil; return }
        shop = s
    }
}
