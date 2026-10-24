import Foundation

/// Keymaster's tents, border gates and border guards (re/keymaster_spec.md).
///
/// A player's keys are one byte per colour at player +0xec (0x7e10c0 reads, 0x7e10a0 sets); the
/// colours are the objects' subtypes (blue, green, purple, red, teal, yellow; the "Orange" gate
/// models are yellow). A gate stays on the map: for an army whose player holds its key it is
/// open ground (its passage cell neither stops a route, vtable+0x18 = 0x4393c0, nor is entered,
/// +0x4c = 0x439400), for anyone else the passage is a stop the route ends on and the bump says
/// "Denied". A guard is a solid object that goes away -- with the chains next to it -- once a
/// key holder says yes.
extension GameState {
    public func hasKey(_ colour: Int, _ keyColour: String) -> Bool { keys[colour]?.contains(keyColour) ?? false }

    /// The passage cells of every border gate (its footprint's trigger cells), by level.
    var borderGatePassages: [(z: Int, x: Int, y: Int, colour: String)] {
        if let c = borderGateCache { return c }
        var out: [(z: Int, x: Int, y: Int, colour: String)] = []
        for (z, s) in scenes.enumerated() where z < passabilities.count {
            for p in s.placed where p.type == "border_gate" {
                for i in 0..<p.sprite.footprint.w { for j in 0..<p.sprite.footprint.h where passabilities[z].isTrigger(p.cellX + i, p.cellY + j) {
                    out.append((z, p.cellX + i, p.cellY + j, p.subtype))
                } }
            }
        }
        borderGateCache = out
        return out
    }

    /// Shut or open every border gate as the planner sees it for an army of `colour`
    /// (0x4cbc10 asks the gate with the army): shut without the gate's key, open with it.
    func applyBorderGates(for colour: Int) {
        for g in borderGatePassages { passabilities[g.z].setStop(g.x, g.y, !hasKey(colour, g.colour)) }
    }

    /// A keymaster's tent visited (t_adv_keymaster_tent 0x443310): the player's key of its
    /// colour. Only a human player sees and hears it -- sound 17, then "Initial" the first time
    /// or "Empty" when the key is held already.
    func visitKeymaster(_ hero: Hero, _ p: MapScene.Placed) {
        let human = hero.owner == map.humanColour
        if human { dialogueSound(17) }
        if hasKey(hero.owner, p.subtype) { if human { say(p, "Empty") }; return }
        keys[hero.owner, default: []].insert(p.subtype)
        if human { say(p, "Initial") }
        applyBorderGates(for: hero.owner)
    }

    /// The tent's keymaster name for a gate's or guard's "Denied" text (0x465e30(0x25, colour)).
    func keymasterName(_ colour: String) -> String {
        tables?.objectText("keymaster_tent", colour, "name") ?? "Keymaster's Tent"
    }

    /// A border gate bumped (0x438f90): only a human player without the key is told "Denied"
    /// (then sound 17). The gate never goes away; with the key it is not bumped at all.
    func visitBorderGate(_ hero: Hero, _ p: MapScene.Placed) {
        guard hero.owner == map.humanColour, !hasKey(hero.owner, p.subtype) else { return }
        say(p, "Denied", ["%keymaster_tent_name": keymasterName(p.subtype)])
        dialogueSound(17)
    }

    /// A border guard bumped (0x4396e0). A computer player with the key passes at once, without
    /// it nothing happens. A human player without the key is told "Denied"; with it he is asked
    /// "Accepted" and a yes takes the guard away. Both play sound 17.
    func visitBorderGuard(_ hero: Hero, _ p: MapScene.Placed) {
        let key = hasKey(hero.owner, p.subtype)
        guard hero.owner == map.humanColour else { if key { openBorderGuard(p) }; return }
        dialogueSound(17)
        if key { question = (objectText(p, "Accepted") ?? "", { [weak self] in self?.openBorderGuard(p) }) }
        else { say(p, "Denied", ["%keymaster_tent_name": keymasterName(p.subtype)]) }
    }

    /// The guard goes, and with it every chain joined to it (0x439d70): from each removed object
    /// the cells around its footprint, corners left out, are searched for chain objects, which
    /// are removed and searched from in turn.
    func openBorderGuard(_ p: MapScene.Placed) {
        var queue = [p]
        remove(p)
        while !queue.isEmpty {
            let o = queue.removeFirst()
            let w = o.sprite.footprint.w, h = o.sprite.footprint.h
            for dx in -1...w { for dy in -1...h where !((dx == -1 || dx == w) && (dy == -1 || dy == h)) {
                let c = (o.cellX + dx, o.cellY + dy)
                while let q = scene.placed.first(where: { $0.type == "chain" && covers($0, c) }) { remove(q); queue.append(q) }
            } }
        }
    }

    private func covers(_ p: MapScene.Placed, _ c: (Int, Int)) -> Bool {
        c.0 >= p.cellX && c.0 < p.cellX + p.sprite.footprint.w && c.1 >= p.cellY && c.1 < p.cellY + p.sprite.footprint.h
    }

    /// What a right click on a tent says (0x443730): its name, and "visited.object" under it
    /// when the player holds its key.
    func keymasterInfo(_ p: MapScene.Placed) -> (title: String, body: [String]) {
        let name = tables?.objectText(p.type, p.subtype, "name") ?? GameState.shortName(p.name)
        return (name, hasKey(map.humanColour, p.subtype) ? [text("visited.object", "(Visited)")] : [])
    }
}
