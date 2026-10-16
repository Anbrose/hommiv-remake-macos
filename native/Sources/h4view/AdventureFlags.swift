import Foundation
import H4Engine

/// The owner flags as heroes4.exe draws them (re/adventure_flags_spec.md): animation.Flags.<colour>
/// (t_adv_object_flag 0x44b030 / draw 0x44b360) with the frame's box placed at the model's flag
/// point less the animation's anchor (the trailer's (0, 13): the pole's foot at the point), the
/// frame ((ms + phase) / frame time) % 10 through the trailer's order (0x44b1c0).
private var flagInfos: [String: CombatScreen.EffectInfo?] = [:]
private var actorModels: [String: AdvActor?] = [:]

extension Renderer {
    /// The animation of a colour (0 red ... 5 teal) with its trailer.
    func flagInfo(_ colour: Int) -> CombatScreen.EffectInfo? {
        let name = AdventureUI.playerColourNames[colour]
        if let i = flagInfos[name] { return i }
        var info: CombatScreen.EffectInfo? = nil
        if let r = resolver, let e = r.entry("animation.Flags.\(name).h4d"), let d = try? r.archive.payload(e),
           let s = try? Sprite(data: d), !s.images.isEmpty {
            info = CombatScreen.effectTrailer(d, sprite: s)
        }
        flagInfos[name] = .some(info)
        return info
    }

    /// The flag quad for a flag point (px, py) on the screen; nil without a flag for the colour.
    func flagQuad(colour: Int, x px: Int, y py: Int, cellX: Int, cellY: Int, at t: Double) -> Quad? {
        guard (0..<6).contains(colour), let info = flagInfo(colour), !info.order.isEmpty else { return nil }
        let imgs = info.sprite.images
        // the anchor: the trailer's point where it says so, else the middle of the frames' box (0x44b0c3)
        let l = imgs.map { $0.box.left }.min() ?? 0, r = imgs.map { $0.box.right }.max() ?? 0
        let tp = imgs.map { $0.box.top }.min() ?? 0, b = imgs.map { $0.box.bottom }.max() ?? 0
        let ax = info.useX ? info.anchor.0 : l + (r - l) / 2, ay = info.useY ? info.anchor.1 : tp + (b - tp) / 2
        let k = GameState.flagFrame(ms: Int(t * 1000), frameTime: max(1, info.frameTime), frames: info.order.count, cellX: cellX, cellY: cellY, level: game?.level ?? 0)
        let f = imgs[info.order[k]]
        return Quad(texture: texture(for: f, of: "flag|\(colour)"), x: px - ax + f.box.left, y: py - ay + f.box.top, w: f.bitmap.width, h: f.bitmap.height)
    }

    /// An owned object's flag: at its model's flag point from the anchor cell's top vertex.
    func objectFlag(_ p: MapScene.Placed, at t: Double) -> Quad? {
        guard let g = game, let fp = p.sprite.flagPoint, let c = g.flagOwner(of: p) else { return nil }
        return flagQuad(colour: c, x: p.anchorX + fp.x, y: p.anchorY + fp.y, cellX: p.cellX, cellY: p.cellY, at: t)
    }

    /// The adv_actor model of an actor name ("hero.life_might_male", "ships.order").
    func actorModel(_ name: String) -> AdvActor? {
        if let m = actorModels[name] { return m }
        var m: AdvActor? = nil
        if let r = resolver, let e = r.entry("adv_actor.\(name).h4d"), let d = try? r.archive.payload(e) { m = try? AdvActor(data: d) }
        actorModels[name] = .some(m)
        return m
    }

    /// An owned army's flag (0x403ec0): the actor model's flag point from the actor's position,
    /// the point its images are offset from by the model offset. (ix, iy) is where this renderer
    /// puts the images' reference (the cell's top vertex), taken as position + model offset.
    func actorFlag(actor: String, owner: Int, imageX ix: Int, imageY iy: Int, cellX: Int, cellY: Int, at t: Double) -> Quad? {
        guard let m = actorModel(actor), let fp = m.flagPoint else { return nil }
        return flagQuad(colour: owner, x: ix - m.offset.x + fp.x, y: iy - m.offset.y + fp.y, cellX: cellX, cellY: cellY, at: t)
    }
}
