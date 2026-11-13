#if os(iOS)
import Foundation
import CoreGraphics
import Metal
import H4Engine

/// The iPhone's own settings (UserDefaults).
enum IOSSettings {
    /// A combat move needs a second tap on the same place (the first shows where the stack would go).
    static var confirmCombatMoves: Bool {
        get { UserDefaults.standard.object(forKey: "h4view.ios.confirmCombatMoves") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "h4view.ios.confirmCombatMoves") }
    }
}

/// What a press on the battlefield would do, as the combat pointer reads it (Renderer.combatCursor).
enum CombatTouchAction: Equatable {
    case none
    /// A shot or the spell book of a casting stack (or a move without confirmation): one tap acts.
    case direct
    /// A blow at `target` from the footprint corner (x, y).
    case melee(target: Int, x: Int, y: Int)
    /// A blow at the castle gate from (x, y) ((-1, -1): no place in reach this turn).
    case gate(x: Int, y: Int)
    case move(x: Int, y: Int)
}

/// What the battlefield shows for the touch selection (no hover on a phone): the pointer the mac
/// would show and the place the stack would go, with its way there.
struct CombatTouchPreview {
    let action: CombatTouchAction
    /// The stack that was to act (another one acting ends the preview).
    let unit: Int
    /// The pointer shown (layers.cursor.<name>) and its frame (nil: the first).
    let cursor: String
    let frame: Int?
    /// Where the pointer's hot spot is drawn (frame canvas).
    let at: (Float, Float)
    /// The footprint the stack would stand on, and the footprints on its way there this turn.
    let dest: (x: Int, y: Int, size: Int)?
    let path: [(Int, Int)]
    /// The way on beyond this turn, and where this turn's move ends short of `dest`.
    var later: [(Int, Int)] = []
    var stop: (Int, Int)? = nil
}

/// One of the eight sides of the selected target in the sidebar's direction picker: the place the
/// mac's aim from that side picks (Battle.attackPlace(aim:)), if any is on that side.
struct PickSide {
    /// The grid step from the target to this side (world cells, -1...1) and the blow's aim from it.
    let gx: Int, gy: Int, aim: Int
    let place: Battle.AttackPlace?
    /// The stack can stand there and strike this turn.
    let today: Bool
    let turns: Int?
    let retaliates: Bool
    let extra: Int
    var enabled: Bool { place != nil && today }
}

/// The touch sidebar's selection: an enemy to strike (with the side picked) or a place to move to.
struct CombatPick {
    let unit: Int
    var target: Int? = nil
    var sides: [PickSide] = []
    var chosen: Int? = nil
    /// The stack shoots at the target (Shoot), as the mac's click would.
    var shoot = false
    var move: (x: Int, y: Int, turns: Int, cost: Float, today: Bool)? = nil
}

enum SidebarAction: Equatable { case side(Int), attack, shoot, move, cancel }
struct SidebarButton {
    let x: Int, y: Int, w: Int, h: Int
    let diamond: Bool
    let action: SidebarAction
    let enabled: Bool
    func contains(_ px: Float, _ py: Float) -> Bool {
        guard px >= Float(x), px < Float(x + w), py >= Float(y), py < Float(y + h) else { return false }
        guard diamond else { return true }
        let dx = abs(px - Float(x) - Float(w) / 2) / (Float(w) / 2), dy = abs(py - Float(y) - Float(h) / 2) / (Float(h) / 2)
        return dx + dy <= 1
    }
}

extension Renderer {
    /// Is the battle waiting for the player's order (no spell being aimed, no window open)?
    func combatOrdersOpen() -> Bool {
        guard let cs = combat, let b = cs.battle, let cur = b.current else { return false }
        return cs.info == nil && prompt == nil && spellBook == nil && optionsOpen == nil && casting == nil && !cs.showResults
            && cs.awaitingOrders && !cs.busy && cs.result == nil && !cs.autoCombat && b.commander(of: cur) == 0
    }
    /// Is the battlefield taking the player's orders at this frame canvas point (not a panel button)?
    func combatTouchAims(x: Float, y: Float) -> Bool {
        guard combatOrdersOpen(), let cs = combat, let b = cs.battle, x >= 0, x < Float(cs.hotspot("battle_scene")?.width ?? 885) else { return false }
        return !combatButtons(cs, b).contains { inside(cs.hotspot($0.hotspot), x, y) }
    }

    /// What a press at this canvas point would do (as combatClick would do it), with the pointer it shows.
    func combatTouchAction(x: Float, y: Float) -> (action: CombatTouchAction, cursor: String, frame: Int?, dest: (Int, Int)?) {
        cursorFrameIndex = nil
        let name = combatCursor(x: x, y: y)
        let frame = cursorFrameIndex
        guard let b = combat?.battle, let cur = b.current else { return (.none, name, frame, nil) }
        if name == "combat.shoot" || name == "combat.cast_spell" { return (.direct, name, frame, nil) }
        if name.hasPrefix("combat.melee") {
            if let t = enemyUnder(b, x: x, y: y) {
                guard let p = b.attackPlace(cur, t, aim: meleeAim(t, x: x, y: y)) else { return (.none, name, frame, nil) }
                return (.melee(target: t.id, x: p.x, y: p.y), name, frame, (p.x, p.y))
            }
            let p = gateStrikePosition(b, cur, x: x, y: y)
            return (.gate(x: p?.0 ?? -1, y: p?.1 ?? -1), name, frame, p)
        }
        if name == "combat.walk" || name == "combat.fly" {
            let c = footprintAt(cur, x: x, y: y)
            return (IOSSettings.confirmCombatMoves ? .move(x: c.0, y: c.1) : .direct, name, frame, c)
        }
        return (.none, name, frame, nil)
    }

    /// Forget the aimed action and what it marked.
    func clearTouchPreview() {
        guard touchPreview != nil || combatPick != nil else { return }
        touchPreview = nil; combatPick = nil
        combatTarget = nil; combatArea = nil; hover = nil
    }

    /// The selection ends when its stack no longer waits for orders: another acts, a window opens,
    /// the battle ends, the target dies (checked every frame). While it lasts the target keeps
    /// its shadow.
    func validateTouchPreview(_ cs: CombatScreen, _ b: Battle) {
        let unit = combatPick?.unit ?? touchPreview?.unit
        guard let u = unit else { return }
        if !combatOrdersOpen() || b.current?.id != u || combatPick?.target.map({ !b.unit($0).alive }) == true {
            clearTouchPreview(); return
        }
        if let p = combatPick, let t = p.target {
            combatTarget = t
            if let k = p.chosen, let pl = p.sides[k].place, let cur = b.current {
                let extra = b.extraTargets(cur, b.unit(t), ranged: false, from: (pl.x, pl.y), preview: true)
                combatArea = extra.isEmpty ? nil : Set(extra.map { $0.id })
            } else { combatArea = nil }
        }
    }

    // MARK: the selection

    /// The eight sides round the target, each with the place the aim from that side picks (the
    /// mac's pointer on that side of the stack aims so, 0x56f600); a side whose aim lands on a
    /// place more than 22 degrees off (nothing to stand on that way) is shown blocked.
    func pickSides(_ b: Battle, _ cur: Battle.Unit, _ t: Battle.Unit) -> [PickSide] {
        let today = b.reachable(cur)
        let steps = [(-1, -1), (-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1)]
        return steps.map { gx, gy in
            let aim = Battle.worldAngle(dx: -gx * 16, dy: -gy * 16)
            var place = b.attackPlace(cur, t, aim: aim)
            if let p = place, Battle.angleDifference(p.angle, aim) > 22 { place = nil }
            guard let p = place else { return PickSide(gx: gx, gy: gy, aim: aim, place: nil, today: false, turns: nil, retaliates: false, extra: 0) }
            let now = (p.x, p.y) == (cur.x, cur.y) || today[Battle.key(p.x, p.y)] != nil
            return PickSide(gx: gx, gy: gy, aim: aim, place: p, today: now, turns: b.turnsToAttack(cur, t, aim: aim),
                            retaliates: b.canRetaliate(t, against: cur, from: (p.x, p.y)),
                            extra: b.extraTargets(cur, t, ranged: false, from: (p.x, p.y), preview: true).count)
        }
    }

    /// Select the enemy: its sides, the one the mac would strike from without an aim (the
    /// cheapest place) picked, unless the stack shoots.
    func pickTarget(_ t: Battle.Unit) {
        guard let cs = combat, let b = cs.battle, let cur = b.current else { return }
        var p = CombatPick(unit: cur.id)
        p.target = t.id
        p.shoot = b.canShoot(cur) && cs.shownMode(cur) == 0
        p.sides = pickSides(b, cur, t)
        if !p.shoot, let cheapest = b.attackPlace(cur, t) {
            p.chosen = p.sides.firstIndex { $0.enabled && $0.place.map { ($0.x, $0.y) == (cheapest.x, cheapest.y) } == true }
                ?? p.sides.indices.filter { p.sides[$0].enabled }.min { Battle.angleDifference(p.sides[$0].aim, cheapest.angle) < Battle.angleDifference(p.sides[$1].aim, cheapest.angle) }
        }
        combatPick = p
        hover = nil
        showPick()
        MapView.touchLog("target \(t.keyword) id \(t.id): shoot \(p.shoot), sides \(p.sides.map { $0.enabled ? "\($0.place!.x),\($0.place!.y)" : ($0.place == nil ? "blocked" : "later") }.joined(separator: " ")), chosen \(p.chosen.map(String.init) ?? "-")")
    }

    /// Select a place to move to: its way (this turn's part and the rest), its turns.
    func pickMove(_ x: Int, _ y: Int, cursor: String, frame: Int?) {
        guard let b = combat?.battle, let cur = b.current else { return }
        let route = b.route(cur, to: x, y) ?? []
        let today = b.reachable(cur)
        let split = (route.lastIndex { today[Battle.key($0.0, $0.1)] != nil } ?? -1) + 1
        let reached = today[Battle.key(x, y)] != nil
        let cost = b.cost(cur, to: x, y) ?? 0
        let turns = max(1, Int((cost / Float(max(1, cur.move))).rounded(.up)))
        var p = CombatPick(unit: cur.id)
        p.move = (x, y, turns, cost, reached)
        combatPick = p
        let (cx, cy) = CombatScreen.point(Float(x) + Float(cur.size) / 2, Float(y) + Float(cur.size) / 2)
        var pv = CombatTouchPreview(action: .move(x: x, y: y), unit: cur.id, cursor: cursor, frame: frame, at: (cx, cy),
                                    dest: (x, y, cur.size), path: Array(route[..<split]))
        pv.later = Array(route[split...])
        pv.stop = reached ? nil : b.stepToward(cur, x, y)
        touchPreview = pv
        combatTarget = nil; combatArea = nil; hover = nil
        MapView.touchLog("move preview (\(x),\(y)): \(turns) turn(s), cost \(cost), this turn \(split) of \(route.count) steps, stop \(pv.stop.map { "\($0.0),\($0.1)" } ?? "there")")
    }

    /// The battlefield shows the picked side: the place, the way there, the sword pointer.
    func showPick() {
        guard let p = combatPick, let tid = p.target, let b = combat?.battle, let cur = b.current else { return }
        let t = b.unit(tid)
        let tc = CombatScreen.point(t.centre.0, t.centre.1)
        guard let k = p.chosen, let pl = p.sides[k].place else {
            // no side picked: the shooting pointer on the target, if it shoots
            touchPreview = p.shoot ? CombatTouchPreview(action: .direct, unit: cur.id, cursor: "combat.shoot", frame: shotFrame(b, cur, t), at: (tc.0, tc.1 - 20), dest: nil, path: []) : nil
            return
        }
        let pc = CombatScreen.point(Float(pl.x) + Float(cur.size) / 2, Float(pl.y) + Float(cur.size) / 2)
        let at = (tc.0 + (pc.0 - tc.0) * 0.45, tc.1 - 20 + (pc.1 - tc.1) * 0.45)
        touchPreview = CombatTouchPreview(action: .melee(target: tid, x: pl.x, y: pl.y), unit: cur.id, cursor: Renderer.meleeCursor(pl.angle),
                                          frame: min(4, p.sides[k].turns ?? 1) - 1, at: at, dest: (pl.x, pl.y, cur.size),
                                          path: (pl.x, pl.y) == (cur.x, cur.y) ? [] : (b.path(cur, to: pl.x, pl.y) ?? []))
    }
    /// The shooting pointer's frame: the damage divisor 1, 2, 4, 8 (as combatCursor picks it).
    func shotFrame(_ b: Battle, _ cur: Battle.Unit, _ t: Battle.Unit) -> Int {
        let div = b.rangeDivisor(cur, t)
        return div >= 8 ? 3 : div >= 4 ? 2 : div >= 2 ? 1 : 0
    }

    /// Do what a sidebar button says (the same engine calls as combatClick's).
    func sidebarPress(_ a: SidebarAction) {
        guard combatOrdersOpen(), let cs = combat, let b = cs.battle, var p = combatPick else { return }
        switch a {
        case .side(let k):
            guard k < p.sides.count, p.sides[k].enabled else { return }
            buttonClick()
            p.chosen = k; combatPick = p; showPick()
            MapView.touchLog("side \(k): place \(p.sides[k].place!.x),\(p.sides[k].place!.y) aim \(p.sides[k].aim)")
        case .attack:
            guard let t = p.target, let k = p.chosen, p.sides[k].enabled else { return }
            buttonClick()
            let pl = p.sides[k].place!
            MapView.touchLog("attack \(t) from \(pl.x),\(pl.y) aim \(p.sides[k].aim)")
            clearTouchPreview()
            let cur = b.current
            _ = b.attack(t, aim: p.sides[k].aim)
            if let u = cur { MapView.touchLog("attacker now at \(u.x),\(u.y)") }
            cs.pump()
        case .shoot:
            guard let t = p.target, p.shoot else { return }
            buttonClick()
            MapView.touchLog("shoot \(t)")
            clearTouchPreview()
            _ = b.shoot(t)
            cs.pump()
        case .move:
            guard let m = p.move else { return }
            buttonClick()
            MapView.touchLog("move to \(m.x),\(m.y)")
            clearTouchPreview()
            _ = b.move(to: m.x, m.y)
            cs.pump()
        case .cancel:
            buttonClick()
            clearTouchPreview()
        }
    }

    // MARK: drawing

    /// The destination's cells, the way there this turn (lighter), the way on beyond this turn
    /// (blue) and where this turn's move ends, under the units.
    func touchPreviewGround() -> [Quad] {
        guard let p = touchPreview, let d = p.dest else { return [] }
        var cells: [Int: UInt32] = [:]
        let way = Renderer.rgba(255, 255, 160, 80), later = Renderer.rgba(120, 170, 255, 90)
        let there = p.stop == nil ? Renderer.rgba(255, 230, 90, 150) : Renderer.rgba(140, 190, 255, 150)
        let stop = Renderer.rgba(255, 230, 90, 150)
        func mark(_ x: Int, _ y: Int, _ c: UInt32) {
            for dx in 0..<d.size { for dy in 0..<d.size where Battlefield.onField(x + dx, y + dy) { cells[Battle.key(x + dx, y + dy)] = c } }
        }
        for (x, y) in p.path { mark(x, y, way) }
        for (x, y) in p.later { mark(x, y, later) }
        mark(d.x, d.y, there)
        if let s = p.stop { mark(s.0, s.1, stop) }
        return [fieldOverlay("touchpreview", cells)]
    }

    func cursorLayer(_ name: String, frame: Int?) -> (UILayer, hot: (Int, Int))? {
        guard let cs = combat else { return nil }
        let file = "layers.cursor.\(name).h4d"
        if touchCursorFiles[file] == nil { touchCursorFiles[file] = .some((try? cs.archive.payload(file)).flatMap { try? LayerFile(data: $0) }) }
        guard let f = touchCursorFiles[file] ?? nil else { return nil }
        let hot = f.layers.first { $0.name.lowercased() == "hot_spot" }
        let frames = f.layers.filter { $0.name.lowercased() != "hot_spot" && $0.width > 0 }
        guard !frames.isEmpty else { return nil }
        return (frames[min(frame ?? 0, frames.count - 1)], (hot?.x ?? 0, hot?.y ?? 0))
    }
    /// The pointer the preview shows (the phone has none of its own): its picture with the hot spot at `at`.
    func touchPreviewCursor() -> [Quad] {
        guard let p = touchPreview, let (l, hot) = cursorLayer(p.cursor, frame: p.frame) else { return [] }
        return [image(l, key: "touchcursor|\(p.cursor)|\(l.name)", Int(p.at.0) - hot.0, Int(p.at.1) - hot.1)]
    }

    /// A plain colour.
    func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> MTLTexture {
        uiTexture("solid|\(r)|\(g)|\(b)|\(a)") {
            var bm = Bitmap(width: 2, height: 2)
            for i in 0..<4 { bm.pixels[i * 4] = r; bm.pixels[i * 4 + 1] = g; bm.pixels[i * 4 + 2] = b; bm.pixels[i * 4 + 3] = a }
            return bm
        }
    }
    /// A diamond (the battlefield's cell shape) of that size, filled, with a border.
    func diamond(_ w: Int, _ h: Int, fill: (UInt8, UInt8, UInt8, UInt8), edge: (UInt8, UInt8, UInt8, UInt8)) -> MTLTexture {
        uiTexture("diamond|\(w)|\(h)|\(fill)|\(edge)") {
            var bm = Bitmap(width: w, height: h)
            let hw = Float(w) / 2, hh = Float(h) / 2
            for y in 0..<h { for x in 0..<w {
                let d = abs(Float(x) + 0.5 - hw) / hw + abs(Float(y) + 0.5 - hh) / hh
                guard d <= 1 else { continue }
                let c = d > 1 - 3 / hh ? edge : fill
                let i = (y * w + x) * 4
                // premultiplied (the pipeline blends with source factor one)
                bm.pixels[i] = UInt8(Int(c.0) * Int(c.3) / 255); bm.pixels[i + 1] = UInt8(Int(c.1) * Int(c.3) / 255)
                bm.pixels[i + 2] = UInt8(Int(c.2) * Int(c.3) / 255); bm.pixels[i + 3] = c.3
            } }
            return bm
        }
    }
    /// Text lines in the game's font, wrapped to `width`; returns the quads and the height used.
    func sideText(_ s: String, size: Int, colour: (UInt8, UInt8, UInt8), x: Int, y: Int, width: Int, centred: Bool = false) -> ([Quad], Int) {
        guard let ui = ui else { return ([], 0) }
        let f = ui.font(size)
        var out: [Quad] = [], yy = y
        for line in AdventureUI.wrap(s, font: f, width: width) {
            let w = f.measure(line)
            out.append(Quad(texture: uiTexture("side|\(size)|\(colour)|\(line)", { f.render(line, colour: colour, halo: (0, 0, 0)) }),
                            x: centred ? x + (width - w) / 2 : x, y: yy, w: w, h: f.size))
            yy += f.lineHeight
        }
        return (out, yy - y)
    }
    func sideButton(_ title: String, _ a: SidebarAction, x: Int, y: Int, w: Int, h: Int, enabled: Bool) -> [Quad] {
        sidebarButtons.append(SidebarButton(x: x, y: y, w: w, h: h, diamond: false, action: a, enabled: enabled))
        let edge = enabled ? solid(214, 176, 92) : solid(90, 84, 76)
        var out = [Quad(texture: edge, x: x, y: y, w: w, h: h),
                   Quad(texture: enabled ? solid(96, 58, 24) : solid(52, 46, 40), x: x + 3, y: y + 3, w: w - 6, h: h - 6)]
        let f = ui?.font(20)
        out += sideText(title, size: 20, colour: enabled ? (255, 236, 200) : (140, 132, 120), x: x, y: y + (h - (f?.size ?? 20)) / 2, width: w, centred: true).0
        return out
    }

    /// The touch sidebar left of the battlefield (an overlay on it when the screen has no room):
    /// the stack to act; the selected enemy with Shoot, its sides to strike from and Attack; or the
    /// place to move to with its turns and Move.
    func combatSidebarQuads(_ cs: CombatScreen, _ b: Battle) -> [Quad] {
        sidebarButtons = []
        var r = sidebarRect
        let overlay = r.w < 300
        if overlay {
            guard combatPick != nil else { return [] }
            r = (8, 8, 330, AdventureUI.height - 16)
        }
        guard let cur = b.current, !cs.showResults, cs.result == nil else { return sidebarPanel(r, overlay) }
        let cream: (UInt8, UInt8, UInt8) = (255, 236, 200), gold: (UInt8, UInt8, UInt8) = (240, 200, 110), grey: (UInt8, UInt8, UInt8) = (170, 160, 150)
        var out = sidebarPanel(r, overlay)
        let x = r.x + 14, w = r.w - 28
        var y = r.y + 14
        // the stack to act
        let own = b.commander(of: cur) == 0
        if let pic = unitPortrait(cur, size: 52) { out.append(image(pic, key: "icon|\(pic.name)", x, y)) }
        let (t1, h1) = sideText(own ? unitName(cur) : "Enemy turn", size: 20, colour: gold, x: x + 62, y: y + 4, width: w - 62)
        out += t1
        out += sideText(own ? "to act: \(cur.move) move a turn" : unitName(cur), size: 14, colour: grey, x: x + 62, y: y + 6 + h1, width: w - 62).0
        y += 64
        out.append(Quad(texture: solid(214, 176, 92, 160), x: x, y: y, w: w, h: 2))
        y += 12
        guard own, combatOrdersOpen(), let p = combatPick, p.unit == cur.id else {
            if own, combatOrdersOpen() {
                for line in ["Tap an enemy to target it: pick the side to strike from, then Attack (or Shoot).",
                             "Tap the ground to see the way there and its turns; tap it again (or Move) to go.",
                             "Hold a stack for its information."] {
                    let (q, h) = sideText(line, size: 16, colour: cream, x: x, y: y, width: w)
                    out += q; y += h + 10
                }
            }
            return out
        }
        let bh = 56, bw = (w - 12) / 2
        if let tid = p.target {
            let t = b.unit(tid)
            if let pic = unitPortrait(t, size: 82) { out.append(image(pic, key: "icon|\(pic.name)", x, y)) }
            let (tn, th) = sideText(unitName(t), size: 23, colour: gold, x: x + 92, y: y + 6, width: w - 92)
            out += tn
            if let s = attackStatusText(b, cur, t, ranged: false) { out += sideText(s.replacingOccurrences(of: "Attack ", with: "Melee: "), size: 14, colour: cream, x: x + 92, y: y + 10 + th, width: w - 92).0 }
            y += 92
            if p.shoot {
                let s = attackStatusText(b, cur, t, ranged: true) ?? ""
                let (q, h) = sideText("Shot: " + s.replacingOccurrences(of: "Attack ", with: ""), size: 14, colour: cream, x: x, y: y, width: w)
                out += q; y += h + 6
                out += sideButton("Shoot", .shoot, x: x, y: y, w: w, h: bh, enabled: true)
                y += bh + 10
                out += sideText("or strike in melee from a side:", size: 14, colour: grey, x: x, y: y, width: w).0
                y += 20
            }
            // the direction picker: the target's footprint in the middle of a 3x3 grid of the
            // battlefield's diamonds, a side of it in each of the other eight
            let hw = min(66, w / 6), hh = hw / 2
            let gh = 6 * hh
            let cx = x + w / 2, cy = y + gh / 2
            func centre(_ gx: Int, _ gy: Int) -> (Int, Int) { (cx + (gy - gx) * hw, cy + (gx + gy) * hh) }
            out.append(Quad(texture: diamond(2 * hw, 2 * hh, fill: (150, 40, 30, 230), edge: (255, 120, 90, 255)), x: cx - hw, y: cy - hh, w: 2 * hw, h: 2 * hh))
            if let pic = unitPortrait(t, size: 52) {
                let s: Float = 0.8
                out.append(image(pic, key: "icon|\(pic.name)", cx - Int(Float(pic.width) * s) / 2, cy - Int(Float(pic.height) * s) / 2, scale: s))
            }
            for (k, side) in p.sides.enumerated() {
                let (sx, sy) = centre(side.gx, side.gy)
                let chosen = p.chosen == k
                let fill: (UInt8, UInt8, UInt8, UInt8) = chosen ? (226, 180, 70, 255) : side.enabled ? (58, 96, 52, 240) : side.place != nil ? (56, 62, 96, 200) : (40, 36, 32, 170)
                let edge: (UInt8, UInt8, UInt8, UInt8) = chosen ? (255, 250, 210, 255) : side.enabled ? (170, 220, 140, 255) : (90, 86, 80, 220)
                let bx = sx - hw + 3, by = sy - hh + 2, dw = 2 * hw - 6, dh = 2 * hh - 4
                out.append(Quad(texture: diamond(dw, dh, fill: fill, edge: edge), x: bx, y: by, w: dw, h: dh))
                sidebarButtons.append(SidebarButton(x: bx, y: by, w: dw, h: dh, diamond: true, action: .side(k), enabled: side.enabled))
                if let pl = side.place, side.enabled, let (l, _) = cursorLayer(Renderer.meleeCursor(pl.angle), frame: 0) {
                    let s = min(1, Float(dh - 8) / Float(max(1, l.height)) * 0.8)
                    out.append(image(l, key: "touchcursor|\(Renderer.meleeCursor(pl.angle))|\(l.name)", sx - Int(Float(l.width) * s) / 2, sy - Int(Float(l.height) * s) / 2 - 6, scale: s))
                    let tag = (side.retaliates ? "ret" : "safe") + (side.extra > 0 ? " +\(side.extra)" : "")
                    out += sideText(tag, size: 12, colour: side.retaliates ? (255, 150, 130) : (170, 255, 150), x: sx - hw, y: sy + hh / 2 - 7, width: 2 * hw, centred: true).0
                } else if side.place != nil, let n = side.turns {
                    out += sideText("\(n) turns", size: 12, colour: grey, x: sx - hw, y: sy - 6, width: 2 * hw, centred: true).0
                }
            }
            y += gh + 8
            // what the picked side means
            var detail = "Pick a side to strike from."
            if let k = p.chosen, p.sides[k].enabled {
                let s = p.sides[k]
                detail = s.retaliates ? "\(unitName(t)) will strike back." : "No retaliation from there."
                if s.extra > 0 { detail += " The blow also hits \(s.extra) more stack\(s.extra > 1 ? "s" : "")." }
                if (s.place!.x, s.place!.y) == (cur.x, cur.y) { detail += " (From where it stands.)" }
            } else if !p.sides.contains(where: { $0.enabled }) {
                detail = "No side to strike from this turn."
            }
            let (dq, dh) = sideText(detail, size: 16, colour: cream, x: x, y: y, width: w)
            out += dq; y += dh + 8
            let by = max(y, r.y + r.h - bh - 14)
            out += sideButton("Attack", .attack, x: x, y: by, w: bw, h: bh, enabled: p.chosen.map { p.sides[$0].enabled } ?? false)
            out += sideButton("Cancel", .cancel, x: x + bw + 12, y: by, w: bw, h: bh, enabled: true)
        } else if let m = p.move {
            out += sideText("Move", size: 23, colour: gold, x: x, y: y, width: w).0
            y += 32
            let lines = [m.today ? "There this turn." : "\(m.turns) turns to get there; this turn it stops on the bright place (the blue part of the way is for later turns).",
                         "The way costs \(Int(m.cost.rounded(.up))) of \(cur.move) move a turn."]
            for line in lines { let (q, h) = sideText(line, size: 16, colour: cream, x: x, y: y, width: w); out += q; y += h + 8 }
            let by = max(y, r.y + r.h - bh - 14)
            out += sideButton("Move", .move, x: x, y: by, w: bw, h: bh, enabled: true)
            out += sideButton("Cancel", .cancel, x: x + bw + 12, y: by, w: bw, h: bh, enabled: true)
        }
        return out
    }
    /// The sidebar's panel: a gold edge round a dark ground.
    private func sidebarPanel(_ r: (x: Int, y: Int, w: Int, h: Int), _ overlay: Bool) -> [Quad] {
        [Quad(texture: solid(214, 176, 92), x: r.x, y: r.y, w: r.w, h: r.h),
         Quad(texture: solid(34, 24, 14, overlay ? 235 : 255), x: r.x + 3, y: r.y + 3, w: r.w - 6, h: r.h - 6)]
    }
    /// The sidebar's button under a frame canvas point (the sidebar must be showing there).
    func sidebarButton(x: Float, y: Float) -> SidebarButton? { sidebarButtons.last { $0.contains(x, y) } }
    /// Is this frame canvas point on the sidebar (its room, or the overlay while it shows)?
    func onSidebar(x: Float, y: Float) -> Bool {
        let r = sidebarRect
        if r.w >= 300 { return x < 0 }
        return combatPick != nil && x >= 8 && x < 338
    }
}

extension MapView {
    /// Canvas pixels per point of the view.
    private var canvasPerPoint: Float { bounds.height > 0 ? Float(AdventureUI.height) / Float(bounds.height) : 1 }
    /// A view point on the frame's canvas pixels.
    private func canvas(_ p: CGPoint) -> (Float, Float) { (Float(p.x) * canvasPerPoint - renderer.pointerShift, Float(p.y) * canvasPerPoint) }

    /// A finger came down: on the battlefield taking orders or on the sidebar the touch is the
    /// battle's (true: its lift selects or acts), else it is the plain mouse. The action before
    /// this touch is kept for the gate: a tap on the same one confirms it.
    func combatTouchDown(_ p: CGPoint) -> Bool {
        guard renderer.inCombat else { return false }
        let c = canvas(p)
        if renderer.onSidebar(x: c.0, y: c.1) { return true }
        guard renderer.combatTouchAims(x: c.0, y: c.1) else { return false }
        renderer.touchBefore = renderer.touchPreview?.action
        return true
    }
    /// The finger lifted (where it came down: a slide changes nothing). On the sidebar: its button.
    /// On an enemy: select it (again: its default, Shoot or Attack). On the ground: show the way
    /// (again on the same place: go). A shot at an unselected stack, a spell's target: at once.
    func combatTouchLifted(_ p: CGPoint, slid: Bool) {
        let c = canvas(p)
        if renderer.onSidebar(x: c.0, y: c.1) {
            if let bt = renderer.sidebarButton(x: c.0, y: c.1), bt.enabled { renderer.sidebarPress(bt.action) }
            return
        }
        guard renderer.combatTouchAims(x: c.0, y: c.1), let b = renderer.combat?.battle, let cur = b.current else { renderer.clearTouchPreview(); return }
        let r = renderer.combatTouchAction(x: c.0, y: c.1)
        let pick = renderer.combatPick
        defer { renderer.touchBefore = nil }
        if r.cursor == "combat.shoot" || r.cursor.hasPrefix("combat.melee"), let t = renderer.enemyUnder(b, x: c.0, y: c.1) {
            if pick?.target == t.id, let p = pick {   // the selected target again: its default action
                renderer.sidebarPress(p.shoot ? .shoot : .attack)
            } else { renderer.pickTarget(t) }
            return
        }
        switch r.action {
        case .none: MapView.touchLog("nothing to do: cancelled"); renderer.clearTouchPreview()
        case .direct: perform(p)
        case .move(let x, let y):
            if let m = pick?.move, (m.x, m.y) == (x, y) { renderer.sidebarPress(.move) }
            else { renderer.pickMove(x, y, cursor: r.cursor, frame: r.frame) }
        case .gate:
            if r.action == renderer.touchBefore { perform(p) } else { aimGate(c, r, cur) }
        case .melee: break   // (an enemy: above)
        }
    }
    func combatTouchCancelled() { renderer.touchBefore = nil }

    /// The gate: show the place the stack would strike it from (a tap on the same again does it).
    private func aimGate(_ c: (Float, Float), _ r: (action: CombatTouchAction, cursor: String, frame: Int?, dest: (Int, Int)?), _ cur: Battle.Unit) {
        renderer.combatPick = nil
        renderer.touchPreview = CombatTouchPreview(action: r.action, unit: cur.id, cursor: r.cursor, frame: r.frame, at: c,
                                                   dest: r.dest.map { ($0.0, $0.1, cur.size) }, path: [])
        hoverPending = nil
        renderer.hover = renderer.combatStatusText(x: c.0, y: c.1).map { (text: $0, x: Int(c.0) - 18, y: Int(c.1) + 36) }
        MapView.touchLog("preview gate: \(r.action)")
    }
    /// The scripted touches (H4TOUCHES) say what the battlefield made of them.
    static func touchLog(_ s: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["H4TOUCHES"] != nil { print("combat touch: \(s())"); fflush(stdout) }
    }
    /// The normal click at the point.
    private func perform(_ p: CGPoint) {
        MapView.touchLog("act at \(Int(canvas(p).0)),\(Int(canvas(p).1))")
        renderer.clearTouchPreview()
        let e = event(p)
        pointerMoved(e); pointerDown(e); pointerUp(e)
        renderer.combatTarget = nil; renderer.combatArea = nil; renderer.hover = nil; hoverPending = nil
    }

    /// Debugging (the simulator): H4TOUCHBATTLE="orc:30,titan:2" starts a battle of the first
    /// hero's army (H4ARMY="devil:5,imp:20" sets it) against those stacks at once.
    func startTouchTestBattle(_ spec: String) {
        guard let g = renderer.game, let cs = renderer.combat, let h = g.heroes.first else { return }
        if let a = ProcessInfo.processInfo.environment["H4ARMY"] {
            h.army = a.split(separator: ",").compactMap { p in let q = p.split(separator: ":"); return q.count == 2 ? Int(q[1]).map { Hero.Stack(creature: String(q[0]), count: $0) } : nil }
        }
        let defenders: [(String, Int)] = spec.split(separator: ",").compactMap { p in
            let q = p.split(separator: ":"); return q.count == 2 ? Int(q[1]).map { (String(q[0]), $0) } : nil }
        cs.startTest(game: g, hero: h, defenders: defenders)
        cs.pump()
        renderer.layoutWide()
        for u in cs.battle?.units ?? [] {
            let (x, y) = CombatScreen.point(u.centre.0, u.centre.1)
            print("test battle: unit \(u.id) \(u.keyword)x\(u.stats.count) side \(u.side) cells (\(u.x),\(u.y)) size \(u.size) centre frame canvas \(Int(x)),\(Int(y)) (frame at canvas x \(Int(renderer.frameOffset)))")
        }
        fflush(stdout)
    }
}
#endif
