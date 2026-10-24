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
        g.monsters[i] = GameState.Monster(x: c.0, y: c.1, name: m.name, creature: creature, count: 50)   // (worth over a fifth of the army: it does not flee, 0x522727)
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
        h.army = [Hero.Stack(creature: "peasant", count: 1)]   // (weak: a stack facing a far stronger army flees, 0x522560)
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
        try scenarioNoWayPastAStackInAPass(g)
        try scenarioClickOnAStackPlansThenAttacks(g)
        try scenarioAdjacentStackTakesTwoClicks(g)
        try scenarioPickingUpInAZoneIsAttacked(g)
        try scenarioUnseenStackStopsTheWalkBeforeItsZone(g)
        try scenarioClickWhileWalkingStops(g)
    }

    /// Another player's army on open ground: the cleared spot of a wandering stack (put out of
    /// the way), an enemy hero of another team with a strong army standing there.
    func enemyOnOpenGround(_ g: GameState) throws -> (Hero, (Int, Int)) {
        let me = g.map.humanColour
        guard let foe = (0..<8).first(where: { $0 != me && g.team(of: $0) != g.team(of: me) }) else { throw XCTSkip("no foe") }
        let (i, m) = try stackOnOpenGround(g)
        g.monsters[i].count = 0; g.passability.free(m.0, m.1)
        g.enemyHeroes = []; g.armyCharge = nil; g.pendingHeroBattle = nil; g.aiAttacking = false
        let e = Hero(actor: "hero.death_might_male", x: m.0, y: m.1, movement: 30)
        e.owner = foe; e.name = "Foe"
        e.army = [Hero.Stack(creature: "peasant", count: 50)]
        g.place(enemy: e)
        return (e, m)
    }

    /// The zones of other players' armies (0x498460 floods every army of another team): an enemy
    /// hero's army marks, forces routes and falls on the player's army that ends its move in its
    /// zone (0x4f81e0, the enemy the attacker); the player's army falls on a computer army that
    /// ends its move in his; an enemy the player does not see does not attack.
    func testEnemyHeroZones() throws {
        let g = try loadGame()
        // the flood and the cell's attacker; a forced exit and a yellow arrow toward it
        var (e, m) = try enemyOnOpenGround(g)
        var h = hero(g, at: (m.0 - 6, m.1))
        let map = g.guardMap(for: h)
        XCTAssertEqual(map.a(m.0, m.1)?.dist, 0)
        XCTAssertEqual(map.a(m.0 + 1, m.1 + 1)?.dist, 3)
        XCTAssertEqual(map.a(m.0 - 2, m.1)?.dist, 4)
        XCTAssertNil(map.a(m.0 - 3, m.1))
        XCTAssertEqual(g.guardAttacker(at: (m.0 - 2, m.1 + 1), map), .army(e))
        XCTAssertEqual(g.forcedExits(for: h)[(m.0 - 2) * g.map.size + m.1], 4)   // (+1, 0): toward the enemy
        XCTAssertEqual(g.seenThreat(to: h, at: m.0 - 2, m.1), .army(e))
        XCTAssertNil(g.seenThreat(to: h, at: m.0 - 3, m.1))
        // an army of the player's own team marks nothing
        e.owner = g.map.humanColour
        XCTAssertNil(g.guardMap(for: h).a(m.0 - 1, m.1))
        e.owner = (0..<8).first { $0 != g.map.humanColour && g.team(of: $0) != g.team(of: g.map.humanColour) }!

        // walking into the zone: the walk ends there, the enemy walks up and attacks
        g.click(hero: h, x: m.0 - 2, y: m.1)
        g.click(hero: h, x: m.0 - 2, y: m.1)
        XCTAssertTrue(h.isWalking)
        var enemyStates: [String] = []
        for _ in 0..<900 {
            g.update(dt: 1.0 / 30)
            if g.armyCharge != nil, let s = e.animState, enemyStates.last != s { enemyStates.append(s) }
            if g.pendingHeroBattle != nil { break }
        }
        XCTAssertEqual([h.x, h.y], [m.0 - 2, m.1])
        XCTAssertTrue(g.pendingHeroBattle?.hero === h && g.pendingHeroBattle?.enemy === e)
        XCTAssertTrue(g.aiAttacking)   // the computer's army attacks
        XCTAssertEqual([e.x, e.y], [m.0 - 1, m.1])   // it came to the hero
        XCTAssertEqual(enemyStates.first, "prewalk")
        XCTAssertEqual(e.animState, "attack")
        XCTAssertFalse(g.passability.isFree(e.x, e.y))

        // the reverse: a computer army whose move ends in the zone of the player's army
        (e, m) = try enemyOnOpenGround(g)
        h = hero(g, at: (m.0 + 2, m.1))
        XCTAssertEqual(g.guardMap(for: e).a(e.x, e.y)?.dist, 4)   // (an army's cell is entered straight)
        g.guardAttack(e)
        XCTAssertTrue(g.armyCharge?.attacker === h)
        for _ in 0..<900 { g.update(dt: 1.0 / 30); if g.pendingHeroBattle != nil { break } }
        XCTAssertTrue(g.pendingHeroBattle?.hero === h && g.pendingHeroBattle?.enemy === e)
        XCTAssertFalse(g.aiAttacking)   // the player's army attacks
        XCTAssertEqual([h.x, h.y], [m.0 + 1, m.1])

        // an enemy the player does not see (Grandmaster Stealth, no creatures): it marks the
        // ground (A) but forces nothing, and does not fall on him (0x4f83c1)
        (e, m) = try enemyOnOpenGround(g)
        e.army = []; e.skills["stealth"] = 5
        h = hero(g, at: (m.0 - 2, m.1))
        g.fogEnabled = true; g.updateVision()
        defer { g.fogEnabled = false }
        XCTAssertFalse(g.isVisible(e))
        XCTAssertEqual(g.threat(to: h, at: h.x, h.y), .army(e))
        XCTAssertNil(g.seenThreat(to: h, at: h.x, h.y))
        XCTAssertNil(g.forcedExits(for: h)[h.x * g.map.size + h.y])
        g.guardAttack(h)
        XCTAssertNil(g.armyCharge)
        XCTAssertNil(g.pendingHeroBattle)
        g.fogEnabled = false
        try garrisonPassage(g)
    }

    /// A garrison's gate (0x442a90): it stops an army while it has troops and is not its side's;
    /// the player's view shuts it, the computer's planner (type 7) never; a computer army fights
    /// the troops from the cell before (0x4423f0): a win takes it, a loss leaves the survivors.
    func garrisonPassage(_ g: GameState) throws {
        let (e, m) = try enemyOnOpenGround(g)
        g.removeEnemy(e)
        let me = g.map.humanColour, foe = e.owner, n = g.map.size, key = "0|\(m.0)|\(m.1)"
        var st = ObjectState(); st.isGarrison = true; st.garrisonOwner = me
        st.troopCreatures = ["peasant"]; st.troopCounts = [300]; st.gate = [m.0 * n + m.1]
        g.objectStates[key] = st
        XCTAssertFalse(g.garrisonStops(st, for: me))
        XCTAssertTrue(g.garrisonStops(st, for: foe))
        if let ally = (0..<8).first(where: { $0 != me && g.team(of: $0) == g.team(of: me) }) { XCTAssertFalse(g.garrisonStops(st, for: ally)) }
        var nobody = st; nobody.garrisonOwner = nil
        XCTAssertTrue(g.garrisonStops(nobody, for: me))   // (no owner: nobody's ally)
        var empty = st; empty.troopCounts = [0]
        XCTAssertFalse(g.garrisonStops(empty, for: foe))
        // the views: the player's own gate is open; a foe's shut to him, open to the computer's planner
        g.applyGarrisonGates(for: me)
        XCTAssertTrue(g.passability.isFree(m.0, m.1))
        st.garrisonOwner = foe; g.objectStates[key] = st
        g.applyGarrisonGates(for: me)
        XCTAssertFalse(g.passability.isFree(m.0, m.1))
        g.applyGarrisonGates(for: nil, planner: true)
        XCTAssertTrue(g.passability.isFree(m.0, m.1))
        g.applyGarrisonGates(for: me)
        // a computer army before the player's gate: stopped there, it fights the troops
        st.garrisonOwner = me; g.objectStates[key] = st; g.applyGarrisonGates(for: me)
        let a = Hero(actor: "hero.death_might_male", x: m.0 - 1, y: m.1, movement: 30)
        a.owner = foe; a.name = "Foe"; a.army = [Hero.Stack(creature: "peasant", count: 2)]
        g.place(enemy: a)
        XCTAssertEqual(g.garrisonGate(at: (m.0, m.1), z: 0), key)
        XCTAssertTrue(g.aiVacant((m.0, m.1), for: a))   // (whether it stops is the walk's test)
        g.aiAttackGarrison(a, key)
        XCTAssertFalse(g.enemyHeroes.contains { $0 === a })   // beaten
        XCTAssertEqual(g.objectStates[key]?.garrisonOwner, me)
        XCTAssertGreaterThan(g.objectStates[key]?.troopCounts.first ?? 0, 0)
        let b = Hero(actor: "hero.death_might_male", x: m.0 - 1, y: m.1, movement: 30)
        b.owner = foe; b.name = "Foe"; b.army = [Hero.Stack(creature: "peasant", count: 5000)]
        g.place(enemy: b)
        g.aiAttackGarrison(b, key)
        XCTAssertTrue(g.enemyHeroes.contains { $0 === b })
        XCTAssertEqual(g.objectStates[key]?.garrisonOwner, foe)   // taken (0x442710); it stays outside
        XCTAssertEqual([b.x, b.y], [m.0 - 1, m.1])
        XCTAssertEqual(g.objectStates[key]?.troopCounts, [0])
        XCTAssertTrue(g.passability.isFree(m.0, m.1))   // (empty: open to the player too)
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
            XCTAssertEqual(g.guardAttacker(at: (x, y), map), .stack(i))
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

    /// The planner weighs no danger for a player's route (0x4fe640 adds the danger penalty only
    /// for type 2): a zone shapes routes solely through its forced exits (0x4ff856). A pass whose
    /// only cell is in a seen stack's zone cannot be crossed -- no route at all, not one through
    /// the zone; the stack itself is still reached and attacked. Unseen (fog: no B marks, no
    /// forced exits), the route goes through the pass at its plain cost.
    func scenarioNoWayPastAStackInAPass(_ g: GameState) throws {
        let strong = g.tables?.creatures.first { $0.level == 4 }?.keyword ?? "peasant"
        let (i, m) = try stackOnOpenGround(g, creature: strong)
        // a box of radius 6 split by a wall through the stack's column; the one gap is the cell
        // next to the stack, (m.0, m.1 + 1)
        var walls: [(Int, Int)] = []
        for dx in -6...6 { for dy in -6...6 where abs(dx) == 6 || abs(dy) == 6 || (dx == 0 && dy != 0 && dy != 1) { walls.append((m.0 + dx, m.1 + dy)) } }
        for c in walls { g.passability.block(c.0, c.1) }
        defer { for c in walls { g.passability.free(c.0, c.1) } }
        let h = hero(g, at: (m.0 - 4, m.1 + 3))
        let target = (m.0 + 4, m.1 + 3)
        XCTAssertEqual(g.guardMap(for: h).b(m.0, m.1 + 1).map { [$0.dir, $0.dist] }, [6, 2])   // clean, straight at the stack
        XCTAssertEqual(g.guardMap(for: h).b(m.0, m.1 + 1)?.clean, true)
        g.click(hero: h, x: target.0, y: target.1)
        XCTAssertTrue(h.plan.isEmpty)                                 // no route past it
        XCTAssertNil(g.daysToReach(h, target))
        // the stack: the route ends on it and the hero attacks from the cell before it
        guard let p = g.scene.placed.first(where: { g.monster(for: $0) == i }) else { return XCTFail() }
        g.click(hero: h, pickup: p)
        XCTAssertEqual(h.target.map { [$0.x, $0.y] }, [m.0, m.1])
        g.click(hero: h, pickup: p)
        run(g)
        XCTAssertEqual(g.pendingBattle?.monster, i)
        XCTAssertEqual(max(abs(h.x - m.0), abs(h.y - m.1)), 1)
        g.pendingBattle = nil; g.charge = nil; g.pendingGuardChecks = []
        // not seen: no forced exits, the route takes the gap at its plain cost
        let h2 = hero(g, at: (m.0 - 4, m.1 + 3))
        g.fogEnabled = true
        let n = g.map.size
        g.fog = [Array(repeating: GameState.fogUnexplored, count: n * n)]
        g.fogLevel = [Array(repeating: -1, count: n * n)]
        defer { g.fogEnabled = false }
        g.click(hero: h2, x: target.0, y: target.1)
        XCTAssertTrue(h2.plan.contains { $0.x == m.0 && $0.y == m.1 + 1 })
        var p0 = g.passability; p0.forcedExit = [:]
        XCTAssertEqual(h2.plan.map { [$0.x, $0.y] }, p0.path(from: (h2.x, h2.y), to: target)?.map { [$0.x, $0.y] })
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
                guard g.threat(to: h, at: s.0, s.1) == .stack(i) else { why[3] += 1; continue }
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
