import Foundation
import H4Engine

/// The computer players' turns on the screen (re/ai_turn_display_spec.md): End Turn flips the
/// hourglass and starts them (GameState.beginEndTurn); while one plays, its progress box stands at
/// the bottom of the screen, the map and the panel take no input, and the view follows a walking
/// army that leaves the middle of the map window.
extension Renderer {
    /// End Turn (the button, Enter, E).
    func endTurn() {
        guard let g = game, g.computerTurn == nil else { return }
        endTurnFlip = Date()
        g.beginEndTurn()
    }

    /// The computer players are playing and nothing of the player's is open (a battle they started,
    /// its messages, a level up): clicks and keys on the map and the panel do nothing (inferred).
    var computerTurnBusy: Bool {
        guard let g = game, g.computerTurn != nil else { return false }
        return !inCombat && prompt == nil && g.levelUp == nil && g.booty == nil && g.scripts.messages.isEmpty
    }

    /// t_ai_progress_bar (0x479c10): a t_basic_dialog holding one picture, the t_progress_bar
    /// (layers.icons.progress_bar, the player's colour filling it as its armies have moved,
    /// 0x7e8740), with the colour's name ("<colour>.color") as its caption (0x5584b0); centred
    /// across the screen, its bottom on the screen's bottom (0x479d45).
    func computerTurnQuads() -> [Quad] {
        guard let g = game, let t = g.computerTurn, t.animated, let c = t.colour, !inCombat, townOpen == nil,
              let f = progressBarLayers else { return [] }
        let key = Renderer.colourKeys[min(max(0, c), Renderer.colourKeys.count - 1)]
        func l(_ n: String) -> UILayer? { f.layers.first { $0.name.lowercased() == n } }
        let W = 200, H = 20
        let track = l("bar")
        let fillW = (track?.width ?? 198) * min(t.moved, t.armies) / max(1, t.armies)
        let picture = UILayer(name: "progress|\(key)|\(fillW)", kind: 4, x: 0, y: 0, width: W, height: H, bitmap: {
            var bm = Bitmap(width: W, height: H)
            if let b = track { AdventureUI.blend(b.bitmap, onto: &bm, x: b.x, y: b.y) }
            if let fill = l(key), fillW > 0 { AdventureUI.blend(Renderer.crop(fill.bitmap, x: 0, y: 0, w: min(fillW, fill.width), h: fill.height), onto: &bm, x: fill.x, y: fill.y) }
            for n in ["top", "bottom", "left", "right"] { if let e = l(n) { AdventureUI.blend(e.bitmap, onto: &bm, x: e.x, y: e.y) } }
            return bm
        }())
        let name = g.tables?.strings["\(key).color"] ?? key.capitalized
        guard let d = basicDialog(text: "", items: [(picture, name)]) else { return [] }
        return basicDialogQuads(d, x: (AdventureUI.width - d.W) / 2, y: AdventureUI.height - d.H)
    }

    /// The view follows a shown walk (t_army_mover's cell switch 0x545d90): when the army moves
    /// onto its next cell (half a step) and that cell's top vertex lies outside the map window less
    /// 256 pixels each side (at least a 64-pixel band in the middle, 0x4f7700), the view centres
    /// on the cell (0x4f9060), on the army's level.
    func followWalkingArmies() {
        guard let g = game, !inCombat, townOpen == nil, ui != nil else { followCells = [:]; return }
        var walkers = g.heroes.filter { $0.isWalking && $0.walkAnim != nil && $0.z == g.level }
        if let w = g.computerTurn?.walk, w.shown { walkers.append(w.hero) }
        var seen: [ObjectIdentifier: (x: Int, y: Int)] = [:]
        for h in walkers {
            let id = ObjectIdentifier(h), c = h.drawCell
            seen[id] = c
            guard let last = followCells[id], last != c else { continue }   // (not at the walk's start)
            if !inFollowArea(c) {
                if g.level != h.z { g.level = h.z }
                centre(onCell: c)
            }
        }
        followCells = seen
    }

    /// 0x4f77c0 / 0x4f7700: the cell's top vertex inside the map window shrunk by 256 pixels.
    func inFollowArea(_ c: (x: Int, y: Int)) -> Bool {
        let w = mapWindow, (sx, sy) = scene.screen(x: c.x, y: c.y)
        let v0 = pan + w.min / zoom, v1 = pan + w.max / zoom
        var l = v0.x + 256, r = v1.x - 256, t = v0.y + 256, b = v1.y - 256
        if b - t < 64 { let m = ((t + b) / 2).rounded(.towardZero); t = m - 32; b = m + 32 }
        if r - l < 64 { let m = ((l + r) / 2).rounded(.towardZero); l = m - 32; r = m + 32 }
        let px = Float(sx), py = Float(sy - 16)
        return px >= l && px < r && py >= t && py < b
    }
}
