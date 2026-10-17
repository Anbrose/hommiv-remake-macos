import Foundation

/// An Eye of the Magi a Window of the Magi shows: its anchor cell, footprint and map level.
public struct MagiEye: Equatable {
    public let level: Int, x: Int, y: Int, w: Int, h: Int
}

/// A Window of the Magi being played to the player (0x842ef0 ticks): the eyes of its colour in map
/// order, the next one to show and the one in full sight now.
public struct MagiView {
    public let eyes: [MagiEye]
    public var next = 0
    public var showing: MagiEye?
    /// Seconds each eye stays in view (the idle processor's period, 0x748b00(1, 0xbb8)).
    public static let period = 3.0
}

/// The shroud removers -- tower, cartographer, Window of the Magi (hut_of_the_magi) -- as
/// heroes4.exe's t_tower / t_cartographer / t_magi_hut do it (re/window_of_the_magi_spec.md).
extension GameState {
    /// Has this player (colour) visited the object (bit set at +0x48, 0x842010)?
    func shroudVisited(_ key: String, by colour: Int) -> Bool { shroudVisits[key]?.contains(colour) ?? false }
    /// The computer's interest (0x842120): 750 until the player has been there, then nothing.
    func shroudRemoverValue(_ p: MapScene.Placed, for colour: Int) -> Float {
        shroudVisited(objectKey(p), by: colour) ? 0 : 750
    }

    /// Tower and cartographer (0x8423b0): the view explored for whoever comes (+0xb4), then a human
    /// player's message (+0xb8): first_visit / re_visit.shroud_removers with the object's name, sound 26.
    func visitLookout(_ hero: Hero, _ p: MapScene.Placed) {
        let key = objectKey(p), colour = actingColour, before = shroudVisited(key, by: colour)
        if !before { shroudVisits[key, default: []].append(colour) }
        guard isHumanActing else { return }   // (only the player's sight is kept)
        // a lookout explores 24 cells round it; a cartographer water within 36 and land within 24
        let (w, h) = (p.sprite.footprint.w, p.sprite.footprint.h)
        if p.type == "tower" { explore(level: level, x: p.cellX, y: p.cellY, w: w, h: h, radius: 24) }
        else {
            explore(level: level, x: p.cellX, y: p.cellY, w: w, h: h, radius: 36, terrain: 2)
            explore(level: level, x: p.cellX, y: p.cellY, w: w, h: h, radius: 24, terrain: 1)
        }
        let name = objectText(p, "name") ?? (p.type == "tower" ? "Tower" : "Cartographer's Tower")
        let t = before ? text("re_visit.shroud_removers", "You lean back, letting a cool breeze dry your sweaty brow as you admire the spectacular view from the top of this %name.")
                       : text("first_visit.shroud_removers", "Your legs feel like rubber after climbing all the way to the top of this %name, but look at that view!  Simply breathtaking!")
        scripts.messages.append(t.replacingOccurrences(of: "%name", with: name))
        dialogueSound(26)
    }

    /// The Eyes of the Magi of a colour, in the map's object order (the map's eye list, 0x4dbc00).
    public func magiEyes(_ colour: String) -> [MagiEye] {
        scenes.indices.flatMap { l in
            scenes[l].placed.filter { $0.type == "eye_of_the_magi" && $0.subtype == colour }.map { ($0.seq, l, $0) }
        }.sorted { $0.0 < $1.0 }.map { MagiEye(level: $0.1, x: $0.2.cellX, y: $0.2.cellY, w: $0.2.sprite.footprint.w, h: $0.2.sprite.footprint.h) }
    }

    /// Window of the Magi (0x842b60): a computer player's eyes are explored at once (0x842de0);
    /// a human gets the first / re-visit message (sound 26), then each eye of the window's colour
    /// in turn, 3 s in full sight with the view on it, and the view back where it was.
    func visitMagiHut(_ hero: Hero, _ p: MapScene.Placed) {
        let key = objectKey(p), colour = actingColour, before = shroudVisited(key, by: colour)
        if !before { shroudVisits[key, default: []].append(colour) }
        guard isHumanActing else { return }   // (the computer's sight is not kept)
        scripts.messages.append(before ? text("re_visit_magi.shroud_removers", "Again, the Window of the Magi reveals a far off land.")
                                       : text("first_visit_magi.shroud_removers", "You stare into the magical images hovering before the Window of the Magi.  At first, everything is blurry as if you're underwater.  Then the image clears and you realize you're looking at some far off land."))
        dialogueSound(26)
        magiView = MagiView(eyes: magiEyes(p.subtype))
    }

    /// One tick of the Window of the Magi (0x842f80 mode 2): the eye in sight falls back to explored
    /// (0x4e0a60) and the next one comes into full sight, radius 9 (0x4e10d0 state 2). Returns the
    /// eye the view jumps to, nil when all have been shown (the playback is over).
    public func magiViewStep() -> MagiEye? {
        guard var v = magiView else { return nil }
        if v.showing != nil { v.showing = nil; updateVision() }
        guard v.next < v.eyes.count else { magiView = nil; return nil }
        let e = v.eyes[v.next]
        v.next += 1; v.showing = e
        magiView = v
        reveal(level: e.level, x: e.x, y: e.y, w: e.w, h: e.h, radius: 9, state: GameState.fogSeen, vision: -1)
        visionChanged = true
        return e
    }

    /// Input during the playback (0x842e70: step(1) to the end): the eye in sight falls back to
    /// explored, the remaining ones are explored at once.
    public func magiViewFinish() {
        guard let v = magiView else { return }
        if v.showing != nil { updateVision() }
        for e in v.eyes[min(v.next, v.eyes.count)...] { explore(level: e.level, x: e.x, y: e.y, w: e.w, h: e.h, radius: 9) }
        magiView = nil
    }
}
