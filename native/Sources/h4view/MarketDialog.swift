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

    /// The dialog (0x6c3940 / 0x6c3b40, town_screens_spec §4.3) in its children's order: the two selection
    /// frames (at the picked icon + (-18,-15)), the sell and buy icons (at the hotspot's top-left plus the
    /// material layer's own box), OK / Buy / Max, the slider, then the texts -- black, no halo: title and
    /// intro Prose 20 centred, kingdom amounts and rates 16, the quantities 18.
    func marketQuads() -> [Quad] {
        guard let m = market, let g = game, let ui = ui, let d = ui.dialog("Marketplace") else { return [] }
        let (ox, oy) = marketOrigin
        var out = dImage(d, "market", "Background", ox, oy)
        func icon(_ r: Int, at slot: String) -> [Quad] {
            guard let s = d[slot] else { return [] }
            return dImageOffset(materialIcon(Renderer.marketNames[r], size: 64), "mat64", x: ox + s.x, y: oy + s.y)
        }
        if let a = m.sell, let s = d["\(Renderer.marketNames[a])_Icon"] { out += dImageAt(d["Frame"], "market", x: ox + s.x - 18, y: oy + s.y - 15) }
        if let b = m.buy, let s = d["\(Renderer.marketNames[b])_Icon_2"] { out += dImageAt(d["Frame"], "market", x: ox + s.x - 18, y: oy + s.y - 15) }
        for (r, name) in Renderer.marketNames.enumerated() { out += icon(r, at: "\(name)_Icon"); out += icon(r, at: "\(name)_Icon_2") }
        let mx = marketMaxLots(m)
        out += townButton("ok", x: ox + 694, y: oy + 541)
        out += townButton("buy", x: ox + 474, y: oy + 541, disabled: m.lots <= 0)
        out += townButton("max", x: ox + 253, y: oy + 541, disabled: mx <= 0)
        if let kit = kit, let bar = d["Scrollbar"] {
            out += quads(kit.hScrollbar(UIRect(ox + bar.x, oy + bar.y, bar.width, bar.height), value: mx > 0 ? Float(m.lots) / Float(mx) : 0))
        }
        let strings = g.tables?.strings ?? [:]
        let f20 = ui.font(20), f16 = ui.font(16), f18 = ui.font(18)
        out += dText(strings["market_place.misc"] ?? "Marketplace", rect(d["Title"], ox, oy), font: f20, centre: true, 0, 0)
        out += dText(strings["market_place_intro.misc"] ?? "", rect(d["Text"], ox, oy), font: f20, centre: true, 0, 0)
        for name in Renderer.marketNames {
            guard let r = rect(d["Kingdom_\(name)"], ox, oy) else { continue }
            out += dText(Renderer.materialText(g.resources[name] ?? 0, font: f16, width: r.w), r, font: f16, centre: true, 0, 0)
        }
        for (r, name) in Renderer.marketNames.enumerated() {
            // the rate of each resource to buy, for the one chosen to sell (0x6c6280)
            guard let a = m.sell else { break }
            let rate = Renderer.marketRate(a, r, k: m.k).map { r == 0 ? "\($0.get)" : "\($0.get) / \($0.give)" } ?? (strings["not_applicable.misc"] ?? "n/a")
            out += dText(rate, rect(dLayer(d, "\(name)_exchange"), ox, oy), font: f16, centre: true, 0, 0)
        }
        if let a = m.sell { out += icon(a, at: "Selling_Icon") }
        if let b = m.buy { out += icon(b, at: "Buying_Icon") }
        if let a = m.sell, let b = m.buy, let r = Renderer.marketRate(a, b, k: m.k) {
            out += dText("\(r.give * m.lots)", rect(d["Qty_Selling"], ox, oy), font: f18, centre: true, 0, 0)
            out += dText("\(r.get * m.lots)", rect(d["Exchange_Rate"], ox, oy), font: f18, centre: true, 0, 0)
        }
        return out
    }

    func marketClick(x: Float, y: Float) {
        guard var m = market, let g = game, let d = ui?.dialog("Marketplace") else { market = nil; return }
        let (ox, oy) = marketOrigin
        for (r, name) in Renderer.marketNames.enumerated() {
            if inside(d["\(name)_Icon"], at: ox, oy, x, y) { m.sell = r; m.lots = 0 }
            if inside(d["\(name)_Icon_2"], at: ox, oy, x, y) { m.buy = r; m.lots = 0 }
        }
        if let bar = d["Scrollbar"], inside(bar, at: ox, oy, x, y), let kit = kit {
            let r = UIRect(ox + bar.x, oy + bar.y, bar.width, bar.height), f = kit.file("control.horizontal_scroll")
            let lw = MenuKit.find(f, "Up_Released")?.width ?? 52, rw = MenuKit.find(f, "Down_Released")?.width ?? 56
            if x < Float(r.x + lw) { m.lots -= 1 } else if x >= Float(r.x + r.w - rw) { m.lots += 1 }
            else { m.lots = Int((kit.hScrollbarValue(r, x) * Float(marketMaxLots(m))).rounded()) }
            m.lots = max(0, min(marketMaxLots(m), m.lots))
        }
        if townButtonHit("max", x: ox + 253, y: oy + 541, x, y) { m.lots = marketMaxLots(m) }
        if townButtonHit("buy", x: ox + 474, y: oy + 541, x, y), let a = m.sell, let b = m.buy, let r = Renderer.marketRate(a, b, k: m.k), m.lots > 0, r.get > 0 {
            g.resources[Renderer.marketNames[a], default: 0] -= r.give * m.lots
            g.resources[Renderer.marketNames[b], default: 0] += r.get * m.lots
            m.sell = nil; m.buy = nil; m.lots = 0
            sound?.play("miscellaneous.button")
        }
        if townButtonHit("ok", x: ox + 694, y: oy + 541, x, y) { market = nil; return }
        market = m
    }
}
