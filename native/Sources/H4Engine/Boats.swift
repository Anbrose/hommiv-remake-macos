import Foundation

/// Ships (heroes4.exe: a boat is an army with a ship alignment, army+0xc8): an empty one waits on
/// the water; an army stepping onto it boards (its movement gone for the day unless it has the
/// Seaman's Hat), sails water cells only, and landing leaves the empty ship behind. At sea an army
/// moves 15 cells, a hero 15 x 100/125/150/200/250/300% by Seamanship, +10 with a lighthouse.
public struct Boat: Codable {
    public var x: Int, y: Int, z: Int
    public var alignment: String
    public var owner: Int?
}

extension GameState {
    static let seaTable = [100, 125, 150, 200, 250, 300]

    public func boat(at x: Int, _ y: Int) -> Int? { boats.firstIndex { $0.z == level && $0.x == x && $0.y == y } }

    /// Movement at sea (0x642740): the best of 15 per stack and the heroes' seamanship, +10 with a lighthouse.
    func seaMovement(_ h: Hero) -> Float {
        var best: Float = h.army.isEmpty && h.companions.isEmpty ? 0 : 15
        for hh in [h] + h.companions {
            let items = hh.artifactEffects.filter { $0.type == 0x00 && $0.sea }.reduce(0) { $0 + $1.amount }
            best = max(best, 0.15 * Float(GameState.seaTable[min(5, hh.skill("seamanship"))] + items))
        }
        let team = map.teams[h.owner]
        let lighthouse = objectStates.values.contains { $0.countdown == -1 && $0.owner != nil && ($0.owner == h.owner || (team != nil && map.teams[$0.owner!] == team)) }
        return best + (lighthouse ? 10 : 0)
    }
    /// The Seaman's Hat (effect 0x28): no movement lost boarding or landing.
    func keepsMovementBoarding(_ h: Hero) -> Bool { ([h] + h.companions).contains { hh in hh.artifactEffects.contains { $0.type == 0x28 } } }

    /// A water route (8 neighbours, x1.4 diagonally) over free water to `goal`.
    public func seaPath(from s: (Int, Int), to goal: (Int, Int), landingAt land: (Int, Int)? = nil) -> [(x: Int, y: Int)]? {
        let n = map.size
        guard passability.isFreeWater(goal.0, goal.1) || boat(at: goal.0, goal.1) != nil && goal == s else { return nil }
        var dist = [Float](repeating: .infinity, count: n * n), prev = [Int](repeating: -1, count: n * n)
        dist[s.0 * n + s.1] = 0
        var open: [(Float, Int)] = [(0, s.0 * n + s.1)]
        while !open.isEmpty {
            open.sort { $0.0 > $1.0 }
            let (c, k) = open.removeLast()
            if c > dist[k] { continue }
            let x = k / n, y = k % n
            if (x, y) == goal { break }
            for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard passability.isFreeWater(nx, ny) else { continue }
                let nc = c + (dx != 0 && dy != 0 ? 1.4 : 1)
                if nc < dist[nx * n + ny] { dist[nx * n + ny] = nc; prev[nx * n + ny] = k; open.append((nc, nx * n + ny)) }
            } }
        }
        guard dist[goal.0 * n + goal.1] < .infinity else { return nil }
        var out: [(x: Int, y: Int)] = []
        var k = goal.0 * n + goal.1
        while k != s.0 * n + s.1 { out.append((k / n, k % n)); k = prev[k] }
        out.reverse()
        if let l = land { out.append(l) }
        return out
    }

    /// Place a ship by a shipyard (0x46a770): the first free coastal water cell with a way out,
    /// in the bands around the footprint `ring` cells deep.
    func shipCell(near p: MapScene.Placed, ring r: Int) -> (Int, Int)? {
        let a = p.cellX, b = p.cellY, sa = p.sprite.footprint.w, sb = p.sprite.footprint.h
        func ok(_ x: Int, _ y: Int) -> Bool {
            guard passability.isFreeWater(x, y), boat(at: x, y) == nil else { return false }
            let dirs = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
            var blocked = dirs.map { !passability.isFreeWater(x + $0.0, y + $0.1) }
            guard dirs.indices.contains(where: { blocked[$0] && !passability.isWater(x + dirs[$0].0, y + dirs[$0].1) }) else { return false }
            for d in [0, 2, 4, 6] where blocked[d] { blocked[(d + 1) % 8] = true; blocked[(d + 7) % 8] = true }
            return blocked.contains(false)
        }
        let bands: [(ClosedRange<Int>, ClosedRange<Int>)] = [((a + sa)...(a + sa + r - 1), (b - r)...(b + sb + r - 1)), ((a - r)...(a + sa - 1), (b + sb)...(b + sb + r - 1)),
                                                              (a...(a + sa - 1), (b - r)...(b - 1)), ((a - r)...(a - 1), (b - r)...(b + sb - 1))]
        for (xs, ys) in bands { for x in xs { for y in ys where ok(x, y) { return (x, y) } } }
        return nil
    }

    /// A shipyard: 1000 gold and 10 wood for a ship (0x46a3b0).
    func visitShipyard(_ hero: Hero, _ p: MapScene.Placed) {
        dialogueSound(21)
        guard let cell = shipCell(near: p, ring: 2) else { say(p, "full"); return }
        let cost = [(0, 1000), (1, 10)]
        question = (objectText(p, "initial", ["%material_list": materialList(cost)]) ?? "Build a ship for 1000 gold and 10 wood?", { [weak self] in
            guard let self = self else { return }
            guard self.resources["Gold", default: 0] >= 1000, self.resources["Wood", default: 0] >= 10 else { self.say(p, "Denied", ["%material_list": self.materialList(cost)]); return }
            self.resources["Gold", default: 0] -= 1000; self.resources["Wood", default: 0] -= 10
            self.boats.append(Boat(x: cell.0, y: cell.1, z: self.level, alignment: hero.alignment, owner: hero.owner))
            self.passability.block(cell.0, cell.1)
        })
    }

    /// Board the empty ship at `b` (the army stands next to it).
    func board(_ h: Hero, _ b: Int) {
        let s = boats.remove(at: b)
        passability.free(h.x, h.y)
        passability.free(s.x, s.y)
        h.x = s.x; h.y = s.y; h.boat = s.alignment
        if !keepsMovementBoarding(h) { h.movement = 0 }
        h.path = []; h.plan = []
        h.maxMovement = armyMovement(h)
    }
    /// Land on a coastal cell next to the ship: the empty ship stays.
    func land(_ h: Hero, at c: (Int, Int)) {
        boats.append(Boat(x: h.x, y: h.y, z: h.z, alignment: h.boat ?? "life", owner: h.owner))
        passability.block(h.x, h.y)
        h.x = c.0; h.y = c.1; h.boat = nil
        if !keepsMovementBoarding(h) { h.movement = 0 }
        h.path = []; h.plan = []
        h.maxMovement = armyMovement(h)
    }

    /// Summon Boat (0x507910): the player's nearest empty ship comes next to the caster.
    func summonBoat(_ h: Hero) -> Bool {
        let mine = boats.indices.filter { boats[$0].owner == h.owner }
        guard let b = mine.min(by: { a, c in
            let da = abs(boats[a].z - h.z) * 100000 + (boats[a].x - h.x) * (boats[a].x - h.x) + (boats[a].y - h.y) * (boats[a].y - h.y)
            let dc = abs(boats[c].z - h.z) * 100000 + (boats[c].x - h.x) * (boats[c].x - h.x) + (boats[c].y - h.y) * (boats[c].y - h.y)
            return da < dc }) else { scripts.messages.append(text("no_boats_available.misc", "You must own a ship before you can summon one.")); return false }
        for dx in -1...1 { for dy in -1...1 where passability.isFreeWater(h.x + dx, h.y + dy) {
            if boats[b].z < passabilities.count { passabilities[boats[b].z].free(boats[b].x, boats[b].y) }
            boats[b].x = h.x + dx; boats[b].y = h.y + dy; boats[b].z = h.z
            passability.block(boats[b].x, boats[b].y)
            return true
        } }
        scripts.messages.append(text("not_adjacent_to_water.misc", "You must be next to water to summon a ship."))
        return false
    }

    /// Debugging: build a ship at the first shipyard and put the hero aboard.
    public func debugBoard(_ h: Hero) -> (Int, Int)? {
        guard let p = scene.placed.first(where: { $0.type == "shipyard" }), let cell = shipCell(near: p, ring: 2) else { return nil }
        boats.append(Boat(x: cell.0, y: cell.1, z: level, alignment: h.alignment, owner: h.owner))
        passability.block(cell.0, cell.1)
        guard let shore = (-1...1).flatMap({ dx in (-1...1).map { (cell.0 + dx, cell.1 + $0) } }).first(where: { passability.isFree($0.0, $0.1) }) else { return cell }
        h.x = shore.0; h.y = shore.1
        board(h, boats.count - 1)
        return cell
    }
}
