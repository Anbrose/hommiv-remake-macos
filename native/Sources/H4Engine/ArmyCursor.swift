import Foundation

extension GameState {
    /// The pointer over an army on a cell, as heroes4.exe's t_army gives it (vtable+0x20,
    /// 0x521360), whatever the media -- a ship on the water from the shore included:
    /// - the selected army's own player or an ally (the same team, player +0x2b8): "exchange"
    ///   (adventure window +0x14c), an empty ship of theirs too;
    /// - an empty army with a ship (no creature in its 7 slots, 0x63fcb0; ship +0xbc set):
    ///   "Boat_Activate" when the selected army is aboard (vtable+0x38, 0x4f8b80), else
    ///   "activate" (+0xec / +0xe4);
    /// - any other army: "attack" (+0xfc).
    /// nil when no army the player knows of stands there (an enemy must be seen).
    public func armyCursor(for h: Hero, at x: Int, _ y: Int) -> String? {
        func friendly(_ owner: Int?) -> Bool { owner.map { $0 == h.owner || team(of: $0) == team(of: h.owner) } ?? false }
        if let e = enemyAt(x, y) { return isVisible(e) ? (friendly(e.owner) ? "exchange" : "attack") : nil }
        if heroes.contains(where: { $0 !== h && $0.z == level && standingCell($0) == (x, y) }) { return "exchange" }
        if let b = boat(at: x, y) {
            if fogEnabled, fogState(x, y) == GameState.fogUnexplored { return nil }
            return friendly(boats[b].owner) ? "exchange" : (h.boat != nil ? "Boat_Activate" : "activate")
        }
        return nil
    }

    /// The pointer over a cell no army stands on for an army aboard a ship (0x4f6780, the
    /// adventure window's cursors of 0x4f4d2f..0x4f4db3): with a route afloat there (the same
    /// planner the click uses, 0x4f7300) "Anchor" (+0xf4) when the route ends on land (0x405350:
    /// the landing) and "Boat_Move" (+0x134) on the water; no route: "blocked" (+0x124).
    public func afloatMoveCursor(for h: Hero, at x: Int, _ y: Int) -> String {
        preparePlanner(for: h)
        guard h.boat != nil, passability.path(from: standingCell(h), to: (x, y), afloat: true) != nil else { return "blocked" }
        return passability.isSea(x, y) ? "Boat_Move" : "Anchor"
    }

    /// The pointer over an ownable object, as its vtable+0x20 gives it (the selected army's
    /// owner against the object's, 0x44c930; "friendly" = the same player, or both owned and on
    /// one team, player +0x2b8; "activate" is "Boat_Activate" aboard, 0x4f8b80):
    /// - a town (t_town, 0x894e60): friendly "activate", any other -- neutral, enemy, with or
    ///   without a garrison -- "attack" (+0xfc);
    /// - a garrison or a mine (t_adv_garrison / t_mine, 0x4429e0): friendly or holding no
    ///   creature (0x63fcb0 on +0x54) "activate", else "attack".
    /// nil for other objects (dwellings and the rest keep 0x4fa6b0's plain "activate").
    public func ownedObjectCursor(for h: Hero, _ p: MapScene.Placed) -> String? {
        func friendly(_ o: Int?) -> Bool { o == h.owner || o.map { team(of: $0) == team(of: h.owner) } ?? false }
        let activate = h.boat != nil ? "Boat_Activate" : "activate"
        if let i = town(for: p) { return friendly(towns[i].owner) ? activate : "attack" }
        if let i = mine(for: p) { return friendly(mines[i].owner) || !mines[i].guards.contains { $0.count > 0 } ? activate : "attack" }
        if let st = objectStates[objectKey(p)], st.isGarrison {
            return friendly(st.garrisonOwner) || !st.troopCounts.contains { $0 > 0 } ? activate : "attack"
        }
        return nil
    }
}
