import Foundation

/// Owner flags on the adventure map (re/adventure_flags_spec.md). heroes4.exe gives an object a
/// flag (t_adv_object_flag, ctor 0x44b030) when its model has a flag point and its owner is a
/// player colour (6 = none: no flag, 0x411a40 / 0x403ec0): towns, mines, dwellings, garrisons,
/// weekly generators, and every owned army (heroes, ships) at its actor model's flag point.
extension GameState {
    /// The player colour (0 red ... 5 teal) owning a placed object, nil when it is neutral or
    /// not an ownable object here.
    public func flagOwner(of p: MapScene.Placed) -> Int? {
        let z = level
        if let t = towns.first(where: { $0.z == z && $0.x == p.cellX && $0.y == p.cellY }) { return colour(t.owner) }
        if let m = mines.first(where: { $0.z == z && $0.x == p.cellX && $0.y == p.cellY }) { return colour(m.owner ?? (m.owned ? map.humanColour : nil)) }
        if let d = dwellings.first(where: { $0.z == z && $0.x == p.cellX && $0.y == p.cellY }) { return colour(d.owner ?? (d.owned ? map.humanColour : nil)) }
        if let s = objectStates[objectKey(p)] { return colour(s.isGarrison ? s.garrisonOwner : s.owner) }
        return nil
    }

    private func colour(_ c: Int?) -> Int? { c.flatMap { (0..<6).contains($0) ? $0 : nil } }

    /// A flag's frame at a time (0x44b1c0): ((ms + phase) / frame time) % frames, the phase drawn
    /// once per flag in 0 ..< frames x frame time (rand() % ..., 0x44b0f8); here from the
    /// object's cell so it stays put from frame to frame.
    public static func flagFrame(ms: Int, frameTime: Int, frames: Int, cellX: Int, cellY: Int, level: Int = 0) -> Int {
        guard frames > 0, frameTime > 0 else { return 0 }
        var h = UInt32(truncatingIfNeeded: cellX &* 73856093 ^ cellY &* 19349663 ^ level &* 83492791)
        h = (h ^ (h >> 13)) &* 0x5bd1e995
        let phase = Int(h % UInt32(frames * frameTime))
        return ((ms + phase) / frameTime) % frames
    }
}
