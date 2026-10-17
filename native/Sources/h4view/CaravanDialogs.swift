import Foundation
import AppKit
import H4Engine

/// The caravan dialogs (re/caravans_dialogs_create_spec.md, re/caravans_dialogs_view_spec.md):
/// the caravan building's first dialog (t_dialog_caravan_initial), Create Caravan
/// (t_dialog_caravan_creation), View Caravans (t_dialog_caravan_view) and Manage Arrived Caravans
/// (t_dialog_caravan_arrivals). Every text is Prose Antique, black, no halo, centred, top-aligned
/// unless noted.
enum CaravanUI {
    case initial(town: Int)
    case create(CaravanCreate)
    case view(CaravanView)
    case arrivals(CaravanArrivals)
    /// The dwelling's recruit dialog over Create Caravan (Buy, 0x68c8d0 -> 0x43dee0).
    case buy(CaravanCreate, dwelling: Int, count: Int)
}

/// Create Caravan's working state: the mode, the lists and their routes, and the rows of the town
/// entry shown (working copies, put back into the world when sending or leaving the entry).
final class CaravanCreate {
    let town: Int, player: Int
    /// 0 "To <town>" (pick an origin, this town is the destination), 1 "From <town>" (pick a destination).
    var mode = 0
    var origins: [CaravanSource] = [], destinations: [Int] = []
    var routes: [[CaravanRoute]] = [[], []]
    var selected = [0, 0], top = [0, 0]
    /// The origin town whose rows are shown (nil for a dwelling entry).
    var origin: Int?
    /// Rows: 0 the origin's garrison, 1 its visiting army (or the new empty army next to it), 2 the caravan.
    var rows: [[ArmySlot?]] = [[], [], []]
    var visitor: Hero?
    /// The visiting row is a new army that is placed next to the town only if it gets troops (0x51fa90).
    var temp = false
    var picked: (row: Int, k: Int)?
    var split = false
    init(town: Int, player: Int) { self.town = town; self.player = player }
    var list: [CaravanSource] { mode == 0 ? origins : destinations.map { .town($0) } }
    var entry: CaravanSource? { let l = list; return selected[mode] < l.count ? l[selected[mode]] : nil }
    var route: CaravanRoute? { selected[mode] < routes[mode].count ? routes[mode][selected[mode]] : nil }
    var reachable: Bool { route?.days != nil }
    var caravanEmpty: Bool { !rows[2].contains { $0 != nil } }
    static func emptyRow() -> [ArmySlot?] { [ArmySlot?](repeating: nil, count: GameState.rowSlots) }
}

final class CaravanView {
    let town: Int?
    var list: [Caravan]
    var top = 0
    var selected: (row: Int, k: Int)?
    init(town: Int?, list: [Caravan]) { self.town = town; self.list = list }
}

final class CaravanArrivals {
    let town: Int
    var list: [Caravan]
    var top = 0
    var picked: (row: Int, k: Int)?
    init(town: Int, list: [Caravan]) { self.town = town; self.list = list }
}

extension Renderer {
    var caravanPlayer: Int { game?.actingColour ?? 0 }

    // MARK: entry points

    /// The caravan building is clicked (0x8bc390): without the building a message, else always
    /// the first dialog.
    func openCaravanBuilding(_ town: Int) {
        guard let g = game else { return }
        if !g.hasCaravan(town) { prompt = (text("caravan.no_caravan_building", "There are no caravan stations in this town."), false, nil); return }
        caravanUI = .initial(town: town)
    }
    /// Create Caravan (0x8bc680): the preconditions' message, or the dialog.
    func openCaravanCreate(_ town: Int) {
        guard let g = game else { return }
        let p = caravanPlayer
        if let r = g.caravanCreateRefusal(town: town, player: p) { prompt = (r, false, nil); caravanUI = nil; return }
        let c = CaravanCreate(town: town, player: p)
        let l = g.caravanLists(town: town, player: p)
        c.origins = l.origins; c.destinations = l.destinations
        c.routes[0] = c.origins.map { g.caravanRoute(from: $0, to: town, owner: p) }
        c.routes[1] = c.destinations.map { g.caravanRoute(from: .town(town), to: $0, owner: p) }
        c.mode = c.origins.isEmpty ? 1 : 0
        caravanUI = .create(c)
        caravanLoadEntry(c)
    }
    /// View Caravans, globally (nil) or for a town (0x6962a0); with none a plain message.
    func openCaravanView(_ town: Int?) {
        guard let g = game else { return }
        let list = g.viewedCaravans(town: town, player: caravanPlayer)
        if list.isEmpty {
            caravanUI = nil
            prompt = (town.map { GameState.substitute(text("caravan_view.no_caravans_town", "There are no caravans headed for %town."), ["%town": g.towns[$0].name]) }
                      ?? text("caravan_view.no_caravans_global", "You have no active caravans."), false, nil)
            return
        }
        let v = CaravanView(town: town, list: list)
        v.selected = caravanFirstSelection(list)
        caravanUI = .view(v)
    }
    /// Manage Arrived Caravans (0x682e10); with none a plain message.
    func openCaravanArrivals(_ town: Int) {
        guard let g = game else { return }
        let list = g.waitingCaravans(town: town, owner: caravanPlayer)
        if list.isEmpty {
            caravanUI = nil
            prompt = (GameState.substitute(text("caravan_arrivals.no_arrivals", "There are no caravans outside %town waiting for you to manage them."), ["%town": g.towns[town].name]), false, nil)
            return
        }
        caravanUI = .arrivals(CaravanArrivals(town: town, list: list))
    }
    /// Setting the rings' arrays selects the first filled place of each; the last row set wins (0x64fb00).
    func caravanFirstSelection(_ list: [Caravan]) -> (row: Int, k: Int)? {
        var sel: (Int, Int)? = nil
        for r in 0..<min(3, list.count) { if let k = list[r].slots.firstIndex(where: { $0 != nil }) { sel = (r, k) } }
        return sel
    }

    // MARK: shared drawing

    var caravanInitialOrigin: (Int, Int) { ((AdventureUI.width - 554) / 2, (AdventureUI.height - 373) / 2) }

    /// A button made of a layout's <prefix>_Released/_Highlighted/_Pressed/_Disabled layers at their own boxes (0x5a2250).
    func caravanPrefixButton(_ d: LayerFile?, _ tag: String, _ prefix: String, _ ox: Int, _ oy: Int, disabled: Bool = false, pressed: Bool = false) -> [Quad] {
        guard let r = dRect(d, "\(prefix)_Released") ?? dRect(d, "\(prefix)_released") else { return [] }
        let over = r.offset(ox, oy).contains(pointerCanvas.0, pointerCanvas.1)
        let names = disabled ? ["Disabled", "Released"] : pressed ? ["Pressed", "Released"] : over ? ["Highlighted", "Released"] : ["Released"]
        for n in names { if dLayer(d, "\(prefix)_\(n)") != nil { return dImage(d, tag, "\(prefix)_\(n)", ox, oy) } }
        return []
    }
    func caravanPrefixHit(_ d: LayerFile?, _ prefix: String, _ ox: Int, _ oy: Int, _ x: Float, _ y: Float) -> Bool {
        (dRect(d, "\(prefix)_Released") ?? dRect(d, "\(prefix)_released"))?.offset(ox, oy).contains(x, y) ?? false
    }
    /// A ring row's place under a point (a place is the 66 x 66 around the ring's centre).
    func caravanRing(_ slots: [(piece: String, fx: Int, fy: Int)], _ x: Float, _ y: Float) -> Int? {
        slots.indices.first { abs(x - Float(slots[$0].fx + 41)) < 33 && abs(y - Float(slots[$0].fy + 41)) < 33 }
    }
    /// A t_creature_array_window row: portraits, pieces (the selected one highlighted), labels.
    func caravanRowQuads(_ slots: [(piece: String, fx: Int, fy: Int)], _ row: [ArmySlot?], selected: Int?, lifted: Int? = nil) -> [Quad] {
        guard let ui = ui else { return [] }
        var items: [(icon: UILayer?, count: String?, hero: Bool)] = []
        for (k, s) in row.enumerated() {
            guard let s = s, k != lifted else { items.append((nil, nil, false)); continue }
            let (icon, count) = slotIcon(s, ui: ui)
            items.append((icon, count, s.hero != nil))
        }
        var out: [Quad] = []
        for (k, s) in slots.enumerated() {
            let cx = s.fx + 41, cy = s.fy + 41
            if k < items.count, let icon = items[k].icon {
                out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height))
            }
            if let p = ui.creatureRing(k == selected ? s.piece + "_Highlight" : s.piece) ?? ui.creatureRing(s.piece) {
                out.append(Quad(texture: uiTexture("cring|\(p.name)", { p.bitmap }), x: s.fx + p.x, y: s.fy + p.y, w: p.width, h: p.height))
            }
            if k < items.count, items[k].icon != nil { ringLabel(&out, ui: ui, cx: cx, cy: cy, count: items[k].count, hero: items[k].hero) }
        }
        return out
    }
    /// The lifted place under the pointer while dragging.
    func caravanLiftedQuads(_ s: ArmySlot?) -> [Quad] {
        guard let ui = ui, let s = s, let at = caravanDragAt else { return [] }
        let (icon, count) = slotIcon(s, ui: ui)
        var out: [Quad] = []
        if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: Int(at.0) - icon.width / 2, y: Int(at.1) - icon.height / 2, w: icon.width, h: icon.height)) }
        ringLabel(&out, ui: ui, cx: Int(at.0), cy: Int(at.1), count: count, hero: s.hero != nil)
        return out
    }
    /// A piece of the minimap around a cell (the location pictures' map, 0x79bdd0).
    func caravanMiniMap(cellX: Int, cellY: Int, x: Int, y: Int, w: Int, h: Int) -> [Quad] {
        guard let g = game, let ui = ui else { return [] }
        let hs = ui.hotspot("mini_map")?.width ?? 200
        let tex = uiTexture("cvmap|\(cellX),\(cellY)|\(minimapStamp)|\(w)x\(h)", {
            let full = AdventureUI.minimap(game: g, size: hs)
            let sz = Float(g.map.size)
            let px = Int((Float(cellY - cellX) + sz / 2) / sz * Float(hs)), py = Int((Float(cellX + cellY + 6) - sz / 2) / sz * Float(hs))
            return Renderer.crop(full, x: px - w / 2, y: py - h / 2, w: w, h: h)
        })
        return [Quad(texture: tex, x: x, y: y, w: w, h: h)]
    }
    /// A location's picture (0x44c460 / 0x44c250): a town as layers.town.<alignment>.caravan's
    /// terrain under its walls with the three bars; a dwelling as its creature's image there.
    func caravanPicture(_ s: CaravanSource, x: Int, y: Int) -> [Quad] {
        guard let g = game else { return [] }
        switch s {
        case .town(let i):
            let t = g.towns[i]
            guard let f = dFile("town.\(t.alignment).Caravan") else { return [] }
            var out: [Quad] = []
            let terrain = TownScreen.terrainNames[t.terrain] ?? "grass"
            out += dImageOffset(dLayer(f, terrain) ?? dLayer(f, "grass"), "cvpic.\(t.alignment)", x: x, y: y)
            let walls = t.buildings.contains("castle") ? "Castle" : t.buildings.contains("citadel") ? "Citadel" : t.buildings.contains("fort") ? "Fort" : "Village"
            out += dImageOffset(dLayer(f, walls), "cvpic.\(t.alignment)", x: x, y: y)
            let waiting = t.available.values.reduce(0, +)
            let guild = (1...5).filter { t.buildings.contains("mage guild \($0)") }.count
            let built = g.tables.map { tb in Float(t.buildings.count) / Float(max(1, tb.buildings(for: t.alignment).count)) } ?? 0
            for (slot, frac, rgb) in [("creatures", min(1, Float(waiting) / 60), (40, 200, 40)), ("magic", Float(guild) / 5, (40, 80, 220)), ("misc", built, (220, 40, 40))] as [(String, Float, (UInt8, UInt8, UInt8))] {
                guard let hs = dLayer(f, slot) else { continue }
                out.append(Quad(texture: solid(20, 20, 20), x: x + hs.x, y: y + hs.y, w: hs.width, h: hs.height))
                let w = Int(Float(hs.width) * max(0, min(1, frac)))
                if w > 0 { out.append(Quad(texture: solid(rgb.0, rgb.1, rgb.2), x: x + hs.x, y: y + hs.y, w: w, h: hs.height)) }
            }
            return out
        case .dwelling(let i):
            guard let c = g.tables?.creature(g.dwellings[i].creature), let f = dFile("town.\(c.alignment.lowercased()).Caravan") else { return [] }
            return dImageOffset(dLayer(f, c.name) ?? dLayer(f, c.keyword), "cvpic.\(c.alignment)", x: x, y: y)
        }
    }
    func caravanCell(_ s: CaravanSource) -> (Int, Int) {
        guard let g = game else { return (0, 0) }
        switch s {
        case .town(let i): return (g.towns[i].x, g.towns[i].y)
        case .dwelling(let i): return (g.dwellings[i].x, g.dwellings[i].y)
        }
    }

    func caravanQuads() -> [Quad] {
        guard let c = caravanUI else { return [] }
        switch c {
        case .initial(let t): return caravanInitialQuads(t)
        case .create(let s): return caravanCreateQuads(s)
        case .view(let v): return caravanViewQuads(v)
        case .arrivals(let a): return caravanArrivalsQuads(a)
        case .buy(let s, let d, let n):
            guard let g = game, let cr = g.tables?.creature(g.dwellings[d].creature) else { return caravanCreateQuads(s) }
            let cost = g.recruitCost(cr, discount: 0)
            return caravanCreateQuads(s) + recruitDialogQuads(cr, available: g.dwellings[d].available, count: n, cost: cost, most: g.recruitMost(available: g.dwellings[d].available, cost: cost))
        }
    }

    // MARK: t_dialog_caravan_initial (layers.dialog.caravan_initial, 554 x 373)

    func caravanInitialQuads(_ t: Int) -> [Quad] {
        guard let d = dFile("dialog.caravan_initial") else { return [] }
        let (ox, oy) = caravanInitialOrigin
        var out = dImage(d, "cvi", "Background", ox, oy)
        out += dText(text("caravan_initial.title", "Caravans"), dRect(d, "title"), font: dFont(20), ox, oy)
        out += dText(text("caravan_initial.text", ""), dRect(d, "text"), font: dFont(18), ox, oy)
        for p in ["Create", "View", "Arrived"] { out += caravanPrefixButton(d, "cvi", p, ox, oy) }
        out += dText(text("caravan_initial.create_text", "Create"), dRect(d, "create_text"), font: dFont(18), ox, oy)
        out += dText(text("caravan_initial.view_text", "View"), dRect(d, "view_text"), font: dFont(18), ox, oy)
        out += dText(text("caravan_initial.arrived_text", "Manage Arrivals"), dRect(d, "arrived_text"), font: dFont(18), ox, oy)
        if let r = dRect(d, "close_button") { out += townButton("close", x: ox + r.x, y: oy + r.y) }
        return out
    }
    func caravanInitialClick(_ t: Int, _ x: Float, _ y: Float) {
        guard let d = dFile("dialog.caravan_initial") else { caravanUI = nil; return }
        let (ox, oy) = caravanInitialOrigin
        if caravanPrefixHit(d, "Create", ox, oy, x, y) { caravanUI = nil; openCaravanCreate(t); return }
        if caravanPrefixHit(d, "View", ox, oy, x, y) { caravanUI = nil; openCaravanView(t); return }
        if caravanPrefixHit(d, "Arrived", ox, oy, x, y) { caravanUI = nil; openCaravanArrivals(t); return }
        if let r = dRect(d, "close_button"), townButtonHit("close", x: ox + r.x, y: oy + r.y, x, y) { caravanUI = nil }
    }

    // MARK: t_dialog_caravan_creation (layers.dialog.caravan_create, 800 x 600)

    /// Show the selected entry (0x68f1f0 for a town, the buy block for a dwelling): a town's rows
    /// are its garrison and the army visiting it -- or a new empty army next to it while the player
    /// has fewer than 8 armies.
    func caravanLoadEntry(_ c: CaravanCreate) {
        guard let g = game else { return }
        c.picked = nil; c.split = false
        c.rows = [CaravanCreate.emptyRow(), CaravanCreate.emptyRow(), c.rows[2].count == GameState.rowSlots ? c.rows[2] : CaravanCreate.emptyRow()]
        c.origin = nil; c.visitor = nil; c.temp = false
        let o: Int
        if c.mode == 1 { o = c.town } else if case .town(let t)? = c.entry { o = t } else { return }
        c.origin = o
        c.rows[0] = g.garrisonSlots(o)
        if let v = g.visitingArmy(town: o), v.owner == c.player { c.visitor = v; c.rows[1] = g.armySlots(v) }
        else if g.heroes.count < GameState.maxArmies { c.temp = true }
    }
    /// Does the origin show two rows (garrison and visiting army)? Else one: the garrison of the
    /// player's town, or the army visiting an ally's.
    func caravanDouble(_ c: CaravanCreate) -> Bool {
        guard let g = game, let o = c.origin else { return false }
        return (c.visitor != nil || c.temp) && g.towns[o].owner == c.player
    }
    /// The single row's index (0 garrison of the player's town, 1 the visiting army in an ally's).
    func caravanSingleRow(_ c: CaravanCreate) -> Int {
        guard let g = game, let o = c.origin else { return 0 }
        return g.towns[o].owner == c.player ? 0 : 1
    }
    /// Put the garrison and the visiting army back into the world.
    func caravanApplyRows(_ c: CaravanCreate) {
        guard let g = game, let o = c.origin else { return }
        if g.towns[o].owner == c.player { g.setGarrison(o, c.rows[0]) }
        if let v = c.visitor {
            let lead = g.setArmy(v, c.rows[1])
            c.visitor = lead
            if lead == nil { c.temp = g.heroes.count < GameState.maxArmies }
        }
    }
    /// Leave the entry (0x68eb80): the rows back, the new army placed if it got troops.
    func caravanFinishEntry(_ c: CaravanCreate) {
        guard let g = game, let o = c.origin else { return }
        caravanApplyRows(c)
        if c.visitor == nil, c.temp, c.rows[1].contains(where: { $0 != nil }) { g.leaveTown(o, spare: c.rows[1]) }
        c.rows[1] = CaravanCreate.emptyRow()
    }
    /// Put the caravan's troops back (0x68e2d0): into the garrison (or the single row), the rest
    /// into the visiting row. False when something is left.
    @discardableResult
    func caravanMergeBack(_ c: CaravanCreate) -> Bool {
        let double = caravanDouble(c)
        var rows = c.rows
        GameState.moveAll(&rows, from: 2, to: double ? 0 : caravanSingleRow(c))
        if double { GameState.moveAll(&rows, from: 2, to: 1) }
        c.rows = rows
        if !c.caravanEmpty { prompt = (text("caravan.merge_failure", "This merge is not possible.  Try again."), false, nil); return false }
        return true
    }
    /// Changing the entry or the mode with troops in the caravan asks first; yes puts them back.
    func caravanChange(_ c: CaravanCreate, _ change: @escaping () -> Void) {
        let go = { [weak self] in
            guard let self = self else { return }
            self.caravanFinishEntry(c); change(); self.caravanLoadEntry(c)
        }
        if c.caravanEmpty { go(); return }
        prompt = (text("caravan.change_without_sending_text", "To change to a different origin or destination, you must clear the current caravan.  Are you sure you want to place the creatures in the caravan in your garrison?"), true, { [weak self] in
            guard let self = self, self.caravanMergeBack(c) else { return }
            go()
        })
    }
    /// Send the caravan (0x68e5b0): troops in it and a route; it arrives today + days.
    @discardableResult
    func caravanSend(_ c: CaravanCreate) -> Bool {
        guard let g = game, !c.caravanEmpty, let days = c.route?.days, let entry = c.entry else { return false }
        let (from, to): (CaravanSource, Int)
        if c.mode == 0 { from = entry; to = c.town } else if case .town(let d) = entry { from = .town(c.town); to = d } else { return false }
        caravanApplyRows(c)
        g.sendCaravan(c.rows[2], from: from, to: to, days: days, owner: c.player)
        c.rows[2] = CaravanCreate.emptyRow()
        c.picked = nil
        return true
    }
    func caravanClose(_ c: CaravanCreate) {
        caravanFinishEntry(c)
        caravanUI = nil
    }

    /// The rows' geometry (dialog-relative): (row index, its slots).
    func caravanCreateRows(_ c: CaravanCreate, _ ox: Int, _ oy: Int) -> [(row: Int, slots: [(piece: String, fx: Int, fy: Int)])] {
        guard c.origin != nil else { return [] }
        var out: [(Int, [(piece: String, fx: Int, fy: Int)])] = []
        if caravanDouble(c) {
            out.append((0, ringRow(x: ox + 321, y: oy + 263, style: 1)))
            out.append((1, ringRow(x: ox + 321, y: oy + 335, style: 2)))
        } else {
            out.append((caravanSingleRow(c), ringRow(x: ox + 321, y: oy + 295, style: 0)))
        }
        if c.reachable { out.append((2, ringRow(x: ox + 318, y: oy + 450, style: 0))) }
        return out
    }

    func caravanCreateQuads(_ c: CaravanCreate) -> [Quad] {
        guard let g = game, let d = dFile("dialog.caravan_create") else { return [] }
        let (ox, oy) = dialogOrigin800
        let tag = "cvc"
        var out = dImage(d, tag, "Background", ox, oy)
        out += dText(text("caravan.title", "Create Caravan"), dRect(d, "Title"), font: dFont(20), ox, oy)
        let townEntry = c.origin != nil
        var dwelling: Int? = nil
        if case .dwelling(let i)? = c.entry { dwelling = i }
        let here = g.towns[c.town].name
        if townEntry, let r = c.route {
            let (o, dst) = c.mode == 0 ? (g.caravanSourceName(c.entry!), here) : (here, g.caravanSourceName(c.entry!))
            out += dImage(d, tag, "text scroll", ox, oy)
            out += dText(g.caravanRouteText(r, origin: o, destination: dst), dRect(d, "Text"), font: dFont(18), ox, oy)
        }
        if let i = dwelling, let r = c.route {
            out += dImage(d, tag, "buy_text_scroll", ox, oy)
            out += dText(g.caravanBuyText(dwelling: i, route: r, destination: here), dRect(d, "Buy_Text"), font: dFont(18), ox, oy)
        }
        out += dText(here, dRect(d, "Target_town_Name"), font: dFont(18), ox, oy)
        if let p = dRect(d, "Target_town_picture") { out += caravanPicture(.town(c.town), x: ox + p.x, y: oy + p.y) }
        if let m = dRect(d, "Target_town_map") { out += caravanMiniMap(cellX: g.towns[c.town].x, cellY: g.towns[c.town].y, x: ox + m.x, y: oy + m.y, w: m.w, h: m.h) }
        out += dImage(d, tag, "Target_Town_Frame", ox, oy)
        let list = c.list
        if list.count > 4, let kit = kit { out += quads(kit.vScrollbar(ox + 6, oy + 115, 382, first: c.top[c.mode], visible: 4, total: list.count)) }
        if townEntry {
            out += dImage(d, tag, "Garrison_Text_Background", ox, oy)
            out += dText(text("caravan.garrison_title", "Existing Troops"), dRect(d, "Garrison_text"), font: dFont(16), ox, oy)
        }
        let R = townEntry && c.reachable
        if R {
            out += dImage(d, tag, "Caravan_Text_Background", ox, oy)
            out += dText(text("caravan.new_caravan_title", "Caravan"), dRect(d, "Caravan_Text"), font: dFont(16), ox, oy)
        }
        if let r = dRect(d, "Ok_button") { out += townButton("ok", x: ox + r.x, y: oy + r.y) }
        if let r = dRect(d, "Cancel_button") { out += townButton("cancel", x: ox + r.x, y: oy + r.y) }
        let double = caravanDouble(c)
        if townEntry {
            if double { out += dImage(d, tag, "Double_Ring_Background", ox, oy) } else { out += dImage(d, tag, "Single_Ring_Background", ox, oy) }
        }
        if R { out += dImage(d, tag, "Caravan_Ring_Background", ox, oy) }
        if townEntry {
            if let r = dRect(d, double ? "Double_Split_Button" : "Single_Split_Button") { out += townButton("split", x: ox + r.x, y: oy + r.y, pressed: c.split) }
        }
        out += caravanPrefixButton(d, tag, "Transport", ox, oy, disabled: c.caravanEmpty || !c.reachable)
        if R {
            if double {
                out += caravanPrefixButton(d, tag, "Move_To_Caravan_Double_1", ox, oy)
                out += caravanPrefixButton(d, tag, "Move_To_Caravan_Double_2", ox, oy)
            } else {
                out += caravanPrefixButton(d, tag, "Move_To_Caravan_Single", ox, oy)
            }
            out += caravanPrefixButton(d, tag, "Move_Back", ox, oy)
        }
        out += caravanPrefixButton(d, tag, "From_Town", ox, oy, disabled: c.destinations.isEmpty, pressed: c.mode == 1)
        out += dText(text("caravan.from_town_text", "From"), dRect(d, "From_Town_Text"), font: dFont(16), ox, oy)
        out += caravanPrefixButton(d, tag, "To_Town", ox, oy, disabled: c.origins.isEmpty, pressed: c.mode == 0)
        out += dText(text("caravan.to_town_text", "To"), dRect(d, "To_Town_Text"), font: dFont(16), ox, oy)
        // the rows
        let lifted = caravanDragAt != nil ? caravanDrag : nil
        for (row, slots) in caravanCreateRows(c, ox, oy) {
            let sel = c.picked.flatMap { $0.row == row ? $0.k : nil }
            out += caravanRowQuads(slots, c.rows[row], selected: sel, lifted: lifted.flatMap { $0.row == row ? $0.k : nil })
        }
        // the dwelling's Buy and portrait
        if let i = dwelling, let cr = g.tables?.creature(g.dwellings[i].creature) {
            let avail = g.dwellings[i].available
            if let r = dRect(d, "Buy_button") { out += townButton("buy", x: ox + r.x, y: oy + r.y, disabled: !(c.reachable && avail >= 1)) }
            if let r = dRect(d, "Buy_Portrait"), let ui = ui, let icon = ui.creatureIcon(cr.keyword) {
                out += dImageAt(icon, "icon", x: ox + r.x + (r.w - icon.width) / 2, y: oy + r.y + 2)
                out += dText("\(avail)", DRect(r.x, r.y + r.h - 20, r.w, 20), font: dFont(16), halo: Renderer.halo200, ox, oy)
            }
        }
        // the location slots
        for k in 0..<min(4, list.count) {
            let n = c.top[c.mode] + k
            guard n < list.count else { break }
            let dy = 129 * k, e = list[n]
            if let p = dRect(d, "Location_1_picture") { out += caravanPicture(e, x: ox + p.x, y: oy + p.y + dy) }
            if let m = dRect(d, "Location_1_map") { let cell = caravanCell(e); out += caravanMiniMap(cellX: cell.0, cellY: cell.1, x: ox + m.x, y: oy + m.y + dy, w: m.w, h: m.h) }
            out += dImage(d, tag, "Location_1_Frame", ox, oy, dy: dy)
            if n == c.selected[c.mode] { out += dImage(d, tag, "Location_1_Frame_Highlighted", ox, oy, dy: dy) }
            out += dImage(d, tag, "Location_1_Name_Background", ox, oy, dy: dy)
            let name = g.caravanSourceName(e)
            let title = c.routes[c.mode][n].days.map { GameState.substitute(text("caravan.location_title", "%name: %days"), ["%name": name, "%days": "\($0)"]) }
                ?? GameState.substitute(text("caravan.unreachable_location_title", "%name"), ["%name": name])
            out += dText(title, dRect(d, "Location_1_Name")?.offset(0, dy), font: dFont(18), ox, oy)
        }
        if let l = lifted, l.row < c.rows.count, l.k < c.rows[l.row].count { out += caravanLiftedQuads(c.rows[l.row][l.k]) }
        return out
    }

    func caravanCreateClick(_ c: CaravanCreate, _ x: Float, _ y: Float) {
        guard let g = game, let d = dFile("dialog.caravan_create") else { caravanUI = nil; return }
        let (ox, oy) = dialogOrigin800
        func button(_ name: String, _ file: String) -> Bool { dRect(d, name).map { townButtonHit(file, x: ox + $0.x, y: oy + $0.y, x, y) } ?? false }
        if button("Ok_button", "ok") { caravanOK(c); return }
        if button("Cancel_button", "cancel") { caravanCancel(c); return }
        let townEntry = c.origin != nil, R = townEntry && c.reachable, double = caravanDouble(c)
        if !c.caravanEmpty, c.reachable, caravanPrefixHit(d, "Transport", ox, oy, x, y) { caravanSend(c); return }
        if !c.destinations.isEmpty, c.mode != 1, caravanPrefixHit(d, "From_Town", ox, oy, x, y) { caravanChange(c) { c.mode = 1 }; return }
        if !c.origins.isEmpty, c.mode != 0, caravanPrefixHit(d, "To_Town", ox, oy, x, y) { caravanChange(c) { c.mode = 0 }; return }
        if townEntry, let r = dRect(d, double ? "Double_Split_Button" : "Single_Split_Button"), townButtonHit("split", x: ox + r.x, y: oy + r.y, x, y) { c.split.toggle(); return }
        if R {
            let moves: [(String, Int)] = double ? [("Move_To_Caravan_Double_1", 0), ("Move_To_Caravan_Double_2", 1)] : [("Move_To_Caravan_Single", caravanSingleRow(c))]
            for (p, from) in moves where caravanPrefixHit(d, p, ox, oy, x, y) {
                var rows = c.rows; GameState.moveAll(&rows, from: from, to: 2); c.rows = rows; c.picked = nil; caravanApplyRows(c); return
            }
            if caravanPrefixHit(d, "Move_Back", ox, oy, x, y) {
                var rows = c.rows
                GameState.moveAll(&rows, from: 2, to: double ? 0 : caravanSingleRow(c))
                if double { GameState.moveAll(&rows, from: 2, to: 1) }
                c.rows = rows; c.picked = nil; caravanApplyRows(c); return
            }
        }
        if case .dwelling(let i)? = c.entry, let r = dRect(d, "Buy_button"), townButtonHit("buy", x: ox + r.x, y: oy + r.y, x, y) {
            guard c.reachable, g.dwellings[i].available >= 1, let cr = g.tables?.creature(g.dwellings[i].creature) else { return }
            caravanUI = .buy(c, dwelling: i, count: g.recruitMost(available: g.dwellings[i].available, cost: g.recruitCost(cr, discount: 0)))
            return
        }
        // the scrollbar
        let list = c.list
        if list.count > 4, let kit = kit, let dir = kit.vScrollbarHit(ox + 6, oy + 115, 382, x, y) {
            c.top[c.mode] = max(0, min(list.count - 4, c.top[c.mode] + dir)); return
        }
        // a location
        if let l = dRect(d, "Location_1") {
            for k in 0..<min(4, list.count) where l.offset(ox, oy + 129 * k).contains(x, y) {
                let n = c.top[c.mode] + k
                if n < list.count, n != c.selected[c.mode] { caravanChange(c) { c.selected[c.mode] = n } }
                return
            }
        }
        // the rows: pick a place, then the place to move it to
        for (row, slots) in caravanCreateRows(c, ox, oy) {
            guard let k = caravanRing(slots, x, y) else { continue }
            if let p = c.picked {
                if p.row == row && p.k == k { c.picked = nil } else { caravanMove(c, from: p, to: (row, k)) }
            } else if c.rows[row][k] != nil { c.picked = (row, k) }
            return
        }
    }
    /// A move between the rows (a drop or a click), with the split dialog for Shift / the split toggle.
    func caravanMove(_ c: CaravanCreate, from: (row: Int, k: Int), to: (row: Int, k: Int), split: Bool = false) {
        c.picked = nil
        guard let src = c.rows[from.row][from.k] else { return }
        let dst = c.rows[to.row][to.k]
        if split || c.split, let a = src.stack, dst == nil || dst?.stack?.creature == a.creature, a.count + (dst?.stack?.count ?? 0) >= 2 {
            let have = dst?.stack?.count ?? 0
            c.split = false
            openSplit(creature: a.creature, source: a.count, destination: have) { [weak self] n in
                var rows = c.rows
                if n > have { _ = GameState.move(&rows, from: from, to: to, split: n - have) }
                else if n < have { _ = GameState.move(&rows, from: to, to: from, split: have - n) }
                c.rows = rows; self?.caravanApplyRows(c)
            }
            return
        }
        var rows = c.rows
        guard GameState.move(&rows, from: from, to: to) else { return }
        c.rows = rows
        caravanApplyRows(c)
    }
    /// OK (0x68da50): send what is in the caravan, then leave (asking first when it could not go).
    func caravanOK(_ c: CaravanCreate) {
        caravanSend(c)
        if c.caravanEmpty { caravanClose(c); return }
        prompt = (text("caravan.change_without_sending_text", "To change to a different origin or destination, you must clear the current caravan.  Are you sure you want to place the creatures in the caravan in your garrison?"), true, { [weak self] in
            guard let self = self, self.caravanMergeBack(c) else { return }
            self.caravanClose(c)
        })
    }
    /// Cancel (0x68cf20): with troops in the caravan ask, put them back, leave.
    func caravanCancel(_ c: CaravanCreate) {
        if c.caravanEmpty { caravanClose(c); return }
        prompt = (text("caravan.cancel_without_sending_text", "Are you sure you wish to cancel this caravan and place the creatures in your garrison?"), true, { [weak self] in
            guard let self = self, self.caravanMergeBack(c) else { return }
            self.caravanClose(c)
        })
    }
    /// The recruit dialog of the dwelling: bought creatures go straight into a new caravan.
    func caravanBuyClick(_ c: CaravanCreate, dwelling i: Int, count: Int, _ x: Float, _ y: Float) {
        guard let g = game, let cr = g.tables?.creature(g.dwellings[i].creature) else { caravanUI = .create(c); return }
        let cost = g.recruitCost(cr, discount: 0)
        switch recruitDialogClick(x: x, y: y, count: count, most: g.recruitMost(available: g.dwellings[i].available, cost: cost)) {
        case .buy:
            caravanUI = .create(c)
            guard let days = c.route?.days, g.buyCaravan(dwelling: i, count: count, to: c.town, days: days) != nil else { return }   // silent (0x43dee0 direct)
            let s = days == 1 ? text("caravan.dwelling_caravan_sent_1_day", "Today, the caravan began its journey and will arrive at %destination in 1 day.")
                              : text("caravan.dwelling_caravan_sent_multiple_days", "Today, the caravan began its journey and will arrive at %destination in %days days.")
            prompt = (GameState.substitute(s, ["%destination": g.towns[c.town].name, "%days": "\(days)"]), false, nil)
        case .cancel: caravanUI = .create(c)
        case .count(let n): caravanUI = .buy(c, dwelling: i, count: n)
        case .none: break
        }
    }

    // MARK: t_dialog_caravan_view (layers.Dialog.Caravan_View, 800 x 600)

    static let caravanViewRowY = [0, 170, 339]

    func caravanViewQuads(_ v: CaravanView) -> [Quad] {
        guard let g = game, let ui = ui, let d = dFile("Dialog.Caravan_View") else { return [] }
        let (ox, oy) = dialogOrigin800
        let tag = "cvv"
        var out = dImage(d, tag, "Background", ox, oy)
        out += dImage(d, tag, "title scroll", ox, oy)
        let title = v.town.map { GameState.substitute(text("caravan_view.title_town", "View Caravans for %Town."), ["%town": g.towns[$0].name]) }
            ?? text("caravan_view.title_global", "View Caravans")
        out += dText(title, dRect(d, "Title"), font: dFont(20), ox, oy)
        if v.list.count > 3, let kit = kit { out += quads(kit.vScrollbar(ox + 54, oy + 162, 315, first: v.top, visible: 3, total: v.list.count)) }
        if let r = dRect(d, "Close_Button") { out += townButton("ok", x: ox + r.x, y: oy + r.y) }
        let me = caravanPlayer
        let flags = dFile("icons.flags.55")
        for i in 0..<min(3, v.list.count) {
            let n = v.top + i
            guard n < v.list.count else { break }
            let c = v.list[n], dy = Renderer.caravanViewRowY[i]
            for l in ["Days_Background", "Number_background", "Rings_Background", "location_scroll"] { out += dImage(d, tag, l, ox, oy, dy: dy) }
            if let f = dRect(d, "Flag_1") { out += dImageOffset(dLayer(flags, AdventureUI.playerColourNames[min(5, max(0, c.owner))]), "flag55", x: ox + f.x, y: oy + f.y + dy) }
            let arrived = c.arrivalDay < g.day || (c.arrivalDay == g.day && c.owner <= me)
            let days = c.arrivalDay - g.day
            if arrived || days <= 0 {
                out += dText(arrived ? text("caravan_view.arrived_text", "Arrived") : text("caravan_view.today_text", "Today"), dRect(d, "Days_Text")?.offset(0, dy), font: dFont(14), ox, oy)
            } else {
                out += dText("\(days)", dRect(d, "Days_Text")?.offset(0, dy), font: dFont(36), ox, oy)
                out += dText(days == 1 ? text("caravan_view.day_subtext", "day") : text("caravan_view.days_subtext", "days"), dRect(d, "Days_subtext")?.offset(0, dy), font: dFont(12), ox, oy)
            }
            let friendly = g.sameSide(c.owner, me)
            let dest = g.towns[c.destination].name
            let loc = friendly ? GameState.substitute(text("caravan_view.location_self", "From %origin To %destination"), ["%origin": c.origin, "%destination": dest])
                : GameState.substitute(text("caravan_view.location_other", "To %destination"), ["%destination": dest])
            out += dText(loc, dRect(d, "Location")?.offset(0, dy), font: dFont(16), ox, oy)
            // the rings (t_creature_info_window): exact counts for one's own side, size words for the enemy's
            let slots = ringRow(x: ox + 279, y: oy + 58 + dy, style: 0)
            let sel = v.selected.flatMap { $0.row == n ? $0.k : nil }
            let numberBox = ui.creatureRing("number_text").map { DRect($0) } ?? DRect(12, 80, 55, 30)
            for (k, s) in slots.enumerated() {
                let cx = s.fx + 41, cy = s.fy + 41
                let slot = k < c.slots.count ? c.slots[k] : nil
                if let sl = slot { let (icon, _) = slotIcon(sl, ui: ui); if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height)) } }
                if let p = ui.creatureRing(k == sel ? s.piece + "_Highlight" : s.piece) ?? ui.creatureRing(s.piece) {
                    out.append(Quad(texture: uiTexture("cring|\(p.name)", { p.bitmap }), x: s.fx + p.x, y: s.fy + p.y, w: p.width, h: p.height))
                }
                if let st = slot?.stack {
                    if friendly { out += dText("\(st.count) ", numberBox.offset(s.fx, s.fy), font: dFont(30), halo: Renderer.halo200, 0, 0) }
                    else { out += dText(Renderer.armySizeWord(st.count, g.tables?.strings ?? [:]), numberBox.offset(s.fx, s.fy), font: dFont(12), halo: Renderer.halo200, 0, 0) }
                }
            }
        }
        return out
    }
    func caravanViewClick(_ v: CaravanView, _ x: Float, _ y: Float) {
        guard let d = dFile("Dialog.Caravan_View") else { caravanUI = nil; return }
        let (ox, oy) = dialogOrigin800
        if let r = dRect(d, "Close_Button"), townButtonHit("ok", x: ox + r.x, y: oy + r.y, x, y) { caravanUI = nil; return }
        if v.list.count > 3, let kit = kit, let dir = kit.vScrollbarHit(ox + 54, oy + 162, 315, x, y) { v.top = max(0, min(v.list.count - 3, v.top + dir)); return }
        for i in 0..<min(3, v.list.count) {
            let n = v.top + i
            guard n < v.list.count, let k = caravanRing(ringRow(x: ox + 279, y: oy + 58 + Renderer.caravanViewRowY[i], style: 0), x, y), v.list[n].slots[k] != nil else { continue }
            v.selected = (n, k); return
        }
    }
    /// The right click texts of the days field (caravan_view.*_right_click).
    func caravanViewHelp(_ v: CaravanView, _ x: Float, _ y: Float) -> String? {
        guard let g = game, let d = dFile("Dialog.Caravan_View"), let r = dRect(d, "Days_Background") else { return nil }
        let (ox, oy) = dialogOrigin800
        for i in 0..<min(3, v.list.count) where r.offset(ox, oy + Renderer.caravanViewRowY[i]).contains(x, y) {
            let c = v.list[v.top + i]
            let arrived = c.arrivalDay < g.day || (c.arrivalDay == g.day && c.owner <= caravanPlayer)
            if arrived { return text("caravan_view.arrived_right_click", "") }
            if c.arrivalDay - g.day <= 0 { return text("caravan_view.today_right_click", "") }
            return text("caravan_view.days_right_click", "")
        }
        return nil
    }

    // MARK: t_dialog_caravan_arrivals (layers.Dialog.Caravan_Arrival, 800 x 600)

    static let caravanArrivalRow = [(0, 0), (0, 92), (-1, 186)]

    /// The arrivals dialog's rows: 0 the garrison, 1 the visiting army (when there is one), 2 + i the shown caravans.
    func caravanArrivalRows(_ a: CaravanArrivals, _ ox: Int, _ oy: Int) -> [(row: Int, slots: [(piece: String, fx: Int, fy: Int)])] {
        guard let g = game else { return [] }
        var out: [(Int, [(piece: String, fx: Int, fy: Int)])] = []
        if g.visitingArmy(town: a.town) != nil {
            out.append((0, ringRow(x: ox + 183, y: oy + 412, style: 1)))
            out.append((1, ringRow(x: ox + 183, y: oy + 484, style: 2)))
        } else {
            out.append((0, ringRow(x: ox + 177, y: oy + 443, style: 0)))
        }
        for i in 0..<min(3, a.list.count) where a.top + i < a.list.count {
            let (dx, dy) = Renderer.caravanArrivalRow[i]
            out.append((2 + i, ringRow(x: ox + 177 + dx, y: oy + 125 + dy, style: 0)))
        }
        return out
    }
    /// The rows' contents: [garrison, visiting, caravan top, top + 1, top + 2].
    func caravanArrivalContents(_ a: CaravanArrivals) -> [[ArmySlot?]] {
        guard let g = game else { return [] }
        var rows: [[ArmySlot?]] = [g.garrisonSlots(a.town), g.visitingArmy(town: a.town).map { g.armySlots($0) } ?? CaravanCreate.emptyRow()]
        for i in 0..<3 { rows.append(a.top + i < a.list.count ? a.list[a.top + i].slots : CaravanCreate.emptyRow()) }
        return rows
    }
    func caravanArrivalApply(_ a: CaravanArrivals, _ rows: [[ArmySlot?]]) {
        guard let g = game else { return }
        if let v = g.visitingArmy(town: a.town) { g.applyTownRows(a.town, [rows[0], rows[1]], visitor: v) } else { g.setGarrison(a.town, rows[0]) }
        for i in 0..<3 where a.top + i < a.list.count { a.list[a.top + i].slots = rows[2 + i] }
    }

    func caravanArrivalsQuads(_ a: CaravanArrivals) -> [Quad] {
        guard let g = game, let d = dFile("Dialog.Caravan_Arrival") else { return [] }
        let (ox, oy) = dialogOrigin800
        let tag = "cva"
        var out = dImage(d, tag, "Background", ox, oy)
        out += dImage(d, tag, "Text Scroll", ox, oy)
        out += dImage(d, tag, "title scroll", ox, oy)
        let town = g.towns[a.town].name
        out += dText(GameState.substitute(text("caravan_arrivals.title", "Manage Arrived Caravans"), ["%town": town]), dRect(d, "Title"), font: dFont(20), ox, oy)
        out += dText(GameState.substitute(text("caravan_arrivals.text", ""), ["%town": town]), dRect(d, "Text"), font: dFont(16), ox, oy)
        if let r = dRect(d, "OK_Button") { out += townButton("ok", x: ox + r.x, y: oy + r.y) }
        let visiting = g.visitingArmy(town: a.town) != nil
        out += dImage(d, tag, visiting ? "Double_Garrison_Background" : "Single_Garrison_Background", ox, oy)
        let rows = caravanArrivalContents(a)
        let lifted = caravanDragAt != nil ? caravanDrag : nil
        let all = caravanArrivalRows(a, ox, oy)
        for (row, slots) in all where row < 2 {
            out += caravanRowQuads(slots, rows[row], selected: a.picked.flatMap { $0.row == row ? $0.k : nil }, lifted: lifted.flatMap { $0.row == row ? $0.k : nil })
        }
        if visiting {
            if let r = dRect(d, "Move_Garrison_Button") { out += townButton("move_garrison_down", x: ox + r.x, y: oy + r.y) }
            if let r = dRect(d, "Move_Visiting_Button") { out += townButton("move_up", x: ox + r.x, y: oy + r.y) }
        }
        if a.list.count > 3, let kit = kit { out += quads(kit.vScrollbar(ox + 60, oy + 163, 220, first: a.top, visible: 3, total: a.list.count)) }
        for (row, slots) in all where row >= 2 {
            let (dx, dy) = Renderer.caravanArrivalRow[row - 2]
            out += dImage(d, tag, "Caravan_Background", ox, oy, dx: dx, dy: dy)
            out += townButton("move_Caravan_To_Garrison", x: ox + 111 + dx, y: oy + 136 + dy)
            if visiting { out += townButton("move_Caravan_To_Visiting", x: ox + 623 + dx, y: oy + 137 + dy) }
            out += caravanRowQuads(slots, rows[row], selected: a.picked.flatMap { $0.row == row ? $0.k : nil }, lifted: lifted.flatMap { $0.row == row ? $0.k : nil })
        }
        if let l = lifted, l.row < rows.count { out += caravanLiftedQuads(rows[l.row][l.k]) }
        return out
    }
    func caravanArrivalsClick(_ a: CaravanArrivals, _ x: Float, _ y: Float) {
        guard let g = game, let d = dFile("Dialog.Caravan_Arrival") else { caravanUI = nil; return }
        let (ox, oy) = dialogOrigin800
        if let r = dRect(d, "OK_Button"), townButtonHit("ok", x: ox + r.x, y: oy + r.y, x, y) { caravanArrivalsOK(a); return }
        let visiting = g.visitingArmy(town: a.town) != nil
        var rows = caravanArrivalContents(a)
        if visiting {
            if let r = dRect(d, "Move_Garrison_Button"), townButtonHit("move_garrison_down", x: ox + r.x, y: oy + r.y, x, y) { GameState.moveAll(&rows, from: 0, to: 1); caravanArrivalApply(a, rows); return }
            if let r = dRect(d, "Move_Visiting_Button"), townButtonHit("move_up", x: ox + r.x, y: oy + r.y, x, y) { GameState.moveAll(&rows, from: 1, to: 0); caravanArrivalApply(a, rows); return }
        }
        if a.list.count > 3, let kit = kit, let dir = kit.vScrollbarHit(ox + 60, oy + 163, 220, x, y) { a.top = max(0, min(a.list.count - 3, a.top + dir)); a.picked = nil; return }
        for i in 0..<min(3, a.list.count) where a.top + i < a.list.count {
            let (dx, dy) = Renderer.caravanArrivalRow[i]
            // "move all" (0x647280): each stack into the same place or the first that takes it; no room, it stays
            if townButtonHit("move_Caravan_To_Garrison", x: ox + 111 + dx, y: oy + 136 + dy, x, y) {
                let c = a.list[a.top + i]; var row = rows[0]; GameState.mergeCaravan(c, into: &row); rows[0] = row; rows[2 + i] = c.slots
                caravanArrivalApply(a, rows); return
            }
            if visiting, townButtonHit("move_Caravan_To_Visiting", x: ox + 623 + dx, y: oy + 137 + dy, x, y) {
                let c = a.list[a.top + i]; var row = rows[1]; GameState.mergeCaravan(c, into: &row); rows[1] = row; rows[2 + i] = c.slots
                caravanArrivalApply(a, rows); return
            }
        }
        for (row, slots) in caravanArrivalRows(a, ox, oy) {
            guard let k = caravanRing(slots, x, y) else { continue }
            if let p = a.picked {
                a.picked = nil
                if !(p.row == row && p.k == k), GameState.move(&rows, from: p, to: (row, k)) { caravanArrivalApply(a, rows) }
            } else if rows[row][k] != nil { a.picked = (row, k) }
            return
        }
    }
    /// OK (0x685040): the emptied caravans go; the rest keep waiting outside the town.
    func caravanArrivalsOK(_ a: CaravanArrivals) {
        game?.caravans.removeAll { $0.isEmpty }
        caravanUI = nil
    }

    // MARK: input

    func caravanClick(x: Float, y: Float) {
        guard let c = caravanUI else { return }
        switch c {
        case .initial(let t): caravanInitialClick(t, x, y)
        case .create(let s): caravanCreateClick(s, x, y)
        case .view(let v): caravanViewClick(v, x, y)
        case .arrivals(let a): caravanArrivalsClick(a, x, y)
        case .buy(let s, let d, let n): caravanBuyClick(s, dwelling: d, count: n, x, y)
        }
    }
    /// Enter / Esc (and the initial dialog's C / V / M).
    func caravanKey(_ code: UInt16) -> Bool {
        guard let c = caravanUI else { return false }
        let enter = code == 36 || code == 76, esc = code == 53
        switch c {
        case .initial(let t):
            if esc { caravanUI = nil }
            else if code == 8 { caravanUI = nil; openCaravanCreate(t) }      // C
            else if code == 9 { caravanUI = nil; openCaravanView(t) }        // V
            else if code == 46 { caravanUI = nil; openCaravanArrivals(t) }   // M
        case .create(let s):
            if enter { caravanOK(s) } else if esc { caravanCancel(s) }
            else if code == 116 || code == 121, !s.list.isEmpty {   // Page Up / Page Down: the previous / next entry
                let n = max(0, min(s.list.count - 1, s.selected[s.mode] + (code == 116 ? -1 : 1)))
                if n != s.selected[s.mode] {
                    caravanChange(s) { s.selected[s.mode] = n; if n < s.top[s.mode] { s.top[s.mode] = n } else if n >= s.top[s.mode] + 4 { s.top[s.mode] = n - 3 } }
                }
            }
        case .view: if enter || esc { caravanUI = nil }
        case .arrivals(let a): if enter || esc { caravanArrivalsOK(a) }
        case .buy(let s, _, _): if esc { caravanUI = .create(s) }
        }
        return true
    }
    /// A press on a ring of the open caravan dialog: it may be dragged.
    func caravanPress(x: Float, y: Float) {
        caravanDragAt = nil; caravanDrag = nil
        guard let c = caravanUI, prompt == nil else { return }
        let (ox, oy) = dialogOrigin800
        switch c {
        case .create(let s):
            for (row, slots) in caravanCreateRows(s, ox, oy) { if let k = caravanRing(slots, x, y), s.rows[row][k] != nil { caravanDrag = (row, k) } }
        case .arrivals(let a):
            let rows = caravanArrivalContents(a)
            for (row, slots) in caravanArrivalRows(a, ox, oy) { if let k = caravanRing(slots, x, y), rows[row][k] != nil { caravanDrag = (row, k) } }
        default: break
        }
    }
    func caravanDragged(x: Float, y: Float) {
        guard caravanDrag != nil else { return }
        if caravanDragAt == nil { NSCursor.hide() }
        caravanDragAt = (x, y)
    }
    /// A drop: a move between the rows (Shift: the split dialog in Create Caravan).
    func caravanDrop(x: Float, y: Float, shift: Bool) {
        defer { caravanDrag = nil; if caravanDragAt != nil { NSCursor.unhide() }; caravanDragAt = nil }
        guard let from = caravanDrag, let c = caravanUI else { return }
        let (ox, oy) = dialogOrigin800
        switch c {
        case .create(let s):
            for (row, slots) in caravanCreateRows(s, ox, oy) {
                if let k = caravanRing(slots, x, y), (row, k) != (from.row, from.k) { caravanMove(s, from: from, to: (row, k), split: shift); return }
            }
        case .arrivals(let a):
            var rows = caravanArrivalContents(a)
            for (row, slots) in caravanArrivalRows(a, ox, oy) {
                if let k = caravanRing(slots, x, y), (row, k) != (from.row, from.k) {
                    if GameState.move(&rows, from: from, to: (row, k)) { caravanArrivalApply(a, rows) }
                    a.picked = nil; return
                }
            }
        default: break
        }
    }
}

extension Renderer {
    /// Snapshot set-ups (H4CARAVAN=initial|create|dwelling|buy|view|global|arrivals|nolist with --town):
    /// the open town and another one get caravans, a dwelling is flagged, sample caravans are sent.
    func caravanSnapshot(_ what: String, town i: Int) {
        guard let g = game else { return }
        let me = g.map.humanColour
        g.towns[i].buildings.insert("caravan")
        if let j = g.towns.indices.first(where: { $0 != i && g.towns[$0].z == g.towns[i].z }) {
            g.towns[j].owner = me; g.towns[j].owned = true; g.towns[j].buildings.insert("caravan")
            if g.towns[j].garrison.isEmpty { g.towns[j].garrison = [Hero.Stack(creature: "Peasant", count: 40), Hero.Stack(creature: "Squire", count: 6)] }
            let other = (me + 1) % 6
            switch what {
            case "view", "global":
                g.sendCaravan([.stack(Hero.Stack(creature: "Peasant", count: 25)), .stack(Hero.Stack(creature: "Crossbowman", count: 7))], from: .town(j), to: i, days: 3, owner: me)
                g.sendCaravan([.stack(Hero.Stack(creature: "Squire", count: 12))], from: .town(j), to: i, days: 1, owner: me)
                let e = g.sendCaravan([.stack(Hero.Stack(creature: "Imp", count: 33)), .stack(Hero.Stack(creature: "Cerberus", count: 4))], from: .town(j), to: i, days: 2, owner: other)
                e?.arrivalDay = g.day
                g.sendCaravan([.stack(Hero.Stack(creature: "Archangel", count: 1))], from: .town(i), to: j, days: 4, owner: me)
            case "arrivals":
                for (c, n) in [("Peasant", 30), ("Pikeman", 9)] {
                    let cv = g.sendCaravan([.stack(Hero.Stack(creature: c, count: n)), .stack(Hero.Stack(creature: "Squire", count: 2))], from: .town(j), to: i, days: 1, owner: me)
                    cv?.arrivalDay = g.day
                }
            default: break
            }
        }
        if let d = g.dwellings.indices.first { g.dwellings[d].owner = me; g.dwellings[d].owned = true; g.dwellings[d].available = max(g.dwellings[d].available, 6) }
        switch what {
        case "initial": openCaravanBuilding(i)
        case "view": openCaravanView(i)
        case "global": openCaravanView(nil)
        case "arrivals": openCaravanArrivals(i)
        case "nolist": openCaravanView(i)
        default:
            openCaravanCreate(i)
            guard case .create(let c)? = caravanUI else { return }
            if what == "dwelling" || what == "buy", let k = c.origins.firstIndex(where: { if case .dwelling = $0 { return true }; return false }) {
                c.selected[0] = k; c.top[0] = max(0, k - 3); caravanLoadEntry(c)
                if what == "buy", let dw = { () -> Int? in if case .dwelling(let d) = c.origins[k] { return d }; return nil }() { caravanUI = .buy(c, dwelling: dw, count: 3) }
            } else if c.reachable {
                var rows = c.rows; _ = GameState.move(&rows, from: (0, 0), to: (2, 0)); c.rows = rows
            }
            print("caravan create: mode \(c.mode) origins \(c.origins.map { g.caravanSourceName($0) }) routes \(c.routes[0]) dests \(c.destinations.map { g.towns[$0].name })")
        }
    }
}
