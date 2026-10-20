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
}
