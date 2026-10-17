import XCTest
@testable import H4Engine

/// The army screen's artifact drag and drop (re/hero_artifacts_spec.md), on the game's own
/// table.Artifacts when the game is installed.
final class ArtifactDragTests: XCTestCase {
    var tables: RuleTables!
    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data/text.h4r")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("game data not installed") }
        tables = try RuleTables(archive: H4Archive(url: url))
    }
    func id(_ k: String) -> Int { RuleTables.artifactIds.firstIndex(of: k)! }
    func hero() -> Hero { Hero(actor: "hero.life_might_male", x: 0, y: 0, movement: 20) }

    func testSlotTypesFollowTheTable() {
        XCTAssertEqual(ArtifactRules.slotType(id("helm_of_command"), tables: tables), 2)
        XCTAssertEqual(ArtifactRules.slotType(id("greatsword"), tables: tables), ArtifactRules.bothHands)
        XCTAssertEqual(ArtifactRules.slotType(id("binding_liquid"), tables: tables), ArtifactRules.potion)
        XCTAssertEqual(ArtifactRules.slotType(id("crown"), tables: tables), ArtifactRules.backpackOnly)
        XCTAssertEqual(ArtifactRules.slotType(id("telescope"), tables: tables), ArtifactRules.miscellaneous)
        XCTAssertEqual(ArtifactRules.slotType(id("ring_of_regeneration"), tables: tables), ArtifactRules.ring)
    }

    func testWhichSlotsTakeWhat() {
        let h = hero()
        XCTAssertEqual(ArtifactRules.takingSlots(id("helm_of_command"), of: h, tables: tables), [2])
        XCTAssertEqual(ArtifactRules.takingSlots(id("greatsword"), of: h, tables: tables), [13])
        XCTAssertEqual(ArtifactRules.takingSlots(id("telescope"), of: h, tables: tables), [4, 5, 6, 7])
        XCTAssertEqual(ArtifactRules.takingSlots(id("ring_of_regeneration"), of: h, tables: tables), [3, 9])
        XCTAssertEqual(ArtifactRules.takingSlots(id("binding_liquid"), of: h, tables: tables), [])
        XCTAssertEqual(ArtifactRules.takingSlots(id("crown"), of: h, tables: tables), [])
        // occupied slots still take it (a swap) unless the army is not the player's
        h.equipped[2] = id("helm_of_power")
        XCTAssertEqual(ArtifactRules.takingSlots(id("helm_of_command"), of: h, tables: tables), [2])
        XCTAssertEqual(ArtifactRules.takingSlots(id("helm_of_command"), of: h, tables: tables, strict: true), [])
        h.equipped[13] = id("greatsword")
        XCTAssertFalse(ArtifactRules.accepts(id("shield"), slot: 10, of: h, tables: tables, strict: true))
        XCTAssertTrue(ArtifactRules.accepts(id("shield"), slot: 10, of: h, tables: tables))
    }

    func testTakeOffIntoTheBackpackAndPutBack() {
        let h = hero()
        h.equipped[2] = id("helm_of_command")
        h.backpack = [id("crown"), id("telescope")]
        let d = ArtifactRules.pickUp(.worn(h, 2))!
        XCTAssertNil(h.equipped[2])                        // the slot is empty while it is carried
        XCTAssertTrue(ArtifactRules.drop(d, on: .backpack(h, 1), tables: tables).accepted)
        XCTAssertEqual(h.backpack, [id("crown"), id("helm_of_command"), id("telescope")])
        // a drop on an empty place past the end goes to the front (0x652c69)
        let e = ArtifactRules.pickUp(.backpack(h, 1))!
        ArtifactRules.drop(e, on: .backpack(h, 7), tables: tables)
        XCTAssertEqual(h.backpack, [id("helm_of_command"), id("crown"), id("telescope")])
        // and back on the head
        let f = ArtifactRules.pickUp(.backpack(h, 0))!
        XCTAssertTrue(ArtifactRules.drop(f, on: .worn(h, 2), tables: tables).accepted)
        XCTAssertEqual(h.equipped[2], id("helm_of_command"))
        XCTAssertEqual(h.backpack, [id("crown"), id("telescope")])
    }

    func testRefusedOrLostDropsGoHome() {
        let h = hero()
        h.backpack = [id("crown"), id("helm_of_command")]
        let d = ArtifactRules.pickUp(.backpack(h, 1))!
        XCTAssertFalse(ArtifactRules.drop(d, on: .worn(h, 12), tables: tables).accepted)   // a helm on the torso
        ArtifactRules.cancel(d, tables: tables)
        // home is backpack place 1, now past the end: the exe's insert puts it in front (0x652c69)
        XCTAssertEqual(h.backpack, [id("helm_of_command"), id("crown")])
        let d2 = ArtifactRules.pickUp(.backpack(h, 0))!
        ArtifactRules.cancel(d2, tables: tables)
        XCTAssertEqual(h.backpack, [id("helm_of_command"), id("crown")])
        // from a worn slot: worn again
        h.equipped[1] = id("boots_of_speed")
        let e = ArtifactRules.pickUp(.worn(h, 1))!
        ArtifactRules.cancel(e, tables: tables)
        XCTAssertEqual(h.equipped[1], id("boots_of_speed"))
        ArtifactRules.cancel(e, tables: tables)              // only once
        XCTAssertEqual(h.backpack.count, 2)
    }

    func testSwapSendsTheWornOneWhereTheNewOneCameFrom() {
        let h = hero()
        h.equipped[2] = id("helm_of_power")
        h.backpack = [id("crown"), id("helm_of_command"), id("telescope")]
        let d = ArtifactRules.pickUp(.backpack(h, 1))!
        ArtifactRules.drop(d, on: .worn(h, 2), tables: tables)
        XCTAssertEqual(h.equipped[2], id("helm_of_command"))
        XCTAssertEqual(h.backpack, [id("crown"), id("helm_of_power"), id("telescope")])
        // rings swap between the two hands
        h.equipped[3] = id("ring_of_regeneration"); h.equipped[9] = id("equestrians_gloves")
        let r = ArtifactRules.pickUp(.worn(h, 3))!
        ArtifactRules.drop(r, on: .worn(h, 9), tables: tables)
        XCTAssertEqual(h.equipped[9], id("ring_of_regeneration"))
        XCTAssertEqual(h.equipped[3], id("equestrians_gloves"))
    }

    func testTwoHandedTakesBothHandsOff() {
        let h = hero()
        h.equipped[13] = id("axe"); h.equipped[10] = id("shield")
        h.backpack = [id("greatsword")]
        let d = ArtifactRules.pickUp(.backpack(h, 0))!
        ArtifactRules.drop(d, on: .worn(h, 13), tables: tables)
        XCTAssertEqual(h.equipped[13], id("greatsword"))
        XCTAssertNil(h.equipped[10])
        // both go to the backpack place it came from: the axe first, then the shield in front of it
        XCTAssertEqual(h.backpack, [id("shield"), id("axe")])
        // a shield into the free left hand sends the two-handed sword back where the shield was
        let s = ArtifactRules.pickUp(.backpack(h, 0))!
        ArtifactRules.drop(s, on: .worn(h, 10), tables: tables)
        XCTAssertEqual(h.equipped[10], id("shield"))
        XCTAssertNil(h.equipped[13])
        XCTAssertEqual(h.backpack, [id("greatsword"), id("axe")])
    }

    func testGivingToAnotherHeroOnItsRing() {
        let a = hero(), b = hero()
        a.equipped[12] = id("chainmail")
        let d = ArtifactRules.pickUp(.worn(a, 12))!
        ArtifactRules.drop(d, onto: b)
        XCTAssertNil(a.equipped[12])
        XCTAssertEqual(b.backpack, [id("chainmail")])
        ArtifactRules.cancel(d, tables: tables)              // consumed: nothing comes back
        XCTAssertNil(a.equipped[12])
    }

    func testWornEffectsChangeAtOnce() {
        let h = hero()
        h.backpack = [id("chainmail")]
        let before = h.artifactEffects.count
        let d = ArtifactRules.pickUp(.backpack(h, 0))!
        ArtifactRules.drop(d, on: .worn(h, 12), tables: tables)
        XCTAssertGreaterThan(h.artifactEffects.count, before)
        let e = ArtifactRules.pickUp(.worn(h, 12))!
        XCTAssertEqual(h.artifactEffects.count, before)       // carried: no longer worn
        ArtifactRules.cancel(e, tables: tables)
    }

    func testParchmentIsReadWhenPutOn() {
        let h = hero()
        // a parchment is a miscellaneous-slot... whatever its table slot, read it where it goes
        let sp = 72   // magic fist (order 1)
        let p = RuleTables.artifact(0x7c, spell: sp)
        let slot = ArtifactRules.takingSlots(p, of: h, tables: tables).first
        guard let s = slot else { return }
        h.backpack = [p]
        let d = ArtifactRules.pickUp(.backpack(h, 0))!
        let r = ArtifactRules.drop(d, on: .worn(h, s), tables: tables)
        if h.canLearn(sp) || h.spells.contains(sp) { return }
        XCTAssertEqual(r.note, .needsSkill(spell: sp, skill: RuleTables.spells[sp].schoolSkill))
        XCTAssertEqual(h.equipped[s], p)                      // not learned: it stays worn
    }
}
