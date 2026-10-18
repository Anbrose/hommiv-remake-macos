import Foundation

/// What a right click on the adventure map may tell about an army, a town or a quest
/// (re/town_popup_spec.md).
extension GameState {
    /// Is a colour the player's or an ally's (the same team)?
    func isPlayerSide(_ colour: Int) -> Bool {
        let me = map.humanColour
        return colour == me || (map.teams[me] != nil && map.teams[colour] == map.teams[me])
    }

    /// The information level of an object for the player (heroes4.exe 0x4faf40): -1 when its
    /// first footprint cell is not in sight now; 4 when the player or an ally owns it; else the
    /// best Scouting level (-1 none, 0 basic ... 4 grandmaster; at least 3 under Visions) of a
    /// hero of the player's armies on that map level whose sight radius (10 + Scouting level +
    /// worn bonuses, 0x72a2b0) reaches the cell (straight-line distance); -1 when none does.
    /// Creatures count with radius 9 and level -1, so they never raise it.
    public func infoLevel(x: Int, y: Int, z: Int, owner: Int?) -> Int {
        guard fogState(x, y, level: z) == GameState.fogSeen else { return -1 }
        if let o = owner, isPlayerSide(o) { return 4 }
        var best = -1
        for a in heroes where a.z == z {
            let d = Double((a.x - x) * (a.x - x) + (a.y - y) * (a.y - y)).squareRoot()
            for m in a.members where !m.actor.isEmpty {
                let s = m.skill("scouting") - 1
                guard Double(10 + s + m.artifactSum(0x26)) >= d else { continue }
                best = max(best, s < 3 && m.timedEffects["spell.visions"] != nil ? 3 : s)
            }
        }
        return best
    }

    /// The first cell of a placed object's footprint that it occupies, scanned x outer, y inner
    /// as 0x4faf40 does (the anchor cell when the footprint is unknown).
    func firstOccupiedCell(_ p: MapScene.Placed) -> (Int, Int) {
        let occupied = Set(p.sprite.blocked.map { $0.x * 1024 + $0.y })
        for i in 0..<p.sprite.footprint.w { for j in 0..<p.sprite.footprint.h where occupied.contains(i * 1024 + j) { return (p.cellX + i, p.cellY + j) } }
        return (p.cellX, p.cellY)
    }

    /// The information level of a placed object on the level in view (a garrison, a quest).
    public func infoLevel(_ p: MapScene.Placed, owner: Int?) -> Int {
        let (x, y) = firstOccupiedCell(p)
        return infoLevel(x: x, y: y, z: level, owner: owner)
    }
    /// The information level of a town for the player.
    public func infoLevel(town i: Int) -> Int {
        let t = towns[i]
        let p = scenes.indices.contains(t.z) ? scenes[t.z].placed.first { $0.category == "castle" && $0.cellX == t.x && $0.cellY == t.y } : nil
        let (x, y) = p.map(firstOccupiedCell) ?? (t.x, t.y)
        return infoLevel(x: x, y: y, z: t.z, owner: townColour(t))
    }
    /// The information level of an army (its own cell) for the player.
    public func infoLevel(army h: Hero) -> Int {
        infoLevel(x: h.x, y: h.y, z: h.z, owner: heroes.contains { $0 === h } ? map.humanColour : h.owner)
    }

    /// The right-click text of a quest hut, gate or guard (0x7ee020): unless the player's colour
    /// has visited it or a scout sees it (information level >= 0), its table `help`; else, until
    /// the colour has completed it, the quest's objective text (+0x70); then the table's
    /// `completed`. Only the text: no title (0x845200).
    public func questHelp(_ p: MapScene.Placed) -> String? {
        let st = objectStates[objectKey(p)] ?? ObjectState()
        let me = map.humanColour
        if !st.questVisited.contains(me), infoLevel(p, owner: nil) < 0 { return objectText(p, "help") }
        if !st.questDone.contains(me) { return record(for: p).flatMap { $0.questTexts.count > 1 ? $0.questTexts[1] : nil } ?? objectText(p, "help") }
        return objectText(p, "completed")
    }
}
