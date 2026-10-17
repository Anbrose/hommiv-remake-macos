import XCTest
@testable import H4Engine

/// Preplaced armies' records (re/start_placement_spec.md): position read verbatim, v7+ ship byte.
final class StartPlacementTests: XCTestCase {
    static let root = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4")

    func archive() throws -> (H4Archive, Set<String>) {
        let data = StartPlacementTests.root.appendingPathComponent("Data")
        guard FileManager.default.fileExists(atPath: data.appendingPathComponent("storm.h4r").path) else { throw XCTSkip("no game files") }
        let a = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let s = try? H4Archive(url: data.appendingPathComponent(f)) { a.supplement(with: s) } }
        return (a, Set(a.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) }))
    }

    /// Isle of the Dawn (Bard campaign, scenario 1): Agraynel's army record says (33,106) on the
    /// surface with no ship; that cell is beach sand and she can walk off it. The original's save
    /// after her first move has her at (36,105) by (34,105) and (35,105).
    func testIsleOfTheDawnStartsOnTheBeachAndCanMove() throws {
        let (a, names) = try archive()
        let m = try MapFile(data: CampaignFile.load(11, from: a).scenario(0), objectNames: names)
        let o = try XCTUnwrap(m.objects.first { $0.heroes.contains { $0.name == "Agraynel" } })
        XCTAssertEqual([o.x, o.y, o.level], [33, 106, 0])
        XCTAssertNil(o.boat)
        let types = [(33, 106), (34, 105), (35, 105), (36, 105)].map { m.cells[0][$0.0 * m.size + $0.1]?.type }
        XCTAssertEqual(types, [6, 2, 2, 6])   // sand, rough, rough, sand
        let masks = try TransitionMasks(data: a.payload("transition.Transitions.h4d"))
        let scene = try MapScene(map: m, level: 0, archive: a, masks: masks)
        let p = Passability(map: m, level: 0, objects: scene.placed)
        XCTAssertTrue(p.isFree(33, 106))
        let route = try XCTUnwrap(p.path(from: (33, 106), to: (36, 105)))
        XCTAssertEqual(route.count, 3)
    }

    /// Every preplaced army of every shipped map stands on ground its creatures can stand on:
    /// land stacks on land (the terrain block was read from a byte too early on 47 maps, shifting
    /// every cell along y). Mermaids and sea monsters (0x642910: creature ids 0x26, 0x34) are the
    /// sea's; the only land stacks left on water are Zanfas's Challenge's three water elementals.
    func testPreplacedArmiesStandOnTheirGround() throws {
        let (a, names) = try archive()
        var maps: [(String, Data)] = []
        let dir = StartPlacementTests.root.appendingPathComponent("maps")
        if let en = FileManager.default.enumerator(atPath: dir.path) { for case let f as String in en where f.hasSuffix(".h4c") { maps.append((f, try Data(contentsOf: dir.appendingPathComponent(f)))) } }
        for id in CampaignFile.resources.keys.sorted() { if let c = try? CampaignFile.load(id, from: a) { for i in 0..<c.count { maps.append(("campaign \(id) #\(i)", try c.scenario(i))) } } }
        let sea: Set<String> = ["mermaid", "sea monster"]
        var land = 0, wrong: [String] = []
        for (name, d) in maps {
            let m = try MapFile(data: d, objectNames: names)
            for o in m.objects where (o.type == "army" || o.type == "hero_army") && o.boat == nil {
                let kinds = (o.army ?? []).compactMap { $0 }.map { $0.creature < RuleTables.creatureIds.count ? RuleTables.creatureIds[$0.creature] : "" }
                guard let c = m.cells[o.level][o.x * m.size + o.y] else { wrong.append("\(name) (\(o.x),\(o.y)) off the map"); continue }
                if !kinds.isEmpty, kinds.allSatisfy({ sea.contains($0) }) { continue }
                land += 1
                if c.type == 0 { wrong.append("\(name) (\(o.x),\(o.y)) \(kinds) \(o.heroes.map(\.name)) on water") }
            }
        }
        XCTAssertGreaterThan(land, 6000)
        XCTAssertEqual(wrong.sorted(), ["Zanfas's Challenge.h4c (136,232) [\"water elemental\"] [] on water",
                                        "Zanfas's Challenge.h4c (167,217) [\"water elemental\"] [] on water",
                                        "Zanfas's Challenge.h4c (223,147) [\"water elemental\"] [] on water"])
    }

    /// A player's army that starts aboard a ship (v7+ byte 0x523e55 = the ship's alignment).
    func testShipByteOfAPlayersArmy() throws {
        let (_, names) = try archive()
        let url = StartPlacementTests.root.appendingPathComponent("maps/Search for the Old Heroes 2.h4c")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no map") }
        let m = try MapFile(data: Data(contentsOf: url), objectNames: names)
        let o = try XCTUnwrap(m.objects.first { $0.heroes.contains { $0.name == "Timin" } })
        XCTAssertEqual([o.x, o.y], [76, 5])
        XCTAssertEqual(o.boat, 5)
    }
}
