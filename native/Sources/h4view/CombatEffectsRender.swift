import Foundation
import Metal
import H4Engine

/// Drawing the combat screen's spell effects, missiles and field actors (spell_visuals_spec 2.4-2.5,
/// missiles_spec 3.6, area_spells_spec 0.2).
extension Renderer {
    /// A combat actor's frame (a missile, a burst, a cloud) with its origin on a ground point (cells)
    /// raised by `z` world units (1 scene px each, before the 0.75 scale); the draw offset applied.
    func fieldActorQuads(_ cs: CombatScreen, model: String, state: String, facing: String, frame k: Int, at p: (Float, Float), z: Float) -> [Quad]? {
        guard let (s, entry) = combatSprite(cs, actor: model, state: state, facing: facing) else { return nil }
        let sc = CombatScreen.sceneScale
        let tl = s.timeline
        let frame: SpriteImage?, shadow: SpriteImage?
        if tl.isEmpty { frame = s.frames.first; shadow = frame.flatMap { s.shadow(for: $0) } }
        else { let e = tl[max(0, k) % tl.count]; frame = e.frame; shadow = e.shadow }
        let (px, py) = CombatScreen.point(p.0, p.1)
        let off: (x: Int, y: Int) = cs.actor(model)?.drawOffset ?? (0, 0)
        let ox = px + Float(Int(s.origin.x) + off.x) * sc, oy = py - z * sc + Float(Int(s.origin.y) + off.y) * sc
        var q: [Quad] = []
        if let sh = shadow { q.append(Quad(texture: texture(for: sh, of: entry), x: Int(ox + Float(sh.box.left) * sc), y: Int(oy + Float(sh.box.top) * sc), w: max(1, Int(Float(sh.bitmap.width) * sc)), h: max(1, Int(Float(sh.bitmap.height) * sc)))) }
        if let fr = frame { q.append(Quad(texture: texture(for: fr, of: entry), x: Int(ox + Float(fr.box.left) * sc), y: Int(oy + Float(fr.box.top) * sc), w: max(1, Int(Float(fr.bitmap.width) * sc)), h: max(1, Int(Float(fr.bitmap.height) * sc)))) }
        if ProcessInfo.processInfo.environment["H4ANIMLOG"] != nil { print("  draw \(model) \(state) \(facing) at \(p) z \(z): " + q.map { "(\($0.x),\($0.y) \($0.w)x\($0.h))" }.joined(separator: " ")) }
        return q
    }

    /// The scaled box of an effect image (0x80f0c0): k = (int)(0.75 x 1024) = 768; left and top
    /// k >> 10 down, right and bottom rounded up.
    static func scaledBox(_ b: (left: Int, top: Int, right: Int, bottom: Int)) -> (Int, Int, Int, Int) {
        let k = Int(CombatScreen.sceneScale * 1024)
        return (b.left * k >> 10, b.top * k >> 10, (b.right * k + 1023) >> 10, (b.bottom * k + 1023) >> 10)
    }

    /// One effect window's quad: the image of step `step`, anchored on the stack (0x5f6fe0): the
    /// projected footprint centre raised by the actor's height; the anchor (scaled, truncated) where
    /// the file flags it, else the centre of the width and the bottom; a window shorter than 350 px
    /// never starts above the battlefield's top.
    func effectQuad(_ cs: CombatScreen, _ info: CombatScreen.EffectInfo, step: Int, on u: Battle.Unit, key: String) -> Quad? {
        let images = info.sprite.images
        guard !info.order.isEmpty else { return nil }
        let idx = info.order[max(0, min(info.order.count - 1, step))]
        guard idx < images.count else { return nil }
        let img = images[idx]
        let sc = CombatScreen.sceneScale
        let pos = cs.unitPos[u.id] ?? cs.shownPos[u.id] ?? (Float(u.x), Float(u.y))
        let (cx, cy) = CombatScreen.point(pos.0 + Float(u.size) / 2, pos.1 + Float(u.size) / 2)
        let sx = Int(cx), sy = Int(cy - Float(cs.actor(u.actor)?.height ?? 0) * sc)
        // the union of every image box, scaled
        let L = images.map { $0.box.left }.min() ?? 0, T = images.map { $0.box.top }.min() ?? 0
        let R = images.map { $0.box.right }.max() ?? 0, B = images.map { $0.box.bottom }.max() ?? 0
        let ub = Renderer.scaledBox((L, T, R, B))
        let w = ub.2 - ub.0, h = ub.3 - ub.1
        let ox = info.useX ? Int(Float(info.anchor.0) * sc) : w >> 1
        let oy = info.useY ? Int(Float(info.anchor.1) * sc) : h
        let winX = sx - ox
        var winY = sy - oy
        if winY < 0, h < 350 { winY = 0 }
        let fb = Renderer.scaledBox(img.box)
        return Quad(texture: texture(for: img, of: key), x: winX + fb.0, y: winY + fb.1, w: max(1, fb.2 - fb.0), h: max(1, fb.3 - fb.1))
    }

    /// The effect windows over the field: the one-shots playing, then the looping status windows of
    /// berserk and hypnotized stacks (0x5f7150: berserk_effect / hypnotize_effect at a fixed 100 %
    /// speed, only while the stack shows and no one-shot plays on it).
    func effectWindowQuads(_ cs: CombatScreen, _ b: Battle, now: Date) -> [Quad] {
        var out: [Quad] = []
        for u in b.units where cs.shownAlive(u) && !cs.windowBusy.contains(u.id) {
            let name: String
            if u.stats.effects.contains(6) { name = "berserk_effect" }
            else if u.hypnotized || u.stats.effects.contains(62) || u.stats.effects.contains(138) { name = "hypnotize_effect" }
            else { continue }
            guard let info = cs.effectInfo(name) else { continue }
            let step = Int(now.timeIntervalSince1970 * 1000) / cs.effectStep(info, speed: 100) % max(1, info.order.count)
            if let q = effectQuad(cs, info, step: step, on: u, key: "spell.\(name)") { out.append(q) }
        }
        for w in cs.windows {
            guard let info = cs.effectInfo(w.name), b.units.contains(where: { $0.id == w.unit }) else { continue }
            let step = Int(max(0, now.timeIntervalSince(w.since)) * 1000) / cs.effectStep(info)
            if let q = effectQuad(cs, info, step: step, on: b.unit(w.unit), key: "spell.\(w.name.lowercased())") { out.append(q) }
        }
        return out
    }
}
