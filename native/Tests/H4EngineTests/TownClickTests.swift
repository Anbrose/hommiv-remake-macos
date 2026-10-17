import XCTest
@testable import H4Engine

/// Town view clicks (re/town_clicks_spec.md): every building of every town type opens what the
/// exe binds to its button, and the hit test picks the building the original would.
final class TownClickTests: XCTestCase {
    static let alignments = ["life", "order", "death", "chaos", "nature", "might"]

    /// What the exe's handlers (0x8aed50) open, by building keyword.
    static func expected(_ keyword: String, id: Int) -> TownView.Action {
        switch keyword {
        case "village hall", "town hall", "city hall": return .buyBuilding
        case "fort", "citadel", "castle": return .castle
        case "shipyard": return .buildShip
        case "caravan": return .caravan
        case "prison": return .prison
        case "tavern": return .tavern
        case "blacksmith": return .blacksmith
        case _ where keyword.hasPrefix("mage guild"), _ where keyword.hasSuffix(" library"): return .mageGuild
        case "seminary", "university": return .seminary
        case "treasury": return .treasury
        case "skeleton transformer": return .skeletonTransformer
        case "mana vortex": return .manaVortex
        case "creature portal": return .creaturePortal
        case "grail", "stables", "abbey", "necromancy amplifier", "academy", "training grounds", "rainbow", "grove",
             "breeding pit", "magic dampener", "arena": return .describe
        default: return (12...19).contains(id) ? .recruit : .describe
        }
    }

    func testEveryBuildingOfEveryTownOpensItsWindow() {
        for a in Self.alignments {
            let ids = RuleTables.buildingIds[a] ?? [:]
            let order = TownView.drawOrder[a] ?? []
            XCTAssertFalse(order.isEmpty, a)
            // every button is a building of the town and none is listed twice
            XCTAssertEqual(Set(order).count, order.count, a)
            for id in order {
                guard let k = ids[id] else { XCTFail("\(a): button \(id) is no building"); continue }
                XCTAssertEqual(TownView.leftClick(id), Self.expected(k, id: id), "\(a) \(k) (\(id))")
                XCTAssertEqual(TownView.rightClick(id), .describe, "\(a) \(k) (\(id))")
            }
            // the town's dwellings all recruit
            for id in 12...19 { XCTAssertTrue(order.contains(id), "\(a) dwelling \(id)"); XCTAssertEqual(TownView.leftClick(id), .recruit) }
        }
        // the cases the remake used to get wrong
        XCTAssertEqual(TownView.leftClick(25), .mageGuild)   // libraries
        XCTAssertEqual(TownView.leftClick(26), .mageGuild)
        XCTAssertEqual(TownView.leftClick(11), .describe)    // grail
        XCTAssertEqual(TownView.leftClick(28), .describe)    // stables
        XCTAssertEqual(TownView.leftClick(42), .describe)    // arena
        XCTAssertEqual(TownView.leftClick(30), .seminary)    // university
        XCTAssertEqual(TownView.leftClick(6), .buildShip)
        XCTAssertEqual(TownView.leftClick(8), .prison)
    }

    func layer(_ name: String, x: Int, y: Int, w: Int, h: Int, solid: (Int, Int) -> Bool) -> UILayer {
        var b = Bitmap(width: w, height: h)
        for yy in 0..<h { for xx in 0..<w where solid(xx, yy) { b.pixels[(yy * w + xx) * 4 + 3] = 17 } }
        return UILayer(name: name, kind: 4, x: x, y: y, width: w, height: h, bitmap: b)
    }

    func testHitTestTopmostSolidPictureAndForegroundsBlock() {
        let back = layer("back", x: 0, y: 0, w: 20, h: 20) { _, _ in true }
        let front = layer("front", x: 10, y: 10, w: 20, h: 20) { x, _ in x < 10 }   // right half transparent
        let shown: [(id: Int, layer: UILayer)] = [(3, back), (12, front)]
        XCTAssertEqual(TownView.building(at: 15, 15, shown: shown, foregrounds: []), 12)   // both solid: the later one
        XCTAssertEqual(TownView.building(at: 5, 5, shown: shown, foregrounds: []), 3)
        XCTAssertEqual(TownView.building(at: 25, 15, shown: shown, foregrounds: []), nil)  // the front's clear pixels and nothing below
        XCTAssertEqual(TownView.building(at: 22, 5, shown: shown, foregrounds: []), nil)   // outside both
        let fg = layer("foreground 1", x: 0, y: 0, w: 8, h: 8) { _, _ in true }
        XCTAssertEqual(TownView.building(at: 5, 5, shown: shown, foregrounds: [fg]), nil)  // a solid foreground takes the click
        XCTAssertEqual(TownView.building(at: 9, 9, shown: shown, foregrounds: [fg]), 3)
        // superseded and unbuilt buildings have no button
        let s = TownView.shown(alignment: "life", built: { [0, 1, 3, 4, 20, 21, 12].contains($0) }, layer: { id in self.layer("\(id)", x: 0, y: 0, w: 1, h: 1) { _, _ in true } })
        XCTAssertEqual(s.map(\.id), [1, 4, 21, 12])
    }

    // MARK: with the game's files

    func archives() throws -> (H4Archive, RuleTables) {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        guard FileManager.default.fileExists(atPath: data.appendingPathComponent("heroes4.h4r").path) else { throw XCTSkip("game data not installed") }
        let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: data.appendingPathComponent(f)) { archive.supplement(with: a) } }
        return (archive, try RuleTables(archive: H4Archive(url: data.appendingPathComponent("text.h4r"))))
    }

    func testDwellingsRecruitTheirCreatureAndEveryBuildingDescribesItself() throws {
        let (_, tables) = try archives()
        for a in Self.alignments {
            let defs = tables.buildings(for: a)
            for id in TownView.drawOrder[a] ?? [] {
                guard let k = RuleTables.buildingIds[a]?[id], let d = defs.first(where: { $0.keyword == k }) else { XCTFail("\(a): no table row for \(id)"); continue }
                XCTAssertFalse(d.name.isEmpty, "\(a) \(k)")
                if TownView.leftClick(id) == .recruit {
                    guard let c = d.creature else { XCTFail("\(a) \(k): no creature"); continue }
                    XCTAssertNotNil(tables.creature(c), "\(a) \(k) -> \(c)")
                }
            }
        }
    }

    /// With every building built, each building's picture can be clicked somewhere (not wholly
    /// covered by later buildings or the foregrounds), and that click finds it.
    func testEveryBuiltBuildingIsClickableOnTheRealViews() throws {
        let (archive, _) = try archives()
        for a in Self.alignments {
            guard let lay = try? LayerFile(data: archive.payload("layers.town.\(a).layout.h4d")),
                  let view = try? LayerFile(data: archive.payload("layers.town.\(a).grass.h4d")) else { XCTFail("\(a): no layout/view"); continue }
            let fg = view.layers.filter { $0.name.lowercased() != "background" && $0.width > 0 }
            XCTAssertEqual(view.layers.filter { $0.name.lowercased() == "background" }.count, 1, a)
            let ids = RuleTables.buildingIds[a] ?? [:]
            // the top of each upgrade chain, and everything else
            let all = Set(TownView.drawOrder[a] ?? [])
            let shown = TownView.shown(alignment: a, built: { all.contains($0) }, layer: { id in ids[id].flatMap { k in lay.layers.first { $0.name.lowercased() == k } } })
            XCTAssertGreaterThan(shown.count, 15, a)
            for (k, s) in shown.enumerated() {
                let l = s.layer
                var found = false
                outer: for y in stride(from: l.y, to: l.y + l.height, by: 2) {
                    for x in stride(from: l.x, to: l.x + l.width, by: 2) where TownView.opaque(l, x, y) {
                        if shown[(k + 1)...].contains(where: { TownView.opaque($0.layer, x, y) }) || fg.contains(where: { TownView.opaque($0, x, y) }) { continue }
                        XCTAssertEqual(TownView.building(at: x, y, shown: shown, foregrounds: fg), s.id)
                        found = true; break outer
                    }
                }
                XCTAssertTrue(found, "\(a) \(ids[s.id] ?? "?") cannot be clicked")
            }
        }
    }

    func testRefusalsOfTheDwellingAndBlacksmithHandlers() throws {
        let g = try DwellingTests().loadGame()
        guard !g.towns.isEmpty else { return XCTFail("no town") }
        let i = 0
        g.towns[i].owned = true
        g.towns[i].garrison = []; g.towns[i].garrisonHeroes = []
        g.townVisitor = nil
        for h in g.heroes { h.x = -10; h.y = -10 }
        XCTAssertEqual(g.blacksmithRefusal(town: i), g.tables?.strings["no_armies_for_blacksmith.text"])
        XCTAssertNil(g.townRecruitRefusal(town: i, creature: "squire"))
        g.towns[i].garrison = (0..<7).map { Hero.Stack(creature: "c\($0)", count: 1) }
        XCTAssertNil(g.blacksmithRefusal(town: i))
        XCTAssertEqual(g.townRecruitRefusal(town: i, creature: "c3"), nil)   // joins its stack
        XCTAssertTrue(g.townRecruitRefusal(town: i, creature: "squire")?.hasPrefix("There is no room in your garrison") ?? false)
        g.towns[i].owned = false
        XCTAssertEqual(g.townRecruitRefusal(town: i, creature: "c3"), g.tables?.strings["town.buy_creatures_not_owner"])
    }

    /// A purchase's fade (re/town_build_fade_spec.md): level n after n 50 ms ticks, full at 15
    /// (750 ms) when the animation starts; the replaced building goes at the first tick.
    func testBuildFade() {
        XCTAssertEqual(TownView.fadeTickSeconds, 0.05)
        XCTAssertEqual((0...20).map { TownView.fadeLevel(ticks: $0) }, Array(0...15) + [15, 15, 15, 15, 15])
        XCTAssertTrue(TownView.replacedShown(ticks: 0))
        XCTAssertFalse(TownView.replacedShown(ticks: 1))
        XCTAssertFalse(TownView.animates(ticks: 14))
        XCTAssertTrue(TownView.animates(ticks: 15))
        // 0x592370: w = L + ((L >> 3) & 1) of 16
        XCTAssertEqual(TownView.fadeWeight(level: 0), 0)
        XCTAssertEqual(TownView.fadeWeight(level: 7), 7 / 16)
        XCTAssertEqual(TownView.fadeWeight(level: 8), 9 / 16)
        XCTAssertEqual(TownView.fadeWeight(level: 14), 15 / 16)
        XCTAssertEqual(TownView.fadeWeight(level: 15), 1)
        // a kept (replaced) fort is shown with the citadel until the first tick
        let layer = UILayer(name: "x", kind: 4, x: 0, y: 0, width: 1, height: 1, bitmap: Bitmap(width: 1, height: 1))
        let built: (Int) -> Bool = { [0, 3, 4].contains($0) }
        XCTAssertEqual(TownView.shown(alignment: "life", built: built, layer: { _ in layer }).map { $0.id }, [0, 4])
        XCTAssertEqual(TownView.shown(alignment: "life", built: built, layer: { _ in layer }, keep: [3]).map { $0.id }, [0, 3, 4])
    }
}
