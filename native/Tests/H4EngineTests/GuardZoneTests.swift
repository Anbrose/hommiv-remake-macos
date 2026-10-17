import XCTest
@testable import H4Engine

/// Guard zones and monster attacks as heroes4.exe has them (re/adventure_guards_spec.md): the
/// flood 0x4979f0, the forced exits of 0x4ff856, the walk cut of 0x5439e0 and the attack at the
/// end of a move 0x4f81e0. On a real map (skipped when the game is not installed): a real
/// wandering stack is moved onto open ground.
final class GuardZoneTests: XCTestCase {
    func loadGame() throws -> GameState {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/A Land without a King.h4c")
        guard FileManager.default.fileExists(atPath: mapURL.path) else { throw XCTSkip("game data not installed") }
        let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: data.appendingPathComponent(f)) { archive.supplement(with: a) } }
        let tables = try RuleTables(archive: H4Archive(url: data.appendingPathComponent("text.h4r")))
        RandomResolver.creaturePool = (1...4).map { lv in tables.creatures.filter { $0.level == lv && $0.expansion == 0 }.map { $0.keyword } }
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let map = try MapFile(data: Data(contentsOf: mapURL), objectNames: names)
        let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
        let scene = try MapScene(map: map, level: 0, archive: archive, masks: masks)
        let g = GameState(map: map, level: 0, scenes: [scene])
        g.tables = tables
        g.registerObjects(townFactions: [:])
        g.fogEnabled = false
        return g
    }

    /// Open land around a cell: free, dry, nothing to enter, no other stack near.
    func open(_ g: GameState, _ c: (Int, Int), radius r: Int, except: Int? = nil) -> Bool {
        let p = g.passability
        for x in c.0 - r...c.0 + r { for y in c.1 - r...c.1 + r {
            guard p.isFree(x, y), !p.isWater(x, y), !p.isTrigger(x, y), !p.edgeAt(x, y), p.bridgeAxis[x * p.size + y] == 0 else { return false }
        } }
        return !g.monsters.indices.contains { $0 != except && max(abs(g.monsters[$0].x - c.0), abs(g.monsters[$0].y - c.1)) <= r + 3 }
    }
    /// Move stack i to cell c (as finishCharge does), as `creature`.
    func move(_ g: GameState, _ i: Int, to c: (Int, Int), creature: String) {
        let m = g.monsters[i]
        guard let p = g.scene.placed.first(where: { g.monster(for: $0) == i }) else { return XCTFail("stack not placed") }
        g.passability.free(m.x, m.y)
        g.monsters[i] = GameState.Monster(x: c.0, y: c.1, name: m.name, creature: creature, count: 3)
        g.passability.block(c.0, c.1); g.passability.openTrigger(c.0, c.1, object: Int.max)
        _ = g.scene.relocate(p, toX: c.0, y: c.1)
    }
    /// A wandering stack on cleared open ground (radius 6 around it, on dry land away from the
    /// other stacks and from the spots used before), and its index.
    func stackOnOpenGround(_ g: GameState, creature: String = "peasant") throws -> (Int, (Int, Int)) {
        guard let i = g.guardStacks.first else { throw XCTSkip("no wandering stack") }
        let n = g.map.size, r = 6
        g.pendingBattle = nil; g.charge = nil; g.pendingGuardChecks = []; g.chestOffer = nil; g.scripts.messages = []
        for x in r + 2..<n - r - 2 { for y in r + 2..<n - r - 2 where !used.contains(where: { max(abs($0.0 - x), abs($0.1 - y)) < 2 * r + 4 }) {
            var ok = true
            for dx in -r...r { for dy in -r...r where ok {
                let a = x + dx, b = y + dy
                if g.map.cells[0][a * n + b] == nil || g.passability.terrainBlocked[a * n + b] || g.passability.isWater(a, b) || g.passability.bridgeAxis[a * n + b] != 0 { ok = false }
            } }
            guard ok else { continue }
            for k in g.monsters.indices where k != i && max(abs(g.monsters[k].x - x), abs(g.monsters[k].y - y)) <= r + 4 { g.monsters[k].count = 0 }   // (out of the way)
            for dx in -r...r { for dy in -r...r { g.passability.free(x + dx, y + dy) } }
            move(g, i, to: (x, y), creature: creature)
            used.append((x, y))
            return (i, (x, y))
        } }
        throw XCTSkip("no open ground")
    }
    var used: [(Int, Int)] = []
    func hero(_ g: GameState, at c: (Int, Int)) -> Hero {
        let h = Hero(actor: "hero.life_might_male", x: c.0, y: c.1, movement: 30)
        h.owner = g.map.humanColour
        h.army = [Hero.Stack(creature: g.tables?.creatures.first { $0.level == 4 }?.keyword ?? "peasant", count: 50)]
        g.heroes = [h]
        return h
    }
    func run(_ g: GameState, frames: Int = 900) {
        for _ in 0..<frames {
            g.update(dt: 1.0 / 30)
            if g.pendingBattle != nil { break }
        }
    }

    /// All the scenarios on one loaded map (loading it takes long).
    func testGuardZones() throws {
        let g = try loadGame()
        try scenarioFloodOnOpenGround(g)
        try scenarioStealthHidesFromLowerStacks(g)
        try scenarioEndingAMoveInAZoneIsAttacked(g)
        try scenarioRoutesGoRoundASeenZone(g)
        try scenarioClickOnAStackPlansThenAttacks(g)
        try scenarioAdjacentStackTakesTwoClicks(g)
        try scenarioPickingUpInAZoneIsAttacked(g)
        try scenarioUnseenStackStopsTheWalkBeforeItsZone(g)
        try scenarioClickWhileWalkingStops(g)
    }

    /// The flood on open ground: the 5 x 5 square, 2 a straight step, 3 a diagonal, pointing back
    /// at the stack; the chain from any of its cells finds the stack.
    func scenarioFloodOnOpenGround(_ g: GameState) throws {
        let (i, m) = try stackOnOpenGround(g)
        let h = hero(g, at: (m.0 - 5, m.1))
        let map = g.guardMap(for: h)
        XCTAssertEqual(map.a(m.0, m.1)?.dist, 0)
        XCTAssertEqual(map.a(m.0 + 1, m.1)?.dist, 2)
        XCTAssertEqual(map.a(m.0 + 1, m.1 + 1)?.dist, 3)
        XCTAssertEqual(map.a(m.0 + 2, m.1)?.dist, 4)
        XCTAssertEqual(map.a(m.0 + 2, m.1 + 1)?.dist, 5)
        XCTAssertEqual(map.a(m.0 - 2, m.1 - 2)?.dist, 6)
        XCTAssertNil(map.a(m.0 + 3, m.1))
        XCTAssertEqual(map.a(m.0 + 1, m.1)?.dir, 0)   // (-1, 0): toward the stack
        var marked = 0
        for x in m.0 - 3...m.0 + 3 { for y in m.1 - 3...m.1 + 3 where map.a(x, y) != nil {
            marked += 1
            XCTAssertEqual(g.guardAttacker(at: (x, y), map), i)
        } }
        XCTAssertEqual(marked, 25)
        XCTAssertEqual(map.b(m.0 + 2, m.1)?.dist, 4)   // seen (no fog): B as A
    }

    /// Stealth against scouting (0x497b5d): no zone when the army's stealth is above the stack's
    /// scouting (level - 2) + 1; any creature in the army spoils it (-1).
    func scenarioStealthHidesFromLowerStacks(_ g: GameState) throws {
        guard let t = g.tables, let one = t.creatures.first(where: { $0.level == 1 && !GameState.isStealthy($0.keyword) })?.keyword,
              let four = t.creatures.first(where: { $0.level == 4 })?.keyword else { return XCTFail("no creatures") }
        let (i, m) = try stackOnOpenGround(g, creature: one)
        let h = hero(g, at: (m.0 - 5, m.1))
        h.army = []
        func zone() -> Bool { g.guardMap(for: h).a(m.0 + 1, m.1) != nil }
        h.skills["stealth"] = 1; XCTAssertTrue(zone())    // basic (0) <= -1 + 1
        h.skills["stealth"] = 2; XCTAssertFalse(zone())   // advanced (1) > 0
        move(g, i, to: m, creature: four)
        h.skills["stealth"] = 4; XCTAssertTrue(zone())    // master (3) <= 2 + 1
        h.skills["stealth"] = 5; XCTAssertFalse(zone())   // grandmaster
        h.army = [Hero.Stack(creature: one, count: 1)]; XCTAssertTrue(zone())   // a creature: -1
    }

    /// Walking onto a cell of a seen stack's zone: the walk ends there, the stack walks up and the
    /// battle starts (0x4f81e0 at the end of the move); nothing on the way before.
    func scenarioEndingAMoveInAZoneIsAttacked(_ g: GameState) throws {
        let (i, m) = try stackOnOpenGround(g)
        let h = hero(g, at: (m.0 - 6, m.1))
        g.click(hero: h, x: m.0 - 2, y: m.1)
        XCTAssertEqual(h.plan.last.map { [$0.x, $0.y] }, [m.0 - 2, m.1])
        g.click(hero: h, x: m.0 - 2, y: m.1)
        XCTAssertTrue(h.isWalking)
        var heroStates: [String] = [], stackStates: [String] = []
        for _ in 0..<900 {
            g.update(dt: 1.0 / 30)
            if let s = h.animState, heroStates.last != s { heroStates.append(s) }
            if let c = g.charge, stackStates.last != c.animState { stackStates.append(c.animState) }
            if g.pendingBattle != nil { break }
        }
        XCTAssertEqual([h.x, h.y], [m.0 - 2, m.1])
        XCTAssertEqual(g.pendingBattle?.monster, i)
        XCTAssertEqual([g.monsters[i].x, g.monsters[i].y], [m.0 - 1, m.1])   // it came to the hero
        // both walks start with the prewalk and end with the postwalk (re/adventure_walk_spec.md §3, §6)
        XCTAssertEqual(heroStates, ["prewalk", "walk", "postwalk", "attack"])
        XCTAssertEqual(stackStates.first, "prewalk")
        XCTAssertEqual(stackStates.last, "postwalk")
        XCTAssertEqual(g.monsters[i].facing, "ne")   // toward the hero
    }

    /// A route cannot cross a seen zone (forced exits toward the stack): it goes round.
    func scenarioRoutesGoRoundASeenZone(_ g: GameState) throws {
        let (_, m) = try stackOnOpenGround(g)
        let h = hero(g, at: (m.0 - 4, m.1))
        g.click(hero: h, x: m.0 + 4, y: m.1)
        XCTAssertFalse(h.plan.isEmpty)
        let map = g.guardMap(for: h)
        var prev = (h.x, h.y)
        for c in h.plan {   // a zone cell is only left toward the stack
            if let b = map.b(prev.0, prev.1), b.clean, prev != (h.x, h.y) {
                let d = Passability.directions[b.dir]
                XCTAssertEqual([c.x, c.y], [prev.0 + d.dx, prev.1 + d.dy])
            }
            prev = (c.x, c.y)
        }
        XCTAssertFalse(h.plan.dropLast().contains { map.a($0.x, $0.y) != nil })
    }

    /// Clicking on the stack: the first click plans a route into it, the second walks it and
    /// the hero attacks from the cell before it.
    func scenarioClickOnAStackPlansThenAttacks(_ g: GameState) throws {
        let (i, m) = try stackOnOpenGround(g)
        guard let p = g.scene.placed.first(where: { g.monster(for: $0) == i }) else { return XCTFail() }
        let h = hero(g, at: (m.0 - 5, m.1 + 1))
        g.click(hero: h, pickup: p)
        XCTAssertFalse(h.plan.isEmpty)
        XCTAssertFalse(h.isWalking)
        XCTAssertEqual(h.target.map { [$0.x, $0.y] }, [m.0, m.1])
        let last = h.plan.last!
        XCTAssertEqual(max(abs(last.x - m.0), abs(last.y - m.1)), 1)
        XCTAssertEqual(g.arrows(for: h).last?.name.hasSuffix(".dest"), true)
        XCTAssertEqual(g.arrows(for: h).last.map { [$0.x, $0.y] }, [m.0, m.1])   // the X on the stack
        g.click(hero: h, pickup: p)
        XCTAssertTrue(h.isWalking)
        run(g)
        XCTAssertEqual(g.pendingBattle?.monster, i)
        XCTAssertEqual([h.x, h.y], [last.x, last.y])
        // the walk ended facing the stack (0x544ce0), the hero in his attack state and the stack
        // turned toward him (0x522560); re/adventure_walk_spec.md §5-6
        XCTAssertEqual(h.facing, Hero.facing(dx: m.0 - h.x, dy: m.1 - h.y))
        XCTAssertEqual(h.animState, "attack")
        XCTAssertEqual(g.monsters[i].facing, GameState.facing(from: m, toward: (h.x, h.y)))
        // the combat screen took the battle: no stack falls on the hero while it is open
        g.pendingBattle = nil; g.battleUnderway = true
        for _ in 0..<10 { g.update(dt: 1.0 / 30) }
        XCTAssertNil(g.pendingBattle)
        XCTAssertNil(g.charge)
        g.battleUnderway = false
    }

    /// An object next to the hero takes two clicks too (its route is the one step into it).
    func scenarioAdjacentStackTakesTwoClicks(_ g: GameState) throws {
        let (i, m) = try stackOnOpenGround(g)
        guard let p = g.scene.placed.first(where: { g.monster(for: $0) == i }) else { return XCTFail() }
        let h = hero(g, at: (m.0 - 1, m.1))
        g.click(hero: h, pickup: p)
        XCTAssertNil(g.pendingBattle)
        XCTAssertEqual(g.arrows(for: h).map { [$0.x, $0.y] }, [[m.0, m.1]])
        g.click(hero: h, pickup: p)
        run(g, frames: 5)
        XCTAssertEqual(g.pendingBattle?.monster, i)
    }

    /// The user's case: a pile used from a cell of a stack's zone. The hero picks it up, then the
    /// stack falls on him.
    func scenarioPickingUpInAZoneIsAttacked(_ g: GameState) throws {
        guard let i = g.guardStacks.first else { throw XCTSkip("no stack") }
        let p0 = g.passability
        g.pendingBattle = nil; g.charge = nil; g.pendingGuardChecks = []
        // a pile with open ground on one side: hero cell s next to it, the stack two beyond
        var why = [0, 0, 0, 0, 0]
        for pile in g.scene.placed where ["material_pile", "random_material_pile"].contains(pile.type) {
            why[0] += 1
            for d in [(0, 1), (1, 0), (0, -1), (-1, 0)] {
                // the stack beside the pile, the hero on the other side: the stack's way to him goes
                // round the pile's corners (not clean), so the pile can still be entered from there
                let s = (pile.cellX - d.0, pile.cellY - d.1), m = (pile.cellX + d.0, pile.cellY + d.1)
                let mid = (pile.cellX + d.1, pile.cellY + d.0)
                let n = g.map.size
                guard [s, mid, m].allSatisfy({ $0.0 > 0 && $0.1 > 0 && $0.0 < n - 1 && $0.1 < n - 1 && g.map.cells[0][$0.0 * n + $0.1] != nil
                          && !p0.terrainBlocked[$0.0 * n + $0.1] && !p0.isWater($0.0, $0.1) && !p0.isTrigger($0.0, $0.1) }),
                      !g.monsters.indices.contains(where: { $0 != i && max(abs(g.monsters[$0].x - m.0), abs(g.monsters[$0].y - m.1)) <= 6 })
                else { why[1] += 1; continue }
                for c in [s, mid, m] { g.passability.free(c.0, c.1) }
                guard g.canUse(from: s, pile) else { why[2] += 1; continue }
                move(g, i, to: m, creature: "peasant")
                let h = hero(g, at: s)
                guard g.threat(to: h, at: s.0, s.1) == i else { why[3] += 1; continue }
                g.click(hero: h, pickup: pile)
                XCTAssertNotNil(h.target)
                XCTAssertTrue(g.scene.placed.contains { $0.cellX == pile.cellX && $0.cellY == pile.cellY && $0.name == pile.name })   // not yet
                g.click(hero: h, pickup: pile)
                XCTAssertFalse(g.scene.placed.contains { $0.cellX == pile.cellX && $0.cellY == pile.cellY && $0.name == pile.name })  // picked up first
                g.chestOffer = nil; g.scripts.messages = []
                run(g)
                XCTAssertEqual(g.pendingBattle?.monster, i)
                return
            }
        }
        XCTFail("no pile with room for a stack \(why)")
    }

    /// A stack the player does not see (fog) but the hero can make out stops the walk before
    /// its zone (0x5439e0, diff <= 0): no attack.
    func scenarioUnseenStackStopsTheWalkBeforeItsZone(_ g: GameState) throws {
        let (_, m) = try stackOnOpenGround(g)
        let h = hero(g, at: (m.0 - 6, m.1))
        g.click(hero: h, x: m.0 - 1, y: m.1)
        g.fogEnabled = true
        let n = g.map.size
        g.fog = [Array(repeating: GameState.fogUnexplored, count: n * n)]
        g.fogLevel = [Array(repeating: -1, count: n * n)]
        g.click(hero: h, x: m.0 - 1, y: m.1)
        XCTAssertTrue(h.isWalking)
        g.update(dt: 0)   // the walk starts: cut
        XCTAssertEqual(h.path.last.map { [$0.x, $0.y] }, [m.0 - 3, m.1])
        run(g)
        XCTAssertEqual([h.x, h.y], [m.0 - 3, m.1])
        XCTAssertNil(g.pendingBattle)
        XCTAssertNil(g.charge)
        g.fogEnabled = false
    }

    /// A click while walking only stops the walk; the rest of the route stays.
    func scenarioClickWhileWalkingStops(_ g: GameState) throws {
        let (_, m) = try stackOnOpenGround(g)
        let h = hero(g, at: (m.0 - 6, m.1 - 6))
        g.click(hero: h, x: m.0 - 6, y: m.1 - 2)
        g.click(hero: h, x: m.0 - 6, y: m.1 - 2)
        g.update(dt: 0.1)
        g.click(hero: h, x: m.0 + 3, y: m.1 + 3)
        XCTAssertEqual(h.path.count, 1)
        XCTAssertEqual(h.plan.last.map { [$0.x, $0.y] }, [m.0 - 6, m.1 - 2])
    }
}
