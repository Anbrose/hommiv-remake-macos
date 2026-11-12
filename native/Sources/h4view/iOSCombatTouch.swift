#if os(iOS)
import Foundation
import CoreGraphics
import H4Engine

/// The iPhone's own settings (UserDefaults).
enum IOSSettings {
    /// A combat move needs a second tap on the same place (the first shows where the stack would go).
    static var confirmCombatMoves: Bool {
        get { UserDefaults.standard.object(forKey: "h4view.ios.confirmCombatMoves") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "h4view.ios.confirmCombatMoves") }
    }
}

/// What a press on the battlefield would do, as the combat pointer reads it (Renderer.combatCursor):
/// the same target and place twice is the same action.
enum CombatTouchAction: Equatable {
    case none
    /// A shot or the spell book of a casting stack: no direction to choose, one tap acts.
    case direct
    /// A blow at `target` from the footprint corner (x, y).
    case melee(target: Int, x: Int, y: Int)
    /// A blow at the castle gate from (x, y) ((-1, -1): no place in reach this turn).
    case gate(x: Int, y: Int)
    case move(x: Int, y: Int)
}

/// The action a touch on the battlefield has aimed and not yet done (no hover on a phone: the first
/// tap shows what the mac's pointer would, a second tap on the same action does it).
struct CombatTouchPreview {
    let action: CombatTouchAction
    /// The stack that was to act (another one acting ends the preview).
    let unit: Int
    /// The pointer shown (layers.cursor.<name>) and its frame (nil: the first).
    let cursor: String
    let frame: Int?
    /// Where the pointer's hot spot is drawn (canvas).
    let at: (Float, Float)
    /// The footprint the stack would stand on, and the footprints on its way there.
    let dest: (x: Int, y: Int, size: Int)?
    let path: [(Int, Int)]
}

extension Renderer {
    /// Is the battlefield taking the player's orders at this canvas point, the way a touch aims
    /// (no spell being aimed, no window open, not a panel button)?
    func combatTouchAims(x: Float, y: Float) -> Bool {
        guard let cs = combat, let b = cs.battle, cs.info == nil, prompt == nil, spellBook == nil, optionsOpen == nil, casting == nil,
              !cs.showResults, cs.awaitingOrders, x < Float(cs.hotspot("battle_scene")?.width ?? 885) else { return false }
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
        guard touchPreview != nil else { return }
        touchPreview = nil
        combatTarget = nil; combatArea = nil; hover = nil
    }

    /// The preview ends when its stack no longer waits for orders: another acts, a window opens,
    /// the battle ends (checked every frame).
    func validateTouchPreview(_ cs: CombatScreen, _ b: Battle) {
        guard let p = touchPreview else { return }
        if !cs.awaitingOrders || b.current?.id != p.unit || cs.info != nil || prompt != nil || spellBook != nil || optionsOpen != nil || casting != nil || cs.showResults {
            clearTouchPreview()
        }
    }

    /// The destination's cells (and, lighter, the way there), under the units.
    func touchPreviewGround() -> [Quad] {
        guard let p = touchPreview, let d = p.dest else { return [] }
        var cells: [Int: UInt32] = [:]
        let way = Renderer.rgba(255, 255, 160, 70), there = Renderer.rgba(255, 230, 90, 140)
        func mark(_ x: Int, _ y: Int, _ c: UInt32) {
            for dx in 0..<d.size { for dy in 0..<d.size where Battlefield.onField(x + dx, y + dy) { cells[Battle.key(x + dx, y + dy)] = c } }
        }
        for (x, y) in p.path { mark(x, y, way) }
        mark(d.x, d.y, there)
        return [fieldOverlay("touchpreview", cells)]
    }

    /// The pointer the preview shows (the phone has none of its own): its picture with the hot spot at `at`.
    func touchPreviewCursor() -> [Quad] {
        guard let p = touchPreview, let cs = combat else { return [] }
        let file = p.cursor == "combat.normal" ? "layers.cursor.combat.normal.h4d" : "layers.cursor.\(p.cursor).h4d"
        if touchCursorFiles[file] == nil { touchCursorFiles[file] = .some((try? cs.archive.payload(file)).flatMap { try? LayerFile(data: $0) }) }
        guard let f = touchCursorFiles[file] ?? nil else { return [] }
        let hot = f.layers.first { $0.name.lowercased() == "hot_spot" }
        let frames = f.layers.filter { $0.name.lowercased() != "hot_spot" && $0.width > 0 }
        guard !frames.isEmpty else { return [] }
        let l = frames[min(p.frame ?? 0, frames.count - 1)]
        return [image(l, key: "touchcursor|\(file)|\(l.name)", Int(p.at.0) - (hot?.x ?? 0), Int(p.at.1) - (hot?.y ?? 0))]
    }
}

extension MapView {
    /// Canvas pixels per point of the view.
    private var canvasPerPoint: Float { bounds.height > 0 ? Float(AdventureUI.height) / Float(bounds.height) : 1 }
    private func canvas(_ p: CGPoint) -> (Float, Float) { (Float(p.x) * canvasPerPoint, Float(p.y) * canvasPerPoint) }

    /// A finger came down: on the battlefield taking orders the touch aims (true), else it is the
    /// plain mouse. The action before this touch is kept: a tap on the same one confirms it.
    func combatTouchDown(_ p: CGPoint) -> Bool {
        guard renderer.inCombat else { return false }
        let c = canvas(p)
        guard renderer.combatTouchAims(x: c.0, y: c.1) else { renderer.clearTouchPreview(); return false }
        renderer.touchBefore = renderer.touchPreview?.action
        aim(p, lifted: false)
        return true
    }
    /// The finger slides: the preview follows it.
    func combatTouchSlid(_ p: CGPoint) { aim(p, lifted: false) }
    /// The finger lifted: a slide does what is under it; a tap does a shot at once, else confirms
    /// the action it previewed before (the same target and place), else previews this one.
    func combatTouchLifted(_ p: CGPoint, slid: Bool) {
        let c = canvas(p)
        guard renderer.combatTouchAims(x: c.0, y: c.1) else { renderer.clearTouchPreview(); return }
        let a = renderer.combatTouchAction(x: c.0, y: c.1).action
        switch a {
        case .none: MapView.touchLog("nothing to do: cancelled"); renderer.clearTouchPreview()
        case .direct: perform(p)
        default:
            if slid || a == renderer.touchBefore { perform(p) } else { aim(p, lifted: true) }
        }
        renderer.touchBefore = nil
    }
    func combatTouchCancelled() { renderer.touchBefore = nil; renderer.clearTouchPreview() }

    /// Show what a press at the point would do: the mac's hover there (target shadow, status
    /// line), the pointer (above the finger while it is down) and the place the stack would go.
    private func aim(_ p: CGPoint, lifted: Bool) {
        pointerMoved(PointerEvent(location: CGPoint(x: p.x, y: bounds.height - p.y)))
        let c = canvas(p)
        let r = renderer.combatTouchAction(x: c.0, y: c.1)
        guard r.action != .none, let b = renderer.combat?.battle, let cur = b.current else { renderer.clearTouchPreview(); return }
        let at = (c.0, lifted ? c.1 : max(0, c.1 - 40 * canvasPerPoint))
        var path: [(Int, Int)] = []
        if case .move = r.action, let d = r.dest { path = b.path(cur, to: d.0, d.1) ?? [] }
        renderer.touchPreview = CombatTouchPreview(action: r.action, unit: cur.id, cursor: r.cursor, frame: r.frame, at: at,
                                                   dest: r.dest.map { ($0.0, $0.1, cur.size) }, path: path)
        // the status line at once, by the drawn pointer (the mac's waits for the pointer to rest)
        hoverPending = nil
        renderer.hover = renderer.combatStatusText(x: c.0, y: c.1).map { (text: $0, x: Int(at.0) - 18, y: Int(at.1) + 36) }   // under the pointer, not over it
        MapView.touchLog("preview \(cur.keyword): \(r.action) \(r.cursor) at \(Int(c.0)),\(Int(c.1))")
    }
    /// The scripted touches (H4TOUCHES) say what the battlefield made of them.
    static func touchLog(_ s: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["H4TOUCHES"] != nil { print("combat touch: \(s())"); fflush(stdout) }
    }
    /// The normal click at the point.
    private func perform(_ p: CGPoint) {
        MapView.touchLog("act at \(Int(canvas(p).0)),\(Int(canvas(p).1))")
        renderer.clearTouchPreview()
        let e = PointerEvent(location: CGPoint(x: p.x, y: bounds.height - p.y))
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
        for u in cs.battle?.units ?? [] {
            let (x, y) = CombatScreen.point(u.centre.0, u.centre.1)
            print("test battle: unit \(u.id) \(u.keyword)x\(u.stats.count) side \(u.side) cells (\(u.x),\(u.y)) size \(u.size) centre canvas \(Int(x)),\(Int(y))")
        }
        fflush(stdout)
    }
}
#endif
