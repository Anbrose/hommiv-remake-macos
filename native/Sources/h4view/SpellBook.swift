import Foundation
import H4Engine

/// The spell book (t_spellbook_window 0x868980, layers.dialog.spell_book; object_dialogs_spec §1):
/// 13 exclusive tabs, each shown only when it has spells; on the index view the tab's banner
/// (icons.spells.type) with its box top-left at (120,52), Header_Background with the tab's title,
/// twelve cells a spread (level then name) -- Name_Background, Cost_Background, the school's frame
/// (Generic for artifacts) with the 52 px icon at +(7,6), the Spell Book hero text in Prose 12 and
/// "Cost N" (dark red when unaffordable), both black with the light halo, and the Information
/// button. The detail view shows two spells, one a page: the page overlay, the name, the frame and
/// icon at spell_Details, help + cost + hero text in Prose 20, the flavour in Script 18 20 px lower,
/// scroll arrows when it overflows, the 180 px silhouette, and the cast button (Disabled when the
/// points are short). The spell points: Prose 16, white with a black halo.
struct SpellBookState {
    var spells: [Int]            // the book's spells
    var castable: Set<Int>
    var points: Int
    var tab: String              // Damage, Curse, Blessings, Summoning, Combat, Adventure, All, Items, Life ...
    var page = 0
    var costs: [Int: Int] = [:]
    var items: Set<Int> = []     // spells the worn items give
    var detail: Int? = nil       // the detail view: the first of the two spells shown
    var powers: [Int: Int] = [:] // each spell's power for the caster (the hero text's %power)
    var scroll = [0, 0]          // the detail pages' description scroll, in lines
    init(spells: [Int], castable: Set<Int>, points: Int, combat: Bool, costs: [Int: Int] = [:], items: Set<Int> = []) {
        self.spells = spells; self.castable = castable; self.points = points; self.costs = costs; self.items = items
        tab = combat ? "Combat" : "Adventure"
    }
}

extension Renderer {
    static let bookTabs = ["Damage", "Curse", "Blessings", "Summoning", "Combat", "Adventure", "All", "Items", "Life", "Death", "Order", "Chaos", "Nature"]
    var bookOrigin: (Int, Int) { dialogOrigin800 }
    var bookLayout: LayerFile? { ui?.dialog("spell_book") }

    func bookSpells(_ sb: SpellBookState, tab: String? = nil) -> [Int] {
        let t = tab ?? sb.tab
        return sb.spells.filter { sp in
            let s = RuleTables.spells[sp]
            switch t {
            case "Damage": return s.has("Dmg")
            case "Curse": return s.has("Curse")
            case "Blessings": return s.has("Bless")
            case "Summoning": return s.has("Summ")
            case "Combat": return s.has("Cmb")
            case "Adventure": return s.has("Adv")
            case "Items": return sb.items.contains(sp)
            case "All": return true
            default: return s.school == t.lowercased()
            }
        }.sorted { a, b in
            let x = RuleTables.spells[a], y = RuleTables.spells[b]
            return x.level != y.level ? x.level < y.level : x.name < y.name
        }
    }
    /// A tab's layer, whatever the case of its state suffix.
    func bookLayer(_ d: LayerFile, _ name: String) -> UILayer? { dLayer(d, name) }
    /// The cell origins C of a spread: rows 1-3 on the left page, 4-6 on the right, two a row 164 apart.
    func bookCells(_ d: LayerFile) -> [(Int, Int)] {
        guard let a = d["spell_1_row_1"], let b2 = d["spell_2_row_1"] else { return [] }
        let dx = b2.x - a.x
        let rows: [(Int, Int)] = [(a.x, a.y)] + (2...6).map { r in dRect(d, "row_\(r)").map { ($0.x, $0.y) } ?? (a.x, a.y) }
        return rows.flatMap { [($0.0, $0.1), ($0.0 + dx, $0.1)] }
    }
    func bookCost(_ sb: SpellBookState, _ sp: Int) -> Int { sb.costs[sp] ?? RuleTables.spells[sp].cost }
    func bookAffordable(_ sb: SpellBookState, _ sp: Int) -> Bool { bookCost(sb, sp) <= sb.points }
    func spellIcon180(_ s: SpellDef) -> UILayer? {
        iconSheet("spells.\(s.school).180")[s.name.lowercased()] ?? iconSheet("spells.\(s.school).180")[s.keyword.lowercased()]
    }
    /// The tab's title (interface spellbook/<tab>; "%page" never occurs in them).
    func bookTitle(_ tab: String) -> String {
        if tab == "Combat" { return "Combat Spells" }
        return interfaceText("spellbook", tab == "Items" ? "item" : tab.lowercased())?.balloon ?? tab
    }
    /// A hero's power with a spell (Battle.power for a hero caster, spells_spec).
    func bookPower(_ spell: Int, caster c: Caster) -> Int {
        let s = RuleTables.spells[spell]
        var pct = 100 + 20 * (c.skills[["life": "spirit", "order": "mind", "death": "demonology", "chaos": "pyromancy", "nature": "meditation"][s.school] ?? ""] ?? 0) + (c.powerBonus[spell] ?? 0)
        if s.kind == "damage" || s.has("Dmg") { pct += 20 * (c.skills["sorcery"] ?? 0) }
        var p = s.base * pct / 100
        if s.increment != 0 { p = (s.base + s.increment * c.level) * pct / 100 }
        if spell == 53 || spell == 54 { p = (10 + c.level) * pct / 1000 }
        if s.kind == "summoning", let cr = game?.tables?.creature(s.creature), cr.gold > 0 { p = max(1, p / cr.gold) }
        return p
    }
    /// The "Spell Book Hero Text" line of a spell, formatted (0x73adf0).
    func bookHeroText(_ sb: SpellBookState, _ sp: Int) -> String {
        let s = RuleTables.spells[sp]
        var t = game?.tables?.spellBookText[s.keyword] ?? "%Spell_Name"
        let power = sb.powers[sp] ?? 0
        let creatures: String = {
            guard let c = game?.tables?.creature(s.creature) else { return "\(power)" }
            return "\(power) \(power == 1 ? c.name : c.plural)"
        }()
        for k in ["%capitalize_spell_name", "%Capitalize_spell_name", "%Spell_Name", "%Spell_name", "%spell_name"] { t = t.replacingOccurrences(of: k, with: s.name) }
        t = t.replacingOccurrences(of: "%power", with: "\(power)").replacingOccurrences(of: "%creatures", with: creatures)
        t = t.replacingOccurrences(of: "%lives", with: power == 1 ? "1 life" : "\(max(1, power)) lives")
        return t
    }
    func bookCostText(_ sb: SpellBookState, _ sp: Int) -> String { "\(text("cost.mage_guild", "Cost")) \(bookCost(sb, sp))" }
    /// Fill the powers of the adventure book's caster (the first hero), once.
    func bookPowers(_ sb: inout SpellBookState) {
        guard sb.powers.isEmpty, let g = game, let h = g.heroes.first else { return }
        let c = Caster(hero: h, spellPoints: sb.points)
        for sp in sb.spells { sb.powers[sp] = bookPower(sp, caster: c) }
    }

    /// The detail page k (0 left, 1 right): its offset from the left page.
    func bookPageOffset(_ k: Int) -> (Int, Int) { k == 0 ? (0, 0) : (334, 2) }
    /// The description of a detail page: the help lines (help, cost, hero text) and the flavour lines.
    func bookDetailText(_ sb: SpellBookState, _ sp: Int) -> (help: String, flavour: String) {
        let s = RuleTables.spells[sp]
        let help = (game?.tables?.spellHelp[s.keyword] ?? "") + "\n\n" + bookCostText(sb, sp) + "\n" + bookHeroText(sb, sp)
        return (help, game?.tables?.spellFlavor[s.keyword] ?? "")
    }
    /// Does a detail page's text overflow its 284 px box (the scroll arrows show)?
    func bookOverflow(_ sb: SpellBookState, _ sp: Int) -> (overflow: Bool, helpLines: Int) {
        guard let d = bookLayout, let r = dRect(d, "description_text"), let pf = dFont(20), let sf = scriptFont(18) else { return (false, 0) }
        let t = bookDetailText(sb, sp)
        let h = dLines(t.help, width: r.w, font: pf).count, f = t.flavour.isEmpty ? 0 : dLines(t.flavour, width: r.w, font: sf).count
        return (h * pf.lineHeight + f * sf.lineHeight + 20 > r.h, h)
    }

    func spellBookQuads() -> [Quad] {
        guard var sb = spellBook, let d = bookLayout else { return [] }
        if !inCombat { bookPowers(&sb); spellBook = sb }
        let (ox, oy) = bookOrigin
        var out: [Quad] = []
        func img(_ n: String, dx: Int = 0, dy: Int = 0) { out += dImage(d, "book", n, ox, oy, dx: dx, dy: dy) }
        let list = bookSpells(sb)
        let halo = Renderer.halo200
        img("Background")
        if let first = sb.detail {
            let pages = Array(list.dropFirst(first).prefix(2))
            // the page overlays and the names
            for (k, sp) in pages.enumerated() {
                img(k == 0 ? "Spell_Name_Background" : "Spell_Name_2_Background")
                out += dText(RuleTables.spells[sp].name, dRect(d, k == 0 ? "spell_name" : "spell_name_2"), font: dFont(18), centre: true, vcentre: true, halo: halo, ox, oy)
            }
            // the detail windows
            let frames = iconSheet("spellbook_frames")
            for (k, sp) in pages.enumerated() {
                let s = RuleTables.spells[sp], (dx, dy) = bookPageOffset(k)
                let origin = dRect(d, "spell_Details") ?? DRect(185, 123, 60, 60)
                let item = sb.tab == "Items"
                out += dImageAt(frames[item ? "generic" : s.school] ?? frames["generic"], "bookframe", x: ox + origin.x + dx, y: oy + origin.y + dy)
                if let icon = spellIcon(s.name) ?? spellIcon(s.keyword) {
                    out += dImageAt(icon, "spell52", x: ox + origin.x + 7 + dx, y: oy + origin.y + 6 + dy)
                }
                if let r = dRect(d, "description_text")?.offset(dx, dy), let pf = dFont(20), let sf = scriptFont(18) {
                    let t = bookDetailText(sb, sp)
                    let scroll = sb.scroll[k]
                    let lines = dLines(t.help, width: r.w, font: pf)
                    let visible = max(0, min(lines.count - scroll, r.h / pf.lineHeight))
                    out += dText(t.help, r, font: pf, centre: false, halo: halo, ox, oy, skipLines: scroll, clip: true)
                    if !t.flavour.isEmpty {
                        let fy = r.y + visible * pf.lineHeight + 20
                        if fy < r.y + r.h { out += dText(t.flavour, DRect(r.x, fy, r.w, r.y + r.h - fy), font: sf, centre: false, halo: halo, ox, oy, clip: true) }
                    }
                    if bookOverflow(sb, sp).overflow {
                        let arrows = dFile("control.button_scroll")
                        if let u = dRect(d, "spell_details_scroll_up")?.offset(dx, dy) { out += dImageOffset(dLayer(arrows, "UP_Released"), "bookscroll", x: ox + u.x, y: oy + u.y) }
                        if let dn = dRect(d, "spell_details_scroll_down")?.offset(dx, dy) { out += dImageOffset(dLayer(arrows, "Down_Released"), "bookscroll", x: ox + dn.x, y: oy + dn.y) }
                    }
                }
                if let sil = dRect(d, "icon_silhouette"), let ic = spellIcon180(s) {
                    out += dImageAlpha(ic, "spell180", x: ox + sil.x + dx, y: oy + sil.y + dy, alpha: 4)   // 0x59ee20(..., 1, 4)
                }
                if let c = dRect(d, "cast_spell_detail") {
                    out += dButton("spellbook.cast_spell", bookAffordable(sb, sp) && sb.castable.contains(sp) ? "Released" : "Disabled", x: ox + c.x + dx, y: oy + c.y + dy)
                }
            }
        } else {
            // the index view: header, cells, banner
            img("Header_Background")
            out += dText(bookTitle(sb.tab), dRect(d, "header"), font: dFont(18), centre: true, vcentre: true, halo: halo, ox, oy)
            let frames = iconSheet("spellbook_frames")
            let cells = bookCells(d)
            for (k, sp) in list.dropFirst(sb.page * 12).prefix(12).enumerated() where k < cells.count {
                let s = RuleTables.spells[sp]
                let (cx, cy) = cells[k]
                let dx = cx - 74, dy = cy - 142
                img("Name_Background", dx: dx, dy: dy)
                img("Cost_Background", dx: dx, dy: dy)
                let item = sb.tab == "Items"
                out += dImageAt(frames[item ? "generic" : s.school] ?? frames["generic"], "bookframe", x: ox + cx, y: oy + cy)
                if let icon = spellIcon(s.name) ?? spellIcon(s.keyword) {
                    out += dImageAt(icon, "spell52", x: ox + cx + 7, y: oy + cy + 6)
                }
                out += dText(bookHeroText(sb, sp), DRect(cx + 4, cy + 70, 132, 51), font: dFont(12), centre: true, vcentre: true, halo: halo, ox, oy)
                out += dText(bookCostText(sb, sp), DRect(cx + 71, cy + 34, 56, 26), font: dFont(13), centre: true, vcentre: true, halo: halo,
                             colour: bookAffordable(sb, sp) ? (0, 0, 0) : (170, 0, 0), ox, oy)
                img("Information_Released", dx: dx, dy: dy)
            }
            if let banner = iconSheet("spells.type")[sb.tab.lowercased()], let hb = dRect(d, "header_icon") {
                out += dImageAt(banner, "booktype", x: ox + hb.x, y: oy + hb.y + 5)
            }
        }
        for n in ["Top", "Left", "Bottom", "Right"] { img(n) }
        // the tabs that have spells; the chosen one pressed
        for t in Renderer.bookTabs where !bookSpells(sb, tab: t).isEmpty {
            img("\(t)_\(sb.tab == t ? "Pressed" : "Released")")
        }
        img("Done_Released")
        let first = sb.detail ?? sb.page * 12
        if first > 0 { img("Back_Released") }
        if first + (sb.detail != nil ? 2 : 12) < list.count { img("Forward_Released") }
        if sb.detail != nil, let ib = dRect(d, "index_button") { out += dButton("spellbook.index", "Released", x: ox + ib.x, y: oy + ib.y) }
        img("Points_Frame")
        out += dText("\(sb.points)", dRect(d, "points"), font: dFont(16), centre: true, vcentre: true, halo: (0, 0, 0), colour: (255, 255, 255), ox, oy)
        return out
    }

    /// What is under the pointer: ("cell", i), ("info", i), ("cast", k), ("tab", t), ("done"), ...
    enum BookHit { case cell(Int), info(Int), cast(Int), tab(String), done, back, forward, index, points, scrollUp(Int), scrollDown(Int), none }
    func bookHit(_ sb: SpellBookState, x: Float, y: Float) -> BookHit {
        guard let d = bookLayout else { return .none }
        let (ox, oy) = bookOrigin
        let lx = x - Float(ox), ly = y - Float(oy)
        func hit(_ n: String, _ dx: Int = 0, _ dy: Int = 0) -> Bool { dRect(d, n)?.offset(dx, dy).contains(lx, ly) ?? false }
        let list = bookSpells(sb)
        if let first = sb.detail {
            for k in 0..<2 where first + k < list.count {
                let (dx, dy) = bookPageOffset(k)
                if let c = dRect(d, "cast_spell_detail") {
                    let (w, h) = dButtonSize("spellbook.cast_spell")
                    if DRect(c.x + dx, c.y + dy, w, h).contains(lx, ly) { return .cast(k) }
                }
                if bookOverflow(sb, list[first + k]).overflow {
                    if hit("spell_details_scroll_up", dx, dy) { return .scrollUp(k) }
                    if hit("spell_details_scroll_down", dx, dy) { return .scrollDown(k) }
                }
            }
            if let ib = dRect(d, "index_button") {
                let (w, h) = dButtonSize("spellbook.index")
                if DRect(ib.x, ib.y, w, h).contains(lx, ly) { return .index }
            }
        } else {
            for (k, (cx, cy)) in bookCells(d).enumerated() where sb.page * 12 + k < list.count {
                let i = sb.page * 12 + k
                if hit("Information_Released", cx - 74, cy - 142) { return .info(i) }
                if DRect(cx, cy, 67, 64).contains(lx, ly) { return .cell(i) }
            }
        }
        for t in Renderer.bookTabs where !bookSpells(sb, tab: t).isEmpty && (hit("\(t)_Released") || hit("\(t)_Pressed")) { return .tab(t) }
        if hit("Done_Released") { return .done }
        let first = sb.detail ?? sb.page * 12
        if first > 0, hit("Back_Released") { return .back }
        if first + (sb.detail != nil ? 2 : 12) < list.count, hit("Forward_Released") { return .forward }
        if hit("Points_Frame") { return .points }
        return .none
    }

    func spellBookClick(x: Float, y: Float) {
        guard var sb = spellBook else { spellBook = nil; return }
        let (ox, oy) = bookOrigin
        if x < Float(ox) || x >= Float(ox + 800) || y < Float(oy) || y >= Float(oy + 600) { spellBook = nil; return }
        let list = bookSpells(sb)
        switch bookHit(sb, x: x, y: y) {
        case .done: spellBook = nil; sound?.play("miscellaneous.button"); return
        case .tab(let t): bookSelectTab(&sb, t)
        case .back:
            if let first = sb.detail { sb.detail = max(0, first - 2); sb.scroll = [0, 0] } else { sb.page = max(0, sb.page - 1) }
        case .forward:
            if let first = sb.detail { sb.detail = first + 2; sb.scroll = [0, 0] } else { sb.page += 1 }
        case .index: if let first = sb.detail { sb.page = first / 12; sb.detail = nil }
        case .info(let i): sb.detail = i - i % 2; sb.scroll = [0, 0]
        case .cell(let i):
            if sb.castable.contains(list[i]), bookAffordable(sb, list[i]) { spellBook = nil; castPicked(list[i]); return }
        case .cast(let k):
            if let first = sb.detail, first + k < list.count, sb.castable.contains(list[first + k]), bookAffordable(sb, list[first + k]) {
                spellBook = nil; castPicked(list[first + k]); return
            }
        case .scrollUp(let k): sb.scroll[k] = max(0, sb.scroll[k] - 1)
        case .scrollDown(let k):
            if let first = sb.detail { sb.scroll[k] = min(max(0, bookOverflow(sb, list[first + k]).helpLines - 1), sb.scroll[k] + 1) }
        case .points, .none: break
        }
        spellBook = sb
    }
    func bookSelectTab(_ sb: inout SpellBookState, _ t: String) {
        sb.tab = t; sb.page = 0; sb.detail = nil; sb.scroll = [0, 0]
    }
    /// The book's hot keys: Enter closes, the arrows page, Page Up / Page Down step through the tabs.
    func spellBookKey(_ code: UInt16) -> Bool {
        guard var sb = spellBook else { return false }
        let list = bookSpells(sb)
        let tabs = Renderer.bookTabs.filter { !bookSpells(sb, tab: $0).isEmpty }
        switch code {
        case 36, 76, 53: spellBook = nil; return true
        case 123:
            if let first = sb.detail { if first > 0 { sb.detail = max(0, first - 2); sb.scroll = [0, 0] } } else if sb.page > 0 { sb.page -= 1 }
        case 124:
            if let first = sb.detail { if first + 2 < list.count { sb.detail = first + 2; sb.scroll = [0, 0] } } else if (sb.page + 1) * 12 < list.count { sb.page += 1 }
        case 116, 121:
            if let i = tabs.firstIndex(of: sb.tab), !tabs.isEmpty { bookSelectTab(&sb, tabs[(i + (code == 121 ? 1 : tabs.count - 1)) % tabs.count]) }
        default: return false
        }
        spellBook = sb
        return true
    }
    func spellBookTip(x: Float, y: Float) -> String? {
        guard let sb = spellBook else { return nil }
        let list = bookSpells(sb)
        func b(_ item: String) -> String? { interfaceText("spellbook", item)?.balloon }
        func cast(_ sp: Int) -> String { (b("cast_spell") ?? "Cast %spell_name").replacingOccurrences(of: "%spell_name", with: RuleTables.spells[sp].name) }
        switch bookHit(sb, x: x, y: y) {
        case .cell(let i): return cast(list[i])
        case .cast(let k): return sb.detail.map { cast(list[$0 + k]) }
        case .info: return b("information")
        case .tab(let t): return b("\(t.lowercased())_button")
        case .done: return b("close_button")
        case .back: return b("last_spell_button")
        case .forward: return b("next_spell_button")
        case .index: return b("index_button")
        case .points: return b("spell_points")
        default: return nil
        }
    }

    // MARK: casting in battle

    /// The combat panel's cast button: the book of the unit whose turn it is.
    func openCombatBook() {
        guard let cs = combat, let b = cs.battle, let u = b.current, let c = u.caster else { return }
        let all = Set(c.spells).union(c.free)
        var sb = SpellBookState(spells: Array(all), castable: Set(b.castable(u)), points: c.spellPoints, combat: true,
                                costs: Dictionary(all.map { ($0, c.cost($0)) }, uniquingKeysWith: { a, _ in a }), items: c.free)
        for sp in all { sb.powers[sp] = b.power(sp, by: u, creatures: game?.tables) }
        spellBook = sb
    }
    /// A spell picked from the book: cast now if it needs no target, else aim it.
    func castPicked(_ spell: Int) {
        guard let cs = combat, let b = cs.battle else {
            castAdventure(spell); return
        }
        if Battle.untargeted(spell) { b.cast(spell, on: nil, tables: game?.tables); cs.pump() }
        else { casting = spell }
    }
    /// Adventure-map casting (heroes' map spells).
    func castAdventure(_ spell: Int) {
        guard let g = game, let h = g.heroes.first else { return }
        g.castAdventureSpell(spell, by: h)
    }
}
