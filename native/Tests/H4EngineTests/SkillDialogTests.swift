import XCTest
@testable import H4Engine

/// The teaching objects' selection dialogs (re/schools_spec.md): which portraits may be ticked, the
/// cost, and what Learn does.
final class SkillDialogTests: XCTestCase {
    /// The map, its scene and the tables, loaded once (building the scene is the slow part).
    static var loaded: (map: MapFile, scene: MapScene, tables: RuleTables)?
    func state() throws -> GameState {
        if Self.loaded == nil {
            let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
            let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/Cross Island.h4c")
            guard FileManager.default.fileExists(atPath: mapURL.path) else { throw XCTSkip("game data not installed") }
            let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
            for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: data.appendingPathComponent(f)) { archive.supplement(with: a) } }
            let tables = try RuleTables(archive: H4Archive(url: data.appendingPathComponent("text.h4r")))
            RandomResolver.creaturePool = (1...4).map { lv in tables.creatures.filter { $0.level == lv && $0.expansion == 0 }.map { $0.keyword } }
            let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
            let map = try MapFile(data: Data(contentsOf: mapURL), objectNames: names)
            let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
            Self.loaded = (map, try MapScene(map: map, level: 0, archive: archive, masks: masks), tables)
        }
        let l = Self.loaded!
        let g = GameState(map: l.map, level: 0, scenes: [l.scene])
        g.tables = l.tables
        g.registerObjects(townFactions: [:])
        return g
    }
    func place(_ g: GameState, _ type: String, _ subtype: String) throws -> MapScene.Placed {
        guard let p = g.scenes.first?.placed.first(where: { $0.type == type && $0.subtype == subtype }) else { throw XCTSkip("no \(type).\(subtype) on the map") }
        return p
    }

    func testHutTicksTheHeroesWhoCanLearnAndTeachesOnlyThoseTicked() throws {
        let g = try state()
        let p = try place(g, "school", "witchs_hut")
        let a = Hero(actor: "", x: 0, y: 0), b = Hero(actor: "", x: 0, y: 0), c = Hero(actor: "", x: 0, y: 0)
        b.setLv(4, 0)                                // knows life magic
        for s in [0, 1, 2, 3, 5] { c.setLv(s, 0) }   // five primaries
        let d = SkillDialog(kind: .hut(skill: 4), place: p, title: "", text: "", heroes: [a, b, c])
        XCTAssertEqual(d.heroes.indices.map { g.skillDialogEnabled(d, $0) }, [true, false, false])
        XCTAssertFalse(g.skillDialogCanLearn(d))
        g.skillDialogToggle(d, 1)                    // a disabled portrait does not tick
        XCTAssertFalse(d.ticked[1])
        g.skillDialogToggle(d, 0)
        XCTAssertTrue(g.skillDialogCanLearn(d))
        g.skillDialog = d
        g.skillDialogLearn(d)
        XCTAssertNil(g.skillDialog)
        XCTAssertEqual(a.skill(id: 4), 1)
    }

    func testSchoolCostsTwoThousandPerHeroAndMarksTheHero() throws {
        let g = try state()
        let p = try place(g, "school", "school_of_magic")
        g.objectStates[g.objectKey(p), default: ObjectState()].skills = [4, 5]
        let a = Hero(actor: "", x: 0, y: 0), b = Hero(actor: "", x: 0, y: 0)
        b.setLv(5, 0)   // knows order: refused for order, fine for life
        let d = SkillDialog(kind: .school(skills: [4, 5]), place: p, title: "", text: "", heroes: [a, b])
        g.skillDialogChoose(d, 1)
        XCTAssertEqual(d.heroes.indices.map { g.skillDialogEnabled(d, $0) }, [true, false])
        g.skillDialogChoose(d, 0)   // every hero who can is ticked again
        XCTAssertEqual(d.ticked, [true, true])
        XCTAssertEqual(g.skillDialogCost(d).amount, 4000)
        g.resources["Gold"] = 3999
        XCTAssertFalse(g.skillDialogCanLearn(d))
        g.resources["Gold"] = 4000
        g.skillDialog = d
        g.skillDialogLearn(d)
        XCTAssertNotNil(g.skillDialog)   // the school's dialog stays open
        XCTAssertEqual(g.resources["Gold"], 0)
        XCTAssertEqual(a.skill(id: 4), 1); XCTAssertEqual(b.skill(id: 4), 1)
        // one class per hero here, for good
        XCTAssertEqual(d.heroes.indices.map { g.skillDialogEnabled(d, $0) }, [false, false])
    }

    func testUniversityOffersTheMissingRequirementAndRemembersTheSlot() throws {
        let g = try state()
        let p = try place(g, "school", "magic_university")
        let wanted = 22   // the second life secondary: needs advanced life magic
        g.objectStates[g.objectKey(p), default: ObjectState()].skills = [wanted, 30, 33, 27]
        let h = Hero(actor: "", x: 0, y: 0)
        h.setLv(4, 0)     // basic life magic
        let d = SkillDialog(kind: .university(skills: [wanted, 30, 33, 27]), place: p, title: "", text: "", heroes: [h])
        d.hero = 0
        let o = try XCTUnwrap(g.universitySlot(h, p, 0))
        XCTAssertTrue(o.alternate)
        XCTAssertEqual(RuleTables.primary(of: o.skill), 4)
        g.resources["Gold"] = 2000
        XCTAssertEqual(g.universityStatus(d).cost, 2000)
        g.skillDialog = d
        g.skillDialogLearn(d)
        XCTAssertEqual(g.resources["Gold"], 0)
        let after = try XCTUnwrap(g.universitySlot(h, p, 0))
        XCTAssertTrue(after.stored)
        XCTAssertEqual(g.universityStatus(d).cost, 0)
    }

    func testTreeBuysALevelForEachTickedHero() throws {
        let g = try state()
        let p = try place(g, "tree_of_knowledge", "")
        let a = Hero(actor: "", x: 0, y: 0), b = Hero(actor: "", x: 0, y: 0)
        let d = SkillDialog(kind: .tree(material: 6, price: 5), place: p, title: "", text: "", heroes: [a, b])
        d.ticked = [true, true]
        g.resources["Gems"] = 9
        XCTAssertFalse(g.skillDialogCanLearn(d))
        g.skillDialogToggle(d, 1)
        XCTAssertEqual(g.skillDialogCost(d).amount, 5)
        XCTAssertTrue(g.skillDialogCanLearn(d))
        let before = a.experience
        g.skillDialog = d
        g.skillDialogLearn(d)
        XCTAssertNil(g.skillDialog)
        XCTAssertEqual(g.resources["Gems"], 4)
        XCTAssertGreaterThan(a.experience, before)
        XCTAssertEqual(b.experience, before)
    }
}
