import XCTest
@testable import H4Engine

/// Caravans (re/caravans_logic_spec.md, re/caravans_dialogs_*_spec.md).
final class CaravanTests: XCTestCase {
    func stack(_ c: String, _ n: Int) -> ArmySlot { .stack(Hero.Stack(creature: c, count: n)) }
    func names(_ row: [ArmySlot?]) -> [String] {
        row.map { s in s?.stack.map { "\($0.creature)\($0.count)" } ?? (s?.hero != nil ? "H" : "-") }
    }

    func testMergeSameSlotThenFirstThatTakesIt() {
        // 0x5b7c90: the same place when it takes the stack, else the first one that does
        let c = Caravan(id: 1, owner: 0, destination: 0, origin: "A", arrivalDay: 1, slots: [stack("imp", 5), stack("orc", 3), nil, stack("imp", 2)])
        var row: [ArmySlot?] = [stack("orc", 1), nil, stack("imp", 4), nil, nil, nil, nil]
        XCTAssertTrue(GameState.mergeCaravan(c, into: &row))
        // imp 5 -> place 0 is an orc, the first taker is the empty place 1 (not the imps at 2);
        // orc 3 -> place 1 now holds imps, the first taker is the orcs at 0; imp 2 -> its own place 3
        XCTAssertEqual(names(row), ["orc4", "imp5", "imp4", "imp2", "-", "-", "-"])
        XCTAssertTrue(c.isEmpty)
    }

    func testMergeLeavesWhatDoesNotFitAndJoinsDuplicates() {
        // a full row: only same creatures go in; duplicates of the row are joined before the second pass
        let c = Caravan(id: 1, owner: 0, destination: 0, origin: "A", arrivalDay: 1, slots: [stack("dragon", 1), stack("imp", 1)])
        var row: [ArmySlot?] = (0..<7).map { k in stack(k < 2 ? "orc" : "elf\(k)", 1) }
        XCTAssertFalse(GameState.mergeCaravan(c, into: &row))
        // pass 1 found no place; the two orcs were joined, freeing one place for the dragon (the imp stays)
        XCTAssertEqual(names(row), ["orc2", "dragon1", "elf21", "elf31", "elf41", "elf51", "elf61"])
        XCTAssertEqual(names(c.slots), ["-", "imp1", "-", "-", "-", "-", "-"])
    }

    func testHeroesTakeOnlyEmptyPlaces() {
        let h = Hero(actor: "x", x: 0, y: 0)
        let c = Caravan(id: 1, owner: 0, destination: 0, origin: "A", arrivalDay: 1, slots: [.hero(h)])
        var row: [ArmySlot?] = [stack("orc", 1), nil, nil, nil, nil, nil, nil]
        XCTAssertTrue(GameState.mergeCaravan(c, into: &row))
        XCTAssertTrue(row[1]?.hero === h)
        XCTAssertTrue(GameState.fits(Caravan(id: 2, owner: 0, destination: 0, origin: "", arrivalDay: 0, slots: [stack("orc", 9)]), [stack("orc", 1)] + [ArmySlot?](repeating: stack("elf", 1), count: 6)))
        XCTAssertFalse(GameState.fits(Caravan(id: 2, owner: 0, destination: 0, origin: "", arrivalDay: 0, slots: [stack("imp", 9)]), [stack("orc", 1)] + [ArmySlot?](repeating: stack("elf", 1), count: 6)))
    }

    func testPlaceholdersAnyCase() {
        XCTAssertEqual(GameState.substitute("%Count of your caravans have arrived at %town_list", ["%count": "2", "%town_list": "Ash"]), "2 of your caravans have arrived at Ash")
        XCTAssertEqual(GameState.substitute("View Caravans for %Town.", ["%town": "ash"]), "View Caravans for Ash.")
    }

    // MARK: on a real map when the game is installed

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
        g.quickCombatOnly = true
        return g
    }
    /// Two surface towns of the human with caravans.
    func twoTowns(_ g: GameState) throws -> (Int, Int) {
        let surface = g.towns.indices.filter { g.towns[$0].z == 0 && g.townPlaced($0) != nil }
        guard surface.count >= 2 else { throw XCTSkip("map has fewer than two towns") }
        let (a, b) = (surface[0], surface[1])
        for i in [a, b] { g.towns[i].owner = g.map.humanColour; g.towns[i].owned = true; g.towns[i].buildings.insert("caravan") }
        return (a, b)
    }

    func testRouteDaysFollowTerrainCost() throws {
        let g = try loadGame()
        let (a, b) = try twoTowns(g)
        g.monsters = []   // nothing in the way
        guard case .days(let n) = g.caravanRoute(from: .town(a), to: b) else { return XCTFail("no route") }
        // cost / 3000 rounded up, at least 1; a land route of k cells costs at least 75 k
        XCTAssertGreaterThanOrEqual(n, 1)
        let pa = g.townPlaced(a)!, pb = g.townPlaced(b)!
        let cells = max(abs(pa.cellX - pb.cellX), abs(pa.cellY - pb.cellY))
        XCTAssertLessThanOrEqual(n, max(1, (cells * 400 + 2999) / 3000 + 2))
        XCTAssertEqual(g.caravanRoute(from: .town(a), to: b), g.caravanRoute(from: .town(a), to: b))
    }

    func testArrivalIntoGarrisonThenOutsideThenWaiting() throws {
        let g = try loadGame()
        let (a, b) = try twoTowns(g)
        let me = g.map.humanColour
        g.towns[b].garrison = []; g.towns[b].garrisonHeroes = []
        g.sendCaravan([stack("Peasant", 10)], from: .town(a), to: b, days: 2, owner: me)
        XCTAssertNil(g.caravanArrivals(for: me))            // not yet
        XCTAssertEqual(g.caravans.count, 1)
        g.day += 2
        XCTAssertNil(g.caravanArrivals(for: me))            // into the garrison, no message
        XCTAssertTrue(g.caravans.isEmpty)
        XCTAssertEqual(g.towns[b].garrison.first?.count, 10)

        // a full garrison: an army forms outside the gate ("arrived_full_dropped")
        g.towns[b].garrison = (0..<7).map { Hero.Stack(creature: "elf\($0)", count: 1) }
        let before = g.heroes.count
        g.sendCaravan([stack("Peasant", 3)], from: .town(a), to: b, days: 1, owner: me)
        g.day += 1
        let msg = g.caravanArrivals(for: me)
        XCTAssertEqual(g.heroes.count, before + 1)
        XCTAssertTrue(g.heroes.first!.heroless)
        XCTAssertEqual(g.heroes.first!.army.first?.count, 3)
        XCTAssertTrue(msg?.contains("already full") ?? false, msg ?? "nil")

        // eight armies: it waits outside ("arrived_full", Manage Arrivals) and is tried again each turn
        while g.heroes.count < GameState.maxArmies { let h = Hero(actor: "x", x: 0, y: 0); h.heroless = true; g.heroes.append(h) }
        g.sendCaravan([stack("Peasant", 4)], from: .town(a), to: b, days: 1, owner: me)
        g.day += 1
        let m2 = g.caravanArrivals(for: me)
        XCTAssertTrue(m2?.contains("camped outside the town") ?? false, m2 ?? "nil")
        XCTAssertEqual(g.waitingCaravans(town: b, owner: me).count, 1)
        XCTAssertNotNil(g.caravanArrivals(for: me))
        XCTAssertEqual(g.caravans.count, 1)
    }

    func testCaptureDestroysCampedCaravansAndWarnsOfIncoming() throws {
        let g = try loadGame()
        let (a, b) = try twoTowns(g)
        let me = g.map.humanColour, enemy = (me + 1) % 6
        g.towns[b].owner = enemy; g.towns[b].owned = false
        let h = Hero(actor: "x", x: 0, y: 0); h.name = "Ash"
        let camped = g.sendCaravan([stack("Imp", 3), .hero(h)], from: .town(a), to: b, days: 1, owner: enemy)!
        camped.arrivalDay = g.day   // it has arrived and waits outside
        g.sendCaravan([stack("Imp", 5)], from: .town(a), to: b, days: 2, owner: enemy)
        g.scripts.messages = []
        g.towns[b].owner = me; g.towns[b].owned = true
        g.caravansAtCapture(town: b, newOwner: me)
        XCTAssertEqual(g.caravans.count, 1)                        // the one on the road is untouched
        XCTAssertTrue(g.towns[b].prisoners.first === h)
        XCTAssertEqual(g.scripts.messages.count, 2)
        XCTAssertTrue(g.scripts.messages[0].contains("Ash"))        // killed_both_victor names the hero
        XCTAssertTrue(g.scripts.messages[1].contains("in 2 days"))  // incoming_warning_singular_future
    }

    func testSaveRestoresCaravans() throws {
        let g = try loadGame()
        let (a, b) = try twoTowns(g)
        let h = Hero(actor: "hero.x", x: 0, y: 0); h.name = "Rider"
        g.sendCaravan([stack("Peasant", 7), nil, .hero(h)], from: .town(a), to: b, days: 3, owner: g.map.humanColour)
        let s = g.snapshot(mapPath: "x")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SaveGame.self, from: data)
        let g2 = try loadGame()
        g2.restore(back)
        XCTAssertEqual(g2.caravans.count, 1)
        let c = g2.caravans[0]
        XCTAssertEqual(c.destination, b); XCTAssertEqual(c.arrivalDay, g.day + 3); XCTAssertEqual(c.origin, g.towns[a].name)
        XCTAssertEqual(c.slots[0]?.stack?.count, 7); XCTAssertNil(c.slots[1]); XCTAssertEqual(c.slots[2]?.hero?.name, "Rider")
        XCTAssertEqual(g2.nextCaravanId, 2)
    }

    func testCreationListsRefusalsAndBuyingAtADwelling() throws {
        let g = try loadGame()
        let me = g.map.humanColour
        let surface = g.towns.indices.filter { g.towns[$0].z == 0 && g.townPlaced($0) != nil }
        guard surface.count >= 2 else { throw XCTSkip("map has fewer than two towns") }
        let (a, b) = (surface[0], surface[1])
        for t in g.towns.indices { g.towns[t].owner = nil; g.towns[t].owned = false }
        for d in g.dwellings.indices { g.dwellings[d].owner = nil }
        g.towns[a].owner = me; g.towns[a].owned = true; g.towns[a].buildings.insert("caravan")
        // nothing else to send to or from
        XCTAssertTrue(g.caravanCreateRefusal(town: a, player: me)?.hasPrefix("Caravans must have a destination") ?? false)
        // an enemy's town without an army of ours there
        XCTAssertEqual(g.caravanCreateRefusal(town: b, player: me), "You don't have any troops in this town.")
        // a second caravan town and a dwelling: destinations = that town; origins = the town, then the dwelling
        g.towns[b].owner = me; g.towns[b].owned = true; g.towns[b].buildings.insert("caravan")
        guard let d = g.dwellings.indices.first(where: { g.dwellings[$0].z == 0 }), let c = g.tables?.creature(g.dwellings[d].creature) else { throw XCTSkip("no dwelling") }
        g.dwellings[d].owner = me; g.dwellings[d].available = 5
        XCTAssertNil(g.caravanCreateRefusal(town: a, player: me))
        let l = g.caravanLists(town: a, player: me)
        XCTAssertEqual(l.destinations, [b])
        XCTAssertEqual(l.origins, [.town(b), .dwelling(d)])
        // buying 2 at the dwelling: paid at the normal price, sent at once
        let gold = g.resources["Gold"] ?? 0
        let cv = g.buyCaravan(dwelling: d, count: 2, to: a, days: 2)
        XCTAssertNotNil(cv)
        XCTAssertEqual(g.dwellings[d].available, 3)
        XCTAssertEqual(g.resources["Gold"], gold - 2 * (GameState.recruitCost(c, discount: 0).first { $0.0 == "Gold" }?.1 ?? 0))
        XCTAssertEqual(cv?.arrivalDay, g.day + 2)
        XCTAssertEqual(cv?.stacks.first?.count, 2)
        XCTAssertTrue(g.caravanBuyText(dwelling: d, route: .days(2), destination: g.towns[a].name).contains("in 2 days"))
        XCTAssertEqual(g.viewedCaravans(town: a, player: me).count, 1)
        XCTAssertEqual(g.viewedCaravans(town: nil, player: me).count, 1)
    }
}
