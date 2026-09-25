import Foundation
import H4Engine

/// The marketplace (layers.dialog.Marketplace; heroes4.exe 0x6c3940): resources to sell on the
/// left with what the kingdom has, to buy on the right with the rate, the chosen pair in large,
/// the amount on a slider, Buy, Max and Close. A unit of A buys value[A] / (value[B] x k) of B in
/// whole lots (0x6c6280: values gold 1, wood and ore 125, the rest 250; k = 3 from the panel, 2 at
/// a Trading Post); buying gold gives floor(value[A] / k) per unit.
struct MarketState {
    var k: Int
    var sell: Int? = nil, buy: Int? = nil
    var lots = 0
}

extension Renderer {
    static let marketNames = ["Gold", "Wood", "Ore", "Crystal", "Sulfur", "Mercury", "Gems"]
    var marketOrigin: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 599) / 2) }

    /// (give of A, get of B) for one lot.
    static func marketRate(_ a: Int, _ b: Int, k: Int) -> (give: Int, get: Int)? {
        guard a != b else { return nil }
        let v = GameState.materialValue
        if b == 0 { return (1, max(0, v[a] / k)) }
        let num = v[a], den = v[b] * k
        func gcd(_ x: Int, _ y: Int) -> Int { y == 0 ? x : gcd(y, x % y) }
        let g = gcd(num, den)
        return (den / g, num / g)
    }
    func marketMaxLots(_ m: MarketState) -> Int {
        guard let a = m.sell, let b = m.buy, let r = Renderer.marketRate(a, b, k: m.k), r.give > 0, r.get > 0, let g = game else { return 0 }
        return (g.resources[Renderer.marketNames[a]] ?? 0) / r.give
    }

    func marketQuads() -> [Quad] {
        guard let m = market, let g = game, let ui = ui, let d = ui.dialog("Marketplace") else { return [] }
        let (ox, oy) = marketOrigin
        var out = dialogImages(d, key: "market", at: ox, oy, skip: ["Frame"])
        let strings = g.tables?.strings ?? [:]
        out += centred(strings["market_place.misc"] ?? "Marketplace", in: d["Title"], at: ox, oy, font: ui.dateFont)
        out += paragraph(strings["market_place_intro.misc"] ?? "", in: d["Text"], at: ox, oy, font: ui.numberFont)
        func icon(_ r: Int, in slot: String) {
            guard let s = d[slot], let l = materialIcon(Renderer.marketNames[r], size: 64) else { return }
            out.append(Quad(texture: uiTexture("mat64|\(Renderer.marketNames[r])", { l.bitmap }), x: ox + s.x + (s.width - l.width) / 2, y: oy + s.y + (s.height - l.height) / 2, w: l.width, h: l.height))
        }
        func frame(on slot: String) {
            guard let s = d[slot], let f = d["Frame"] else { return }
            out.append(Quad(texture: uiTexture("dlg|market|Frame", { f.bitmap }), x: ox + s.x + (s.width - f.width) / 2, y: oy + s.y + (s.height - f.height) / 2, w: f.width, h: f.height))
        }
        for (r, name) in Renderer.marketNames.enumerated() {
            icon(r, in: "\(name)_Icon"); icon(r, in: "\(name)_Icon_2")
            out += centred("\(g.resources[name] ?? 0)", in: d["Kingdom_\(name)"], at: ox, oy, font: ui.numberFont)
            // the rate for each resource to buy, for the one chosen to sell
            var rate = ""
            if let a = m.sell { if let q = Renderer.marketRate(a, r, k: m.k) { rate = r == 0 ? "\(q.get)" : "\(q.get) / \(q.give)" } else { rate = "n/a" } }
            out += centred(rate, in: d["\(name)_Exchange"] ?? d["\(name)_exchange"], at: ox, oy, font: ui.numberFont)
        }
        if let a = m.sell { frame(on: "\(Renderer.marketNames[a])_Icon"); icon(a, in: "Selling_Icon") }
        if let b = m.buy { frame(on: "\(Renderer.marketNames[b])_Icon_2"); icon(b, in: "Buying_Icon") }
        if let a = m.sell, let b = m.buy, let r = Renderer.marketRate(a, b, k: m.k) {
            out += centred("\(r.give * m.lots)", in: d["Qty_Selling"], at: ox, oy, font: ui.numberFont)
            out += centred("\(r.get * m.lots)", in: d["Exchange_Rate"], at: ox, oy, font: ui.numberFont)
        }
        // the slider: a track and a knob at the chosen share of the most one can sell
        if let bar = d["Scrollbar"] {
            out.append(Quad(texture: shade, x: ox + bar.x, y: oy + bar.y + bar.height / 2 - 3, w: bar.width, h: 6))
            let mx = marketMaxLots(m)
            let kx = mx > 0 ? bar.width * m.lots / mx : 0
            out.append(Quad(texture: solid(200, 160, 60), x: ox + bar.x + min(bar.width - 10, kx), y: oy + bar.y, w: 10, h: bar.height))
        }
        for (slot, name) in [("Sell_Button", "buy"), ("Close_Button", "close")] {
            guard let s = d[slot], let b = ui.button(name) else { continue }
            out.append(Quad(texture: uiTexture("button|\(name)|\(b.name)", { b.bitmap }), x: ox + s.x + (s.width - b.width) / 2, y: oy + s.y + (s.height - b.height) / 2, w: b.width, h: b.height))
        }
        out += centred("Max", in: d["Max_Button"], at: ox, oy, font: ui.dateFont)
        return out
    }

    func marketClick(x: Float, y: Float) {
        guard var m = market, let g = game, let d = ui?.dialog("Marketplace") else { market = nil; return }
        let (ox, oy) = marketOrigin
        for (r, name) in Renderer.marketNames.enumerated() {
            if inside(d["\(name)_Icon"], at: ox, oy, x, y) { m.sell = r; m.lots = 0 }
            if inside(d["\(name)_Icon_2"], at: ox, oy, x, y) { m.buy = r; m.lots = 0 }
        }
        if let bar = d["Scrollbar"], inside(bar, at: ox, oy, x, y) {
            m.lots = Int((Float(marketMaxLots(m)) * (x - Float(ox + bar.x)) / Float(bar.width)).rounded())
        }
        if inside(d["Max_Button"], at: ox, oy, x, y) { m.lots = marketMaxLots(m) }
        if inside(d["Sell_Button"], at: ox, oy, x, y), let a = m.sell, let b = m.buy, let r = Renderer.marketRate(a, b, k: m.k), m.lots > 0, r.get > 0 {
            g.resources[Renderer.marketNames[a], default: 0] -= r.give * m.lots
            g.resources[Renderer.marketNames[b], default: 0] += r.get * m.lots
            m.sell = nil; m.buy = nil; m.lots = 0
            sound?.play("miscellaneous.button")
        }
        if inside(d["Close_Button"], at: ox, oy, x, y) || x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 599) { market = nil; return }
        market = m
    }
}
