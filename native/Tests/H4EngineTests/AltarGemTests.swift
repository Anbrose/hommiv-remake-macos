import XCTest
@testable import H4Engine

/// Altars (t_adv_altar 0x42d830, t_dialog_altar OK 0x66e480) and magic gems (0x4453d0, effect
/// 0x6bffe0); re/altar_gem_spec.md.
final class AltarGemTests: XCTestCase {
    func state() throws -> GameState {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4")
        let h4r = root.appendingPathComponent("Data/heroes4.h4r"), map = root.appendingPathComponent("maps/Beyond the lake.h4c")
        guard FileManager.default.fileExists(atPath: h4r.path), FileManager.default.fileExists(atPath: map.path) else { throw XCTSkip("no game files") }
        let archive = try H4Archive(url: h4r)
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        return GameState(map: try MapFile(data: Data(contentsOf: map), objectNames: names), level: 0, scenes: [])
    }

    func testAltarOffersThePrimaryToAHeroWithoutIt() throws {
        let g = try state()
        let h = Hero(actor: "", x: 0, y: 0)
        XCTAssertTrue(g.altarEligible(h, family: 0))
        XCTAssertEqual(g.altarSteps(h, family: 0).map { $0.skill }, [0])
        XCTAssertEqual(g.altarSteps(h, family: 0).map { $0.level }, [0])
    }

    func testAltarStepsAreTheFamilysNextLevelsWithTheirRequirements() throws {
        let g = try state()
        let h = Hero(actor: "", x: 0, y: 0)
        h.setLv(0, 0)   // basic tactics
        let steps = g.altarSteps(h, family: 0)
        // advanced tactics, and the tactics secondaries at basic whose requirements basic tactics meets
        XCTAssertTrue(steps.contains { $0.skill == 0 && $0.level == 1 })
        XCTAssertTrue(steps.allSatisfy { RuleTables.primary(of: $0.skill) == 0 && h.meets($0.skill, $0.level) })
        XCTAssertFalse(steps.contains { RuleTables.primary(of: $0.skill) != 0 })
    }

    func testAltarRefusesAHeroWithFivePrimariesAndNoneOfTheFamily() throws {
        let g = try state()
        let h = Hero(actor: "", x: 0, y: 0)
        for p in [0, 1, 2, 3, 4] { h.setLv(p, 0) }
        XCTAssertFalse(g.altarEligible(h, family: 5))
        XCTAssertTrue(g.altarEligible(h, family: 4))
    }

    func testGemEffects() throws {
        let g = try state()
        let h = Hero(actor: "", x: 0, y: 0)
        g.applyGem(h, kind: 1); XCTAssertEqual(h.defenseBonus, 6)
        g.applyGem(h, kind: 2); XCTAssertEqual(h.attackBonus, 6)
        g.applyGem(h, kind: 3); XCTAssertEqual(h.speedBonus, 2)
        // the opal: +6 to the maximum; spell points above the old maximum are kept as they are
        h.spellPoints = g.maxSpellPoints(h) + 20
        let before = h.spellPoints!
        g.applyGem(h, kind: 0)
        XCTAssertEqual(h.spellPointBonus, 6)
        XCTAssertEqual(h.spellPoints, before)
    }
}
